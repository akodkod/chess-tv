import Foundation

enum Square {
  static func name(_ index: Int) -> String { "\(Array("abcdefgh")[index % 8])\(8 - index / 8)" }
  static func index(_ name: String) -> Int? {
    let bytes = Array(name.utf8)
    guard bytes.count == 2, (97...104).contains(bytes[0]), (49...56).contains(bytes[1]) else {
      return nil
    }
    return (8 - Int(bytes[1] - 48)) * 8 + Int(bytes[0] - 97)
  }
  static func order(for color: PieceColor?) -> [Int] {
    color == .black ? Array((0..<64).reversed()) : Array(0..<64)
  }
  static func color(of piece: String?) -> PieceColor? {
    guard let piece else { return nil }
    return piece == piece.uppercased() ? .white : .black
  }
  static func promotion(piece: String?, destination: Int) -> Bool {
    (piece == "P" && destination / 8 == 0) || (piece == "p" && destination / 8 == 7)
  }
  static func pieceName(_ piece: String?) -> String {
    guard let piece else { return "empty" }
    let names = ["p": "pawn", "n": "knight", "b": "bishop", "r": "rook", "q": "queen", "k": "king"]
    return
      "\(color(of: piece) == .white ? "White" : "Black") \(names[piece.lowercased()] ?? "piece")"
  }
  static func glyph(_ piece: String?) -> String {
    guard let piece else { return "" }
    // Request text presentation: the black pawn otherwise becomes a colored emoji.
    // Use filled silhouettes for both sides, with contrasting foreground/outline.
    let symbols = ["k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"]
    return (symbols[piece.lowercased()] ?? "") + "\u{FE0E}"
  }
}

struct ClockReading {
  var clocks: Clocks
  var receivedAt: TimeInterval
  var frozenAt: TimeInterval?
  func remaining(_ color: PieceColor, now: TimeInterval) -> Double? {
    let clock = color == .white ? clocks.white : clocks.black
    guard let ms = clock.remainingMs else { return nil }
    let elapsed = clock.running == true ? max(0, (frozenAt ?? now) - receivedAt) * 1000 : 0
    return max(0, ms - elapsed)
  }
  static func format(_ ms: Double?) -> String {
    guard let ms, ms.isFinite, ms >= 0 else { return "—:—" }
    if ms >= 360_000_000 { return "99h+" }
    let seconds = Int(ceil(ms / 1000))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
