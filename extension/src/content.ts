import { createAdapter } from "./create-adapter"
import { allowedGameURL } from "./game-sites"

const scope = globalThis as typeof globalThis & { chessTVInstalled?: boolean }
if (!scope.chessTVInstalled && allowedGameURL(location.href)) {
  scope.chessTVInstalled = true
  const adapter = createAdapter(document, async (request) => {
    const response = await chrome.runtime.sendMessage(request)
    if (response?.error) throw new Error(response.error)
    return response
  })
  chrome.runtime.onMessage.addListener((raw: unknown, sender, reply) => {
    // Commands originate in our service worker, never a web page or another tab.
    if (
      sender.id !== chrome.runtime.id ||
      sender.tab ||
      sender.url === chrome.runtime.getURL("popup.html")
    )
      return
    void adapter.handle(raw).then(reply)
    return true
  })
}
