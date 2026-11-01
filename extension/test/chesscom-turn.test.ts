import { JSDOM } from "jsdom"
import { describe, expect, it } from "vite-plus/test"

import { readChessComTurn } from "../src/chesscom-turn"

// Minimal markup transcribed from the inspected live e4/d5 bot game.
function page(selected: number | null = 1, notation = ["e4", "d5"]) {
  const rows = notation.map(
    (text, i) => `<div class="main-line-row" data-whole-move-number="${Math.floor(i / 2) + 1}">
      <div data-node="0-${i}" class="node ${i % 2 ? "black" : "white"}-move main-line-ply">
        <span class="node-highlight-content${selected === i ? " selected" : ""}">${text}</span>
      </div></div>`,
  )
  return new JSDOM(`<wc-chess-board id="board-play-computer"></wc-chess-board>
    <wc-simple-move-list board-id="board-play-computer">${rows.join("")}</wc-simple-move-list>`)
    .window.document
}

describe("Chess.com bot turn evidence", () => {
  it("reports White next after e4/d5 at the latest position", () => {
    expect(readChessComTurn(page())).toEqual({
      state: "latest",
      latestPly: 2,
      displayedPly: 2,
      nextColorInLatestPosition: "white",
      nextColorInDisplayedPosition: "white",
    })
  })

  it("separates history navigation from the latest game's next side", () => {
    expect(readChessComTurn(page(0))).toEqual({
      state: "history",
      latestPly: 2,
      displayedPly: 1,
      nextColorInLatestPosition: "white",
      nextColorInDisplayedPosition: "black",
    })
  })

  it("reports Black next while the history ends with White's move", () => {
    expect(readChessComTurn(page(0, ["e4"]))).toMatchObject({
      state: "latest",
      nextColorInLatestPosition: "black",
    })
  })

  it("does not infer White from an empty list or a missing selection", () => {
    expect(readChessComTurn(page(null, []))).toMatchObject({ state: "unknown" })
    expect(readChessComTurn(page(null))).toMatchObject({ state: "unknown" })
  })

  it("rejects truncated history and contradictory move colors", () => {
    const truncated = page()
    truncated.querySelector(".main-line-ply")!.remove()
    expect(readChessComTurn(truncated)).toMatchObject({ state: "unknown" })
    const contradictory = page()
    contradictory.querySelector(".black-move")!.classList.add("white-move")
    expect(readChessComTurn(contradictory)).toMatchObject({ state: "unknown" })
  })

  it("rejects ambiguous selection or multiple boards", () => {
    const ambiguous = page()
    ambiguous.querySelector(".node-highlight-content")!.classList.add("selected")
    expect(readChessComTurn(ambiguous)).toMatchObject({ state: "unknown" })
    const duplicate = page()
    duplicate.body.append(duplicate.querySelector("wc-chess-board")!.cloneNode(true))
    expect(readChessComTurn(duplicate)).toMatchObject({ state: "unknown" })
  })
})
