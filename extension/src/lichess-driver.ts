import {
  Color,
  GameResult,
  GameResultReason,
  MoveOutcome,
  pieceSchema,
  type MoveRequest,
} from "@chess-tv/protocol"
import { Chess, DEFAULT_POSITION, type Square } from "chess.js"
import { z } from "zod"

import { GameAdapter } from "./game-adapter"
import type { GameDriver, GamePosition } from "./game-driver"
import { lichessGameID } from "./lichess-url"

export const lichessState = z.object({
  moves: z.string().max(32768),
  status: z.string(),
  winner: z.enum(["white", "black"]).optional(),
  wtime: z.number().nonnegative().optional(),
  btime: z.number().nonnegative().optional(),
})
const player = z.object({
  id: z.string().optional(),
  name: z.string().optional(),
  aiLevel: z.number().optional(),
})
export const lichessGame = z.object({
  id: z.string().regex(/^[a-zA-Z0-9]{8}$/),
  variant: z.object({ key: z.string() }),
  speed: z.string(),
  initialFen: z.string(),
  white: player,
  black: player,
  state: lichessState,
})
export const lichessView = z.object({
  accountId: z.string(),
  game: lichessGame,
  connected: z.boolean(),
  compatible: z.boolean(),
  observedAt: z.number(),
})
export const lichessRequest = z.discriminatedUnion("kind", [
  z.strictObject({
    kind: z.literal("lichess-state"),
    gameId: z.string().regex(/^[a-zA-Z0-9]{8}$/),
  }),
  z.strictObject({
    kind: z.literal("lichess-move"),
    gameId: z.string().regex(/^[a-zA-Z0-9]{8}$/),
    uci: z.string().regex(/^[a-h][1-8][a-h][1-8][qrbn]?$/),
    before: z.string().max(32768),
    commandId: z.string().min(1).max(128),
  }),
])
export type LichessRequest = z.infer<typeof lichessRequest>
export type LichessView = z.infer<typeof lichessView>
export type LichessRPC = (request: LichessRequest) => Promise<unknown>

// The Board stream uses king-to-rook castling notation; chess.js uses king destination.
export function replayLichess(moves: string) {
  const chess = new Chess()
  const history: string[] = []
  for (const raw of moves.trim().split(/\s+/).filter(Boolean)) {
    let uci = raw
    if (chess.get(raw.slice(0, 2) as Square)?.type === "k") {
      uci =
        ({ e1h1: "e1g1", e1a1: "e1c1", e8h8: "e8g8", e8a8: "e8c8" } as Record<string, string>)[
          raw
        ] ?? raw
    }
    const move = chess.move({
      from: uci.slice(0, 2),
      to: uci.slice(2, 4),
      ...(uci[4] ? { promotion: uci[4] } : {}),
    })
    history.push(move.lan)
  }
  return { chess, history }
}

class LichessDriver implements GameDriver {
  readonly name = "Lichess"
  private view?: LichessView
  private uncertain = false
  constructor(
    private doc: Document,
    private rpc: LichessRPC,
    private allowBackground: boolean,
  ) {}
  get visible() {
    return this.allowBackground || !this.doc.hidden
  }
  get unresolved() {
    return this.uncertain
  }
  reset() {
    this.uncertain = false
  }
  async prepare() {
    const gameId = lichessGameID(this.doc.URL)
    if (!gameId) throw new Error("Open a standard Lichess game.")
    this.view = undefined // Never retain a playable stale state after a failed refresh.
    const view = lichessView.parse(await this.rpc({ kind: "lichess-state", gameId }))
    if (gameId !== lichessGameID(this.doc.URL) || view.game.id !== gameId)
      throw new Error("Game changed. Reconnect the current game.")
    this.view = view
  }
  read(): GamePosition {
    const v = this.view
    if (!v || v.game.id !== lichessGameID(this.doc.URL))
      throw new Error("Waiting for Lichess game state.")
    const g = v.game
    if (g.variant.key !== "standard" || !["startpos", DEFAULT_POSITION].includes(g.initialFen))
      throw new Error("Only standard Lichess games from the starting position are supported.")
    const playerColor =
      g.white.id?.toLowerCase() === v.accountId.toLowerCase()
        ? Color.White
        : g.black.id?.toLowerCase() === v.accountId.toLowerCase()
          ? Color.Black
          : null
    if (!playerColor) throw new Error("Connect the Lichess account playing this game.")
    if (!v.compatible && ["created", "started"].includes(g.state.status))
      throw new Error(
        "Lichess Board API supports rapid, classical, correspondence, and blitz direct challenges or AI games.",
      )
    const { chess, history } = replayLichess(g.state.moves)
    const ended = !["created", "started"].includes(g.state.status)
    const result =
      g.state.winner === "white"
        ? GameResult.WhiteWon
        : g.state.winner === "black"
          ? GameResult.BlackWon
          : ["draw", "stalemate"].includes(g.state.status)
            ? GameResult.Draw
            : null
    let resultReason: GamePosition["resultReason"] = null
    if (result) {
      if (g.state.status === "mate") resultReason = GameResultReason.Checkmate
      else if (g.state.status === "resign") resultReason = GameResultReason.Resignation
      else if (["outoftime", "timeout"].includes(g.state.status))
        resultReason = GameResultReason.Timeout
      else if (g.state.status === "stalemate") resultReason = GameResultReason.Stalemate
      else if (result === GameResult.Draw) {
        if (chess.isInsufficientMaterial()) resultReason = GameResultReason.InsufficientMaterial
        else if (chess.isThreefoldRepetition()) resultReason = GameResultReason.Repetition
        else if (chess.isDrawByFiftyMoves()) resultReason = GameResultReason.FiftyMoveRule
        // The API's generic draw status does not establish agreement.
      }
    }
    const running = !ended && v.connected && g.speed !== "correspondence" && history.length >= 2
    // TV clocks extrapolate from snapshot receipt. Project the last stream event
    // to now so repeated snapshots cannot reset a running clock to its old value.
    const now = Date.now()
    const clock = (color: Color, remaining: number | undefined) => {
      if (g.speed === "correspondence") return { remainingMs: null, running: null }
      const active = running && (chess.turn() === "w" ? Color.White : Color.Black) === color
      return {
        remainingMs:
          remaining === undefined
            ? null
            : Math.max(0, remaining - (active ? Math.max(0, now - v.observedAt) : 0)),
        running: remaining === undefined ? null : active,
      }
    }
    return {
      identity: `${g.id}/${v.accountId}`,
      history,
      chess,
      fingerprint: JSON.stringify([history, g.state.status, v.connected]),
      playable: v.connected && v.compatible && !ended,
      unavailableReason: ended
        ? g.state.status === "aborted"
          ? "Game aborted. Start a new game on Lichess."
          : "Game finished. Start a new game on Lichess."
        : !v.connected
          ? "Reconnecting to Lichess…"
          : undefined,
      playerColor,
      bottomColor: playerColor,
      result,
      resultReason,
      boardCells: chess
        .board()
        .flat()
        .map((p) =>
          p ? pieceSchema.parse(p.color === "w" ? p.type.toUpperCase() : p.type) : null,
        ),
      players: {
        white: g.white.name ?? (g.white.aiLevel ? `Lichess AI level ${g.white.aiLevel}` : null),
        black: g.black.name ?? (g.black.aiLevel ? `Lichess AI level ${g.black.aiLevel}` : null),
        whiteAvatar: null,
        blackAvatar: null,
      },
      clocks: {
        white: clock(Color.White, g.state.wtime),
        black: clock(Color.Black, g.state.btime),
        observedAt: now,
      },
    }
  }
  async submit(move: MoveRequest) {
    const view = this.view!
    const before = view.game.state.moves
    this.uncertain = true // Once dispatched, a transport failure cannot become a rejected/retryable move.
    try {
      const response = z.object({ outcome: z.enum(MoveOutcome), message: z.string() }).parse(
        await this.rpc({
          kind: "lichess-move",
          gameId: view.game.id,
          before,
          commandId: move.commandId,
          uci: move.from + move.to + (move.promotion ?? ""),
        }),
      )
      this.uncertain = response.outcome === MoveOutcome.Uncertain
      try {
        await this.prepare()
      } catch {
        /* Outcome survives a disconnected stream. */
      }
      return response
    } catch {
      return {
        outcome: MoveOutcome.Uncertain,
        message: "Lichess move interrupted. Inspect the game and reconnect.",
      }
    }
  }
}

export class LichessAdapter extends GameAdapter {
  constructor(doc: Document, rpc: LichessRPC, allowBackground = false) {
    super(new LichessDriver(doc, rpc, allowBackground))
  }
}
