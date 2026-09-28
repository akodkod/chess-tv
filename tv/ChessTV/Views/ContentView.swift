import SwiftUI

struct ContentView: View {
  let session: TVSession
  @State private var showConnection = false
  var body: some View {
    Group {
      if session.credential == nil {
        PairingView(session: session)
      } else {
        VStack(spacing: 20) {
          HStack {
            Text("Chess TV").font(.headline)
            Spacer()
            Button("Connection", systemImage: "antenna.radiowaves.left.and.right") {
              showConnection = true
            }
            .font(.caption)
          }
          if let snapshot = session.snapshot {
            BoardView(session: session, snapshot: snapshot)
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
