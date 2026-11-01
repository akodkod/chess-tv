import SwiftUI

/// Pieces have no focus or hit targets; the underlying square buttons own input.
struct PieceBoardOverlay: View {
  let snapshot: Message
  let side: CGFloat
  var selectedSquare: Int?
  var animateChanges = true
  var resetToken = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var captures: [CaptureFlight] = []
  @State private var previous: Message?
  @State private var transition: BoardTransition?
  @State private var progress: CGFloat = 0
  @State private var animationTask: Task<Void, Never>?
  @State private var animationID = UUID()

  private struct CaptureFlight: Identifiable {
    let id = UUID()
    let piece: String
    let square: Int
    let direction: CGFloat
    let launch: Date
    let duration: TimeInterval
  }

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
            .scaleEffect(selectedSquare == index ? 1.08 : 1, anchor: .center)
            .shadow(
              color: .black.opacity(selectedSquare == index ? 0.4 : 0),
              radius: selectedSquare == index ? side / 100 : 0,
              x: 0, y: selectedSquare == index ? side / 160 : 0
            )
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
      ForEach(captures) { capture in
        TimelineView(.animation) { context in
          let t = CGFloat(max(0, min(1, context.date.timeIntervalSince(capture.launch) / capture.duration)))
          let origin = center(capture.square)
          // Ballistic motion: a sharp upward kick, then gravity wins spectacularly.
          pieceImage(capture.piece)
            .scaleEffect(1 + 0.2 * sin(min(t * 4, 1) * .pi))
            .rotationEffect(.degrees(Double(capture.direction * 1080 * t)))
            .position(
              x: origin.x + capture.direction * side * 0.65 * t,
              y: origin.y + side * (-1.4 * t + 4 * t * t))
        }
        .zIndex(10)
        .task {
          let remaining = max(0, capture.launch.timeIntervalSinceNow + capture.duration)
          try? await Task.sleep(for: .seconds(remaining))
          guard !Task.isCancelled else { return }
          captures.removeAll { $0.id == capture.id }
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
    .onDisappear { reset() }
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
  private func reset(clearCaptures: Bool = true) {
    animationTask?.cancel()
    animationID = UUID()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      transition = nil
      progress = 0
      if clearCaptures { captures = [] }
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
    let move = animateChanges && !reduceMotion
      ? old.flatMap { BoardTransition.presentationBetween($0, snapshot) } : nil
    let reversing = (snapshot.revision ?? 0) < (old?.revision ?? 0)
    // Consecutive moves may overlap in flight; resets and ambiguous jumps clear them.
    reset(clearCaptures: move == nil || reversing)
    guard let move else { return }
    transition = move
    let opponentCapture = move.capturedSquare != nil && snapshot.playerColor != nil
      && old?.turn != snapshot.playerColor
    let moveDuration = opponentCapture ? 0.35 : 0.18
    if let square = move.capturedSquare, let piece = old?.board?[square] {
      let displayed = Square.displayIndex(square, for: snapshot.playerColor)
      let victimFile = displayed % 8
      let attackerFile = move.moves.first.map {
        Square.displayIndex($0.from, for: snapshot.playerColor) % 8
      } ?? victimFile
      // Push away from the attacker's visible side, including on a flipped board.
      // Vertical approaches have no horizontal side; use the nearest edge.
      let direction: CGFloat = attackerFile == victimFile
        ? (victimFile < 4 ? -1 : 1) : (attackerFile < victimFile ? 1 : -1)
      captures.append(
        CaptureFlight(
          piece: piece, square: square, direction: direction,
          launch: Date().addingTimeInterval(moveDuration),
          duration: opponentCapture ? 1.75 : 1.25))
    }
    let identifier = animationID
    animationTask = Task { @MainActor in
      // Give the starting position a rendering pass before setting its target.
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, animationID == identifier else { return }
      withAnimation(.easeInOut(duration: moveDuration)) { progress = 1 }
      try? await Task.sleep(for: .seconds(moveDuration))
      guard !Task.isCancelled, animationID == identifier else { return }
      transition = nil
    }
  }
}
