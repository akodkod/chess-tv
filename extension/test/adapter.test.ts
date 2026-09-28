import { JSDOM } from "jsdom"
import { describe, expect, it } from "vite-plus/test"

import { applyMove, fixture, index, squares, type Scenario } from "../simulator/fixtures"
import { Adapter, clickMove, readPage } from "../src/adapter"
import type { Move } from "../src/messages"
function setup(scenario: Scenario = "normal") {
  let state = fixture(scenario)
  let now = 0
  let clicks = 0
  let accept = true
  const adapter = new Adapter(
    () => structuredClone(state),
    (move) => {
      clicks++
      if (accept) state = applyMove(state, scenario, move.from, move.to, move.promotion ?? null)
    },
    () => now,
  )
  adapter.session("generation", true)
  adapter.observe()
  const move = (extra: Partial<Move> = {}): Move => ({
    v: 1,
    type: "move",
    gameId: state.snapshot.gameId,
    generation: "generation",
    revision: adapter.revision,
    commandId: "command",
    from: "e2",
    to: "e4",
    ...extra,
  })
  return {
    adapter,
    move,
    get state() {
      return state
    },
    set state(value) {
      state = value
    },
    get clicks() {
      return clicks
    },
    delay() {
      accept = false
    },
    advance() {
      now += 6000
    },
  }
}
describe("adapter move evidence", () => {
  it.each([
    ["normal", "e2", "e4", undefined],
    ["black", "e7", "e5", undefined],
    ["castling", "e1", "g1", undefined],
    ["en-passant", "e5", "d6", undefined],
    ...["q", "r", "b", "n"].map(
      (p) => ["promotion", "a7", "a8", p] as [string, string, string, string],
    ),
  ])("observes %s %s-%s %s", (scenario, from, to, promotion) => {
    const s = setup(scenario as Scenario)
    const command = s.move({
      from: from!,
      to: to!,
      ...(promotion ? { promotion: promotion as "q" } : {}),
    })
    expect(s.adapter.move(command)).toContainEqual(
      expect.objectContaining({ type: "outcome", outcome: "observed-complete" }),
    )
    expect(s.state.snapshot.board[index(from!)]).toBeNull()
    expect(s.clicks).toBe(1)
    expect(s.adapter.move(command)).toContainEqual(
      expect.objectContaining({ outcome: "observed-complete" }),
    )
    expect(s.clicks).toBe(1)
  })
  it("ingests direct page input before checking revisions", () => {
    const s = setup(),
      move = s.move()
    s.state = applyMove(s.state, "normal", "e2", "e4", null)
    expect(s.adapter.move(move)).toContainEqual(expect.objectContaining({ outcome: "rejected" }))
    expect(s.clicks).toBe(0)
  })
  it("keeps revisions stable for clocks and advances on turn or result", () => {
    const s = setup(),
      revision = s.adapter.revision
    s.state.snapshot.clocks.white.remainingMs = 5000
    s.adapter.observe()
    expect(s.adapter.revision).toBe(revision)
    s.state.snapshot.turn = "black"
    s.adapter.observe()
    expect(s.adapter.revision).toBe(revision + 1)
    s.state.snapshot.result = "draw"
    s.adapter.observe()
    expect(s.adapter.revision).toBe(revision + 2)
  })
  it("never replays a pending command and rejects a second move", () => {
    const s = setup()
    s.delay()
    const command = s.move()
    s.adapter.move(command)
    s.adapter.move(command)
    expect(s.adapter.move(s.move({ commandId: "second" }))).toContainEqual(
      expect.objectContaining({ outcome: "rejected" }),
    )
    s.advance()
    expect(s.adapter.observe()).toContainEqual(expect.objectContaining({ outcome: "uncertain" }))
    expect(s.clicks).toBe(1)
    s.state = applyMove(s.state, "normal", "e2", "e4", null)
    expect(s.adapter.observe()).toContainEqual(
      expect.objectContaining({ outcome: "observed-complete" }),
    )
  })
  it("requires placement change as well as matching acceptance", () => {
    const s = setup()
    s.delay()
    s.adapter.move(s.move())
    s.state.sequence = 1
    s.state.acceptance = { sequence: 1, from: "e2", to: "e4", promotion: null, accepted: true }
    expect(
      s.adapter.observe().some((m) => m.type === "outcome" && m.outcome === "observed-complete"),
    ).toBe(false)
  })
  it("blocks interrupted pending moves after a generation change", () => {
    const s = setup()
    s.delay()
    s.adapter.move(s.move())
    s.adapter.session("replacement", true)
    expect(s.adapter.move(s.move({ generation: "replacement", commandId: "new" }))).toContainEqual(
      expect.objectContaining({ outcome: "rejected" }),
    )
    expect(s.clicks).toBe(1)
  })
  it("rejects hidden, stale-generation, and wrong-game requests", () => {
    const s = setup()
    s.adapter.move(s.move({ generation: "old" }))
    s.adapter.move(s.move({ gameId: "other", commandId: "other" }))
    s.adapter.session("generation", false)
    s.adapter.move(s.move({ commandId: "hidden" }))
    expect(s.clicks).toBe(0)
  })
  it("rejects an illegal move only after page rejection", () => {
    const s = setup()
    expect(s.adapter.move(s.move({ to: "e5" }))).toContainEqual(
      expect.objectContaining({ outcome: "rejected", reason: "The page rejected the move." }),
    )
  })
  it("ends observation on changed identity", () => {
    const s = setup()
    s.state.snapshot.gameId = "new-game"
    expect(() => s.adapter.observe()).toThrow("Game changed")
  })
})
it("reads and interacts through DOM coordinates in either orientation", () => {
  for (const order of [squares, [...squares].reverse()]) {
    const dom = new JSDOM(
      `<script id="chess-tv-state" type="application/json"></script>${order.map((s) => `<button data-square="${s}"></button>`).join("")}<button data-promotion="n"></button>`,
    )
    const doc = dom.window.document
    doc.querySelector("script")!.textContent = JSON.stringify(fixture())
    expect(readPage(doc).snapshot.board).toHaveLength(64)
    const clicked: string[] = []
    for (const b of doc.querySelectorAll<HTMLButtonElement>("button"))
      b.onclick = () => {
        clicked.push(b.dataset.square || b.dataset.promotion!)
      }
    clickMove(doc, setup().move({ from: "a7", to: "a8", promotion: "n" }))
    expect(clicked).toEqual(["a7", "a8", "n"])
    expect(() => readPage(doc, Date.now() + 5000)).toThrow("stale")
    doc.querySelector("script")!.textContent = "{}"
    expect(() => readPage(doc)).toThrow()
    dom.window.close()
  }
})

it("keeps a previously submitted move uncertain when observation subsequently fails", () => {
  let broken = false
  const state = fixture()
  const adapter = new Adapter(
    () => {
      if (broken) throw new Error("broken")
      return state
    },
    () => {},
  )
  adapter.session("generation", true)
  adapter.observe()
  const move: Move = {
    v: 1,
    type: "move",
    gameId: state.snapshot.gameId,
    generation: "generation",
    revision: adapter.revision,
    commandId: "pending",
    from: "e2",
    to: "e4",
  }
  adapter.move(move)
  broken = true
  expect(adapter.move(move)).toContainEqual(expect.objectContaining({ outcome: "uncertain" }))
  expect(adapter.move(move)).toContainEqual(
    expect.objectContaining({ type: "status", available: false }),
  )
})
