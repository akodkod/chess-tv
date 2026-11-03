import SwiftUI

@main struct ChessTVMacApp: App {
  @State private var browser: ChessBrowser
  @State private var session: MacSession?
  @State private var startupError: String?

  init() {
    let browser = ChessBrowser()
    _browser = State(initialValue: browser)
    // Hosted tests provide their own stores and relay; never open the user's Keychain.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    do {
      #if DEBUG
        let allowLoopback = true
      #else
        let allowLoopback = false
      #endif
      let configuration = try RelayConfiguration(
        ProcessInfo.processInfo.environment["RELAY_URL"]
          ?? "https://chess-tv-relay.kodkod.me", allowLoopback: allowLoopback)
      let session = try MacSession(page: browser, socket: RelaySocket(),
        api: MacPairingAPI(api: PairingAPI(configuration: configuration)),
        store: MacStore(origin: configuration.origin.absoluteString), configuration: configuration)
      browser.onInvalidate = { [weak session] in session?.pageChanged() }
      _session = State(initialValue: session)
    } catch { _startupError = State(initialValue: error.localizedDescription) }
  }
  var body: some Scene {
    Window("Chess TV", id: "main") {
      ContentView(browser: browser, session: session, startupError: startupError)
        .frame(minWidth: 800, minHeight: 600)
        .task {
          if session != nil { browser.home() }
          session?.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          session?.stop()
        }
    }
    .defaultSize(width: 1100, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Navigate") {
        Button("Back") { browser.webView.goBack() }.keyboardShortcut("[")
        Button("Forward") { browser.webView.goForward() }.keyboardShortcut("]")
        Button("Home") { browser.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
        Button("Reload") { browser.webView.reload() }.keyboardShortcut("r")
      }
    }
  }
}
