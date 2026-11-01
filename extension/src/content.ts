import { ChessComAdapter } from "./chesscom-adapter"

const scope = globalThis as typeof globalThis & { chessTVInstalled?: boolean }
if (
  !scope.chessTVInstalled &&
  location.origin === "https://www.chess.com" &&
  location.pathname.startsWith("/play/computer/")
) {
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
