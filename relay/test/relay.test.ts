import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"

import {
  Promotion,
  GameResult,
  GameResultReason,
  MessageKind,
  MoveOutcome,
  VERSION,
  parseMessage,
} from "@chess-tv/protocol"
import { afterEach, describe, expect, it } from "vite-plus/test"

import snapshot from "../../protocol/fixtures/snapshot.json"
import { harness, pair, type Harness } from "./helpers"
const running: Harness[] = []
async function setup(env?: Record<string, string>) {
  const h = await harness(env)
  running.push(h)
  return h
}
afterEach(async () => {
  await Promise.all(running.splice(0).map((h) => h.dispose()))
})
async function attached(h: Harness) {
  const credentials = await pair(h)
  const extension = await h.client(credentials.extension)
  await extension.take(MessageKind.Authenticated)
  await extension.take(MessageKind.Session)
  const tv = await h.client(credentials.tv)
  await tv.take(MessageKind.Authenticated)
  await tv.take(MessageKind.Session)
  const before = await extension.take(MessageKind.Session)
  extension.send({
    v: VERSION as typeof VERSION,
    type: MessageKind.Attachment,
    generation: before.generation,
    gameId: "game-1",
  })
  const session = await extension.take(MessageKind.Session)
  await tv.take(MessageKind.Session)
  await extension.take(MessageKind.SnapshotRequest)
  return { credentials, extension, tv, generation: session.generation }
}
describe("real Bun relay", () => {
  it("pairs with confirmation, retries delivery, persists hashes and survives restart", async () => {
    const h = await setup()
    expect((await h.request("/health")).status).toBe(200)
    const p = await pair(h)
    const poll = await h.request(`/v1/pairing/${p.challengeId}`, "GET", undefined, p.tvToken)
    expect(((await poll.json()) as { credential: string }).credential).toBe(p.tv)
    expect(
      (await h.request(`/v1/pairing/${p.challengeId}`, "GET", undefined, p.extension)).status,
    ).toBe(404)
    const db = Buffer.concat(
      await Promise.all(
        ["relay.db", "relay.db-wal"].map((file) =>
          readFile(join(h.dir, file)).catch(() => Buffer.alloc(0)),
        ),
      ),
    )
    expect(db.includes(Buffer.from(p.tv))).toBe(false)
    expect(db.includes(Buffer.from(p.extension))).toBe(false)
    expect(db.includes(Buffer.from(createHash("sha256").update(p.tv).digest("hex")))).toBe(true)
    await h.restart()
    const client = await h.client(p.tv)
    expect((await client.take(MessageKind.Authenticated)).pairingId).toBe(p.pairingId)
    expect(
      (await h.request(`/v1/pairing/${p.challengeId}`, "GET", undefined, p.tvToken)).status,
    ).toBe(404)
  })
  it("rejects unconfirmed and rejected challenges, expires challenges and limits attempts", async () => {
    const h = await setup({ TEST_PAIRING_TTL_MS: "200" })
    const tv = (await (await h.request("/v1/pairing", "POST")).json()) as {
      challengeId: string
      token: string
      code: string
    }
    const path = `/v1/pairing/${tv.challengeId}`
    expect((await h.request(`${path}/decision`, "POST", { confirm: true }, tv.token)).status).toBe(
      409,
    )
    await h.request("/v1/pairing/claim", "POST", { code: tv.code })
    expect((await h.request(`${path}/decision`, "POST", { confirm: false }, tv.token)).status).toBe(
      200,
    )
    expect(
      ((await (await h.request(path, "GET", undefined, tv.token)).json()) as { state: string })
        .state,
    ).toBe(MoveOutcome.Rejected)
    await delay(220)
    expect((await h.request(path, "GET", undefined, tv.token)).status).toBe(404)
    for (let i = 0; i < 9; i++) await h.request("/v1/pairing/claim", "POST", { code: "000000" })
    expect((await h.request("/v1/pairing/claim", "POST", { code: "000000" })).status).toBe(429)
    for (let i = 0; i < 4; i++) await h.request("/v1/pairing", "POST")
    expect((await h.request("/v1/pairing", "POST")).status).toBe(429)
  })
  it("revokes both endpoints and pending credential delivery", async () => {
    const h = await setup()
    const { credentials: p, tv, extension } = await attached(h)
    expect((await h.request("/v1/pairing", "DELETE", undefined, p.extension)).status).toBe(204)
    expect(await tv.closed).toBe(4003)
    expect(await extension.closed).toBe(4003)
    expect(await (await h.client(p.tv)).closed).toBe(1008)
    expect(
      (await h.request(`/v1/pairing/${p.challengeId}`, "GET", undefined, p.tvToken)).status,
    ).toBe(404)
  })
  it("routes snapshots, promotions, duplicate commands and outcomes unchanged without chess validation", async () => {
    const h = await setup()
    const { tv, extension, generation } = await attached(h)
    const state = parseMessage({ ...snapshot, generation })
    extension.send(state)
    expect(await tv.take(MessageKind.Snapshot)).toEqual(state)
    for (const promotion of Object.values(Promotion)) {
      const move = {
        v: VERSION as typeof VERSION,
        type: MessageKind.Move as const,
        gameId: "game-1",
        generation,
        revision: 1,
        commandId: promotion,
        from: "a7",
        to: "a8",
        promotion,
      }
      tv.send(move)
      expect(await extension.take(MessageKind.Move)).toEqual(move)
      tv.send(move)
      expect(await extension.take(MessageKind.Move)).toEqual(move)
      const outcome = {
        v: VERSION as typeof VERSION,
        type: MessageKind.Outcome as const,
        gameId: "game-1",
        generation,
        commandId: promotion,
        outcome: MoveOutcome.ObservedComplete as const,
        reason: null,
      }
      extension.send(outcome)
      expect(await tv.take(MessageKind.Outcome)).toEqual(outcome)
    }
    for (const secret of ["White", "game-1", generation]) expect(h.logs()).not.toContain(secret)
  })
  it("rejects wrong roles and stale generations, isolates pairings", async () => {
    const h = await setup()
    const a = await attached(h)
    const b = await attached(h)
    a.tv.send(parseMessage({ ...snapshot, generation: a.generation }))
    expect((await a.tv.take(MessageKind.Error)).code).toBe("wrong_role")
    a.extension.send(parseMessage({ ...snapshot, generation: b.generation }))
    expect((await a.extension.take(MessageKind.Error)).code).toBe("stale_session")
    a.extension.send(parseMessage({ ...snapshot, generation: a.generation }))
    await a.tv.take(MessageKind.Snapshot)
    expect(b.tv.messages.some((m) => m.type === MessageKind.Snapshot)).toBe(false)
  })
  it("replaces connections safely, requests fresh snapshots and never caches snapshots", async () => {
    const h = await setup()
    const a = await attached(h)
    a.extension.send(parseMessage({ ...snapshot, generation: a.generation }))
    await a.tv.take(MessageKind.Snapshot)
    const replacement = await h.client(a.credentials.tv)
    await replacement.take(MessageKind.Authenticated)
    const session = await replacement.take(MessageKind.Session)
    expect(session.generation).not.toBe(a.generation)
    expect(await a.tv.closed).toBe(4001)
    await a.extension.take(MessageKind.Session)
    expect((await a.extension.take(MessageKind.SnapshotRequest)).generation).toBe(
      session.generation,
    )
    expect(replacement.messages.some((m) => m.type === MessageKind.Snapshot)).toBe(false)
    a.extension.send(parseMessage({ ...snapshot, generation: session.generation }))
    expect((await replacement.take(MessageKind.Snapshot)).generation).toBe(session.generation)
  })
  it("clears extension attachment on loss, drops in-flight moves and requires reattachment", async () => {
    const h = await setup()
    const a = await attached(h)
    a.tv.send({
      v: VERSION as typeof VERSION,
      type: MessageKind.Move,
      gameId: "game-1",
      generation: a.generation,
      revision: 1,
      commandId: MoveOutcome.Uncertain,
      from: "a2",
      to: "a4",
    })
    await a.extension.take(MessageKind.Move)
    a.extension.ws.close()
    await a.extension.closed
    const disconnected = await a.tv.take(MessageKind.Session)
    expect(disconnected.gameId).toBeNull()
    const replacement = await h.client(a.credentials.extension)
    await replacement.take(MessageKind.Authenticated)
    const fresh = await replacement.take(MessageKind.Session)
    await a.tv.take(MessageKind.Session)
    expect(fresh.gameId).toBeNull()
    expect(replacement.messages.some((m) => m.type === MessageKind.Move)).toBe(false)
    replacement.send({
      v: VERSION as typeof VERSION,
      type: MessageKind.Attachment,
      generation: fresh.generation,
      gameId: "game-1",
    })
    const newSession = await replacement.take(MessageKind.Session)
    await replacement.take(MessageKind.SnapshotRequest)
    await a.tv.take(MessageKind.Session)
    expect(newSession.generation).not.toBe(a.generation)
    replacement.send({
      v: VERSION as typeof VERSION,
      type: MessageKind.Attachment,
      generation: newSession.generation,
      gameId: null,
    })
    expect((await a.tv.take(MessageKind.Session)).gameId).toBeNull()
  })
  it("rejects invalid authentication and closes unauthenticated or silent clients", async () => {
    const h = await setup({ TEST_AUTH_MS: "80", TEST_HEARTBEAT_MS: "30", TEST_TIMEOUT_MS: "120" })
    expect(await (await h.client("0".repeat(64))).closed).toBe(1008)
    expect(await (await h.client()).closed).toBe(1008)
    const p = await pair(h)
    const silent = await h.client(p.tv, false)
    await silent.take(MessageKind.Authenticated)
    expect(await silent.closed).toBe(1008)
    const active = await h.client(p.tv)
    await active.take(MessageKind.Authenticated)
    await delay(180)
    expect(active.ws.readyState).toBe(WebSocket.OPEN)
  })
  it("rejects malformed, incompatible, binary, oversized and rate-excessive messages", async () => {
    const h = await setup()
    for (const input of [
      "{",
      JSON.stringify({ v: 1, type: MessageKind.Authenticate, credential: "0".repeat(64) }),
      "x".repeat(65537),
      new Uint8Array([1]),
    ]) {
      const client = await h.client()
      client.ws.send(input)
      // Bun rejects oversized frames at the transport layer without a close frame.
      expect(
        typeof input === "string" && input.length > 65536 ? [1006, 1009] : [1007, 1008, 1009],
      ).toContain(await client.closed)
    }
    const p = await pair(h)
    const client = await h.client(p.tv)
    await client.take(MessageKind.Authenticated)
    for (let i = 0; i < 61; i++)
      client.send({ v: VERSION as typeof VERSION, type: MessageKind.Ping, nonce: String(i) })
    expect(await client.closed).toBe(1008)
    expect(h.logs()).not.toContain(p.tv)
    expect(h.logs()).not.toContain(p.code)
  })
})

it("forwards the terminal position and result reason together", async () => {
  const h = await setup()
  const { extension, tv, generation } = await attached(h)
  const final = {
    ...snapshot,
    generation,
    revision: 2,
    result: GameResult.BlackWon,
    resultReason: GameResultReason.Checkmate,
    legalMoves: [],
  }
  extension.send(parseMessage(final))
  expect(await tv.take(MessageKind.Snapshot)).toEqual(final)
})
