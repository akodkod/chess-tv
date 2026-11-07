# Chess TV for macOS

A Chess.com and Lichess browser with connection status and controls in the window toolbar. macOS 14 or later.

The speaker button after the microphone toggles website sounds in the embedded browser. Sounds start muted, and your choice is remembered across launches. Apple TV sounds and microphone input are controlled separately.

## Build and run

Install the repository's dependencies with `bun install --frozen-lockfile` and
configure [development signing](#development-signing), then run:

```sh
./mac/script/build_and_run.sh
```

The script first builds the pinned `transcribe.cpp` Swift framework under
`mac/.generated`. First setup requires network access and Python 3; if CMake/Ninja
are missing, pinned copies are installed into `mac/.build/runtime-tools`.
For direct Xcode builds, run `./mac/script/prepare_speech_runtime.sh` once first.

Then open `mac/ChessTVMac.xcodeproj` and run the **ChessTVMac** scheme. The built app is named **ChessTV.app**. The Xcode build phase bundles the existing TypeScript adapter with Vite+ for Safari 17; no Chrome extension is required. Xcode and Bun must be installed. The development app is signed locally; distribution and notarization are not configured.

The run script also accepts `--verify`, `--debug`, `--logs`, and `--telemetry`. The local Codex Run action invokes it.

## Connect your TV

1. Sign in to Chess.com inside the app. Its persistent WebKit profile is separate from your regular browser.
2. Request a code in the Apple TV app, then choose **… → Pair TV** on the Mac.
3. Enter the six-digit code; the current TV app confirms automatically.
4. Open a supported standard bot or online game. Attachment is automatic; online spectator games are view-only.

TV moves remain enabled when the Mac window is unfocused, covered, hidden, or minimized. Keep the app running and the Mac awake. A Mac-only animation callback fallback keeps Chess.com board updates progressing while WebKit hides the page. The adapter still requires board/history confirmation and never retries an uncertain move. Choose bots, new games, and time controls on Chess.com. Use **Navigate** for Back (⌘[), Forward (⌘]), Home (⇧⌘H), and Reload (⌘R).

**Disconnect Game** pauses automatic attachment. **Connect Game** resumes automatic attachment. The action reads **Reconnect Game** when a game is already attached or an interrupted move needs inspection; reconnecting acknowledges that inspection. Always inspect the actual board before using this action after an uncertain move. Commands are never automatically replayed after a crash, navigation, or ambiguous result.

Pairing credentials, pending claims, and interrupted-move state are stored in Keychain, scoped to the relay origin. Unpairing revokes the pairing remotely; an offline revocation retains the credential and blocks reconnection until Unpair succeeds. The webview never receives relay credentials.

The app defaults to `https://chess-tv-relay.kodkod.me`. For local development, set `RELAY_URL=http://127.0.0.1:3000` in the Xcode scheme's Run environment. HTTP is accepted only for loopback in Debug builds. Both TV and Mac must use the same relay. An app launched by Finder uses the default relay.

Chess.com and Lichess pages stay inside the main window. Other links open in the default browser. Use Chess.com's own username/password login inside the webview; external-provider popup sign-in is not implemented.

## Lichess

Choose **Lichess** from the toolbar site menu, then **… → Connect Lichess…**. Authorize **Play games using the Board API** in your regular browser. The Mac app saves its own revocable token in Keychain, separately from the extension. **Disconnect Lichess** revokes that token.

Start a game on Lichess, then choose **… → Open My Lichess Game** to open your first ongoing game. You can start it in your regular browser; API authorization does not sign the embedded webview in. A signed-out page may say “spectator,” while TV and voice input use your authorized playing account. Sign in inside the app separately if you want Lichess's own account controls there.

Supported games are standard rapid, classical, correspondence, and blitz direct challenges or AI games. Bullet, pool blitz, variants, custom starting positions, puzzles, analysis, and Lichess spectator games are unsupported. Moves and live state use the official Board API through native networking, including while the window is hidden or minimized. The existing TV controls and voice commands work unchanged. Inspect the game before **Reconnect Game** after any uncertain move.

## Architecture

SwiftUI owns the window and status UI. `ChessBrowser` wraps WKWebView and injects `extension/src/macos-content.ts` into an isolated content world. It calls the same adapter actions and reply format used by the extension, with main-frame and origin restrictions. A main-world script supplies timer-backed animation callbacks while the page is hidden; the adapter and relay credentials remain isolated. Reloads invalidate outstanding callbacks; same-document game changes are detected by the adapter.

`LichessConnection` owns PKCE authorization, Keychain storage, the Board API stream, and move submission. The isolated WebKit bridge passes only game data and outcomes; authorization headers stay native. `GameAdapter` shares revisions, legal-move checks, voice resolution, and uncertainty rules across the Chess.com and Lichess drivers.

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

Lichess live validation on 2026-11-07: separate OAuth authorization survived relaunch, **Open My Lichess Game** found the Chrome-started AI game, and TV input played `g1-f3` while the Mac window was minimized. The `b8-c6` reply and live clocks reached the Apple TV simulator. Native tests also cover streamed confirmation, stale commands, lost responses, deduplication, unsupported time controls, and standalone voice through the real isolated WebKit bridge. Physical HappyTV was unavailable for this pass.

## Voice control

Click the microphone in the window toolbar to toggle English voice commands. It
starts off on each launch. In **… → Voice Settings…**, choose Apple recognition
(macOS 26+) or **Parakeet Unified English** (Apple Silicon, macOS 14+).
Both transcribe locally. Apple is the initial selection. Download Parakeet and
its Silero speech detector (about 733 MB total), then select it. Downloads are
pinned and size/SHA-256 verified before installation in Application Support.
First use asks for microphone access. No audio is uploaded.

Parakeet runs Q8_0 Unified EN 0.6B through the pinned `transcribe.cpp` Swift
bindings with Metal. Live preview uses the 480 ms buffered-streaming configuration;
a command is finalized after 600 ms of silence. It retains 300 ms of pre-roll,
resets between commands, and rejects speech over ten seconds rather than executing
a truncated command. The model stays loaded during listening. Removing models
stops capture and switches back to Apple.
Audio is not saved. Recent transcripts appear in the in-memory debug history. Recognition details are available in the debug window rather than the toolbar.

For the Apple engine, **Prefer recognition accuracy** is on by default. Turn it off for faster recognition. This preference
persists across launches; changing it restarts active listening and discards
pending speech. Listening itself still starts off on each launch.

Open a supported Chess.com or authorized Lichess game and wait for your turn, then say one command:

- “Rook D4”
- “Knight F3” (“night” is accepted as “knight”)
- “Pawn D4”
- “Rook from B1 to B4” when multiple rooks can reach B4
- “Pawn takes D6”
- “Castle king side” or “castle queen side”
- “Pawn E8 promote to queen” (rook, bishop, and knight also supported)

Always name the piece, including Pawn. “D4”, “dee four”, and “move D4” are
rejected rather than interpreted as pawn moves. This also applies to Jev.
A starting square is optional when the piece and destination identify one legal
move; include it to resolve ambiguity.

Piece-first commands work without saying “move”; “night” is accepted as “knight”.
Spoken square names such as “gee four” and “bee seven” are accepted. Alternative
transcriptions are checked against the same board: only one distinct legal move
may match. Conflicting moves or ambiguous pieces ask you to repeat the command.

A complete command identifying exactly one legal move plays immediately. Name a
starting file, rank, or square if multiple pieces can reach the destination.
Promotions require a piece. Unrelated speech is ignored. Rejected commands show a brief toolbar notice and send their explanation to the paired Apple TV for a temporary warning. The warning does not disable legal moves; successful commands simply perform the move.

Voice works without a TV pairing, and a connected TV receives the normal board
updates. Listening continues with the window hidden or minimized while the Mac
is awake. Turning it off immediately stops capture and discards pending speech;
a move already dispatched to the chess site still completes. Microphone interruption
or sleep stops listening with an error; toggle it back on to retry. Denied
microphone access can be enabled in System Settings → Privacy & Security →
Microphone.

### Jev interpretation

Enable **Use Jev for unrecognized commands** and enter a key in the secure Settings
field. **Save Key** stores it in a separate macOS Keychain item; **Test Saved Key**
sends a synthetic command without playing a move. Keys never enter the webview,
source files, or logs. Saving a key does not enable Jev automatically.

Exact commands stay local. For unrecognized speech while it is your turn, Jev
receives the transcript and the app-validated legal move descriptions, never audio.
Only a supplied legal move with reported probability at least 0.98 may execute.
This threshold is a conservative starting point, not an accuracy guarantee.
Ambiguity, negation, conflicting commands and explicit illegal moves do not reach
the fallback. Uncertain responses ask you to repeat; timeouts and errors do not
retry or replay. A board change, navigation, microphone-off or settings change
invalidates pending interpretation. Exact commands work even when Jev is unavailable.

Native voice and TV commands share the session's serialized queue and durable
move-dispatch boundary. The Mac-only isolated adapter endpoints `voice-position`, `voice-resolve`,
`voice-selected-move`, and `voice-move` bind commands to the observed game and board. A delayed command
cannot apply to a changed position, and uncertain moves remain locked until
inspection and **Reconnect Game**, including standalone play. No relay
protocol changes are required.

## Development signing

Debug and Release builds use Apple Development signing. Before building, copy
`mac/Config/Local.xcconfig.example` to `mac/Config/Local.xcconfig` and replace
`YOUR_TEAM_ID` with your own team ID. The local file is ignored by Git and applies
to both configurations. Install the matching Apple Development certificate and
private key through Xcode. The build fails if that identity is unavailable; it
does not silently fall back to ad-hoc signing.

A stable signed identity lets Keychain recognize subsequent builds. The first
launch after switching from the old ad-hoc build may still ask for access to the
existing TV pairing. Approve that prompt locally; “Always Allow” remembers access
for the signed app. This does not require your Chess.com password. Development
signing is for local use, not a notarized distribution build.

### Speech verification

Ordinary tests mock Jev and do not download models or read your API key. Optional
live tests use installed models, generated (not microphone) chess audio, and the
saved Jev key. Generate fixtures and run:

```sh
mkdir -p mac/.build/voice-fixtures
say -o mac/.build/voice-fixtures/pawn.wav --file-format=WAVE --data-format=LEF32@16000 'Pawn G four.'
say -o mac/.build/voice-fixtures/knight.wav --file-format=WAVE --data-format=LEF32@16000 'Knight F three.'
TEST_RUNNER_CHESS_VOICE_LIVE_TESTS=1 xcodebuild -project mac/ChessTVMac.xcodeproj \
  -scheme ChessTVMac -destination 'platform=macOS,arch=arm64' -derivedDataPath mac/.build \
  -only-testing:ChessTVMacTests/SpeechPipelineTests test
```

These smoke tests establish integration, not accuracy on your accent or microphone.
Compare both engines on the same commands in a bot game; record correct moves,
rejections, wrong moves, and end-of-speech latency. The trial target is zero wrong
executions, better command success than Apple, and warm p95 latency below two
seconds; real-voice measurements are still required.

The runtime is MIT licensed; its framework includes third-party notices. Parakeet
weights use the NVIDIA Open Model License; Silero VAD uses MIT. Model weights are
not bundled with the repository or app.

### Voice recognition debugging

Open **Voice → Voice Recognition Debug…** (⌥⌘D), or use the button in
Voice Settings. The window shows partial/final transcripts, alternatives,
segment timing, local parser decisions, legal moves, Jev request/response JSON
and probabilities, request latency, cancellations, and observed move completion.
Events have an utterance trace ID to associate asynchronous results. The latest
300 events are kept only in memory, including while the window is closed.
**Copy All** copies them for troubleshooting; **Clear** removes them. No audio
or authorization headers are included. Copied details do include spoken text
and the board position.

The local parser runs first. Jev handles parser fallbacks, choosing among legal
moves plus `unclear`, `not_a_command`, and `illegal_requested_move`. A legal
choice must have probability at least 0.98; the app checks the current position
again before dispatch. The probability is a model score, not a measured move
accuracy guarantee. Debugging does not relax this threshold or replay commands.
