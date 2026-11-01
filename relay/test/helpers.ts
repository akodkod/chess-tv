import { spawn, type ChildProcess } from "node:child_process"
import { once } from "node:events"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Message } from "@chess-tv/protocol"

export class Client {
  ws: WebSocket
  messages: Message[] = []
  waiters = new Set<() => void>()
  closed: Promise<number>
  constructor(url: string, heartbeat = true) {
    this.ws = new WebSocket(url)
    this.closed = new Promise((resolve) =>
      this.ws.addEventListener("close", (e) => resolve(e.code)),
    )
    this.ws.addEventListener("message", (e) => {
      const msg = JSON.parse(String(e.data)) as Message
      if (heartbeat && msg.type === "ping") this.send({ v: 1, type: "pong", nonce: msg.nonce })
      else {
        this.messages.push(msg)
        for (const waiter of this.waiters) waiter()
      }
    })
  }
  async open() {
    if (this.ws.readyState !== WebSocket.OPEN)
      await new Promise<void>((resolve, reject) => {
        this.ws.addEventListener("open", () => resolve(), { once: true })
        this.ws.addEventListener("error", reject, { once: true })
      })
    return this
  }
  send(message: Message) {
    this.ws.send(JSON.stringify(message))
  }
  async take<T extends Message["type"]>(type: T): Promise<Extract<Message, { type: T }>> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(check)
        reject(new Error(`Missing ${type}; received ${JSON.stringify(this.messages)}`))
      }, 3000)
      const check = () => {
        const index = this.messages.findIndex((m) => m.type === type)
        if (index < 0) return
        clearTimeout(timer)
        this.waiters.delete(check)
        resolve(this.messages.splice(index, 1)[0] as Extract<Message, { type: T }>)
      }
      this.waiters.add(check)
      check()
    })
  }
}
export async function harness(env: Record<string, string> = {}) {
  const dir = await mkdtemp(join(tmpdir(), "chess-relay-"))
  let process: ChildProcess
  let url = ""
  let logs = ""
  const clients: Client[] = []
  async function start() {
    process = spawn("bun", ["relay/src/index.ts"], {
      env: {
        ...globalThis.process.env,
        NODE_ENV: "test",
        PORT: url ? new URL(url).port : "0",
        DATABASE_PATH: join(dir, "relay.db"),
        ...env,
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Startup timeout: ${logs}`)), 10000)
      process.once("error", (e) => {
        clearTimeout(timer)
        reject(e)
      })
      process.once("exit", (code) => {
        clearTimeout(timer)
        reject(new Error(`Relay exit ${code}: ${logs}`))
      })
      process.stdout!.on("data", (data: Buffer) => {
        logs += data.toString()
        const match = logs
          .match(/"port":(\d+)/g)
          ?.at(-1)
          ?.match(/\d+/)
        if (match) {
          url = `http://127.0.0.1:${match[0]}`
          clearTimeout(timer)
          resolve()
        }
      })
      process.stderr!.on("data", (data: Buffer) => {
        logs += data.toString()
      })
    })
  }
  async function stop() {
    if (!process.pid || process.exitCode !== null || process.signalCode !== null) return
    const exited = once(process, "exit")
    process.kill("SIGTERM")
    const timer = setTimeout(() => process.kill("SIGKILL"), 3000)
    await exited
    clearTimeout(timer)
  }
  async function request(path: string, method = "GET", body?: unknown, token?: string) {
    return fetch(`${url}${path}`, {
      method,
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
  }
  try {
    await start()
  } catch (error) {
    await stop()
    await rm(dir, { recursive: true, force: true })
    throw error
  }
  return {
    dir,
    request,
    logs: () => logs,
    async restart() {
      await stop()
      logs = ""
      await start()
    },
    async client(token?: string, heartbeat = true) {
      const client = new Client(url.replace("http:", "ws:") + "/v1/ws", heartbeat)
      clients.push(client)
      await client.open()
      if (token) client.send({ v: 1, type: "authenticate", credential: token })
      return client
    },
    async dispose() {
      for (const client of clients) client.ws.close()
      await stop()
      await rm(dir, { recursive: true, force: true })
    },
  }
}
export type Harness = Awaited<ReturnType<typeof harness>>
export async function pair(h: Harness) {
  const create = await h.request("/v1/pairing", "POST")
  const tv = (await create.json()) as { challengeId: string; code: string; token: string }
  const claim = await h.request("/v1/pairing/claim", "POST", { code: tv.code })
  const extension = (await claim.json()) as { token: string }
  const decision = await h.request(
    `/v1/pairing/${tv.challengeId}/decision`,
    "POST",
    { confirm: true },
    tv.token,
  )
  if (decision.status !== 200) throw new Error(`Pairing failed ${decision.status}`)
  const tvResult = (await (
    await h.request(`/v1/pairing/${tv.challengeId}`, "GET", undefined, tv.token)
  ).json()) as { credential: string; pairingId: string }
  const extensionResult = (await (
    await h.request(`/v1/pairing/${tv.challengeId}`, "GET", undefined, extension.token)
  ).json()) as { credential: string }
  return {
    tv: tvResult.credential,
    extension: extensionResult.credential,
    pairingId: tvResult.pairingId,
    challengeId: tv.challengeId,
    tvToken: tv.token,
    code: tv.code,
  }
}
