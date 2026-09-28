import { messageSchema } from "@chess-tv/protocol"

import type { Move, Snapshot } from "../src/messages"

export type TVState = {
  connected: boolean
  generation?: string
  snapshot?: Snapshot
  observedAt: number
  available: boolean
  reason: string
  pending?: string
}

// This is a local, cancellable submission countdown, never a retry or delivery queue.
export class MoveCountdown {
  private timer?: ReturnType<typeof setTimeout>
  constructor(
    private current: () => TVState,
    private submit: (move: Move) => void,
    private report: (message: string) => void,
    private now = () => performance.now(),
  ) {}
  get scheduled() {
    return this.timer !== undefined
  }
  cancel(reason = "Scheduled move cancelled.") {
    if (!this.timer) return
    clearTimeout(this.timer)
    this.timer = undefined
    this.report(reason)
  }
  schedule(from?: string, to?: string, promotion?: string) {
    if (this.scheduled) throw new Error("A move is already scheduled. Type cancel to cancel it.")
    const state = this.current()
    if (!state.connected) throw new Error("TV is disconnected. Restart the TV client to reconnect.")
    if (state.pending)
      throw new Error(
        "A submitted move is still unresolved. Inspect Chrome and reconnect the game; it will not be resent.",
      )
    if (!state.snapshot || !state.generation)
      throw new Error("No fresh game snapshot. Open the extension and choose Connect this game.")
    if (this.now() - state.observedAt > 3000)
      throw new Error(`Game observation is stale. ${state.reason}`)
    if (state.snapshot.result)
      throw new Error("This game has finished. Start and attach a new game.")
    if (!state.snapshot.playerColor || state.snapshot.turn !== state.snapshot.playerColor)
      throw new Error("It is not your turn. Wait for the page to show your turn.")
    const parsed = messageSchema.safeParse({
      v: 1,
      type: "move",
      gameId: state.snapshot.gameId,
      generation: state.generation,
      revision: state.snapshot.revision,
      commandId: crypto.randomUUID(),
      from,
      to,
      ...(promotion ? { promotion } : {}),
    })
    if (!parsed.success || parsed.data.type !== "move")
      throw new Error("Use: move e2 e4 (or move a7 a8 q for promotion).")
    const move = parsed.data
    this.report(
      "Move scheduled in 5 seconds. Switch to Chrome now and keep the attached game visible. Type cancel to cancel.",
    )
    this.timer = setTimeout(() => {
      this.timer = undefined
      const latest = this.current()
      if (
        !latest.connected ||
        latest.generation !== move.generation ||
        latest.snapshot?.gameId !== move.gameId ||
        latest.snapshot.revision !== move.revision ||
        latest.pending
      ) {
        this.report(
          "Move cancelled: the connection, game, or position changed. Nothing was submitted.",
        )
        return
      }
      if (!latest.available || this.now() - latest.observedAt > 3000) {
        this.report(
          `Move cancelled; nothing was submitted. ${latest.reason || "Wait for fresh state."}`,
        )
        return
      }
      this.submit(move)
    }, 5000)
  }
}
