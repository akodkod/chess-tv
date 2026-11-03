import XCTest
@testable import ChessTV

@MainActor final class MemoryStore: MacStateStoring {
  var state = MacSavedState()
  var failSave = false
  func load() throws -> MacSavedState { state }
  func save(_ state: MacSavedState) throws {
    if failSave { throw ProtocolFailure("Storage failed") }
    self.state = state
  }
}

@MainActor final class FakePage: GamePage {
  var usable = true
  var documentID = UUID()
  var calls: [[String: Any]] = []
  var action: (([String: Any]) async throws -> AdapterReply)?
  func call(_ input: [String: Any]) async throws -> AdapterReply {
    calls.append(input)
    if let action { return try await action(input) }
    let messages: [Message] = input["kind"] as? String == "sync"
      ? [.status(GameStatus(context: GameContext(gameId: "game", generation: "generation"), available: true))] : []
    return AdapterReply(instance: "instance", gameId: "game", messages: messages, error: nil)
  }
}

@MainActor final class FakeSocket: RelayConnecting {
  var onMessage: ((Message) -> Void)?
  var onClose: ((Int, String) -> Void)?
  var sent: [Message] = []
  var connects = 0
  func connect(url: URL, credential: String) { connects += 1 }
  func send(_ message: Message) async throws { sent.append(message) }
  func disconnect() {}
}

@MainActor final class FakePairing: MacPairingServing {
  var result = PairingStatus(state: "confirmed", expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000,
    pairingId: "pair", credential: String(repeating: "a", count: 64))
  var revokeFails = false
  func claim(_ code: String) async throws -> PairingClaim {
    PairingClaim(challengeId: UUID().uuidString, token: String(repeating: "a", count: 64),
      expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
  }
  func poll(_ claim: PairingClaim) async throws -> PairingStatus { result }
  func revoke(_ credential: String) async throws {
    if revokeFails { throw ProtocolFailure("Offline") }
  }
}

@MainActor final class MacSessionTests: XCTestCase {
  var store: MemoryStore!
  var page: FakePage!
  var socket: FakeSocket!
  var api: FakePairing!
  var session: MacSession!
  let context = GameContext(gameId: "game", generation: "generation")

  override func setUp() async throws {
    store = MemoryStore()
    page = FakePage()
    socket = FakeSocket()
    api = FakePairing()
    session = try makeSession()
  }
  func makeSession() throws -> MacSession {
    try MacSession(page: page, socket: socket, api: api, store: store,
      configuration: RelayConfiguration("https://example.com"))
  }
  func attach() async throws {
    try await session.claim("123456")
    try await session.tick()
    try await session.receive(.authenticated(Authenticated(role: .extension, pairingId: "pair")))
    try await session.receive(.session(SessionState(generation: "generation", peerConnected: true)))
    try await session.receive(.session(SessionState(generation: "generation", gameId: "game", peerConnected: true)))
  }
  func move() -> MoveRequest {
    MoveRequest(context: context, revision: 1, commandId: "command", from: "e2", to: "e4")
  }
  func testPairingPersistsAndAttaches() async throws {
    try await attach()
    XCTAssertTrue(session.paired)
    XCTAssertNotNil(store.state.device)
    XCTAssertNil(store.state.claim)
    XCTAssertTrue(session.available)
    XCTAssertTrue(socket.sent.contains(.attachment(Attachment(generation: "generation", gameId: "game"))))
  }
  func testExpiredAndRejectedClaimsAreCleared() async throws {
    store.state.claim = PairingClaim(challengeId: "claim", token: "token", expiresAt: 1)
    session = try makeSession()
    do { try await session.tick(); XCTFail("Expected expiry") } catch {}
    XCTAssertNil(store.state.claim)
    try await session.claim("123456")
    api.result = PairingStatus(state: "rejected", expiresAt: 1000, pairingId: nil, credential: nil)
    do { try await session.tick(); XCTFail("Expected rejection") } catch {}
    XCTAssertNil(store.state.claim)
  }
  func testUnpairFailureKeepsCredentialAndBlocksReconnect() async throws {
    try await attach()
    api.revokeFails = true
    do { try await session.revoke(); XCTFail("Expected revocation failure") } catch {}
    XCTAssertTrue(store.state.revocationPending)
    XCTAssertNotNil(store.state.device)
    let count = socket.connects
    try await session.tick()
    XCTAssertEqual(socket.connects, count)
    api.revokeFails = false
    try await session.revoke()
    XCTAssertNil(store.state.device)
  }
  func testMovePersistsRiskBeforeDispatchAndClearsOnObservedOutcome() async throws {
    try await attach()
    page.action = { [self] input in
      XCTAssertEqual(input["kind"] as? String, "move")
      XCTAssertTrue(store.state.interruptedMove)
      return AdapterReply(instance: "instance", gameId: "game", messages: [
        .outcome(CommandOutcome(context: context, commandId: "command", outcome: .observedComplete))
      ], error: nil)
    }
    try await session.receive(.move(move()))
    XCTAssertFalse(store.state.interruptedMove)
    XCTAssertTrue(socket.sent.contains { if case .outcome(let value) = $0 { value.outcome == .observedComplete } else { false } })
  }
  func testStorageFailurePreventsDispatch() async throws {
    try await attach()
    let count = page.calls.count
    store.failSave = true
    do { try await session.receive(.move(move())); XCTFail("Expected storage failure") } catch {}
    XCTAssertEqual(page.calls.count, count)
  }
  func testNavigationDuringMovePreservesRiskAcrossRestart() async throws {
    try await attach()
    page.action = { [self] _ in
      page.documentID = UUID()
      return AdapterReply(instance: "instance", gameId: "game", messages: [
        .outcome(CommandOutcome(context: context, commandId: "command", outcome: .observedComplete))
      ], error: nil)
    }
    try await session.receive(.move(move()))
    XCTAssertTrue(store.state.interruptedMove)
    let count = page.calls.count
    session = try makeSession()
    try await session.tick()
    try await session.receive(.authenticated(Authenticated(role: .extension, pairingId: "pair")))
    try await session.receive(.session(SessionState(generation: "new", peerConnected: true)))
    XCTAssertEqual(page.calls.count, count)
    XCTAssertFalse(session.available)
  }
  func testUnavailablePageRejectsWithoutDispatch() async throws {
    try await attach()
    page.usable = false
    let count = page.calls.count
    try await session.receive(.move(move()))
    XCTAssertEqual(page.calls.count, count)
    XCTAssertFalse(store.state.interruptedMove)
    XCTAssertTrue(socket.sent.contains { if case .outcome(let value) = $0 { value.outcome == .rejected } else { false } })
  }
  func testStaleGenerationDoesNotDispatch() async throws {
    try await attach()
    var request = move()
    request.generation = "old"
    let count = page.calls.count
    try await session.receive(.move(request))
    XCTAssertEqual(page.calls.count, count)
  }
  func testUncertainMoveCannotReplay() async throws {
    try await attach()
    page.action = { [self] _ in
      AdapterReply(instance: "instance", gameId: "game", messages: [
        .outcome(CommandOutcome(context: context, commandId: "command", outcome: .uncertain))
      ], error: nil)
    }
    try await session.receive(.move(move()))
    let count = page.calls.count
    try await session.receive(.move(move()))
    XCTAssertEqual(page.calls.count, count)
    XCTAssertTrue(store.state.interruptedMove)
  }
  func testExternalDomainsAreNotTreatedAsChessCom() {
    XCTAssertTrue(ChessBrowser.isChessURL(URL(string: "https://www.chess.com/login")!))
    XCTAssertFalse(ChessBrowser.isChessURL(URL(string: "https://chess.com.evil.example")!))
    XCTAssertFalse(ChessBrowser.isChessURL(URL(string: "http://www.chess.com")!))
  }
}
