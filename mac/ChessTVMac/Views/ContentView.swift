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
  let voice: VoiceControl?
  let startupError: String?
  @State private var showPairing = false
  @State private var confirmUnpair = false

  private var message: String {
    startupError ?? browser.loadError ?? voice?.commandNotice ?? voice?.error ?? session?.error
      ?? (browser.loading ? "Loading Chess.com…" : session?.status ?? "Open a game on Chess.com")
  }
  var body: some View {
    BrowserView(browser: browser)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
          .allowsHitTesting(false)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
      .toolbar {
        if #available(macOS 26.0, *) {
          statusItem.sharedBackgroundVisibility(.hidden)
          ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
          statusItem
        }
        if #available(macOS 26.0, *) {
          ToolbarItem(placement: .primaryAction) {
            GlassEffectContainer(spacing: 0) {
              toolbarActions.buttonStyle(.plain)
            }
            .padding(.trailing, 4)
          }
          .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .primaryAction) {
            toolbarActions
          }
        }
      }
      .sheet(isPresented: $showPairing) {
        if let session { PairingSheet(session: session) }
      }
      .confirmationDialog("Unpair this TV?", isPresented: $confirmUnpair) {
        Button("Unpair TV", role: .destructive) { session?.unpair() }
      } message: { Text("You can pair again using a new code from your TV.") }
  }

  private var toolbarActions: some View {
    HStack(spacing: 6) {
      if let voice {
        Button { voice.toggle() } label: {
          Image(systemName: voice.enabled ? "mic.fill" : "mic.slash")
            .frame(width: 24, height: 24)
            .foregroundStyle(voice.enabled ? Color.accentColor : Color.secondary)
        }
        .modifier(ToolbarControlSurface())
        .disabled(voice.unavailableReason != nil)
        .help(voice.unavailableReason ?? (voice.enabled ? "Turn voice control off" : "Turn voice control on"))
        .accessibilityLabel("Voice control")
        .accessibilityValue(voice.enabled ? "On" : "Off")
      }
      Menu {
        if let session {
          if session.saved.revocationPending {
            Button("Retry Unpairing") { session.unpair() }
          } else if session.paired {
            if session.canConnectGame {
              Button(session.gameConnectionActionTitle) { session.reconnectGame() }
            }
            if session.canDisconnectGame {
              Button("Disconnect Game") { session.disconnectGame() }
            }
            if session.canReconnectRelay {
              Button("Reconnect Relay") { session.reconnectRelay() }
            }
            Button("Unpair TV…") { confirmUnpair = true }
          } else if session.pairing {
            Button("View Pairing Request…") { showPairing = true }
            Button("Cancel Pairing") { session.unpair() }
          } else {
            Button("Pair TV…") { showPairing = true }
          }
          // Local voice control can also need recovery without a paired TV.
          if !session.paired && session.canConnectGame {
            Button(session.gameConnectionActionTitle) { session.reconnectGame() }
          }
          Divider()
        }
        SettingsLink { Text("Voice Settings…") }
        Button("Reload Page") { browser.webView.reload() }
      } label: { Image(systemName: "ellipsis")
          .frame(width: 24, height: 24) }
      .menuStyle(.borderlessButton).menuIndicator(.hidden)
      .modifier(ToolbarControlSurface())
      .accessibilityLabel("Connection options")
    }
  }

  private var statusItem: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      HStack(spacing: 8) {
        Circle()
          .fill(session?.available == true ? Color.green : Color.secondary.opacity(0.5))
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
        Text(message)
          .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      }
      .frame(maxWidth: 420, alignment: .leading)
      .help(message)
      .accessibilityElement(children: .combine)
    }
  }

}

private struct ToolbarControlSurface: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .frame(width: 24, height: 24)
        .glassEffect(.regular.interactive(), in: Circle())
    } else {
      content
    }
  }
}
