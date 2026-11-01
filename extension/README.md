# Chess TV Chrome extension

One Chrome 116+ Manifest V3 extension for Chess.com bot games.

## Build and load

From the repository root:

```sh
bun install
(cd extension && vp build)
```

Load `extension/dist-chesscom` with **Load unpacked** in `chrome://extensions`. This is the sole build output. The installed extension is named **Chess TV**. Reload it after rebuilding, and reload the game page to replace any previously injected content script.

## Current capabilities

Open a Chess.com bot game at `https://www.chess.com/play/computer/…`, open the extension, select your color, and click **Inspect position**. Enter a source and destination square, then choose **Play move** to submit your own move.

The extension reads board placement and recorded move history, distinguishes the latest position from history navigation, and determines the next side to move. It checks the inspected position again before dispatch and waits for matching board and move-history evidence. Uncertain moves are never resent automatically.

Live turn observation has been verified. Extension-generated move execution still needs live verification. Empty move history, castling, promotion, result detection, and automatic player-color detection are not supported yet. No engine chooses moves.

## Apple TV integration

The native app, shared protocol, pairing, and relay transport remain in the repository. The Chess.com content script is not connected to the TV message contract yet, so TV pairing and game attachment are not exposed in the current popup. The worker transport tests use a mock content peer; they do not establish end-to-end Chess.com support.

Next implementation steps:

1. Verify a user-selected move through the extension on a real bot game.
2. Connect real board observations and confirmed move outcomes to the worker's snapshot/status/outcome contract, including game identity and selected player color.
3. Expose TV pairing and explicit game attachment in the popup.
4. Verify a move from the native Apple TV app through the relay to Chess.com, then cover game changes, reconnects, promotion, and interrupted moves.

For relay development, use `bun run dev` from the repository root. An explicit `RELAY_URL=https://your-relay.example` build adds that relay's host permission; without it, the extension requests only Chess.com access. Physical Apple TV requires a reachable HTTPS relay configured identically in both clients. See `../tv/README.md`.

## Verification

Run `vp test` and `vp check` from the repository root. DOM tests cover observed Chess.com markup and move evidence. Relay tests launch real local Bun processes with temporary databases and require permission to bind local ports.
