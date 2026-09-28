# Chess TV for Apple TV

Native SwiftUI app for **tvOS 27+ / Xcode 27+**. Open `ChessTV.xcodeproj` and choose the shared **ChessTV** scheme. No package dependencies or generated clients are needed.

## Configure and run

Debug simulator builds default to `http://127.0.0.1:3000`. Start the relay from the repository root with `bun run dev`, then run the app on an Apple TV simulator in Xcode, or:

```sh
./tv/script/build_and_run.sh
```

The script selects an installed tvOS 27 simulator; set `TV_SIMULATOR_ID` to override it. It supports `--logs`, `--debug`, and `--verify`. Keep simulator signing enabled: disabling code signing can prevent Keychain access even when the app launches.

For an Apple TV device or Release build, copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig`, set `RELAY_ORIGIN` to your relay's HTTPS origin, and set your signing team. Use `https:$(SLASH)$(SLASH)host` in xcconfig files because literal `//` starts a comment. No paths, credentials, query strings, or fragments are allowed in the origin. Release has no default relay. Plain HTTP is accepted only for loopback in Debug simulator builds; device builds always require HTTPS. Trust a real TLS certificate rather than bypassing transport security.

Use the same relay origin in the extension build. A device cannot reach the Mac through `127.0.0.1`; configure a reachable HTTPS relay for both clients. Select the connected Apple TV as the Xcode destination and use your personal signing team for manual installation. Public distribution is outside this prototype.

## Pair and play

1. Choose **Get pairing code** on the TV. Enter its six-digit code in the extension popup.
2. Confirm the request on the TV. The TV saves its credential in Keychain before connecting. Pairing is remembered per relay origin.
3. Keep the connected simulator tab visible in foreground Chrome. The existing extension automatically attaches the foreground simulated game after pairing.
4. Use directional focus to select your source piece and then its destination. Select another owned piece to change source; select the same square or press Back to cancel. Promotion offers queen, rook, bishop, and knight.
5. Pieces update only from extension snapshots. A pending destination has an hourglass; completion requires an observed outcome. After five seconds, the TV requests fresh state and displays **Checking move**. It never resends a move.

For an interrupted move, inspect Chrome, then explicitly reconnect the game through the extension. Reconnecting only the TV's relay connection does not clear uncertainty. **Connection** provides relay reconnection and Unpair. An offline unpair retains the credential and reports incomplete revocation; retry when the relay returns.

When using a simulator on the same Mac, clicking the Simulator window takes foreground focus away from Chrome and the extension correctly blocks moves. For full manual gameplay, use Apple TV hardware with the Siri Remote while Chrome remains foreground. Do not disable the extension's foreground checks to make simulator input work.

Real Chess.com observation and interaction are still deferred. This app uses the existing simulator protocol and introduces no Chess.com permissions, private endpoints, or rules engine.

## Verification

Run native tests with simulator signing enabled:

```sh
xcodebuild -project tv/ChessTV.xcodeproj -scheme ChessTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -derivedDataPath tv/.build test
```

Tests cover the shared `../protocol/fixtures/snapshot.json`, strict protocol fields, orientation, promotions, clocks, session/revision checks, one pending command, timeout, suspension, replacement, pairing failures, real Keychain round trips, and offline revocation. The fixture is referenced directly by the Xcode test target.

The opt-in **ChessTVIntegration** scheme adds a native end-to-end test against the real Bun relay with a simulated extension WebSocket peer. Run an isolated relay in one terminal, then the test in another:

```sh
HOST=127.0.0.1 PORT=33017 DATABASE_PATH=/tmp/chess-tv-native-test.sqlite bun relay/src/index.ts

xcodebuild -project tv/ChessTV.xcodeproj -scheme ChessTVIntegration \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -derivedDataPath tv/.build -only-testing:ChessTVTests/RelayIntegrationTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 test
```

It creates and confirms a pairing, authenticates both roles, attaches a game, publishes a snapshot, submits a native move, observes its completion, and revokes the pairing. Stop the temporary relay after testing. This verifies the native client and real relay; it does not drive the Chrome extension DOM adapter or a physical remote.

Static board renders can be produced by setting `CHESS_TV_RENDER=1` in the scheme test environment and running `testBoardRenderingForVisualInspection`. The test prints paths to PNGs in the simulator cache. These offscreen renders check layout, not focus behavior. Rendering is opt-in because Xcode can stall while finalizing an offscreen SwiftUI rendering test.

The workspace's existing checks remain `vp check`, `vp test`, and `vp build` in `extension`.

Before relying on device play, check directional focus across all 64 squares, focus stability during snapshots, Back behavior, promotion focus restoration, both orientations, viewing-distance readability, large text, VoiceOver, increased contrast, reduced motion/transparency, and TV suspension. Hardware and assistive-technology checks require an Apple TV; simulator builds alone do not establish them.

## Implementation boundaries

One root-owned `TVSession` owns pairing, transport, pending moves, and authoritative snapshots. Views own selection and focus. `RelaySocket` uses `URLSessionWebSocketTask`; `PairingAPI` uses HTTP; `CredentialStore` uses device-only Keychain storage. Small transport/storage interfaces permit focused tests without a dependency-injection framework.

Board order is a8–h8 through a1–h1 regardless of orientation. Revisions change placement or move-relevant state, while clocks may refresh at the same revision. Unknown clocks remain unknown. Clock estimates use monotonic elapsed time from receipt and freeze on disconnect, inactivity, stale observations, or a reported result. Displayed zero never establishes a timeout result.

Input requires an authenticated, active connection, a peer, a fresh matching snapshot and status, known player/turn, and no unresolved command. Observation freshness expires after five seconds. Old connection callbacks and mismatched game/generation messages cannot alter the current game. Credentials and game payloads are never logged by the app.
