import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

struct LichessCredential: Codable {
  let token: String
  let id: String
  let name: String
}

struct LichessKeychain {
  private let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "ChessTV.Mac.Lichess", kSecAttrAccount as String: "https://lichess.org"
  ]
  func load() throws -> LichessCredential? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let code = SecItemCopyMatching(request as CFDictionary, &result)
    if code == errSecItemNotFound { return nil }
    guard code == errSecSuccess, let data = result as? Data else {
      throw ProtocolFailure("Cannot read Lichess authorization from Keychain.")
    }
    return try JSONDecoder().decode(LichessCredential.self, from: data)
  }
  func save(_ credential: LichessCredential?) throws {
    guard let credential else {
      let code = SecItemDelete(query as CFDictionary)
      guard code == errSecSuccess || code == errSecItemNotFound else {
        throw ProtocolFailure("Cannot remove Lichess authorization from Keychain.")
      }
      return
    }
    let data = try JSONEncoder().encode(credential)
    let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if code == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw ProtocolFailure("Cannot save Lichess authorization in Keychain.")
      }
    } else if code != errSecSuccess { throw ProtocolFailure("Cannot save Lichess authorization in Keychain.") }
  }
}

// Authenticated networking stays in the native host. Only snapshots and outcomes cross WebKit.
@MainActor @Observable final class LichessConnection: NSObject, ASWebAuthenticationPresentationContextProviding {
  private(set) var accountName: String?
  private(set) var connecting = false
  var error: String?
  weak var window: NSWindow?
  private var credential: LichessCredential?
  private var authSession: ASWebAuthenticationSession?
  private let network: URLSession
  private let store = LichessKeychain()
  private var gameID: String?
  private var game: [String: Any]?
  private var connected = false
  private var compatible = false
  private var observedAt = 0.0
  private var streamTask: Task<Void, Never>?
  private var streamEpoch = UUID()
  private var retryAt = Date.distantPast
  private var rateLimitUntil = Date.distantPast
  private var outcomes: [String: (String, Task<[String: Any], Never>)] = [:]

  init(network: URLSession = .shared, credential: LichessCredential? = nil, loadSaved: Bool = true) {
    self.network = network
    self.credential = credential
    super.init()
    if loadSaved {
      do { self.credential = try store.load() }
      catch { self.error = error.localizedDescription }
    }
    accountName = self.credential?.name
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window ?? NSApp.keyWindow ?? ASPresentationAnchor()
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ProtocolFailure("Cannot start secure Lichess authorization.")
    }
    return base64URL(Data(bytes))
  }
  private static func form(_ values: [String: String]) -> String {
    var components = URLComponents()
    components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
  }

  func connect() async {
    guard !connecting else { return }
    connecting = true
    error = nil
    defer { connecting = false; authSession = nil }
    do {
      let verifier = try Self.random()
      let state = try Self.random()
      let redirect = "com.chesstv.mac://lichess"
      let client = "chess-tv-macos"
      let query = Self.form(["response_type": "code", "client_id": client,
        "redirect_uri": redirect, "scope": "board:play", "state": state,
        "code_challenge_method": "S256", "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))])
      let callback: URL = try await withCheckedThrowingContinuation { continuation in
        let session = ASWebAuthenticationSession(url: URL(string: "https://lichess.org/oauth?\(query)")!,
          callbackURLScheme: "com.chesstv.mac") { url, error in
          if let url { continuation.resume(returning: url) }
          else { continuation.resume(throwing: error ?? ProtocolFailure("Lichess authorization cancelled.")) }
        }
        session.presentationContextProvider = self
        authSession = session
        if !session.start() { continuation.resume(throwing: ProtocolFailure("Cannot open Lichess authorization.")) }
      }
      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard callback.scheme == "com.chesstv.mac", callback.host == "lichess",
        items.first(where: { $0.name == "state" })?.value == state,
        let code = items.first(where: { $0.name == "code" })?.value else {
        throw ProtocolFailure("Lichess authorization was not completed.")
      }
      var request = URLRequest(url: URL(string: "https://lichess.org/api/token")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(Self.form(["grant_type": "authorization_code", "code": code,
        "code_verifier": verifier, "redirect_uri": redirect, "client_id": client]).utf8)
      let (data, response) = try await network.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let token = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String else {
        throw ProtocolFailure("Cannot complete Lichess authorization. Try again.")
      }
      var accountRequest = URLRequest(url: URL(string: "https://lichess.org/api/account")!)
      accountRequest.timeoutInterval = 10
      accountRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (accountData, accountResponse) = try await network.data(for: accountRequest)
      guard (accountResponse as? HTTPURLResponse)?.statusCode == 200,
        let account = try JSONSerialization.jsonObject(with: accountData) as? [String: Any],
        let id = account["id"] as? String, let name = account["username"] as? String else {
        throw ProtocolFailure("Cannot read the authorized Lichess account.")
      }
      let next = LichessCredential(token: token, id: id, name: name)
      try store.save(next)
      stop()
      credential = next
      accountName = name
    } catch { self.error = "Lichess connection was not completed. \(error.localizedDescription)" }
  }

  func currentGameURL() async throws -> URL? {
    let (data, response) = try await network.data(for: request("/api/account/playing?nb=50"))
    try check(response)
    let games = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["nowPlaying"] as? [[String: Any]] ?? []
    guard let id = games.first?["gameId"] as? String,
      id.range(of: "^[a-zA-Z0-9]{8}$", options: .regularExpression) != nil else { return nil }
    return URL(string: "https://lichess.org/game/\(id)")
  }

  func disconnect() async {
    stop()
    do {
      if credential != nil {
        let (_, response) = try await network.data(for: request("/api/token", method: "DELETE"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 401 else {
          throw ProtocolFailure("Cannot revoke Lichess access. Retry Disconnect Lichess.")
        }
      }
      try store.save(nil)
      credential = nil
      accountName = nil
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func stop() {
    streamEpoch = UUID()
    streamTask?.cancel()
    streamTask = nil
    gameID = nil
    game = nil
    connected = false
  }

  static func gameID(in url: URL?) -> String? {
    guard let url, url.scheme == "https", url.host == "lichess.org", url.user == nil, url.password == nil else { return nil }
    let path = url.path.hasPrefix("/game/") ? String(url.path.dropFirst(5)) : url.path
    guard path.range(of: "^/[a-zA-Z0-9]{8}([a-zA-Z0-9]{4})?(/(white|black))?/?$", options: .regularExpression) != nil else { return nil }
    let id = String(path.dropFirst().prefix(8))
    return ["training", "analysis", "practice", "features", "password", "timeline", "streamer"].contains(id) ? nil : id
  }
  static func boardCompatible(speed: String, source: String) -> Bool {
    ["rapid", "classical", "correspondence"].contains(speed) ||
      (speed == "blitz" && ["friend", "ai", "api"].contains(source))
  }
  private func request(_ path: String, method: String = "GET") throws -> URLRequest {
    guard let credential else { throw ProtocolFailure("Choose Connect Lichess to authorize your account.") }
    guard Date() >= rateLimitUntil else { throw ProtocolFailure("Lichess rate limit. Waiting before reconnecting.") }
    var request = URLRequest(url: URL(string: "https://lichess.org\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
    return request
  }
  private func check(_ response: URLResponse) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 429 { rateLimitUntil = Date().addingTimeInterval(60) }
    guard status == 200 else {
      throw ProtocolFailure(status == 401 ? "Lichess authorization expired. Connect Lichess again." :
        "Cannot read this Lichess game. Check your account and connection.")
    }
  }

  private func start(_ id: String) {
    stop()
    gameID = id
    let epoch = streamEpoch
    retryAt = .distantFuture
    error = nil
    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        let (playingData, playingResponse) = try await network.data(for: request("/api/account/playing?nb=50"))
        try check(playingResponse)
        let playing = (try JSONSerialization.jsonObject(with: playingData) as? [String: Any])?["nowPlaying"] as? [[String: Any]] ?? []
        let current = playing.first { $0["gameId"] as? String == id }
        let canPlay = Self.boardCompatible(speed: current?["speed"] as? String ?? "", source: current?["source"] as? String ?? "")
        let (bytes, response) = try await network.bytes(for: request("/api/board/game/stream/\(id)"))
        try check(response)
        for try await line in bytes.lines {
          try Task.checkCancellation()
          guard epoch == streamEpoch else { return }
          if line.isEmpty { continue }
          guard line.utf8.count <= 262_144,
            let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw ProtocolFailure("Invalid Lichess stream.")
          }
          if event["type"] as? String == "gameFull" {
            guard event["id"] as? String == id else { throw ProtocolFailure("Lichess game mismatch.") }
            game = event
            compatible = canPlay
            connected = true
            observedAt = Date().timeIntervalSince1970 * 1000
          } else if event["type"] as? String == "gameState", game != nil {
            game?["state"] = event
            observedAt = Date().timeIntervalSince1970 * 1000
          }
        }
      } catch {
        if epoch == streamEpoch { self.error = "Lichess stream disconnected. \(error.localizedDescription)" }
      }
      guard epoch == streamEpoch else { return }
      let status = (game?["state"] as? [String: Any])?["status"] as? String ?? "started"
      if ["created", "started"].contains(status) { connected = false }
      retryAt = Date().addingTimeInterval(3)
    }
  }

  func handle(_ action: [String: Any]) async throws -> [String: Any] {
    guard let id = action["gameId"] as? String,
      id.range(of: "^[a-zA-Z0-9]{8}$", options: .regularExpression) != nil else { throw ProtocolFailure("Invalid Lichess game.") }
    if action["kind"] as? String == "lichess-state" {
      guard let credential else { throw ProtocolFailure("Choose Connect Lichess to authorize your account.") }
      if gameID != id || (!connected && Date() >= retryAt) { start(id) }
      let epoch = streamEpoch
      for _ in 0..<100 {
        if game != nil || retryAt != .distantFuture { break }
        try await Task.sleep(for: .milliseconds(100))
        guard epoch == streamEpoch else { throw ProtocolFailure("Lichess game changed.") }
      }
      guard let game, gameID == id else { throw ProtocolFailure(error ?? "Waiting for Lichess game state.") }
      return ["accountId": credential.id, "game": game, "connected": connected,
        "compatible": compatible, "observedAt": observedAt]
    }
    guard action["kind"] as? String == "lichess-move", let uci = action["uci"] as? String,
      uci.range(of: "^[a-h][1-8][a-h][1-8][qrbn]?$", options: .regularExpression) != nil,
      let before = action["before"] as? String, before.utf8.count <= 32768,
      let commandID = action["commandId"] as? String, !commandID.isEmpty, commandID.count <= 128 else {
      throw ProtocolFailure("Invalid Lichess command.")
    }
    let key = "\(credential?.id ?? "")/\(id)/\(commandID)"
    let fingerprint = "\(before)/\(uci)"
    if let cached = outcomes[key] {
      if cached.0 != fingerprint { return Self.outcome("rejected", "Command ID reused with different move data.") }
      return await cached.1.value
    }
    let task = Task { await self.move(id: id, uci: uci, before: before) }
    outcomes[key] = (fingerprint, task)
    return await task.value
  }
  private static func outcome(_ outcome: String, _ message: String) -> [String: Any] {
    ["outcome": outcome, "message": message]
  }
  private func move(id: String, uci: String, before: String) async -> [String: Any] {
    let state = game?["state"] as? [String: Any]
    let ply = before.split(separator: " ").count
    let player = game?[ply % 2 == 0 ? "white" : "black"] as? [String: Any]
    guard gameID == id, connected, compatible, state?["status"] as? String == "started",
      state?["moves"] as? String == before, player?["id"] as? String == credential?.id else {
      return Self.outcome("rejected", "Lichess position or connection changed. Choose your move again.")
    }
    guard Date() >= rateLimitUntil else {
      return Self.outcome("rejected", "Lichess rate limit. Wait before trying again.")
    }
    let epoch = streamEpoch
    do {
      let (_, response) = try await network.data(for: request("/api/board/game/\(id)/move/\(uci)", method: "POST"))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 429 { rateLimitUntil = Date().addingTimeInterval(60) }
      if (400..<500).contains(status) { return Self.outcome("rejected", "Lichess rejected the move. Check your account and time control.") }
      guard status == 200 else { throw ProtocolFailure("Move response lost.") }
      let prefix = before.split(separator: " ").map(String.init)
      for _ in 0..<100 {
        guard epoch == streamEpoch, gameID == id else { break }
        let moves = ((game?["state"] as? [String: Any])?["moves"] as? String ?? "").split(separator: " ").map(String.init)
        if moves.count > prefix.count, Array(moves.prefix(prefix.count)) == prefix,
          (moves[prefix.count] == uci || Self.normalizedUCI(moves[prefix.count]) == uci) {
          return Self.outcome("observed-complete", "Move confirmed by Lichess.")
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    } catch { /* No retry: a lost response may hide a successful submission. */ }
    return Self.outcome("uncertain", "Lichess move unconfirmed. Inspect the game and reconnect.")
  }
  static func normalizedUCI(_ value: String) -> String {
    ["e1h1": "e1g1", "e1a1": "e1c1", "e8h8": "e8g8", "e8a8": "e8c8"][value] ?? value
  }
}
