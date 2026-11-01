export const onlineGamePath = (path: string) => /^\/game\/(?:live\/)?\d+\/?$/.test(path)

export const liveBotPath = (path: string) =>
  path === "/play/computer" || path.startsWith("/play/computer/")

// Chess.com replaces the live URL with this archive URL when a bot game finishes.
export const completedBotPath = (path: string) => /^\/game\/computer\/\d+\/?$/.test(path)

export function allowedGameURL(value?: string): boolean {
  if (!value) return false
  try {
    const url = new URL(value)
    return (
      url.origin === "https://www.chess.com" &&
      (liveBotPath(url.pathname) ||
        completedBotPath(url.pathname) ||
        url.pathname === "/play/coach" ||
        url.pathname.startsWith("/play/coach/") ||
        url.pathname === "/play/online" ||
        url.pathname.startsWith("/play/online/") ||
        onlineGamePath(url.pathname))
    )
  } catch {
    return false
  }
}
