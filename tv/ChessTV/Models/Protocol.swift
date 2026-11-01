import CoreFoundation
import Foundation

struct ProtocolFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

enum PieceColor: String, Codable { case white, black }
enum GameResult: String, Codable {
  case whiteWon = "white-won"
  case blackWon = "black-won"
  case draw
  var label: String {
    switch self {
    case .whiteWon: "White wins"
    case .blackWon: "Black wins"
    case .draw: "Draw"
    }
  }
}
struct Players: Codable, Equatable {
  var white: String?
  var black: String?
  var whiteAvatar: String?
  var blackAvatar: String?
}
struct ObservedClock: Codable, Equatable {
  var remainingMs: Double?
  var running: Bool?
}
struct Clocks: Codable, Equatable {
  var white: ObservedClock
  var black: ObservedClock
  var observedAt: Double?
}

/// Protocol v1 uses required nullable fields. Validation runs before decoding, and
/// encoding reinstates explicit nulls for those fields (Swift normally omits them).
struct Message: Codable, Equatable {
  var v = 1
  var type: String
  var credential: String?
  var role: String?
  var pairingId: String?
  var nonce: String?
  var generation: String?
  var gameId: String?
  var peerConnected: Bool?
  var available: Bool?
  var reason: String?
  var revision: Int64?
  var board: [String?]?
  var players: Players?
  var playerColor: PieceColor?
  var turn: PieceColor?
  var clocks: Clocks?
  var result: GameResult?
  var commandId: String?
  var from: String?
  var to: String?
  var promotion: String?
  var outcome: String?
  var code: String?
  var message: String?

  static let fields: [String: Set<String>] = [
    "authenticate": ["credential"], "authenticated": ["role", "pairingId"],
    "ping": ["nonce"], "pong": ["nonce"],
    "attachment": ["generation", "gameId"],
    "session": ["generation", "gameId", "peerConnected"],
    "status": ["gameId", "generation", "available", "reason"],
    "snapshot": [
      "gameId", "generation", "revision", "board", "players", "playerColor", "turn", "clocks",
      "result",
    ],
    "move": ["gameId", "generation", "revision", "commandId", "from", "to"],
    "outcome": ["gameId", "generation", "commandId", "outcome", "reason"],
    "snapshot-request": ["gameId", "generation"], "error": ["code", "message"],
  ]

  static func decode(_ data: Data) throws -> Message {
    guard data.count <= 65_536 else { throw ProtocolFailure("Relay message exceeds 64 KiB.") }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProtocolFailure("Invalid relay message.")
    }
    guard let version = object["v"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1
    else {
      throw ProtocolFailure("Unsupported relay protocol. Update Chess TV and the relay together.")
    }
    guard let type = object["type"] as? String, let fields = fields[type] else {
      throw ProtocolFailure("Unknown relay message type. Update Chess TV.")
    }
    let required = fields.union(["v", "type"])
    let allowed = type == "move" ? required.union(["promotion"]) : required
    guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed) else {
      throw ProtocolFailure("Relay message fields do not match protocol v1.")
    }
    if type == "snapshot" {
      guard let players = object["players"] as? [String: Any],
        Set(["white", "black"]).isSubset(of: Set(players.keys)),
        Set(players.keys).isSubset(of: ["white", "black", "whiteAvatar", "blackAvatar"])
      else { throw ProtocolFailure("Invalid player fields.") }
      try exact(object["clocks"], keys: ["white", "black", "observedAt"])
      if let clocks = object["clocks"] as? [String: Any] {
        try exact(clocks["white"], keys: ["remainingMs", "running"])
        try exact(clocks["black"], keys: ["remainingMs", "running"])
      }
    }
    if type == "move", object.keys.contains("promotion"), !(object["promotion"] is String) {
      throw ProtocolFailure("Promotion must be omitted or name a piece.")
    }
    let value = try JSONDecoder().decode(Message.self, from: data)
    try value.validate()
    return value
  }

  func encoded() throws -> Data {
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    for field in Self.fields[type] ?? [] where object[field] == nil { object[field] = NSNull() }
    if type == "snapshot" {
      var playerObject: [String: Any] = [
        "white": players?.white as Any? ?? NSNull(), "black": players?.black as Any? ?? NSNull(),
      ]
      if let avatar = players?.whiteAvatar { playerObject["whiteAvatar"] = avatar }
      if let avatar = players?.blackAvatar { playerObject["blackAvatar"] = avatar }
      object["players"] = playerObject
      func clock(_ value: ObservedClock?) -> [String: Any] {
        [
          "remainingMs": value?.remainingMs as Any? ?? NSNull(),
          "running": value?.running as Any? ?? NSNull(),
        ]
      }
      object["clocks"] = [
        "white": clock(clocks?.white), "black": clock(clocks?.black),
        "observedAt": clocks?.observedAt as Any? ?? NSNull(),
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    _ = try Self.decode(data)
    return data
  }

  private static func exact(_ value: Any?, keys: Set<String>) throws {
    guard let value = value as? [String: Any], Set(value.keys) == keys else {
      throw ProtocolFailure("Invalid nested protocol fields.")
    }
  }
  private func validate() throws {
    func require(_ condition: Bool) throws {
      if !condition { throw ProtocolFailure("Invalid \(type) message.") }
    }
    func id(_ value: String?) -> Bool {
      value.map { !$0.isEmpty && $0.utf16.count <= 128 } ?? false
    }
    for key in Self.fields[type] ?? [] {
      switch key {
      case "generation": try require(id(generation))
      case "gameId":
        try require(id(gameId) || (gameId == nil && ["session", "attachment"].contains(type)))
      case "nonce": try require(id(nonce))
      case "pairingId": try require(id(pairingId))
      case "commandId": try require(id(commandId))
      case "code": try require(id(code))
      case "credential":
        try require(credential?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
      case "role": try require(["tv", "extension"].contains(role ?? ""))
      case "revision": try require(revision.map { $0 >= 0 && $0 <= 9_007_199_254_740_991 } ?? false)
      case "peerConnected": try require(peerConnected != nil)
      case "available": try require(available != nil)
      case "message": try require(message.map { $0.utf16.count <= 256 } ?? false)
      case "reason": try require(reason.map { $0.utf16.count <= 256 } ?? true)
      case "from", "to": try require(Square.index(key == "from" ? from ?? "" : to ?? "") != nil)
      case "outcome":
        try require(["rejected", "uncertain", "observed-complete"].contains(outcome ?? ""))
      default: break
      }
    }
    if promotion != nil { try require(["q", "r", "b", "n"].contains(promotion!)) }
    if type == "snapshot" {
      try require(
        board?.count == 64
          && board!.allSatisfy { $0 == nil || "PNBRQKpnbrqk".map(String.init).contains($0!) })
      try require(players != nil && clocks != nil)
      try require(
        [players?.white, players?.black].allSatisfy { $0.map { $0.utf16.count <= 128 } ?? true })
      for avatar in [players?.whiteAvatar, players?.blackAvatar].compactMap({ $0 }) {
        let url = URLComponents(string: avatar)
        try require(
          avatar.utf16.count <= 2048 && url?.scheme == "https"
            && url?.host?.isEmpty == false && url?.user == nil && url?.password == nil)
      }
      for number in [clocks?.white.remainingMs, clocks?.black.remainingMs, clocks?.observedAt] {
        try require(number.map { $0.isFinite && $0 >= 0 } ?? true)
      }
    }
  }
}
