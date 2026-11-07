import { z } from "zod"

import type { LichessCredential } from "./lichess-api"

const encode = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")

export async function connectLichess(): Promise<LichessCredential> {
  const verifier = encode(crypto.getRandomValues(new Uint8Array(32)))
  const state = encode(crypto.getRandomValues(new Uint8Array(32)))
  const challenge = encode(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))),
  )
  const redirect = chrome.identity.getRedirectURL("lichess")
  const client = "chess-tv-extension"
  const params = new URLSearchParams({
    response_type: "code",
    client_id: client,
    redirect_uri: redirect,
    code_challenge_method: "S256",
    code_challenge: challenge,
    state,
    scope: "board:play",
  })
  const result = await chrome.identity.launchWebAuthFlow({
    url: `https://lichess.org/oauth?${params}`,
    interactive: true,
  })
  if (!result) throw new Error("Lichess authorization cancelled.")
  const callback = new URL(result)
  if (
    callback.origin + callback.pathname !== redirect ||
    callback.searchParams.get("state") !== state ||
    !callback.searchParams.get("code")
  )
    throw new Error("Lichess authorization was not completed.")
  const response = await fetch("https://lichess.org/api/token", {
    method: "POST",
    redirect: "error",
    credentials: "omit",
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: callback.searchParams.get("code")!,
      code_verifier: verifier,
      redirect_uri: redirect,
      client_id: client,
    }),
    signal: AbortSignal.timeout(10000),
  })
  if (!response.ok) throw new Error("Cannot complete Lichess authorization. Try again.")
  const { access_token: token } = z
    .object({ access_token: z.string().min(1) })
    .parse(await response.json())
  const account = await fetch("https://lichess.org/api/account", {
    headers: { Authorization: `Bearer ${token}` },
    redirect: "error",
    credentials: "omit",
    signal: AbortSignal.timeout(10000),
  })
  if (!account.ok) throw new Error("Cannot read the authorized Lichess account.")
  const { id, username } = z
    .object({ id: z.string(), username: z.string() })
    .parse(await account.json())
  return { token, id, name: username }
}
