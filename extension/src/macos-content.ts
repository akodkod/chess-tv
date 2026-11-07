import { z } from "zod"

import { createAdapter } from "./create-adapter"
import type { GameAdapter } from "./game-adapter"
import { allowedGameURL } from "./game-sites"
import type { LichessRequest } from "./lichess-driver"

const voiceAction = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("voice-position") }),
  z.strictObject({
    kind: z.literal("voice-resolve"),
    text: z.string().max(512),
    alternatives: z.array(z.string().max(512)).max(8),
    position: z.string().max(32768),
  }),
  z.strictObject({
    kind: z.literal("voice-selected-move"),
    move: z.string().regex(/^[a-h][1-8][a-h][1-8][qrbn]?$/),
    position: z.string().max(32768),
    commandId: z.string().uuid(),
  }),
  z.strictObject({
    kind: z.literal("voice-move"),
    text: z.string().max(512),
    alternatives: z.array(z.string().max(512)).max(8).optional(),
    position: z.string().max(32768),
    commandId: z.string().uuid(),
  }),
])

// Installed only in the app's isolated WKContentWorld, never the page world.
const scope = globalThis as typeof globalThis & {
  webkit?: {
    messageHandlers: { lichess: { postMessage(request: LichessRequest): Promise<unknown> } }
  }
  chessTV?: { handle: (action: unknown) => ReturnType<GameAdapter["handle"]> }
}
if (["https://www.chess.com", "https://lichess.org"].includes(location.origin) && !scope.chessTV) {
  const adapter = createAdapter(
    document,
    async (request) => {
      if (!scope.webkit) throw new Error("Lichess connection unavailable.")
      return scope.webkit.messageHandlers.lichess.postMessage(request)
    },
    true,
  )
  scope.chessTV = {
    async handle(action) {
      if (!allowedGameURL(location.href))
        throw new Error("Open a supported Chess.com or Lichess game.")
      const voice = voiceAction.safeParse(action)
      if (voice.success) {
        await adapter.prepare()
        if (voice.data.kind === "voice-position") return Promise.resolve(adapter.voicePosition())
        if (voice.data.kind === "voice-resolve")
          return Promise.resolve(
            adapter.voiceResolve(voice.data.text, voice.data.alternatives, voice.data.position),
          )
        if (voice.data.kind === "voice-selected-move")
          return adapter.voiceMove(
            "",
            voice.data.position,
            voice.data.commandId,
            [],
            voice.data.move,
          )
        return adapter.voiceMove(
          voice.data.text,
          voice.data.position,
          voice.data.commandId,
          voice.data.alternatives,
        )
      }
      return adapter.handle(action)
    },
  }
}
