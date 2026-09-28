import { messageSchema, type Message } from "@chess-tv/protocol"
import { z } from "zod"
export type Snapshot = Extract<Message, { type: "snapshot" }>
export type Move = Extract<Message, { type: "move" }>
export type Outcome = Extract<Message, { type: "outcome" }>
export const snapshotSchema = z.custom<Snapshot>((v) => {
  const p = messageSchema.safeParse(v)
  return p.success && p.data.type === "snapshot"
})
export const moveSchema = z.custom<Move>((v) => {
  const p = messageSchema.safeParse(v)
  return p.success && p.data.type === "move"
})
export const popupAction = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("state") }),
  z.strictObject({ kind: z.literal("pair"), code: z.string().regex(/^\d{6}$/) }),
  z.strictObject({ kind: z.literal("attach") }),
  z.strictObject({ kind: z.literal("reconnect") }),
  z.strictObject({ kind: z.literal("disconnect") }),
  z.strictObject({ kind: z.literal("unpair") }),
])
export const contentAction = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("inspect") }),
  z.strictObject({ kind: z.literal("stop") }),
  z.strictObject({ kind: z.literal("sync"), generation: z.string().min(1), enabled: z.boolean() }),
  z.strictObject({ kind: z.literal("move"), move: moveSchema }),
])
export const contentReply = z.strictObject({
  instance: z.string().min(1),
  gameId: z.string().nullable(),
  messages: z.array(messageSchema),
  error: z.string().nullable(),
})
export type ContentReply = z.infer<typeof contentReply>
export type PopupState = {
  autoConnect: boolean
  paired: boolean
  pairing: boolean
  connected: boolean
  peerConnected: boolean
  gameId: string | null
  available: boolean
  status: string
  error: string | null
  simulator: boolean
  relay: string
}
// Simulator-only observation contract. The page publishes evidence, not commands from the extension.
export const observationSchema = z.strictObject({
  snapshot: snapshotSchema,
  updatedAt: z.number(),
  sequence: z.number().int().nonnegative(),
  acceptance: z
    .strictObject({
      sequence: z.number().int().nonnegative(),
      from: z.string().regex(/^[a-h][1-8]$/),
      to: z.string().regex(/^[a-h][1-8]$/),
      promotion: z.enum(["q", "r", "b", "n"]).nullable(),
      accepted: z.boolean(),
    })
    .nullable(),
})
export type Observation = z.infer<typeof observationSchema>
