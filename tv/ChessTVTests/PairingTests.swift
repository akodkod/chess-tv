import XCTest

@testable import ChessTV

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responder: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.responder!(request)
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
@MainActor final class PairingTests: XCTestCase {
  func testRealKeychainRoundTrip() throws {
    let store = CredentialStore(origin: "https://test-\(UUID().uuidString).invalid")
    defer { try? store.remove() }
    XCTAssertNil(try store.load())
    let value = DeviceCredential(pairingId: "test", credential: String(repeating: "c", count: 64))
    try store.save(value)
    XCTAssertEqual(try store.load(), value)
    try store.remove()
    XCTAssertNil(try store.load())
  }
  func api() throws -> PairingAPI {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return PairingAPI(
      configuration: try RelayConfiguration("https://example.com"),
      session: URLSession(configuration: config))
  }
  func waitFor(_ predicate: @escaping () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for pairing operation")
  }
  func testKeychainFailurePreventsConnection() throws {
    let store = MemoryCredentials()
    store.value = nil
    store.failSave = true
    let socket = FakeSocket()
    let session = TVSession(
      configuration: try RelayConfiguration("https://example.com"), store: store, socket: socket)
    session.setActive(true)
    defer { session.setActive(false) }
    XCTAssertThrowsError(
      try session.acceptPairing(
        .init(
          state: "confirmed", expiresAt: 100, pairingId: "pair",
          credential: String(repeating: "a", count: 64))))
    XCTAssertNil(session.credential)
    XCTAssertEqual(socket.connects, 0)
  }
  func testRevocationFailureRetainsCredentialThenRetryRemovesIt() async throws {
    let store = MemoryCredentials()
    let session = TVSession(
      configuration: try RelayConfiguration("https://example.com"), store: store,
      socket: FakeSocket(), api: try api())
    session.setActive(true)
    defer { session.setActive(false) }
    StubURLProtocol.responder = { request in
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
      throw URLError(.notConnectedToInternet)
    }
    session.unpair()
    try await waitFor { !session.busy }
    XCTAssertNotNil(store.value)
    XCTAssertNotNil(session.credential)
    XCTAssertTrue(session.notice.contains("Unpair incomplete"))
    StubURLProtocol.responder = { _ in (401, Data()) }
    session.unpair()
    try await waitFor { !session.busy }
    XCTAssertNil(store.value)
    XCTAssertNil(session.credential)
  }
  func testExpiredChallengeAndDeclinedPairing() async throws {
    let api = try api()
    StubURLProtocol.responder = { _ in (404, Data("{\"error\":\"invalid_challenge\"}".utf8)) }
    do {
      _ = try await api.status(
        .init(challengeId: "id", code: "123456", token: "secret", expiresAt: 1))
      XCTFail("Expected expiry")
    } catch let failure as HTTPFailure { XCTAssertEqual(failure.status, 404) }
    let store = MemoryCredentials()
    store.value = nil
    let session = TVSession(configuration: api.configuration, store: store, socket: FakeSocket())
    session.setActive(true)
    defer { session.setActive(false) }
    try session.acceptPairing(
      .init(state: "rejected", expiresAt: 1, pairingId: nil, credential: nil))
    XCTAssertNil(session.credential)
    XCTAssertTrue(session.notice.contains("declined"))
  }
  func testClaimedCodeAutomaticallyPairs() async throws {
    try await automaticPairing(lostDecisionResponse: false)
  }
  func testLostAutomaticDecisionResponseRecoversByPolling() async throws {
    try await automaticPairing(lostDecisionResponse: true)
  }
  private func automaticPairing(lostDecisionResponse: Bool) async throws {
    let api = try api()
    let store = MemoryCredentials()
    store.value = nil
    let socket = FakeSocket()
    let session = TVSession(
      configuration: api.configuration, store: store, socket: socket, api: api)
    let id = UUID().uuidString
    let token = String(repeating: "b", count: 64)
    let credential = String(repeating: "c", count: 64)
    let expiry = Date().timeIntervalSince1970 * 1000 + 60_000
    var requests = 0
    // The session issues requests serially. Assert the protocol sequence, including
    // polling after a lost response instead of issuing a second decision blindly.
    StubURLProtocol.responder = { request in
      requests += 1
      let body: [String: Any]
      switch requests {
      case 1:
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/pairing")
        body = ["challengeId": id, "code": "123456", "token": token, "expiresAt": expiry]
      case 2, 3:
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/pairing/\(id)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        body = ["state": requests == 2 ? "waiting" : "claimed", "expiresAt": expiry]
      case 4:
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/pairing/\(id)/decision")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = stream.read(&bytes, maxLength: bytes.count)
        XCTAssertGreaterThan(count, 0)
        let decision = try JSONDecoder().decode([String: Bool].self, from: Data(bytes.prefix(max(0, count))))
        XCTAssertEqual(decision, ["confirm": true])
        if lostDecisionResponse { throw URLError(.networkConnectionLost) }
        body = ["state": "confirmed"]
      case 5:
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/pairing/\(id)")
        body = ["state": "confirmed", "expiresAt": expiry, "pairingId": "pair", "credential": credential]
      default:
        XCTFail("Unexpected extra pairing request")
        throw URLError(.badServerResponse)
      }
      return (200, try JSONSerialization.data(withJSONObject: body))
    }
    session.setActive(true)
    defer {
      session.setActive(false)
      StubURLProtocol.responder = nil
    }
    session.createCode()
    try await waitFor { session.credential != nil }
    XCTAssertEqual(requests, 5)
    XCTAssertEqual(store.value, DeviceCredential(pairingId: "pair", credential: credential))
    XCTAssertNil(session.challenge)
    XCTAssertEqual(socket.connects, 1)
  }
  func testDecisionUsesPrivateToken() async throws {
    StubURLProtocol.responder = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
      XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query)
      return (200, Data("{\"state\":\"confirmed\"}".utf8))
    }
    try await api().decide(
      .init(challengeId: "id", code: "123456", token: "private-token", expiresAt: 1), confirm: true)
  }
}
