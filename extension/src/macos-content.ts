import { ChessComAdapter } from "./chesscom-adapter"
import { allowedGameURL } from "./chesscom-url"

// Installed only in the app's isolated WKContentWorld, never the page world.
const scope = globalThis as typeof globalThis & {
  chessTV?: { handle: (action: unknown) => ReturnType<ChessComAdapter["handle"]> }
}
if (location.origin === "https://www.chess.com" && !scope.chessTV) {
  const adapter = new ChessComAdapter(document, { allowBackground: true })
  scope.chessTV = {
    handle(action) {
      if (!allowedGameURL(location.href)) throw new Error("Open a supported Chess.com game.")
      return adapter.handle(action)
    },
  }
}
