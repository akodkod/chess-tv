import SwiftUI

enum BoardHighlightColor: String, CaseIterable {
  case yellow, green, blue, purple, orange

  func tint(lightSquare: Bool) -> Color {
    switch self {
    case .yellow: lightSquare ? Color(red: 0.72, green: 0.52, blue: 0.06) : .yellow
    case .green: lightSquare ? Color(red: 0.12, green: 0.55, blue: 0.22) : .green
    case .blue: lightSquare ? Color(red: 0.08, green: 0.38, blue: 0.85) : .cyan
    case .purple: lightSquare ? Color(red: 0.52, green: 0.20, blue: 0.75) : .purple
    case .orange: lightSquare ? Color(red: 0.85, green: 0.35, blue: 0.04) : .orange
    }
  }
}

struct BoardView: View {
  let session: TVSession
  let snapshot: Snapshot
  var showSquareLabels = true
  var edgeSquareLabelsOnly = true
  var lastMoveColor = BoardHighlightColor.yellow
  var selectedSquareColor = BoardHighlightColor.yellow
  var onSettings: () -> Void
  var settingsPanel: AnyView? = nil

  private var settingsOpen: Bool { settingsPanel != nil }
  @State private var source: Int?
  @State private var promotionTarget: Int?
  @State private var promotionSource: Int?
  @State private var restoreFocus: Int?
  @FocusState private var focused: Int?
  @FocusState private var settingsFocused: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let panelWidth: CGFloat = settingsOpen ? 560 : 340
      let side = min(geometry.size.height - 116, geometry.size.width - panelWidth - 64)
      HStack(alignment: .center, spacing: 64) {
        VStack(spacing: 10) {
          playerLine(snapshot.boardOrientation == .black ? .white : .black)
          grid(side: max(240, side))
            .zIndex(1)
          playerLine(snapshot.boardOrientation == .black ? .black : .white)
        }.frame(width: max(240, side))
          .zIndex(1)
        Group {
          if let settingsPanel {
            settingsPanel
          } else {
            gamePanel
          }
        }
        .frame(width: panelWidth, height: max(240, side), alignment: .leading)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: settingsOpen)
    }
    // Group the board and side-panel controls for remote focus navigation.
    .focusSection()
    .task {
      guard !settingsOpen else { return }
      if snapshot.playerColor != nil {
        focused = Square.index(snapshot.boardOrientation == .black ? "e7" : "e2")
      } else {
        settingsFocused = true
      }
    }
    .onChange(of: focused) { _, square in
      if square != nil && !settingsOpen { session.revealBoardCursor() }
    }
    .onChange(of: session.lastVoiceMoveCommandID) { _, _ in
      source = nil
      promotionTarget = nil
    }
    .onChange(of: settingsOpen) { _, open in
      focused = nil
      source = nil
      if !open { settingsFocused = true }
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
          ForEach(Promotion.allCases, id: \.self) { piece in
            Button(piece.label) {
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
      if !settingsOpen && snapshot.playerColor == nil && focused != nil {
        focused = nil
        settingsFocused = true
      }
    }
    .onExitCommand(perform: !settingsOpen && source != nil && promotionTarget == nil ? { source = nil } : nil)
  }
  private var gamePanel: some View {
    VStack(alignment: .leading, spacing: 32) {
      VStack(alignment: .leading, spacing: 20) {
        Button("Settings", systemImage: "gearshape", action: onSettings)
          .controlSize(.small)
          .font(.caption2)
          .focused($settingsFocused)
      }
      .font(.caption)
      .focusSection()
      Spacer(minLength: 24)
      statusSnapshots
      Group {
        if session.isReviewing {
          Text(
            "\(session.movesBehindLive) \(session.movesBehindLive == 1 ? "move" : "moves") ago"
          )
          .font(.title2.weight(.semibold))
        } else if let result = snapshot.result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.title(for: snapshot.playerColor))
            Text(result.detail(reason: snapshot.resultReason, player: snapshot.playerColor))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
          }
          .font(.title2.weight(.semibold))
          .lineSpacing(2)
        } else {
          Text(snapshot.turn.map { "\($0.rawValue.capitalized)\nto move" } ?? "Turn\nunknown")
            .font(.title2.weight(.semibold))
            .lineSpacing(2)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 24) {
        Button("Previous move", systemImage: "chevron.left") { session.previousMove() }
          .disabled(!session.canGoBack)
        Button("Next move", systemImage: "chevron.right") { session.nextMove() }
          .disabled(!session.canGoForward)
      }
      .labelStyle(.iconOnly)
      .font(.caption)
      .focusSection()
    }
  }

  private var statusSnapshots: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        if let warning = session.gameplayWarning.flatMap(messageText) {
          Text(warning).font(.callout)
        }
        if let notice = session.moveNotice.flatMap(messageText) { Text(notice).font(.callout) }
        if !session.isReviewing && session.clocksStale && snapshot.result == nil {
          Label("Clocks paused", systemImage: "pause.circle").font(.caption)
        }
      }
      .fontWeight(.regular)
      .foregroundStyle(.secondary)
      if session.needsReconnect { Button("Reconnect relay") { session.reconnect() } }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 340, alignment: .leading)
  }
  private func messageText(_ message: String) -> String? {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    // These transient observation states need no action from the TV player.
    if text == "Board is animating. Inspect again."
      || text == "Wait for board animation to finish, then inspect again."
    {
      return nil
    }
    return text.displayText
  }

  private func playerLine(_ color: PieceColor) -> some View {
    let avatar = color == .white ? snapshot.players.whiteAvatar : snapshot.players.blackAvatar
    return HStack(spacing: 12) {
      AsyncImage(url: avatar.flatMap(URL.init(string:))) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          Image(color == .white ? "chess-wp" : "chess-bp")
            .resizable().scaledToFit()
            .shadow(color: .white.opacity(0.25), radius: 16)
        }
      }
      .frame(width: 44, height: 44)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityHidden(true)
      Text(
        (color == .white ? snapshot.players.white : snapshot.players.black)
          ?? "\(color.rawValue.capitalized) player"
      )
      .lineLimit(1).minimumScaleFactor(0.8)
      Spacer()
      if !session.isReviewing,
        let remaining = session.clockReading?.displayedRemaining(color, now: session.now)
      {
        Text(ClockReading.format(remaining))
          .monospacedDigit().font(.headline).frame(minWidth: 100, alignment: .trailing)
          .accessibilityLabel("\(color.rawValue.capitalized) clock")
          .accessibilityValue(ClockReading.format(remaining))
      }
    }.font(.headline)
  }
  private func grid(side: CGFloat) -> some View {
    let order = Square.order(for: snapshot.boardOrientation)
    let opponentMove = session.displayedOpponentMove
    return VStack(spacing: 0) {
      ForEach(0..<8) { row in
        HStack(spacing: 0) {
          ForEach(Array(order[(row * 8)..<(row * 8 + 8)]), id: \.self) { index in
            square(index, size: side / 8, opponentMove: opponentMove)
          }
        }
      }
    }.frame(width: side, height: side)
      .background { BoardFocusRegion() }
      .background { Image("chess-walnut").resizable().frame(width: side, height: side) }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        PieceBoardOverlay(
          snapshot: snapshot, side: side,
          selectedSquare: source,
          animateChanges: session.active && session.authenticated && session.peerConnected,
          resetToken: String(session.presentationEpoch))
      }
  }
  private func square(
    _ index: Int, size: CGFloat, opponentMove: BoardTransition.Movement?
  ) -> some View {
    let piece = snapshot.board[index]
    let selected = source == index
    let checked = snapshot.checkSquare == Square.name(index)
    let lastMove = opponentMove?.from == index || opponentMove?.to == index
    let destination =
      session.canMove
      && source.map { from in
        snapshot.legalMoves.contains {
          $0.from == Square.name(from) && $0.to == Square.name(index)
        } == true
      } == true
    let isFocused = focused == index && !session.boardCursorHidden
    let light = (index / 8 + index % 8).isMultiple(of: 2)
    let highlightColor = selectedSquareColor.tint(lightSquare: light)
    let highlightOpacity =
      contrast == .increased
      ? (light ? 0.55 : 0.52) : 0.40
    return Button {
      select(index)
    } label: {
      ZStack(alignment: .topLeading) {
        if lastMove {
          Rectangle().fill(
            lastMoveColor.tint(lightSquare: light).opacity(contrast == .increased ? 0.42 : 0.26))
        }
        if checked {
          Rectangle().fill(Color.red.opacity(contrast == .increased ? 0.85 : 0.65))
        }
        Rectangle().fill(
          selected || isFocused
            ? highlightColor.opacity(highlightOpacity) : Color.clear)
        if showSquareLabels {
          squareLabels(index, size: size, light: light)
        }
        if destination {
          LegalMoveMarker(size: size, capture: piece != nil, lightSquare: light)
        }
      }.frame(width: size, height: size)
    }
    .buttonStyle(BoardSquareButtonStyle()).focused($focused, equals: index)
    .disabled(settingsOpen || snapshot.playerColor == nil)
    .accessibilityLabel("\(Square.name(index)), \(Square.pieceName(piece))")
    .accessibilityValue(
      [
        selected ? "Selected" : nil, destination ? "Legal destination" : nil,
        checked ? "In check" : nil,
        opponentMove?.from == index ? "Opponent's last move, starting square" : nil,
        opponentMove?.to == index ? "Opponent's last move, ending square" : nil,
      ]
      .compactMap { $0 }.joined(separator: ", ")
    )
    .accessibilityHint(session.canMove ? "Select piece or destination" : "Move input unavailable")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
  @ViewBuilder private func squareLabels(_ index: Int, size: CGFloat, light: Bool) -> some View {
    let displayIndex = Square.displayIndex(index, for: snapshot.boardOrientation)
    let name = Square.name(index)
    Group {
      if edgeSquareLabelsOnly {
        ZStack {
          if displayIndex % 8 == 0 {
            Text(String(name.suffix(1)))
              .padding(6)
              .frame(width: size, height: size, alignment: .topLeading)
          }
          if displayIndex / 8 == 7 {
            Text(String(name.prefix(1)))
              .padding(6)
              .frame(width: size, height: size, alignment: .bottomTrailing)
          }
        }
        .font(.system(size: max(12, size * 0.20), weight: .bold))
      } else {
        Text(name.uppercased())
          .font(.system(size: max(11, size * 0.15), weight: .semibold))
          .padding(6)
          .frame(width: size, height: size, alignment: .topTrailing)
      }
    }
    .foregroundStyle(light
      ? Color(red: 0.22, green: 0.16, blue: 0.10)
      : Color(red: 0.86, green: 0.79, blue: 0.66))
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
  private func select(_ index: Int) {
    session.revealBoardCursor()
    guard session.canMove else { return }
    let board = snapshot.board
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
// Squares draw their own focus and selection tint, so keep the label's
// exact bounds and provide press feedback without lifting it above its neighbors.
private struct BoardSquareButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

/// Insets keep capture rings visible around the piece artwork.
struct LegalMoveMarker: View {
  let size: CGFloat
  let capture: Bool
  var lightSquare = true
  var body: some View {
    if capture {
      Circle().strokeBorder(
        Color.black.opacity(lightSquare ? 0.24 : 0.30), lineWidth: size * 0.075
      )
      .padding(size * 0.13)
    } else {
      Circle().fill(Color.black.opacity(0.25))
        .frame(width: size * 0.24, height: size * 0.24)
        .frame(width: size, height: size)
    }
  }
}
