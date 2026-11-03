import { describe, expect, it } from "vite-plus/test"

import snapshot from "../fixtures/snapshot.json"
import { VERSION } from "./index"
import { parseMessage } from "./index"
describe("protocol", () => {
  it("accepts shared snapshots with explicit unknown clocks", () => {
    expect(parseMessage(snapshot)).toEqual(snapshot)
  })
  it("rejects incompatible versions, extra fields and invalid boards", () => {
    for (const value of [
      { ...snapshot, v: 1 },
      { ...snapshot, secret: "no" },
      { ...snapshot, board: [] },
    ])
      expect(() => parseMessage(value)).toThrow()
  })
  it("accepts optional HTTPS avatars and rejects unsafe image URLs", () => {
    const withAvatar = (url: string) => ({
      ...snapshot,
      players: { ...snapshot.players, whiteAvatar: url },
    })
    expect(parseMessage(withAvatar("https://images.chesscomfiles.com/avatar.png"))).toBeDefined()
    for (const url of [
      "http://example.com/a.png",
      "file:///a.png",
      "javascript:alert(1)",
      "https://user:password@example.com/a.png",
    ])
      expect(() => parseMessage(withAvatar(url))).toThrow()
  })
  it("accepts all promotions and rejects invalid coordinates", () => {
    const move = {
      v: VERSION,
      type: "move",
      gameId: "g",
      generation: "s",
      revision: 0,
      commandId: "c",
      from: "a7",
      to: "a8",
    }
    for (const promotion of ["q", "r", "b", "n"])
      expect(parseMessage({ ...move, promotion }).type).toBe("move")
    expect(() => parseMessage({ ...move, from: "a9" })).toThrow()
  })
})

it("requires and validates move and check metadata", () => {
  for (const key of ["legalMoves", "checkSquare"]) {
    const missing: Record<string, unknown> = { ...snapshot }
    delete missing[key]
    expect(() => parseMessage(missing)).toThrow()
  }
  for (const metadata of [
    { legalMoves: null },
    { legalMoves: [{ from: "a9", to: "a1" }] },
    { legalMoves: [{ from: "a1", to: "a2", promotion: "q" }] },
    { legalMoves: Array(257).fill({ from: "a1", to: "a2" }) },
    { checkSquare: "z9" },
  ])
    expect(() => parseMessage({ ...snapshot, ...metadata })).toThrow()
  expect(parseMessage({ ...snapshot, checkSquare: "e1" })).toBeDefined()
})

it("accepts optional result reasons and rejects unsupported reasons", () => {
  for (const resultReason of [
    "checkmate",
    "stalemate",
    "timeout",
    "resignation",
    "insufficient-material",
    "repetition",
    "fifty-move-rule",
    "agreement",
    null,
  ]) {
    expect(parseMessage({ ...snapshot, result: "white-won", resultReason })).toMatchObject({
      resultReason,
    })
  }
  expect(() => parseMessage({ ...snapshot, resultReason: "guessed" })).toThrow()
})

it("keeps viewing orientation separate from player identity", () => {
  for (const bottomColor of ["white", "black"]) {
    expect(parseMessage({ ...snapshot, playerColor: null, bottomColor })).toMatchObject({
      playerColor: null,
      bottomColor,
    })
  }
  expect(() => parseMessage({ ...snapshot, bottomColor: "unknown" })).toThrow()
})

// Both runtimes read exactly the same contract cases.
import cases from "../fixtures/messages.json"
import { messageSchema, MessageKind } from "./index"
it("covers every message kind in the shared corpus", () => {
  expect(new Set(cases.filter((c) => c.valid).map((c) => c.message.type))).toEqual(
    new Set(Object.values(MessageKind)),
  )
})
for (const entry of cases) {
  it(`shared contract: ${entry.name}`, () => {
    const parsed = messageSchema.safeParse(entry.message)
    expect(parsed.success).toBe(entry.valid)
    if (parsed.success) expect(parsed.data).toEqual(entry.message)
  })
}
