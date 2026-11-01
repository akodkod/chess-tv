import { describe, expect, it } from "vite-plus/test"

import snapshot from "../fixtures/snapshot.json"
import { parseMessage } from "./index"
describe("protocol", () => {
  it("accepts shared snapshots with explicit unknown clocks", () => {
    expect(parseMessage(snapshot)).toEqual(snapshot)
  })
  it("rejects incompatible versions, extra fields and invalid boards", () => {
    for (const value of [
      { ...snapshot, v: 2 },
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
      v: 1,
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
