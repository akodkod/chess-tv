import Foundation
import Observation

@MainActor @Observable final class MacSession {
  private(set) var status = "Pair your TV to connect a game"
  private(set) var error: String?
  private(set) var available = false
  private(set) var authenticated = false
  private(set) var saved: MacSavedState
  var paired: Bool { saved.device != nil }
  var pairing: Bool { saved.claim != nil }

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
    try persist { $0 = MacSavedState() }
    error = nil
    status = "Pair your TV to connect a game"
  }

  // Called synchronously by navigation/lifecycle events, even during an awaited move.
  func pageChanged() {
    available = false
    enqueue { [self] in try await detach() }
  }
  private func resetConnection() {
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
    if binding != nil { _ = try? await page.call(["kind": "stop"]) }
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
      if case .outcome(let value) = message, value.commandId == commandID {
        if value.outcome != .uncertain {
          try persist { $0.interruptedMove = false }
        }
        commandID = nil
      }
      if case .status(var value) = message {
        value.available = value.available && page.usable && session.peerConnected && !saved.interruptedMove
        if !value.available {
          value.reason = saved.interruptedMove ? "Inspect the interrupted move, then reconnect the game"
            : !session.peerConnected ? "Waiting for your TV"
            : !page.usable ? "Open the game in the Mac app" : value.reason
        }
        available = value.available
        status = value.reason ?? "Connected · Ready for your move"
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
    // Keychain persistence must succeed before any JavaScript can dispatch a move.
    try persist { $0.interruptedMove = true }
    commandID = move.commandId
    available = false
    do {
      let object = try JSONSerialization.jsonObject(with: Message.move(move).encoded())
      let reply = try await page.call(["kind": "move", "move": object])
      guard connection == epoch, binding.document == page.documentID else {
        commandID = nil
        return
      }
      try await process(reply)
      // Missing outcomes are ambiguous too; a normal tick must never clear the marker.
      if saved.interruptedMove { commandID = nil }
    } catch {
      commandID = nil
      try await unavailable("Move interrupted. Inspect the game, then reconnect.")
    }
  }
}
