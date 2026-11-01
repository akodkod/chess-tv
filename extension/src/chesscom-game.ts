import type { Message } from "@chess-tv/protocol"
import { Chess } from "chess.js"

import { position } from "./chesscom-move"

type Snapshot = Extract<Message, { type: "snapshot" }>

// Reconstruct rules from the complete recorded game, then independently compare
// every rendered square. Never publish a guessed position during an animation.
export function readGame(doc: Document) {
  const observed = position(doc)
  const chess = new Chess()
  for (const san of observed.history) chess.move(san)
  const board: Snapshot["board"] = chess
    .board()
    .flat()
    .map((p) =>
      p
        ? ((p.color === "w" ? p.type.toUpperCase() : p.type) as NonNullable<
            Snapshot["board"][number]
          >)
        : null,
    )
  for (let i = 0; i < 64; i++) {
    const square = `${String.fromCharCode(97 + (i % 8))}${8 - Math.floor(i / 8)}`
    const piece = observed.pieces.get(square)?.code
    const rendered = piece ? (piece[0] === "w" ? piece[1]!.toUpperCase() : piece[1]!) : null
    if (rendered !== board[i]) throw new Error("Waiting for board and move history to agree.")
  }
  const resultText = doc
    .querySelector('wc-simple-move-list[board-id="board-play-computer"] .game-result')
    ?.textContent?.trim()
  let result: Snapshot["result"] =
    resultText === "1-0"
      ? "white-won"
      : resultText === "0-1"
        ? "black-won"
        : resultText === "1/2-1/2"
          ? "draw"
          : null
  if (chess.isCheckmate()) result = chess.turn() === "w" ? "black-won" : "white-won"
  else if (chess.isStalemate() || chess.isInsufficientMaterial()) result = "draw"
  const players: Snapshot["players"] = { white: null, black: null }
  const clocks: Snapshot["clocks"] = {
    white: { remainingMs: null, running: null },
    black: { remainingMs: null, running: null },
    observedAt: null,
  }
  const rows = doc.querySelectorAll(".player-row-component")
  if (
    rows.length === 2 &&
    [...rows].filter((r) => r.classList.contains("player-row-top")).length === 1
  ) {
    const flipped = observed.board.classList.contains("flipped")
    for (const row of rows) {
      const top = row.classList.contains("player-row-top")
      const color = top === flipped ? "white" : "black"
      players[color] =
        row
          .querySelector('[data-test-element="user-tagline-username"]')
          ?.textContent?.trim()
          .slice(0, 128) || null
      const image = row.querySelector<HTMLImageElement>("img.cc-avatar-img")
      const avatar = avatarURL(image?.currentSrc || image?.getAttribute("src"), doc.baseURI)
      if (avatar) players[color === "white" ? "whiteAvatar" : "blackAvatar"] = avatar
      const remainingMs = parseClock(row.querySelector(".move-time-content")?.textContent ?? "")
      if (remainingMs !== null) {
        clocks[color] = {
          remainingMs,
          running: !result && (chess.turn() === "w" ? "white" : "black") === color,
        }
        clocks.observedAt = Date.now()
      }
    }
  }
  return { ...observed, chess, boardCells: board, result, players, clocks }
}

// Chess.com uses m:ss, h:mm:ss, and fractional seconds near time control.
export function parseClock(text: string): number | null {
  const match = /^(?:(\d+):)?(\d{1,3}):(\d{2})(?:[.,](\d{1,3}))?$/.exec(text.trim())
  if (!match || Number(match[3]) >= 60 || (match[1] && Number(match[2]) >= 60)) return null
  return (
    (Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3])) * 1000 +
    Number((match[4] ?? "").padEnd(3, "0"))
  )
}

function avatarURL(value: string | null | undefined, base: string): string | null {
  if (!value) return null
  try {
    const url = new URL(value, base)
    return url.protocol === "https:" && !url.username && !url.password && url.href.length <= 2048
      ? url.href
      : null
  } catch {
    return null
  }
}
