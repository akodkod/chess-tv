import Foundation

/// A visual explanation of one observed board change, never a source of game rules.
struct BoardTransition: Equatable {
  enum Kind: Equatable { case move, capture, castle, promotion }
  struct Movement: Equatable {
    let piece: String
    let from: Int
    let to: Int
    let resultPiece: String
  }
  let moves: [Movement]
  let kind: Kind
  let capturedSquare: Int?

  static func between(_ previous: Message, _ next: Message) -> BoardTransition? {
    guard let before = previous.board, let after = next.board,
      before.count == 64, after.count == 64, before != after,
      previous.gameId != nil, previous.gameId == next.gameId,
      previous.generation != nil, previous.generation == next.generation,
      previous.playerColor == next.playerColor,
      let oldRevision = previous.revision, let revision = next.revision, revision > oldRevision,
      let color = previous.turn, next.turn != nil, next.turn != color
    else { return nil }

    func matches(_ movements: [Movement], captured: Int? = nil) -> Bool {
      var expected = before
      for move in movements { expected[move.from] = nil }
      if let captured { expected[captured] = nil }
      for move in movements { expected[move.to] = move.resultPiece }
      return expected == after
    }
    let king = color == .white ? "K" : "k"
    let rook = color == .white ? "R" : "r"
    let home = color == .white ? 56 : 0
    for (kingTo, rookFrom, rookTo) in [(6, 7, 5), (2, 0, 3)] {
      let moves = [
        Movement(piece: king, from: home + 4, to: home + kingTo, resultPiece: king),
        Movement(piece: rook, from: home + rookFrom, to: home + rookTo, resultPiece: rook),
      ]
      let emptyFiles = kingTo == 6 ? [5, 6] : [1, 2, 3]
      if before[home + 4] == king, before[home + rookFrom] == rook,
        emptyFiles.allSatisfy({ before[home + $0] == nil }), matches(moves)
      {
        return Self(moves: moves, kind: .castle, capturedSquare: nil)
      }
    }

    var candidates: [BoardTransition] = []
    for from in 0..<64 where before[from] != nil && after[from] == nil {
      guard let piece = before[from], Square.color(of: piece) == color else { continue }
      for to in 0..<64 where to != from && after[to] != before[to] {
        guard let resultPiece = after[to], Square.color(of: resultPiece) == color,
          Square.color(of: before[to]) != color
        else { continue }
        let dx = to % 8 - from % 8
        let dy = to / 8 - from / 8
        let pawn = piece.lowercased() == "p"
        let direction = color == .white ? -1 : 1
        let promotes = pawn && to / 8 == (color == .white ? 0 : 7)
        if promotes {
          guard ["q", "r", "b", "n"].contains(resultPiece.lowercased()) else { continue }
        } else if resultPiece != piece {
          continue
        }

        var captured = before[to] == nil ? nil : to
        let valid: Bool
        switch piece.lowercased() {
        case "p":
          if dx == 0 {
            valid =
              before[to] == nil
              && (dy == direction
                || (dy == direction * 2 && from / 8 == (color == .white ? 6 : 1)
                  && before[from + direction * 8] == nil))
          } else if abs(dx) == 1 && dy == direction {
            if before[to] != nil {
              valid = true
            } else {
              let victim = to - direction * 8
              valid =
                from / 8 == (color == .white ? 3 : 4)
                && before[victim] == (color == .white ? "p" : "P")
              captured = victim
            }
          } else {
            valid = false
          }
        case "n": valid = (abs(dx) == 1 && abs(dy) == 2) || (abs(dx) == 2 && abs(dy) == 1)
        case "k": valid = max(abs(dx), abs(dy)) == 1
        case "b", "r", "q":
          let diagonal = abs(dx) == abs(dy)
          let straight = dx == 0 || dy == 0
          let shape =
            piece.lowercased() == "b"
            ? diagonal
            : piece.lowercased() == "r" ? straight : diagonal || straight
          if shape {
            let step = (dy == 0 ? 0 : dy > 0 ? 8 : -8) + (dx == 0 ? 0 : dx > 0 ? 1 : -1)
            var square = from + step
            var clear = true
            while square != to {
              if before[square] != nil {
                clear = false
                break
              }
              square += step
            }
            valid = clear
          } else {
            valid = false
          }
        default: valid = false
        }
        let movement = Movement(piece: piece, from: from, to: to, resultPiece: resultPiece)
        if valid && matches([movement], captured: captured) {
          candidates.append(
            Self(
              moves: [movement],
              kind: promotes
                ? .promotion
                : captured == nil ? .move : .capture, capturedSquare: captured))
        }
      }
    }
    return candidates.count == 1 ? candidates[0] : nil
  }
}
