# Chess TV relay

One Bun/Hono process routes messages between a paired extension and TV. SQLite stores only pairing IDs and credential hashes. This package does not access Chess.com or validate chess moves.

## Run locally

Use Bun **1.4.2**, Node **24.21.0**, and Vite+ (`vp`). From the workspace root:

```sh
bun install --frozen-lockfile
bun run dev
# Or, without watching:
bun run start
```

The default address is `http://127.0.0.1:3000`. `GET /health` returns `{"status":"ok"}` after schema initialization succeeds. Environment variables:

| Variable        | Default           | Meaning                                                |
| --------------- | ----------------- | ------------------------------------------------------ |
| `HOST`          | `127.0.0.1`       | Listening interface                                    |
| `PORT`          | `3000`            | Listening port; `0` chooses a free port                |
| `DATABASE_PATH` | `./data/relay.db` | SQLite file, relative to the process working directory |

The database schema initializes automatically. SIGINT/SIGTERM closes connections and SQLite. There is no build step for the server.

Production requires a trusted TLS reverse proxy and persistent storage for the database and WAL files. Bind externally only within that deployment. Forwarded IP headers are deliberately ignored; limits behind a proxy apply to its actual peer address. Do not log request bodies, authorization headers, or WebSocket frames.

## Railway deployment

To host your own relay, create a Railway service from this repository with the
repository root as its source directory and Railpack as the builder. Configure:

- Start command: `bun run start`; health check: `/health` (60-second timeout).
- One replica, with sleeping disabled. Live sessions and pending challenges are
  process-local; do not add replicas without changing the relay.
- `HOST=0.0.0.0`, `NODE_ENV=production`, and Railway's supplied `PORT`.
- `DATABASE_PATH=/data/relay.db`, backed by a persistent volume mounted at `/data`.
- Watch paths covering `relay`, `protocol`, root `package.json`, and `bun.lock`.
- A reachable HTTPS origin configured in both clients (see their READMEs).

Use your own project and service when deploying. Keep deployment IDs and access
tokens in local tooling or the hosting provider's settings. Wait for a successful
deployment and verify its `/health` endpoint. Redeployments disconnect sockets;
clients reconnect and resynchronize, while pairing credentials survive on the
volume. Pending pairing challenges must be started again after a restart.

Clients sharing a proxy peer may share the 5 creation / 10 claim attempts per
minute. Forwarded headers are not trusted. Before broader use, implement and
test a proxy trust policy for your ingress rather than blindly trusting
client-supplied `X-Forwarded-For` or `X-Real-IP`.

## Pairing HTTP API

Responses are JSON, except successful deletion (204). Authentication uses `Authorization: Bearer <token>`, never URL parameters. Pairing responses use `Cache-Control: no-store`. Bodies are limited to 4 KiB.

1. TV: `POST /v1/pairing` with no body → 201 `{challengeId, code, token, expiresAt}`. Keep `token` private; display the six-digit code. `expiresAt` is Unix milliseconds, five minutes after creation.
2. Extension: `POST /v1/pairing/claim` with `{ "code": "123456" }` → `{challengeId, token, expiresAt}`. Only the first claim succeeds. This token belongs to the extension.
3. Both: `GET /v1/pairing/:id` with the respective challenge token → `{state, expiresAt}`. Poll about once per second. States are `waiting`, `claimed`, `confirmed`, `rejected`.
4. TV: after a user confirmation, `POST /v1/pairing/:id/decision` with its challenge token and `{ "confirm": true }`. Use `false` to reject. Only the TV token can decide; repeated completed decisions return the existing state.
5. Once confirmed, each device's GET response additionally includes `{pairingId, credential}` for that device only. Persist the credential before connecting. Delivery can be retried until challenge expiry. After expiry or relay restart, undelivered credentials cannot be recovered; pair again.
6. Either device: `DELETE /v1/pairing` with its **device credential** → 204. Revokes both credentials, closes both sockets, and removes delivery results. An offline client cannot claim that remote revocation succeeded.

Errors use `{error}`: `invalid_request` (400), `unauthorized` (401), `invalid_code`/`invalid_challenge` (404), `not_claimed`/`busy` (409), `rate_limited` (429), or capacity `busy` (503). A concurrent confirmation may return 409; poll before retrying. Expired/rejected/claimed codes cannot be claimed again. Failed creation or claim response delivery requires a new challenge; do not blindly repeat a claim.

Creation is limited to 5 attempts per peer IP per minute, claims to 10. There are at most 1,000 challenges and 10,000 active rate-limit buckets. Challenges and buckets expire in memory. These limits are local to this single process.

## WebSocket contract

Connect to `/v1/ws` and send within five seconds:

```json
{ "v": 3, "type": "authenticate", "credential": "<64 hex characters>" }
```

Wait for `authenticated` (`role`, `pairingId`) and `session` (`generation`, nullable `gameId`, `peerConnected`). The server derives the role from the credential. A replacement connection closes the previous connection with 4001; revocation closes both with 4003. Every client must disable move submission on a new generation until it obtains authoritative fresh state.

All messages use `v: 3` and `type`. Snapshots require `legalMoves`, nullable `checkSquare`, `bottomColor`, nullable `resultReason`, and both nullable avatar fields inside `players`. Unknown values are explicit JSON nulls; only move `promotion` is omitted when inapplicable. Update the TV, extension, and relay together; older protocol versions are rejected, with no compatibility layer. Pairing credentials and the `/v1` HTTP/WebSocket endpoint paths are unchanged. Named strict Zod schemas, inferred payload types, and string enums live in `protocol/src/index.ts`; Swift uses matching associated-value messages and typed payloads. Both runtimes consume the valid/invalid cases in `protocol/fixtures/messages.json`. Extra fields and incompatible versions are rejected. Messages are text JSON, at most 64 KiB, at most 60 messages per connection per second. Oversized frames may terminate without a WebSocket close frame.

| Type               | Direction               | Fields besides `v` and `type`                                                                     |
| ------------------ | ----------------------- | ------------------------------------------------------------------------------------------------- |
| `attachment`       | Extension → relay       | `generation`, nullable `gameId` (null detaches)                                                   |
| `session`          | Relay → both            | `generation`, nullable `gameId`, `peerConnected`                                                  |
| `status`           | Extension → TV          | `gameId`, `generation`, `available`, nullable `reason`                                            |
| `snapshot`         | Extension → TV          | `gameId`, `generation`, `revision`, `board`, `players`, `playerColor`, `turn`, `clocks`, `result` |
| `move`             | TV → extension          | `gameId`, `generation`, `revision`, `commandId`, `from`, `to`, optional `promotion`               |
| `outcome`          | Extension → TV          | `gameId`, `generation`, `commandId`, `outcome`, nullable `reason`                                 |
| `snapshot-request` | TV or relay → extension | `gameId`, `generation`                                                                            |
| `ping` / `pong`    | Both directions         | `nonce`; reply with the exact ping nonce                                                          |
| `error`            | Relay → client          | `code`, `message`                                                                                 |

Board cells run from **a8 to h8, then a7 to h7, through a1 to h1**. Null means empty; uppercase pieces are white, lowercase black. This is placement only, without inferred castling or en-passant rights. Players contain nullable white/black display names. Colors are `white`/`black`; player color and turn may be null. Each clock has nullable `remainingMs` and nullable `running`; `observedAt` is nullable Unix milliseconds at observation. Null is unknown, never zero. Results are null, `white-won`, `black-won`, or `draw`. Promotions are `q`, `r`, `b`, `n`; squares use algebraic coordinates independent of board orientation.

An extension reports its attachment using the current generation. An attachment change produces a **new** generation; adopt it before publishing. When both endpoints and an attachment exist, the relay asks the extension for a fresh snapshot. TV reconnection preserves the attached identity but changes generation. Extension loss/replacement clears attachment; it must verify and report its attachment again. Relay restart clears all live state while preserving pairing credentials. If the adapter loses its deduplication state without a transport loss, explicitly detach and reattach (waiting for each new session) before accepting moves.

The extension advances revision for move-relevant changes, enforces one pending move, rejects stale revisions, and deduplicates command IDs. Repeated commands are forwarded unchanged so the extension can return its known outcome. Outcomes are `rejected`, `uncertain`, or `observed-complete`; only website observation establishes completion. Never automatically replay after an interruption. After five seconds without completion, the TV requests fresh state and displays “Checking move.” If reconciliation remains ambiguous, keep input disabled.

The relay validates roles, generation and attachment identity, not board legality, move revision, or completion. It holds no snapshot, command queue, or move history. A missing peer produces `peer_unavailable`; other routing errors include `wrong_role`, `stale_session`, and `not_attached`. The server pings every 20 seconds and closes clients without a valid pong for 60 seconds. Clients should also ping to detect a lost server. Reconnect with bounded backoff and jitter, authenticate, and wait for resynchronization.

## Verification and simulated smoke test

From the workspace root:

```sh
vp check
vp test
# Focused pairing → attachment → snapshot → promotion → observed outcome smoke test:
vp test relay/test/relay.test.ts -t 'routes snapshots'
```

Tests run under Vite+'s Node-based Vitest and launch the actual Bun server on an ephemeral localhost port, with temporary SQLite files and simulated WebSocket clients. They require local port-binding permission. Processes and databases are cleaned up after each test. No real website, extension, or TV is needed.

The integration harness may shorten timings through `TEST_PAIRING_TTL_MS`, `TEST_AUTH_MS`, `TEST_HEARTBEAT_MS`, and `TEST_TIMEOUT_MS` only when `NODE_ENV=test`. These are not production configuration options.
