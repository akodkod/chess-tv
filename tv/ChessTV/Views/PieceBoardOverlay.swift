import SwiftUI

/// Pieces have no focus or hit targets; the underlying square buttons own input.
struct PieceBoardOverlay: View {
  let snapshot: Message
  let side: CGFloat
  var selectedSquare: Int?
  var animateChanges = true
  var resetToken = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var previous: Message?
  @State private var transition: BoardTransition?
  @State private var progress: CGFloat = 0
  @State private var animationTask: Task<Void, Never>?
  @State private var animationID = UUID()

  private struct Position: Equatable {
    let board: [String?]?
    let game: String?
    let generation: String?
    let color: PieceColor?
    let revision: Int64?
  }
  private var position: Position {
    Position(
      board: snapshot.board, game: snapshot.gameId, generation: snapshot.generation,
      color: snapshot.playerColor, revision: snapshot.revision)
  }
  var body: some View {
    let movingDestinations = Set(transition?.moves.map(\.to) ?? [])
    ZStack(alignment: .topLeading) {
      ForEach(0..<64, id: \.self) { index in
        if let board = snapshot.board, let piece = board[index], !movingDestinations.contains(index)
        {
          pieceImage(piece)
            .scaleEffect(selectedSquare == index ? 1.08 : 1)
            .shadow(
              color: .black.opacity(selectedSquare == index ? 0.4 : 0),
              radius: selectedSquare == index ? side / 100 : 0,
              x: 0, y: selectedSquare == index ? side / 160 : 0
            )
            .offset(y: selectedSquare == index ? -side / 320 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selectedSquare)
            .position(center(index))
            .zIndex(selectedSquare == index ? 1 : 0)
        }
      }
      if let transition {
        ForEach(Array(transition.moves.enumerated()), id: \.offset) { _, move in
          let start = center(move.from)
          let end = center(move.to)
          pieceImage(move.piece)
            .position(
              x: start.x + (end.x - start.x) * progress,
              y: start.y + (end.y - start.y) * progress)
        }
      }
    }
    .frame(width: side, height: side)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear { reset() }
    .onChange(of: position) { _, _ in update() }
    .onChange(of: resetToken) { _, _ in reset() }
    .onChange(of: reduceMotion) { _, _ in reset() }
    .onChange(of: animateChanges) { _, _ in reset() }
    .onDisappear { animationTask?.cancel() }
  }

  private func pieceImage(_ piece: String) -> some View {
    let prefix = Square.color(of: piece) == .white ? "w" : "b"
    return Image("chess-\(prefix)\(piece.lowercased())")
      .resizable().scaledToFit().frame(width: side / 8, height: side / 8)
  }
  private func center(_ index: Int) -> CGPoint {
    let displayed = Square.displayIndex(index, for: snapshot.playerColor)
    return CGPoint(
      x: (CGFloat(displayed % 8) + 0.5) * side / 8,
      y: (CGFloat(displayed / 8) + 0.5) * side / 8)
  }
  private func reset() {
    animationTask?.cancel()
    animationID = UUID()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      transition = nil
      progress = 0
    }
    previous = snapshot
  }
  private func update() {
    let old = previous
    // Metadata-only revisions must not interrupt a piece already in flight.
    if old?.board == snapshot.board, old?.gameId == snapshot.gameId,
      old?.generation == snapshot.generation, old?.playerColor == snapshot.playerColor
    {
      previous = snapshot
      return
    }
    reset()
    guard animateChanges, !reduceMotion, let old,
      let move = BoardTransition.between(old, snapshot)
    else { return }
    transition = move
    let identifier = animationID
    animationTask = Task { @MainActor in
      // Give the starting position a rendering pass before setting its target.
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, animationID == identifier else { return }
      withAnimation(.easeInOut(duration: 0.18)) { progress = 1 }
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, animationID == identifier else { return }
      transition = nil
    }
  }
}
