import Foundation
import Observation

@MainActor @Observable final class TVSession {
  private(set) var credential: DeviceCredential?
  private(set) var challenge: Challenge?
  private(set) var busy = false
  private(set) var authenticated = false
  private(set) var active = false
  private(set) var peerConnected = false
  private(set) var generation: String?
  private(set) var gameId: String?
  private(set) var snapshot: Message?
  private(set) var clockReading: ClockReading?
  private(set) var available = false
  private(set) var pending: Message?
  private(set) var checkingMove = false
  private(set) var needsReconnect = false
  private(set) var notice = "Pair this TV with the Chrome extension."
  private(set) var moveNotice: String?
  private(set) var now: TimeInterval = ProcessInfo.processInfo.systemUptime
  private var snapshotAt: TimeInterval?
  private var statusAt: TimeInterval?
  private var pendingAt: TimeInterval?
  private var pendingInterrupted = false
  private var sawDetachAfterPending = false
  private(set) var presentationEpoch = 0
  private var fresh = false {
    didSet {
      if !fresh { presentationEpoch += 1 }
    }
  }
  private var started = false
  private var attempt = 0
  private var reconnectAt: TimeInterval?
  private var authenticateBy: TimeInterval?
  private var operation = UUID()
  private var connection = UUID()
  private var soundsEnabled = true
  @ObservationIgnored private let sounds: any BoardSoundPlaying
  @ObservationIgnored private let api: PairingAPI
  @ObservationIgnored private let store: any CredentialStoring
  @ObservationIgnored private let socket: any RelayConnecting
  @ObservationIgnored private let uptime: () -> TimeInterval
  @ObservationIgnored private var pairingTask: Task<Void, Never>?
  @ObservationIgnored private var ticker: Task<Void, Never>?

  init(
    configuration: RelayConfiguration, store: (any CredentialStoring)? = nil,
    socket: (any RelayConnecting)? = nil, api: PairingAPI? = nil,
    sounds: (any BoardSoundPlaying)? = nil,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.api = api ?? PairingAPI(configuration: configuration)
    self.store = store ?? CredentialStore(origin: configuration.origin.absoluteString)
    self.socket = socket ?? RelaySocket()
    self.sounds = sounds ?? BoardSounds()
    self.uptime = uptime
  }
  func setSoundsEnabled(_ enabled: Bool) {
    soundsEnabled = enabled
    if !enabled { sounds.stop() }
  }
  var canMove: Bool {
    active && authenticated && peerConnected && fresh && available && pending == nil
      && snapshot?.generation == generation && snapshot?.gameId == gameId && snapshot?.result == nil
      && snapshot?.playerColor != nil && snapshot?.turn == snapshot?.playerColor
      && snapshotAt.map { now - $0 <= 5 } == true && statusAt.map { now - $0 <= 5 } == true
  }
  var selectionContext: String {
    "\(generation ?? "")/\(gameId ?? "")/\(snapshot?.revision ?? -1)/\(canMove)"
  }
  var clocksStale: Bool { clockReading?.frozenAt != nil }
  var statusText: String {
    if notice.hasPrefix("Unpair incomplete") { return notice }
    if pendingInterrupted {
      return "Move interrupted. Inspect Chrome and reconnect the game. Nothing will be resent."
    }
    if checkingMove { return "Checking move. Inspect Chrome if it remains unresolved." }
    if pending != nil { return "Waiting for the observed move…" }
    if available, fresh, snapshot?.result == nil, let turn = snapshot?.turn,
      let player = snapshot?.playerColor, turn != player {
      return "Waiting for the bot's move…"
    }
    return notice
  }

  func setActive(_ value: Bool) {
    guard active != value else { return }
    active = value
    if value {
      now = uptime()
      if !started {
        started = true
        do { credential = try store.load() } catch { notice = error.localizedDescription }
      }
      ticker = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          self?.tick()
        }
      }
      if credential != nil && !needsReconnect {
        connect()
      } else if challenge != nil {
        pollChallenge()
      }
    } else {
      invalidatePairingWork()
      ticker?.cancel()
      ticker = nil
      stopConnection()
      notice = "TV paused. Waiting to synchronize."
    }
  }

  func createCode() {
    guard active, credential == nil, !busy else { return }
    invalidatePairingWork()
    challenge = nil
    busy = true
    let op = operation
    pairingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await api.create()
        guard op == operation, active else { return }
        challenge = value
        busy = false
        notice = "Enter this code in the Chrome extension."
        pollChallenge()
      } catch {
        guard op == operation else { return }
        busy = false
        notice = error.localizedDescription
      }
    }
  }
  private func pollChallenge() {
    guard let challenge, active else { return }
    pairingTask?.cancel()
    let op = operation
    pairingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, op == operation, active {
        if challenge.expiresAt <= Date().timeIntervalSince1970 * 1000 {
          self.challenge = nil
          notice = "Code expired. Request a new code."
          return
        }
        do {
          let status = try await api.status(challenge)
          guard op == operation, active else { return }
          if status.state == "claimed" {
            notice = "Connecting to the extension…"
            // Entering this TV's code completes pairing; no second remote action is needed.
            // If the response is lost, poll again before deciding whether to retry.
            try await api.decide(challenge, confirm: true)
            guard op == operation, active else { return }
          } else {
            try acceptPairing(status)
          }
          if self.challenge == nil { return }
        } catch let error as HTTPFailure where [401, 404].contains(error.status) {
          guard op == operation else { return }
          self.challenge = nil
          notice = error.localizedDescription
          return
        } catch {
          guard op == operation else { return }
          notice = error.localizedDescription
          // Keep the challenge so credential delivery / Keychain persistence can be retried.
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
  func acceptPairing(_ status: PairingStatus) throws {
    switch status.state {
    case "confirmed":
      guard let id = status.pairingId, !id.isEmpty, id.utf16.count <= 128,
        let token = status.credential,
        token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
      else {
        throw ProtocolFailure("Relay did not deliver valid pairing credentials.")
      }
      let value = DeviceCredential(pairingId: id, credential: token)
      try store.save(value)
      credential = value
      challenge = nil
      needsReconnect = false
      connect()
    case "rejected":
      challenge = nil
      notice = "Pairing declined. Request a new code."
    case "claimed":
      notice = "Connecting to the extension…"
    default: break
    }
  }
  func reconnect() {
    guard active, credential != nil, !busy else { return }
    needsReconnect = false
    attempt = 0
    connect()
  }
  func unpair() {
    guard let credential, !busy else { return }
    invalidatePairingWork()
    busy = true
    stopConnection()
    let op = operation
    pairingTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await api.revoke(credential.credential)
        guard op == operation else { return }
        try store.remove()
        self.credential = nil
        snapshot = nil
        clockReading = nil
        pending = nil
        pendingInterrupted = false
        checkingMove = false
        needsReconnect = false
        notice = "Unpaired. Request a new code to connect again."
      } catch {
        guard op == operation else { return }
        needsReconnect = true
        notice =
          "Unpair incomplete. The saved credential was retained. \(error.localizedDescription)"
      }
      busy = false
    }
  }
  private func invalidatePairingWork() {
    operation = UUID()
    pairingTask?.cancel()
    pairingTask = nil
    busy = false
  }
  private func stopConnection() {
    sounds.stop()
    connection = UUID()
    socket.disconnect()
    reconnectAt = nil
    authenticateBy = nil
    authenticated = false
    available = false
    fresh = false
    peerConnected = false
    freezeClocks()
    if pending != nil { pendingInterrupted = true }
  }
  private func connect() {
    guard active, let credential else { return }
    stopConnection()
    let epoch = connection
    notice = "Connecting to relay…"
    socket.onMessage = { [weak self] message in
      guard let self, self.connection == epoch else { return }
      self.receive(message)
    }
    socket.onClose = { [weak self] code, reason in
      guard let self, self.connection == epoch else { return }
      self.closed(code: code, reason: reason)
    }
    socket.connect(url: api.configuration.socketURL, credential: credential.credential)
    authenticateBy = uptime() + 8
  }
  func closed(code: Int, reason: String) {
    stopConnection()
    notice = reason
    guard active, credential != nil else { return }
    if [4001, 4003, 1002, 1007, 1009].contains(code)
      || (code == 1008 && !["Heartbeat timeout", "Authentication timeout"].contains(reason))
    {
      needsReconnect = true
      if code == 4001 { notice = "Another TV replaced this connection. Reconnect to take over." }
      if code == 4003 { notice = "Pairing was revoked. Unpair here, then request a new code." }
      return
    }
    let delay = min(30, pow(2, Double(min(attempt, 5))) * Double.random(in: 0.75...1.25))
    attempt = min(attempt + 1, 5)
    notice = "Relay disconnected. Reconnecting…"
    reconnectAt = uptime() + delay
  }
  func receive(_ message: Message) {
    guard active else { return }
    now = uptime()
    if message.type == "authenticated" {
      guard message.role == "tv", message.pairingId == credential?.pairingId else {
        closed(code: 1002, reason: "Relay authenticated the wrong device. Unpair and try again.")
        return
      }
      authenticated = true
      attempt = 0
      authenticateBy = nil
      reconnectAt = nil
      notice = "Waiting for the extension…"
      return
    }
    if message.type == "error" {
      if ["unauthorized", "invalid_credential", "unsupported_version", "invalid_message"].contains(
        message.code ?? "")
      {
        closed(code: 1002, reason: message.message ?? "Relay rejected this client.")
      } else {
        available = false
        fresh = false
        freezeClocks()
        if message.code == "peer_unavailable" { peerConnected = false }
        notice = message.message ?? "Relay request failed."
        // Routing errors cannot repair the context they rejected. Wait for the
        // relay's next session instead of looping snapshot requests into errors.
      }
      return
    }
    guard authenticated else { return }
    if message.type == "session" {
      if pending != nil && message.generation != generation { pendingInterrupted = true }
      if pending != nil && message.gameId == nil { sawDetachAfterPending = true }
      generation = message.generation
      gameId = message.gameId
      peerConnected = message.peerConnected == true
      available = false
      fresh = false
      snapshotAt = nil
      statusAt = nil
      freezeClocks()
      notice =
        !peerConnected
        ? "Waiting for the Chrome extension to reconnect…"
        : gameId == nil
          ? "Start a Chess.com bot game, then connect it in the Chrome extension."
          : "Synchronizing game…"
      requestSnapshot()
      return
    }
    guard message.generation == generation, message.gameId == gameId, gameId != nil else { return }
    switch message.type {
    case "snapshot":
      if fresh, let old = snapshot?.revision, let next = message.revision, next < old { return }
      if fresh, message.revision == snapshot?.revision,
        message.board != snapshot?.board || message.turn != snapshot?.turn
          || message.playerColor != snapshot?.playerColor || message.result != snapshot?.result
      {
        closed(code: 1002, reason: "Position changed without a new revision. Reconnect the game.")
        return
      }
      // Only live, observed single-move transitions produce a cue. Reconnects,
      // duplicate snapshots, and missed positions establish a silent baseline.
      if soundsEnabled, fresh,
        let previous = snapshot, let transition = BoardTransition.between(previous, message)
      {
        sounds.play(transition.capturedSquare == nil ? .move : .capture)
      }
      // Reset presentation on the arriving baseline too: a reconnect may have
      // advanced the board while preserving the same game and generation.
      if !fresh { presentationEpoch += 1 }
      snapshot = message
      fresh = true
      snapshotAt = now
      if let clocks = message.clocks {
        clockReading = ClockReading(
          clocks: clocks, receivedAt: now, frozenAt: message.result == nil ? nil : now)
      }
      reconcileInterrupted()
    case "status":
      available = message.available == true
      statusAt = now
      notice = message.reason ?? "Your move"
      reconcileInterrupted()
    case "outcome":
      guard message.commandId == pending?.commandId, !pendingInterrupted else { return }
      if message.outcome == "uncertain" {
        moveNotice = message.reason
      } else {
        pending = nil
        pendingAt = nil
        checkingMove = false
        available = false
        statusAt = nil
        moveNotice = message.outcome == "rejected" ? (message.reason ?? "Move rejected.") : nil
        requestSnapshot()
      }
    default: break
    }
  }
  private func reconcileInterrupted() {
    // A snapshot alone cannot prove completion. Only a detached/re-attached,
    // available fresh session can clear an interrupted command locally.
    if pendingInterrupted, sawDetachAfterPending, fresh, available, peerConnected,
      snapshot?.generation == generation, snapshot?.gameId == gameId
    {
      pending = nil
      pendingAt = nil
      pendingInterrupted = false
      sawDetachAfterPending = false
      checkingMove = false
    }
  }
  func submit(from: Int, to: Int, promotion: String? = nil) {
    now = uptime()
    guard canMove, (0..<64).contains(from), (0..<64).contains(to), from != to,
      let snapshot, let board = snapshot.board,
      Square.color(of: board[from]) == snapshot.playerColor
    else { return }
    let promotes = Square.promotion(piece: board[from], destination: to)
    guard promotes ? ["q", "r", "b", "n"].contains(promotion ?? "") : promotion == nil else {
      return
    }
    var move = Message(type: "move")
    move.gameId = gameId
    move.generation = generation
    move.revision = snapshot.revision
    move.commandId = UUID().uuidString
    move.from = Square.name(from)
    move.to = Square.name(to)
    move.promotion = promotion
    pending = move
    pendingAt = now
    checkingMove = false
    pendingInterrupted = false
    sawDetachAfterPending = false
    moveNotice = nil
    send(move)
  }
  func requestSnapshot() {
    guard authenticated, peerConnected, let generation, let gameId else { return }
    var message = Message(type: "snapshot-request")
    message.generation = generation
    message.gameId = gameId
    send(message)
  }
  private func send(_ message: Message) {
    let epoch = connection
    Task { [weak self] in
      guard let self, connection == epoch else { return }
      do { try await socket.send(message) } catch {
        guard connection == epoch else { return }
        closed(code: 0, reason: "Relay connection was lost. No move will be replayed.")
      }
    }
  }
  func tick() {
    now = uptime()
    guard active else { return }
    // Monotonic deadlines also recover after delayed ticks or device sleep.
    if let authenticateBy, !authenticated, now >= authenticateBy {
      closed(code: 0, reason: "Relay authentication timed out.")
    } else if let reconnectAt, now >= reconnectAt, !needsReconnect, !busy {
      connect()
    }
    if let pendingAt, pending != nil, !checkingMove, now - pendingAt >= 5 {
      checkingMove = true
      requestSnapshot()
    }
    if fresh, snapshotAt.map({ now - $0 > 5 }) == true || statusAt.map({ now - $0 > 5 }) == true {
      available = false
      freezeClocks()
      notice = "Game observation is stale. Waiting for fresh state."
    }
  }
  private func freezeClocks() {
    if clockReading?.frozenAt == nil { clockReading?.frozenAt = uptime() }
  }
}
