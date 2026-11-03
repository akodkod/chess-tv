import { Color, MoveOutcome, Promotion } from "@chess-tv/protocol"
import { Chess } from "chess.js"

import { gameLayout } from "./chesscom-layout"
import { readChessComTurn } from "./chesscom-turn"

type PageMoveRequest = {
  kind: "bot-move"
  id: string
  token: string
  from: string
  to: string
  color: Color
  promotion?: Promotion
}
type BotReply = { message: string; outcome: MoveOutcome.ObservedComplete | MoveOutcome.Uncertain }

export function position(doc: Document) {
  const turn = readChessComTurn(doc)
  if (turn.state === "unknown") throw new Error(turn.reason)
  if (turn.state !== "latest") throw new Error("Return to the latest recorded move on Chess.com.")
  const { board, list, online } = gameLayout(doc)!
  const pieces = new Map<string, { code: string; element: HTMLElement }>()
  for (const element of board.querySelectorAll<HTMLElement>(".piece")) {
    const square = [...element.classList].find((c) => /^square-[1-8][1-8]$/.test(c))
    const code = [...element.classList].find((c) => /^[wb][pnbrqk]$/.test(c))
    if (!square || !code) throw new Error("Unrecognized board pieces.")
    const key = `${String.fromCharCode(96 + Number(square[7]))}${square[8]}`
    if (pieces.has(key)) throw new Error("Board is animating. Inspect again.")
    pieces.set(key, { code, element })
  }
  if (
    !["wk", "bk"].every((code) => [...pieces.values()].filter((p) => p.code === code).length === 1)
  )
    throw new Error("Board is incomplete.")
  const history = Array.from(list.querySelectorAll(".main-line-ply"), (e) => {
    const notation = e.querySelector(".node-highlight-content")!.cloneNode(true) as HTMLElement
    for (const figurine of notation.querySelectorAll("[data-figurine]")) {
      const piece = figurine.getAttribute("data-figurine")
      if (!piece || !/^[KQRBNP]$/.test(piece)) throw new Error("Unrecognized move notation.")
      figurine.replaceWith(piece)
    }
    return (notation.textContent ?? "").replace(/\s/g, "")
  })
  const fingerprint = JSON.stringify([
    history,
    [...pieces].sort(([a], [b]) => a.localeCompare(b)).map(([s, p]) => [s, p.code]),
  ])
  return { board, list, online, pieces, turn, history, fingerprint }
}

export function squareCenter(square: string, rect: DOMRect, flipped: boolean) {
  let file = square.charCodeAt(0) - 97
  let row = 8 - Number(square[1])
  if (flipped) {
    file = 7 - file
    row = 7 - row
  }
  return {
    x: rect.left + ((file + 0.5) * rect.width) / 8,
    y: rect.top + ((row + 0.5) * rect.height) / 8,
  }
}

// History may already include a quick bot reply. Match our exact appended ply,
// retain the old prefix, and require the requested piece at its destination.
export function moveObserved(
  before: ReturnType<typeof position>,
  after: ReturnType<typeof position>,
  move: PageMoveRequest,
) {
  const piece = before.pieces.get(move.from)!.code
  const promoted = move.promotion ? piece[0] + move.promotion : piece
  const castle = piece[1] === "k" && Math.abs(move.from.charCodeAt(0) - move.to.charCodeAt(0)) === 2
  const notation = after.history[before.history.length]?.replace(/[+#]$/, "")
  const matchingNotation = castle
    ? notation === (move.to[0] === "g" ? "O-O" : "O-O-O")
    : new RegExp(
        `${move.to}${move.promotion ? "=" + move.promotion.toUpperCase() : ""}[+#]?$`,
      ).test(after.history[before.history.length] ?? "")
  // A fast bot capture can remove our piece before the observer runs. In that
  // case, validate the entire resulting board against the appended legal history.
  let boardMatchesAfterReply = false
  if (after.history.length > before.history.length + 1) {
    try {
      const chess = new Chess()
      for (const san of after.history) chess.move(san)
      const pieces = chess
        .board()
        .flat()
        .filter((p) => p !== null)
      boardMatchesAfterReply =
        pieces.length === after.pieces.size &&
        pieces.every((p) => after.pieces.get(p.square)?.code === p.color + p.type)
    } catch {
      /* Incomplete history cannot confirm a move. */
    }
  }
  return (
    after.history.length > before.history.length &&
    before.history.every((text, i) => after.history[i] === text) &&
    (boardMatchesAfterReply ||
      (!after.pieces.has(move.from) && after.pieces.get(move.to)?.code === promoted)) &&
    matchingNotation
  )
}

function clickAt(target: Element, p: { x: number; y: number }) {
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
    const down = type.endsWith("down")
    const init = {
      bubbles: true,
      cancelable: true,
      composed: true,
      clientX: p.x,
      clientY: p.y,
      button: 0,
      buttons: down ? 1 : 0,
      view: window,
    }
    target.dispatchEvent(
      type.startsWith("pointer")
        ? new PointerEvent(type, {
            ...init,
            pointerId: 1,
            pointerType: "mouse",
            isPrimary: true,
          })
        : new MouseEvent(type, init),
    )
  }
}

export type MoveControllerOptions = { allowBackground?: boolean }

export function createMoveController(options: MoveControllerOptions = {}) {
  const instance = crypto.randomUUID()
  let pending = false
  let uncertain = false
  const outcomes = new Map<string, Promise<BotReply>>()
  const token = (p: ReturnType<typeof position>) => instance + p.fingerprint

  async function submit(move: PageMoveRequest): Promise<BotReply> {
    if (pending || uncertain)
      throw new Error("A move is unresolved. Inspect the game; do not resend it.")
    if (!options.allowBackground && document.hidden) throw new Error("Keep the game tab visible.")
    const before = position(document)
    if (token(before) !== move.token) throw new Error("Position changed. Inspect again.")
    if (before.turn.nextColorInLatestPosition !== move.color)
      throw new Error("It is not your turn.")
    const piece = before.pieces.get(move.from)
    if (!piece || piece.code[0] !== move.color[0] || move.from === move.to)
      throw new Error("Choose one of your pieces and a different destination.")
    if (before.pieces.get(move.to)?.code[0] === move.color[0])
      throw new Error("Destination has your piece.")
    const rect = before.board.getBoundingClientRect()
    if (rect.width < 80 || Math.abs(rect.width - rect.height) > 2)
      throw new Error("Board geometry unavailable.")
    // Infer orientation from rendered pieces rather than assuming player color = orientation.
    const orientations = [false, true].filter((flipped) =>
      [...before.pieces].every(([s, p]) => {
        const actual = p.element.getBoundingClientRect()
        const expected = squareCenter(s, rect, flipped)
        return (
          Math.abs(actual.left + actual.width / 2 - expected.x) < 3 &&
          Math.abs(actual.top + actual.height / 2 - expected.y) < 3
        )
      }),
    )
    if (orientations.length !== 1)
      throw new Error("Wait for board animation to finish, then inspect again.")
    const points = [move.from, move.to].map((s) => squareCenter(s, rect, orientations[0]!))
    for (const p of points) {
      const target = document.elementFromPoint(p.x, p.y)
      if (!target || !before.board.contains(target)) throw new Error("The board is obscured.")
    }
    pending = true
    return await new Promise<BotReply>((resolve) => {
      let finished = false
      const finish = (message: string, unresolved: boolean) => {
        if (finished) return
        finished = true
        observer.disconnect()
        clearTimeout(timeout)
        pending = false
        uncertain = unresolved
        resolve({
          message,
          outcome: unresolved ? MoveOutcome.Uncertain : MoveOutcome.ObservedComplete,
        })
      }
      let promotionSelected = false
      const observer = new MutationObserver(() => {
        try {
          if (move.promotion && !promotionSelected) {
            const choice = before.board.querySelector<HTMLElement>(
              `.promotion-window--visible .promotion-piece.${move.color[0]}${move.promotion}`,
            )
            if (choice && (options.allowBackground || !document.hidden)) {
              const r = choice.getBoundingClientRect()
              const target = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
              if (r.width > 0 && target && choice.contains(target)) {
                promotionSelected = true
                clickAt(choice, { x: r.left + r.width / 2, y: r.top + r.height / 2 })
              }
            }
          }
          if (moveObserved(before, position(document), move))
            finish(`Observed ${move.from} → ${move.to} in Chess.com.`, false)
        } catch {
          /* Transitional DOM remains uncertain. */
        }
      })
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        characterData: true,
      })
      const timeout = setTimeout(
        () =>
          finish(
            "Move unconfirmed. Inspect the game. It will not be resent; reload the page only after resolving it.",
            true,
          ),
        5000,
      )
      try {
        for (const p of points) {
          if (!options.allowBackground && document.hidden) throw new Error("Tab hidden")
          const target = document.elementFromPoint(p.x, p.y)
          if (!target || !before.board.contains(target)) throw new Error("Board obscured")
          clickAt(target, p)
        }
      } catch {
        finish("Interaction interrupted. Inspect the game; the move will not be retried.", true)
      }
    })
  }

  return {
    token,
    get unresolved() {
      return pending || uncertain
    },
    async move(action: PageMoveRequest) {
      const known = outcomes.get(action.id)
      if (known) return await known
      if (outcomes.size >= 500) throw new Error("Session move limit reached. Reconnect the game.")
      const result = submit(action)
      outcomes.set(action.id, result)
      return await result
    },
  }
}
