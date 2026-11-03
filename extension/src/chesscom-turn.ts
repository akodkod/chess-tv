import { Color } from "@chess-tv/protocol"

import { gameLayout } from "./chesscom-layout"

export type TurnReading =
  | { state: "unknown"; reason: string }
  | {
      state: "latest" | "history"
      latestPly: number
      displayedPly: number
      nextColorInLatestPosition: Color
      nextColorInDisplayedPosition: Color
    }

// Observed on Chess.com's standard bot and online game pages. This reports history evidence, not
// permission to play: player identity, game result and board consistency are separate.
export function readChessComTurn(doc: Document): TurnReading {
  const unknown = (reason: string): TurnReading => ({ state: "unknown", reason })
  const layout = gameLayout(doc)
  if (!layout) return unknown("This game layout is not supported yet.")
  const { board, list } = layout
  const moves = Array.from(list.querySelectorAll(".main-line-ply"))
  // An empty history is actionable only with the complete standard start board.
  if (!moves.length) {
    const expected = new Map<string, string>()
    for (let file = 1; file <= 8; file++) {
      const piece = "rnbqkbnr"[file - 1]!
      for (const [rank, code] of [
        [1, `w${piece}`],
        [2, "wp"],
        [7, "bp"],
        [8, `b${piece}`],
      ] as const)
        expected.set(`square-${file}${rank}`, code)
    }
    const pieces = board.querySelectorAll(".piece")
    if (
      pieces.length !== 32 ||
      ![...pieces].every((p) => {
        const square = [...p.classList].find((c) => expected.has(c))
        if (!square || !p.classList.contains(expected.get(square)!)) return false
        expected.delete(square)
        return true
      })
    )
      return unknown("Waiting for a complete starting position.")
    return {
      state: "latest",
      latestPly: 0,
      displayedPly: 0,
      nextColorInLatestPosition: Color.White,
      nextColorInDisplayedPosition: Color.White,
    }
  }

  for (const [index, move] of moves.entries()) {
    const white = index % 2 === 0
    const row = move.closest(".main-line-row")
    if (
      move.getAttribute("data-node") !== `0-${index}` ||
      row?.getAttribute("data-whole-move-number") !== String(Math.floor(index / 2) + 1) ||
      move.classList.contains("white-move") !== white ||
      move.classList.contains("black-move") === white ||
      !move.querySelector(".node-highlight-content")?.textContent?.trim()
    )
      return unknown("Move history is incomplete or has an unsupported structure.")
  }

  const selected = list.querySelectorAll(".node-highlight-content.selected")
  if (selected.length !== 1)
    return unknown("Displayed position is not identified by one selected move.")
  const selectedIndex = moves.indexOf(selected[0]!.closest(".main-line-ply")!)
  if (selectedIndex < 0) return unknown("Selected move is outside the main line.")
  const latestPly = moves.length
  const displayedPly = selectedIndex + 1
  const nextColor = (ply: number): Color => (ply % 2 === 0 ? Color.White : Color.Black)
  return {
    state: displayedPly === latestPly ? "latest" : "history",
    latestPly,
    displayedPly,
    nextColorInLatestPosition: nextColor(latestPly),
    nextColorInDisplayedPosition: nextColor(displayedPly),
  }
}
