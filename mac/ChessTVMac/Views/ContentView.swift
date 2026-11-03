import SwiftUI
import WebKit

struct BrowserView: NSViewRepresentable {
  let browser: ChessBrowser
  func makeNSView(context: Context) -> WKWebView { browser.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}

struct ContentView: View {
  let browser: ChessBrowser
  let session: MacSession?
  let startupError: String?
  @State private var showPairing = false
  @State private var confirmUnpair = false

  private var message: String {
    startupError ?? browser.loadError ?? session?.error
      ?? (browser.loading ? "Loading Chess.com…" : session?.status ?? "Open a game on Chess.com")
  }
  var body: some View {
    VStack(spacing: 0) {
      BrowserView(browser: browser)
      Divider()
      HStack(spacing: 8) {
        Circle()
          .fill(session?.available == true ? Color.green : Color.secondary.opacity(0.5))
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(1).help(message)
        Spacer(minLength: 8)
        Menu {
          if let session {
            Button(session.pairing ? "Pairing…" : "Pair TV…") { showPairing = true }
              .disabled(session.paired)
            Divider()
            Button("Connect / Reconnect Game") { session.reconnectGame() }
              .disabled(!session.paired)
            Button("Disconnect Game") { session.disconnectGame() }
              .disabled(!session.paired)
            Button("Reconnect Relay") { session.reconnectRelay() }
              .disabled(!session.paired)
            Divider()
            Button("Unpair TV…") { confirmUnpair = true }
              .disabled(!session.paired && !session.pairing)
          }
          Button("Reload Page") { browser.webView.reload() }
        } label: { Image(systemName: "ellipsis").frame(width: 18) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Connection options")
      }
      .padding(.horizontal, 12).frame(height: 30)
      .background(.bar)
    }
    .sheet(isPresented: $showPairing) {
      if let session { PairingSheet(session: session) }
    }
    .confirmationDialog("Unpair this TV?", isPresented: $confirmUnpair) {
      Button("Unpair TV", role: .destructive) { session?.unpair() }
    } message: { Text("You can pair again using a new code from your TV.") }
  }
}
