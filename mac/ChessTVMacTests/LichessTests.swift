import AppKit
import Foundation
import WebKit
import XCTest
@testable import ChessTV

private final class LichessFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var streams: [LichessFixtureProtocol] = []
  nonisolated(unsafe) static var posts = 0
  nonisolated(unsafe) static var failPost = false
  nonisolated(unsafe) static var postStatus = 200
  static func reset() { lock.lock(); defer { lock.unlock() }; streams = []; posts = 0; failPost = false; postStatus = 200 }
  static func state(_ moves: String) -> [String: Any] {
    ["type": "gameState", "moves": moves, "status": "started", "wtime": 600000, "btime": 600000]
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lichess.org" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  func send(_ object: [String: Any], line: Bool = false) {
    var data = try! JSONSerialization.data(withJSONObject: object)
    if line { data.append(10) }
    client?.urlProtocol(self, didLoad: data)
  }
  override func startLoading() {
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
      client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
    }
    let path = request.url!.path
    Self.lock.lock()
    if path.contains("/move/") { Self.posts += 1 }
    let fail = Self.failPost
    let status = path.contains("/move/") ? Self.postStatus : 200
    Self.lock.unlock()
    if path.contains("/move/"), fail {
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": path.contains("/stream/") ? "application/x-ndjson" : "application/json"])!, cacheStoragePolicy: .notAllowed)
    if status != 200 {
      send(["error": "Rate limited"]); client?.urlProtocolDidFinishLoading(self); return
    }
    if path == "/api/account/playing" {
      send(["nowPlaying": [["gameId": "Ab12Cd34", "speed": "rapid", "source": "ai"]]])
      client?.urlProtocolDidFinishLoading(self)
    } else if path.contains("/stream/") {
      Self.lock.lock(); Self.streams.append(self); Self.lock.unlock()
      send(["type": "gameFull", "id": "Ab12Cd34", "variant": ["key": "standard"], "speed": "rapid", "initialFen": "startpos",
        "white": ["id": "human", "name": "Human"], "black": ["aiLevel": 1], "state": Self.state("")], line: true)
    } else if path.contains("/move/") {
      Self.lock.lock(); let streams = Self.streams; Self.lock.unlock()
      for stream in streams { stream.send(Self.state("e2e4 e7e5"), line: true) }
      send(["ok": true]); client?.urlProtocolDidFinishLoading(self)
    } else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
  }
  override func stopLoading() {
    Self.lock.lock(); Self.streams.removeAll { $0 === self }; Self.lock.unlock()
  }
}

@MainActor final class LichessTests: XCTestCase {
  private func connection() -> (LichessConnection, URLSession) {
    LichessFixtureProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LichessFixtureProtocol.self]
    let network = URLSession(configuration: config)
    return (LichessConnection(network: network,
      credential: LichessCredential(token: "fixture-token", id: "human", name: "Human"), loadSaved: false), network)
  }
  func testNativeTransportStreamsConfirmsAndDeduplicatesMoves() async throws {
    let (connection, network) = connection()
    defer { connection.stop(); network.invalidateAndCancel() }
    let state = try await connection.handle(["kind": "lichess-state", "gameId": "Ab12Cd34"])
    XCTAssertEqual(state["connected"] as? Bool, true)
    XCTAssertEqual(state["accountId"] as? String, "human")
    let command: [String: Any] = ["kind": "lichess-move", "gameId": "Ab12Cd34", "uci": "e2e4", "before": "", "commandId": "native-move"]
    let result = try await connection.handle(command)
    XCTAssertEqual(result["outcome"] as? String, "observed-complete")
    let again = try await connection.handle(command)
    XCTAssertEqual(again["outcome"] as? String, "observed-complete")
    XCTAssertEqual(LichessFixtureProtocol.posts, 1)
  }
  func testNativeTransportRejectsStaleAndPreservesLostResponse() async throws {
    let (connection, network) = connection()
    defer { connection.stop(); network.invalidateAndCancel() }
    _ = try await connection.handle(["kind": "lichess-state", "gameId": "Ab12Cd34"])
    let stale = try await connection.handle(["kind": "lichess-move", "gameId": "Ab12Cd34", "uci": "e2e4", "before": "d2d4", "commandId": "stale"])
    XCTAssertEqual(stale["outcome"] as? String, "rejected")
    XCTAssertEqual(LichessFixtureProtocol.posts, 0)
    LichessFixtureProtocol.failPost = true
    let command: [String: Any] = ["kind": "lichess-move", "gameId": "Ab12Cd34", "uci": "e2e4", "before": "", "commandId": "lost"]
    let lost = try await connection.handle(command)
    XCTAssertEqual(lost["outcome"] as? String, "uncertain")
    _ = try await connection.handle(command)
    XCTAssertEqual(LichessFixtureProtocol.posts, 1)
  }
  func testNativeTransportRejectsMovesDuringRateLimitCooldown() async throws {
    let (connection, network) = connection()
    defer { connection.stop(); network.invalidateAndCancel() }
    _ = try await connection.handle(["kind": "lichess-state", "gameId": "Ab12Cd34"])
    LichessFixtureProtocol.postStatus = 429
    var command: [String: Any] = ["kind": "lichess-move", "gameId": "Ab12Cd34", "uci": "e2e4", "before": "", "commandId": "rate-limited"]
    let limited = try await connection.handle(command)
    XCTAssertEqual(limited["outcome"] as? String, "rejected")
    LichessFixtureProtocol.postStatus = 200
    command["commandId"] = "cooldown"
    let cooldown = try await connection.handle(command)
    XCTAssertEqual(cooldown["outcome"] as? String, "rejected")
    XCTAssertTrue((cooldown["message"] as? String)?.contains("rate limit") == true)
    XCTAssertEqual(LichessFixtureProtocol.posts, 1)
    let state = try await connection.handle(["kind": "lichess-state", "gameId": "Ab12Cd34"])
    XCTAssertEqual(state["connected"] as? Bool, true)
  }
  func testURLAndTimeControlRestrictions() {
    XCTAssertEqual(LichessConnection.gameID(in: URL(string: "https://lichess.org/Ab12Cd34wxyz")), "Ab12Cd34")
    XCTAssertEqual(LichessConnection.gameID(in: URL(string: "https://lichess.org/game/Ab12Cd34")), "Ab12Cd34")
    for url in ["http://lichess.org/Ab12Cd34", "https://lichess.org.evil.test/Ab12Cd34", "https://lichess.org/training"] {
      XCTAssertNil(LichessConnection.gameID(in: URL(string: url)))
    }
    XCTAssertTrue(LichessConnection.boardCompatible(speed: "rapid", source: "pool"))
    XCTAssertTrue(LichessConnection.boardCompatible(speed: "blitz", source: "friend"))
    XCTAssertFalse(LichessConnection.boardCompatible(speed: "blitz", source: "pool"))
    XCTAssertFalse(LichessConnection.boardCompatible(speed: "bullet", source: "ai"))
  }
  func testRealWebKitLichessBridgeAndStandaloneVoiceWhileHidden() async throws {
    let (connection, network) = connection()
    defer { connection.stop(); network.invalidateAndCancel() }
    let browser = ChessBrowser(lichess: connection)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 800),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.contentView = browser.webView
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    browser.webView.loadHTMLString("<p>Lichess API fixture — no DOM board required</p>", baseURL: URL(string: "https://lichess.org/Ab12Cd34"))
    for _ in 0..<100 {
      if !browser.loading { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let isolated = try await browser.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.lichess") as? String
    XCTAssertEqual(isolated, "undefined")
    window.orderOut(nil)
    let reply = try await browser.call(["kind": "voice-position"])
    XCTAssertNil(reply.error)
    let position = try XCTUnwrap(reply.voicePosition)
    XCTAssertEqual(reply.voiceCandidates?.count, 20)
    let result = try await browser.call(["kind": "voice-move", "text": "Pawn e4", "position": position, "commandId": UUID().uuidString])
    XCTAssertTrue(result.messages.contains { if case .outcome(let outcome) = $0 { return outcome.outcome == .observedComplete }; return false })
    XCTAssertEqual(LichessFixtureProtocol.posts, 1)
    let synced = try await browser.call(["kind": "sync", "generation": "native-test", "enabled": true])
    let snapshot = try XCTUnwrap(synced.messages.compactMap { if case .snapshot(let s) = $0 { return s }; return nil }.first)
    XCTAssertEqual(snapshot.turn, .white)
    XCTAssertEqual(snapshot.players.white, "Human")
  }
}
