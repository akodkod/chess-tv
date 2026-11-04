import AppKit
import AVFoundation
import Speech

/// Audio exists only in the bounded stream feeding Apple's on-device recognizer.
@available(macOS 26, *)
@MainActor final class AppleSpeechListener: SpeechListening {
  static var unavailableReason: String? {
    SpeechTranscriber.isAvailable ? nil : "On-device voice recognition is unavailable on this Mac."
  }
  private let preferAccuracy: Bool

  init(preferAccuracy: Bool = true) { self.preferAccuracy = preferAccuracy }

  private var engine: AVAudioEngine?
  private var analyzer: SpeechAnalyzer?
  private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
  private var observers: [NSObjectProtocol] = []
  private var stopped = false

  func run(status: @escaping (String) -> Void,
           command: @escaping (SpeechCommand) -> Void) async throws {
    defer { stop() }
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      throw ProtocolFailure("Microphone access denied. Enable Chess TV in System Settings → Privacy & Security → Microphone.")
    }
    try checkRunning()
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
      throw ProtocolFailure("English on-device speech recognition is unavailable.")
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
      reportingOptions: preferAccuracy ? [.alternativeTranscriptions] : [.fastResults, .alternativeTranscriptions], attributeOptions: [.audioTimeRange])
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      status("Downloading English voice recognition…")
      try await installation.downloadAndInstall()
    }
    try checkRunning()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let natural = input.outputFormat(forBus: 0)
    guard natural.sampleRate > 0, natural.channelCount > 0,
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
      let converter = AVAudioConverter(from: natural, to: format) else {
      throw ProtocolFailure("No usable microphone. Connect one and toggle voice control to retry.")
    }
    try checkRunning()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    try await analyzer.prepareToAnalyze(in: format)
    try checkRunning()
    let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    self.continuation = continuation
    self.engine = engine
    // The converter and sample counter belong exclusively to the serial audio tap.
    var frames: Int64 = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
      let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate)) + 32
      guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      var supplied = false
      var failure: NSError?
      let result = converter.convert(to: output, error: &failure) { _, state in
        if supplied { state.pointee = .noDataNow; return nil }
        supplied = true
        state.pointee = .haveData
        return buffer
      }
      if result == .error {
        continuation.finish(throwing: failure ?? ProtocolFailure("Microphone audio conversion failed.") as NSError)
        return
      }
      guard output.frameLength > 0 else { return }
      let start = CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
      frames += Int64(output.frameLength)
      if case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: start)) {
        continuation.finish(throwing: ProtocolFailure("Voice recognition fell behind. Toggle the microphone to retry."))
      }
    }
    let center = NotificationCenter.default
    for name in [Notification.Name.AVAudioEngineConfigurationChange, NSWorkspace.willSleepNotification] {
      let notifications = name == NSWorkspace.willSleepNotification ? NSWorkspace.shared.notificationCenter : center
      observers.append(notifications.addObserver(forName: name,
        object: name == Notification.Name.AVAudioEngineConfigurationChange ? engine : nil, queue: nil) { _ in
          continuation.finish(throwing: ProtocolFailure("Microphone interrupted. Toggle voice control to retry."))
        })
    }
    engine.prepare()
    let began = Date()
    try engine.start()
    status("Listening · Say “Rook D4”, “Knight F3”, or “Pawn D4”…")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await analyzer.start(inputSequence: stream) }
      group.addTask { @MainActor in
        for try await result in transcriber.results {
          try Task.checkCancellation()
          guard result.isFinal else { continue }
          command(SpeechCommand(text: String(result.text.characters),
            start: began.addingTimeInterval(result.range.start.seconds),
            end: began.addingTimeInterval(CMTimeRangeGetEnd(result.range).seconds),
            alternatives: result.alternatives.prefix(8).map { String($0.characters) }))
        }
      }
      do {
        while try await group.next() != nil {}
      } catch {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        group.cancelAll()
        throw error
      }
    }
  }

  private func checkRunning() throws {
    try Task.checkCancellation()
    if stopped { throw CancellationError() }
  }
  func stop() {
    stopped = true
    if let engine {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    engine = nil
    continuation?.finish()
    continuation = nil
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    observers.removeAll()
    if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    analyzer = nil
  }
}
