import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test"

import { fixture } from "../simulator/fixtures"
import { MoveCountdown, type TVState } from "../simulator/move-countdown"
import type { Move } from "../src/messages"
beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())
function setup() {
  let now = 0
  const state: TVState = {
    connected: true,
    generation: "session",
    snapshot: { ...fixture().snapshot, generation: "session", revision: 1 },
    observedAt: 0,
    available: false,
    reason: "Keep the attached game visible in the active Chrome window.",
  }
  const sent: Move[] = [],
    reported: string[] = []
  const countdown = new MoveCountdown(
    () => state,
    (m) => sent.push(m),
    (m) => reported.push(m),
    () => now,
  )
  return {
    state,
    sent,
    reported,
    countdown,
    finish(fresh = true) {
      now = 5000
      if (fresh) state.observedAt = now
      vi.advanceTimersByTime(5000)
    },
  }
}
it("allows typing while Chrome is unfocused, then submits once after returning", () => {
  const s = setup()
  s.countdown.schedule("e2", "e4")
  expect(s.sent).toHaveLength(0)
  s.state.available = true
  s.finish()
  expect(s.sent).toEqual([
    expect.objectContaining({ from: "e2", to: "e4", revision: 1, generation: "session" }),
  ])
  vi.advanceTimersByTime(30000)
  expect(s.sent).toHaveLength(1)
})
it("cancels with the real blocking reason if Chrome stays unfocused; never waits to replay", () => {
  const s = setup()
  s.countdown.schedule("e2", "e4")
  s.finish()
  expect(s.reported.at(-1)).toContain(s.state.reason)
  s.state.available = true
  vi.advanceTimersByTime(30000)
  expect(s.sent).toHaveLength(0)
})
it.each(["generation", "revision", "game", "connection", "pending"])(
  "cancels on changed %s",
  (change) => {
    const s = setup()
    s.countdown.schedule("e2", "e4")
    s.state.available = true
    if (change === "generation") s.state.generation = "replacement"
    if (change === "revision") s.state.snapshot!.revision++
    if (change === "game") s.state.snapshot!.gameId = "other"
    if (change === "connection") s.state.connected = false
    if (change === "pending") s.state.pending = "another"
    s.finish()
    expect(s.sent).toHaveLength(0)
    expect(s.reported.at(-1)).toContain("Nothing was submitted")
  },
)
it("rejects stale observation, manual cancellation, and a second scheduled move", () => {
  const s = setup()
  s.countdown.schedule("e2", "e4")
  expect(() => s.countdown.schedule("d2", "d4")).toThrow("already scheduled")
  s.state.available = true
  s.finish(false)
  expect(s.sent).toHaveLength(0)
  s.state.observedAt = 5000
  s.countdown.schedule("e2", "e4")
  s.countdown.cancel()
  s.finish()
  expect(s.sent).toHaveLength(0)
})
it("explains missing attachment and rejects unresolved moves before scheduling", () => {
  const s = setup()
  s.state.pending = "uncertain"
  expect(() => s.countdown.schedule("e2", "e4")).toThrow("unresolved")
  s.state.pending = undefined
  s.state.snapshot = undefined
  expect(() => s.countdown.schedule("e2", "e4")).toThrow("Connect this game")
})
