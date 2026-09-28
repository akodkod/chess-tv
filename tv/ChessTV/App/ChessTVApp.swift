import SwiftUI

@main struct ChessTVApp: App {
  var body: some Scene { WindowGroup { AppRoot() } }
}

private struct AppRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var session: TVSession?
  @State private var configurationError: String?
  var body: some View {
    Group {
      if let session {
        ContentView(session: session)
      } else {
        VStack(spacing: 24) {
          Text("Chess TV").font(.largeTitle)
          Text(configurationError ?? "Starting…").multilineTextAlignment(.center)
        }.padding(80)
      }
    }
    .task {
      guard session == nil else { return }
      do {
        let model = TVSession(configuration: try .bundled())
        session = model
        model.setActive(scenePhase == .active)
      } catch { configurationError = error.localizedDescription }
    }
    .onChange(of: scenePhase) { _, phase in session?.setActive(phase == .active) }
  }
}
