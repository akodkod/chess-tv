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
  const resultText = observed.list.querySelector(".game-result")?.textContent?.trim()
  let result: Snapshot["result"] =
    resultText === "1-0"
      ? "white-won"
      : resultText === "0-1"
        ? "black-won"
        : resultText === "1/2-1/2"
          ? "draw"
          : null
  let resultReason: Snapshot["resultReason"] = null
  if (chess.isCheckmate()) {
    result = chess.turn() === "w" ? "black-won" : "white-won"
    resultReason = "checkmate"
  } else if (chess.isStalemate()) {
    result = "draw"
    resultReason = "stalemate"
  } else if (chess.isInsufficientMaterial()) {
    result = "draw"
    resultReason = "insufficient-material"
  }
  // Only accept a page-supplied reason once the move list confirms a result.
  // The modal can appear a rendering pass later than the final board position.
  if (result && !resultReason) {
    const subtitle = doc
      .querySelector(".game-over-modal-subtitle-text")
      ?.textContent?.trim()
      .toLowerCase()
    if (subtitle && /\b(time(?:out)?|time out)\b/.test(subtitle)) resultReason = "timeout"
    else if (subtitle?.includes("resignation")) resultReason = "resignation"
    else if (result === "draw") {
      if (chess.isThreefoldRepetition()) resultReason = "repetition"
      else if (chess.isDrawByFiftyMoves()) resultReason = "fifty-move-rule"
      else if (subtitle?.includes("agreement")) resultReason = "agreement"
    }
  }
  const players: Snapshot["players"] = { white: null, black: null }
  const clocks: Snapshot["clocks"] = {
    white: { remainingMs: null, running: null },
    black: { remainingMs: null, running: null },
    observedAt: null,
  }
  const rows = doc.querySelectorAll(observed.online ? ".player-component" : ".player-row-component")
  const topClass = observed.online ? "player-top" : "player-row-top"
  if (rows.length === 2 && [...rows].filter((r) => r.classList.contains(topClass)).length === 1) {
    const flipped = observed.board.classList.contains("flipped")
    for (const row of rows) {
      const top = row.classList.contains(topClass)
      const color = top === flipped ? "white" : "black"
      players[color] =
        row
          .querySelector('[data-test-element="user-tagline-username"]')
          ?.textContent?.trim()
          .slice(0, 128) || null
      const image = row.querySelector<HTMLImageElement>("img.cc-avatar-img")
      const avatar = avatarURL(image?.currentSrc || image?.getAttribute("src"), doc.baseURI)
      if (avatar) players[color === "white" ? "whiteAvatar" : "blackAvatar"] = avatar
      const clock = row.querySelector(".clock-component")
      if (
        observed.online &&
        (!clock?.classList.contains(`clock-${color}`) ||
          clock.classList.contains(`clock-${color === "white" ? "black" : "white"}`))
      )
        throw new Error("Waiting for player colors and clocks to agree.")
      const remainingMs = parseClock(
        row.querySelector(observed.online ? ".clock-time-monospace" : ".move-time-content")
          ?.textContent ?? "",
      )
      if (remainingMs !== null) {
        clocks[color] = {
          remainingMs,
          running:
            !result &&
            (observed.online
              ? clock!.classList.contains("clock-player-turn")
              : (chess.turn() === "w" ? "white" : "black") === color),
        }
        clocks.observedAt = Date.now()
      }
    }
  }
  const profiles = doc.querySelectorAll<HTMLAnchorElement>('a[data-user-activity-key="profile"]')
  let playerColor: Snapshot["playerColor"] = null
  if (profiles.length === 1 && rows.length === 2) {
    const profile = new URL(profiles[0]!.href, doc.baseURI)
    const username = /^\/member\/([^/]+)\/?$/.exec(profile.pathname)?.[1]?.toLowerCase()
    if (profile.origin === "https://www.chess.com" && username) {
      const matches = (["white", "black"] as const).filter(
        (color) => players[color]?.toLowerCase() === username,
      )
      if (matches.length === 1) playerColor = matches[0]!
    }
  }
  const activeClocks = doc.querySelectorAll(".player-component .clock-player-turn")
  const followedUser = new URL(doc.URL).searchParams.get("username")?.toLowerCase()
  const followedColors = (["white", "black"] as const).filter(
    (color) => followedUser && players[color]?.toLowerCase() === followedUser,
  )
  const bottomColor =
    playerColor ??
    (followedColors.length === 1
      ? followedColors[0]!
      : observed.board.classList.contains("flipped")
        ? "black"
        : "white")
  const playable =
    !observed.online ||
    (activeClocks.length === 1 &&
      activeClocks[0]!.classList.contains(`clock-${chess.turn() === "w" ? "white" : "black"}`) &&
      clocks.white.remainingMs !== null &&
      clocks.black.remainingMs !== null)
  return {
    ...observed,
    playable,
    chess,
    boardCells: board,
    result,
    resultReason,
    players,
    clocks,
    playerColor,
    bottomColor,
  }
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
