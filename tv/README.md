# Chess TV for Apple TV

Native SwiftUI app for **tvOS 27+ / Xcode 27+**. Open `ChessTV.xcodeproj` and choose the shared **ChessTV** scheme. No package dependencies or generated clients are needed.

## Configure and run

Debug and Release builds default to `https://chess-tv-relay.kodkod.me`. Run the app on an Apple TV simulator in Xcode, or:

```sh
./tv/script/build_and_run.sh
```

The script selects an installed tvOS 27 simulator and opens Simulator or Xcode 27 Device Hub; set `TV_SIMULATOR_ID` to override it. It supports `--logs`, `--debug`, and `--verify`. Keep simulator signing enabled: disabling code signing can prevent Keychain access even when the app launches.

Set your signing team in Xcode for an Apple TV device build. To override the relay or signing team locally, copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and edit it. Use `https:$(SLASH)$(SLASH)host` in xcconfig files because literal `//` starts a comment. No paths, credentials, query strings, or fragments are allowed in the origin. Plain HTTP is accepted only for loopback in Debug simulator builds; device builds always require HTTPS. Trust a real TLS certificate rather than bypassing transport security.

For local simulator development, start `bun run dev` from the repository root and set `RELAY_ORIGIN = http:$(SLASH)$(SLASH)127.0.0.1:3000` in `Config/Local.xcconfig`. Use the same relay origin in the extension build. A device cannot reach the Mac through `127.0.0.1`; configure a reachable HTTPS relay for both clients. Select the connected Apple TV as the Xcode destination and use your personal signing team for manual installation. Public distribution is outside this prototype.

## Play with Chess.com

Pair the app by entering the TV's six-digit code in the Chrome extension; the TV confirms automatically. Start or continue a standard Chess.com bot game in the active tab of the focused Chrome window. The extension detects your playing color and attaches automatically, or you can click **Connect this game**. **Disconnect** pauses automatic attachment until you connect manually again. Select a piece and destination with the TV remote. Back cancels selection; reaching a promotion rank opens a Queen/Rook/Bishop/Knight chooser.

The extension synchronizes the actual board, turn, and result. It validates chosen moves and supports castling, en passant, and promotion. Keep the bot tab selected and visible. Start new games and choose bots in Chrome. Player names and timed-game clocks synchronize from Chrome; untimed and Lichess correspondence clocks are hidden, as are clocks with six hours or more remaining. See `../extension/README.md` for setup, recovery, and verification details.

The playing side always appears at the bottom, including Black. Selecting a piece shows legal destinations: dots for empty squares and rings for captures. A king in check has a red square and a check warning. The last observed opponent move has a subtle yellow highlight on its starting and ending squares (the king’s squares for castling). It clears after your reply or resynchronization, and follows the displayed position during move review. During play, only warnings/errors and game results appear beside the board; routine instructions and pending-move indicators are hidden.

Protocol v3 uses an associated-value `Message` enum and typed payloads. Views, previews, and history consume `Snapshot`; pending commands use `MoveRequest`. Snapshot orientation is required, and unknown result reasons and avatars are explicit nulls. Update the TV, extension, and relay together; older versions are unsupported. Pairing credentials remain valid.

The board uses bundled Chess.com Neo-Wood pieces and the Walnut texture. Legal moves animate immediately for 180 ms, including castling, en passant, and promotions, while Chrome confirms the move. Confirmation preserves the displayed position without replaying the animation; a rejection, uncertainty, timeout, or disconnect restores the last confirmed board. Preview positions do not enter move history or enable another move. Incoming confirmed single moves use the same animation. Piece movement and capture flights use Core Animation layers, so interpolation runs in the compositor without per-frame SwiftUI updates. Confirmation and clock updates preserve in-flight layers. Opponent captures approach over 350 ms and send the captured piece into a slower 1.75-second flight; Reduce Motion disables animation. Initial loads, reconnects, and ambiguous position jumps update immediately.

Open **Settings** in the right panel to control **Show square labels**, **Labels on board edges only**, and **Game sounds**. All three default to on and persist between launches. Settings and its nested choice and Connection lists stay in the right panel, with the live board visible. The panel expands from 340 to 560 points with a 0.25-second transition (instant with Reduce Motion); wrapped settings labels align left. Remote Back returns to the parent list, then the game. Board input is disabled while settings are open. Color rows always show their setting label, color name, and swatch. **Sound level** adjusts all game sounds and capture previews from 0–100% in 10% steps, defaults to 100%, and persists between launches. Game sounds remains the master mute and retains your selected level. **Last move color** and **Selected square color** independently choose yellow, green, blue, purple, or orange; both default to yellow and persist between launches. The selected-square color also applies to remote focus on the board. Edge labels follow the visible left and bottom edges for either playing color; disable edge-only mode to label every square. Board-square focus opts out of the native tvOS navigation sound; controls outside the grid retain system feedback. Sounds use bundled Chess.com Default move, capture, and check clips and play only for confirmed single moves. The **Capture sound** picker offers **Default**, **Spring boing**, **Cartoon pop**, **Bonk!**, and **Yoink!**, with automatic preview when you select a different sound. The selection persists between launches; Game sounds also mutes previews. The four cartoon effects are adapted from Pixabay downloads (0.075–0.55 seconds, pitch lowered five semitones). Credits, source URLs, hashes, and license are recorded in `ChessTV/Sounds/capture-sources.json`. To rebuild from the original downloaded MP3s, run `python3 tv/script/prepare_capture_sounds.py /path/to/downloads` (requires ffmpeg). Existing Slide whistle preferences become Yoink!; other selections persist. A check cue replaces the move/capture cue. Live wins and losses play distinct local chimes once, taking priority over move/check cues and honoring Game sounds. Reconnects, initial results, and move review stay silent. Regenerate the original result chimes with `python3 tv/script/generate_result_sounds.py`. Theme source URLs are recorded in `ChessTV/theme-sources.json`; later Chess.com theme changes do not change this bundled theme.

The TV and extension automatically reconnect after temporary network loss, relay restarts, and heartbeat or authentication timeouts, including when both disconnect. Pairing is retained, and the game resynchronizes before moves are enabled. Retries back off to at most 30 seconds; returning to the TV app reconnects immediately. While only the extension is offline, the TV waits for it to return. Revoked credentials, protocol rejection, and replacement by another client require explicit recovery through **Settings → Connection**.

For an interrupted move, inspect Chrome, then explicitly reconnect the game through the extension. Reconnecting only the TV's relay connection does not clear uncertainty. **Settings → Connection** provides relay reconnection and Unpair. An offline unpair retains the credential and reports incomplete revocation; retry when the relay returns.

The app prevents automatic idle sleep and the screensaver while an unfinished attached game is displayed in the foreground, including spectating, move review, and settings. Normal idle behavior resumes after the live game ends, detaches, requires connection recovery, or the app leaves the foreground. Temporary relay interruptions do not end the keep-awake behavior.

## Verification

Run native tests with simulator signing enabled:

```sh
xcodebuild -project tv/ChessTV.xcodeproj -scheme ChessTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' \
  -derivedDataPath tv/.build test
```

Tests cover the shared `../protocol/fixtures/snapshot.json` and valid/invalid `messages.json` corpus, strict protocol fields, orientation, promotions, clocks, session/revision checks, one pending command, timeout, suspension, replacement, pairing failures, real Keychain round trips, and offline revocation. Both fixture files are referenced directly by the Xcode test target.

The opt-in **ChessTVIntegration** scheme adds a native end-to-end test against the real Bun relay with a simulated extension WebSocket peer. Run an isolated relay in one terminal, then the test in another:

```sh
HOST=127.0.0.1 PORT=33017 DATABASE_PATH=/tmp/chess-tv-native-test.sqlite bun relay/src/index.ts

xcodebuild -project tv/ChessTV.xcodeproj -scheme ChessTVIntegration \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' \
  -derivedDataPath tv/.build -only-testing:ChessTVTests/RelayIntegrationTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 test
```

It creates and confirms a pairing, authenticates both roles, attaches a game, publishes a snapshot, submits a native move, observes its completion, and revokes the pairing. Stop the temporary relay after testing. This verifies the native client and real relay; it does not drive the Chrome extension DOM adapter or a physical remote.

Static board renders can be produced by setting `CHESS_TV_RENDER=1` in the scheme test environment and running `testBoardRenderingForVisualInspection`. The test prints paths to PNGs in the simulator cache. These offscreen renders check layout, not focus behavior. Rendering is opt-in because Xcode can stall while finalizing an offscreen SwiftUI rendering test.

The workspace's existing checks remain `vp check`, `vp test`, and `vp build` in `extension` (output: `dist`).

Before relying on device play, check directional focus across all 64 squares, focus stability during snapshots, Back behavior, promotion focus restoration, both orientations, viewing-distance readability, large text, VoiceOver, increased contrast, reduced motion/transparency, and TV suspension. Hardware and assistive-technology checks require an Apple TV; simulator builds alone do not establish them.

## Implementation boundaries

One root-owned `TVSession` owns pairing, transport, pending moves, authoritative snapshots, and a separate temporary move preview. Views own selection and focus. `RelaySocket` uses `URLSessionWebSocketTask`; `PairingAPI` uses HTTP; `CredentialStore` uses device-only Keychain storage. Small transport/storage interfaces permit focused tests without a dependency-injection framework.

Board order is a8–h8 through a1–h1 regardless of orientation. Revisions change placement or move-relevant state, while clocks may refresh at the same revision. Unknown clocks remain unknown. Clock estimates use monotonic elapsed time from receipt and freeze on disconnect, inactivity, stale observations, or a reported result. Displayed zero never establishes a timeout result.

Input requires an authenticated, active connection, a peer, a fresh matching snapshot and status, known player/turn, and no unresolved command. Observation freshness expires after five seconds. Old connection callbacks and mismatched game/generation messages cannot alter the current game. Credentials and game payloads are never logged by the app.

Use the icon-only back/forward buttons below the turn text to review moves observed by the TV since its latest synchronization. Pieces animate in both directions, including castling and promotions; stepping back restores captured pieces and clears any outgoing capture flight. Reduce Motion disables these animations. Incoming moves remain available while reviewing; move input and live clocks resume when you reach the latest position. Reconnection or a missing/ambiguous move starts a new review history.

The Apple TV app icon uses the queen artwork from `../artwork/ChessTV.icon` in a native tvOS layered asset catalog, with separate foreground and background for parallax. Run `python3 tv/script/generate_icon.py` from the repository root after changing the source queen SVG or background color (requires `rsvg-convert` from librsvg). The generated Home screen and App Store PNG layers are committed; normal builds need no extra tools.

Open a friend’s standard online game in the paired browser to watch it on TV. When the signed-in account is not a player (or is signed out), the app shows “Viewing game” with the URL’s `username` player at the bottom (falling back to the browser’s orientation). Board squares cannot be focused or selected; Settings (including Connection) and move review remain available. Both players’ observed moves receive last-move highlights.

Confirmed Mac voice moves hide the board cursor until the remote changes board focus or selects a square. Rejected or uncertain commands do not hide it. Voice command IDs use a `voice-` prefix in the existing outcome messages; update the Mac app alongside the TV app for this behavior.
