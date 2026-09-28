import Foundation

struct RelayConfiguration {
  let origin: URL
  init(_ raw: String, allowLoopback: Bool = false) throws {
    guard let parts = URLComponents(string: raw), let host = parts.host,
      !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/",
      parts.scheme == "https"
        || (allowLoopback && parts.scheme == "http"
          && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
      let url = parts.url
    else {
      throw ProtocolFailure(
        "Configure RELAY_ORIGIN with an HTTPS origin in tv/Config. Debug simulator builds also accept loopback HTTP."
      )
    }
    origin = url
  }
  static func bundled() throws -> Self {
    #if DEBUG && targetEnvironment(simulator)
      let allowLoopback = true
    #else
      let allowLoopback = false
    #endif
    return try Self(
      Bundle.main.object(forInfoDictionaryKey: "RelayOrigin") as? String ?? "",
      allowLoopback: allowLoopback)
  }
  func endpoint(_ path: String) -> URL { origin.appendingPathComponent(path) }
  var socketURL: URL {
    var parts = URLComponents(url: endpoint("v1/ws"), resolvingAgainstBaseURL: false)!
    parts.scheme = origin.scheme == "https" ? "wss" : "ws"
    return parts.url!
  }
}
