import Foundation
import Observation

@MainActor @Observable final class MacSession: VoiceGameControlling {
  private(set) var status = "Pair your TV to connect a game"
  private(set) var error: String?
  private(set) var available = false
  private(set) var authenticated = false
  private(set) var saved: MacSavedState
  var paired: Bool { saved.device != nil }
  var pairing: Bool { saved.claim != nil }
  private var canChangeGameConnection: Bool {
    !saved.revocationPending && !attaching && commandID == nil && !voiceSubmitting
  }
  var canConnectGame: Bool {
    canChangeGameConnection && page.usable &&
      (saved.interruptedMove || (paired && authenticated && (!saved.autoConnect || (binding != nil && !available))))
  }
  var canDisconnectGame: Bool {
    paired && canChangeGameConnection && binding != nil
  }
  var canReconnectRelay: Bool {
    paired && !saved.revocationPending && !authenticated && !connecting
  }
  var gameConnectionActionTitle: String {
    binding != nil || saved.interruptedMove ? "Reconnect Game" : "Connect Game"
  }

  private(set) var voiceEnabled = false
  private(set) var voicePosition: VoicePosition?
  private var voiceWarning: (context: GameContext, message: String, until: TimeInterval)?
  private var voiceEpoch = UUID()
  private var voiceSubmitting = false
  private var interpretation: Task<String?, Error>?
  var useJev: () -> Bool = { UserDefaults.standard.bool(forKey: "voiceUseJev") }
  var interpretWithJev: (String, [VoiceCandidate]) async throws -> String? = { text, candidates in
    guard let key = try JevKeyStore().load(), !key.isEmpty else {
      throw ProtocolFailure("Add your Jev API key in Voice Settings.")
    }
    return try await JevMoveInterpreter().interpret(text, candidates: candidates, key: key)
  }

  func reportVoiceWarning(_ message: String) {
    guard authenticated, let session, session.peerConnected, let game = session.gameId,
      binding?.game == game, !attaching else { return }
    // Status reasons already travel through the relay. Keep the availability bit
    // tied to the board, and expire feedback instead of replaying it on reconnect.
    let text = "Voice command: " + message
    let bounded = String(decoding: Array(text.utf16.prefix(256)), as: UTF16.self)
    voiceWarning = (GameContext(gameId: game, generation: session.generation),
      bounded, ProcessInfo.processInfo.systemUptime + 4)
    scheduleTick()
  }

  func setVoiceEnabled(_ enabled: Bool) {
    interpretation?.cancel()
    interpretation = nil
    if !enabled { voiceWarning = nil }
    voiceEnabled = enabled
    voiceEpoch = UUID()
    voicePosition = nil
    if enabled { scheduleTick() }
  }

  private func refreshVoicePosition() async {
    guard voiceEnabled, page.usable, !saved.interruptedMove else { interpretation?.cancel(); voicePosition = nil; return }
    let document = page.documentID
    let epoch = voiceEpoch
    do {
      let reply = try await page.call(["kind": "voice-position"])
      guard epoch == voiceEpoch, document == page.documentID else { return }
      if let token = reply.voicePosition {
        if voicePosition?.token != token || voicePosition?.document != document {
          interpretation?.cancel()
          voicePosition = VoicePosition(token: token, document: document, since: Date())
        }
      } else { interpretation?.cancel(); voicePosition = nil }
    } catch { interpretation?.cancel(); voicePosition = nil }
  }

  func interpretVoice(_ text: String, alternatives: [String], position: VoicePosition,
                      status: @escaping (String) -> Void) async throws {
    let epoch = voiceEpoch
    let reply: AdapterReply = try await withCheckedThrowingContinuation { continuation in
      enqueue { [self] in
        do {
          guard voiceEnabled, voiceEpoch == epoch, voicePosition == position,
            page.documentID == position.document, page.usable, !saved.interruptedMove else {
            throw ProtocolFailure("Position changed. Repeat your command.")
          }
          let reply = try await page.call(["kind": "voice-resolve", "text": text,
            "alternatives": alternatives, "position": position.token])
          continuation.resume(returning: reply)
        } catch { continuation.resume(throwing: error) }
      }
    }
    try Task.checkCancellation()
    guard voiceEpoch == epoch, voicePosition == position,
      let resolution = reply.voiceResolution else { throw ProtocolFailure("Position changed. Repeat your command.") }
    VoiceDiagnostics.shared.record("Local parser", "State: \(resolution.state)\nMove: \(resolution.move ?? "none")\nReason: \(resolution.reason ?? "none")\nPosition: \(position.token)\nLegal moves:\n" + (reply.voiceCandidates ?? []).map { "\($0.id): \($0.description)" }.joined(separator: "\n"))
    let selected: String?
    switch resolution.state {
    case "resolved": selected = resolution.move
    case "rejected": throw ProtocolFailure(resolution.reason ?? "Repeat one clear move command.")
    case "fallback":
      guard useJev() else {
        throw ProtocolFailure(resolution.reason ?? "Say a piece and destination, for example Rook D4, Knight F3, or Pawn D4.")
      }
      guard let candidates = reply.voiceCandidates else { throw ProtocolFailure("No legal moves available.") }
      status("Interpreting…")
      let request = Task { try await interpretWithJev(text, candidates) }
      interpretation = request
      defer { interpretation = nil }
      selected = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
    default: throw ProtocolFailure("Invalid voice resolution.")
    }
    try Task.checkCancellation()
    guard voiceEpoch == epoch, voicePosition == position else { throw ProtocolFailure("Position changed. Repeat your command.") }
    guard let selected else { VoiceDiagnostics.shared.record("No move", "Interpreter abstained."); return }
    VoiceDiagnostics.shared.record("Move selected", "\(selected); rechecking position before dispatch.")
    try await submitVoice(text, alternatives: [], position: position, selectedMove: selected)
    VoiceDiagnostics.shared.record("Move completed", "\(selected); board confirmed completion.")
  }

  func submitVoice(_ text: String, alternatives: [String] = [], position: VoicePosition) async throws {
    try await submitVoice(text, alternatives: alternatives, position: position, selectedMove: nil)
  }

  private func submitVoice(_ text: String, alternatives: [String], position: VoicePosition, selectedMove: String? = nil) async throws {
    guard voiceEnabled, !voiceSubmitting, !saved.interruptedMove, commandID == nil else {
      throw ProtocolFailure("A move is in progress or needs inspection. Repeat after it finishes.")
    }
    voiceSubmitting = true
    defer { voiceSubmitting = false }
    let epoch = voiceEpoch
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      enqueue { [self] in
        do {
          guard voiceEnabled, voiceEpoch == epoch, voicePosition == position,
            page.documentID == position.document, page.usable, !saved.interruptedMove else {
            throw ProtocolFailure("Position changed. Repeat your command.")
          }
          // Let TV distinguish confirmed voice moves without changing the wire schema.
          let id = "voice-" + UUID().uuidString
          let action: [String: Any]
          if let selectedMove {
            action = ["kind": "voice-selected-move", "move": selectedMove, "position": position.token, "commandId": id]
          } else {
            action = ["kind": "voice-move", "text": text, "alternatives": alternatives, "position": position.token, "commandId": id]
          }
          let reply = try await dispatchMove(action, id: id, document: position.document)
          try await process(reply)
          await refreshVoicePosition()
          guard let outcome = reply.messages.compactMap({ message -> CommandOutcome? in
            if case .outcome(let value) = message, value.commandId == id { return value }
            return nil
          }).first else { throw ProtocolFailure("Move interrupted. Inspect the game, then reconnect.") }
          guard outcome.outcome == .observedComplete else {
            throw ProtocolFailure(outcome.reason ?? "Move not completed. Inspect the game.")
          }
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  // One durable dispatch boundary for TV and local voice commands.
  private func dispatchMove(_ action: [String: Any], id: String, document: UUID) async throws -> AdapterReply {
    try persist { $0.interruptedMove = true }
    commandID = id
    available = false
    voicePosition = nil
    defer { commandID = nil }
    let reply = try await page.call(action)
    guard document == page.documentID else {
      throw ProtocolFailure("Move interrupted by navigation. Inspect the game, then reconnect.")
    }
    for message in reply.messages {
      if case .outcome(let value) = message, value.commandId == id, value.outcome != .uncertain {
        try persist { $0.interruptedMove = false }
      }
    }
    return reply
  }

  private let page: GamePage
  private let socket: RelayConnecting
  private let api: MacPairingServing
  private let store: MacStateStoring
  private let configuration: RelayConfiguration
  private var session: SessionState?
  private var binding: (game: String, instance: String, document: UUID)?
  private var attaching = false
  private var commandID: String?
  private var connection = UUID()
  private var connecting = false
  private var halted = false
  private var connectDeadline = Date.distantFuture
  private var retryAt = Date.distantPast
  private var attempts = 0
  private var tail: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var tickQueued = false

  init(page: GamePage, socket: RelayConnecting, api: MacPairingServing,
    store: MacStateStoring, configuration: RelayConfiguration) throws {
    self.page = page
    self.socket = socket
    self.api = api
    self.store = store
    self.configuration = configuration
    saved = try store.load()
    if saved.interruptedMove {
      status = "Inspect the interrupted move, then reconnect the game"
    }
  }

  func start() {
    guard timer == nil else { return }
    timer = Task { [weak self] in
      while !Task.isCancelled {
        self?.scheduleTick()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
  func stop() {
    setVoiceEnabled(false)
    timer?.cancel()
    timer = nil
    resetConnection()
  }
  private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
    let previous = tail
    tail = Task { [weak self] in
      await previous?.value
      do { try await action() }
      catch {
        self?.available = false
        self?.error = error.localizedDescription
      }
    }
  }
  private func scheduleTick() {
    guard !tickQueued else { return }
    tickQueued = true
    enqueue { [weak self] in
      guard let self else { return }
      defer { tickQueued = false }
      try await tick()
    }
  }
  private func persist(_ update: (inout MacSavedState) -> Void) throws {
    var next = saved
    update(&next)
    try store.save(next)
    saved = next
  }

  func pair(code: String) { enqueue { [self] in try await claim(code) } }
  func claim(_ code: String) async throws {
    guard !paired, !pairing else { throw ProtocolFailure("Finish the current pairing first.") }
    error = nil
    let claim = try await api.claim(code)
    try persist { $0.claim = claim; $0.autoConnect = true }
    status = "Confirm pairing on your TV"
  }
  private func pollPairing() async throws {
    guard let claim = saved.claim else { return }
    if claim.expiresAt <= Date().timeIntervalSince1970 * 1000 {
      try persist { $0.claim = nil }
      throw ProtocolFailure("Pairing expired. Request a new TV code.")
    }
    let result: PairingStatus
    do { result = try await api.poll(claim) }
    catch let failure as HTTPFailure where [401, 404].contains(failure.status) {
      try persist { $0.claim = nil }
      throw failure
    }
    if result.state == "rejected" {
      try persist { $0.claim = nil }
      throw ProtocolFailure("Pairing declined on TV. Request a new code.")
    }
    if result.state == "confirmed" {
      guard let id = result.pairingId, let credential = result.credential else {
        throw ProtocolFailure("Invalid pairing response.")
      }
      try persist {
        $0.device = DeviceCredential(pairingId: id, credential: credential)
        $0.claim = nil
      }
      error = nil
      status = "Pairing complete"
      halted = false
    }
  }

  func reconnectGame() { enqueue { [self] in
    // An explicit reconnect acknowledges that the user inspected an ambiguous move.
    try await detach()
    try persist { $0.interruptedMove = false; $0.autoConnect = true }
    commandID = nil
    error = nil
    try await synchronize()
  } }
  func disconnectGame() { enqueue { [self] in
    try persist { $0.autoConnect = false }
    try await detach()
    status = "Game disconnected"
  } }
  func reconnectRelay() { enqueue { [self] in
    resetConnection()
    halted = false
    retryAt = .distantPast
    error = nil
    connectIfNeeded()
  } }
  func unpair() { enqueue { [self] in try await revoke() } }
  func revoke() async throws {
    try persist { $0.revocationPending = true; $0.autoConnect = false }
    try? await detach()
    resetConnection()
    if let credential = saved.device?.credential { try await api.revoke(credential) }
    try persist { state in
      let interrupted = state.interruptedMove
      state = MacSavedState()
      state.interruptedMove = interrupted
    }
    error = nil
    status = "Pair your TV to connect a game"
  }

  // Called synchronously by navigation/lifecycle events, even during an awaited move.
  func pageChanged() {
    interpretation?.cancel()
    voicePosition = nil
    voiceEpoch = UUID()
    available = false
    enqueue { [self] in try await detach() }
  }
  private func resetConnection() {
    voiceWarning = nil
    connection = UUID()
    socket.disconnect()
    authenticated = false
    connecting = false
    available = false
    session = nil
    attaching = false
    commandID = nil
  }
  private func connectIfNeeded() {
    guard let device = saved.device, !saved.revocationPending, !halted,
      !connecting, !authenticated, Date() >= retryAt else { return }
    connecting = true
    connectDeadline = Date().addingTimeInterval(5)
    status = "Connecting to relay…"
    let epoch = connection
    socket.onMessage = { [weak self] message in
      guard let self, connection == epoch else { return }
      enqueue { [weak self] in
        guard let self, connection == epoch else { return }
        try await receive(message)
      }
    }
    socket.onClose = { [weak self] code, reason in
      guard let self, connection == epoch else { return }
      closed(code: code, reason: reason)
    }
    socket.connect(url: configuration.socketURL, credential: device.credential)
  }
  private func closed(code: Int, reason: String) {
    resetConnection()
    if [4001, 4003, 1002, 1007, 1009].contains(code)
      || (code == 1008 && !["Heartbeat timeout", "Authentication timeout"].contains(reason)) {
      halted = true
      error = code == 4001 ? "Connection replaced. Reconnect relay to take over." : reason
    } else {
      attempts = min(attempts + 1, 5)
      retryAt = Date().addingTimeInterval(min(30, pow(2, Double(attempts - 1))))
      status = "Relay disconnected. Reconnecting…"
    }
  }
  func tick() async throws {
    try await pollPairing()
    if connecting && Date() >= connectDeadline { closed(code: 0, reason: "Authentication timed out") }
    connectIfNeeded()
    try await synchronize()
    await refreshVoicePosition()
  }

  func receive(_ message: Message) async throws {
    switch message {
    case .authenticated(let value):
      guard !authenticated, value.role == .extension else {
        closed(code: 1002, reason: "Relay returned an invalid device role.")
        return
      }
      authenticated = true
      connecting = false
      attempts = 0
      error = nil
    case .session(let value):
      guard authenticated else { return }
      error = nil
      session = value
      attaching = false
      available = false
      try await synchronize()
    case .snapshotRequest(let value):
      if value.generation == session?.generation && value.gameId == session?.gameId {
        try await synchronize()
      }
    case .move(let move): try await submit(move)
    case .error(let value):
      error = value.message
      try await unavailable(value.message)
    default: break
    }
  }

  private func attachment(_ game: String?) async throws {
    guard let session, authenticated else { return }
    attaching = true
    do { try await socket.send(.attachment(Attachment(generation: session.generation, gameId: game))) }
    catch { attaching = false; throw error }
  }
  private func detach() async throws {
    available = false
    if binding != nil || voiceEnabled || saved.interruptedMove {
      _ = try? await page.call(["kind": "stop"])
    }
    binding = nil
    if session?.gameId != nil, !attaching { try await attachment(nil) }
  }
  private func unavailable(_ reason: String) async throws {
    available = false
    status = reason
    if let session, let game = session.gameId, session.peerConnected, authenticated, !attaching {
      try await socket.send(.status(GameStatus(context: GameContext(gameId: game,
        generation: session.generation), available: false, reason: String(reason.prefix(256)))))
    }
  }
  private func synchronize() async throws {
    guard authenticated, let session, !attaching else { return }
    if saved.interruptedMove && commandID == nil {
      try await unavailable("Inspect the interrupted move, then reconnect the game")
      return
    }
    if binding == nil {
      if session.gameId != nil { try await attachment(nil); return }
      guard saved.autoConnect, page.usable, !saved.revocationPending else { return }
      let document = page.documentID
      let epoch = connection
      do {
        let reply = try await page.call(["kind": "inspect"])
        guard document == page.documentID, epoch == connection else { return }
        guard reply.error == nil, let game = reply.gameId else {
          status = reply.error?.message ?? "Open a game to play or watch on TV"
          return
        }
        binding = (game, reply.instance, document)
        try await attachment(game)
      } catch { status = "Open a game to play or watch on TV" }
      return
    }
    guard let binding else { return }
    if binding.document != page.documentID { try await detach(); return }
    if session.gameId != binding.game { try await attachment(binding.game); return }
    let epoch = connection
    do {
      let reply = try await page.call(["kind": "sync", "generation": session.generation,
        "enabled": page.usable && session.peerConnected && !saved.interruptedMove])
      guard epoch == connection else { return }
      try await process(reply)
    } catch { try await unavailable("Game unavailable. Keep the game open.") }
  }
  private func process(_ reply: AdapterReply) async throws {
    guard let binding, let session, binding.document == page.documentID else { return }
    if reply.gameId != binding.game || reply.instance != binding.instance || reply.error?.code == "game_changed" {
      try await detach()
      return
    }
    if let failure = reply.error { try await unavailable(failure.message); return }
    guard !attaching, session.gameId == binding.game, authenticated else { return }
    error = nil
    for message in reply.messages {
      let context: GameContext
      switch message {
      case .snapshot(let value): context = value.context
      case .status(let value): context = value.context
      case .outcome(let value): context = value.context
      default: continue
      }
      guard context.gameId == binding.game, context.generation == session.generation else { continue }
      if case .status(var value) = message {
        value.available = value.available && page.usable && session.peerConnected && !saved.interruptedMove
        if !value.available {
          value.reason = saved.interruptedMove ? "Inspect the interrupted move, then reconnect the game"
            : !session.peerConnected ? "Waiting for your TV"
            : !page.usable ? "Open the game in the Mac app" : value.reason
        }
        available = value.available
        status = value.reason ?? "Connected · Ready for your move"
        if let warning = voiceWarning, warning.context == value.context,
          ProcessInfo.processInfo.systemUptime < warning.until,
          page.usable, !saved.interruptedMove {
          value.reason = warning.message
        } else { voiceWarning = nil }
        if session.peerConnected { try await socket.send(.status(value)) }
      } else if session.peerConnected { try await socket.send(message) }
    }
  }
  private func submit(_ move: MoveRequest) async throws {
    guard authenticated, !attaching, let session, session.peerConnected,
      session.generation == move.generation, session.gameId == move.gameId,
      let binding, binding.game == move.gameId else { return }
    let epoch = connection
    guard page.usable, binding.document == page.documentID, !saved.interruptedMove else {
      try await socket.send(.outcome(CommandOutcome(context: move.context,
        commandId: move.commandId, outcome: .rejected, reason: "Game is unavailable. Inspect and reconnect if needed.")))
      return
    }
    do {
      let object = try JSONSerialization.jsonObject(with: Message.move(move).encoded())
      let reply = try await dispatchMove(["kind": "move", "move": object],
        id: move.commandId, document: binding.document)
      guard connection == epoch, binding.document == page.documentID else {
        return
      }
      try await process(reply)
    } catch {
      if !saved.interruptedMove { throw error }
      commandID = nil
      try await unavailable("Move interrupted. Inspect the game, then reconnect.")
    }
  }
}
