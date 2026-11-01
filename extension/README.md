# Chess TV Chrome extension

Chrome 116+ extension connecting **standard Chess.com bot games** to the native Apple TV app.

## Build and pair

From the repository root:

```sh
bun install --frozen-lockfile
(cd extension && vp build)
bun run dev
```

1. Load `extension/dist-chesscom` with **Load unpacked** in `chrome://extensions` (Developer mode enabled).
2. Run the Apple TV app with `./tv/script/build_and_run.sh`, or select your Apple TV in Xcode.
3. Get a pairing code on the TV. Enter it in the **Chess TV** extension and confirm on the TV.
4. Start or continue a bot game at `https://www.chess.com/play/computer/…`.
5. Select **Your color** in the extension and click **Connect this game**.
6. Use the TV remote to select a piece, then its destination. Back cancels selection. Promotion opens a piece chooser on the TV.

After rebuilding, reload the extension and the game page, then Continue the game in Chess.com. Pairing is remembered. Keep Chrome awake with the bot-game tab selected and visible; it need not have keyboard focus. Minimized windows, hidden tabs, history navigation, and obscured boards cannot accept moves.

The default relay is `http://127.0.0.1:3000`, suitable for the Mac's TV simulator. For a physical Apple TV, build with `RELAY_URL=https://your-relay.example vp build` from `extension`, and configure the same reachable HTTPS relay in the native app. See `../tv/README.md`. The manifest grants access only to Chess.com and the configured relay host.

## Play and recovery

The adapter reconstructs legal state from the complete recorded move history and checks it against every rendered square. It supports the starting position, letter and figurine notation, both board orientations, captures, castling, en passant, and all four promotion choices. `chess.js` validates the user's chosen move; it never chooses moves. The browser's observed board and history determine completion.

Snapshots carry game identity, revision, selected player color, turn, and result. Player names and timed-game clocks are read from the page; untimed or unrecognized clocks remain unknown. Custom starting positions and variants are unsupported; use a standard bot game from its normal initial position. Choose bots, time controls, new games, undo, or resign in Chrome.

Pairing survives reloads and relay restarts. Board resets, changed history, and new documents invalidate the old attachment before moves resume. When switching playing colors, select the new color and reconnect the game.

Moves have one command ID and are never automatically resent after ambiguity. An illegal or stale move is rejected without clicking the board. If an interaction is interrupted or unconfirmed, inspect the actual game in Chrome, then use **Reconnect this game**. **Disconnect game** pauses automatic attachment; **Unpair** revokes the pairing.

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
