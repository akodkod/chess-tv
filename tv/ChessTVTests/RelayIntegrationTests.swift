import XCTest

@testable import ChessTV

/// Opt in with CHESS_TV_INTEGRATION=1 in the scheme's test environment.
/// Requires the real relay listening on loopback port 33017.
@MainActor final class RelayIntegrationTests: XCTestCase {
  func testRealRelayPairingSnapshotMoveAndRevocation() async throws {
    guard ProcessInfo.processInfo.environment["CHESS_TV_INTEGRATION"] == "1" else {
      throw XCTSkip("Start the real relay and enable CHESS_TV_INTEGRATION=1")
    }
    let config = try RelayConfiguration("http://127.0.0.1:33017", allowLoopback: true)
    let api = PairingAPI(configuration: config)
    let challenge = try await api.create()
    struct Claim: Decodable {
      let challengeId: String
      let token: String
      let expiresAt: Double
    }
    let claim = try JSONDecoder().decode(
      Claim.self,
      from: await api.request(
        "v1/pairing/claim", method: "POST", body: JSONEncoder().encode(["code": challenge.code])))
    try await api.decide(challenge, confirm: true)
    let tv = try await api.status(challenge)
    let ext = try await api.status(
      .init(
        challengeId: claim.challengeId, code: "", token: claim.token, expiresAt: claim.expiresAt))
    var extensionSocket = URLSession.shared.webSocketTask(with: config.socketURL)
    extensionSocket.resume()
    defer { extensionSocket.cancel(with: .goingAway, reason: nil) }
    func send(_ message: Message) async throws {
      try await extensionSocket.send(.string(String(decoding: message.encoded(), as: UTF8.self)))
    }
    func next(_ type: String) async throws -> Message {
      for _ in 0..<30 {
        let frame = try await extensionSocket.receive()
        guard case .string(let text) = frame else { continue }
        let message = try Message.decode(Data(text.utf8))
        if message.type == "ping" {
          var pong = Message(type: "pong")
          pong.nonce = message.nonce
          try await send(pong)
        }
        if message.type == type { return message }
      }
      throw ProtocolFailure("Expected \(type)")
    }
    var auth = Message(type: "authenticate")
    auth.credential = ext.credential
    try await send(auth)
    _ = try await next("authenticated")
    _ = try await next("session")
    let store = MemoryCredentials()
    store.value = .init(pairingId: tv.pairingId!, credential: tv.credential!)
    let session = TVSession(configuration: config, store: store)
    session.setActive(true)
    defer { session.setActive(false) }
    let connected = try await next("session")
    var attachment = Message(type: "attachment")
    attachment.generation = connected.generation
    attachment.gameId = "game-1"
    try await send(attachment)
    let attached = try await next("session")
    var snapshot = try ProtocolTests.fixture()
    snapshot.generation = attached.generation
    var status = Message(type: "status")
    status.generation = attached.generation
    status.gameId = "game-1"
    status.available = true
    try await send(snapshot)
    try await send(status)
    for _ in 0..<100 {
      if session.canMove { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(session.canMove)
    session.submit(from: 60, to: 52)
    let move = try await next("move")
    XCTAssertEqual(move.from, "e1")
    XCTAssertEqual(move.to, "e2")
    var outcome = Message(type: "outcome")
    outcome.gameId = move.gameId
    outcome.generation = move.generation
    outcome.commandId = move.commandId
    outcome.outcome = "observed-complete"
    try await send(outcome)
    snapshot.revision = 2
    snapshot.board?[60] = nil
    snapshot.board?[52] = "K"
    try await send(snapshot)
    try await send(status)
    for _ in 0..<100 {
      if session.pending == nil && session.snapshot?.revision == 2 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(session.pending)
    XCTAssertEqual(session.snapshot?.board?[52], "K")
    for interruption in ["tv", "extension", "both"] {
      let previous = session.generation
      if interruption != "extension" {
        // Model a transport failure reported by RelaySocket; the session must retry itself.
        session.closed(code: 1006, reason: "Test connection interruption")
      }
      if interruption != "tv" {
        extensionSocket.cancel(with: .goingAway, reason: nil)
        for _ in 0..<100 {
          if !session.peerConnected { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        extensionSocket = URLSession.shared.webSocketTask(with: config.socketURL)
        extensionSocket.resume()
        try await send(auth)
        _ = try await next("authenticated")
      }
      var recovered = try await next("session")
      while recovered.peerConnected != true { recovered = try await next("session") }
      if recovered.gameId == nil {
        attachment.generation = recovered.generation
        try await send(attachment)
        recovered = try await next("session")
      }
      snapshot.generation = recovered.generation
      status.generation = recovered.generation
      try await send(snapshot)
      try await send(status)
      for _ in 0..<100 {
        if session.canMove && session.generation != previous { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertTrue(session.canMove, "Failed to recover after \(interruption) disconnected")
      XCTAssertNotEqual(session.generation, previous)
      XCTAssertEqual(session.snapshot?.board?[52], "K")
    }
    session.unpair()
    for _ in 0..<100 {
      if !session.busy { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(session.credential)
    XCTAssertNil(store.value)
  }
}
