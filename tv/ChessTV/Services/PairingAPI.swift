import Foundation

struct Challenge: Decodable {
  let challengeId: String
  let code: String
  let token: String
  let expiresAt: Double
}
struct PairingStatus: Decodable {
  let state: String
  let expiresAt: Double
  let pairingId: String?
  let credential: String?
}
struct HTTPFailure: LocalizedError {
  let status: Int
  var errorDescription: String? {
    switch status {
    case 401, 404: "Pairing expired or is no longer valid. Request a new code."
    case 409: "Pairing is busy. Wait for its current status before trying again."
    case 429: "Too many pairing attempts. Wait a minute and try again."
    default: "Relay request failed (HTTP \(status)). Check the relay and try again."
    }
  }
}
struct PairingAPI {
  let configuration: RelayConfiguration
  var session = URLSession.shared
  func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil)
    async throws -> Data
  {
    var request = URLRequest(url: configuration.endpoint(path))
    request.httpMethod = method
    request.timeoutInterval = 8
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ProtocolFailure("Invalid relay response.")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPFailure(status: response.statusCode)
    }
    guard data.count <= 65_536 else { throw ProtocolFailure("Relay response is too large.") }
    return data
  }
  func create() async throws -> Challenge {
    let value = try JSONDecoder().decode(
      Challenge.self, from: await request("v1/pairing", method: "POST"))
    guard value.code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil,
      UUID(uuidString: value.challengeId) != nil,
      value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      value.expiresAt.isFinite, value.expiresAt > Date().timeIntervalSince1970 * 1000
    else {
      throw ProtocolFailure("Invalid pairing challenge from relay.")
    }
    return value
  }
  func status(_ challenge: Challenge) async throws -> PairingStatus {
    let value = try JSONDecoder().decode(
      PairingStatus.self,
      from: await request("v1/pairing/\(challenge.challengeId)", token: challenge.token))
    guard ["waiting", "claimed", "confirmed", "rejected"].contains(value.state),
      value.expiresAt.isFinite
    else {
      throw ProtocolFailure("Invalid pairing status from relay.")
    }
    return value
  }
  func decide(_ challenge: Challenge, confirm: Bool) async throws {
    _ = try await request(
      "v1/pairing/\(challenge.challengeId)/decision", method: "POST", token: challenge.token,
      body: JSONEncoder().encode(["confirm": confirm]))
  }
  func revoke(_ credential: String) async throws {
    do { _ = try await request("v1/pairing", method: "DELETE", token: credential) } catch let error
      as HTTPFailure where error.status == 401
    { /* Already revoked. */  }
  }
}
