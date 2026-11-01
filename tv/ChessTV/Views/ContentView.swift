import SwiftUI

struct ContentView: View {
  let session: TVSession
  @AppStorage("showSquareLabels") private var showSquareLabels = true
  @State private var showConnection = false
  @State private var showSettings = false
  var body: some View {
    Group {
      if session.credential == nil {
        PairingView(session: session)
      } else {
        VStack(spacing: 20) {
          HStack {
            Text("Chess TV").font(.headline)
            Spacer()
            Button("Settings", systemImage: "gearshape") {
              showSettings = true
            }
            .font(.caption)
            Button("Connection", systemImage: "antenna.radiowaves.left.and.right") {
              showConnection = true
            }
            .font(.caption)
          }.focusSection()
          if let snapshot = session.snapshot {
            BoardView(session: session, snapshot: snapshot, showSquareLabels: showSquareLabels)
          } else {
            Spacer()
            Image(systemName: "checkerboard.rectangle").font(.system(size: 80)).accessibilityHidden(
              true)
            Text("Waiting for a game").font(.title)
            Text(session.statusText).multilineTextAlignment(.center)
            Spacer()
          }
        }.padding(.horizontal, 32).padding(.vertical, 16)
      }
    }
    .sheet(isPresented: $showSettings) {
      BoardSettingsView(showSquareLabels: $showSquareLabels)
    }
    .sheet(isPresented: $showConnection) {
      VStack(spacing: 30) {
        Text("Connection").font(.title)
        Text(session.statusText).multilineTextAlignment(.center)
        Button("Reconnect relay") {
          session.reconnect()
          showConnection = false
        }.disabled(session.busy)
        Button("Unpair", role: .destructive) { session.unpair() }.disabled(session.busy)
        Button("Done") { showConnection = false }
      }.padding(80)
    }
    .onChange(of: session.credential) { _, value in if value == nil { showConnection = false } }
  }
}

private struct BoardSettingsView: View {
  @Binding var showSquareLabels: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 30) {
      Text("Settings").font(.title)
      Toggle("Show square labels", isOn: $showSquareLabels)
      Text("Display coordinates such as a1 and e4 on the board.")
        .font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Done") { dismiss() }
    }
    .frame(maxWidth: 700)
    .padding(80)
  }
}
