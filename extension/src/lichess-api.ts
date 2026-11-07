import { MoveOutcome } from "@chess-tv/protocol"
import { z } from "zod"

import {
  lichessGame,
  lichessState,
  replayLichess,
  type LichessRequest,
  type LichessView,
} from "./lichess-driver"

export const lichessCredential = z.object({
  token: z.string().min(1),
  id: z.string().min(1),
  name: z.string().min(1),
})
export type LichessCredential = z.infer<typeof lichessCredential>
const ongoingGames = z.object({
  nowPlaying: z.array(z.object({ gameId: z.string(), source: z.string(), speed: z.string() })),
})
export function boardCompatible(speed: string, source: string) {
  return (
    ["rapid", "classical", "correspondence"].includes(speed) ||
    (speed === "blitz" && ["friend", "ai", "api"].includes(source))
  )
}
const outcome = (value: MoveOutcome, message: string) => ({ outcome: value, message })

// Trusted host only. Content scripts receive game data and outcomes, never the bearer token.
export class LichessAPI {
  private stream?: {
    id: string
    controller: AbortController
    view?: LichessView
    failure?: string
    retryAt: number
    ready: Promise<void>
  }
  private outcomes = new Map<
    string,
    { request: string; result: Promise<ReturnType<typeof outcome>> }
  >()
  private retryAt = 0
  constructor(
    private credentials: () => LichessCredential | undefined,
    private fetcher: (url: string, init?: RequestInit) => Promise<Response> = (url, init) =>
      fetch(url, init),
  ) {}
  stop() {
    this.stream?.controller.abort()
    this.stream = undefined
    // Do not clear command history on navigation or reconnection.
  }
  private async request(path: string, init: RequestInit = {}) {
    const credential = this.credentials()
    if (!credential)
      throw new Error("Choose Connect Lichess in Chess TV to authorize your account.")
    if (Date.now() < this.retryAt)
      throw new Error("Lichess rate limit. Waiting before reconnecting.")
    const headers = new Headers(init.headers)
    headers.set("Authorization", `Bearer ${credential.token}`)
    const response = await this.fetcher(`https://lichess.org${path}`, {
      ...init,
      redirect: "error",
      credentials: "omit",
      cache: "no-store",
      headers,
    })
    if (response.status === 429) this.retryAt = Date.now() + 60_000
    return response
  }
  private async start(gameId: string) {
    this.stop()
    const controller = new AbortController()
    const stream = { id: gameId, controller, retryAt: 0, ready: Promise.resolve() } as NonNullable<
      typeof this.stream
    >
    this.stream = stream
    let timer = setTimeout(() => controller.abort(), 25_000)
    stream.ready = (async () => {
      try {
        const playing = await this.request("/api/account/playing?nb=50", {
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]),
        })
        if (!playing.ok)
          throw new Error(
            playing.status === 401
              ? "Lichess authorization expired. Connect Lichess again."
              : "Cannot read your Lichess games.",
          )
        const current = ongoingGames
          .parse(await playing.json())
          .nowPlaying.find((g) => g.gameId === gameId)
        const response = await this.request(`/api/board/game/stream/${gameId}`, {
          signal: controller.signal,
        })
        if (!response.ok || !response.body)
          throw new Error(
            response.status === 401
              ? "Lichess authorization expired. Connect Lichess again."
              : "Cannot stream this game. Connect the Lichess account playing it.",
          )
        // Resolve startup at the first full event, while the same response continues streaming.
        let resolveFirst!: () => void
        let rejectFirst!: (reason: unknown) => void
        const first = new Promise<void>((resolve, reject) => {
          resolveFirst = resolve
          rejectFirst = reject
        })
        const reader = response.body.getReader()
        const arm = () => {
          clearTimeout(timer)
          timer = setTimeout(() => controller.abort(), 25_000)
        }
        arm()
        void (async () => {
          const decoder = new TextDecoder()
          let buffer = ""
          try {
            for (;;) {
              const { value, done } = await reader.read()
              if (done) break
              arm()
              buffer += decoder.decode(value, { stream: true })
              if (buffer.length > 262144) throw new Error("Invalid Lichess stream.")
              let end: number
              while ((end = buffer.indexOf("\n")) >= 0) {
                const line = buffer.slice(0, end).trim()
                buffer = buffer.slice(end + 1)
                if (!line) continue
                const event = JSON.parse(line) as { type?: string }
                if (event.type === "gameFull") {
                  const game = lichessGame.parse(event)
                  if (game.id !== gameId) throw new Error("Lichess game mismatch.")
                  stream.view = {
                    game,
                    accountId: this.credentials()!.id,
                    observedAt: Date.now(),
                    connected: true,
                    compatible: current ? boardCompatible(current.speed, current.source) : false,
                  }
                  resolveFirst()
                } else if (event.type === "gameState" && stream.view) {
                  stream.view.game.state = lichessState.parse(event)
                  stream.view.observedAt = Date.now()
                }
              }
            }
            if (!stream.view) throw new Error("Lichess stream ended before the game arrived.")
          } catch (e) {
            stream.failure = e instanceof Error ? e.message : "Lichess stream disconnected."
            rejectFirst(new Error("Lichess stream disconnected. Reconnecting…"))
          } finally {
            clearTimeout(timer!)
            reader.releaseLock()
            if (stream.view && ["created", "started"].includes(stream.view.game.state.status))
              stream.view.connected = false
            stream.retryAt = Date.now() + 3000
          }
        })()
        await first
      } catch (e) {
        clearTimeout(timer)
        controller.abort()
        stream.retryAt = Date.now() + 3000
        stream.failure = e instanceof Error ? e.message : "Lichess connection failed."
        throw e
      }
    })()
    await stream.ready
  }
  async state(gameId: string): Promise<LichessView> {
    if (
      !this.stream ||
      this.stream.id !== gameId ||
      ((!this.stream.view || !this.stream.view.connected) &&
        this.stream.retryAt > 0 &&
        Date.now() >= this.stream.retryAt)
    )
      await this.start(gameId)
    else await this.stream.ready
    const view = this.stream?.view
    if (!view) throw new Error(this.stream?.failure ?? "Waiting for Lichess.")
    return structuredClone(view)
  }
  async handle(request: LichessRequest) {
    if (request.kind === "lichess-state") return this.state(request.gameId)
    const key = `${this.credentials()?.id}/${request.gameId}/${request.commandId}`
    const encoded = JSON.stringify(request)
    const prior = this.outcomes.get(key)
    if (prior)
      return prior.request === encoded
        ? prior.result
        : outcome(MoveOutcome.Rejected, "Command ID reused with different move data.")
    const result = this.move(request)
    this.outcomes.set(key, { request: encoded, result })
    return result
  }
  private async move(request: Extract<LichessRequest, { kind: "lichess-move" }>) {
    const view = this.stream?.view
    if (
      !view ||
      view.game.id !== request.gameId ||
      !view.connected ||
      !view.compatible ||
      view.game.state.status !== "started" ||
      view.game.state.moves !== request.before
    )
      return outcome(
        MoveOutcome.Rejected,
        "Lichess position or connection changed. Choose your move again.",
      )
    try {
      const { chess } = replayLichess(request.before)
      const player = chess.turn() === "w" ? view.game.white : view.game.black
      if (player.id?.toLowerCase() !== this.credentials()?.id.toLowerCase()) throw new Error()
      chess.move({
        from: request.uci.slice(0, 2),
        to: request.uci.slice(2, 4),
        ...(request.uci[4] ? { promotion: request.uci[4] } : {}),
      })
    } catch {
      return outcome(MoveOutcome.Rejected, "This move is not legal for your account.")
    }
    if (Date.now() < this.retryAt)
      return outcome(MoveOutcome.Rejected, "Lichess rate limit. Wait before trying again.")
    // No retries after this point. A lost response may conceal a successfully played move.
    try {
      const response = await this.request(`/api/board/game/${request.gameId}/move/${request.uci}`, {
        method: "POST",
        signal: AbortSignal.timeout(8000),
      })
      if (response.status >= 400 && response.status < 500)
        return outcome(
          MoveOutcome.Rejected,
          response.status === 401
            ? "Reconnect your Lichess account."
            : "Lichess rejected the move. Check the game and its time control.",
        )
      if (!response.ok) throw new Error()
      const before = replayLichess(request.before).history
      const deadline = Date.now() + 5000
      while (Date.now() < deadline) {
        const latest = this.stream?.view
        if (latest?.game.id !== request.gameId) break
        const history = replayLichess(latest.game.state.moves).history
        if (
          before.every((move, index) => history[index] === move) &&
          history[before.length] === request.uci
        )
          return outcome(MoveOutcome.ObservedComplete, "Move confirmed by Lichess.")
        await new Promise((resolve) => setTimeout(resolve, 50))
      }
    } catch {
      /* Preserve uncertainty, including network errors and confirmation timeouts. */
    }
    return outcome(
      MoveOutcome.Uncertain,
      "Lichess move unconfirmed. Inspect the game and reconnect.",
    )
  }
}
