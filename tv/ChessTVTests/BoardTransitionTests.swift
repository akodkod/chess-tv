import UIKit
import XCTest

@testable import ChessTV

final class BoardTransitionTests: XCTestCase {
  @MainActor func testLayerMovesSurviveConfirmationAndResetCleanly() throws {
    let view = PieceLayerView()
    let before = position(["e2": .whitePawn, "e7": .blackPawn])
    let after = position(["e4": .whitePawn, "e7": .blackPawn], turn: .black, revision: 2)
    func update(_ message: Snapshot, animate: Bool = true, token: String = "") {
      view.update(
        message, side: 800, selectedSquare: nil, animateChanges: animate, resetToken: token)
    }
    update(before)
    let pawn = try XCTUnwrap(view.layer.sublayers?.first { $0.position == CGPoint(x: 450, y: 650) })
    update(after)
    XCTAssertEqual(pawn.position, CGPoint(x: 450, y: 450))
    let motion = try XCTUnwrap(pawn.animation(forKey: "move") as? CABasicAnimation)
    XCTAssertEqual((motion.fromValue as? NSValue)?.cgPointValue, CGPoint(x: 450, y: 650))
    XCTAssertEqual(motion.duration, 0.18)
    var confirmation = after
    confirmation.revision = 3
    update(confirmation)
    XCTAssertTrue(view.layer.sublayers?.contains { $0 === pawn } == true)
    XCTAssertNotNil(pawn.animation(forKey: "move"))
    update(before, token: "reconnect")
    XCTAssertNil(pawn.superlayer)
    XCTAssertTrue(view.layer.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
    update(after, animate: false)
    XCTAssertTrue(view.layer.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
    view.clear()
    XCTAssertTrue((view.layer.sublayers ?? []).isEmpty)
  }
  @MainActor func testLayerCaptureUsesCompositorFlightAndUndoRemovesIt() throws {
    let view = PieceLayerView()
    let before = position(["e4": .whitePawn, "d5": .blackPawn], turn: .black)
    let after = position(["e4": .blackPawn], revision: 2)
    view.update(before, side: 800, selectedSquare: nil, animateChanges: true, resetToken: "")
    let victim = try XCTUnwrap(
      view.layer.sublayers?.first { $0.position == CGPoint(x: 450, y: 450) })
    view.update(after, side: 800, selectedSquare: nil, animateChanges: true, resetToken: "")
    let flight = try XCTUnwrap(victim.animation(forKey: "capture") as? CAAnimationGroup)
    XCTAssertEqual(flight.duration, 1.75)
    XCTAssertEqual(
      flight.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath },
      ["position", "transform.scale", "transform.rotation.z"])
    XCTAssertEqual((flight.animations?.first as? CAKeyframeAnimation)?.values?.count, 121)
    XCTAssertEqual(
      flight.fillMode, .backwards, "Victim waits on its square until the attacker arrives")
    view.update(before, side: 800, selectedSquare: nil, animateChanges: true, resetToken: "")
    XCTAssertNil(victim.superlayer)
    XCTAssertEqual(view.layer.sublayers?.count, 2)
  }
  @MainActor func testLayerCastlingPromotionAndBlackOrientation() throws {
    for color in [PieceColor.white, .black] {
      let view = PieceLayerView()
      var before = position(["e1": .whiteKing, "h1": .whiteRook])
      var after = position(["g1": .whiteKing, "f1": .whiteRook], turn: .black, revision: 2)
      before.playerColor = color
      after.playerColor = color
      before.bottomColor = color
      after.bottomColor = color
      view.update(before, side: 800, selectedSquare: nil, animateChanges: true, resetToken: "")
      view.update(after, side: 800, selectedSquare: nil, animateChanges: true, resetToken: "")
      XCTAssertEqual(view.layer.sublayers?.filter { $0.animation(forKey: "move") != nil }.count, 2)
      let expected = color == .white ? CGPoint(x: 650, y: 750) : CGPoint(x: 150, y: 50)
      XCTAssertTrue(view.layer.sublayers?.contains { $0.position == expected } == true)
    }
    let view = PieceLayerView()
    view.update(
      position(["a7": .whitePawn]), side: 800, selectedSquare: nil, animateChanges: true,
      resetToken: "")
    view.update(
      position(["a8": .whiteKnight], turn: .black, revision: 2), side: 800,
      selectedSquare: nil, animateChanges: true, resetToken: "")
    XCTAssertNotNil(view.layer.sublayers?.first?.animation(forKey: "promotion"))
  }
  private func position(
    _ pieces: [String: Piece], turn: PieceColor = .white,
    revision: Int64 = 1
  ) -> Snapshot {
    var board = [Piece?](repeating: nil, count: 64)
    for (square, piece) in pieces { board[Square.index(square)!] = piece }
    return Snapshot(
      context: GameContext(gameId: "game", generation: "generation"),
      revision: revision, board: board, players: Players(), playerColor: .white,
      bottomColor: .white, turn: turn,
      clocks: Clocks(white: ObservedClock(), black: ObservedClock()), legalMoves: [])
  }
  func testQuietMoveAndCapture() throws {
    let old = position(["e2": .whitePawn, "d3": .blackPawn])
    let quiet = position(["e4": .whitePawn, "d3": .blackPawn], turn: .black, revision: 2)
    let move = try XCTUnwrap(BoardTransition.between(old, quiet))
    XCTAssertEqual(move.kind, .move)
    XCTAssertEqual(move.moves.first?.from, Square.index("e2"))
    XCTAssertEqual(move.moves.first?.to, Square.index("e4"))
    let capture = position(["d3": .whitePawn], turn: .black, revision: 2)
    XCTAssertEqual(BoardTransition.between(old, capture)?.kind, .capture)
    XCTAssertEqual(BoardTransition.between(old, capture)?.capturedSquare, Square.index("d3"))
  }
  func testLegalMovePreviewsIncludeSpecialMovesForBothColors() throws {
    for color in [PieceColor.white, .black] {
      let white = color == .white
      let home = white ? "1" : "8"
      let pawnRank = white ? "7" : "2"
      let promotionRank = white ? "8" : "1"
      let scenarios: [([String: Piece], String, String, Promotion?, [String: Piece])] =
        [
          (["e2": .whitePawn], "e2", "e4", nil, ["e4": .whitePawn]),
          (
            ["e" + home: .whiteKing, "h" + home: .whiteRook], "e" + home, "g" + home, nil,
            ["g" + home: .whiteKing, "f" + home: .whiteRook]
          ),
          (
            ["e" + home: .whiteKing, "a" + home: .whiteRook], "e" + home, "c" + home, nil,
            ["c" + home: .whiteKing, "d" + home: .whiteRook]
          ),
          (
            [white ? "e5" : "e4": .whitePawn, white ? "d5" : "d4": .blackPawn],
            white ? "e5" : "e4", white ? "d6" : "d3", nil, [white ? "d6" : "d3": .whitePawn]
          ),
        ]
        + Promotion.allCases.flatMap { promotion in
          [false, true].map { capture in
            let from = "a" + pawnRank
            let to = (capture ? "b" : "a") + promotionRank
            var pieces: [String: Piece] = [from: .whitePawn]
            if capture { pieces[to] = .blackRook }
            return (pieces, from, to, Optional(promotion), [to: promotion.piece(for: .white)])
          }
        }
      for (pieces, from, to, promotion, expected) in scenarios {
        // The simple pawn scenario is white-only; others use color-specific ranks.
        if !white && from == "e2" { continue }
        func colored(_ pieces: [String: Piece]) -> [String: Piece] {
          pieces.mapValues {
            white
              ? $0
              : Piece(
                rawValue: $0.color == .white ? $0.rawValue.lowercased() : $0.rawValue.uppercased())!
          }
        }
        var before = position(colored(pieces), turn: color)
        before.playerColor = color
        before.legalMoves = [LegalMove(from: from, to: to)]
        let preview = try XCTUnwrap(
          BoardTransition.preview(
            before, from: Square.index(from)!, to: Square.index(to)!, promotion: promotion))
        XCTAssertEqual(preview.board, position(colored(expected)).board)
        XCTAssertNotNil(BoardTransition.between(before, preview))
        before.legalMoves = []
        XCTAssertNil(
          BoardTransition.preview(
            before, from: Square.index(from)!, to: Square.index(to)!, promotion: promotion))
      }
    }
  }
  func testHistoryReversesCapturesCastlesAndPromotions() throws {
    let pairs: [(Snapshot, Snapshot)] = [
      (
        position(["e2": .whitePawn, "d3": .blackPawn]),
        position(["d3": .whitePawn], turn: .black, revision: 2)
      ),
      (
        position(["e1": .whiteKing, "h1": .whiteRook]),
        position(["g1": .whiteKing, "f1": .whiteRook], turn: .black, revision: 2)
      ),
      (
        position(["a7": .whitePawn, "b8": .blackRook]),
        position(["b8": .whiteQueen], turn: .black, revision: 2)
      ),
    ]
    for (before, after) in pairs {
      let forward = try XCTUnwrap(BoardTransition.between(before, after))
      XCTAssertEqual(BoardTransition.presentationBetween(before, after), forward)
      let reverse = try XCTUnwrap(BoardTransition.presentationBetween(after, before))
      XCTAssertNil(reverse.capturedSquare, "Undoing a capture must not eject a piece again")
      XCTAssertEqual(reverse.moves.count, forward.moves.count)
      for (move, undo) in zip(forward.moves, reverse.moves) {
        XCTAssertEqual(undo.from, move.to)
        XCTAssertEqual(undo.to, move.from)
        XCTAssertEqual(undo.piece, move.resultPiece)
        XCTAssertEqual(undo.resultPiece, move.piece)
      }
    }
  }
  func testAllCastlesMoveBothPieces() throws {
    for color in [PieceColor.white, .black] {
      let rank = color == .white ? "1" : "8"
      let king: Piece = color == .white ? .whiteKing : .blackKing
      let rook: Piece = color == .white ? .whiteRook : .blackRook
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
      position(["e5": .whitePawn, "d5": .blackPawn]),
      position(["d6": .whitePawn], turn: .black, revision: 2))
    XCTAssertEqual(white?.kind, .capture)
    XCTAssertEqual(white?.capturedSquare, Square.index("d5"))
    let black = BoardTransition.between(
      position(["e4": .blackPawn, "d4": .whitePawn], turn: .black),
      position(["d3": .blackPawn], revision: 2))
    XCTAssertEqual(black?.capturedSquare, Square.index("d4"))
  }
  func testAllPromotionsWithAndWithoutCapture() {
    for color in [PieceColor.white, .black] {
      let pawn: Piece = color == .white ? .whitePawn : .blackPawn
      let from = color == .white ? "a7" : "a2"
      let rank = color == .white ? "8" : "1"
      for promoted in Promotion.allCases {
        let result = promoted.piece(for: color)
        for captures in [false, true] {
          let to = (captures ? "b" : "a") + rank
          var pieces = [from: pawn]
          if captures { pieces[to] = color == .white ? .blackRook : .whiteRook }
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
    let before = position(["e2": .whitePawn, "e7": .blackPawn])
    let after = position(["e4": .whitePawn, "e7": .blackPawn], turn: .black, revision: 2)
    XCTAssertNil(BoardTransition.between(before, before))
    XCTAssertNil(
      BoardTransition.between(
        before,
        position(["e4": .whitePawn, "e5": .blackPawn], revision: 3)))
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
        position(["e2": .whitePawn]),
        position(["e5": .whitePawn], turn: .black, revision: 2)))
    XCTAssertNil(
      BoardTransition.between(
        position(["a1": .whiteRook, "a2": .whitePawn]),
        position(["a8": .whiteRook, "a2": .whitePawn], turn: .black, revision: 2)))
    XCTAssertNil(
      BoardTransition.between(
        position(["e5": .whitePawn, "d5": .blackPawn, "a1": .whiteRook]),
        position(["d6": .whitePawn], turn: .black, revision: 2)))
  }
}
