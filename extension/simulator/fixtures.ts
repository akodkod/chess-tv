import type { Observation, Snapshot } from "../src/messages"
export const squares = Array.from(
  { length: 64 },
  (_, i) => `${"abcdefgh"[i % 8]}${8 - Math.floor(i / 8)}`,
)
export const index = (square: string) => squares.indexOf(square)
export type Scenario = "normal" | "castling" | "en-passant" | "promotion" | "black"
export function fixture(scenario: Scenario = "normal", gameId = "sim-game"): Observation {
  const board: Snapshot["board"] = Array.from({ length: 64 }, () => null)
  const pieces: Record<string, Snapshot["board"][number]> =
    scenario === "normal" || scenario === "black"
      ? {
          a8: "r",
          b8: "n",
          c8: "b",
          d8: "q",
          e8: "k",
          f8: "b",
          g8: "n",
          h8: "r",
          a7: "p",
          b7: "p",
          c7: "p",
          d7: "p",
          e7: "p",
          f7: "p",
          g7: "p",
          h7: "p",
          a2: "P",
          b2: "P",
          c2: "P",
          d2: "P",
          e2: "P",
          f2: "P",
          g2: "P",
          h2: "P",
          a1: "R",
          b1: "N",
          c1: "B",
          d1: "Q",
          e1: "K",
          f1: "B",
          g1: "N",
          h1: "R",
        }
      : scenario === "castling"
        ? { e1: "K", h1: "R", e8: "k" }
        : scenario === "en-passant"
          ? { e1: "K", e8: "k", e5: "P", d5: "p" }
          : { e1: "K", e8: "k", a7: "P" }
  for (const [square, piece] of Object.entries(pieces)) board[index(square)] = piece
  const color = scenario === "black" ? "black" : "white"
  return {
    snapshot: {
      v: 1,
      type: "snapshot",
      gameId,
      generation: "observation",
      revision: 0,
      board,
      players: { white: "Ada", black: "Turing" },
      playerColor: color,
      turn: color,
      clocks: {
        white: { remainingMs: 600000, running: color === "white" },
        black: { remainingMs: 600000, running: color === "black" },
        observedAt: Date.now(),
      },
      result: null,
    },
    updatedAt: Date.now(),
    sequence: 0,
    acceptance: null,
  }
}
// Deliberately scripted fixtures, not a chess legality engine.
export function applyMove(
  state: Observation,
  scenario: Scenario,
  from: string,
  to: string,
  promotion: "q" | "r" | "b" | "n" | null,
  reject = false,
): Observation {
  const next = structuredClone(state)
  const expected =
    scenario === "castling"
      ? ["e1", "g1"]
      : scenario === "en-passant"
        ? ["e5", "d6"]
        : scenario === "promotion"
          ? ["a7", "a8"]
          : scenario === "black"
            ? ["e7", "e5"]
            : ["e2", "e4"]
  const accepted =
    !reject &&
    !state.snapshot.result &&
    from === expected[0] &&
    to === expected[1] &&
    (scenario !== "promotion" || promotion !== null) &&
    !!next.snapshot.board[index(from)]
  next.sequence++
  next.acceptance = { sequence: next.sequence, from, to, promotion, accepted }
  if (accepted) {
    const board = next.snapshot.board
    board[index(to)] = promotion
      ? (promotion.toUpperCase() as Snapshot["board"][number])
      : board[index(from)]!
    board[index(from)] = null
    if (scenario === "castling") {
      board[index("h1")] = null
      board[index("f1")] = "R"
    }
    if (scenario === "en-passant") board[index("d5")] = null
    next.snapshot.turn = next.snapshot.turn === "white" ? "black" : "white"
    next.snapshot.clocks.white.running = next.snapshot.turn === "white"
    next.snapshot.clocks.black.running = next.snapshot.turn === "black"
  }
  next.updatedAt = Date.now()
  return next
}
