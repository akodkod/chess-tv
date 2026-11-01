type Color = "white" | "black"

export type TurnReading =
  | { state: "unknown"; reason: string }
  | {
      state: "latest" | "history"
      latestPly: number
      displayedPly: number
      nextColorInLatestPosition: Color
      nextColorInDisplayedPosition: Color
    }

// Observed on Chess.com's standard bot page. This reports history evidence, not
// permission to play: player identity, game result and board consistency are separate.
export function readChessComTurn(doc: Document): TurnReading {
  const unknown = (reason: string): TurnReading => ({ state: "unknown", reason })
  const boards = doc.querySelectorAll("wc-chess-board#board-play-computer")
  const lists = doc.querySelectorAll('wc-simple-move-list[board-id="board-play-computer"]')
  if (boards.length !== 1 || lists.length !== 1)
    return unknown("Expected one bot board and its move list.")

  const list = lists[0]!
  const moves = Array.from(list.querySelectorAll(".main-line-ply"))
  // An empty list can mean initial position, loading, reset, or unsupported DOM.
  // Do not silently call all of those White's turn.
  if (!moves.length) return unknown("No complete move history observed yet.")

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
  const nextColor = (ply: number): Color => (ply % 2 === 0 ? "white" : "black")
  return {
    state: displayedPly === latestPly ? "latest" : "history",
    latestPly,
    displayedPly,
    nextColorInLatestPosition: nextColor(latestPly),
    nextColorInDisplayedPosition: nextColor(displayedPly),
  }
}
