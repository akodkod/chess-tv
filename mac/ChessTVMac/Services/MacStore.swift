import Foundation
import Security

struct PairingClaim: Codable {
  let challengeId: String
  let token: String
  let expiresAt: Double
}

struct MacSavedState: Codable {
  var device: DeviceCredential?
  var claim: PairingClaim?
  var revocationPending = false
  var autoConnect = true
  var interruptedMove = false
}

@MainActor protocol MacStateStoring {
  func load() throws -> MacSavedState
  func save(_ state: MacSavedState) throws
}

struct MacStore: MacStateStoring {
  let origin: String
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "ChessTV.Mac.Session", kSecAttrAccount as String: origin]
  }
  func load() throws -> MacSavedState {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let code = SecItemCopyMatching(query as CFDictionary, &result)
    if code == errSecItemNotFound { return MacSavedState() }
    try check(code)
    guard let data = result as? Data else { throw ProtocolFailure("Cannot read saved pairing.") }
    return try JSONDecoder().decode(MacSavedState.self, from: data)
  }
  func save(_ state: MacSavedState) throws {
    let data = try JSONEncoder().encode(state)
    let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if code == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      try check(SecItemAdd(item as CFDictionary, nil))
    } else { try check(code) }
  }
  private func check(_ code: OSStatus) throws {
    guard code == errSecSuccess else {
      throw ProtocolFailure("Could not save session in Keychain (\(code)).")
    }
  }
}
