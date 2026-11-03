import { expect, it } from "vite-plus/test"

import { displayText } from "../src/display-text"
it.each([
  ["Viewing game.", "Viewing game"],
  ["Open Chess.com to watch.", "Open Chess.com to watch"],
  ["Game changed. Connect again.", "Game changed. Connect again."],
  ["Connecting…", "Connecting…"],
])("formats UI text %s", (input, expected) => expect(displayText(input)).toBe(expected))
