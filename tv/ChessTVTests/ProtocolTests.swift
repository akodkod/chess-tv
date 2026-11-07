import XCTest

@testable import ChessTV

final class ProtocolTests: XCTestCase {
  func testSharedMessageCorpus() throws {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "messages", withExtension: "json"))
    let cases = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    var kinds = Set<Message.Kind>()
    for entry in cases {
      let name = try XCTUnwrap(entry["name"] as? String)
      let object = try XCTUnwrap(entry["message"] as? [String: Any])
      let data = try JSONSerialization.data(withJSONObject: object)
      if entry["valid"] as? Bool == true {
        let value = try Message.decode(data)
        kinds.insert(value.kind)
        let encoded = try value.encoded()
        XCTAssertEqual(try Message.decode(encoded), value, name)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(roundTrip, object as NSDictionary, name)
      } else {
        XCTAssertThrowsError(try Message.decode(data), name)
      }
    }
    XCTAssertEqual(kinds, Set(Message.Kind.allCases))
  }

  func testSpectatorOrientationAndDisplayText() throws {
    var snapshot = try Self.fixture()
    snapshot.playerColor = nil
    for color in [PieceColor.white, .black] {
      snapshot.bottomColor = color
      guard case .snapshot(let decoded) = try Message.decode(Message.snapshot(snapshot).encoded())
      else { return XCTFail("Expected snapshot") }
      XCTAssertEqual(decoded.boardOrientation, color)
      XCTAssertNil(decoded.playerColor)
      XCTAssertEqual(Square.order(for: decoded.boardOrientation).first, color == .black ? 63 : 0)
    }
    XCTAssertEqual("Viewing game.".displayText, "Viewing game")
    XCTAssertEqual("Open Chess.com to watch.".displayText, "Open Chess.com to watch")
    XCTAssertEqual("Game changed. Connect again.".displayText, "Game changed. Connect again.")
  }
  static func fixture() throws -> Snapshot {
    let url = Bundle(for: ProtocolTests.self).url(forResource: "snapshot", withExtension: "json")!
    guard case .snapshot(let value) = try Message.decode(Data(contentsOf: url)) else {
      throw ProtocolFailure("Expected snapshot fixture")
    }
    return value
  }
  func testSharedSnapshotRoundTripPreservesNulls() throws {
    let snapshot = try Self.fixture()
    XCTAssertEqual(snapshot.board.count, 64)
    XCTAssertNil(snapshot.clocks.black.remainingMs)
    let data = try Message.snapshot(snapshot).encoded()
    XCTAssertEqual(try Message.decode(data), Message.snapshot(snapshot))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(object["result"] is NSNull)
  }
  func testOptionalAvatarRoundTripAndURLValidation() throws {
    var snapshot = try Self.fixture()
    snapshot.players.whiteAvatar = "https://images.chesscomfiles.com/avatar.png"
    XCTAssertEqual(
      try Message.decode(Message.snapshot(snapshot).encoded()), Message.snapshot(snapshot))
    for value in [
      "http://example.com/avatar.png", "file:///avatar.png",
      "https://user:password@example.com/a.png",
    ] {
      snapshot.players.whiteAvatar = value
      XCTAssertThrowsError(try Message.snapshot(snapshot).encoded())
    }
  }
  func testResultReasonsAndPlayerPerspective() throws {
    var snapshot = try Self.fixture()
    snapshot.result = .whiteWon
    for reason in GameResultReason.allCases {
      snapshot.resultReason = reason
      XCTAssertEqual(
        try Message.decode(Message.snapshot(snapshot).encoded()), Message.snapshot(snapshot))
    }
    XCTAssertEqual(GameResult.whiteWon.title(for: .white), "You won")
    XCTAssertEqual(GameResult.blackWon.title(for: .black), "You won")
    XCTAssertEqual(GameResult.whiteWon.title(for: .black), "You lost")
    XCTAssertEqual(GameResult.blackWon.title(for: .white), "You lost")
    XCTAssertEqual(GameResult.whiteWon.detail(reason: .checkmate, player: .white), "by checkmate 🎉")
    XCTAssertEqual(GameResult.whiteWon.detail(reason: .checkmate, player: .black), "by checkmate 😔")
    XCTAssertEqual(GameResult.draw.title(for: .black), "Draw")
    XCTAssertEqual(GameResult.draw.detail(reason: .stalemate, player: .black), "by stalemate 🤝")
    XCTAssertEqual(GameResult.blackWon.detail(reason: .timeout, player: .black), "by timeout 🎉")
    XCTAssertEqual(GameResult.whiteWon.title(for: nil), "White wins")
  }

  func testRejectsMalformedAndIncompatibleMessages() throws {
    let valid = try Message.snapshot(Self.fixture()).encoded()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    for (key, value) in [
      ("v", 1 as Any), ("v", true as Any), ("board", [] as Any), ("revision", -1 as Any),
      ("revision", 1.5 as Any), ("extra", true as Any), ("gameId", NSNull()),
    ] {
      var bad = object
      bad[key] = value
      XCTAssertThrowsError(
        try Message.decode(JSONSerialization.data(withJSONObject: bad)), "\(key)")
    }
    var missing = object
    missing.removeValue(forKey: "result")
    XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: missing)))
    var badClock = object
    badClock["clocks"] = [
      "white": ["remainingMs": -1, "running": true], "black": ["remainingMs": 1, "running": false],
      "observedAt": 1,
    ]
    XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: badClock)))
    XCTAssertThrowsError(try Message.decode(Data(repeating: 32, count: 65_537)))
  }
  func testRequiredMoveAndCheckMetadata() throws {
    let valid = try Message.snapshot(Self.fixture()).encoded()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    for key in ["legalMoves", "checkSquare"] {
      var missing = object
      missing.removeValue(forKey: key)
      XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: missing)))
    }
    for (key, value) in [
      ("checkSquare", "z9" as Any), ("legalMoves", NSNull()),
      ("legalMoves", [["from": "a9", "to": "a1"]]),
      ("legalMoves", [["from": "a1", "to": "a2", "promotion": "q"]]),
    ] {
      var bad = object
      bad[key] = value
      XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: bad)))
    }
    var checked = try Self.fixture()
    checked.checkSquare = "e1"
    XCTAssertEqual(
      try Message.decode(Message.snapshot(checked).encoded()), Message.snapshot(checked))
  }
  func testMoveEncodingAndAllPromotions() throws {
    for promotion in Promotion.allCases {
      let move = MoveRequest(
        context: GameContext(gameId: "game", generation: "generation"), revision: 1,
        commandId: "command", from: "a7", to: "a8", promotion: promotion)
      XCTAssertEqual(try Message.decode(Message.move(move).encoded()), Message.move(move))
      var invalid = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Message.move(move).encoded()) as? [String: Any])
      invalid["promotion"] = NSNull()
      XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: invalid)))
    }
    let request = SnapshotRequest(context: GameContext(gameId: "game", generation: "generation"))
    XCTAssertEqual(
      try Message.decode(Message.snapshotRequest(request).encoded()),
      Message.snapshotRequest(request))
  }
  func testCoordinatesAndOrientation() {
    for index in 0..<64 { XCTAssertEqual(Square.index(Square.name(index)), index) }
    XCTAssertEqual(Square.order(for: .white).first, Square.index("a8"))
    XCTAssertEqual(Square.order(for: .black).first, Square.index("h1"))
    for color in [PieceColor.white, .black] {
      let order = Square.order(for: color)
      for (displayed, square) in order.enumerated() {
        XCTAssertEqual(Square.displayIndex(square, for: color), displayed)
      }
      let bottomRank = color == .black ? "8" : "1"
      XCTAssertTrue(order.suffix(8).allSatisfy { Square.name($0).hasSuffix(bottomRank) })
    }
    XCTAssertNil(Square.index("a9"))
    XCTAssertNil(Square.index("z1"))
    XCTAssertTrue(Square.promotion(piece: .whitePawn, destination: 0))
    XCTAssertTrue(Square.promotion(piece: .blackPawn, destination: 63))
    XCTAssertFalse(Square.promotion(piece: .whiteRook, destination: 0))
  }
  func testMonotonicClocksFreezeAndRemainUnknown() {
    var reading = ClockReading(
      clocks: .init(
        white: .init(remainingMs: 10_000, running: true),
        black: .init(remainingMs: nil, running: nil), observedAt: 1), receivedAt: 100)
    XCTAssertEqual(reading.remaining(.white, now: 102), 8_000)
    XCTAssertNil(reading.remaining(.black, now: 102))
    reading.frozenAt = 103
    XCTAssertEqual(reading.remaining(.white, now: 500), 7_000)
    XCTAssertEqual(ClockReading.format(nil), "—:—")
    XCTAssertEqual(ClockReading.format(1e100), "99h+")
    XCTAssertEqual(ClockReading.format(1), "0:01")
    reading.frozenAt = nil
    XCTAssertEqual(reading.remaining(.white, now: 500), 0)
  }
  func testClockDisplayHidesUnlimitedAndLongDeadlines() {
    for remaining in [nil, 6 * 60 * 60 * 1000, 1e100] as [Double?] {
      let reading = ClockReading(clocks: .init(
        white: .init(remainingMs: remaining, running: false),
        black: .init(remainingMs: 30 * 60 * 1000, running: true)), receivedAt: 100)
      XCTAssertNil(reading.displayedRemaining(.white, now: 101))
      XCTAssertEqual(reading.displayedRemaining(.black, now: 101), 1_799_000)
    }
    let reading = ClockReading(clocks: .init(
      white: .init(remainingMs: 6 * 60 * 60 * 1000 - 1, running: false),
      black: .init(remainingMs: 0, running: false)), receivedAt: 100)
    XCTAssertNotNil(reading.displayedRemaining(.white, now: 100))
    XCTAssertEqual(reading.displayedRemaining(.black, now: 100), 0)
  }
  func testConfigurationLimitsHTTPToOptInLoopback() throws {
    XCTAssertNoThrow(try RelayConfiguration("http://127.0.0.1:3000", allowLoopback: true))
    for origin in [
      "http://127.0.0.1:3000", "http://relay.example.com", "https://user:secret@example.com",
      "https://example.com/path", "https://example.com?secret=x", "",
    ] {
      XCTAssertThrowsError(try RelayConfiguration(origin))
    }
    XCTAssertThrowsError(try RelayConfiguration("http://192.168.1.1:3000", allowLoopback: true))
    XCTAssertEqual(
      try RelayConfiguration("https://example.com").socketURL.absoluteString,
      "wss://example.com/v1/ws")
  }
}

@MainActor extension TVSession {
  func receive(_ payload: Snapshot) { receive(.snapshot(payload)) }
  func receive(_ payload: Authenticated) { receive(.authenticated(payload)) }
  func receive(_ payload: SessionState) { receive(.session(payload)) }
  func receive(_ payload: GameStatus) { receive(.status(payload)) }
  func receive(_ payload: CommandOutcome) { receive(.outcome(payload)) }
  func receive(_ payload: RelayError) { receive(.error(payload)) }
}
