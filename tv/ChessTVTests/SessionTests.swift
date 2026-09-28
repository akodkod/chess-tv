import SwiftUI
import XCTest

@testable import ChessTV

final class MemoryCredentials: CredentialStoring {
  var value: DeviceCredential? = .init(
    pairingId: "pair", credential: String(repeating: "a", count: 64))
  var failSave = false
  var failRemove = false
  func load() throws -> DeviceCredential? { value }
  func save(_ value: DeviceCredential) throws {
    if failSave { throw ProtocolFailure("Keychain unavailable") }
    self.value = value
  }
  func remove() throws {
    if failRemove { throw ProtocolFailure("Keychain unavailable") }
    value = nil
  }
}
@MainActor final class FakeSocket: RelayConnecting {
  var onMessage: ((Message) -> Void)?
  var onClose: ((Int, String) -> Void)?
  var sent: [Message] = []
  var connects = 0
  var failSend = false
  func connect(url: URL, credential: String) { connects += 1 }
  func send(_ message: Message) async throws {
    if failSend { throw ProtocolFailure("Offline") }
    sent.append(message)
  }
  func disconnect() {}
}
@MainActor final class SessionTests: XCTestCase {
  var socket: FakeSocket!
  var session: TVSession!
  var time = 100.0
  override func setUp() async throws {
    time = 100
    socket = FakeSocket()
    session = TVSession(
      configuration: try RelayConfiguration("https://example.com"), store: MemoryCredentials(),
      socket: socket, uptime: { [unowned self] in self.time })
    session.setActive(true)
    var auth = Message(type: "authenticated")
    auth.role = "tv"
    auth.pairingId = "pair"
    session.receive(auth)
  }
  override func tearDown() async throws {
    session.setActive(false)
    session = nil
    socket = nil
  }
  func state(generation: String = "generation-1", game: String? = "game-1") {
    var message = Message(type: "session")
    message.generation = generation
    message.gameId = game
    message.peerConnected = true
    session.receive(message)
  }
  func available(generation: String = "generation-1") {
    var message = Message(type: "status")
    message.generation = generation
    message.gameId = "game-1"
    message.available = true
    session.receive(message)
  }
  func ready() throws {
    state()
    session.receive(try ProtocolTests.fixture())
    available()
  }
  func outcome(_ result: String, command: String? = nil) {
    var message = Message(type: "outcome")
    message.generation = "generation-1"
    message.gameId = "game-1"
    message.commandId = command ?? session.pending?.commandId
    message.outcome = result
    session.receive(message)
  }
  func testBoardRenderingForVisualInspection() throws {
    guard ProcessInfo.processInfo.environment["CHESS_TV_RENDER"] == "1" else {
      throw XCTSkip(
        "Enable CHESS_TV_RENDER=1 for static board renders; remote focus requires a live view.")
    }
    try ready()
    var position = try ProtocolTests.fixture()
    position.revision = 2
    position.board =
      Array("rnbqkbnrpppppppp").map(String.init) + Array(repeating: nil, count: 32)
      + Array("PPPPPPPPRNBQKBNR").map(String.init)
    session.receive(position)
    for color in [PieceColor.white, .black] {
      position.playerColor = color
      position.turn = color
      position.revision! += 1
      session.receive(position)
      available()
      let view = ContentView(session: session)
        .padding(60).frame(width: 1920, height: 1080)
        .background(Color.black).environment(\.colorScheme, .dark)
      let renderer = ImageRenderer(content: view)
      let image = try XCTUnwrap(renderer.uiImage)
      let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let url = directory.appendingPathComponent("Board-\(color.rawValue).png")
      try XCTUnwrap(image.pngData()).write(to: url)
      print("Board rendering: \(url.path)")
    }
  }
  func testFailedSubmissionIsNotReplayedOnReconnect() async throws {
    try ready()
    socket.failSend = true
    session.submit(from: 60, to: 52)
    await Task.yield()
    await Task.yield()
    XCTAssertNotNil(session.pending)
    XCTAssertFalse(session.canMove)
    socket.failSend = false
    session.reconnect()
    XCTAssertNotNil(session.pending)
    XCTAssertEqual(socket.sent.filter { $0.type == "move" }.count, 0)
  }
  func testFreshSnapshotAndStatusRequiredInEitherOrder() throws {
    state()
    available()
    XCTAssertFalse(session.canMove)
    session.receive(try ProtocolTests.fixture())
    XCTAssertTrue(session.canMove)
    state(generation: "new")
    XCTAssertFalse(session.canMove)
    session.receive(try ProtocolTests.fixture())
    available()
    XCTAssertFalse(session.canMove)
    var fresh = try ProtocolTests.fixture()
    fresh.generation = "new"
    session.receive(fresh)
    XCTAssertFalse(session.canMove)
    available(generation: "new")
    XCTAssertTrue(session.canMove)
  }
  func testOnePendingMoveTimeoutAndDefinitiveOutcome() async throws {
    try ready()
    session.submit(from: 60, to: 52)
    let id = session.pending?.commandId
    session.submit(from: 60, to: 51)
    XCTAssertEqual(session.pending?.commandId, id)
    time += 5
    session.tick()
    XCTAssertTrue(session.checkingMove)
    outcome("uncertain")
    XCTAssertNotNil(session.pending)
    outcome("observed-complete", command: "other")
    XCTAssertNotNil(session.pending)
    var changed = try ProtocolTests.fixture()
    changed.revision = 2
    changed.board?[60] = nil
    changed.board?[52] = "K"
    session.receive(changed)
    XCTAssertNotNil(session.pending)
    outcome("observed-complete")
    XCTAssertNil(session.pending)
    XCTAssertFalse(session.canMove)
    available()
    XCTAssertTrue(session.canMove)
    await Task.yield()
    XCTAssertEqual(socket.sent.filter { $0.type == "move" }.count, 1)
    XCTAssertGreaterThanOrEqual(socket.sent.filter { $0.type == "snapshot-request" }.count, 2)
  }
  func testInterruptedMoveNeedsDetachAndFreshAvailableSession() throws {
    try ready()
    session.submit(from: 60, to: 52)
    state(generation: "new")
    var fresh = try ProtocolTests.fixture()
    fresh.generation = "new"
    session.receive(fresh)
    available(generation: "new")
    XCTAssertNotNil(session.pending)
    XCTAssertFalse(session.canMove)
    state(generation: "detached", game: nil)
    state(generation: "reattached")
    fresh.generation = "reattached"
    session.receive(fresh)
    available(generation: "reattached")
    XCTAssertNil(session.pending)
    XCTAssertTrue(session.canMove)
  }
  func testStalenessSuspensionAndReplacementDisableMoves() throws {
    try ready()
    time += 6
    session.tick()
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
    session.receive(try ProtocolTests.fixture())
    available()
    XCTAssertTrue(session.canMove)
    session.setActive(false)
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
    session.setActive(true)
    XCTAssertFalse(session.canMove)
    session.closed(code: 4001, reason: "Replaced")
    XCTAssertTrue(session.needsReconnect)
    let before = socket.connects
    session.reconnect()
    XCTAssertEqual(socket.connects, before + 1)
  }
  func testRoutingErrorDoesNotRetryIntoAnErrorLoop() async throws {
    try ready()
    await Task.yield()
    let count = socket.sent.count
    var error = Message(type: "error")
    error.code = "peer_unavailable"
    error.message = "Extension offline"
    session.receive(error)
    await Task.yield()
    XCTAssertEqual(socket.sent.count, count)
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
  }
  func testOldRevisionAndWrongGameIgnored() throws {
    try ready()
    var message = try ProtocolTests.fixture()
    message.revision = 0
    message.board?[60] = nil
    session.receive(message)
    XCTAssertEqual(session.snapshot?.revision, 1)
    message.revision = 9
    message.gameId = "other"
    session.receive(message)
    XCTAssertEqual(session.snapshot?.revision, 1)
  }
  func testOutcomeRejectionAndResultNeverOptimisticallyMovePieces() throws {
    try ready()
    let original = session.snapshot?.board
    session.submit(from: 60, to: 52)
    XCTAssertEqual(session.snapshot?.board, original)
    outcome("rejected")
    XCTAssertNil(session.pending)
    XCTAssertNotNil(session.moveNotice)
    var ended = try ProtocolTests.fixture()
    ended.revision = 2
    ended.result = .draw
    session.receive(ended)
    available()
    XCTAssertFalse(session.canMove)
  }
  func testPromotionsRequireExplicitChoice() throws {
    try ready()
    var board = try ProtocolTests.fixture()
    board.revision = 2
    board.board?[8] = "P"
    session.receive(board)
    session.submit(from: 8, to: 0)
    XCTAssertNil(session.pending)
    session.submit(from: 8, to: 0, promotion: "n")
    XCTAssertEqual(session.pending?.promotion, "n")
  }
  func testObsoleteConnectionCallbackCannotMutateState() throws {
    try ready()
    let oldCallback = socket.onMessage
    session.reconnect()
    var auth = Message(type: "authenticated")
    auth.role = "tv"
    auth.pairingId = "pair"
    oldCallback?(auth)
    XCTAssertFalse(session.authenticated)
  }
}
