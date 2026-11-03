import { Color } from "@chess-tv/protocol"
import { JSDOM } from "jsdom"
import { expect, it } from "vite-plus/test"

import { moveObserved, position, squareCenter } from "../src/chesscom-move"

function snapshot(moves: string[], pawn = "54") {
  const doc = new JSDOM(`<wc-chess-board id="board-play-computer">
    <div class="piece wk square-51"></div><div class="piece bk square-58"></div>
    <div class="piece wp square-${pawn}"></div></wc-chess-board>
    <wc-simple-move-list board-id="board-play-computer">${moves
      .map(
        (san, i) => `
      <div class="main-line-row" data-whole-move-number="${Math.floor(i / 2) + 1}">
        <div class="main-line-ply ${i % 2 ? Color.Black : Color.White}-move" data-node="0-${i}">
          <span class="node-highlight-content ${i === moves.length - 1 ? "selected" : ""}">${san}</span>
        </div></div>`,
      )
      .join("")}</wc-simple-move-list>`).window.document
  return position(doc)
}

const move = {
  kind: "bot-move" as const,
  id: "test",
  token: "test",
  from: "e4",
  to: "e5",
  color: Color.White as const,
}

it("confirms e5 even when a bot reply has already appended another ply", () => {
  const before = snapshot(["e4", "d5"])
  expect(moveObserved(before, snapshot(["e4", "d5", "e5"], "55"), move)).toBe(true)
  expect(moveObserved(before, snapshot(["e4", "d5", "e5", "Nc6"], "55"), move)).toBe(true)
})

it("requires both history and actual piece movement", () => {
  const before = snapshot(["e4", "d5"])
  expect(moveObserved(before, snapshot(["e4", "d5", "e5"]), move)).toBe(false)
  expect(moveObserved(before, snapshot(["e4", "d5"], "55"), move)).toBe(false)
  expect(moveObserved(before, snapshot(["e4", "d5", "Nf3"], "55"), move)).toBe(false)
})

it("does not confirm a different history after a restart or undo", () => {
  expect(moveObserved(snapshot(["e4", "d5"]), snapshot(["e4", "d6", "e5"], "55"), move)).toBe(false)
})

it("maps coordinates in both orientations", () => {
  const { DOMRect } = new JSDOM().window
  const rect = new DOMRect(100, 50, 800, 800)
  expect(squareCenter("e5", rect, false)).toEqual({ x: 550, y: 400 })
  expect(squareCenter("e5", rect, true)).toEqual({ x: 450, y: 500 })
})
