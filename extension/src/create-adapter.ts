import { ChessComAdapter } from "./chesscom-adapter"
import { LichessAdapter, type LichessRPC } from "./lichess-driver"

export function createAdapter(doc: Document, rpc: LichessRPC, allowBackground = false) {
  return doc.location.origin === "https://lichess.org"
    ? new LichessAdapter(doc, rpc, allowBackground)
    : new ChessComAdapter(doc, { allowBackground })
}
