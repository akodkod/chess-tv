import SwiftUI

enum SettingsPage: String {
  case settings, volume, capture, lastMove, selectedSquare, connection

  var title: String {
    switch self {
    case .settings: "Settings"
    case .volume: "Sound level"
    case .capture: "Capture sound"
    case .lastMove: "Last move color"
    case .selectedSquare: "Selected square color"
    case .connection: "Connection"
    }
  }
}

struct ContentView: View {
  let session: TVSession
  @AppStorage("showSquareLabels") private var showSquareLabels = true
  @AppStorage("edgeSquareLabelsOnly") private var edgeSquareLabelsOnly = true
  @AppStorage("soundsEnabled") private var soundsEnabled = true
  @AppStorage("soundVolume") private var soundVolume = 1.0
  @AppStorage("captureSound") private var captureSound = CaptureSound.classic
  @AppStorage("lastMoveColor") private var lastMoveColor = BoardHighlightColor.yellow
  @AppStorage("selectedSquareColor") private var selectedSquareColor = BoardHighlightColor.yellow
  @State private var settingsPage: SettingsPage?
  @FocusState private var waitingSettingsFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if session.credential == nil {
        PairingView(session: session)
      } else {
        Group {
          if let snapshot = session.displayedSnapshot {
            BoardView(
              session: session, snapshot: snapshot, showSquareLabels: showSquareLabels,
              edgeSquareLabelsOnly: edgeSquareLabelsOnly,
              lastMoveColor: lastMoveColor, selectedSquareColor: selectedSquareColor,
              onSettings: { settingsPage = .settings },
              settingsPanel: settingsPage == nil ? nil : AnyView(settingsPanel))
          } else {
            GeometryReader { geometry in
              let panelWidth: CGFloat = settingsPage != nil ? 560 : 340
              let side = max(240, min(geometry.size.height - 116, geometry.size.width - panelWidth - 64))
              HStack(spacing: 64) {
                VStack(spacing: 24) {
                  Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 80)).accessibilityHidden(true)
                  Text("Waiting for a game").font(.title)
                  Text(session.statusText.displayText).multilineTextAlignment(.center)
                }.frame(width: side)
                Group {
                  if settingsPage != nil {
                    settingsPanel
                  } else {
                    VStack {
                      Button("Settings", systemImage: "gearshape") { settingsPage = .settings }
                        .focused($waitingSettingsFocused)
                      Spacer()
                    }.font(.caption)
                  }
                }.frame(width: panelWidth, height: side, alignment: .topLeading)
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: settingsPage != nil)
            }
          }
        }.padding(.horizontal, 32).padding(.vertical, 16)
      }
    }
    .onChange(of: settingsPage) { _, page in
      if page == nil && session.displayedSnapshot == nil { waitingSettingsFocused = true }
    }
    .onChange(of: session.credential) { _, value in
      if value == nil { settingsPage = nil }
    }
    .onChange(of: soundsEnabled, initial: true) { _, value in session.setSoundsEnabled(value) }
    .onChange(of: soundVolume, initial: true) { _, value in session.setSoundVolume(value) }
    .onChange(of: captureSound, initial: true) { _, value in session.setCaptureSound(value) }
  }

  private var settingsPanel: some View {
    BoardSettingsView(
      session: session, page: $settingsPage,
      showSquareLabels: $showSquareLabels, edgeSquareLabelsOnly: $edgeSquareLabelsOnly,
      soundsEnabled: $soundsEnabled, soundVolume: $soundVolume, captureSound: $captureSound,
      lastMoveColor: $lastMoveColor, selectedSquareColor: $selectedSquareColor)
  }
}

struct BoardSettingsView: View {
  let session: TVSession
  @Binding var page: SettingsPage?
  @Binding var showSquareLabels: Bool
  @Binding var edgeSquareLabelsOnly: Bool
  @Binding var soundsEnabled: Bool
  @Binding var soundVolume: Double
  @Binding var captureSound: CaptureSound
  @Binding var lastMoveColor: BoardHighlightColor
  @Binding var selectedSquareColor: BoardHighlightColor
  @FocusState private var focusedRow: String?
  @State private var returnRow = "labels"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(page?.title ?? "Settings").font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Button(action: goBack) {
              Label(page == .settings ? "Back to game" : "Back", systemImage: "chevron.left")
                .frame(maxWidth: .infinity, alignment: .leading)
            }.focused($focusedRow, equals: "back").id("back")
            pageContents
          }.padding(16)
        }
        .task(id: page) {
          // Wait for the destination's controls to join the focus tree.
          await Task.yield()
          guard !Task.isCancelled else { return }
          let target = initialFocus
          proxy.scrollTo(target, anchor: .center)
          focusedRow = target
        }
      }
    }
    .font(.caption)
    .multilineTextAlignment(.leading)
    .buttonStyle(.bordered)
    .focusSection()
    .onExitCommand(perform: goBack)
  }

  @ViewBuilder private var pageContents: some View {
    switch page {
    case .settings:
      sectionTitle("Board")
      toggleRow("Show square labels", value: $showSquareLabels, id: "labels")
      toggleRow("Labels on board edges only", value: $edgeSquareLabelsOnly, id: "edges")
        .disabled(!showSquareLabels)
      navigationRow(.lastMove, value: lastMoveColor.rawValue.capitalized, color: lastMoveColor)
      navigationRow(.selectedSquare, value: selectedSquareColor.rawValue.capitalized,
        color: selectedSquareColor)
      sectionTitle("Sound")
      toggleRow("Game sounds", value: $soundsEnabled, id: "sounds")
      navigationRow(.volume, value: "\(Int((soundVolume * 100).rounded()))%")
        .disabled(!soundsEnabled)
      navigationRow(.capture, value: captureSound.title)
      sectionTitle("Connection")
      navigationRow(.connection)
    case .volume:
      ForEach(0...10, id: \.self) { level in
        choiceRow("\(level * 10)%", selected: abs(soundVolume - Double(level) / 10) < 0.001,
          id: "volume-\(level)") { soundVolume = Double(level) / 10 }
      }
    case .capture:
      ForEach(CaptureSound.allCases, id: \.self) { sound in
        choiceRow(sound.title, selected: captureSound == sound, id: sound.rawValue) {
          guard captureSound != sound else { return }
          captureSound = sound
          // Set first so preview never uses the previous selection. Restoring preferences stays silent.
          session.setCaptureSound(sound)
          session.previewCaptureSound()
        }
      }
    case .lastMove:
      colorChoices(selection: $lastMoveColor)
    case .selectedSquare:
      colorChoices(selection: $selectedSquareColor)
    case .connection:
      Text(session.statusText.displayText)
        .fixedSize(horizontal: false, vertical: true)
      Button("Reconnect relay") { session.reconnect() }
        .focused($focusedRow, equals: "reconnect").id("reconnect")
        .disabled(session.busy)
      Button("Unpair", role: .destructive) { session.unpair() }
        .disabled(session.busy)
    case nil:
      EmptyView()
    }
  }

  private var initialFocus: String {
    switch page {
    case .settings: returnRow
    case .volume: "volume-\(Int((soundVolume * 10).rounded()))"
    case .capture: captureSound.rawValue
    case .lastMove: lastMoveColor.rawValue
    case .selectedSquare: selectedSquareColor.rawValue
    case .connection, nil: "back"
    }
  }

  private func goBack() {
    if let page, page != .settings {
      returnRow = page.rawValue
      self.page = .settings
    } else {
      page = nil
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
      .padding(.top, 8).accessibilityAddTraits(.isHeader)
  }

  private func toggleRow(_ title: String, value: Binding<Bool>, id: String) -> some View {
    Toggle(isOn: value) {
      Text(title).multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }.focused($focusedRow, equals: id).id(id)
  }

  private func navigationRow(
    _ destination: SettingsPage, value: String? = nil, color: BoardHighlightColor? = nil
  ) -> some View {
    Button { page = destination } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(destination.title).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          if let value {
            HStack(spacing: 8) {
              if let color { swatch(color) }
              Text(value).foregroundStyle(.secondary)
            }
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").accessibilityHidden(true)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.focused($focusedRow, equals: destination.rawValue).id(destination.rawValue)
  }

  private func colorChoices(selection: Binding<BoardHighlightColor>) -> some View {
    ForEach(BoardHighlightColor.allCases, id: \.self) { color in
      choiceRow(color.rawValue.capitalized, selected: selection.wrappedValue == color,
        id: color.rawValue, color: color) { selection.wrappedValue = color }
    }
  }

  private func choiceRow(
    _ title: String, selected: Bool, id: String, color: BoardHighlightColor? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if let color { swatch(color) }
        Text(title).multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Image(systemName: "checkmark").opacity(selected ? 1 : 0).accessibilityHidden(true)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .focused($focusedRow, equals: id).id(id)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func swatch(_ color: BoardHighlightColor) -> some View {
    Circle().fill(color.tint(lightSquare: false)).frame(width: 20, height: 20)
      .accessibilityHidden(true)
  }
}
