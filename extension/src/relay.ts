import {
  DeviceRole,
  MessageKind,
  VERSION,
  MAX_BYTES,
  messageSchema,
  type Message,
} from "@chess-tv/protocol"

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
  private authenticateBy = 0
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
    if (this.stopped) return
    if (this.socket) {
      if (
        this.authenticated ? Date.now() - this.lastPong >= 60000 : Date.now() >= this.authenticateBy
      )
        this.closed(this.socket, 0, "Connection timed out")
    } else if (Date.now() >= this.nextAttempt) this.connect()
  }
  send(message: Message) {
    if (!this.authenticated || this.socket?.readyState !== WebSocket.OPEN) return false
    try {
      this.socket.send(JSON.stringify(message))
      return true
    } catch {
      this.closed(this.socket, 0, "Send failed")
      return false
    }
  }
  private connect() {
    if (this.stopped || this.socket) return
    clearTimeout(this.retry)
    this.status("Connecting to relay…", false)
    let ws: WebSocket
    try {
      ws = new WebSocket(this.url)
    } catch {
      this.scheduleRetry()
      return
    }
    this.socket = ws
    this.authenticateBy = Date.now() + 5000
    this.deadline = setTimeout(() => this.closed(ws, 0, "Authentication timeout"), 5000)
    ws.onopen = () => {
      if (ws !== this.socket) return
      try {
        ws.send(
          JSON.stringify({
            v: VERSION,
            type: MessageKind.Authenticate,
            credential: this.credential,
          }),
        )
      } catch {
        this.closed(ws, 0, "Authentication failed")
      }
    }
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
      if (m.type === MessageKind.Authenticated) {
        if (m.role !== DeviceRole.Extension || this.authenticated) {
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
            this.closed(ws, 0, "Heartbeat timeout")
            return
          }
          this.nonce ??= crypto.randomUUID()
          this.send({ v: VERSION, type: MessageKind.Ping, nonce: this.nonce })
        }, 20000)
      } else if (m.type === MessageKind.Ping)
        this.send({ v: VERSION, type: MessageKind.Pong, nonce: m.nonce })
      else if (m.type === MessageKind.Pong) {
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
    ws.onerror = () => this.closed(ws, 0, "Transport error")
    ws.onclose = (e) => this.closed(ws, e.code, e.reason)
  }
  private closed(ws: WebSocket, code: number, reason: string) {
    if (ws !== this.socket) return
    this.clear()
    // Do not wait for the closing handshake on a dead transport before retrying.
    ws.close()
    if (this.stopped) return
    if (
      [4001, 4003, 1002, 1007, 1009].includes(code) ||
      (code === 1008 && !["Heartbeat timeout", "Authentication timeout"].includes(reason))
    ) {
      this.stopped = true
      this.status(
        code === 4003
          ? "Pairing revoked. Unpair locally, then pair again."
          : code === 4001
            ? "Connection replaced. Choose Reconnect relay to take over."
            : "Relay rejected the connection. Pair again.",
        true,
      )
      return
    }
    this.scheduleRetry()
  }
  private scheduleRetry() {
    this.status("Relay disconnected. Reconnecting…", false)
    const delay = Math.min(30000, 1000 * 2 ** this.attempt * (0.75 + Math.random() * 0.5))
    this.attempt = Math.min(this.attempt + 1, 5)
    this.nextAttempt = Date.now() + delay
    clearTimeout(this.retry)
    this.retry = setTimeout(() => this.connect(), delay)
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
