# Chess TV extension

A Chrome 116+ Manifest V3 extension for the Chess TV relay. **Simulator only:** this version does not inspect or interact with Chess.com. Simulator success does not establish real-site feasibility or authorization.

The popup uses locally bundled React, Tailwind, and small native Button/Input components adapted from shadcn/ui patterns. Closing it does not stop pairing, observation, or the relay connection. The service worker owns credentials and relay sessions; the content script owns revisions, move deduplication, and page interaction. No chess rules engine is embedded.

## Try the complete local flow

Use the workspace's pinned Bun 1.4.2 and Node 24.21.0. From the repository root:

```sh
bun install --frozen-lockfile
bun run dev
```

In another terminal:

```sh
cd extension
vp build --mode simulator
bun run simulator
```

1. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select `extension/dist-simulator`.
2. Open <http://127.0.0.1:4173/> in Chrome. Keep that tab visible in the focused Chrome window.
3. In another terminal, run `bun run --cwd extension tv`. Enter its six-digit code in the extension popup, then type `confirm` in the TV terminal. The terminal is the simulated TV's explicit confirmation UI.
4. Return to the simulator in Chrome. The paired extension automatically connects to the current game; no popup action is needed.
5. In the TV terminal, type `move e2 e4`, then switch back to Chrome during the **five-second countdown**. Chrome must be foreground when the countdown ends. Completion is reported only after the simulator publishes matching acceptance evidence and a changed board.

Typing in VS Code or another terminal takes focus away from Chrome, so the extension temporarily disables input. The countdown gives you time to return without weakening that requirement. Type `cancel` to cancel a scheduled move or `status` to see the exact blocking reason. If the game, revision, session, or availability changes before submission, the move is cancelled rather than retried.

The TV client stores its credential in `data/simulator-tv.json` with owner-only permissions; the existing repository ignore excludes that directory. It never prints credentials. Rerun it to reconnect. Commands are `confirm`, `reject`, `move <from> <to> [q|r|b|n]`, `cancel`, `status`, `snapshot`, `unpair`, and `quit`.

The simulator offers scripted scenarios: normal white/black moves, castling, en passant, and four promotions. Changing scenario creates a **new game**: the extension automatically attaches when the simulator is foreground, unless automatic connection is paused. Click board squares directly to simulate Chrome input. Controls also simulate delayed or missing acceptance, page rejection, a result, broken layout, and stale observation. Reload preserves the simulated game in the tab's session storage. These fixtures are intentionally limited examples, not a playable chess engine.

## Builds and permissions

`RELAY_URL` is a build-time origin, never a secret. The simulator build defaults to `http://127.0.0.1:3000`. Override it when necessary:

```sh
cd extension
RELAY_URL=https://relay.example.com vp build --mode simulator
```

For a production package, explicitly supply the relay origin:

```sh
cd extension
RELAY_URL=https://relay.example.com vp build
```

This produces `extension/dist`. It can pair and report status, but game attachment is disabled until real-site support is implemented. No simulator page permission or Chess.com permission is added in this mode. HTTP is accepted only for loopback relay origins; other origins must use HTTPS. Paths, URL credentials, query strings, and fragments are rejected. Changing the configured relay requires pairing again.

Permissions are `storage`, `scripting`, and `alarms`, plus the configured relay host and, in simulator builds, `http://127.0.0.1/*`. Chrome host match patterns cannot restrict ports; runtime injection is restricted to the exact simulator origin `http://127.0.0.1:4173` and path `/`. Automatic injection is limited to the foreground simulator when paired and automatic connection is enabled. An existing attachment is retained when switching tabs; another game tab does not take it over. No cookies, broad browsing permissions, external scripts, or remotely hosted styles are used.

After rebuilding, reload the extension in `chrome://extensions` and reload any previously attached simulator tab to restore observation.

## Recovery behavior

- Disconnect detaches the game and persistently pauses automatic attachment while retaining pairing. **Connect this game** resumes automatic attachment; it also remains available for explicit recovery after inspecting an interrupted move. Unpair revokes both relay credentials before local removal. Offline failures retain the credential and report incomplete remote revocation; retry Unpair when the relay returns.
- A new relay generation disables input until a fresh observation. Heartbeats run every 20 seconds; reconnection uses jittered exponential delays capped at 30 seconds before jitter. A one-minute Chrome alarm resumes recovery if the worker was suspended. Browser exit clears tab attachment; pairing and the automatic connection preference remain remembered.
- Hidden/inactive tabs, unknown player or turn, stale observations, navigation, and broken layout disable input. Reload resumes the same game with a fresh generation after detecting the new content-script instance. A changed game ends the old attachment before automatically attaching the foreground game. Unresolved moves pause automatic attachment even if the tab navigates or closes.
- Only one move can be pending. The worker records potential dispatch in trusted session storage before sending it to the content script. Command IDs are deduplicated within the adapter session; direct page input is read before revision validation.
- After five seconds without evidence, the adapter refreshes state and reports **Checking move**. Delivery is never completion. An uncertain move is never resent automatically. A lost adapter or interrupted pending move blocks input until the user inspects Chrome and explicitly reconnects the game.
- A replaced or rejected relay connection stops automatic reconnection. **Reconnect relay** explicitly takes over; this avoids two extension instances continuously replacing each other.

Credentials and pending claims are restricted to trusted extension storage contexts. Content scripts receive no pairing credentials. Extension-internal messages are validated; only this extension's popup can issue worker actions, and adapter communication targets the bound tab's top frame. The relay protocol remains unchanged.

## Verification

From the workspace root:

```sh
vp check
vp test
```

Tests cover adapter evidence, stale/duplicate moves, pending commands, orientation, promotions, castling, en passant, direct page input, clock-only revisions, observation failures, pairing persistence/expiry/revocation, and live relay replacement sessions. Relay tests start real Bun processes with temporary SQLite databases and require local port-binding access.

The opt-in browser test loads the actual built extension in an isolated Chrome for Testing profile and exercises the popup, pairing, DOM clicks, popup closure, tab visibility, reload generations, and interrupted moves. Install its browser once, then run it with ports 3000 and 4173 free:

```sh
bun extension/node_modules/playwright/cli.js install chromium
(cd extension && vp build --mode simulator)
CHESS_TV_BROWSER_TEST=1 vp test extension/test/browser.test.ts
```

Set `PLAYWRIGHT_BROWSERS_PATH` for an alternate browser cache. The test cleans up its browser profile, simulator, relay, and database. It writes a popup screenshot to the system temporary directory for visual review. The normal suite skips this browser-dependent test.

## Real-site work remains deferred

Before enabling Chess.com, obtain the appropriate integration/testing authorization and verify real rapid/bot DOM identity, placement, player color, turn, clock, result, and acceptance evidence—including promotions. Do not substitute simulator selectors for verified real-site observation, use private endpoints, export login data, or expand host access silently. Stop if reliable human-selected move execution cannot be established.
