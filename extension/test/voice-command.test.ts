import { Chess } from "chess.js"
import { expect, it } from "vite-plus/test"

import { resolveVoiceMove, resolveVoiceAlternatives } from "../src/voice-command"

it.each([
  "move pawn e4",
  "Pawn e four",
  "move pawn to e4",
  "move pawn e2 to e4",
  "move e pawn to e4",
  "move pawn from e2 to e4",
])("resolves %s", (text) => {
  expect(resolveVoiceMove(new Chess(), text)?.lan).toBe("e2e4")
})
it.each(["move knight f3", "move night to f three", "move g knight to f3", "move knight g1 to f3"])(
  "resolves piece and source: %s",
  (text) => {
    expect(resolveVoiceMove(new Chess(), text)?.lan).toBe("g1f3")
  },
)
it("ignores unrelated speech and refuses extra words", () => {
  expect(resolveVoiceMove(new Chess(), "I might move pawn e4")).toBeNull()
  expect(() => resolveVoiceMove(new Chess(), "move pawn e4 and then e5")).toThrow()
  expect(() => resolveVoiceMove(new Chess(), "move pawn e5")).toThrow("not legal")
})
it("requires source disambiguation", () => {
  const chess = new Chess("4k3/8/8/8/8/8/3N3N/4K3 w - - 0 1")
  expect(() => resolveVoiceMove(chess, "move knight to f3")).toThrow("More than one")
  expect(resolveVoiceMove(chess, "move d knight to f3")?.from).toBe("d2")
  expect(resolveVoiceMove(chess, "move knight d2 to f3")?.from).toBe("d2")
})
it.each(["king", "kind", "queen"])("supports castle %s side", (side) => {
  const chess = new Chess("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  expect(resolveVoiceMove(chess, `castle ${side} side`)?.to).toBe(side === "queen" ? "c1" : "g1")
  expect(() => resolveVoiceMove(new Chess(), `castle ${side} side`)).toThrow()
})
it.each(["queen", "rook", "bishop", "knight"])("requires explicit promotion to %s", (piece) => {
  const chess = new Chess("7k/P7/8/8/8/8/8/7K w - - 0 1")
  expect(() => resolveVoiceMove(chess, "move pawn a8")).toThrow("promotion piece")
  expect(resolveVoiceMove(chess, `move pawn to a8 promote to ${piece}`)?.promotion).toBe(
    piece === "knight" ? "n" : piece[0],
  )
})
it("supports captures and en passant, and rejects a false capture", () => {
  const chess = new Chess()
  for (const move of ["e4", "a6", "e5", "d5"]) chess.move(move)
  expect(resolveVoiceMove(chess, "move pawn takes d6")?.isEnPassant()).toBe(true)
  expect(() => resolveVoiceMove(new Chess(), "move pawn takes e4")).toThrow("not legal")
})

it.each(["move pawn g4", "move pawn gee four", "Pawn from gee two to gee for"])(
  "normalizes spoken squares: %s",
  (text) => {
    expect(resolveVoiceMove(new Chess(), text)?.lan).toBe("g2g4")
  },
)
it("does not normalize letter names outside square context", () => {
  expect(() => resolveVoiceMove(new Chess(), "move gee pawn g4")).toThrow()
})
it("accepts alternatives that resolve to the same legal move", () => {
  expect(resolveVoiceAlternatives(new Chess(), ["move pawn gee four", "move pawn g4"])?.lan).toBe(
    "g2g4",
  )
  expect(
    resolveVoiceAlternatives(new Chess(), ["move pawn cheese four", "move pawn g4"])?.lan,
  ).toBe("g2g4")
})
it("rejects conflicting legal alternatives", () => {
  expect(() => resolveVoiceAlternatives(new Chess(), ["move pawn g4", "move pawn e4"])).toThrow(
    "different moves",
  )
})
it("does not use alternatives to hide piece ambiguity", () => {
  const chess = new Chess("4k3/8/8/8/8/8/3N3N/4K3 w - - 0 1")
  expect(() => resolveVoiceAlternatives(chess, ["move knight f3", "move pawn d2 f3"])).toThrow(
    "More than one",
  )
})
it("preserves errors when no alternative is legal", () => {
  expect(() => resolveVoiceAlternatives(new Chess(), ["move pawn e5", "move pawn g5"])).toThrow(
    "not legal",
  )
  expect(resolveVoiceAlternatives(new Chess(), ["hello"])).toBeNull()
})

it("requires explicit promotion even when an alternative suggests a piece", () => {
  const chess = new Chess("7k/P7/8/8/8/8/8/7K w - - 0 1")
  expect(() =>
    resolveVoiceAlternatives(chess, ["move pawn a8", "move pawn a8 promote queen"]),
  ).toThrow("promotion piece")
})

it.each(["G4. Move pawn G4.", "Move, pon, G4."])("accepts reported transcript: %s", (text) => {
  expect(resolveVoiceMove(new Chess(), text)?.lan).toBe("g2g4")
})
it("rejects conflicting fragments and multiple commands", () => {
  expect(() => resolveVoiceMove(new Chess(), "E4. Move pawn G4.")).toThrow()
  expect(() => resolveVoiceMove(new Chess(), "Move e4. Move pawn g4.")).toThrow()
  expect(resolveVoiceMove(new Chess(), "Don't move pawn g4.")).toBeNull()
  expect(() =>
    resolveVoiceAlternatives(new Chess(), ["E4. Move pawn G4.", "move pawn g4"]),
  ).toThrow()
})

it("prepares exact moves, rejects dangerous interpretations, and routes recoverable speech", async () => {
  const { prepareVoiceMove, voiceCandidates } = await import("../src/voice-command")
  const chess = new Chess()
  expect(prepareVoiceMove(chess, ["move pawn g4"])).toEqual({ state: "resolved", move: "g2g4" })
  for (const text of [
    "move pawn e5",
    "don't move pawn e4",
    "move pawn e4 and move pawn d4",
    "move pawn e4 then d4",
    "E4. Move G4.",
  ])
    expect(prepareVoiceMove(chess, [text]).state).toBe("rejected")
  expect(prepareVoiceMove(chess, ["move the pony to f three"]).state).toBe("fallback")
  expect(voiceCandidates(chess)).toHaveLength(20)
  expect(voiceCandidates(chess).find((m) => m.id === "g2g4")?.description).toContain(
    "pawn from g2 to g4",
  )
})

it.each(["d4", "D4.", "dee four", "move d4", "move d2 to d4"])(
  "rejects missing piece: %s",
  async (text) => {
    const { prepareVoiceMove } = await import("../src/voice-command")
    expect(prepareVoiceMove(new Chess(), [text]).state).toBe("rejected")
  },
)
it("requires Pawn and does not infer another piece", () => {
  const chess = new Chess("4k3/8/8/8/8/8/5PP1/4K1N1 w - - 0 1")
  expect(resolveVoiceMove(chess, "Pawn F3")?.lan).toBe("f2f3")
  expect(resolveVoiceMove(chess, "Knight F3")?.lan).toBe("g1f3")
  expect(() => resolveVoiceMove(chess, "Pawn H3")).toThrow("not legal")
})
it("uses the source only when needed to disambiguate rooks", () => {
  const chess = new Chess("4k3/8/8/8/8/8/8/1R2K2R w - - 0 1")
  expect(resolveVoiceMove(chess, "Rook B4")?.lan).toBe("b1b4")
  expect(resolveVoiceMove(chess, "Rook from B1 to B4")?.lan).toBe("b1b4")
  const ambiguous = new Chess("4k3/8/8/8/7R/8/8/1R2K3 w - - 0 1")
  expect(() => resolveVoiceMove(ambiguous, "Rook B4")).toThrow("More than one")
  expect(resolveVoiceMove(ambiguous, "Rook from B1 to B4")?.lan).toBe("b1b4")
})

it.each(["Rook D4", "rook to dee four"])("accepts piece-first rook command: %s", (text) => {
  expect(resolveVoiceMove(new Chess("4k3/8/8/8/8/8/3R4/4K3 w - - 0 1"), text)?.lan).toBe("d2d4")
})
it.each(["Knight F3", "night to f three"])("accepts piece-first knight command: %s", (text) => {
  expect(resolveVoiceMove(new Chess(), text)?.lan).toBe("g1f3")
})
