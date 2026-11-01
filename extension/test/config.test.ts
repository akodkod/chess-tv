import { expect, it } from "vite-plus/test"

import { buildSettings } from "../config"

it("builds Chess.com with the default hosted relay access", () => {
  const settings = buildSettings("production")
  expect(settings.manifest.name).toBe("Chess TV")
  expect(settings.manifest.host_permissions).toEqual([
    "https://www.chess.com/play/computer/*",
    "https://chess-tv-relay.kodkod.me/*",
  ])
  expect(settings.manifest.permissions).toEqual(["storage", "scripting", "alarms"])
})
it("adds only the explicitly configured relay host", () => {
  const settings = buildSettings("production", "https://relay.example.com")
  expect(settings.manifest.host_permissions).toEqual([
    "https://www.chess.com/play/computer/*",
    "https://relay.example.com/*",
  ])
  expect(settings.socket).toBe("wss://relay.example.com/v1/ws")
})
it("rejects removed modes and insecure or ambiguous relay endpoints", () => {
  expect(() => buildSettings("simulator")).toThrow("Unsupported build mode")
  for (const url of [
    "http://example.com",
    "https://a:b@example.com",
    "https://example.com/path",
    "https://example.com?q=secret",
    "ftp://127.0.0.1",
  ])
    expect(() => buildSettings("production", url)).toThrow()
})
