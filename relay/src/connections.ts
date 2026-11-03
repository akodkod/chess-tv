import { randomUUID } from "node:crypto"

import {
  DeviceRole,
  MessageKind,
  VERSION,
  MAX_BYTES,
  messageSchema,
  type Message,
  type Role,
} from "@chess-tv/protocol"
import type { SQL } from "bun"
import type { WSContext, WSEvents } from "hono/ws"

import { authenticate } from "./database"

type Client = {
  ws: WSContext
  pairingId?: string
  role?: Role
  closed: boolean
  authenticating: boolean
  deadline: number
  authTimer?: ReturnType<typeof setTimeout>
  lastPong: number
  lastPing: number
  nonce?: string
  count: number
  window: number
}
type Session = { generation: string; gameId: string | null; tv?: Client; extension?: Client }
export function connections(sql: SQL, heartbeatMs = 20_000, timeoutMs = 60_000, authMs = 5000) {
  const sessions = new Map<string, Session>()
  const clients = new Set<Client>()
  // An authentication that overlaps revocation must retry against the database.
  let revocationEpoch = 0
  const send = (client: Client | undefined, message: Message) => {
    if (client && !client.closed && client.ws.readyState === 1)
      client.ws.send(JSON.stringify(message))
  }
  function refresh(session: Session) {
    session.generation = randomUUID()
    for (const role of Object.values(DeviceRole))
      send(session[role], {
        v: VERSION,
        type: MessageKind.Session,
        generation: session.generation,
        gameId: session.gameId,
        peerConnected: Boolean(
          session[role === DeviceRole.TV ? DeviceRole.Extension : DeviceRole.TV],
        ),
      })
    if (session.tv && session.extension && session.gameId)
      send(session.extension, {
        v: VERSION,
        type: MessageKind.SnapshotRequest,
        generation: session.generation,
        gameId: session.gameId,
      })
  }
  function remove(client: Client) {
    if (client.closed) return
    client.closed = true
    clearTimeout(client.authTimer)
    clients.delete(client)
    if (!client.pairingId || !client.role) return
    const session = sessions.get(client.pairingId)
    if (!session || session[client.role] !== client) return
    delete session[client.role]
    if (client.role === DeviceRole.Extension) session.gameId = null
    if (!session.tv && !session.extension) sessions.delete(client.pairingId)
    else refresh(session)
  }
  function close(client: Client, code: number, reason: string) {
    remove(client)
    client.ws.close(code, reason)
  }
  const error = (client: Client, code: string, message: string) =>
    send(client, { v: VERSION, type: MessageKind.Error, code, message })
  const timer = setInterval(
    () => {
      const now = Date.now()
      for (const client of clients) {
        if (!client.role) {
          if (now >= client.deadline) close(client, 1008, "Authentication timeout")
          continue
        }
        if (now - client.lastPong >= timeoutMs) {
          close(client, 1008, "Heartbeat timeout")
          continue
        }
        // Keep the outstanding nonce until answered, rather than invalidating a delayed pong.
        if (now - client.lastPing < heartbeatMs) continue
        client.lastPing = now
        client.nonce ??= randomUUID()
        send(client, { v: VERSION, type: MessageKind.Ping, nonce: client.nonce })
      }
    },
    Math.min(heartbeatMs, authMs),
  )
  // Authentication deadlines are also checked on every incoming message.
  async function receive(client: Client, data: unknown) {
    if (client.closed) return
    if (typeof data !== "string" || Buffer.byteLength(data) > MAX_BYTES) {
      close(client, 1009, "Text payload limit")
      return
    }
    const now = Date.now()
    if (now - client.window >= 1000) {
      client.window = now
      client.count = 0
    }
    if (++client.count > 60) {
      close(client, 1008, "Rate limit")
      return
    }
    let json: unknown
    try {
      json = JSON.parse(data)
    } catch {
      close(client, 1007, "Invalid JSON")
      return
    }
    const parsed = messageSchema.safeParse(json)
    if (!parsed.success) {
      const incompatible =
        typeof json === "object" && json !== null && "v" in json && json.v !== VERSION
      error(
        client,
        incompatible ? "incompatible_version" : "invalid_message",
        incompatible ? "Use protocol version 3." : "Invalid message shape.",
      )
      close(client, 1008, "Invalid protocol")
      return
    }
    const msg = parsed.data
    if (!client.role) {
      if (
        msg.type !== MessageKind.Authenticate ||
        client.authenticating ||
        now >= client.deadline
      ) {
        close(client, 1008, "Authenticate first")
        return
      }
      client.authenticating = true
      let epoch: number, device
      do {
        epoch = revocationEpoch
        device = await authenticate(sql, msg.credential)
      } while (epoch !== revocationEpoch && !client.closed)
      if (client.closed) return
      if (!device || Date.now() >= client.deadline) {
        close(client, 1008, "Invalid credential")
        return
      }
      clearTimeout(client.authTimer)
      Object.assign(client, device)
      let session = sessions.get(device.pairingId)
      if (!session) {
        session = { generation: randomUUID(), gameId: null }
        sessions.set(device.pairingId, session)
      }
      const previous = session[device.role]
      session[device.role] = client
      if (device.role === DeviceRole.Extension) session.gameId = null
      if (previous) close(previous, 4001, "Connection replaced")
      send(client, { v: VERSION, type: MessageKind.Authenticated, ...device })
      refresh(session)
      return
    }
    if (msg.type === MessageKind.Ping) {
      send(client, { v: VERSION, type: MessageKind.Pong, nonce: msg.nonce })
      return
    }
    if (msg.type === MessageKind.Pong) {
      if (msg.nonce === client.nonce) {
        client.lastPong = now
        client.nonce = undefined
      }
      return
    }
    const session = sessions.get(client.pairingId!)
    if (!session || session[client.role] !== client) return
    const allowed: MessageKind[] =
      client.role === DeviceRole.Extension
        ? [MessageKind.Attachment, MessageKind.Status, MessageKind.Snapshot, MessageKind.Outcome]
        : [MessageKind.Move, MessageKind.SnapshotRequest]
    if (!allowed.includes(msg.type)) {
      error(client, "wrong_role", "Message is not allowed for this endpoint.")
      return
    }
    if (!("generation" in msg) || msg.generation !== session.generation) {
      error(client, "stale_session", "Wait for the current session and a fresh snapshot.")
      return
    }
    if (msg.type === MessageKind.Attachment) {
      if (msg.gameId !== session.gameId) {
        session.gameId = msg.gameId
        refresh(session)
      }
      return
    }
    if (!("gameId" in msg) || !session.gameId || msg.gameId !== session.gameId) {
      error(client, "not_attached", "Attach the game before routing messages.")
      return
    }
    const peer = session[client.role === DeviceRole.TV ? DeviceRole.Extension : DeviceRole.TV]
    if (!peer) {
      error(client, "peer_unavailable", "The other device is disconnected. Do not replay moves.")
      return
    }
    send(peer, msg)
  }
  return {
    events(): WSEvents {
      let client: Client
      return {
        onOpen(_event, ws) {
          const now = Date.now()
          client = {
            ws,
            closed: false,
            authenticating: false,
            deadline: now + authMs,
            lastPong: now,
            lastPing: now,
            count: 0,
            window: now,
          }
          client.authTimer = setTimeout(() => close(client, 1008, "Authentication timeout"), authMs)
          clients.add(client)
        },
        onMessage(event) {
          void receive(client, event.data).catch(() => {
            console.error("websocket_operation_failed")
            close(client, 1011, "Server error")
          })
        },
        onClose() {
          if (client) remove(client)
        },
        onError() {
          if (client) close(client, 1011, "Transport error")
        },
      }
    },
    revoke(id: string) {
      revocationEpoch++
      const session = sessions.get(id)
      if (!session) return
      sessions.delete(id)
      for (const client of [session.tv, session.extension])
        if (client) close(client, 4003, "Pairing revoked")
    },
    stop() {
      clearInterval(timer)
      for (const client of clients) close(client, 1001, "Server shutdown")
    },
  }
}
