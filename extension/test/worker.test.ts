import { Color, MessageKind, MoveOutcome, VERSION } from "@chess-tv/protocol"
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
const sendMessage = vi.fn<() => Promise<unknown>>()
let listener: (raw: unknown, sender: unknown, reply: (value: any) => void) => void
let local: Record<string, unknown>
let session: Record<string, unknown>
let focused: boolean
let tabActive: boolean
let windowState: "normal" | "minimized"
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
  relay.receive({
    type: MessageKind.Session,
    generation: "generation",
    gameId: null,
    peerConnected: true,
  })
  await action()
  await vi.advanceTimersByTimeAsync(1000)
  await action()
}
beforeEach(() => {
  vi.resetModules()
  vi.useFakeTimers()
  relay.send.mockClear()
  sendMessage.mockReset()
  sendMessage.mockImplementation(async () => ({
    instance: "instance",
    gameId,
    messages: [],
    error: null,
  }))
  focused = true
  tabActive = true
  windowState = "normal"
  gameId = "game-one"
  url = "https://www.chess.com/play/computer/Zach-BOT"
  local = {}
  session = {}
  vi.stubGlobal("__SETTINGS__", {
    relay: "http://127.0.0.1:3000",
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
      get: async () => ({ id: 1, windowId: 1, url, active: tabActive }),
      sendMessage,
      onRemoved: event(),
      onUpdated: event(),
      onActivated: event(),
    },
    windows: { get: async () => ({ focused, state: windowState }), onFocusChanged: event() },
    scripting: { executeScript: vi.fn() },
  })
})
afterEach(() => {
  vi.clearAllTimers()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

it("attaches the foreground supported game without a popup action", async () => {
  await start()
  expect((await action()).gameId).toBe("game-one")
  expect(relay.send).toHaveBeenCalledWith(
    expect.objectContaining({ type: MessageKind.Attachment, gameId: "game-one" }),
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
  url = "https://www.chess.com/play/computer/Zach-BOT"
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBe("game-one")
})
it("dispatches moves from a visible attached tab while the TV simulator has focus", async () => {
  await start()
  focused = false
  relay.receive({
    type: MessageKind.Session,
    generation: "attached-generation",
    gameId,
    peerConnected: true,
  })
  await action()
  await vi.advanceTimersByTimeAsync(1000)
  expect(chrome.tabs.sendMessage).toHaveBeenLastCalledWith(
    1,
    { kind: "sync", generation: "attached-generation", enabled: true },
    { frameId: 0 },
  )
  const move = {
    v: VERSION,
    type: MessageKind.Move,
    gameId,
    generation: "attached-generation",
    revision: 1,
    commandId: "test-move",
    from: "e2",
    to: "e4",
  }
  relay.receive(move)
  await action()
  expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(1, { kind: "move", move }, { frameId: 0 })
})
it.each(["inactive tab", "minimized window"])("blocks game moves for an %s", async (condition) => {
  await start()
  relay.receive({
    type: MessageKind.Session,
    generation: "attached-generation",
    gameId,
    peerConnected: true,
  })
  await action()
  focused = false
  if (condition === "inactive tab") tabActive = false
  else if (condition === "minimized window") windowState = "minimized"
  await vi.advanceTimersByTimeAsync(1000)
  expect(chrome.tabs.sendMessage).toHaveBeenLastCalledWith(
    1,
    { kind: "sync", generation: "attached-generation", enabled: false },
    { frameId: 0 },
  )
  const move = {
    v: VERSION,
    type: MessageKind.Move,
    gameId,
    generation: "attached-generation",
    revision: 1,
    commandId: "blocked-move",
    from: "e2",
    to: "e4",
  }
  relay.receive(move)
  await action()
  expect(chrome.tabs.sendMessage).not.toHaveBeenCalledWith(
    1,
    { kind: "move", move },
    { frameId: 0 },
  )
  expect(relay.send).toHaveBeenCalledWith(
    expect.objectContaining({
      type: MessageKind.Outcome,
      commandId: "blocked-move",
      outcome: MoveOutcome.Rejected,
    }),
  )
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
  relay.receive({
    type: MessageKind.Session,
    generation: "attached-generation",
    gameId,
    peerConnected: true,
  })
  await action()
  gameId = "game-two"
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBeNull()
  relay.receive({
    type: MessageKind.Session,
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
    expect.objectContaining({ type: MessageKind.Attachment, gameId: "game-one" }),
  )
})

it("reattaches the saved game after a worker restart without requiring Chrome focus", async () => {
  await start()
  vi.clearAllTimers()
  vi.resetModules()
  focused = false
  relay.send.mockClear()
  await start()
  expect((await action()).gameId).toBe("game-one")
  expect(relay.send).toHaveBeenCalledWith(
    expect.objectContaining({ type: MessageKind.Attachment, gameId: "game-one" }),
  )
})
it("resumes observation automatically when the TV returns with a new generation", async () => {
  await start()
  relay.receive({ type: MessageKind.Session, generation: "offline", gameId, peerConnected: false })
  await action()
  expect(chrome.tabs.sendMessage).toHaveBeenLastCalledWith(
    1,
    { kind: "sync", generation: "offline", enabled: false },
    { frameId: 0 },
  )
  relay.receive({ type: MessageKind.Error, message: "The other device is disconnected." })
  await action()
  relay.receive({
    type: MessageKind.Session,
    generation: "reconnected",
    gameId,
    peerConnected: true,
  })
  const current = await action()
  expect(current.error).toBeNull()
  expect(current.peerConnected).toBe(true)
  expect(chrome.tabs.sendMessage).toHaveBeenLastCalledWith(
    1,
    { kind: "sync", generation: "reconnected", enabled: true },
    { frameId: 0 },
  )
})

it("defaults automatic attachment to detection instead of a stale saved color", async () => {
  local.playerColor = Color.White
  await start()
  expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(1, { kind: "inspect" }, { frameId: 0 })
})

it("ignores obsolete manual color preferences", async () => {
  local.playerColorMode = Color.Black
  await start()
  expect(chrome.tabs.sendMessage).toHaveBeenCalledWith(1, { kind: "inspect" }, { frameId: 0 })
})

it("attaches as soon as the relay session arrives, without waiting for a timer", async () => {
  await import("../src/worker")
  await action()
  relay.receive({
    type: MessageKind.Session,
    generation: "generation",
    gameId: null,
    peerConnected: true,
  })
  expect((await action()).gameId).toBe("game-one")
})

it.each(["tab", "focus", "load"])("attaches immediately on %s activity", async (trigger) => {
  url = "https://www.chess.com/"
  await start()
  expect((await action()).gameId).toBeNull()
  url = "https://www.chess.com/play/computer/Zach-BOT"
  const source =
    trigger === "tab"
      ? chrome.tabs.onActivated
      : trigger === "focus"
        ? chrome.windows.onFocusChanged
        : chrome.tabs.onUpdated
  const callback = vi.mocked(source.addListener).mock.calls[0]![0]
  if (trigger === "load")
    (callback as (id: number, change: unknown) => void)(1, { status: "complete" })
  else (callback as () => void)()
  expect((await action()).gameId).toBe("game-one")
})

it("keeps synchronizing the attached game after its completed-game URL transition", async () => {
  await start()
  relay.receive({
    type: MessageKind.Session,
    generation: "attached-generation",
    gameId,
    peerConnected: true,
  })
  await action()
  url = "https://www.chess.com/game/computer/2494028730"
  // Chrome event methods are replaced by receiver-independent test spies above.
  // oxlint-disable-next-line typescript/unbound-method
  const updated = vi.mocked(chrome.tabs.onUpdated.addListener).mock.calls[0]![0]
  updated(1, { url }, { id: 1, url } as chrome.tabs.Tab)
  await action()
  await vi.advanceTimersByTimeAsync(1000)
  expect((await action()).gameId).toBe("game-one")
  expect(chrome.tabs.sendMessage).toHaveBeenLastCalledWith(
    1,
    { kind: "sync", generation: "attached-generation", enabled: true },
    { frameId: 0 },
  )
})

it.each(["https://www.chess.com/play/computer", "https://www.chess.com/play/computer?color=black"])(
  "automatically attaches the base bot page %s",
  async (page) => {
    url = page
    await start()
    expect((await action()).gameId).toBe("game-one")
  },
)

it("automatically attaches a live game at its numeric URL", async () => {
  url = "https://www.chess.com/game/186358488264"
  await start()
  expect((await action()).gameId).toBe("game-one")
})

it.each([
  { code: "game_changed", message: "A different game is now open.", detached: true },
  { code: "unavailable", message: "Game changed appearance; wait for animation.", detached: false },
])(
  "routes content errors by $code rather than display text",
  async ({ code, message, detached }) => {
    await start()
    focused = false
    sendMessage.mockResolvedValueOnce({
      instance: "instance",
      gameId,
      messages: [],
      error: { code, message },
    })
    relay.receive({
      type: MessageKind.Session,
      generation: "attached-generation",
      gameId,
      peerConnected: true,
    })
    const current = await action()
    expect(current.gameId).toBe(detached ? null : gameId)
    expect(current.available).toBe(false)
    if (!detached) expect(current.status).toBe(message)
  },
)
