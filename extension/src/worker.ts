import type { Message } from "@chess-tv/protocol"
import { z } from "zod"

import { contentReply, popupAction, type ContentReply, type PopupState } from "./messages"
import { Pairing, savedSchema } from "./pairing"
import { RelayLink } from "./relay"

const bindingSchema = z.strictObject({
  tabId: z.number(),
  gameId: z.string(),
  instance: z.string(),
  risk: z.boolean(),
  commandId: z.string().nullable(),
  locked: z.boolean(),
})
type Binding = z.infer<typeof bindingSchema>
let autoConnect = true
let binding: Binding | undefined
let link: RelayLink | undefined
let generation: string | undefined
let attached: string | null = null
let peerConnected = false
let phase: "idle" | "detaching" | "attaching" = "idle"
let available = false
let status = "Enter the code displayed on your TV."
let error: string | null = null
let serial = Promise.resolve()
const pairing = new Pairing(__SETTINGS__.relay, async (saved) => {
  await chrome.storage.local.set({ pairing: saved })
})
const ready = (async () => {
  await chrome.storage.local.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" })
  await chrome.storage.session.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" })
  autoConnect = (await chrome.storage.local.get("autoConnect")).autoConnect !== false
  const stored = savedSchema.safeParse((await chrome.storage.local.get("pairing")).pairing)
  if (stored.success && stored.data.relay === __SETTINGS__.relay) pairing.saved = stored.data
  const previous = bindingSchema.safeParse((await chrome.storage.session.get("binding")).binding)
  if (previous.success) {
    binding = previous.data
    if (binding.risk) binding.locked = true
  }
  await chrome.alarms.create("recover", { periodInMinutes: 1 })
})()
function enqueue(action: () => Promise<void>) {
  serial = serial
    .then(() => ready)
    .then(action)
    .catch(() => {
      available = false
      error = "Operation failed. Check the relay and reconnect the game."
    })
  return serial
}
async function saveBinding() {
  if (binding) await chrome.storage.session.set({ binding })
  else await chrome.storage.session.remove("binding")
}
function supported(url?: string) {
  if (!url || !__SETTINGS__.simulator) return false
  const parsed = new URL(url)
  return parsed.origin === __SETTINGS__.simulatorOrigin && parsed.pathname === "/"
}
function state(): PopupState {
  return {
    autoConnect,
    paired: !!pairing.saved.device,
    pairing: !!pairing.saved.claim,
    connected: !!link?.authenticated,
    peerConnected,
    gameId: binding?.gameId ?? null,
    available,
    status,
    error,
    simulator: __SETTINGS__.simulator,
    relay: __SETTINGS__.relay,
  }
}
async function content(action: unknown): Promise<ContentReply> {
  if (!binding) throw new Error("No game attached.")
  return contentReply.parse(await chrome.tabs.sendMessage(binding.tabId, action, { frameId: 0 }))
}
async function active() {
  if (!binding) return false
  const tab = await chrome.tabs.get(binding.tabId)
  return supported(tab.url) && tab.active && (await chrome.windows.get(tab.windowId)).focused
}
function connect() {
  if (!pairing.saved.device || pairing.saved.revocationPending || link) return
  link = new RelayLink(
    __SETTINGS__.socket,
    pairing.saved.device.credential,
    (m) => {
      void enqueue(() => receive(m))
    },
    (text, fatal) => {
      status = text
      available = false
      if (!link?.authenticated) {
        generation = undefined
        attached = null
        peerConnected = false
        phase = "idle"
      }
      if (fatal) error = text
    },
  )
  link.start()
}
function sendAttachment(gameId: string | null) {
  if (generation && link?.authenticated) {
    phase = gameId === null ? "detaching" : "attaching"
    link.send({ v: 1, type: "attachment", generation, gameId })
  }
}
async function processReply(reply: ContentReply) {
  if (!binding || !generation) return
  if (reply.error) {
    available = false
    status = reply.error
    if (reply.error.startsWith("Game changed")) await detach()
    else reportUnavailable(reply.error)
    return
  }
  if (reply.gameId !== binding.gameId) {
    await detach()
    status = "Game changed. Waiting for the current game to connect."
    return
  }
  if (reply.instance !== binding.instance) {
    binding.instance = reply.instance
    if (binding.risk) binding.locked = true
    await saveBinding()
    available = false
    // A new document lost the adapter's command history. Obtain another generation first.
    if (attached) sendAttachment(null)
    return
  }
  if (phase !== "idle" || attached !== binding.gameId) return
  for (const message of reply.messages) {
    if (
      !("generation" in message) ||
      message.generation !== generation ||
      !("gameId" in message) ||
      message.gameId !== attached ||
      !["snapshot", "status", "outcome"].includes(message.type)
    )
      continue
    if (
      message.type === "outcome" &&
      message.outcome !== "uncertain" &&
      message.commandId === binding.commandId
    ) {
      binding.risk = false
      binding.commandId = null
      await saveBinding()
    }
    if (message.type === "status") {
      available = message.available && peerConnected && !binding.locked
      status = binding.locked
        ? "An interrupted move needs inspection. Reconnect the game."
        : (message.reason ?? "Ready for your move.")
      link?.send({ ...message, available, reason: available ? null : status })
    } else link?.send(message)
  }
}
function reportUnavailable(reason: string) {
  available = false
  if (generation && attached)
    link?.send({ v: 1, type: "status", gameId: attached, generation, available: false, reason })
}
async function synchronize() {
  if (!binding || !generation || !link?.authenticated || phase !== "idle") return
  try {
    if (!attached) {
      const reply = await content({ kind: "inspect" })
      if (reply.error || reply.gameId !== binding.gameId) {
        await detach()
        status = reply.error || "Game changed. Waiting for the current game to connect."
        return
      }
      if (reply.instance !== binding.instance) {
        binding.instance = reply.instance
        if (binding.risk) binding.locked = true
        await saveBinding()
      }
      sendAttachment(binding.gameId)
      return
    }
    await processReply(
      await content({
        kind: "sync",
        generation,
        enabled: peerConnected && !binding.locked && (await active()),
      }),
    )
  } catch {
    reportUnavailable("Game unavailable. Keep the attached simulator open and visible.")
  }
}
async function receive(message: Message) {
  if (message.type === "session") {
    available = false
    generation = message.generation
    attached = message.gameId
    peerConnected = message.peerConnected
    phase = "idle"
    await synchronize()
  } else if (message.type === "snapshot-request") {
    if (message.generation === generation && message.gameId === attached) await synchronize()
  } else if (message.type === "move") {
    if (
      message.generation !== generation ||
      message.gameId !== attached ||
      !binding ||
      phase !== "idle"
    )
      return
    await synchronize()
    if (
      !binding ||
      message.generation !== generation ||
      message.gameId !== attached ||
      phase !== "idle"
    )
      return
    // Persist uncertainty BEFORE dispatch. A crash/reload cannot make this command replayable.
    if (!binding.risk) {
      binding.risk = true
      binding.commandId = message.commandId
    }
    await saveBinding()
    try {
      const foreground = await active()
      if (
        !foreground ||
        !link?.authenticated ||
        generation !== message.generation ||
        !peerConnected ||
        binding.locked
      ) {
        reportUnavailable("Connection or page availability changed before submission.")
        if (binding.commandId === message.commandId) {
          binding.risk = false
          binding.commandId = null
          await saveBinding()
        }
        link?.send({
          v: 1,
          type: "outcome",
          gameId: message.gameId,
          generation: message.generation,
          commandId: message.commandId,
          outcome: "rejected",
          reason: "Move was not submitted: connection or page unavailable.",
        })
        return
      }
      await processReply(await content({ kind: "move", move: message }))
    } catch {
      binding.locked = true
      await saveBinding()
      reportUnavailable("Move interrupted. Inspect Chrome and reconnect the game.")
    }
  } else if (message.type === "error") {
    error = message.message
    reportUnavailable(message.message)
  }
}
async function setAutoConnect(enabled: boolean) {
  autoConnect = enabled
  await chrome.storage.local.set({ autoConnect })
}
async function detach() {
  // Never automatically discard ambiguity, even if the game navigates or closes.
  if (binding?.risk || binding?.locked) await setAutoConnect(false)
  available = false
  if (binding) {
    try {
      await content({ kind: "stop" })
    } catch {
      /* Closed or navigated tab. */
    }
  }
  binding = undefined
  await saveBinding()
  if (attached) sendAttachment(null)
  status = "No game connected. Pairing is remembered."
}
async function attach(automatic = false) {
  if (!pairing.saved.device || !link?.authenticated || !generation)
    throw new Error("Pair and connect to the relay first.")
  if (phase !== "idle") throw new Error("Wait for the connection to synchronize.")
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true })
  if (!tab?.id || !supported(tab.url))
    throw new Error("Simulator only. Open http://127.0.0.1:4173/ in the active tab.")
  if (automatic && !(await chrome.windows.get(tab.windowId)).focused) return
  await detach()
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] })
  const reply = contentReply.parse(
    await chrome.tabs.sendMessage(tab.id, { kind: "inspect" }, { frameId: 0 }),
  )
  if (reply.error || !reply.gameId) throw new Error(reply.error || "No supported game found.")
  binding = {
    tabId: tab.id,
    gameId: reply.gameId,
    instance: reply.instance,
    risk: false,
    commandId: null,
    locked: false,
  }
  await saveBinding()
  await synchronize()
}
async function autoAttach() {
  if (
    binding ||
    !autoConnect ||
    !pairing.saved.device ||
    pairing.saved.revocationPending ||
    !link?.authenticated ||
    !generation ||
    phase !== "idle"
  )
    return
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true })
  if (!supported(tab?.url)) return
  try {
    await attach(true)
  } catch {
    status = "Waiting for a readable simulator game in the active Chrome tab."
  }
}
async function tick() {
  if (pairing.saved.claim) {
    try {
      await pairing.poll()
      error = null
      status = pairing.saved.claim ? "Confirm this pairing on your TV." : "Pairing complete."
    } catch (e) {
      error = e instanceof Error ? e.message : "Cannot check pairing."
    }
  }
  connect()
  link?.wake()
  await synchronize()
  await autoAttach()
}
chrome.runtime.onMessage.addListener((raw: unknown, sender, reply) => {
  // Only our popup may operate the worker. Content scripts never receive credentials.
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL("popup.html")) return
  const parsed = popupAction.safeParse(raw)
  if (!parsed.success) {
    reply({ error: "Invalid request." })
    return
  }
  void enqueue(async () => {
    try {
      const action = parsed.data
      if (action.kind === "pair") {
        error = null
        await pairing.claim(action.code)
        await setAutoConnect(true)
        status = "Confirm this pairing on your TV."
      }
      if (action.kind === "attach") {
        error = null
        await attach()
        await setAutoConnect(true)
      }
      if (action.kind === "disconnect") {
        error = null
        await setAutoConnect(false)
        await detach()
        status = "Automatic connection paused. Connect this game to resume."
      }
      if (action.kind === "unpair") {
        await detach()
        link?.stop()
        link = undefined
        generation = undefined
        attached = null
        peerConnected = false
        try {
          await pairing.unpair()
          error = null
          status = "Unpaired. Enter a new TV code to pair again."
        } catch {
          throw new Error("Remote revocation incomplete. Reconnect and retry Unpair.")
        }
      }
      if (action.kind === "reconnect" && !pairing.saved.revocationPending) {
        link?.stop()
        error = null
        link = undefined
        connect()
      }
    } catch (e) {
      error = e instanceof Error ? e.message : "Operation failed."
    }
    reply(state())
  })
  return true
})
chrome.tabs.onRemoved.addListener((id) => {
  if (binding?.tabId === id) void enqueue(detach)
})
chrome.tabs.onUpdated.addListener((id, change) => {
  if (binding?.tabId !== id) return
  if (change.status === "loading" || change.url) {
    available = false
    void enqueue(async () => {
      reportUnavailable("Page is reloading or navigating.")
      if (change.url && !supported(change.url)) await detach()
    })
  }
  if (change.status === "complete")
    void enqueue(async () => {
      if (!binding) return
      const tab = await chrome.tabs.get(id)
      if (!supported(tab.url)) {
        await detach()
        return
      }
      await chrome.scripting.executeScript({ target: { tabId: id }, files: ["content.js"] })
      await synchronize()
    })
})
chrome.tabs.onActivated.addListener(() => {
  available = false
  void enqueue(synchronize)
})
chrome.windows.onFocusChanged.addListener(() => {
  available = false
  void enqueue(synchronize)
})
chrome.alarms.onAlarm.addListener(scheduleTick)
chrome.runtime.onStartup.addListener(scheduleTick)
chrome.runtime.onInstalled.addListener(scheduleTick)
let tickQueued = false
function scheduleTick() {
  if (tickQueued) return
  tickQueued = true
  void enqueue(tick).finally(() => {
    tickQueued = false
  })
}
setInterval(scheduleTick, 1000)
scheduleTick()
