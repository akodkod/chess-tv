import { expect, it } from "vite-plus/test"

import { buildSettings } from "../config"
it("separates simulator access from production permissions", () => {
  const development = buildSettings("simulator")
  expect(development.relay).toBe("http://127.0.0.1:3000")
  const production = buildSettings("production", "https://relay.example.com")
  expect(production.manifest.host_permissions).toEqual(["https://relay.example.com/*"])
  expect(production.manifest.permissions).toEqual(["storage", "scripting", "alarms"])
  expect(production.manifest.minimum_chrome_version).toBe("116")
})
it("rejects insecure and ambiguous configured endpoints", () => {
  for (const url of [
    "http://example.com",
    "https://a:b@example.com",
    "https://example.com/path",
    "https://example.com?q=secret",
    "ftp://127.0.0.1",
  ])
    expect(() => buildSettings("production", url)).toThrow()
  expect(() => buildSettings("production")).toThrow("RELAY_URL")
})
