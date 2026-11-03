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
enum GameResultReason: String, Codable, CaseIterable {
  case checkmate, stalemate, timeout, resignation
  case insufficientMaterial = "insufficient-material"
  case repetition
  case fiftyMoveRule = "fifty-move-rule"
  case agreement

  var label: String {
    switch self {
    case .insufficientMaterial: "insufficient material"
    case .fiftyMoveRule: "the fifty-move rule"
    default: rawValue
    }
  }
}

extension GameResult {
  func title(for player: PieceColor?) -> String {
    guard self != .draw, let player else { return label }
    let won = (self == .whiteWon) == (player == .white)
    return won ? "You won" : "You lost"
  }

  func detail(reason: GameResultReason?, player: PieceColor?) -> String {
    let emoji =
      self == .draw
      ? "🤝"
      : player.map {
        (self == .whiteWon) == ($0 == .white) ? "🎉" : "😔"
      } ?? ""
    return [reason.map { "by \($0.label)" }, emoji.isEmpty ? nil : emoji]
      .compactMap { $0 }.joined(separator: " ")
  }
}

enum DeviceRole: String, Codable { case tv, `extension` }
enum Piece: String, Codable, CaseIterable {
  case whitePawn = "P"
  case whiteKnight = "N"
  case whiteBishop = "B"
  case whiteRook = "R"
  case whiteQueen = "Q"
  case whiteKing = "K"
  case blackPawn = "p"
  case blackKnight = "n"
  case blackBishop = "b"
  case blackRook = "r"
  case blackQueen = "q"
  case blackKing = "k"
  var color: PieceColor { rawValue == rawValue.uppercased() ? .white : .black }
}
enum Promotion: String, Codable, CaseIterable {
  case queen = "q"
  case rook = "r"
  case bishop = "b"
  case knight = "n"
}
enum MoveOutcome: String, Codable {
  case rejected, uncertain
  case observedComplete = "observed-complete"
}

private struct WireKey: CodingKey, Hashable {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}
private func fields(
  _ decoder: Decoder, required: [String], optional: [String] = [], envelope: Bool = false
) throws -> KeyedDecodingContainer<WireKey> {
  let container = try decoder.container(keyedBy: WireKey.self)
  let keys = Set(container.allKeys.map(\.stringValue))
  let required = Set(required)
  let allowed = required.union(optional).union(envelope ? ["v", "type"] : [])
  guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
    throw ProtocolFailure("Unexpected or missing protocol fields.")
  }
  return container
}
private func require(_ condition: Bool) throws {
  if !condition { throw ProtocolFailure("Invalid protocol payload.") }
}
private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf16.count <= 128 }
private func validAvatar(_ value: String?) -> Bool {
  guard let value else { return true }
  let url = URLComponents(string: value)
  return value.utf16.count <= 2048 && url?.scheme == "https" && url?.host?.isEmpty == false
    && url?.user == nil && url?.password == nil
}

struct GameContext: Codable, Equatable {
  var gameId: String
  var generation: String
  init(gameId: String, generation: String) {
    self.gameId = gameId
    self.generation = generation
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["gameId", "generation"])
    gameId = try c.decode(String.self, forKey: WireKey("gameId"))
    generation = try c.decode(String.self, forKey: WireKey("generation"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(gameId, forKey: WireKey("gameId"))
    try c.encode(generation, forKey: WireKey("generation"))
  }
  func validate() throws {
    try require(validID(gameId))
    try require(validID(generation))
  }
}

struct Players: Codable, Equatable {
  var white: String?
  var black: String?
  var whiteAvatar: String?
  var blackAvatar: String?
  init(
    white: String? = nil, black: String? = nil, whiteAvatar: String? = nil,
    blackAvatar: String? = nil
  ) {
    self.white = white
    self.black = black
    self.whiteAvatar = whiteAvatar
    self.blackAvatar = blackAvatar
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["white", "black", "whiteAvatar", "blackAvatar"])
    white = try c.decode(String?.self, forKey: WireKey("white"))
    black = try c.decode(String?.self, forKey: WireKey("black"))
    whiteAvatar = try c.decode(String?.self, forKey: WireKey("whiteAvatar"))
    blackAvatar = try c.decode(String?.self, forKey: WireKey("blackAvatar"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(white, forKey: WireKey("white"))
    try c.encode(black, forKey: WireKey("black"))
    try c.encode(whiteAvatar, forKey: WireKey("whiteAvatar"))
    try c.encode(blackAvatar, forKey: WireKey("blackAvatar"))
  }
  func validate() throws {
    try require(white.map { $0.utf16.count <= 128 } ?? true)
    try require(black.map { $0.utf16.count <= 128 } ?? true)
    try require(validAvatar(whiteAvatar))
    try require(validAvatar(blackAvatar))
  }
}

struct ObservedClock: Codable, Equatable {
  var remainingMs: Double?
  var running: Bool?
  init(remainingMs: Double? = nil, running: Bool? = nil) {
    self.remainingMs = remainingMs
    self.running = running
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["remainingMs", "running"])
    remainingMs = try c.decode(Double?.self, forKey: WireKey("remainingMs"))
    running = try c.decode(Bool?.self, forKey: WireKey("running"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(remainingMs, forKey: WireKey("remainingMs"))
    try c.encode(running, forKey: WireKey("running"))
  }
  func validate() throws {
    try require(remainingMs.map { $0.isFinite && $0 >= 0 } ?? true)
  }
}

struct Clocks: Codable, Equatable {
  var white: ObservedClock
  var black: ObservedClock
  var observedAt: Double?
  init(white: ObservedClock, black: ObservedClock, observedAt: Double? = nil) {
    self.white = white
    self.black = black
    self.observedAt = observedAt
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["white", "black", "observedAt"])
    white = try c.decode(ObservedClock.self, forKey: WireKey("white"))
    black = try c.decode(ObservedClock.self, forKey: WireKey("black"))
    observedAt = try c.decode(Double?.self, forKey: WireKey("observedAt"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(white, forKey: WireKey("white"))
    try c.encode(black, forKey: WireKey("black"))
    try c.encode(observedAt, forKey: WireKey("observedAt"))
  }
  func validate() throws {
    try white.validate()
    try black.validate()
    try require(observedAt.map { $0.isFinite && $0 >= 0 } ?? true)
  }
}

struct LegalMove: Codable, Equatable {
  var from: String
  var to: String
  init(from: String, to: String) {
    self.from = from
    self.to = to
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["from", "to"])
    from = try c.decode(String.self, forKey: WireKey("from"))
    to = try c.decode(String.self, forKey: WireKey("to"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(from, forKey: WireKey("from"))
    try c.encode(to, forKey: WireKey("to"))
  }
  func validate() throws {
    try require(Square.index(from) != nil)
    try require(Square.index(to) != nil)
  }
}

struct Authenticate: Codable, Equatable {
  var credential: String
  init(credential: String) {
    self.credential = credential
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["credential"], envelope: true)
    credential = try c.decode(String.self, forKey: WireKey("credential"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(credential, forKey: WireKey("credential"))
  }
  func validate() throws {
    try require(credential.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
  }
}

struct Authenticated: Codable, Equatable {
  var role: DeviceRole
  var pairingId: String
  init(role: DeviceRole, pairingId: String) {
    self.role = role
    self.pairingId = pairingId
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["role", "pairingId"], envelope: true)
    role = try c.decode(DeviceRole.self, forKey: WireKey("role"))
    pairingId = try c.decode(String.self, forKey: WireKey("pairingId"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(role, forKey: WireKey("role"))
    try c.encode(pairingId, forKey: WireKey("pairingId"))
  }
  func validate() throws {
    try require(validID(pairingId))
  }
}

struct Heartbeat: Codable, Equatable {
  var nonce: String
  init(nonce: String) {
    self.nonce = nonce
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["nonce"], envelope: true)
    nonce = try c.decode(String.self, forKey: WireKey("nonce"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(nonce, forKey: WireKey("nonce"))
  }
  func validate() throws {
    try require(validID(nonce))
  }
}

struct Attachment: Codable, Equatable {
  var generation: String
  var gameId: String?
  init(generation: String, gameId: String? = nil) {
    self.generation = generation
    self.gameId = gameId
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["generation", "gameId"], envelope: true)
    generation = try c.decode(String.self, forKey: WireKey("generation"))
    gameId = try c.decode(String?.self, forKey: WireKey("gameId"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(generation, forKey: WireKey("generation"))
    try c.encode(gameId, forKey: WireKey("gameId"))
  }
  func validate() throws {
    try require(validID(generation))
    try require(gameId.map(validID) ?? true)
  }
}

struct SessionState: Codable, Equatable {
  var generation: String
  var gameId: String?
  var peerConnected: Bool
  init(generation: String, gameId: String? = nil, peerConnected: Bool) {
    self.generation = generation
    self.gameId = gameId
    self.peerConnected = peerConnected
  }
  init(from decoder: Decoder) throws {
    let c = try fields(
      decoder, required: ["generation", "gameId", "peerConnected"], envelope: true)
    generation = try c.decode(String.self, forKey: WireKey("generation"))
    gameId = try c.decode(String?.self, forKey: WireKey("gameId"))
    peerConnected = try c.decode(Bool.self, forKey: WireKey("peerConnected"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(generation, forKey: WireKey("generation"))
    try c.encode(gameId, forKey: WireKey("gameId"))
    try c.encode(peerConnected, forKey: WireKey("peerConnected"))
  }
  func validate() throws {
    try require(validID(generation))
    try require(gameId.map(validID) ?? true)
  }
}

struct GameStatus: Codable, Equatable {
  var context: GameContext
  var available: Bool
  var reason: String?
  var gameId: String {
    get { context.gameId }
    set { context.gameId = newValue }
  }
  var generation: String {
    get { context.generation }
    set { context.generation = newValue }
  }
  init(context: GameContext, available: Bool, reason: String? = nil) {
    self.context = context
    self.available = available
    self.reason = reason
  }
  init(from decoder: Decoder) throws {
    let c = try fields(
      decoder, required: ["available", "reason", "gameId", "generation"], envelope: true)
    context = GameContext(
      gameId: try c.decode(String.self, forKey: WireKey("gameId")),
      generation: try c.decode(String.self, forKey: WireKey("generation")))
    available = try c.decode(Bool.self, forKey: WireKey("available"))
    reason = try c.decode(String?.self, forKey: WireKey("reason"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(context.gameId, forKey: WireKey("gameId"))
    try c.encode(context.generation, forKey: WireKey("generation"))
    try c.encode(available, forKey: WireKey("available"))
    try c.encode(reason, forKey: WireKey("reason"))
  }
  func validate() throws {
    try context.validate()
    try require(reason.map { $0.utf16.count <= 256 } ?? true)
  }
}

struct Snapshot: Codable, Equatable {
  var context: GameContext
  var revision: Int64
  var board: [Piece?]
  var players: Players
  var playerColor: PieceColor?
  var bottomColor: PieceColor
  var turn: PieceColor?
  var clocks: Clocks
  var legalMoves: [LegalMove]
  var checkSquare: String?
  var result: GameResult?
  var resultReason: GameResultReason?
  var gameId: String {
    get { context.gameId }
    set { context.gameId = newValue }
  }
  var generation: String {
    get { context.generation }
    set { context.generation = newValue }
  }
  var boardOrientation: PieceColor { bottomColor }
  init(
    context: GameContext, revision: Int64, board: [Piece?], players: Players,
    playerColor: PieceColor? = nil, bottomColor: PieceColor, turn: PieceColor? = nil,
    clocks: Clocks, legalMoves: [LegalMove], checkSquare: String? = nil, result: GameResult? = nil,
    resultReason: GameResultReason? = nil
  ) {
    self.context = context
    self.revision = revision
    self.board = board
    self.players = players
    self.playerColor = playerColor
    self.bottomColor = bottomColor
    self.turn = turn
    self.clocks = clocks
    self.legalMoves = legalMoves
    self.checkSquare = checkSquare
    self.result = result
    self.resultReason = resultReason
  }
  init(from decoder: Decoder) throws {
    let c = try fields(
      decoder,
      required: [
        "revision", "board", "players", "playerColor", "bottomColor", "turn", "clocks",
        "legalMoves", "checkSquare", "result", "resultReason", "gameId", "generation",
      ], envelope: true)
    context = GameContext(
      gameId: try c.decode(String.self, forKey: WireKey("gameId")),
      generation: try c.decode(String.self, forKey: WireKey("generation")))
    revision = try c.decode(Int64.self, forKey: WireKey("revision"))
    board = try c.decode([Piece?].self, forKey: WireKey("board"))
    players = try c.decode(Players.self, forKey: WireKey("players"))
    playerColor = try c.decode(PieceColor?.self, forKey: WireKey("playerColor"))
    bottomColor = try c.decode(PieceColor.self, forKey: WireKey("bottomColor"))
    turn = try c.decode(PieceColor?.self, forKey: WireKey("turn"))
    clocks = try c.decode(Clocks.self, forKey: WireKey("clocks"))
    legalMoves = try c.decode([LegalMove].self, forKey: WireKey("legalMoves"))
    checkSquare = try c.decode(String?.self, forKey: WireKey("checkSquare"))
    result = try c.decode(GameResult?.self, forKey: WireKey("result"))
    resultReason = try c.decode(GameResultReason?.self, forKey: WireKey("resultReason"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(context.gameId, forKey: WireKey("gameId"))
    try c.encode(context.generation, forKey: WireKey("generation"))
    try c.encode(revision, forKey: WireKey("revision"))
    try c.encode(board, forKey: WireKey("board"))
    try c.encode(players, forKey: WireKey("players"))
    try c.encode(playerColor, forKey: WireKey("playerColor"))
    try c.encode(bottomColor, forKey: WireKey("bottomColor"))
    try c.encode(turn, forKey: WireKey("turn"))
    try c.encode(clocks, forKey: WireKey("clocks"))
    try c.encode(legalMoves, forKey: WireKey("legalMoves"))
    try c.encode(checkSquare, forKey: WireKey("checkSquare"))
    try c.encode(result, forKey: WireKey("result"))
    try c.encode(resultReason, forKey: WireKey("resultReason"))
  }
  func validate() throws {
    try context.validate()
    try require(revision >= 0 && revision <= 9_007_199_254_740_991)
    try require(board.count == 64)
    try players.validate()
    try clocks.validate()
    try require(legalMoves.count <= 256)
    for move in legalMoves { try move.validate() }
    try require(checkSquare.map { Square.index($0) != nil } ?? true)
  }
}

struct MoveRequest: Codable, Equatable {
  var context: GameContext
  var revision: Int64
  var commandId: String
  var from: String
  var to: String
  var promotion: Promotion?
  var gameId: String {
    get { context.gameId }
    set { context.gameId = newValue }
  }
  var generation: String {
    get { context.generation }
    set { context.generation = newValue }
  }
  init(
    context: GameContext, revision: Int64, commandId: String, from: String, to: String,
    promotion: Promotion? = nil
  ) {
    self.context = context
    self.revision = revision
    self.commandId = commandId
    self.from = from
    self.to = to
    self.promotion = promotion
  }
  init(from decoder: Decoder) throws {
    let c = try fields(
      decoder, required: ["revision", "commandId", "from", "to", "gameId", "generation"],
      optional: ["promotion"], envelope: true)
    context = GameContext(
      gameId: try c.decode(String.self, forKey: WireKey("gameId")),
      generation: try c.decode(String.self, forKey: WireKey("generation")))
    revision = try c.decode(Int64.self, forKey: WireKey("revision"))
    commandId = try c.decode(String.self, forKey: WireKey("commandId"))
    from = try c.decode(String.self, forKey: WireKey("from"))
    to = try c.decode(String.self, forKey: WireKey("to"))
    if c.contains(WireKey("promotion")) {
      promotion = try c.decode(Promotion.self, forKey: WireKey("promotion"))
    } else {
      promotion = nil
    }
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(context.gameId, forKey: WireKey("gameId"))
    try c.encode(context.generation, forKey: WireKey("generation"))
    try c.encode(revision, forKey: WireKey("revision"))
    try c.encode(commandId, forKey: WireKey("commandId"))
    try c.encode(from, forKey: WireKey("from"))
    try c.encode(to, forKey: WireKey("to"))
    try c.encodeIfPresent(promotion, forKey: WireKey("promotion"))
  }
  func validate() throws {
    try context.validate()
    try require(revision >= 0 && revision <= 9_007_199_254_740_991)
    try require(validID(commandId))
    try require(Square.index(from) != nil)
    try require(Square.index(to) != nil)
  }
}

struct CommandOutcome: Codable, Equatable {
  var context: GameContext
  var commandId: String
  var outcome: MoveOutcome
  var reason: String?
  var gameId: String {
    get { context.gameId }
    set { context.gameId = newValue }
  }
  var generation: String {
    get { context.generation }
    set { context.generation = newValue }
  }
  init(context: GameContext, commandId: String, outcome: MoveOutcome, reason: String? = nil) {
    self.context = context
    self.commandId = commandId
    self.outcome = outcome
    self.reason = reason
  }
  init(from decoder: Decoder) throws {
    let c = try fields(
      decoder, required: ["commandId", "outcome", "reason", "gameId", "generation"], envelope: true)
    context = GameContext(
      gameId: try c.decode(String.self, forKey: WireKey("gameId")),
      generation: try c.decode(String.self, forKey: WireKey("generation")))
    commandId = try c.decode(String.self, forKey: WireKey("commandId"))
    outcome = try c.decode(MoveOutcome.self, forKey: WireKey("outcome"))
    reason = try c.decode(String?.self, forKey: WireKey("reason"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(context.gameId, forKey: WireKey("gameId"))
    try c.encode(context.generation, forKey: WireKey("generation"))
    try c.encode(commandId, forKey: WireKey("commandId"))
    try c.encode(outcome, forKey: WireKey("outcome"))
    try c.encode(reason, forKey: WireKey("reason"))
  }
  func validate() throws {
    try context.validate()
    try require(validID(commandId))
    try require(reason.map { $0.utf16.count <= 256 } ?? true)
  }
}

struct SnapshotRequest: Codable, Equatable {
  var context: GameContext
  var gameId: String {
    get { context.gameId }
    set { context.gameId = newValue }
  }
  var generation: String {
    get { context.generation }
    set { context.generation = newValue }
  }
  init(context: GameContext) {
    self.context = context
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["gameId", "generation"], envelope: true)
    context = GameContext(
      gameId: try c.decode(String.self, forKey: WireKey("gameId")),
      generation: try c.decode(String.self, forKey: WireKey("generation")))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(context.gameId, forKey: WireKey("gameId"))
    try c.encode(context.generation, forKey: WireKey("generation"))
  }
  func validate() throws {
    try context.validate()
  }
}

struct RelayError: Codable, Equatable {
  var code: String
  var message: String
  init(code: String, message: String) {
    self.code = code
    self.message = message
  }
  init(from decoder: Decoder) throws {
    let c = try fields(decoder, required: ["code", "message"], envelope: true)
    code = try c.decode(String.self, forKey: WireKey("code"))
    message = try c.decode(String.self, forKey: WireKey("message"))
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(code, forKey: WireKey("code"))
    try c.encode(message, forKey: WireKey("message"))
  }
  func validate() throws {
    try require(validID(code))
    try require(message.utf16.count <= 256)
  }
}

enum Message: Codable, Equatable {
  static let version = 3
  static let maxBytes = 65_536
  case authenticate(Authenticate)
  case authenticated(Authenticated)
  case ping(Heartbeat)
  case pong(Heartbeat)
  case attachment(Attachment)
  case session(SessionState)
  case status(GameStatus)
  case snapshot(Snapshot)
  case move(MoveRequest)
  case outcome(CommandOutcome)
  case snapshotRequest(SnapshotRequest)
  case error(RelayError)
  enum Kind: String, Codable, CaseIterable {
    case authenticate
    case authenticated
    case ping
    case pong
    case attachment
    case session
    case status
    case snapshot
    case move
    case outcome
    case snapshotRequest = "snapshot-request"
    case error
  }
  var kind: Kind {
    switch self {
    case .authenticate: .authenticate
    case .authenticated: .authenticated
    case .ping: .ping
    case .pong: .pong
    case .attachment: .attachment
    case .session: .session
    case .status: .status
    case .snapshot: .snapshot
    case .move: .move
    case .outcome: .outcome
    case .snapshotRequest: .snapshotRequest
    case .error: .error
    }
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: WireKey.self)
    guard try c.decode(Int.self, forKey: WireKey("v")) == Self.version else {
      throw ProtocolFailure("Unsupported relay protocol. Update Chess TV and the relay together.")
    }
    switch try c.decode(Kind.self, forKey: WireKey("type")) {
    case .authenticate: self = .authenticate(try Authenticate(from: decoder))
    case .authenticated: self = .authenticated(try Authenticated(from: decoder))
    case .ping: self = .ping(try Heartbeat(from: decoder))
    case .pong: self = .pong(try Heartbeat(from: decoder))
    case .attachment: self = .attachment(try Attachment(from: decoder))
    case .session: self = .session(try SessionState(from: decoder))
    case .status: self = .status(try GameStatus(from: decoder))
    case .snapshot: self = .snapshot(try Snapshot(from: decoder))
    case .move: self = .move(try MoveRequest(from: decoder))
    case .outcome: self = .outcome(try CommandOutcome(from: decoder))
    case .snapshotRequest: self = .snapshotRequest(try SnapshotRequest(from: decoder))
    case .error: self = .error(try RelayError(from: decoder))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: WireKey.self)
    try c.encode(Self.version, forKey: WireKey("v"))
    try c.encode(kind, forKey: WireKey("type"))
    switch self {
    case .authenticate(let payload): try payload.encode(to: encoder)
    case .authenticated(let payload): try payload.encode(to: encoder)
    case .ping(let payload): try payload.encode(to: encoder)
    case .pong(let payload): try payload.encode(to: encoder)
    case .attachment(let payload): try payload.encode(to: encoder)
    case .session(let payload): try payload.encode(to: encoder)
    case .status(let payload): try payload.encode(to: encoder)
    case .snapshot(let payload): try payload.encode(to: encoder)
    case .move(let payload): try payload.encode(to: encoder)
    case .outcome(let payload): try payload.encode(to: encoder)
    case .snapshotRequest(let payload): try payload.encode(to: encoder)
    case .error(let payload): try payload.encode(to: encoder)
    }
  }
  static func decode(_ data: Data) throws -> Message {
    guard data.count <= maxBytes else { throw ProtocolFailure("Relay message exceeds 64 KiB.") }
    return try JSONDecoder().decode(Self.self, from: data)
  }
  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard data.count <= Self.maxBytes else {
      throw ProtocolFailure("Relay message exceeds 64 KiB.")
    }
    return data
  }
}

extension Promotion {
  var label: String { String(describing: self).capitalized }
  func piece(for color: PieceColor) -> Piece {
    switch (self, color) {
    case (.queen, .white): .whiteQueen
    case (.queen, .black): .blackQueen
    case (.rook, .white): .whiteRook
    case (.rook, .black): .blackRook
    case (.bishop, .white): .whiteBishop
    case (.bishop, .black): .blackBishop
    case (.knight, .white): .whiteKnight
    case (.knight, .black): .blackKnight
    }
  }
}
