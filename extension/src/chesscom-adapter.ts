import type { MoveRequest } from "@chess-tv/protocol"

import { readGame } from "./chesscom-game"
import { createMoveController, type MoveControllerOptions } from "./chesscom-move"
import { completedBotPath, liveBotPath } from "./chesscom-url"
import { GameAdapter } from "./game-adapter"
import type { GameDriver } from "./game-driver"

class ChessComDriver implements GameDriver {
  readonly name = "Chess.com"
  private controller
  private board?: HTMLElement
  private path = ""
  private identity = crypto.randomUUID()
  constructor(
    private doc: Document,
    private options: MoveControllerOptions,
  ) {
    this.controller = createMoveController(options)
  }
  get visible() {
    return !!this.options.allowBackground || !this.doc.hidden
  }
  get unresolved() {
    return this.controller.unresolved
  }
  reset() {
    this.controller = createMoveController(this.options)
  }
  read() {
    const p = readGame(this.doc)
    if (!p.playerColor && !p.online)
      throw new Error(
        "Cannot detect your playing color. Sign in to Chess.com, open your current game, and reconnect.",
      )
    const path = this.doc.location?.pathname ?? ""
    if (
      this.board &&
      (this.board !== p.board ||
        (this.path !== path && !(liveBotPath(this.path) && completedBotPath(path))))
    )
      this.identity = crypto.randomUUID()
    this.board = p.board
    this.path = path
    return { ...p, identity: this.identity, playable: p.playable && !completedBotPath(path) }
  }
  submit(move: MoveRequest) {
    const p = this.read()
    if (!p.playerColor) throw new Error("Viewing game.")
    return this.controller.move({
      kind: "bot-move",
      id: move.commandId,
      token: this.controller.token(p),
      from: move.from,
      to: move.to,
      color: p.playerColor,
      ...(move.promotion ? { promotion: move.promotion } : {}),
    })
  }
}

export class ChessComAdapter extends GameAdapter {
  constructor(doc: Document = document, options: MoveControllerOptions = {}) {
    super(new ChessComDriver(doc, options))
  }
}
