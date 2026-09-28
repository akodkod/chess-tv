import { Adapter, clickMove, readPage } from "./adapter"
import { contentAction, type ContentReply } from "./messages"

// Injection is idempotent within a document; a reload necessarily creates a new instance.
const scope = globalThis as typeof globalThis & { chessTVInstalled?: boolean }
if (
  !scope.chessTVInstalled &&
  __SETTINGS__.simulator &&
  location.origin === __SETTINGS__.simulatorOrigin &&
  location.pathname === "/"
) {
  scope.chessTVInstalled = true
  const instance = crypto.randomUUID()
  let adapter = new Adapter(
    () => readPage(document),
    (move) => clickMove(document, move),
  )
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) adapter.stop()
  })
  chrome.runtime.onMessage.addListener((raw: unknown, sender, reply) => {
    if (sender.id !== chrome.runtime.id || sender.tab) return
    const parsed = contentAction.safeParse(raw)
    if (!parsed.success) return
    const action = parsed.data
    const response: ContentReply = { instance, gameId: null, messages: [], error: null }
    try {
      if (action.kind === "stop") {
        adapter = new Adapter(
          () => readPage(document),
          (move) => clickMove(document, move),
        )
      } else if (action.kind === "inspect") response.gameId = adapter.inspect()
      else {
        if (action.kind === "sync")
          adapter.session(action.generation, action.enabled && !document.hidden)
        // Visibility is rechecked at the last boundary before interacting with the page.
        if (document.hidden) adapter.stop()
        response.messages = action.kind === "move" ? adapter.move(action.move) : adapter.observe()
        response.gameId = adapter.gameId
      }
    } catch (e) {
      adapter.stop()
      response.error =
        e instanceof Error && e.message.startsWith("Game changed")
          ? e.message
          : "Observation or interaction unavailable. Inspect Chrome and reconnect."
    }
    reply(response)
  })
}
