import { z } from "zod"

export enum MessageKind {
  Authenticate = "authenticate",
  Authenticated = "authenticated",
  Ping = "ping",
  Pong = "pong",
  Attachment = "attachment",
  Session = "session",
  Status = "status",
  Snapshot = "snapshot",
  Move = "move",
  Outcome = "outcome",
  SnapshotRequest = "snapshot-request",
  Error = "error",
}
export enum DeviceRole {
  TV = "tv",
  Extension = "extension",
}
export enum Color {
  White = "white",
  Black = "black",
}
export enum Piece {
  WhitePawn = "P",
  WhiteKnight = "N",
  WhiteBishop = "B",
  WhiteRook = "R",
  WhiteQueen = "Q",
  WhiteKing = "K",
  BlackPawn = "p",
  BlackKnight = "n",
  BlackBishop = "b",
  BlackRook = "r",
  BlackQueen = "q",
  BlackKing = "k",
}
export enum Promotion {
  Queen = "q",
  Rook = "r",
  Bishop = "b",
  Knight = "n",
}
export enum MoveOutcome {
  Rejected = "rejected",
  Uncertain = "uncertain",
  ObservedComplete = "observed-complete",
}
export enum GameResult {
  WhiteWon = "white-won",
  BlackWon = "black-won",
  Draw = "draw",
}
export enum GameResultReason {
  Checkmate = "checkmate",
  Stalemate = "stalemate",
  Timeout = "timeout",
  Resignation = "resignation",
  InsufficientMaterial = "insufficient-material",
  Repetition = "repetition",
  FiftyMoveRule = "fifty-move-rule",
  Agreement = "agreement",
}
export const VERSION = 3
export const MAX_BYTES = 64 * 1024
export const id = z.string().min(1).max(128)
export const credential = z.string().regex(/^[a-f0-9]{64}$/)
export const role = z.enum(DeviceRole)
export type Role = z.infer<typeof role>
export const pieceSchema = z.enum(Piece)
const square = z.string().regex(/^[a-h][1-8]$/)
export const colorSchema = z.enum(Color)
const color = colorSchema
const revision = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER)
const context = { gameId: id, generation: id }
const base = { v: z.literal(VERSION) }
const message = <T extends string, S extends z.ZodRawShape>(type: T, shape: S) =>
  z.strictObject({ ...base, type: z.literal(type), ...shape })
const avatar = z
  .string()
  .max(2048)
  .url()
  .refine((value) => {
    try {
      const url = new URL(value)
      return url.protocol === "https:" && !url.username && !url.password
    } catch {
      return false
    }
  })
  .nullable()
const clock = z.strictObject({
  remainingMs: z.number().nonnegative().nullable(),
  running: z.boolean().nullable(),
})
export const authenticateSchema = message(MessageKind.Authenticate, { credential })
export type AuthenticateMessage = z.infer<typeof authenticateSchema>

export const authenticatedSchema = message(MessageKind.Authenticated, { role, pairingId: id })
export type AuthenticatedMessage = z.infer<typeof authenticatedSchema>

export const pingSchema = message(MessageKind.Ping, { nonce: id })
export type PingMessage = z.infer<typeof pingSchema>

export const pongSchema = message(MessageKind.Pong, { nonce: id })
export type PongMessage = z.infer<typeof pongSchema>

export const attachmentSchema = message(MessageKind.Attachment, {
  generation: id,
  gameId: id.nullable(),
})
export type AttachmentMessage = z.infer<typeof attachmentSchema>

export const sessionSchema = message(MessageKind.Session, {
  generation: id,
  gameId: id.nullable(),
  peerConnected: z.boolean(),
})
export type SessionMessage = z.infer<typeof sessionSchema>

export const statusSchema = message(MessageKind.Status, {
  ...context,
  available: z.boolean(),
  reason: z.string().max(256).nullable(),
})
export type StatusMessage = z.infer<typeof statusSchema>

export const snapshotSchema = message(MessageKind.Snapshot, {
  ...context,
  revision,
  board: z.array(pieceSchema.nullable()).length(64),
  players: z.strictObject({
    white: z.string().max(128).nullable(),
    black: z.string().max(128).nullable(),
    whiteAvatar: avatar,
    blackAvatar: avatar,
  }),
  playerColor: color.nullable(),
  bottomColor: color,
  turn: color.nullable(),
  clocks: z.strictObject({
    white: clock,
    black: clock,
    observedAt: z.number().nonnegative().nullable(),
  }),
  legalMoves: z.array(z.strictObject({ from: square, to: square })).max(256),
  checkSquare: square.nullable(),
  result: z.enum(GameResult).nullable(),
  resultReason: z.enum(GameResultReason).nullable(),
})
export type Snapshot = z.infer<typeof snapshotSchema>

export const moveSchema = message(MessageKind.Move, {
  ...context,
  revision,
  commandId: id,
  from: square,
  to: square,
  promotion: z.enum(Promotion).optional(),
})
export type MoveRequest = z.infer<typeof moveSchema>

export const outcomeSchema = message(MessageKind.Outcome, {
  ...context,
  commandId: id,
  outcome: z.enum(MoveOutcome),
  reason: z.string().max(256).nullable(),
})
export type OutcomeMessage = z.infer<typeof outcomeSchema>

export const snapshotRequestSchema = message(MessageKind.SnapshotRequest, context)
export type SnapshotRequestMessage = z.infer<typeof snapshotRequestSchema>

export const errorSchema = message(MessageKind.Error, { code: id, message: z.string().max(256) })
export type ErrorMessage = z.infer<typeof errorSchema>

export const messageSchema = z.discriminatedUnion("type", [
  authenticateSchema,
  authenticatedSchema,
  pingSchema,
  pongSchema,
  attachmentSchema,
  sessionSchema,
  statusSchema,
  snapshotSchema,
  moveSchema,
  outcomeSchema,
  snapshotRequestSchema,
  errorSchema,
])
export type Message = z.infer<typeof messageSchema>
export function parseMessage(value: unknown): Message {
  return messageSchema.parse(value)
}
