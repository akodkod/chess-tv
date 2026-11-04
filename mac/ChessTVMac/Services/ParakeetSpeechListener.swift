import AppKit
import AVFoundation
import TranscribeCpp

/// Sample-count based segmentation, independent of inference speed or UI scheduling.
struct SpeechSegmenter {
  enum Action: Equatable { case idle, begin, append, finish, reject }
  private(set) var active = false
  private var speechSamples = 0
  private var silenceSamples = 0
  private var discarding = false
  mutating func accept(probability: Float, samples: Int) -> Action {
    let speech = probability >= (active ? 0.35 : 0.5)
    if speech { silenceSamples = 0 } else { silenceSamples += samples }
    if discarding {
      if silenceSamples >= 9600 { discarding = false; silenceSamples = 0 }
      return .idle
    }
    if !active {
      guard speech else { return .idle }
      active = true; speechSamples = samples
      return .begin
    }
    speechSamples += samples
    if speechSamples > 160000 {
      active = false; discarding = true; speechSamples = 0
      return .reject
    }
    if silenceSamples >= 9600 {
      active = false; speechSamples = 0; silenceSamples = 0
      return .finish
    }
    return .append
  }
}

actor ParakeetDecoder {
  private let model: Model
  private let session: Session
  private let vadModel: Model
  private let vad: VadSession
  private var stream: TranscribeCpp.Stream?
  private var segmenter = SpeechSegmenter()
  private var pending: [Float] = []
  private var preRoll: [Float] = []
  private var frameCount: Int64 = 0
  private var utteranceStart: Int64 = 0
  private var lastPartial = ""

  init() throws {
    Transcribe.disableLogging()
    for asset in SpeechModelStore.assets {
      try SpeechModelStore.verify(SpeechModelStore.directory.appendingPathComponent(asset.filename), asset: asset)
    }
    model = try Model(path: SpeechModelStore.directory.appendingPathComponent(SpeechModelStore.assets[0].filename).path,
      options: ModelOptions(backend: .metal))
    session = try model.session()
    vadModel = try Model(path: SpeechModelStore.directory.appendingPathComponent(SpeechModelStore.assets[1].filename).path,
      options: ModelOptions(backend: .cpu))
    vad = try vadModel.vadSession(threads: 1)
  }

  func consume(_ samples: [Float], began: Date) throws -> [SpeechCommand] {
    try Task.checkCancellation()
    pending += samples
    var events: [SpeechCommand] = []
    while pending.count >= 512 {
      try Task.checkCancellation()
      let frame = Array(pending.prefix(512)); pending.removeFirst(512)
      let probability = try vad.streamFeed(frame).probs.first ?? 0
      let action = segmenter.accept(probability: probability, samples: frame.count)
      let frameStart = frameCount
      frameCount += Int64(frame.count)
      switch action {
      case .idle:
        preRoll += frame
        if preRoll.count > 4800 { preRoll.removeFirst(preRoll.count - 4800) }
      case .begin:
        utteranceStart = max(0, frameStart - Int64(preRoll.count))
        stream = try session.stream(RunOptions(), StreamOptions(
          commitPolicy: .onFinalize, family: .parakeetBuffered(.init(leftMs: 5600, chunkMs: 160, rightMs: 320))))
        _ = try stream?.feed(preRoll + frame)
        preRoll.removeAll(keepingCapacity: true)
        lastPartial = ""
      case .append: _ = try stream?.feed(frame)
      case .finish:
        _ = try stream?.feed(frame)
        try stream?.finalize()
        let text = stream?.text.full.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
          events.append(SpeechCommand(text: text,
            start: began.addingTimeInterval(Double(utteranceStart) / 16000),
            end: began.addingTimeInterval(Double(frameCount) / 16000)))
        }
        stream = nil; lastPartial = ""; preRoll.removeAll(keepingCapacity: true)
      case .reject:
        stream?.reset(); stream = nil; preRoll.removeAll(keepingCapacity: true)
        events.append(SpeechCommand(text: "", start: began.addingTimeInterval(Double(utteranceStart) / 16000),
          end: began.addingTimeInterval(Double(frameCount) / 16000), rejection: "Command too long. Repeat one short move command."))
      }
      if let stream {
        let text = stream.text.display.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != lastPartial {
          lastPartial = text
          events.append(SpeechCommand(text: text, start: began.addingTimeInterval(Double(utteranceStart) / 16000),
            end: began.addingTimeInterval(Double(frameCount) / 16000), isFinal: false))
        }
      }
    }
    return events
  }
}

@MainActor final class ParakeetSpeechListener: SpeechListening {
  private var engine: AVAudioEngine?
  private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var stopped = false

  func run(status: @escaping (String) -> Void, command: @escaping (SpeechCommand) -> Void) async throws {
    defer { stop() }
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      throw ProtocolFailure("Microphone access denied. Enable Chess TV in System Settings → Privacy & Security → Microphone.")
    }
    status("Loading Parakeet Unified…")
    let decoder = try await Task.detached(priority: .userInitiated) { try ParakeetDecoder() }.value
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let natural = input.outputFormat(forBus: 0)
    guard natural.sampleRate > 0, natural.channelCount > 0,
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: natural, to: format) else {
      throw ProtocolFailure("No usable microphone. Connect one and toggle voice control to retry.")
    }
    let (audio, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    self.continuation = continuation; self.engine = engine
    input.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
      let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / natural.sampleRate)) + 32
      guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      var supplied = false
      var failure: NSError?
      let result = converter.convert(to: output, error: &failure) { _, state in
        if supplied { state.pointee = .noDataNow; return nil }
        supplied = true; state.pointee = .haveData; return buffer
      }
      guard result != .error else {
        continuation.finish(throwing: failure ?? ProtocolFailure("Microphone audio conversion failed.") as NSError); return
      }
      guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
      if case .dropped = continuation.yield(samples) {
        continuation.finish(throwing: ProtocolFailure("Voice recognition fell behind. Toggle the microphone to retry."))
      }
    }
    for (center, name) in [(NotificationCenter.default, Notification.Name.AVAudioEngineConfigurationChange),
                            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification)] {
      let observer = center.addObserver(forName: name,
        object: name == .AVAudioEngineConfigurationChange ? engine : nil, queue: nil) { _ in
          continuation.finish(throwing: ProtocolFailure("Microphone interrupted. Toggle voice control to retry."))
        }
      observers.append((center, observer))
    }
    engine.prepare()
    let began = Date()
    try engine.start()
    status("Listening · Parakeet Unified")
    for try await samples in audio {
      try Task.checkCancellation()
      let events = try await decoder.consume(samples, began: began)
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      for event in events { command(event) }
    }
  }
  func stop() {
    stopped = true
    engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
    continuation?.finish(); continuation = nil
    for (center, observer) in observers { center.removeObserver(observer) }
    observers.removeAll()
  }
}
