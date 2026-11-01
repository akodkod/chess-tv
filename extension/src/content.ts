import { ChessComAdapter } from "./chesscom-adapter"
import { allowedGameURL } from "./chesscom-url"

const scope = globalThis as typeof globalThis & { chessTVInstalled?: boolean }
if (!scope.chessTVInstalled && allowedGameURL(location.href)) {
  scope.chessTVInstalled = true
  const adapter = new ChessComAdapter()
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
