import { z } from "zod"

import { readChessComTurn } from "./chesscom-turn"

const request = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("bot-inspect") }),
  z.strictObject({
    kind: z.literal("bot-move"),
    id: z.string().uuid(),
    token: z.string(),
    from: z.string().regex(/^[a-h][1-8]$/),
    to: z.string().regex(/^[a-h][1-8]$/),
    color: z.enum(["white", "black"]),
  }),
])
type MoveRequest = Extract<z.infer<typeof request>, { kind: "bot-move" }>
export type BotReply = { token?: string; turn?: string; message: string }

export function position(doc: Document) {
  const turn = readChessComTurn(doc)
  if (turn.state !== "latest") throw new Error("Return to the latest recorded move in Chrome.")
  const board = doc.querySelector<HTMLElement>("wc-chess-board#board-play-computer")!
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
  const history = Array.from(
    doc.querySelectorAll("wc-simple-move-list .main-line-ply"),
    (e) => e.textContent?.trim() ?? "",
  )
  const fingerprint = JSON.stringify([
    history,
    [...pieces].sort(([a], [b]) => a.localeCompare(b)).map(([s, p]) => [s, p.code]),
  ])
  return { board, pieces, turn, history, fingerprint }
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
  move: MoveRequest,
) {
  const piece = before.pieces.get(move.from)!.code
  return (
    after.history.length > before.history.length &&
    before.history.every((text, i) => after.history[i] === text) &&
    !after.pieces.has(move.from) &&
    after.pieces.get(move.to)?.code === piece &&
    new RegExp(`${move.to}[+#]?$`).test(after.history[before.history.length]!)
  )
}

export function installChessComMoves() {
  const scope = globalThis as typeof globalThis & { chessTVBotInstalled?: boolean }
  if (
    scope.chessTVBotInstalled ||
    location.origin !== "https://www.chess.com" ||
    !location.pathname.startsWith("/play/computer/")
  )
    return
  scope.chessTVBotInstalled = true
  const instance = crypto.randomUUID()
  let pending = false
  let uncertain = false
  const outcomes = new Map<string, Promise<BotReply>>()
  const token = (p: ReturnType<typeof position>) => instance + p.fingerprint

  async function submit(move: MoveRequest): Promise<BotReply> {
    if (pending || uncertain)
      throw new Error("A move is unresolved. Inspect Chrome; do not resend it.")
    if (document.hidden) throw new Error("Keep the bot tab visible.")
    const before = position(document)
    if (token(before) !== move.token) throw new Error("Position changed. Inspect again.")
    if (before.turn.nextColorInLatestPosition !== move.color)
      throw new Error("It is not your turn.")
    const piece = before.pieces.get(move.from)
    if (!piece || piece.code[0] !== move.color[0] || move.from === move.to)
      throw new Error("Choose one of your pieces and a different destination.")
    if (before.pieces.get(move.to)?.code[0] === move.color[0])
      throw new Error("Destination has your piece.")
    if (
      (piece.code[1] === "p" && /[18]$/.test(move.to)) ||
      (piece.code[1] === "k" && Math.abs(move.from.charCodeAt(0) - move.to.charCodeAt(0)) === 2)
    )
      throw new Error("Promotion and castling are not supported by this test build yet.")
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
        resolve({ message })
      }
      const observer = new MutationObserver(() => {
        try {
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
            "Move unconfirmed. Inspect Chrome. It will not be resent; reload the page only after resolving it.",
            true,
          ),
        5000,
      )
      try {
        for (const p of points) {
          if (document.hidden) throw new Error("Tab hidden")
          const target = document.elementFromPoint(p.x, p.y)
          if (!target || !before.board.contains(target)) throw new Error("Board obscured")
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
      } catch {
        finish("Interaction interrupted. Inspect Chrome; the move will not be retried.", true)
      }
    })
  }

  chrome.runtime.onMessage.addListener((raw: unknown, sender, reply) => {
    if (
      sender.id !== chrome.runtime.id ||
      sender.tab ||
      sender.url !== chrome.runtime.getURL("popup.html")
    )
      return
    const parsed = request.safeParse(raw)
    if (!parsed.success) return
    const action = parsed.data
    void (async (): Promise<BotReply> => {
      if (action.kind === "bot-inspect") {
        if (pending || uncertain)
          return {
            message: "Move unresolved. Inspect Chrome before reloading or trying another move.",
          }
        const p = position(document)
        return {
          token: token(p),
          turn: p.turn.nextColorInLatestPosition,
          message: `${p.turn.nextColorInLatestPosition} to move; ${p.turn.latestPly} plies recorded.`,
        }
      }
      const known = outcomes.get(action.id)
      if (known) return await known
      if (outcomes.size >= 500) throw new Error("Test session limit reached. Reload the page.")
      const result = submit(action)
      outcomes.set(action.id, result)
      return await result
    })()
      .then(reply)
      .catch((e: unknown) =>
        reply({ message: e instanceof Error ? e.message : "Move unavailable." }),
      )
    return true
  })
}
