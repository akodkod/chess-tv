import { useEffect, useState } from "react"

import { displayText } from "./display-text"
import type { PopupState } from "./messages"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

export function ChessComPopup() {
  const [state, setState] = useState<PopupState>()
  const [code, setCode] = useState("")
  const [debug, setDebug] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  useEffect(() => {
    let live = true
    const poll = () => {
      void chrome.runtime
        .sendMessage({ kind: "state" })
        .then((s) => {
          if (live) setState(s as PopupState)
        })
        .catch(() => {
          if (live) setError("Extension unavailable. Reload it and reopen this popup.")
        })
    }
    poll()
    const timer = setInterval(poll, 1000)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [])
  async function act(kind: string) {
    setBusy(true)
    setError(undefined)
    try {
      const action = kind === "pair" ? { kind, code } : { kind }
      setState((await chrome.runtime.sendMessage(action)) as PopupState)
    } catch (e) {
      setError(e instanceof Error ? e.message : "Connection failed.")
    } finally {
      setBusy(false)
    }
  }
  const problem = error ?? state?.error
  const summary = problem
    ? "Needs attention — see Debug."
    : !state
      ? "Connecting…"
      : !state.autoConnect && state.paired
        ? "Connection paused — see Debug."
        : !state.connected
          ? "Connecting to TV…"
          : !state.peerConnected
            ? "Waiting for TV…"
            : state.available
              ? "Connected to TV"
              : state.gameId
                ? "Game connected — see Debug for status."
                : "Open a game to play or watch on TV."
  return (
    <main className="w-[320px] space-y-5 bg-stone-50 p-5 text-stone-900">
      <header className="flex items-center justify-between gap-4">
        {debug ? (
          <h1 className="text-base font-semibold">Debug</h1>
        ) : !state || state.paired ? (
          <p
            role="status"
            className="flex items-center gap-2 text-sm text-stone-600"
          >
            {summary === "Connected to TV" && (
              <span
                aria-hidden="true"
                className="size-2 shrink-0 rounded-full bg-emerald-700"
              />
            )}
            {displayText(summary)}
          </p>
        ) : (
          <span />
        )}
        <Button
          variant="ghost"
          className="h-8 shrink-0 px-2 text-xs"
          aria-expanded={debug}
          aria-controls={debug || (state && !state.paired) ? "popup-content" : undefined}
          onClick={() => setDebug(!debug)}
        >
          {debug ? "Back" : "Debug"}
        </Button>
      </header>
      {(debug || (state && !state.paired)) && (
        <div
          id="popup-content"
          className="space-y-4"
        >
          {debug ? (
            <>
              <p
                role="status"
                className="text-sm break-words"
              >
                {displayText(problem ?? state?.status ?? "Connecting…")}
              </p>
              <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-xs">
                {[
                  [
                    "Pairing",
                    state?.paired
                      ? "Paired"
                      : state?.pairing
                        ? "Awaiting TV confirmation"
                        : "Not paired",
                  ],
                  ["Automatic", state?.autoConnect ? "On" : "Paused"],
                  ["Relay", state?.connected ? "Connected" : "Disconnected"],
                  ["TV", state?.peerConnected ? "Connected" : "Disconnected"],
                  ["Input", state?.available ? "Ready" : "Unavailable"],
                  ["Game", state?.gameId ?? "None"],
                  ["Server", state?.relay ?? "…"],
                ].map(([label, value]) => (
                  <div
                    key={label}
                    className="contents"
                  >
                    <dt className="text-stone-600">{label}</dt>
                    <dd className="min-w-0 break-all">{value}</dd>
                  </div>
                ))}
              </dl>
              <div className="flex flex-col gap-2">
                <Button
                  variant="outline"
                  disabled={busy || !state?.paired || !state.connected}
                  onClick={() => void act("attach")}
                >
                  {state?.gameId ? "Reconnect current game" : "Connect current game"}
                </Button>
                <Button
                  variant="outline"
                  disabled={busy || !state?.paired}
                  onClick={() => void act("reconnect")}
                >
                  Reconnect relay
                </Button>
                <Button
                  variant="outline"
                  disabled={busy || !state?.gameId}
                  onClick={() => void act("disconnect")}
                >
                  Disconnect game
                </Button>
                <Button
                  variant="ghost"
                  disabled={busy || !state?.paired}
                  onClick={() => void act("unpair")}
                >
                  Unpair TV
                </Button>
              </div>
              <p className="text-xs text-stone-600">
                After an interrupted move, inspect the board in Chrome before reconnecting.
                Disconnect pauses automatic connection.
              </p>
            </>
          ) : state && !state.paired ? (
            <>
              <p className="text-sm text-stone-600">Enter the code shown on your TV</p>
              <form
                className="space-y-3"
                onSubmit={(event) => {
                  event.preventDefault()
                  if (!busy && !state.pairing && /^\d{6}$/.test(code)) void act("pair")
                }}
              >
                <label className="block space-y-2 text-sm">
                  <span>TV code</span>
                  <Input
                    value={code}
                    inputMode="numeric"
                    autoComplete="off"
                    maxLength={6}
                    placeholder="123456"
                    disabled={busy || state.pairing}
                    onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                  />
                </label>
                <Button
                  className="w-full"
                  type="submit"
                  disabled={busy || !/^\d{6}$/.test(code) || state.pairing}
                >
                  {state.pairing ? "Confirm on your TV" : "Pair TV"}
                </Button>
              </form>
              {problem && (
                <p
                  role="status"
                  className="text-sm"
                >
                  Pairing needs attention — see Debug
                </p>
              )}
            </>
          ) : null}
        </div>
      )}
    </main>
  )
}
