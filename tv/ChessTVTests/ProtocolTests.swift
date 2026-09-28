import XCTest

@testable import ChessTV

final class ProtocolTests: XCTestCase {
  static func fixture() throws -> Message {
    let url = Bundle(for: ProtocolTests.self).url(forResource: "snapshot", withExtension: "json")!
    return try Message.decode(Data(contentsOf: url))
  }
  func testSharedSnapshotRoundTripPreservesNulls() throws {
    let snapshot = try Self.fixture()
    XCTAssertEqual(snapshot.board?.count, 64)
    XCTAssertNil(snapshot.clocks?.black.remainingMs)
    let data = try snapshot.encoded()
    XCTAssertEqual(try Message.decode(data), snapshot)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(object["result"] is NSNull)
  }
  func testRejectsMalformedAndIncompatibleMessages() throws {
    let valid = try Self.fixture().encoded()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    for (key, value) in [
      ("v", 2 as Any), ("v", true as Any), ("board", [] as Any), ("revision", -1 as Any),
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
  func testMoveEncodingAndAllPromotions() throws {
    for promotion in ["q", "r", "b", "n"] {
      var move = Message(type: "move")
      move.gameId = "game"
      move.generation = "generation"
      move.revision = 1
      move.commandId = "command"
      move.from = "a7"
      move.to = "a8"
      move.promotion = promotion
      XCTAssertEqual(try Message.decode(move.encoded()), move)
      var invalid = try XCTUnwrap(
        JSONSerialization.jsonObject(with: move.encoded()) as? [String: Any])
      invalid["promotion"] = NSNull()
      XCTAssertThrowsError(try Message.decode(JSONSerialization.data(withJSONObject: invalid)))
    }
    var request = Message(type: "snapshot-request")
    request.gameId = "game"
    request.generation = "generation"
    XCTAssertEqual(try Message.decode(request.encoded()), request)
  }
  func testCoordinatesAndOrientation() {
    for index in 0..<64 { XCTAssertEqual(Square.index(Square.name(index)), index) }
    XCTAssertEqual(Square.order(for: .white).first, Square.index("a8"))
    XCTAssertEqual(Square.order(for: .black).first, Square.index("h1"))
    XCTAssertNil(Square.index("a9"))
    XCTAssertNil(Square.index("z1"))
    XCTAssertTrue(Square.promotion(piece: "P", destination: 0))
    XCTAssertTrue(Square.promotion(piece: "p", destination: 63))
    XCTAssertFalse(Square.promotion(piece: "R", destination: 0))
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
