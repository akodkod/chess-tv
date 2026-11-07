export function buildSettings(mode: string, relayValue?: string) {
  if (!["production", "development", "chesscom"].includes(mode))
    throw new Error("Unsupported build mode. Use the default Chess.com build.")
  const relay = new URL(relayValue || "https://chess-tv-relay.kodkod.me")
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(relay.hostname)
  if (
    (relay.protocol !== "https:" && !(loopback && relay.protocol === "http:")) ||
    relay.username ||
    relay.password ||
    relay.search ||
    relay.hash ||
    relay.pathname !== "/"
  )
    throw new Error("RELAY_URL must be an HTTPS origin (HTTP is allowed only on loopback).")
  const socket = new URL("/v1/ws", relay)
  socket.protocol = relay.protocol === "https:" ? "wss:" : "ws:"
  // Chrome match patterns scope hosts, not ports. Runtime checks enforce exact origins.
  const host = `${relay.protocol}//${relay.hostname}/*`
  return {
    relay: relay.origin,
    socket: socket.href,
    manifest: {
      manifest_version: 3,
      name: "Chess TV",
      version: "0.1.0",
      minimum_chrome_version: "116",
      description: "Play Chess.com and Lichess games on Apple TV",
      permissions: ["storage", "scripting", "alarms", "identity"],
      host_permissions: [
        "https://www.chess.com/play/computer*",
        "https://www.chess.com/game/computer/*",
        "https://www.chess.com/play/coach*",
        "https://www.chess.com/play/online*",
        "https://www.chess.com/game/*",
        "https://lichess.org/*",
        host,
      ],
      icons: {
        16: "icons/icon-16.png",
        32: "icons/icon-32.png",
        48: "icons/icon-48.png",
        128: "icons/icon-128.png",
      },
      action: {
        default_popup: "popup.html",
        default_title: "Chess TV",
        default_icon: { 16: "icons/icon-16.png", 32: "icons/icon-32.png" },
      },
      background: { service_worker: "worker.js", type: "module" },
      content_security_policy: { extension_pages: "script-src 'self'; object-src 'none'" },
    },
  }
}
