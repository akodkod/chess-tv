import {
  type MoveRequest,
  Color,
  MessageKind,
  MoveOutcome,
  VERSION,
  type Message,
} from "@chess-tv/protocol"

import { readGame } from "./chesscom-game"
import { createMoveController, type MoveControllerOptions } from "./chesscom-move"
import { completedBotPath, liveBotPath } from "./chesscom-url"
import { ContentErrorCode, contentAction, type ContentReply } from "./messages"

class GameChangedError extends Error {}

export class ChessComAdapter {
  readonly instance = crypto.randomUUID()
  private gameId = crypto.randomUUID()
  private generation = ""
  private color: Color | null = null
  private enabled = false
  private revision = 0
  private fingerprint = ""
  private history: string[] = []
  private boardElement?: HTMLElement
  private path = ""
  private finalResult: ReturnType<typeof readGame>["result"] = null
  private finalReason: ReturnType<typeof readGame>["resultReason"] = null
  private controller: ReturnType<typeof createMoveController>
  private outcomes = new Map<string, { request: string; result: Promise<ContentReply> }>()
  constructor(
    private doc: Document = document,
    private options: MoveControllerOptions = {},
  ) {
    this.controller = createMoveController(options)
  }

  private read() {
    const p = readGame(this.doc)
    const color = p.playerColor
    if (!color && !p.online)
      throw new Error(
        "Cannot detect your playing color. Sign in to Chess.com, open your current game, and reconnect.",
      )
    this.color = color
    const path = this.doc.location?.pathname ?? ""
    const completedSameGame = liveBotPath(this.path) && completedBotPath(path)
    if (
      this.boardElement &&
      (this.boardElement !== p.board ||
        (this.path !== path && !completedSameGame) ||
        this.history.some((san, i) => p.history[i] !== san))
    ) {
      this.gameId = crypto.randomUUID()
      this.enabled = false
      this.fingerprint = ""
      this.history = []
      this.finalResult = null
      this.finalReason = null
      this.boardElement = undefined
      throw new GameChangedError("Game changed. Connect the current game again.")
    }
    this.boardElement = p.board
    this.path = path
    this.history = p.history
    // Closing the game-over modal must not erase a previously observed reason.
    if (p.result && p.result === this.finalResult && !p.resultReason)
      p.resultReason = this.finalReason
    this.finalResult = p.result
    this.finalReason = p.resultReason
    const fingerprint = JSON.stringify([
      p.fingerprint,
      this.color,
      p.bottomColor,
      p.result,
      p.resultReason,
      p.playable,
    ])
    if (fingerprint !== this.fingerprint) {
      this.revision++
      this.fingerprint = fingerprint
    }
    return p
  }
  private reply(messages: Message[] = [], error: ContentReply["error"] = null): ContentReply {
    return { instance: this.instance, gameId: this.gameId, messages, error }
  }
  private sync(): ContentReply {
    const p = this.read()
    const context = {
      v: VERSION as typeof VERSION,
      gameId: this.gameId,
      generation: this.generation,
    }
    const available =
      this.enabled &&
      this.color !== null &&
      (this.options.allowBackground || !this.doc.hidden) &&
      !this.controller.unresolved &&
      !p.result &&
      p.playable &&
      !completedBotPath(this.path)
    return this.reply([
      {
        ...context,
        type: MessageKind.Snapshot,
        revision: this.revision,
        board: p.boardCells,
        players: p.players,
        playerColor: this.color,
        bottomColor: p.bottomColor,
        turn: p.chess.turn() === "w" ? Color.White : Color.Black,
        clocks: p.clocks,
        result: p.result,
        resultReason: p.resultReason,
        legalMoves: p.result
          ? []
          : [
              ...new Map(
                p.chess
                  .moves({ verbose: true })
                  .map(({ from, to }) => [`${from}${to}`, { from, to }]),
              ).values(),
            ],
        checkSquare: p.chess.isCheck()
          ? p.chess
              .board()
              .flat()
              .find((piece) => piece?.type === "k" && piece.color === p.chess.turn())!.square
          : null,
      },
      {
        ...context,
        type: MessageKind.Status,
        available,
        reason: available
          ? null
          : this.controller.unresolved
            ? "Move unresolved. Inspect the game and reconnect the game."
            : this.color === null
              ? "Viewing game."
              : p.result
                ? "Game finished. Start a new game on Chess.com."
                : this.options.allowBackground
                  ? "Keep the game connected."
                  : "Keep the game visible and connected.",
      },
    ])
  }
  private async move(move: MoveRequest): Promise<ContentReply> {
    const outcome = (
      value: MoveOutcome.Rejected | MoveOutcome.Uncertain | MoveOutcome.ObservedComplete,
      reason: string,
    ): ContentReply => {
      const message: Message = {
        v: VERSION as typeof VERSION,
        type: MessageKind.Outcome,
        gameId: move.gameId,
        generation: move.generation,
        commandId: move.commandId,
        outcome: value,
        reason: reason.slice(0, 256),
      }
      try {
        const reply = this.sync()
        reply.messages.unshift(message)
        return reply
      } catch {
        return this.reply([message])
      }
    }
    try {
      const p = this.read()
      if (
        move.gameId !== this.gameId ||
        move.generation !== this.generation ||
        move.revision !== this.revision
      )
        throw new Error("Position changed. Choose your move again.")
      if (
        !this.enabled ||
        !this.color ||
        (!this.options.allowBackground && this.doc.hidden) ||
        p.result ||
        !p.playable ||
        completedBotPath(this.path) ||
        this.controller.unresolved
      )
        throw new Error("Game is not available for a move.")
      if ((p.chess.turn() === "w" ? Color.White : Color.Black) !== this.color)
        throw new Error("Wait for your opponent's move.")
      // Validation only: the engine never chooses a move or updates TV state speculatively.
      const legal = p.chess
        .moves({ verbose: true })
        .some((m) => m.from === move.from && m.to === move.to && m.promotion === move.promotion)
      if (!legal) throw new Error("This move is not legal")
      const reply = await this.controller.move({
        kind: "bot-move",
        id: move.commandId,
        token: this.controller.token(p),
        from: move.from,
        to: move.to,
        color: this.color,
        ...(move.promotion ? { promotion: move.promotion } : {}),
      })
      return outcome(reply.outcome ?? MoveOutcome.Uncertain, reply.message)
    } catch (e) {
      return outcome(MoveOutcome.Rejected, e instanceof Error ? e.message : "Move unavailable.")
    }
  }
  async handle(raw: unknown): Promise<ContentReply> {
    try {
      const action = contentAction.parse(raw)
      if (action.kind === "inspect") {
        this.read()
        return this.reply()
      }
      if (action.kind === "stop") {
        this.enabled = false
        // Explicit reconnect acknowledges inspection; never reuse old command IDs.
        this.controller = createMoveController(this.options)
        this.outcomes.clear()
        this.generation = ""
        return this.reply()
      }
      if (action.kind === "sync") {
        this.generation = action.generation
        this.enabled = action.enabled
        return this.sync()
      }
      const key = `${action.move.generation}/${action.move.commandId}`
      const request = JSON.stringify(action.move)
      const known = this.outcomes.get(key)
      if (known) {
        if (known.request !== request)
          throw new Error("Command ID reused with different move data.")
        const cached = await known.result
        const outcomes = cached.messages.filter((m) => m.type === MessageKind.Outcome)
        try {
          const fresh = this.sync()
          fresh.messages.unshift(...outcomes)
          return fresh
        } catch {
          return this.reply(outcomes)
        }
      }
      const result = this.move(action.move)
      this.outcomes.set(key, { request, result })
      return await result
    } catch (e) {
      return this.reply([], {
        code:
          e instanceof GameChangedError
            ? ContentErrorCode.GameChanged
            : ContentErrorCode.Unavailable,
        message: e instanceof Error ? e.message.slice(0, 256) : "Game unavailable.",
      })
    }
  }
}
