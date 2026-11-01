import XCTest

@testable import ChessTV

final class BoardTransitionTests: XCTestCase {
  private func position(
    _ pieces: [String: String], turn: PieceColor = .white,
    revision: Int64 = 1
  ) -> Message {
    var message = Message(type: "snapshot")
    message.gameId = "game"
    message.generation = "generation"
    message.playerColor = .white
    message.turn = turn
    message.revision = revision
    var board = [String?](repeating: nil, count: 64)
    for (square, piece) in pieces { board[Square.index(square)!] = piece }
    message.board = board
    return message
  }
  func testQuietMoveAndCapture() throws {
    let old = position(["e2": "P", "d3": "p"])
    let quiet = position(["e4": "P", "d3": "p"], turn: .black, revision: 2)
    let move = try XCTUnwrap(BoardTransition.between(old, quiet))
    XCTAssertEqual(move.kind, .move)
    XCTAssertEqual(move.moves.first?.from, Square.index("e2"))
    XCTAssertEqual(move.moves.first?.to, Square.index("e4"))
    let capture = position(["d3": "P"], turn: .black, revision: 2)
    XCTAssertEqual(BoardTransition.between(old, capture)?.kind, .capture)
    XCTAssertEqual(BoardTransition.between(old, capture)?.capturedSquare, Square.index("d3"))
  }
  func testAllCastlesMoveBothPieces() throws {
    for color in [PieceColor.white, .black] {
      let rank = color == .white ? "1" : "8"
      let king = color == .white ? "K" : "k"
      let rook = color == .white ? "R" : "r"
      for (rookFrom, kingTo, rookTo) in [("h", "g", "f"), ("a", "c", "d")] {
        let before = position(["e" + rank: king, rookFrom + rank: rook], turn: color)
        let after = position(
          [kingTo + rank: king, rookTo + rank: rook],
          turn: color == .white ? .black : .white, revision: 2)
        let move = try XCTUnwrap(BoardTransition.between(before, after))
        XCTAssertEqual(move.kind, .castle)
        XCTAssertEqual(move.moves.count, 2)
      }
    }
  }
  func testEnPassantBothColors() {
    let white = BoardTransition.between(
      position(["e5": "P", "d5": "p"]),
      position(["d6": "P"], turn: .black, revision: 2))
    XCTAssertEqual(white?.kind, .capture)
    XCTAssertEqual(white?.capturedSquare, Square.index("d5"))
    let black = BoardTransition.between(
      position(["e4": "p", "d4": "P"], turn: .black),
      position(["d3": "p"], revision: 2))
    XCTAssertEqual(black?.capturedSquare, Square.index("d4"))
  }
  func testAllPromotionsWithAndWithoutCapture() {
    for color in [PieceColor.white, .black] {
      let pawn = color == .white ? "P" : "p"
      let from = color == .white ? "a7" : "a2"
      let rank = color == .white ? "8" : "1"
      for promoted in ["q", "r", "b", "n"] {
        let result = color == .white ? promoted.uppercased() : promoted
        for captures in [false, true] {
          let to = (captures ? "b" : "a") + rank
          var pieces = [from: pawn]
          if captures { pieces[to] = color == .white ? "r" : "R" }
          let transition = BoardTransition.between(
            position(pieces, turn: color),
            position([to: result], turn: color == .white ? .black : .white, revision: 2))
          XCTAssertEqual(transition?.kind, .promotion)
          XCTAssertEqual(transition?.moves.first?.piece, pawn)
          XCTAssertEqual(transition?.moves.first?.resultPiece, result)
          XCTAssertEqual(transition?.capturedSquare, captures ? Square.index(to) : nil)
        }
      }
    }
  }
  func testRejectsResetsRepeatedAndMultipleMoves() {
    let before = position(["e2": "P", "e7": "p"])
    let after = position(["e4": "P", "e7": "p"], turn: .black, revision: 2)
    XCTAssertNil(BoardTransition.between(before, before))
    XCTAssertNil(
      BoardTransition.between(
        before,
        position(["e4": "P", "e5": "p"], revision: 3)))
    for field in ["game", "generation", "orientation", "revision", "turn"] {
      var changed = after
      switch field {
      case "game": changed.gameId = "other"
      case "generation": changed.generation = "other"
      case "orientation": changed.playerColor = .black
      case "revision": changed.revision = 1
      default: changed.turn = .white
      }
      XCTAssertNil(BoardTransition.between(before, changed), field)
    }
  }
  func testRejectsImpossibleGeometryAndExtraChanges() {
    XCTAssertNil(
      BoardTransition.between(
        position(["e2": "P"]),
        position(["e5": "P"], turn: .black, revision: 2)))
    XCTAssertNil(
      BoardTransition.between(
        position(["a1": "R", "a2": "P"]),
        position(["a8": "R", "a2": "P"], turn: .black, revision: 2)))
    XCTAssertNil(
      BoardTransition.between(
        position(["e5": "P", "d5": "p", "a1": "R"]),
        position(["d6": "P"], turn: .black, revision: 2)))
  }
}
