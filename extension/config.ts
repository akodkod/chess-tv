export function buildSettings(mode: string, relayValue?: string) {
  const simulator = mode === "simulator"
  const relay = new URL(
    relayValue || (simulator ? "http://127.0.0.1:3000" : "https://relay.invalid"),
  )
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
  if (!simulator && !relayValue)
    throw new Error("Set RELAY_URL for a production build, or use --mode simulator.")
  const socket = new URL("/v1/ws", relay)
  socket.protocol = relay.protocol === "https:" ? "wss:" : "ws:"
  // Chrome match patterns scope hosts, not ports. Runtime checks enforce exact origins.
  const host = `${relay.protocol}//${relay.hostname}/*`
  return {
    relay: relay.origin,
    socket: socket.href,
    simulator,
    simulatorOrigin: "http://127.0.0.1:4173",
    manifest: {
      manifest_version: 3,
      name: simulator ? "Chess TV · Simulator" : "Chess TV",
      version: "0.1.0",
      minimum_chrome_version: "116",
      description:
        "Pair with Chess TV. Simulator only; Chess.com integration is not yet supported.",
      permissions: ["storage", "scripting", "alarms"],
      host_permissions: [...new Set([host, ...(simulator ? ["http://127.0.0.1/*"] : [])])],
      action: { default_popup: "popup.html", default_title: "Chess TV" },
      background: { service_worker: "worker.js", type: "module" },
      content_security_policy: { extension_pages: "script-src 'self'; object-src 'none'" },
    },
  }
}
