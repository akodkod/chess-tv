import { z } from "zod"
export const VERSION = 2
export const MAX_BYTES = 64 * 1024
export const id = z.string().min(1).max(128)
export const credential = z.string().regex(/^[a-f0-9]{64}$/)
export const role = z.enum(["tv", "extension"])
export type Role = z.infer<typeof role>
const square = z.string().regex(/^[a-h][1-8]$/)
const color = z.enum(["white", "black"])
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
    const url = new URL(value)
    return url.protocol === "https:" && !url.username && !url.password
  })
  .nullable()
  .optional()
const clock = z.strictObject({
  remainingMs: z.number().nonnegative().nullable(),
  running: z.boolean().nullable(),
})
export const messageSchema = z.discriminatedUnion("type", [
  message("authenticate", { credential }),
  message("authenticated", { role, pairingId: id }),
  message("ping", { nonce: id }),
  message("pong", { nonce: id }),
  message("attachment", { generation: id, gameId: id.nullable() }),
  message("session", { generation: id, gameId: id.nullable(), peerConnected: z.boolean() }),
  message("status", { ...context, available: z.boolean(), reason: z.string().max(256).nullable() }),
  message("snapshot", {
    ...context,
    revision,
    board: z
      .array(z.enum(["P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]).nullable())
      .length(64),
    players: z.strictObject({
      white: z.string().max(128).nullable(),
      black: z.string().max(128).nullable(),
      whiteAvatar: avatar,
      blackAvatar: avatar,
    }),
    playerColor: color.nullable(),
    turn: color.nullable(),
    clocks: z.strictObject({
      white: clock,
      black: clock,
      observedAt: z.number().nonnegative().nullable(),
    }),
    legalMoves: z.array(z.strictObject({ from: square, to: square })).max(256),
    checkSquare: square.nullable(),
    result: z.enum(["white-won", "black-won", "draw"]).nullable(),
  }),
  message("move", {
    ...context,
    revision,
    commandId: id,
    from: square,
    to: square,
    promotion: z.enum(["q", "r", "b", "n"]).optional(),
  }),
  message("outcome", {
    ...context,
    commandId: id,
    outcome: z.enum(["rejected", "uncertain", "observed-complete"]),
    reason: z.string().max(256).nullable(),
  }),
  message("snapshot-request", context),
  message("error", { code: id, message: z.string().max(256) }),
])
export type Message = z.infer<typeof messageSchema>
export function parseMessage(value: unknown): Message {
  return messageSchema.parse(value)
}
