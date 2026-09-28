import { spawn, type ChildProcess } from "node:child_process"
import { once } from "node:events"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve, join } from "node:path"

import { chromium, type BrowserContext, type Page } from "playwright"
import { expect, it } from "vite-plus/test"

import { harness, type Client, type Harness } from "../../relay/test/helpers"

const waitFor = <T>(fn: () => T) => expect.poll(fn, { timeout: 10000 })

// Opt-in because this needs a downloaded Chromium and the built simulator extension.
it.skipIf(!process.env.CHESS_TV_BROWSER_TEST)(
  "unpacked MV3 pairing, moves, popup closure, reload and interruption recovery",
  async () => {
    const profile = await mkdtemp(join(tmpdir(), "chess-tv-browser-"))
    let context: BrowserContext | undefined
    let simulator: ChildProcess | undefined
    let h: Harness | undefined
    try {
      h = await harness({ PORT: "3000" })
      simulator = spawn("bun", ["extension/simulator/server.ts"], { stdio: "pipe" })
      await waitFor(async () => {
        try {
          return (await fetch("http://127.0.0.1:4173")).ok
        } catch {
          return false
        }
      }).toBe(true)
      const extension = resolve("extension/dist-simulator")
      context = await chromium.launchPersistentContext(profile, {
        channel: "chromium",
        headless: true,
        args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
      })
      const worker = context.serviceWorkers()[0] || (await context.waitForEvent("serviceworker"))
      const id = new URL(worker.url()).host
      const game = await context.newPage()
      await game.goto("http://127.0.0.1:4173/?game=browser-game")
      const popup = await context.newPage()
      popup.on("pageerror", (e) => {
        console.error("Popup error:", e.message)
      })
      const popupURL = `chrome-extension://${id}/popup.html`
      await popup.goto(popupURL)
      const challenge = (await (await h.request("/v1/pairing", "POST")).json()) as {
        code: string
        challengeId: string
        token: string
      }
      await popup.getByLabel("Six-digit TV code").fill(challenge.code)
      await popup.getByRole("button", { name: "Pair with TV" }).click()
      await waitFor(
        async () => await popup.getByText("Waiting for confirmation", { exact: true }).count(),
      ).toBe(1)
      await h.request(
        `/v1/pairing/${challenge.challengeId}/decision`,
        "POST",
        { confirm: true },
        challenge.token,
      )
      const device = (await (
        await h.request(`/v1/pairing/${challenge.challengeId}`, "GET", undefined, challenge.token)
      ).json()) as { credential: string }
      let tv = await h.client(device.credential)
      await tv.take("authenticated")
      await tv.take("session")
      await waitFor(
        async () => await popup.getByRole("button", { name: "Connect this game" }).isEnabled(),
      ).toBe(true)
      async function popupAction(page: Page, kind: string) {
        // The popup's actual runtime channel; focus remains on the game as with the toolbar popup.
        return page.evaluate((kind) => chrome.runtime.sendMessage({ kind }), kind)
      }
      await game.bringToFront()
      await waitFor(async () => (await popupAction(popup, "state")).gameId).toBe("browser-game")
      async function fresh(client: Client) {
        for (;;) {
          const snapshot = await client.take("snapshot")
          const status = await client.take("status")
          if (status.available && snapshot.generation === status.generation) return snapshot
        }
      }
      let snapshot = await fresh(tv)
      await waitFor(
        async () => await popup.getByText("Ready for your move.", { exact: true }).count(),
      ).toBe(1)
      await popup.locator("main").screenshot({ path: join(tmpdir(), "chess-tv-popup.png") })
      // Closing the popup must leave the worker connection and adapter operational.
      await popup.close()
      await game.bringToFront()
      const command = {
        v: 1 as const,
        type: "move" as const,
        gameId: snapshot.gameId,
        generation: snapshot.generation,
        revision: snapshot.revision,
        commandId: "browser-move",
        from: "e2",
        to: "e4",
      }
      tv.send(command)
      expect((await tv.take("outcome")).outcome).toBe("observed-complete")
      tv.send(command)
      expect((await tv.take("outcome")).outcome).toBe("observed-complete")
      expect(await game.locator('[data-square="e4"]').textContent()).toBe("♙")
      // A new foreground game automatically replaces the old attachment.
      tv.messages = []
      await game.getByRole("button", { name: "New game", exact: true }).click()
      await waitFor(() => tv.messages.some((m) => m.type === "session" && m.gameId === null)).toBe(
        true,
      )
      const reopened = await context.newPage()
      await reopened.goto(popupURL)
      await game.bringToFront()
      tv.messages = []
      snapshot = await fresh(tv)
      // A same-game reload obtains a new generation and fresh observation.
      const beforeReload = snapshot.generation
      await game.reload()
      await game.bringToFront()
      await waitFor(() =>
        tv.messages.some((m) => m.type === "snapshot" && m.generation !== beforeReload),
      ).toBe(true)
      tv.messages = []
      snapshot = await fresh(tv)
      // Tab hiding blocks input, and returning resumes observation.
      await reopened.bringToFront()
      await waitFor(() => tv.messages.some((m) => m.type === "status" && !m.available)).toBe(true)
      await game.bringToFront()
      tv.messages = []
      snapshot = await fresh(tv)
      // A relay restart preserves pairing, but requires a new-generation snapshot.
      const beforeRestart = snapshot.generation
      await h.restart()
      tv = await h.client(device.credential)
      await tv.take("authenticated")
      await tv.take("session")
      snapshot = await fresh(tv)
      expect(snapshot.generation).not.toBe(beforeRestart)
      // Delay page acceptance, interrupt transport, and ensure no automatic replay.
      await game.locator("#delay").selectOption("-1")
      tv.send({
        ...command,
        commandId: "interrupted",
        gameId: snapshot.gameId,
        generation: snapshot.generation,
        revision: snapshot.revision,
      })
      await waitFor(() =>
        tv.messages.some(
          (m) => m.type === "status" && m.reason?.includes("Waiting for the observed"),
        ),
      ).toBe(true)
      tv.ws.close()
      tv = await h.client(device.credential)
      await tv.take("authenticated")
      await tv.take("session")
      await waitFor(() =>
        tv.messages.some(
          (m) => m.type === "status" && !m.available && m.reason?.includes("interrupted"),
        ),
      ).toBe(true)
      expect(await game.locator('[data-square="e2"]').textContent()).toBe("♙")
      // Reload loses adapter deduplication while a move is uncertain: remain blocked.
      await game.reload()
      await game.bringToFront()
      tv.messages = []
      await waitFor(() =>
        tv.messages.some(
          (m) => m.type === "status" && !m.available && m.reason?.includes("interrupted"),
        ),
      ).toBe(true)
      expect(await game.locator('[data-square="e2"]').textContent()).toBe("♙")
      await popupAction(reopened, "attach")
      tv.messages = []
      await fresh(tv)
      await popupAction(reopened, "unpair")
      expect((await popupAction(reopened, "state")).paired).toBe(false)
      expect(await tv.closed).toBe(4003)
    } finally {
      await context?.close()
      if (simulator && simulator.exitCode === null) {
        const exited = once(simulator, "exit")
        simulator.kill("SIGTERM")
        await exited
      }
      await h?.dispose()
      await rm(profile, { recursive: true, force: true })
    }
  },
  60000,
)
