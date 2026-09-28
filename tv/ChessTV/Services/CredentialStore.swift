import Foundation
import Security

struct DeviceCredential: Codable, Equatable {
  let pairingId: String
  let credential: String
}
protocol CredentialStoring {
  func load() throws -> DeviceCredential?
  func save(_ value: DeviceCredential) throws
  func remove() throws
}
struct CredentialStore: CredentialStoring {
  let origin: String
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "ChessTV.Relay", kSecAttrAccount as String: origin,
    ]
  }
  func load() throws -> DeviceCredential? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = result as? Data else {
      throw ProtocolFailure("Could not read the saved pairing from Keychain.")
    }
    let value = try JSONDecoder().decode(DeviceCredential.self, from: data)
    guard value.credential.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      !value.pairingId.isEmpty
    else { throw ProtocolFailure("The saved pairing is invalid. Unpair and try again.") }
    return value
  }
  func save(_ value: DeviceCredential) throws {
    let data = try JSONEncoder().encode(value)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      try check(SecItemAdd(item as CFDictionary, nil))
    } else {
      try check(status)
    }
  }
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
  private func check(_ status: OSStatus) throws {
    if status != errSecSuccess {
      throw ProtocolFailure("Keychain operation failed (\(status)). Pairing has not been changed.")
    }
  }
}
