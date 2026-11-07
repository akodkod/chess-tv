import { allowedGameURL as chesscom } from "./chesscom-url"
import { lichessGameID } from "./lichess-url"

export const allowedGameURL = (url?: string) => chesscom(url) || lichessGameID(url) !== null
