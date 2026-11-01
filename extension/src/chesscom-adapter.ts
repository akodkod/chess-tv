import type { Message } from "@chess-tv/protocol"

import { readGame } from "./chesscom-game"
import { createMoveController } from "./chesscom-move"
import { contentAction, type ContentReply, type Move } from "./messages"

type Color = "white" | "black"
export class ChessComAdapter {
  readonly instance = crypto.randomUUID()
  private gameId = crypto.randomUUID()
  private generation = ""
  private color: Color = "white"
  private enabled = false
  private revision = 0
  private fingerprint = ""
  private history: string[] = []
  private boardElement?: HTMLElement
  private path = ""
  private controller = createMoveController()
  private outcomes = new Map<string, { request: string; result: Promise<ContentReply> }>()
  constructor(private doc: Document = document) {}

  private read() {
    const p = readGame(this.doc)
    const path = this.doc.location?.pathname ?? ""
    if (
      this.boardElement &&
      (this.boardElement !== p.board ||
        this.path !== path ||
        this.history.some((san, i) => p.history[i] !== san))
    ) {
      this.gameId = crypto.randomUUID()
      this.enabled = false
      this.fingerprint = ""
      this.history = []
      this.boardElement = undefined
      throw new Error("Game changed. Connect the current game again.")
    }
    this.boardElement = p.board
    this.path = path
    this.history = p.history
    const fingerprint = JSON.stringify([p.fingerprint, this.color, p.result])
    if (fingerprint !== this.fingerprint) {
      this.revision++
      this.fingerprint = fingerprint
    }
    return p
  }
  private reply(messages: Message[] = [], error: string | null = null): ContentReply {
    return { instance: this.instance, gameId: this.gameId, messages, error }
  }
  private sync(): ContentReply {
    const p = this.read()
    const context = { v: 1 as const, gameId: this.gameId, generation: this.generation }
    const available = this.enabled && !this.doc.hidden && !this.controller.unresolved && !p.result
    return this.reply([
      {
        ...context,
        type: "snapshot",
        revision: this.revision,
        board: p.boardCells,
        players: p.players,
        playerColor: this.color,
        turn: p.chess.turn() === "w" ? "white" : "black",
        clocks: p.clocks,
        result: p.result,
      },
      {
        ...context,
        type: "status",
        available,
        reason: available
          ? null
          : this.controller.unresolved
            ? "Move unresolved. Inspect Chrome and reconnect the game."
            : p.result
              ? "Game finished. Start a new bot game in Chrome."
              : "Keep the bot game visible and connected.",
      },
    ])
  }
  private async move(move: Move): Promise<ContentReply> {
    const outcome = (
      value: "rejected" | "uncertain" | "observed-complete",
      reason: string,
    ): ContentReply => {
      const message: Message = {
        v: 1,
        type: "outcome",
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
      if (!this.enabled || this.doc.hidden || p.result || this.controller.unresolved)
        throw new Error("Game is not available for a move.")
      if ((p.chess.turn() === "w" ? "white" : "black") !== this.color)
        throw new Error("Wait for the bot's move.")
      // Validation only: the engine never chooses a move or updates TV state speculatively.
      const legal = p.chess
        .moves({ verbose: true })
        .some((m) => m.from === move.from && m.to === move.to && m.promotion === move.promotion)
      if (!legal) throw new Error("That move is not legal. Choose another destination.")
      const reply = await this.controller.move({
        kind: "bot-move",
        id: move.commandId,
        token: this.controller.token(p),
        from: move.from,
        to: move.to,
        color: this.color,
        ...(move.promotion ? { promotion: move.promotion } : {}),
      })
      return outcome(reply.outcome ?? "uncertain", reply.message)
    } catch (e) {
      return outcome("rejected", e instanceof Error ? e.message : "Move unavailable.")
    }
  }
  async handle(raw: unknown): Promise<ContentReply> {
    try {
      const action = contentAction.parse(raw)
      if (action.kind === "inspect") {
        if (action.color) this.color = action.color
        this.read()
        return this.reply()
      }
      if (action.kind === "stop") {
        this.enabled = false
        // Explicit reconnect acknowledges inspection; never reuse old command IDs.
        this.controller = createMoveController()
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
        const outcomes = cached.messages.filter((m) => m.type === "outcome")
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
      return this.reply([], e instanceof Error ? e.message.slice(0, 256) : "Game unavailable.")
    }
  }
}
