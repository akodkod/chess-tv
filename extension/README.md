# Chess TV Chrome extension

Chrome 116+ extension connecting **standard Chess.com bot and online games** to the native Apple TV app.

## Build and pair

From the repository root:

```sh
bun install --frozen-lockfile
(cd extension && vp build)
```

1. Load `extension/dist` with **Load unpacked** in `chrome://extensions` (Developer mode enabled).
2. Run the Apple TV app with `./tv/script/build_and_run.sh`, or select your Apple TV in Xcode.
3. Get a pairing code on the TV. Enter it in the **Chess TV** extension and confirm on the TV.
4. Start or continue a bot game at `https://www.chess.com/play/computer`, or an online game at `https://www.chess.com/game/<id>`.
5. The current game connects automatically once paired. The extension matches your signed-in Chess.com profile to the player rows. Online games also connect in view mode when your account does not match a player or you are signed out. View mode synchronizes the board, players, clocks, and result, with the URL’s `username` player at the bottom (falling back to the browser’s orientation) and TV square selection disabled. Bot games still require a detected playing account.
6. Use the TV remote to select a piece, then its destination. Back cancels selection. Promotion opens a piece chooser on the TV.

Deploy the updated relay and update the TV app before using an extension that sends `resultReason`; older strict protocol readers reject that field. The extension also needs access to `https://www.chess.com/game/computer/*` to observe completed games.

After rebuilding, reload the extension and the game page, then Continue the game in Chess.com. Pairing is remembered. Keep Chrome awake with the bot-game tab selected and visible; it need not have keyboard focus. Minimized windows, hidden tabs, history navigation, and obscured boards cannot accept moves.

Builds default to `https://chess-tv-relay.kodkod.me`, matching the native app. To use a local relay with the Mac's TV simulator, build with `RELAY_URL=http://127.0.0.1:3000 vp build` from `extension` and override the native app's relay origin to match. See `../tv/README.md`. The manifest grants access only to Chess.com and the configured relay host.

The popup shows pairing setup or a short connection status. Open **Debug** for detailed status, relay and game information, and manual connection controls.

## Play and recovery

The adapter reconstructs legal state from the complete recorded move history and checks it against every rendered square. It supports the starting position, letter and figurine notation, both board orientations, captures, castling, en passant, and all four promotion choices. `chess.js` validates the user's chosen move; it never chooses moves. The browser's observed board and history determine completion.

Snapshots carry game identity, revision, detected player color, bottom-side color, turn, result, and an optional result reason. Board orientation is separate from identity, so following a player never grants move input. The final position remains connected when Chess.com changes the live URL to `/game/computer/<id>`. The TV shows wins/losses from your playing color and treats stalemate as a draw. Checkmate and stalemate come from the verified move history; timeout and resignation require a recorded result plus the game-over subtitle. Player names and timed-game clocks are read from the page; untimed or unrecognized clocks remain unknown. Custom starting positions and variants are unsupported; use a standard bot game from its normal initial position. Choose bots, time controls, new games, undo, or resign in Chrome.

Pairing survives reloads and relay restarts. Board resets, changed history, and new documents invalidate the old attachment before moves resume. Automatic color detection follows the current game, including when the browser board is flipped.

Moves have one command ID and are never automatically resent after ambiguity. An illegal or stale move is rejected without clicking the board. If an interaction is interrupted or unconfirmed, inspect the actual game in Chrome, then open **Debug → Reconnect current game**. **Debug → Disconnect game** pauses automatic attachment; **Debug → Unpair TV** revokes the pairing.

## Verification

From the repository root:

```sh
vp check
vp test
(cd extension && vp build)
```

Relay tests bind temporary localhost ports. Adapter tests exercise real DOM-event dispatch in JSDOM, history/board reconciliation, initial positions, figurine notation, stale/illegal commands, deduplication, immediate recapture, all promotion choices, timeouts, results, and resets.

Live verification on 2026-11-01:

- Native tvOS 27.2 app paired with the installed Chrome extension through the local relay.
- TV remote submitted `c2-d3` and `g1-f3`; Chess.com recorded the moves and bot replies synchronized back to TV.
- Reloading the extension/page retained pairing and recovered the attached game after Continue.
- Production adapter exercised on the live Chess.com board with legal recorded-history fixtures: kingside castling, en passant, knight underpromotion, and Black moving on a flipped board. Timed-game player/clock markup was also checked in both orientations.
- Native relay integration test separately verified pairing, snapshots, promotion command transport, completion, and revocation.

Physical Apple TV hardware has not been exercised by these simulator checks.

### Allowed pages

The URL allowlist includes `/play/computer` (with or without a bot suffix), completed bot games, `/play/coach`, `/play/online`, and `/game/<id>` or `/game/live/<id>` for online games including Rapid. URL permission alone does not establish adapter support: TV input still requires a recognized board, complete move history, and player identity. Coach layouts remain unsupported. Standard online games use the observed `board-single` layout with color-specific player clocks. Unknown layouts report an unsupported-layout message and do not submit moves.

Rapid-game observation was verified in Dia against a friend game and on the connected Apple TV simulator: position, player identities, Black orientation, and running clocks. Fixture tests cover user-selected move dispatch/confirmation and rejection for missing identity, stale history, stopped clocks, or conflicting clock turns. No move was submitted to the live friend game during validation.

Spectator support requires the updated extension, relay, and TV app together because strict snapshot readers must recognize `bottomColor`.

Live spectator verification on 2026-11-02: the paired Dia extension streamed game `186417811766` to physical HappyTV after the relay update. The TV showed cocoprismo at the bottom as Black, live clocks and incoming moves, “Viewing game” without a trailing period, and focus on Settings with board selection disabled. Automated checks passed: 142 JavaScript tests and 73 native tests (2 opt-in native tests skipped).
