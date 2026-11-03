import SwiftUI
import UIKit

/// Pieces have no focus or hit targets; the underlying square buttons own input.
struct PieceBoardOverlay: View {
  let snapshot: Message
  let side: CGFloat
  var selectedSquare: Int?
  var animateChanges = true
  var resetToken = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    PieceLayerBoard(
      snapshot: snapshot, side: side, selectedSquare: selectedSquare,
      animateChanges: animateChanges && !reduceMotion, resetToken: resetToken
    )
    .frame(width: side, height: side)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct PieceLayerBoard: UIViewRepresentable {
  let snapshot: Message
  let side: CGFloat
  let selectedSquare: Int?
  let animateChanges: Bool
  let resetToken: String

  func makeUIView(context: Context) -> PieceLayerView { PieceLayerView() }
  func updateUIView(_ view: PieceLayerView, context: Context) {
    view.update(
      snapshot, side: side, selectedSquare: selectedSquare,
      animateChanges: animateChanges, resetToken: resetToken)
  }
  static func dismantleUIView(_ view: PieceLayerView, coordinator: ()) { view.clear() }
}

/// Animate layer properties in the compositor, without a SwiftUI update per frame.
/// Model positions always hold the latest board; presentation layers retain motion
/// across clock/confirmation updates and provide the origin of interrupted moves.
@MainActor final class PieceLayerView: UIView {
  private var previous: Message?
  private var pieces: [Int: CALayer] = [:]
  private var flights: [CALayer] = []
  private var images: [String: UIImage] = [:]
  private var side: CGFloat = 0
  private var resetToken = ""
  private var animating = false
  private var selected: Int?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isOpaque = false
    backgroundColor = .clear
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func clear() {
    for piece in pieces.values { piece.removeFromSuperlayer() }
    for flight in flights { flight.removeFromSuperlayer() }
    pieces = [:]
    flights = []
    previous = nil
  }

  func update(
    _ snapshot: Message, side: CGFloat, selectedSquare: Int?,
    animateChanges: Bool, resetToken: String
  ) {
    let old = previous
    let reset = self.side != side || self.resetToken != resetToken
      || animating != animateChanges || old?.gameId != snapshot.gameId
      || old?.generation != snapshot.generation || old?.boardOrientation != snapshot.boardOrientation
    let changed = old?.board != snapshot.board
    let transition = !reset && animateChanges
      ? old.flatMap { BoardTransition.presentationBetween($0, snapshot) } : nil
    self.side = side
    self.resetToken = resetToken
    animating = animateChanges

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if reset || (changed && transition == nil) { clear() }
    flights.removeAll { flight in
      if flight.animation(forKey: "capture") == nil {
        flight.removeFromSuperlayer()
        return true
      }
      return false
    }
    if let transition {
      let reversing = (snapshot.revision ?? 0) < (old?.revision ?? 0)
      if reversing {
        for flight in flights { flight.removeFromSuperlayer() }
        flights = []
      }
      let opponentCapture = transition.capturedSquare != nil
        && snapshot.playerColor != nil && old?.turn != snapshot.playerColor
      let duration = opponentCapture ? 0.35 : 0.18
      if let square = transition.capturedSquare, let victim = pieces.removeValue(forKey: square) {
        launch(
          victim, square: square, attacker: transition.moves.first!.from,
          color: snapshot.boardOrientation, delay: duration,
          duration: opponentCapture ? 1.75 : 1.25)
      }
      // Remove sources together, so castling can reuse both existing layers.
      let moving = transition.moves.map { ($0, pieces.removeValue(forKey: $0.from)) }
      for (move, existing) in moving {
        let piece = existing ?? makePiece(move.piece)
        let start = piece.presentation()?.position ?? center(move.from, color: snapshot.boardOrientation)
        let target = center(move.to, color: snapshot.boardOrientation)
        piece.removeAnimation(forKey: "move")
        piece.position = target
        piece.zPosition = 1
        let motion = CABasicAnimation(keyPath: "position")
        motion.fromValue = NSValue(cgPoint: start)
        motion.toValue = NSValue(cgPoint: target)
        motion.duration = duration
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        piece.add(motion, forKey: "move")
        pieces[move.to] = piece
        // The pawn travels first; its promoted artwork appears at arrival.
        if move.piece != move.resultPiece {
          let artwork = CABasicAnimation(keyPath: "contents")
          artwork.fromValue = image(move.piece).cgImage
          artwork.toValue = image(move.piece).cgImage
          artwork.duration = duration
          piece.add(artwork, forKey: "promotion")
        }
      }
    }
    if let board = snapshot.board {
      for square in 0..<min(64, board.count) {
        guard let code = board[square] else {
          pieces.removeValue(forKey: square)?.removeFromSuperlayer()
          continue
        }
        let piece = pieces[square] ?? makePiece(code)
        pieces[square] = piece
        piece.contents = image(code).cgImage
        piece.bounds = CGRect(x: 0, y: 0, width: side / 8, height: side / 8)
        piece.position = center(square, color: snapshot.boardOrientation)
        let isSelected = selectedSquare == square
        if selected != selectedSquare || reset || changed {
          let from = piece.presentation()?.transform ?? piece.transform
          piece.transform = CATransform3DMakeScale(isSelected ? 1.08 : 1, isSelected ? 1.08 : 1, 1)
          if animateChanges && !reset && (selected == square || isSelected) {
            let selection = CABasicAnimation(keyPath: "transform")
            selection.fromValue = NSValue(caTransform3D: from)
            selection.toValue = NSValue(caTransform3D: piece.transform)
            selection.duration = 0.15
            selection.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            piece.add(selection, forKey: "selection")
          }
          piece.shadowColor = UIColor.black.cgColor
          piece.shadowOpacity = isSelected ? 0.4 : 0
          piece.shadowRadius = side / 100
          piece.shadowOffset = CGSize(width: 0, height: side / 160)
        }
        piece.zPosition = isSelected || piece.animation(forKey: "move") != nil ? 1 : 0
      }
    }
    selected = selectedSquare
    previous = snapshot
  }

  private func image(_ code: String) -> UIImage {
    if let image = images[code] { return image }
    let prefix = Square.color(of: code) == .white ? "w" : "b"
    let image = UIImage(named: "chess-\(prefix)\(code.lowercased())") ?? UIImage()
    images[code] = image
    return image
  }
  private func makePiece(_ code: String) -> CALayer {
    let piece = CALayer()
    piece.contents = image(code).cgImage
    piece.contentsGravity = .resizeAspect
    piece.contentsScale = traitCollection.displayScale
    piece.bounds = CGRect(x: 0, y: 0, width: side / 8, height: side / 8)
    layer.addSublayer(piece)
    return piece
  }
  private func center(_ square: Int, color: PieceColor?) -> CGPoint {
    let index = Square.displayIndex(square, for: color)
    return CGPoint(x: (CGFloat(index % 8) + 0.5) * side / 8,
                   y: (CGFloat(index / 8) + 0.5) * side / 8)
  }
  private func launch(
    _ victim: CALayer, square: Int, attacker: Int, color: PieceColor?,
    delay: TimeInterval, duration: TimeInterval
  ) {
    let origin = center(square, color: color)
    let victimFile = Square.displayIndex(square, for: color) % 8
    let attackerFile = Square.displayIndex(attacker, for: color) % 8
    let direction: CGFloat = attackerFile == victimFile
      ? (victimFile < 4 ? -1 : 1) : (attackerFile < victimFile ? 1 : -1)
    victim.removeAllAnimations()
    victim.transform = CATransform3DIdentity
    victim.shadowOpacity = 0
    victim.zPosition = 10
    let motion = CAKeyframeAnimation(keyPath: "position")
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    let steps = 120
    motion.values = (0...steps).map { step in
      let t = CGFloat(step) / CGFloat(steps)
      return NSValue(cgPoint: CGPoint(
        x: origin.x + direction * side * 0.65 * t,
        y: origin.y + side * (-1.4 * t + 4 * t * t)))
    }
    scale.values = (0...steps).map { step in
      let t = CGFloat(step) / CGFloat(steps)
      return 1 + 0.2 * sin(min(t * 4, 1) * .pi)
    }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = direction * 6 * .pi
    for animation in [motion, scale, spin] { animation.duration = duration }
    let flight = CAAnimationGroup()
    flight.animations = [motion, scale, spin]
    flight.beginTime = CACurrentMediaTime() + delay
    flight.duration = duration
    flight.fillMode = .backwards
    flight.delegate = RemoveCapturedLayer(victim)
    victim.position = CGPoint(x: origin.x + direction * side * 0.65, y: origin.y + side * 2.6)
    victim.add(flight, forKey: "capture")
    flights.append(victim)
  }
}

@MainActor private final class RemoveCapturedLayer: NSObject, CAAnimationDelegate {
  private let layer: CALayer
  init(_ layer: CALayer) { self.layer = layer }
  nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
    Task { @MainActor in layer.removeFromSuperlayer() }
  }
}
