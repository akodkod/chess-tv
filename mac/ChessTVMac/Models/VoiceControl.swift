import AppKit
import Observation

struct VoicePosition: Equatable {
  let token: String
  let document: UUID
  let since: Date
}

@MainActor protocol VoiceGameControlling: AnyObject {
  var voicePosition: VoicePosition? { get }
  func reportVoiceWarning(_ message: String)
  func setVoiceEnabled(_ enabled: Bool)
  func interpretVoice(_ text: String, alternatives: [String], position: VoicePosition, status: @escaping (String) -> Void) async throws
  func submitVoice(_ text: String, alternatives: [String], position: VoicePosition) async throws
}

extension VoiceGameControlling {
  func interpretVoice(_ text: String, alternatives: [String], position: VoicePosition, status: @escaping (String) -> Void) async throws {
    try await submitVoice(text, alternatives: alternatives, position: position)
  }
}

enum VoiceEngine: String, CaseIterable { case apple, parakeet }

struct SpeechCommand: Sendable {
  let text: String
  let start: Date
  let end: Date
  var alternatives: [String] = []
  var isFinal = true
  var rejection: String? = nil
}

@MainActor protocol SpeechListening: AnyObject {
  func run(status: @escaping (String) -> Void,
           command: @escaping (SpeechCommand) -> Void) async throws
  func stop()
}

@MainActor @Observable final class VoiceControl {
  private(set) var commandNotice: String?
  private var noticeTask: Task<Void, Never>?
  private(set) var lastHeard: String?
  private(set) var preferAccuracy = true
  private(set) var enabled = false
  private(set) var status: String?
  private(set) var error: String?
  private let appleUnavailableReason: String?
  private(set) var engine: VoiceEngine = .apple
  var unavailableReason: String? {
    if engine == .apple { return appleUnavailableReason }
    #if arch(arm64)
    return SpeechModelStore.shared.installed ? nil : "Download Parakeet in Voice Settings."
    #else
    return "Parakeet requires Apple Silicon."
    #endif
  }
  private let game: any VoiceGameControlling
  private let makeListener: (Bool) -> any SpeechListening
  private let errorSound: () -> Void
  private let allowsAI: () -> Bool
  private var listener: (any SpeechListening)?
  private var task: Task<Void, Never>?
  private var commandTask: Task<Void, Never>?
  private var epoch = UUID()
  private var finalizedThrough = Date.distantPast
  private var submitting = false
  private var diagnosticStart: Date?
  private var diagnosticTrace = UUID()

  init(game: any VoiceGameControlling, unavailableReason: String? = nil,
       makeListener: @escaping (Bool) -> any SpeechListening,
       errorSound: @escaping () -> Void = { NSSound(named: "Basso")?.play() },
       allowsAI: @escaping () -> Bool = { false }) {
    self.game = game
    self.appleUnavailableReason = unavailableReason
    self.makeListener = makeListener
    self.errorSound = errorSound
    self.allowsAI = allowsAI
  }

  static func live(game: any VoiceGameControlling) -> VoiceControl {
    if #available(macOS 26, *) {
      return VoiceControl(game: game, unavailableReason: AppleSpeechListener.unavailableReason,
        makeListener: { AppleSpeechListener(preferAccuracy: $0) },
        allowsAI: { UserDefaults.standard.bool(forKey: "voiceUseJev") })
    }
    return VoiceControl(game: game, unavailableReason: "Voice control requires macOS 26 or later.",
      makeListener: { _ in preconditionFailure("Unavailable speech engine") },
      allowsAI: { UserDefaults.standard.bool(forKey: "voiceUseJev") })
  }

  func setEngine(_ value: VoiceEngine) {
    guard engine != value else { return }
    let wasEnabled = enabled
    stop(); engine = value
    if wasEnabled { start() }
  }

  func interpretationSettingsChanged() {
    if enabled { stop(); start() }
  }

  func setPreferAccuracy(_ value: Bool) {
    guard preferAccuracy != value else { return }
    preferAccuracy = value
    if enabled { stop(); start() }
  }

  func toggle() { enabled ? stop() : start() }
  func start() {
    guard !enabled, unavailableReason == nil else { return }
    VoiceDiagnostics.shared.record("Listening started", "Engine: \(engine.rawValue); prefer accuracy: \(preferAccuracy); Jev enabled: \(allowsAI())")
    enabled = true
    error = nil
    status = "Preparing voice control…"
    finalizedThrough = .distantPast
    epoch = UUID()
    let current = epoch
    game.setVoiceEnabled(true)
    let source: any SpeechListening = engine == .parakeet ? ParakeetSpeechListener() : makeListener(preferAccuracy)
    listener = source
    task = Task { [weak self] in
      do {
        try await source.run(status: { [weak self] value in
          guard let self, epoch == current, enabled else { return }
          status = value
          VoiceDiagnostics.shared.record("Recognizer status", value)
        }, command: { [weak self] value in
          guard let self, epoch == current, enabled else { return }
          receive(value)
        })
        guard let self, epoch == current, enabled else { return }
        fail("Voice recognition stopped. Toggle the microphone to retry.")
      } catch {
        guard let self, epoch == current, enabled else { return }
        fail(error.localizedDescription)
      }
    }
  }
  func stop() {
    if enabled { VoiceDiagnostics.shared.record("Listening stopped", "Pending interpretation cancelled.") }
    noticeTask?.cancel(); noticeTask = nil; commandNotice = nil
    enabled = false
    epoch = UUID()
    listener?.stop()
    listener = nil
    task?.cancel()
    task = nil
    commandTask?.cancel(); commandTask = nil; submitting = false
    game.setVoiceEnabled(false)
    status = nil
    lastHeard = nil
    error = nil
  }
  private func fail(_ message: String) {
    stop()
    VoiceDiagnostics.shared.record("Error", message)
    error = message
    errorSound()
  }
  private func reject(_ message: String) {
    VoiceDiagnostics.shared.record("Error", message)
    error = message
    game.reportVoiceWarning(message)
    noticeTask?.cancel()
    commandNotice = lastHeard.map { "Command not found: \"\($0)\"" } ?? "Command not found"
    noticeTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      guard let self else { return }
      commandNotice = nil
      error = nil
      lastHeard = nil
      noticeTask = nil
    }
  }
  private func receive(_ command: SpeechCommand) {
    if diagnosticStart != command.start { diagnosticStart = command.start; diagnosticTrace = UUID() }
    VoiceTrace.$id.withValue(diagnosticTrace) { process(command) }
  }
  private func process(_ command: SpeechCommand) {
    VoiceDiagnostics.shared.record(command.isFinal ? "Final transcript" : "Partial transcript", "Engine: \(engine.rawValue)\nText: \(command.text)\nAlternatives: \(command.alternatives)\nAudio interval: \(command.start) – \(command.end)\nDuration: \(command.end.timeIntervalSince(command.start)) s")
    if let rejection = command.rejection {
      lastHeard = String(command.text.prefix(512))
      reject(rejection); return
    }
    guard command.end > finalizedThrough else { VoiceDiagnostics.shared.record("Ignored", "Duplicate or older segment"); return }
    if commandNotice != nil {
      noticeTask?.cancel(); noticeTask = nil; commandNotice = nil; error = nil
    }
    if !command.isFinal { lastHeard = String(command.text.prefix(512)); return }
    finalizedThrough = command.end
    let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
    lastHeard = String(text.prefix(512))
    // Admit a leading square fragment; the board resolver verifies it agrees
    // with the destination and rejects conflicting or multiple commands.
    let commandPrefix = #"^(?:(?:[a-h]|ay|bee|be|cee|see|sea|dee|gee|aitch|haitch)\s*(?:[1-8]|one|two|three|four|five|six|seven|eight|too|for|ate)[\s.,!?]+)?(move|castle|pawn|pon|knight|night|bishop|rook|queen|king)\b"#
    guard !text.isEmpty else { VoiceDiagnostics.shared.record("Ignored", "Empty transcript"); return }
    let bareSquare = #"^(?:[a-h]|ay|bee|be|cee|see|sea|dee|gee|aitch|haitch)\s*(?:[1-8]|one|two|three|four|five|six|seven|eight|too|for|ate)[.,!]*$"#
    if text.range(of: bareSquare, options: [.regularExpression, .caseInsensitive]) != nil {
      reject("Name the piece, for example Pawn D4 or Knight F3.")
      return
    }
    guard allowsAI() || text.range(of: commandPrefix, options: [.regularExpression, .caseInsensitive]) != nil else { VoiceDiagnostics.shared.record("Ignored", "No command prefix and Jev is disabled"); return }
    guard !submitting else { reject("A move is in progress. Repeat after it finishes."); return }
    guard let position = game.voicePosition, command.start >= position.since else {
      reject("Wait for your turn and a stable board, then repeat your command.")
      return
    }
    submitting = true
    error = nil
    let current = epoch
    commandTask = Task { [weak self] in
      guard let self else { return }
      defer { if epoch == current { submitting = false; status = "Listening · Say “Rook D4”, “Knight F3”, or “Pawn D4”…" } }
      guard enabled, epoch == current else { return }
      do {
        // The session rechecks the captured position inside its serialized queue.
        try await game.interpretVoice(String(text.prefix(512)),
          alternatives: command.alternatives.prefix(8).map { String($0.prefix(512)) }, position: position, status: { [weak self] value in
            guard let self, enabled, epoch == current else { return }
            status = value
          })
      } catch is CancellationError { VoiceDiagnostics.shared.record("Cancelled", "Interpretation cancelled; no replay."); return }
      catch {
        if enabled, epoch == current { reject(error.localizedDescription) }
      }
    }
  }
}
