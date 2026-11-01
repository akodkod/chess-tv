import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test"

import { RelayLink } from "../src/relay"

class Socket {
  static OPEN = 1
  static instances: Socket[] = []
  readyState = 0
  onopen?: () => void
  onmessage?: (event: { data: string }) => void
  onclose?: (event: { code: number; reason: string }) => void
  onerror?: () => void
  send = vi.fn()
  // Simulate a dead transport whose closing handshake never finishes.
  close = vi.fn(() => {
    this.readyState = 2
  })
  constructor() {
    Socket.instances.push(this)
  }
  authenticate() {
    this.readyState = 1
    this.onopen?.()
    this.onmessage?.({
      data: JSON.stringify({ v: 1, type: "authenticated", role: "extension", pairingId: "pair" }),
    })
  }
  closed(code: number, reason = "") {
    this.onclose?.({ code, reason })
  }
}
let link: RelayLink
const status = vi.fn()
beforeEach(() => {
  vi.useFakeTimers()
  vi.spyOn(Math, "random").mockReturnValue(0.5)
  vi.stubGlobal("WebSocket", Socket)
  Socket.instances = []
  status.mockClear()
  link = new RelayLink("ws://example.test", "credential", vi.fn(), status)
  link.start()
})
afterEach(() => {
  link.stop()
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})
it.each(["Heartbeat timeout", "Authentication timeout"])("retries relay %s", async (reason) => {
  Socket.instances[0]!.authenticate()
  Socket.instances[0]!.closed(1008, reason)
  expect(link.authenticated).toBe(false)
  expect(link.stopped).toBe(false)
  await vi.advanceTimersByTimeAsync(1000)
  expect(Socket.instances).toHaveLength(2)
  Socket.instances[1]!.authenticate()
  expect(link.authenticated).toBe(true)
})
it("recovers a hung handshake without waiting for onclose and ignores late callbacks", async () => {
  const old = Socket.instances[0]!
  await vi.advanceTimersByTimeAsync(6000)
  expect(Socket.instances).toHaveLength(2)
  Socket.instances[1]!.authenticate()
  old.authenticate()
  old.closed(4003)
  old.onerror?.()
  expect(old.send).not.toHaveBeenCalled()
  expect(link.authenticated).toBe(true)
  expect(link.stopped).toBe(false)
})
it("recovers a silent socket when the worker wakes after missed timers", () => {
  Socket.instances[0]!.authenticate()
  vi.setSystemTime(Date.now() + 60001)
  link.wake()
  expect(link.authenticated).toBe(false)
  vi.setSystemTime(Date.now() + 1000)
  link.wake()
  expect(Socket.instances).toHaveLength(2)
})
it("retries send failures without throwing or replaying messages", async () => {
  Socket.instances[0]!.authenticate()
  Socket.instances[0]!.send.mockImplementation(() => {
    throw new Error("offline")
  })
  expect(link.send({ v: 1, type: "ping", nonce: "ping" })).toBe(false)
  await vi.advanceTimersByTimeAsync(1000)
  Socket.instances[1]!.authenticate()
  expect(Socket.instances[1]!.send).toHaveBeenCalledTimes(1)
})
it("backs off repeated failures, caps at 30 seconds and resets after authentication", async () => {
  for (const delay of [1000, 2000, 4000, 8000, 16000, 30000, 30000]) {
    Socket.instances.at(-1)!.closed(1006)
    expect(link.nextAttempt - Date.now()).toBe(delay)
    const count = Socket.instances.length
    await vi.advanceTimersByTimeAsync(delay)
    expect(Socket.instances).toHaveLength(count + 1)
  }
  Socket.instances.at(-1)!.authenticate()
  Socket.instances.at(-1)!.closed(1006)
  expect(link.nextAttempt - Date.now()).toBe(1000)
})
it.each([4001, 4003, 1002, 1007, 1009, 1008])("does not retry terminal close %s", async (code) => {
  Socket.instances[0]!.closed(code, "Invalid credential")
  await vi.advanceTimersByTimeAsync(60000)
  link.wake()
  expect(link.stopped).toBe(true)
  expect(Socket.instances).toHaveLength(1)
})
it("stop cancels scheduled recovery", async () => {
  Socket.instances[0]!.closed(1006)
  link.stop()
  await vi.advanceTimersByTimeAsync(60000)
  link.wake()
  expect(Socket.instances).toHaveLength(1)
})
