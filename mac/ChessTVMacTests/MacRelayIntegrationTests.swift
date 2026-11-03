import XCTest
@testable import ChessTV

@MainActor final class MacRelayIntegrationTests: XCTestCase {
  func testNativePairingStreamingMoveReconnectAndRevocationThroughRealRelay() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("relay.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bun", "relay/src/index.ts"]
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:\(NSHomeDirectory())/.bun/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["NODE_ENV"] = "test"
    environment["PORT"] = "0"
    environment["DATABASE_PATH"] = directory.appendingPathComponent("relay.db").path
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    var port: Int?
    for _ in 0..<100 {
      let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      for line in text.split(separator: "\n") {
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let value = object["port"] as? Int { port = value }
      }
      if port != nil || !process.isRunning { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let configuration = try RelayConfiguration("http://127.0.0.1:\(XCTUnwrap(port))", allowLoopback: true)
    let api = PairingAPI(configuration: configuration)
    let challenge = try await api.create()
    let page = FakePage()
    let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot", withExtension: "json"))
    guard case .snapshot(let fixture) = try Message.decode(Data(contentsOf: fixtureURL)) else {
      return XCTFail("Missing snapshot fixture")
    }
    page.action = { action in
      var messages: [Message] = []
      if action["kind"] as? String == "sync", let generation = action["generation"] as? String {
        var snapshot = fixture
        snapshot.context = GameContext(gameId: "game", generation: generation)
        messages = [.snapshot(snapshot), .status(GameStatus(context: snapshot.context,
          available: action["enabled"] as? Bool == true))]
      }
      if action["kind"] as? String == "move", let object = action["move"],
        case .move(let move) = try Message.decode(JSONSerialization.data(withJSONObject: object)) {
        messages = [.outcome(CommandOutcome(context: move.context, commandId: move.commandId, outcome: .observedComplete))]
      }
      return AdapterReply(instance: "instance", gameId: "game", messages: messages, error: nil)
    }
    let store = MemoryStore()
    let session = try MacSession(page: page, socket: RelaySocket(),
      api: MacPairingAPI(api: api), store: store, configuration: configuration)
    defer { session.stop() }
    try await session.claim(challenge.code)
    try await api.decide(challenge, confirm: true)
    let tvStatus = try await api.status(challenge)
    let tvCredential = try XCTUnwrap(tvStatus.credential)
    let tvSocket = RelaySocket()
    defer { tvSocket.disconnect() }
    var received: [Message] = []
    tvSocket.onMessage = { received.append($0) }
    tvSocket.connect(url: configuration.socketURL, credential: tvCredential)
    session.start()
    for _ in 0..<100 {
      if session.available { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(session.available, session.error ?? session.status)
    let snapshot = try XCTUnwrap(received.compactMap { message -> Snapshot? in
      if case .snapshot(let value) = message { return value }; return nil
    }.last)
    let move = MoveRequest(context: snapshot.context, revision: snapshot.revision,
      commandId: "integration-move", from: "e1", to: "e2")
    try await tvSocket.send(.move(move))
    for _ in 0..<100 {
      if received.contains(where: { $0.kind == .outcome }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(received.contains(.outcome(CommandOutcome(context: move.context,
      commandId: move.commandId, outcome: .observedComplete))))
    XCTAssertFalse(store.state.interruptedMove)
    let oldGeneration = snapshot.generation
    session.reconnectRelay()
    for _ in 0..<100 {
      if received.contains(where: {
        if case .snapshot(let value) = $0 { return value.generation != oldGeneration }; return false
      }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(received.contains(where: {
      if case .snapshot(let value) = $0 { return value.generation != oldGeneration }; return false
    }))
    try await session.revoke()
    XCTAssertNil(store.state.device)
    XCTAssertFalse(session.authenticated)
  }
}
