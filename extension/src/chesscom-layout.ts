import { onlineGamePath } from "./chesscom-url"

// Verified DOM layouts share the same board and recorded-history components.
export function gameLayout(doc: Document) {
  const online = onlineGamePath(doc.location?.pathname ?? "")
  const boardId = online ? "board-single" : "board-play-computer"
  const boards = doc.querySelectorAll<HTMLElement>(`wc-chess-board#${boardId}`)
  const lists = doc.querySelectorAll<HTMLElement>(`wc-simple-move-list[board-id="${boardId}"]`)
  if (boards.length !== 1 || lists.length !== 1) return null
  return { board: boards[0]!, list: lists[0]!, online }
}
