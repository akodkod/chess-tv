import SwiftUI

struct ContentView: View {
  let session: TVSession
  @AppStorage("showSquareLabels") private var showSquareLabels = true
  @AppStorage("edgeSquareLabelsOnly") private var edgeSquareLabelsOnly = true
  @AppStorage("soundsEnabled") private var soundsEnabled = true
  @AppStorage("soundVolume") private var soundVolume = 1.0
  @AppStorage("captureSound") private var captureSound = CaptureSound.classic
  @AppStorage("lastMoveColor") private var lastMoveColor = BoardHighlightColor.yellow
  @AppStorage("selectedSquareColor") private var selectedSquareColor = BoardHighlightColor.yellow
  @State private var showConnection = false
  @State private var showSettings = false
  var body: some View {
    Group {
      if session.credential == nil {
        PairingView(session: session)
      } else {
        VStack(spacing: 20) {
          if let snapshot = session.displayedSnapshot {
            BoardView(
              session: session, snapshot: snapshot, showSquareLabels: showSquareLabels,
              edgeSquareLabelsOnly: edgeSquareLabelsOnly,
              lastMoveColor: lastMoveColor, selectedSquareColor: selectedSquareColor,
              onSettings: { showSettings = true }, onConnection: { showConnection = true })
          } else {
            HStack(spacing: 24) {
              Button("Settings", systemImage: "gearshape") { showSettings = true }
              Button("Connection", systemImage: "antenna.radiowaves.left.and.right") {
                showConnection = true
              }
            }.font(.caption).focusSection()
            Spacer()
            Image(systemName: "checkerboard.rectangle").font(.system(size: 80)).accessibilityHidden(
              true)
            Text("Waiting for a game").font(.title)
            Text(session.statusText.displayText).multilineTextAlignment(.center)
            Spacer()
          }
        }.padding(.horizontal, 32).padding(.vertical, 16)
      }
    }
    .sheet(isPresented: $showSettings) {
      BoardSettingsView(
        showSquareLabels: $showSquareLabels, edgeSquareLabelsOnly: $edgeSquareLabelsOnly,
        soundsEnabled: $soundsEnabled, soundVolume: $soundVolume, captureSound: $captureSound,
        previewCaptureSound: session.previewCaptureSound,
        lastMoveColor: $lastMoveColor, selectedSquareColor: $selectedSquareColor)
    }
    .sheet(isPresented: $showConnection) {
      VStack(spacing: 30) {
        Text("Connection").font(.title)
        Text(session.statusText.displayText).multilineTextAlignment(.center)
        Button("Reconnect relay") {
          session.reconnect()
          showConnection = false
        }.disabled(session.busy)
        Button("Unpair", role: .destructive) { session.unpair() }.disabled(session.busy)
        Button("Done") { showConnection = false }
      }.padding(80)
    }
    .onChange(of: session.credential) { _, value in if value == nil { showConnection = false } }
    .onChange(of: soundsEnabled, initial: true) { _, value in session.setSoundsEnabled(value) }
    .onChange(of: soundVolume, initial: true) { _, value in session.setSoundVolume(value) }
    .onChange(of: captureSound, initial: true) { _, value in session.setCaptureSound(value) }
  }
}

private struct BoardSettingsView: View {
  @Binding var showSquareLabels: Bool
  @Binding var edgeSquareLabelsOnly: Bool
  @Binding var soundsEnabled: Bool
  @Binding var soundVolume: Double
  @Binding var captureSound: CaptureSound
  var previewCaptureSound: () -> Void
  @Binding var lastMoveColor: BoardHighlightColor
  @Binding var selectedSquareColor: BoardHighlightColor
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(spacing: 30) {
        Text("Settings").font(.title)
        Toggle("Show square labels", isOn: $showSquareLabels)
        Toggle("Labels on board edges only", isOn: $edgeSquareLabelsOnly)
          .disabled(!showSquareLabels)
        Text("Show ranks along the left edge and files along the bottom edge")
          .font(.callout).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Toggle("Game sounds", isOn: $soundsEnabled)
        Picker("Sound level", selection: $soundVolume) {
          ForEach(0...10, id: \.self) { level in
            Text("\(level * 10)%").tag(Double(level) / 10)
          }
        }
        .disabled(!soundsEnabled)
        Picker("Capture sound", selection: $captureSound) {
          ForEach(CaptureSound.allCases, id: \.self) { sound in
            Text(sound.title).tag(sound)
          }
        }
        Button("Preview capture sound", systemImage: "speaker.wave.2", action: previewCaptureSound)
          .disabled(!soundsEnabled)
        highlightPicker("Last move color", selection: $lastMoveColor)
        highlightPicker("Selected square color", selection: $selectedSquareColor)
        Button("Done") { dismiss() }
      }
      .frame(maxWidth: 700)
      .padding(80)
      .frame(maxWidth: .infinity)
    }
  }

  private func highlightPicker(
    _ title: String, selection: Binding<BoardHighlightColor>
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(BoardHighlightColor.allCases, id: \.self) { color in
        HStack(spacing: 12) {
          Circle().fill(color.tint(lightSquare: false)).frame(width: 24, height: 24)
            .accessibilityHidden(true)
          Text(color.rawValue.capitalized)
        }.tag(color)
      }
    }
  }
}
