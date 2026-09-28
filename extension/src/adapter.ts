import type { Message } from "@chess-tv/protocol"

import {
  observationSchema,
  type Move,
  type Observation,
  type Outcome,
  type Snapshot,
} from "./messages"

export function readPage(doc: Document, now = Date.now()): Observation {
  const raw = doc.querySelector("#chess-tv-state")?.textContent
  if (!raw || raw.length > 65536)
    throw new Error("Unsupported simulator layout. Reconnect the game.")
  const observed = observationSchema.parse(JSON.parse(raw))
  if (now - observed.updatedAt > 3000 || observed.updatedAt > now + 1000)
    throw new Error("Game observation is stale.")
  if (!observed.snapshot.playerColor || !observed.snapshot.turn)
    throw new Error("Player or turn is unknown.")
  if (doc.querySelectorAll("[data-square]").length !== 64)
    throw new Error("Board layout is unavailable.")
  return observed
}
export function clickMove(doc: Document, move: Move) {
  const click = (selector: string) => {
    const element = doc.querySelector<HTMLElement>(selector)
    if (!element) throw new Error("Move control is unavailable.")
    element.click()
  }
  click(`[data-square="${move.from}"]`)
  click(`[data-square="${move.to}"]`)
  if (move.promotion) click(`[data-promotion="${move.promotion}"]`)
}
const relevant = (s: Snapshot) => JSON.stringify([s.board, s.playerColor, s.turn, s.result])

export class Adapter {
  generation = "unattached"
  gameId: string | null = null
  revision = 0
  enabled = false
  blocked: string | null = null
  latest?: Observation
  pending?: { move: Move; sequence: number; started: number; board: string }
  outcomes = new Map<string, Outcome>()
  constructor(
    private read: () => Observation,
    private interact: (move: Move) => void,
    private now = () => performance.now(),
  ) {}
  inspect() {
    return this.read().snapshot.gameId
  }
  session(generation: string, enabled: boolean) {
    if (generation !== this.generation) {
      if (this.pending) this.blocked = "Move interrupted. Inspect Chrome and reconnect the game."
      this.generation = generation
      this.outcomes.clear()
    }
    this.enabled = enabled
  }
  stop() {
    this.enabled = false
  }
  reason() {
    if (this.blocked) return this.blocked
    if (!this.enabled) return "Keep the attached game visible in the active Chrome window."
    if (this.pending)
      return this.now() - this.pending.started >= 5000
        ? "Checking move. Inspect Chrome if it remains unresolved."
        : "Waiting for the observed move."
    if (this.latest?.snapshot.result) return "Game finished."
    if (this.latest?.snapshot.turn !== this.latest?.snapshot.playerColor)
      return "Waiting for your turn."
    return null
  }
  observe(): Message[] {
    const next = this.read()
    if (this.gameId && next.snapshot.gameId !== this.gameId)
      throw new Error("Game changed. Connect this game explicitly.")
    this.gameId = next.snapshot.gameId
    if (!this.latest || relevant(next.snapshot) !== relevant(this.latest.snapshot)) this.revision++
    this.latest = next
    const messages: Message[] = []
    const p = this.pending
    if (p) {
      const a = next.acceptance
      if (
        a &&
        a.sequence > p.sequence &&
        a.sequence === next.sequence &&
        a.from === p.move.from &&
        a.to === p.move.to &&
        a.promotion === (p.move.promotion ?? null)
      ) {
        // Acceptance alone is insufficient: successful moves must also change placement.
        if (!a.accepted || JSON.stringify(next.snapshot.board) !== p.board) {
          messages.push(
            this.outcome(
              p.move,
              a.accepted ? "observed-complete" : "rejected",
              a.accepted ? null : "The page rejected the move.",
            ),
          )
          this.pending = undefined
        }
      }
      if (this.pending && this.now() - p.started >= 5000) {
        messages.push(this.outcome(p.move, "uncertain", "Checking move; it will not be resent."))
      }
    }
    messages.push({ ...next.snapshot, generation: this.generation, revision: this.revision })
    const reason = this.reason()
    messages.push({
      v: 1,
      type: "status",
      gameId: this.gameId,
      generation: this.generation,
      available: reason === null,
      reason,
    })
    return messages
  }
  outcome(move: Move, outcome: Outcome["outcome"], reason: string | null): Outcome {
    const result: Outcome = {
      v: 1,
      type: "outcome",
      gameId: move.gameId,
      generation: this.generation,
      commandId: move.commandId,
      outcome,
      reason,
    }
    if (this.outcomes.size < 10000 || this.outcomes.has(move.commandId))
      this.outcomes.set(move.commandId, result)
    else this.blocked = "Session limit reached. Reconnect the game."
    return result
  }
  move(move: Move): Message[] {
    // Read direct browser input before evaluating the request's revision.
    let observations: Message[]
    try {
      observations = this.observe()
    } catch {
      this.enabled = false
      const reason = "Observation unavailable; reconnect the game."
      // A failed read cannot turn a previously dispatched command into a rejection.
      return [
        this.outcomes.get(move.commandId) ?? this.outcome(move, "rejected", reason),
        {
          v: 1,
          type: "status",
          gameId: this.gameId ?? move.gameId,
          generation: this.generation,
          available: false,
          reason,
        },
      ]
    }
    const known = this.outcomes.get(move.commandId)
    if (known) return [...observations, known]
    if (
      move.generation !== this.generation ||
      move.gameId !== this.gameId ||
      move.revision !== this.revision ||
      this.reason()
    )
      return [
        ...observations,
        this.outcome(move, "rejected", this.reason() || "Stale game, generation, or position."),
      ]
    // Bound deduplication memory without evicting commands from a live session.
    if (this.outcomes.size >= 10000) {
      this.blocked = "Session limit reached. Reconnect the game."
      return [...observations, this.outcome(move, "rejected", this.blocked)]
    }
    this.pending = {
      move,
      sequence: this.latest!.sequence,
      started: this.now(),
      board: JSON.stringify(this.latest!.snapshot.board),
    }
    this.outcome(move, "uncertain", "Move submitted; awaiting page observation.")
    try {
      this.interact(move)
    } catch {
      this.blocked = "Interaction was interrupted. Inspect Chrome and reconnect the game."
    }
    return [...observations.filter((m) => m.type !== "status"), ...this.observe()]
  }
}
