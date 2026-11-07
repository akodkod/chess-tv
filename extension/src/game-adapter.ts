import {
  type MoveRequest,
  Color,
  MessageKind,
  MoveOutcome,
  VERSION,
  type Message,
} from "@chess-tv/protocol"

import type { GameDriver, GamePosition } from "./game-driver"
import { ContentErrorCode, contentAction, type ContentReply } from "./messages"
import {
  resolveVoiceAlternatives,
  prepareVoiceMove,
  voiceCandidates,
  type VoiceCandidate,
  type VoiceResolution,
} from "./voice-command"

class GameChangedError extends Error {}

export class GameAdapter {
  readonly instance = crypto.randomUUID()
  private gameId = crypto.randomUUID()
  private generation = ""
  private color: Color | null = null
  private enabled = false
  private revision = 0
  private fingerprint = ""
  private history: string[] = []
  private identity?: unknown
  private finalResult: GamePosition["result"] = null
  private finalReason: GamePosition["resultReason"] = null
  private outcomes = new Map<string, { request: string; result: Promise<ContentReply> }>()
  constructor(private driver: GameDriver) {}

  private read() {
    const p = this.driver.read()
    this.color = p.playerColor
    if (
      this.identity !== undefined &&
      (this.identity !== p.identity || this.history.some((san, i) => p.history[i] !== san))
    ) {
      this.gameId = crypto.randomUUID()
      this.enabled = false
      this.fingerprint = ""
      this.history = []
      this.finalResult = null
      this.finalReason = null
      this.identity = undefined
      throw new GameChangedError("Game changed. Connect the current game again.")
    }
    this.identity = p.identity
    this.history = p.history
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
      this.driver.visible &&
      !this.driver.unresolved &&
      !p.result &&
      p.playable
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
          : this.driver.unresolved
            ? "Move unresolved. Inspect the game and reconnect the game."
            : this.color === null
              ? "Viewing game."
              : p.unavailableReason
                ? p.unavailableReason
                : p.result
                  ? `Game finished. Start a new game on ${this.driver.name}.`
                  : this.driver.visible
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
      await this.driver.prepare?.()
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
        !this.driver.visible ||
        p.result ||
        !p.playable ||
        this.driver.unresolved
      )
        throw new Error("Game is not available for a move.")
      if ((p.chess.turn() === "w" ? Color.White : Color.Black) !== this.color)
        throw new Error("Wait for your opponent's move.")
      // Validation only: the engine never chooses a move or updates TV state speculatively.
      const legal = p.chess
        .moves({ verbose: true })
        .some((m) => m.from === move.from && m.to === move.to && m.promotion === move.promotion)
      if (!legal) throw new Error("This move is not legal")
      const reply = await this.driver.submit(move)

      return outcome(reply.outcome ?? MoveOutcome.Uncertain, reply.message)
    } catch (e) {
      return outcome(MoveOutcome.Rejected, e instanceof Error ? e.message : "Move unavailable.")
    }
  }
  async prepare() {
    await this.driver.prepare?.()
  }

  // Mac-only entry points. They are not accepted by the extension's content-action schema.
  voicePosition(): ContentReply & { voicePosition?: string; voiceCandidates?: VoiceCandidate[] } {
    try {
      const p = this.read()
      if (
        !this.color ||
        p.result ||
        !p.playable ||
        this.driver.unresolved ||
        (p.chess.turn() === "w" ? Color.White : Color.Black) !== this.color
      )
        throw new Error("Wait for your turn in an active game.")
      return {
        ...this.reply(),
        voiceCandidates: voiceCandidates(p.chess),
        voicePosition: JSON.stringify([
          this.instance,
          this.gameId,
          p.chess.fen(),
          p.history,
          this.color,
        ]),
      }
    } catch (e) {
      return this.reply([], {
        code: ContentErrorCode.Unavailable,
        message: e instanceof Error ? e.message : "Game unavailable.",
      })
    }
  }
  voiceResolve(
    text: string,
    alternatives: string[],
    position: string,
  ): ContentReply & { voiceResolution: VoiceResolution } {
    const current = this.voicePosition()
    if (current.voicePosition !== position)
      return {
        ...current,
        voiceResolution: { state: "rejected", reason: "Position changed. Repeat your command." },
      }
    return {
      ...current,
      voiceResolution: prepareVoiceMove(this.read().chess, [text, ...alternatives]),
    }
  }
  async voiceMove(
    text: string,
    position: string,
    commandId: string,
    alternatives: string[] = [],
    selectedMove?: string,
  ): Promise<ContentReply> {
    const current = this.voicePosition()
    const reject = (reason: string) =>
      this.reply([
        {
          v: VERSION,
          type: MessageKind.Outcome,
          gameId: this.gameId,
          generation: this.generation || "mac-local",
          commandId,
          outcome: MoveOutcome.Rejected,
          reason: reason.slice(0, 256),
        },
      ])
    if (!current.voicePosition || current.voicePosition !== position)
      return reject(current.error?.message ?? "Position changed. Repeat your command.")
    try {
      const resolved = selectedMove
        ? this.read()
            .chess.moves({ verbose: true })
            .find((move) => move.lan === selectedMove)
        : resolveVoiceAlternatives(this.read().chess, [text, ...alternatives])
      if (!resolved) return reject("Say move or castle to begin a command.")
      const enabled = this.enabled
      this.enabled = true
      if (!this.generation) this.generation = "mac-local"
      try {
        return await this.handle({
          kind: "move",
          move: {
            v: VERSION,
            type: MessageKind.Move,
            gameId: this.gameId,
            generation: this.generation,
            revision: this.revision,
            commandId,
            from: resolved.from,
            to: resolved.to,
            ...(resolved.promotion ? { promotion: resolved.promotion } : {}),
          },
        })
      } finally {
        this.enabled = enabled
      }
    } catch (e) {
      return reject(e instanceof Error ? e.message : "Move unavailable.")
    }
  }
  async handle(raw: unknown): Promise<ContentReply> {
    try {
      const action = contentAction.parse(raw)
      if (action.kind === "inspect" || action.kind === "sync") await this.driver.prepare?.()
      if (action.kind === "inspect") {
        this.read()
        return this.reply()
      }
      if (action.kind === "stop") {
        this.enabled = false
        // Explicit reconnect acknowledges inspection; never reuse old command IDs.
        this.driver.reset()
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
