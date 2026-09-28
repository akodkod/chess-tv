import { MAX_BYTES, messageSchema, type Message } from "@chess-tv/protocol"

export class RelayLink {
  socket?: WebSocket
  authenticated = false
  stopped = true
  attempt = 0
  nextAttempt = 0
  lastPong = 0
  nonce?: string
  private retry?: ReturnType<typeof setTimeout>
  private heartbeat?: ReturnType<typeof setInterval>
  private deadline?: ReturnType<typeof setTimeout>
  constructor(
    private url: string,
    private credential: string,
    private receive: (m: Message) => void,
    private status: (status: string, fatal: boolean) => void,
  ) {}
  start() {
    this.stopped = false
    this.connect()
  }
  wake() {
    if (!this.stopped && !this.socket && Date.now() >= this.nextAttempt) this.connect()
  }
  send(message: Message) {
    if (!this.authenticated || this.socket?.readyState !== WebSocket.OPEN) return false
    this.socket.send(JSON.stringify(message))
    return true
  }
  private connect() {
    if (this.stopped || this.socket) return
    clearTimeout(this.retry)
    this.status("Connecting to relay…", false)
    const ws = new WebSocket(this.url)
    this.socket = ws
    this.deadline = setTimeout(() => ws.close(), 5000)
    ws.onopen = () =>
      ws.send(JSON.stringify({ v: 1, type: "authenticate", credential: this.credential }))
    ws.onmessage = (e) => {
      if (ws !== this.socket) return
      let value: unknown
      try {
        if (typeof e.data !== "string" || new TextEncoder().encode(e.data).length > MAX_BYTES)
          throw new Error()
        value = JSON.parse(e.data)
      } catch {
        this.fail("Invalid relay message. Update the extension or check the relay.")
        return
      }
      const parsed = messageSchema.safeParse(value)
      if (!parsed.success) {
        this.fail("Incompatible relay protocol. Update the extension or relay.")
        return
      }
      const m = parsed.data
      if (m.type === "authenticated") {
        if (m.role !== "extension" || this.authenticated) {
          this.fail("Relay returned an invalid device role.")
          return
        }
        clearTimeout(this.deadline)
        this.authenticated = true
        this.attempt = 0
        this.lastPong = Date.now()
        this.status("Connected to relay", false)
        this.heartbeat = setInterval(() => {
          if (Date.now() - this.lastPong >= 60000) {
            ws.close()
            return
          }
          this.nonce ??= crypto.randomUUID()
          this.send({ v: 1, type: "ping", nonce: this.nonce })
        }, 20000)
      } else if (m.type === "ping") this.send({ v: 1, type: "pong", nonce: m.nonce })
      else if (m.type === "pong") {
        if (m.nonce === this.nonce) {
          this.lastPong = Date.now()
          this.nonce = undefined
        }
      } else if (!this.authenticated) {
        this.fail("Relay authentication failed. Pair again.")
        return
      }
      this.receive(m)
    }
    ws.onerror = () => ws.close()
    ws.onclose = (e) => {
      if (ws !== this.socket) return
      this.clear()
      if (this.stopped) return
      if ([4001, 4003, 1008].includes(e.code)) {
        this.stopped = true
        this.status(
          e.code === 4003
            ? "Pairing revoked. Unpair locally, then pair again."
            : e.code === 4001
              ? "Connection replaced. Choose Reconnect relay to take over."
              : "Relay rejected the connection. Pair again.",
          true,
        )
        return
      }
      this.status("Relay disconnected. Reconnecting…", false)
      const delay =
        Math.min(30000, 1000 * 2 ** Math.min(this.attempt++, 5)) * (0.75 + Math.random() * 0.5)
      this.nextAttempt = Date.now() + delay
      this.retry = setTimeout(() => this.connect(), delay)
    }
  }
  private clear() {
    clearTimeout(this.deadline)
    clearInterval(this.heartbeat)
    this.socket = undefined
    this.authenticated = false
    this.nonce = undefined
  }
  private fail(reason: string) {
    this.stop()
    this.status(reason, true)
  }
  stop() {
    this.stopped = true
    clearTimeout(this.retry)
    const ws = this.socket
    this.clear()
    ws?.close()
  }
}
