import { describe, expect, it } from "vite-plus/test";
import snapshot from "../fixtures/snapshot.json";
import { parseMessage } from "./index";
describe("protocol", () => {
  it("accepts shared snapshots with explicit unknown clocks", () => {
    expect(parseMessage(snapshot)).toEqual(snapshot);
  });
  it("rejects incompatible versions, extra fields and invalid boards", () => {
    for (const value of [
      { ...snapshot, v: 2 },
      { ...snapshot, secret: "no" },
      { ...snapshot, board: [] },
    ])
      expect(() => parseMessage(value)).toThrow();
  });
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
    };
    for (const promotion of ["q", "r", "b", "n"])
      expect(parseMessage({ ...move, promotion }).type).toBe("move");
    expect(() => parseMessage({ ...move, from: "a9" })).toThrow();
  });
});
