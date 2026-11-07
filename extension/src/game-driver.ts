import type { MoveOutcome, MoveRequest, Snapshot } from "@chess-tv/protocol"
import type { Chess } from "chess.js"

export type GamePosition = Pick<
  Snapshot,
  "players" | "clocks" | "playerColor" | "bottomColor" | "result" | "resultReason"
> & {
  identity: unknown
  history: string[]
  fingerprint: string
  playable: boolean
  unavailableReason?: string
  chess: Chess
  boardCells: Snapshot["board"]
}

// Site knowledge stays behind this seam; session revisions, voice and deduplication are shared.
export interface GameDriver {
  readonly name: string
  readonly visible: boolean
  readonly unresolved: boolean
  prepare?(): Promise<void>
  read(): GamePosition
  reset(): void
  submit(move: MoveRequest): Promise<{ outcome: MoveOutcome; message: string }>
}
