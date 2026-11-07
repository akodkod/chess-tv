import { Color, MessageKind, MoveOutcome, VERSION } from "@chess-tv/protocol"
import { JSDOM } from "jsdom"
import { expect, it, vi } from "vite-plus/test"

import { LichessAPI, boardCompatible } from "../src/lichess-api"
import {
  LichessAdapter,
  replayLichess,
  type LichessRequest,
  type LichessView,
} from "../src/lichess-driver"
import { lichessGameID } from "../src/lichess-url"

function fixture(): LichessView {
  return {
    accountId: "human",
    connected: true,
    compatible: true,
    observedAt: Date.now(),
    game: {
      id: "Ab12Cd34",
      variant: { key: "standard" },
      speed: "rapid",
      initialFen: "startpos",
      white: { id: "human", name: "Human" },
      black: { aiLevel: 1 },
      state: { moves: "", status: "started", wtime: 600000, btime: 600000 },
    },
  }
}
function setup(view = fixture(), background = true) {
  const dom = new JSDOM("", { url: "https://lichess.org/Ab12Cd34wxyz", pretendToBeVisual: true })
  const rpc = vi.fn(async (request: LichessRequest): Promise<unknown> => {
    if (request.kind === "lichess-state") return structuredClone(view)
    view.game.state.moves = [request.before, request.uci].filter(Boolean).join(" ")
    return { outcome: MoveOutcome.ObservedComplete, message: "Confirmed" }
  })
  const adapter = new LichessAdapter(dom.window.document, rpc, background)
  return { dom, view, rpc, adapter }
}
async function snapshot(adapter: LichessAdapter) {
  const reply = await adapter.handle({ kind: "sync", generation: "generation", enabled: true })
  if (reply.error) throw new Error(reply.error.message)
  return reply.messages.find((m) => m.type === MessageKind.Snapshot)!
}
async function move(adapter: LichessAdapter, from = "e2", to = "e4") {
  const state = await snapshot(adapter)
  return {
    v: VERSION,
    type: MessageKind.Move,
    gameId: state.gameId,
    generation: state.generation,
    revision: state.revision,
    commandId: crypto.randomUUID(),
    from,
    to,
  }
}
it("accepts only real Lichess game paths and exact origins", () => {
  for (const path of [
    "Ab12Cd34",
    "Ab12Cd34wxyz",
    "Ab12Cd34/black",
    "Ab12Cd34/white",
    "game/Ab12Cd34",
    "game/Ab12Cd34/black",
  ])
    expect(lichessGameID(`https://lichess.org/${path}`)).toBe("Ab12Cd34")
  for (const url of [
    "http://lichess.org/Ab12Cd34",
    "https://lichess.org.evil.test/Ab12Cd34",
    "https://a@lichess.org/Ab12Cd34",
    "https://lichess.org/analysis",
    "https://lichess.org/training",
    "https://lichess.org/study/Ab12Cd34",
  ])
    expect(lichessGameID(url)).toBeNull()
})
it("streams a standard game into the existing snapshot contract and confirms exactly one selected move", async () => {
  const { adapter, rpc } = setup()
  const first = await snapshot(adapter)
  expect(first.playerColor).toBe(Color.White)
  expect(first.board.filter(Boolean)).toHaveLength(32)
  expect(first.players.black).toBe("Lichess AI level 1")
  const command = await move(adapter)
  const result = await adapter.handle({ kind: "move", move: command })
  expect(result.messages[0]).toMatchObject({
    type: MessageKind.Outcome,
    outcome: MoveOutcome.ObservedComplete,
  })
  await adapter.handle({ kind: "move", move: command })
  expect(rpc.mock.calls.filter(([r]) => r.kind === "lichess-move")).toHaveLength(1)
  expect((await snapshot(adapter)).board[36]).toBe("P")
})
it("rejects preparation failures and allows a new command after recovery", async () => {
  const { adapter, rpc } = setup()
  const command = await move(adapter)
  rpc.mockRejectedValueOnce(new Error("offline"))
  const result = await adapter.handle({ kind: "move", move: command })
  expect(result.error).toBeNull()
  expect(result.messages[0]).toMatchObject({
    type: MessageKind.Outcome,
    gameId: command.gameId,
    generation: command.generation,
    commandId: command.commandId,
    outcome: MoveOutcome.Rejected,
    reason: "offline",
  })
  expect(rpc.mock.calls.some(([r]) => r.kind === "lichess-move")).toBe(false)
  rpc.mockClear()
  expect((await adapter.handle({ kind: "move", move: command })).messages[0]).toEqual(
    result.messages[0],
  )
  expect(rpc).not.toHaveBeenCalled()
  const next = await adapter.handle({ kind: "move", move: await move(adapter) })
  expect(next.messages[0]).toMatchObject({ outcome: MoveOutcome.ObservedComplete })
})
it("returns a completed command's cached outcome while offline", async () => {
  const { adapter, rpc } = setup()
  const command = await move(adapter)
  const result = await adapter.handle({ kind: "move", move: command })
  rpc.mockRejectedValue(new Error("offline"))
  await adapter.handle({ kind: "inspect" })
  rpc.mockClear()
  const duplicate = await adapter.handle({ kind: "move", move: command })
  expect(duplicate.error).toBeNull()
  expect(duplicate.messages[0]).toEqual(result.messages[0])
  expect(duplicate.messages[0]).toMatchObject({ outcome: MoveOutcome.ObservedComplete })
  expect(rpc).not.toHaveBeenCalled()
})
it("rejects stale moves, wrong turns and account mismatches without submitting", async () => {
  const { adapter, view, rpc } = setup()
  const command = await move(adapter)
  view.game.state.moves = "d2d4"
  const reply = await adapter.handle({ kind: "move", move: command })
  expect(reply.messages[0]).toMatchObject({ outcome: MoveOutcome.Rejected })
  const wrongTurn = await adapter.handle({ kind: "move", move: await move(adapter, "e7", "e5") })
  expect(wrongTurn.messages[0]).toMatchObject({ outcome: MoveOutcome.Rejected })
  view.accountId = "someone-else"
  expect((await adapter.handle({ kind: "inspect" })).error?.message).toContain("account playing")
  expect(rpc.mock.calls.some(([r]) => r.kind === "lichess-move")).toBe(false)
})
it("invalidates old attachment and voice context after takebacks or account/game changes", async () => {
  const { adapter, view } = setup()
  view.game.state.moves = "e2e4 e7e5"
  await snapshot(adapter)
  const voice = adapter.voicePosition().voicePosition!
  view.game.state.moves = ""
  expect((await adapter.handle({ kind: "inspect" })).error?.code).toBe("game_changed")
  await snapshot(adapter)
  expect(adapter.voiceResolve("Pawn d4", [], voice).voiceResolution.state).toBe("rejected")
})
it("blocks unsupported variants, custom positions and incompatible time controls", async () => {
  for (const change of [
    (v: LichessView) => {
      v.game.variant.key = "chess960"
    },
    (v: LichessView) => {
      v.game.initialFen = "custom"
    },
    (v: LichessView) => {
      v.compatible = false
    },
  ]) {
    const v = fixture()
    change(v)
    const { adapter } = setup(v)
    expect((await adapter.handle({ kind: "inspect" })).error).not.toBeNull()
  }
  expect(boardCompatible("rapid", "pool")).toBe(true)
  expect(boardCompatible("blitz", "friend")).toBe(true)
  expect(boardCompatible("blitz", "ai")).toBe(true)
  expect(boardCompatible("blitz", "pool")).toBe(false)
  expect(boardCompatible("bullet", "friend")).toBe(false)
})
it("retains uncertainty after lost submission and does not replay the command", async () => {
  const { adapter, rpc } = setup()
  const command = await move(adapter)
  const original = rpc.getMockImplementation()!
  rpc.mockImplementation(async (request) => {
    if (request.kind === "lichess-move") throw new Error("network lost")
    return original(request)
  })
  const result = await adapter.handle({ kind: "move", move: command })
  expect(result.messages[0]).toMatchObject({ outcome: MoveOutcome.Uncertain })
  expect(result.messages.find((m) => m.type === MessageKind.Status)).toMatchObject({
    available: false,
  })
  await adapter.handle({ kind: "move", move: command })
  expect(rpc.mock.calls.filter(([r]) => r.kind === "lichess-move")).toHaveLength(1)
  expect(adapter.voicePosition().voicePosition).toBeUndefined()
})
it("maps checkmate, resignation, timeout and draw without inventing a result reason", async () => {
  const { adapter, view } = setup()
  view.game.state = { moves: "f2f3 e7e5 g2g4 d8h4", status: "mate", winner: "black" }
  expect(await snapshot(adapter)).toMatchObject({
    result: "black-won",
    resultReason: "checkmate",
    legalMoves: [],
  })
  for (const [status, expected] of [
    ["resign", "resignation"],
    ["outoftime", "timeout"],
    ["draw", null],
  ] as const) {
    const v = fixture()
    v.game.state.status = status
    if (status !== "draw") v.game.state.winner = "white"
    expect(await snapshot(setup(v).adapter)).toMatchObject({ resultReason: expected })
  }
})
it("handles castling, en passant and underpromotion in recorded history", () => {
  const castle = replayLichess("e2e4 e7e5 g1f3 b8c6 f1c4 g8f6 e1h1")
  expect(castle.history.at(-1)).toBe("e1g1")
  expect(castle.chess.get("f1")?.type).toBe("r")
  const ep = replayLichess("e2e4 a7a6 e4e5 d7d5 e5d6")
  expect(ep.chess.get("d5")).toBeUndefined()
  // Legal promotion sequence from the normal starting position.
  const promoted = replayLichess("a2a4 h7h5 a4a5 h5h4 a5a6 h4h3 a6b7 h3g2 b7a8n")
  expect(promoted.chess.get("a8")?.type).toBe("n")
})
it("shares standalone voice input and disables it on a disconnected stream", async () => {
  const { adapter, view } = setup()
  await adapter.prepare()
  const position = adapter.voicePosition().voicePosition!
  const reply = await adapter.voiceMove("Pawn e4", position, crypto.randomUUID())
  expect(reply.messages[0]).toMatchObject({ outcome: MoveOutcome.ObservedComplete })
  view.connected = false
  await adapter.prepare()
  expect(adapter.voicePosition().voicePosition).toBeUndefined()
})

function apiFixture() {
  const view = fixture()
  let stream!: ReadableStreamDefaultController<Uint8Array>
  const send = (event: unknown) =>
    stream.enqueue(new TextEncoder().encode(JSON.stringify(event) + "\n"))
  const post = vi.fn(async () => {
    view.game.state.moves = "e2e4 e7e5"
    send({ type: "gameState", ...view.game.state })
    return new Response('{"ok":true}')
  })
  const fetcher = vi.fn(async (url: string, init?: RequestInit): Promise<Response> => {
    expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer test-token")
    const path = url
    if (path.endsWith("playing?nb=50"))
      return Response.json({
        nowPlaying: [{ gameId: view.game.id, speed: "rapid", source: "ai" }],
      })
    if (path.includes("/move/")) return post()
    return new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          stream = controller
          send({ type: "gameFull", ...view.game })
          init?.signal?.addEventListener("abort", () => controller.close(), { once: true })
        },
      }),
    )
  })
  const api = new LichessAPI(() => ({ id: "human", name: "Human", token: "test-token" }), fetcher)
  return { api, post, send, view }
}
it("host confirms a streamed move even with an immediate AI reply and deduplicates requests", async () => {
  const { api, post } = apiFixture()
  try {
    expect((await api.state("Ab12Cd34")).connected).toBe(true)
    const command = {
      kind: "lichess-move" as const,
      gameId: "Ab12Cd34",
      before: "",
      uci: "e2e4",
      commandId: "command",
    }
    expect(await api.handle(command)).toMatchObject({ outcome: MoveOutcome.ObservedComplete })
    expect(await api.handle(command)).toMatchObject({ outcome: MoveOutcome.ObservedComplete })
    expect(post).toHaveBeenCalledTimes(1)
    expect(await api.handle({ ...command, uci: "d2d4" })).toMatchObject({
      outcome: MoveOutcome.Rejected,
    })
  } finally {
    api.stop()
  }
})
it("host rejects stale history and illegal input before HTTP submission", async () => {
  const { api, post } = apiFixture()
  try {
    await api.state("Ab12Cd34")
    for (const [before, uci] of [
      ["e2e4", "e7e5"],
      ["", "e2e5"],
    ]) {
      expect(
        await api.handle({
          kind: "lichess-move",
          gameId: "Ab12Cd34",
          before: before!,
          uci: uci!,
          commandId: crypto.randomUUID(),
        }),
      ).toMatchObject({ outcome: MoveOutcome.Rejected })
    }
    expect(post).not.toHaveBeenCalled()
  } finally {
    api.stop()
  }
})
it("host rejects moves during rate-limit cooldown without another POST", async () => {
  const { api, post } = apiFixture()
  try {
    await api.state("Ab12Cd34")
    post.mockResolvedValueOnce(new Response(null, { status: 429 }))
    const command = {
      kind: "lichess-move" as const,
      gameId: "Ab12Cd34",
      before: "",
      uci: "e2e4",
      commandId: "rate-limited",
    }
    expect(await api.handle(command)).toMatchObject({ outcome: MoveOutcome.Rejected })
    expect(await api.handle({ ...command, commandId: "cooldown" })).toMatchObject({
      outcome: MoveOutcome.Rejected,
      message: expect.stringContaining("rate limit"),
    })
    expect(post).toHaveBeenCalledTimes(1)
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 60_001)
    expect(await api.handle({ ...command, commandId: "recovered" })).toMatchObject({
      outcome: MoveOutcome.ObservedComplete,
    })
    expect(post).toHaveBeenCalledTimes(2)
  } finally {
    vi.restoreAllMocks()
    api.stop()
  }
})
it("host preserves ambiguous POST failures without retrying", async () => {
  const { api, post } = apiFixture()
  try {
    await api.state("Ab12Cd34")
    post.mockRejectedValue(new Error("lost response"))
    const command = {
      kind: "lichess-move" as const,
      gameId: "Ab12Cd34",
      before: "",
      uci: "e2e4",
      commandId: "command",
    }
    expect(await api.handle(command)).toMatchObject({ outcome: MoveOutcome.Uncertain })
    await api.handle(command)
    expect(post).toHaveBeenCalledTimes(1)
  } finally {
    api.stop()
  }
})

it("hides correspondence clocks, including unlimited and short remaining deadlines", async () => {
  for (const time of [undefined, 2147483647, 86400000, 60000]) {
    const view = fixture()
    view.game.speed = "correspondence"
    view.game.state.wtime = time
    view.game.state.btime = time
    const state = await snapshot(setup(view).adapter)
    expect(state.clocks.white).toEqual({ remainingMs: null, running: null })
    expect(state.clocks.black).toEqual({ remainingMs: null, running: null })
  }
})
it("projects streamed clocks at snapshot time without changing position revision", async () => {
  const view = fixture()
  view.game.state.moves = "e2e4 e7e5"
  view.observedAt = Date.now() - 5000
  const { adapter } = setup(view)
  const first = await snapshot(adapter)
  expect(first.clocks.white.remainingMs).toBeLessThanOrEqual(595000)
  expect(first.clocks.white.running).toBe(true)
  expect(first.clocks.black.remainingMs).toBe(600000)
  const next = await snapshot(adapter)
  expect(next.revision).toBe(first.revision)
  expect(next.clocks.white.remainingMs).toBeLessThanOrEqual(first.clocks.white.remainingMs!)
})
