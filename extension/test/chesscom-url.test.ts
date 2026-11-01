import { expect, it } from "vite-plus/test"

import { allowedGameURL } from "../src/chesscom-url"

it.each([
  "/play/computer",
  "/play/computer/",
  "/play/computer?color=black",
  "/play/computer/Zach-BOT",
  "/game/computer/123",
  "/play/coach",
  "/play/coach?source=play_nav",
  "/play/coach/",
  "/play/online",
  "/play/online/",
  "/game/live/123",
  "/game/186358488264",
])("accepts allowed game URL %s", (path) => {
  expect(allowedGameURL(`https://www.chess.com${path}`)).toBe(true)
})
it.each([
  undefined,
  "invalid",
  "https://www.chess.com/play/computers",
  "https://www.chess.com/play/computer-other",
  "https://www.chess.com/play/online-other",
  "https://www.chess.com/play/coaching",
  "https://www.chess.com/game/live/not-a-game",
  "https://example.com/play/computer",
  "http://www.chess.com/play/computer",
])("rejects unrelated URL %s", (url) => {
  expect(allowedGameURL(url)).toBe(false)
})
