import type { Message } from "@chess-tv/protocol"
import { afterEach, expect, it } from "vite-plus/test"

import { harness, pair, type Harness } from "../../relay/test/helpers"
import { Pairing, type Saved } from "../src/pairing"
import { RelayLink } from "../src/relay"
let h: Harness | undefined
let link: RelayLink | undefined
afterEach(async () => {
  link?.stop()
  link = undefined
  await h?.dispose()
  h = undefined
})
async function endpoint() {
  h = await harness()
  return new URL((await h.request("/health")).url).origin
}
it("persists confirmed pairing before connecting, and revokes both credentials", async () => {
  const url = await endpoint()
  const tv = (await (await h!.request("/v1/pairing", "POST")).json()) as {
    code: string
    challengeId: string
    token: string
  }
  let persisted: Saved | undefined
  const client = new Pairing(url, async (saved) => {
    persisted = structuredClone(saved)
  })
  await client.claim(tv.code)
  expect(persisted?.claim).toBeDefined()
  await client.poll()
  expect(client.saved.device).toBeUndefined()
  await h!.request(`/v1/pairing/${tv.challengeId}/decision`, "POST", { confirm: true }, tv.token)
  // A worker restart can resume the stored claim without claiming the code twice.
  const resumed = new Pairing(url, async (saved) => {
    persisted = structuredClone(saved)
  })
  resumed.saved = persisted!
  await resumed.poll()
  expect(persisted?.device?.credential).toMatch(/^[a-f0-9]{64}$/)
  const device = resumed.saved.device!
  await resumed.unpair()
  expect(resumed.saved.device).toBeUndefined()
  expect((await h!.request("/v1/pairing", "DELETE", undefined, device.credential)).status).toBe(401)
})
it("retains credentials and records incomplete remote revocation on transport loss", async () => {
  const url = await endpoint(),
    paired = await pair(h!)
  const client = new Pairing(url, async () => {})
  client.saved = {
    relay: url,
    device: { pairingId: paired.pairingId, credential: paired.extension },
  }
  await h!.dispose()
  h = undefined
  await expect(client.unpair()).rejects.toThrow()
  expect(client.saved.device?.credential).toBe(paired.extension)
  expect(client.saved.revocationPending).toBe(true)
})
it("expires a stored claim without re-claiming", async () => {
  const client = new Pairing("http://127.0.0.1:1", async () => {})
  client.saved.claim = { challengeId: "expired", token: "a".repeat(64), expiresAt: Date.now() - 1 }
  await expect(client.poll()).rejects.toThrow("expired")
  expect(client.saved.claim).toBeUndefined()
})
it("adopts new sessions after TV replacement and stops after extension replacement", async () => {
  const url = await endpoint(),
    paired = await pair(h!),
    received: Message[] = []
  let fatal = false
  link = new RelayLink(
    url.replace("http", "ws") + "/v1/ws",
    paired.extension,
    (m) => received.push(m),
    (_text, stopped) => {
      fatal = stopped
    },
  )
  link.start()
  await expect.poll(() => received.some((m) => m.type === "session")).toBe(true)
  const session = received.find((m) => m.type === "session")!
  if (session.type !== "session") throw new Error()
  link.send({ v: 1, type: "attachment", gameId: "sim-game", generation: session.generation })
  const tv = await h!.client(paired.tv)
  await tv.take("authenticated")
  const first = await tv.take("session")
  const replacement = await h!.client(paired.tv)
  await replacement.take("authenticated")
  const next = await replacement.take("session")
  expect(next.generation).not.toBe(first.generation)
  expect(next.gameId).toBe("sim-game")
  await h!.client(paired.extension)
  await expect.poll(() => fatal).toBe(true)
  expect(link.stopped).toBe(true)
})

it.each(["extension", "tv", "both", "relay"])(
  "restores pairing and game synchronization after %s disconnects",
  async (interruption) => {
    const url = await endpoint()
    const paired = await pair(h!)
    let session: Extract<Message, { type: "session" }> | undefined
    let authentications = 0
    link = new RelayLink(
      url.replace("http", "ws") + "/v1/ws",
      paired.extension,
      (message) => {
        if (message.type === "authenticated") authentications++
        if (message.type === "session") {
          session = message
          if (!message.gameId)
            link!.send({ v: 1, type: "attachment", generation: message.generation, gameId: "game" })
        }
      },
      () => {},
    )
    link.start()
    let tv = await h!.client(paired.tv)
    await tv.take("authenticated")
    await expect.poll(() => session?.gameId === "game" && session.peerConnected).toBe(true)
    const previous = session!.generation
    if (["tv", "both"].includes(interruption)) {
      tv.ws.close()
      await tv.closed
    }
    if (["extension", "both"].includes(interruption)) {
      link.socket!.close()
      await expect.poll(() => link!.authenticated).toBe(false)
    }
    if (interruption === "relay") await h!.restart()
    if (interruption !== "extension") {
      tv = await h!.client(paired.tv)
      await tv.take("authenticated")
    }
    await expect
      .poll(
        () =>
          session?.generation !== previous && session?.gameId === "game" && session.peerConnected,
        { timeout: 10000 },
      )
      .toBe(true)
    expect(link.authenticated).toBe(true)
    expect(authentications).toBe(interruption === "tv" ? 1 : 2)
    link.send({
      v: 1,
      type: "status",
      generation: session!.generation,
      gameId: "game",
      available: true,
      reason: null,
    })
    expect((await tv.take("status")).available).toBe(true)
  },
)
