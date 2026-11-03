import Foundation

@MainActor protocol MacPairingServing {
  func claim(_ code: String) async throws -> PairingClaim
  func poll(_ claim: PairingClaim) async throws -> PairingStatus
  func revoke(_ credential: String) async throws
}

@MainActor struct MacPairingAPI: MacPairingServing {
  let api: PairingAPI
  func claim(_ code: String) async throws -> PairingClaim {
    guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
      throw ProtocolFailure("Enter the six-digit code displayed on your TV.")
    }
    let data = try await api.request("v1/pairing/claim", method: "POST",
      body: JSONEncoder().encode(["code": code]))
    let claim = try JSONDecoder().decode(PairingClaim.self, from: data)
    guard UUID(uuidString: claim.challengeId) != nil,
      claim.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      claim.expiresAt.isFinite, claim.expiresAt > Date().timeIntervalSince1970 * 1000 else {
      throw ProtocolFailure("Invalid pairing response.")
    }
    return claim
  }
  func poll(_ claim: PairingClaim) async throws -> PairingStatus {
    let data = try await api.request("v1/pairing/\(claim.challengeId)", token: claim.token)
    let result = try JSONDecoder().decode(PairingStatus.self, from: data)
    guard ["waiting", "claimed", "confirmed", "rejected"].contains(result.state),
      result.expiresAt.isFinite else { throw ProtocolFailure("Invalid pairing response.") }
    if result.state == "confirmed" {
      guard let credential = result.credential,
        credential.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        let id = result.pairingId, !id.isEmpty else {
        throw ProtocolFailure("Invalid pairing credential.")
      }
    }
    return result
  }
  func revoke(_ credential: String) async throws { try await api.revoke(credential) }
}
