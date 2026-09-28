import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test"

const relay = vi.hoisted(() => ({ receive: (_message: unknown) => {}, send: vi.fn() }))
vi.mock("../src/relay", () => ({
  RelayLink: class {
    authenticated = true
    constructor(_url: string, _credential: string, receive: typeof relay.receive) {
      relay.receive = receive
    }
    start() {}
    wake() {}
    send = relay.send
  },
}))
vi.mock("../src/pairing", async (original) => {
  const actual = await original<typeof import("../src/pairing")>()
  return {
    ...actual,
    Pairing: class {
      saved = { device: { credential: "test" } }
    },
  }
})
let listener: (raw: unknown, sender: unknown, reply: (value: any) => void) => void
let local: Record<string, unknown>
let session: Record<string, unknown>
let focused: boolean
let gameId: string
let url: string
const event = () => ({ addListener: vi.fn() })
const storage = (values: Record<string, unknown>) => ({
  setAccessLevel: vi.fn(),
  get: async (key: string) => ({ [key]: values[key] }),
  set: async (next: Record<string, unknown>) => {
    Object.assign(values, structuredClone(next))
  },
  remove: async (key: string) => {
    delete values[key]
  },
})
async function action(kind = "state") {
  return new Promise<any>((resolve) =>
    listener(
      { kind },
      {
        id: "extension",
        url: "chrome-extension://extension/popup.html",
      },
      resolve,
    ),
  )
}
async function start() {
  await import("../src/worker")
  await action()
  relay.receive({ type: "session", generation: "generation", gameId: null, peerConnected: true })
  await action()
  await vi.advanceTimersByTimeAsync(1000)
  await action()
}
beforeEach(() => {
  vi.resetModules()
  vi.useFakeTimers()
  relay.send.mockClear()
  focused = true
  gameId = "game-one"
  url = "http://127.0.0.1:4173/"
  local = {}
  session = {}
  vi.stubGlobal("__SETTINGS__", {
    relay: "http://127.0.0.1:3000",
    simulator: true,
    simulatorOrigin: "http://127.0.0.1:4173",
  })
  vi.stubGlobal("chrome", {
    storage: { local: storage(local), session: storage(session) },
    alarms: { create: vi.fn(), onAlarm: event() },
    runtime: {
      id: "extension",
      getURL: (path: string) => `chrome-extension://extension/${path}`,
      onMessage: {
        addListener: (fn: typeof listener) => {
          listener = fn
        },
      },
      onStartup: event(),
      onInstalled: event(),
    },
    tabs: {
      query: async () => [{ id: 1, windowId: 1, url, active: true }],
      get: async () => ({ id: 1, windowId: 1, url, active: true }),
      sendMessage: async () => ({ instance: "instance", gameId, messages: [], error: null }),
      onRemoved: event(),
      onUpdated: event(),
      onActivated: event(),
    },
    windows: { get: async () => ({ focused }), onFocusChanged: event() },
    scripting: { executeScript: vi.fn() },
  })
})
afterEach(() => {
  vi.clearAllTimers()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

it("attaches the foreground simulator without a popup action", async () => {
  await start()
  expect((await action()).gameId).toBe("game-one")
  expect(relay.send).toHaveBeenCalledWith(
    expect.objectContaining({ type: "attachment", gameId: "game-one" }),
  )
})
it("waits for Chrome focus and ignores unsupported pages", async () => {
  focused = false
  await start()
  expect((await action()).gameId).toBeNull()
  focused = true
  url = "https://www.chess.com/"
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBeNull()
  url = "http://127.0.0.1:4173/"
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBe("game-one")
})
it("Disconnect persists a pause across worker restarts", async () => {
  await start()
  await action("disconnect")
  await vi.advanceTimersByTimeAsync(2000)
  expect((await action()).gameId).toBeNull()
  expect(local.autoConnect).toBe(false)
  vi.clearAllTimers()
  vi.resetModules()
  await start()
  expect((await action()).gameId).toBeNull()
  await action("attach")
  expect(local.autoConnect).toBe(true)
  expect((await action()).gameId).toBe("game-one")
})
it("ends the old attachment before automatically attaching a changed game", async () => {
  await start()
  relay.receive({ type: "session", generation: "attached-generation", gameId, peerConnected: true })
  await action()
  gameId = "game-two"
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBeNull()
  relay.receive({
    type: "session",
    generation: "detached-generation",
    gameId: null,
    peerConnected: true,
  })
  await action()
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBe("game-two")
})
it("never clears interrupted move risk by automatically attaching a different game", async () => {
  session.binding = {
    tabId: 1,
    gameId: "old-game",
    instance: "instance",
    risk: true,
    commandId: "pending",
    locked: false,
  }
  await start()
  await vi.advanceTimersByTimeAsync(2000)
  expect((await action()).gameId).toBeNull()
  expect(local.autoConnect).toBe(false)
  expect(relay.send).not.toHaveBeenCalledWith(
    expect.objectContaining({ type: "attachment", gameId: "game-one" }),
  )
})
