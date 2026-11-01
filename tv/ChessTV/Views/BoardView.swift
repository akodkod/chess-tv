import SwiftUI

struct BoardView: View {
  let session: TVSession
  let snapshot: Message
  var showSquareLabels = true
  var edgeSquareLabelsOnly = true
  @State private var source: Int?
  @State private var promotionTarget: Int?
  @State private var promotionSource: Int?
  @State private var restoreFocus: Int?
  @FocusState private var focused: Int?
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.height - 116, geometry.size.width - 380)
      HStack(alignment: .center, spacing: 36) {
        VStack(spacing: 10) {
          playerLine(snapshot.playerColor == .black ? .white : .black)
          grid(side: max(240, side))
          playerLine(snapshot.playerColor == .black ? .black : .white)
        }.frame(width: max(240, side))
        VStack(alignment: .leading, spacing: 24) {
          if let result = snapshot.result {
            Text(result.label).font(.title.bold())
          } else {
            Text(snapshot.turn.map { "\($0.rawValue.capitalized) to move" } ?? "Turn unknown").font(
              .title2.bold())
          }
          Text(session.statusText).font(.body)
          if let notice = session.moveNotice { Text(notice).font(.callout) }
          if session.clocksStale {
            Label("Clocks paused", systemImage: "pause.circle").font(.caption)
          }
          if source != nil {
            Text("Select a destination. Back cancels.").font(.caption).foregroundStyle(.secondary)
          } else if session.canMove {
            Text("Select a piece, then its destination.").font(.caption).foregroundStyle(.secondary)
          }
          if session.needsReconnect { Button("Reconnect relay") { session.reconnect() } }
        }.frame(width: 340, alignment: .leading)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // Include the side panel so Down from Connection can reach the board,
    // even though the button isn't horizontally aligned with a square.
    .focusSection()
    .task {
      // A game can arrive while Connection already owns focus. Hand focus to
      // the board once on appearance, without resetting it on snapshot updates.
      focused = Square.index(snapshot.playerColor == .black ? "e7" : "e2")
    }
    .sheet(
      isPresented: Binding(
        get: { promotionTarget != nil }, set: { if !$0 { promotionTarget = nil } }),
      onDismiss: {
        focused = restoreFocus
        promotionSource = nil
      }
    ) {
      VStack(spacing: 32) {
        Text("Promote pawn").font(.title)
        HStack(spacing: 24) {
          ForEach(["q", "r", "b", "n"], id: \.self) { piece in
            Button(["q": "Queen", "r": "Rook", "b": "Bishop", "n": "Knight"][piece]!) {
              if let from = promotionSource, let to = promotionTarget {
                session.submit(from: from, to: to, promotion: piece)
              }
              promotionTarget = nil
              source = nil
            }
          }
        }
        Button("Cancel", role: .cancel) { promotionTarget = nil }
      }.padding(64)
    }
    .onChange(of: session.selectionContext) { _, _ in
      source = nil
      promotionTarget = nil
    }
    .onExitCommand(perform: source != nil && promotionTarget == nil ? { source = nil } : nil)
  }
  private func playerLine(_ color: PieceColor) -> some View {
    let avatar = color == .white ? snapshot.players?.whiteAvatar : snapshot.players?.blackAvatar
    return HStack(spacing: 12) {
      AsyncImage(url: avatar.flatMap(URL.init(string:))) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          Image(systemName: "person.crop.square.fill")
            .resizable().scaledToFit().foregroundStyle(.secondary)
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)
      Text(
        (color == .white ? snapshot.players?.white : snapshot.players?.black)
          ?? "\(color.rawValue.capitalized) player"
      )
      .lineLimit(1).minimumScaleFactor(0.8)
      Spacer()
      if let remaining = session.clockReading?.remaining(color, now: session.now) {
        Text(ClockReading.format(remaining))
          .monospacedDigit().font(.title3).frame(minWidth: 100, alignment: .trailing)
          .accessibilityLabel("\(color.rawValue.capitalized) clock")
          .accessibilityValue(ClockReading.format(remaining))
      }
    }.font(.headline)
  }
  private func grid(side: CGFloat) -> some View {
    let order = Square.order(for: snapshot.playerColor)
    return VStack(spacing: 0) {
      ForEach(0..<8) { row in
        HStack(spacing: 0) {
          ForEach(Array(order[(row * 8)..<(row * 8 + 8)]), id: \.self) { index in
            square(index, size: side / 8)
          }
        }
      }
    }.frame(width: side, height: side)
      .background { Image("chess-walnut").resizable().frame(width: side, height: side) }
      .overlay {
        PieceBoardOverlay(
          snapshot: snapshot, side: side,
          selectedSquare: source,
          animateChanges: session.active && session.authenticated && session.peerConnected,
          resetToken: String(session.presentationEpoch))
      }
  }
  private func square(_ index: Int, size: CGFloat) -> some View {
    let piece = snapshot.board?[index]
    let selected = source == index
    let pending = session.pending?.to == Square.name(index)
    let isFocused = focused == index
    let light = (index / 8 + index % 8).isMultiple(of: 2)
    return Button {
      select(index)
    } label: {
      ZStack(alignment: .topLeading) {
        Rectangle().fill(
          selected ? Color.yellow.opacity(contrast == .increased ? 0.38 : 0.22) : Color.clear)
        if showSquareLabels {
          squareLabels(index, size: size, light: light)
        }
        if pending {
          Image(systemName: "hourglass")
            .font(.system(size: size * 0.22)).foregroundStyle(.black, .yellow)
            .frame(width: size - 8, height: size - 8, alignment: .bottomTrailing)
        }
        Rectangle().strokeBorder(
          isFocused ? Color.white : selected || pending ? Color.yellow : Color.clear,
          lineWidth: isFocused ? (contrast == .increased ? 7 : 5) : 4)
      }.frame(width: size, height: size)
    }
    .buttonStyle(BoardSquareButtonStyle()).focused($focused, equals: index)
    .accessibilityLabel("\(Square.name(index)), \(Square.pieceName(piece))")
    .accessibilityValue(selected ? "Selected" : pending ? "Move pending" : "")
    .accessibilityHint(session.canMove ? "Select piece or destination" : "Move input unavailable")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
  @ViewBuilder private func squareLabels(_ index: Int, size: CGFloat, light: Bool) -> some View {
    let displayIndex = snapshot.playerColor == .black ? 63 - index : index
    let name = Square.name(index)
    ZStack(alignment: .topLeading) {
      if edgeSquareLabelsOnly {
        if displayIndex % 8 == 0 {
          Text(String(name.suffix(1)))
            .padding(6).frame(width: size, height: size, alignment: .topLeading)
        }
        if displayIndex / 8 == 7 {
          Text(String(name.prefix(1)))
            .padding(6).frame(width: size, height: size, alignment: .bottomTrailing)
        }
      } else {
        Text(name).padding(4).offset(x: 4)
      }
    }
    .font(.system(size: max(12, size * 0.17) - 1, weight: .regular))
    .foregroundStyle(light ? Color.black : Color.white)
    .opacity(edgeSquareLabelsOnly ? 0.65 : 0.3)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
  private func select(_ index: Int) {
    guard session.canMove, let board = snapshot.board else { return }
    if source == index {
      source = nil
      return
    }
    if Square.color(of: board[index]) == snapshot.playerColor {
      source = index
      return
    }
    guard let from = source else { return }
    if Square.promotion(piece: board[from], destination: index) {
      promotionSource = from
      promotionTarget = index
      restoreFocus = index
    } else {
      session.submit(from: from, to: index)
      source = nil
    }
  }
}

// Even the plain tvOS button style adds system focus chrome around its label.
// Squares draw their own inset focus and selection borders, so keep the label's
// exact bounds and provide press feedback without lifting it above its neighbors.
private struct BoardSquareButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}
