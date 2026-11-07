export function lichessGameID(value?: string): string | null {
  if (!value) return null
  try {
    const url = new URL(value)
    if (url.origin !== "https://lichess.org" || url.username || url.password) return null
    const match =
      /^\/(?:game\/)?([a-zA-Z0-9]{8})(?:[a-zA-Z0-9]{4})?(?:\/(?:white|black))?\/?$/.exec(
        url.pathname,
      )
    if (
      !match ||
      ["training", "analysis", "practice", "features", "password", "timeline", "streamer"].includes(
        match[1]!,
      )
    )
      return null
    return match[1]!
  } catch {
    return null
  }
}
