# Chess TV for macOS

A single Chess.com webview with a connection status bar. macOS 14 or later.

## Build and run

Install the repository's dependencies with `bun install --frozen-lockfile`, then run:

```sh
./mac/script/build_and_run.sh
```

Or open `mac/ChessTVMac.xcodeproj` and run the **ChessTVMac** scheme. The Xcode build phase bundles the existing TypeScript adapter with Vite+ for Safari 17; no Chrome extension is required. Xcode and Bun must be installed. The development app is signed locally; distribution and notarization are not configured.

The run script also accepts `--verify`, `--debug`, `--logs`, and `--telemetry`. The local Codex Run action invokes it.

## Connect your TV

1. Sign in to Chess.com inside the app. Its persistent WebKit profile is separate from your regular browser.
2. Request a code in the Apple TV app, then choose **… → Pair TV** on the Mac.
3. Enter the six-digit code and confirm on the TV.
4. Open a supported standard bot or online game. Attachment is automatic; online spectator games are view-only.

TV moves remain enabled when the Mac window is unfocused, covered, hidden, or minimized. Keep the app running and the Mac awake. A Mac-only animation callback fallback keeps Chess.com board updates progressing while WebKit hides the page. The adapter still requires board/history confirmation and never retries an uncertain move. Choose bots, new games, and time controls on Chess.com. Use **Navigate** for Back (⌘[), Forward (⌘]), Home (⇧⌘H), and Reload (⌘R).

**Disconnect Game** pauses automatic attachment. **Connect / Reconnect Game** resumes it and acknowledges inspection of an interrupted move. Always inspect the actual board before using this action after an uncertain move. Commands are never automatically replayed after a crash, navigation, or ambiguous result.

Pairing credentials, pending claims, and interrupted-move state are stored in Keychain, scoped to the relay origin. Unpairing revokes the pairing remotely; an offline revocation retains the credential and blocks reconnection until Unpair succeeds. The webview never receives relay credentials.

The app defaults to `https://chess-tv-relay.kodkod.me`. For local development, set `RELAY_URL=http://127.0.0.1:3000` in the Xcode scheme's Run environment. HTTP is accepted only for loopback in Debug builds. Both TV and Mac must use the same relay. An app launched by Finder uses the default relay.

Only Chess.com pages stay inside the main window. Other links open in the default browser. Use Chess.com's own username/password login inside the webview; external-provider popup sign-in is not implemented.

## Architecture

SwiftUI owns the window and status UI. `ChessBrowser` wraps WKWebView and injects `extension/src/macos-content.ts` into an isolated content world. It calls the same adapter actions and reply format used by the extension, with main-frame and origin restrictions. A main-world script supplies timer-backed animation callbacks while the page is hidden; the adapter and relay credentials remain isolated. Reloads invalidate outstanding callbacks; same-document game changes are detected by the adapter.

`MacSession` owns pairing, attachment generations, serialized polling/commands, and durable move uncertainty. The macOS target directly references the TV app's protocol models, pairing HTTP helper, and WebSocket transport. The existing protocol's `extension` role represents the Mac client too; no relay or TV upgrade is required specifically for this wrapper.

## Verification

From the repository root:

```sh
bun run check
bun run test
bun run --bun vp build --config extension/vite.config.ts
xcodebuild -project mac/ChessTVMac.xcodeproj -scheme ChessTVMac \
  -destination 'platform=macOS' -derivedDataPath mac/.build test
```

Native tests cover pairing, expiry/rejection, revocation retry, page availability, stale commands, durable interruption recovery, the shared wire corpus, and adapter execution in a real WKWebView. The WebKit fixture verifies isolated-world access, DOM-observed moves with visible, hidden, and minimized windows, and duplicate-command handling. A native integration test starts the real Bun relay on a temporary port/database and exercises pairing, snapshots, move outcomes, relay reconnection, and unpairing with a simulated TV client.

Live validation: signed-in bot play, pairing with a physical Apple TV through Device Hub, TV-to-Mac moves, Mac-to-TV updates, and bot replies were verified. Background verification included a TV move and bot reply with the Mac window minimized, then a capture and bot reply with the app hidden. Real-WebKit regression fixtures require animation callbacks to complete in visible, hidden, and minimized windows.
