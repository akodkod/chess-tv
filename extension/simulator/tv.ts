import { mkdir, readFile, writeFile, unlink } from "node:fs/promises"
import { resolve } from "node:path"
import { createInterface } from "node:readline"

import { credential, messageSchema, type Message } from "@chess-tv/protocol"
import { z } from "zod"

import type { Snapshot } from "../src/messages"
import { MoveCountdown } from "./move-countdown"
const relay = process.env.RELAY_URL || "http://127.0.0.1:3000"
const file = resolve(import.meta.dir, "../../data/simulator-tv.json")
let token: string | undefined
let socket: WebSocket | undefined
let snapshot: Snapshot | undefined
let generation: string | undefined
let available = false
let reason = "Waiting for an attached game."
let observedAt = 0
let pending: string | undefined
let challenge: { challengeId: string; token: string; code: string } | undefined
async function request(path: string, method = "GET", body?: unknown, auth?: string) {
  const response = await fetch(relay + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(8000),
  })
  if (!response.ok && !(method === "DELETE" && response.status === 401))
    throw new Error(`Relay returned ${response.status}`)
  return response
}
function send(message: Message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message))
}
const countdown = new MoveCountdown(
  () => ({
    connected: socket?.readyState === WebSocket.OPEN,
    snapshot,
    generation,
    available,
    reason,
    observedAt,
    pending,
  }),
  (move) => {
    pending = move.commandId
    send(move)
    console.log("Move submitted; waiting for page observation.")
    setTimeout(() => {
      if (pending === move.commandId && snapshot && generation) {
        console.log("Checking move; it will not be replayed.")
        send({ v: 1, type: "snapshot-request", gameId: snapshot.gameId, generation })
      }
    }, 5000).unref()
  },
  (text) => console.log(text),
)
function connect() {
  socket = new WebSocket(relay.replace(/^http/, "ws") + "/v1/ws")
  socket.onopen = () => send({ v: 1, type: "authenticate", credential: token! })
  socket.onclose = () => {
    available = false
    reason = "TV is disconnected. Restart the TV client to reconnect."
    countdown.cancel("Move cancelled: relay disconnected. Nothing was submitted.")
    console.log("Disconnected. Rerun the TV client to reconnect; no moves will be replayed.")
  }
  socket.onmessage = (e) => {
    const message = messageSchema.parse(JSON.parse(String(e.data)))
    if (message.type === "ping") send({ v: 1, type: "pong", nonce: message.nonce })
    else if (message.type === "session") {
      countdown.cancel("Move cancelled: session changed. Nothing was submitted.")
      generation = message.generation
      snapshot = undefined
      available = false
      reason = message.gameId
        ? "Waiting for a fresh snapshot."
        : "No attached game. Choose Connect this game in the extension."
      if (!message.gameId) pending = undefined
      console.log(
        message.gameId
          ? `Attached: ${message.gameId}; synchronizing`
          : "Waiting for an attached game",
      )
    } else if ("generation" in message && message.generation !== generation) return
    else if (message.type === "snapshot") {
      const changed = message.revision !== snapshot?.revision
      snapshot = message
      observedAt = performance.now()
      if (changed)
        console.log(
          `Position ${message.revision}, ${message.turn} to move, result ${message.result || "playing"}`,
        )
    } else if (message.type === "status") {
      const nextReason = message.reason || "Ready for your move"
      if (reason !== nextReason || available !== message.available) console.log(nextReason)
      reason = nextReason
      available = message.available
    } else if (message.type === "outcome") {
      console.log(`Move ${message.outcome}: ${message.reason || "confirmed by page"}`)
      if (message.commandId === pending && message.outcome !== "uncertain") pending = undefined
    } else if (message.type === "error") console.log(message.message)
  }
}
try {
  const stored = z
    .strictObject({ relay: z.string(), credential })
    .parse(JSON.parse(await readFile(file, "utf8")))
  if (stored.relay === relay) token = stored.credential
} catch {
  /* First run or incompatible saved pairing. */
}
if (token) connect()
else {
  challenge = (await (await request("/v1/pairing", "POST")).json()) as typeof challenge
  console.log(
    `TV code: ${challenge!.code}\nEnter it in the extension, then type confirm here. Code expires in five minutes.`,
  )
}
console.log(
  "Commands: confirm | reject | move e2 e4 [q/r/b/n] | cancel | status | snapshot | unpair | quit",
)
console.log("Moves count down for 5 seconds so you can switch from this terminal back to Chrome.")
const input = createInterface({ input: process.stdin, output: process.stdout })
for await (const line of input) {
  const [command, from, to, promotion] = line.trim().replace(/^>\s*/, "").split(/\s+/)
  try {
    if ((command === "confirm" || command === "reject") && challenge) {
      await request(
        `/v1/pairing/${challenge.challengeId}/decision`,
        "POST",
        { confirm: command === "confirm" },
        challenge.token,
      )
      if (command === "reject") {
        console.log("Pairing declined. Rerun for a new code.")
        continue
      }
      const result = (await (
        await request(`/v1/pairing/${challenge.challengeId}`, "GET", undefined, challenge.token)
      ).json()) as { credential: string }
      token = credential.parse(result.credential)
      await mkdir(resolve(file, ".."), { recursive: true })
      await writeFile(file, JSON.stringify({ relay, credential: token }), { mode: 0o600 })
      challenge = undefined
      connect()
    } else if (command === "move") {
      countdown.schedule(from, to, promotion)
    } else if (command === "cancel") countdown.cancel()
    else if (command === "status")
      console.log(
        `${reason}${pending ? " A submitted move is unresolved." : ""}${countdown.scheduled ? " A move is scheduled." : ""}`,
      )
    else if (command === "snapshot" && snapshot && generation)
      send({ v: 1, type: "snapshot-request", gameId: snapshot.gameId, generation })
    else if (command === "unpair" && token) {
      countdown.cancel()
      await request("/v1/pairing", "DELETE", undefined, token)
      await unlink(file).catch(() => {})
      token = undefined
      console.log("Unpaired. Rerun for a new code.")
    } else if (command === "quit") break
    else if (command)
      console.log(
        "Unknown or unavailable command. Use move e2 e4, cancel, status, snapshot, unpair, or quit.",
      )
  } catch (e) {
    console.log(e instanceof Error ? e.message : "Operation failed")
  }
}
countdown.cancel()
socket?.close()
input.close()
