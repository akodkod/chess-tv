import { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"

import type { PopupState } from "./messages"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

import "./styles.css"

function Popup() {
  const [state, setState] = useState<PopupState>()
  const [code, setCode] = useState("")
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  async function action(kind: string) {
    setBusy(true)
    setFailure(null)
    try {
      setState(
        (await chrome.runtime.sendMessage({
          kind,
          ...(kind === "pair" ? { code } : {}),
        })) as PopupState,
      )
    } catch {
      setFailure("The extension could not respond. Reopen it to retry.")
    } finally {
      setBusy(false)
    }
  }
  useEffect(() => {
    let mounted = true
    const refresh = () => {
      void chrome.runtime
        .sendMessage({ kind: "state" })
        .then((next: PopupState) => {
          if (mounted) setState(next)
        })
        .catch(() => {
          if (mounted) setFailure("Reopen the extension to reconnect.")
        })
    }
    refresh()
    const timer = setInterval(refresh, 1000)
    return () => {
      mounted = false
      clearInterval(timer)
    }
  }, [])
  return (
    <main className="w-[360px] bg-stone-50 p-5 text-stone-900">
      <header className="mb-5 flex items-center justify-between">
        <h1 className="text-xl font-semibold tracking-tight">Chess TV</h1>
        <span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-medium text-amber-900">
          Simulator only
        </span>
      </header>
      <p className="mb-5 text-sm leading-relaxed text-stone-600">
        Your game in Chrome. Your moves on TV.
      </p>
      {!state ? (
        <p role="status">Connecting…</p>
      ) : (
        <>
          <section
            className="mb-4 rounded-lg border border-stone-200 bg-white p-4"
            aria-label="Connection status"
          >
            <div className="mb-2 flex items-center gap-2">
              <span
                aria-hidden="true"
                className={`h-2 w-2 rounded-full ${state.available ? "bg-emerald-600" : "bg-stone-400"}`}
              />
              <strong className="text-sm">
                {state.paired
                  ? state.connected
                    ? state.peerConnected
                      ? "TV connected"
                      : "Waiting for TV"
                    : "Relay offline"
                  : state.pairing
                    ? "Waiting for confirmation"
                    : "Pair your TV"}
              </strong>
            </div>
            <p
              className="text-sm leading-relaxed text-stone-600"
              role="status"
            >
              {state.status}
            </p>
            {state.gameId && (
              <p
                className="mt-2 truncate font-mono text-xs text-stone-500"
                title={state.gameId}
              >
                Game {state.gameId}
              </p>
            )}
          </section>
          {!state.paired && !state.pairing && (
            <form
              className="mb-4 space-y-3"
              onSubmit={(e) => {
                e.preventDefault()
                void action("pair")
              }}
            >
              <label
                className="block text-sm font-medium"
                htmlFor="code"
              >
                Six-digit TV code
              </label>
              <Input
                id="code"
                inputMode="numeric"
                autoComplete="off"
                maxLength={6}
                value={code}
                placeholder="000000"
                className="text-center font-mono text-xl tracking-[0.35em]"
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              />
              <Button
                className="w-full"
                disabled={busy || code.length !== 6}
                type="submit"
              >
                Pair with TV
              </Button>
            </form>
          )}
          {state.paired && (
            <div className="space-y-2">
              {!state.connected && (
                <Button
                  variant="outline"
                  className="w-full"
                  disabled={busy}
                  onClick={() => void action("reconnect")}
                >
                  Reconnect relay
                </Button>
              )}
              <p className="text-xs text-stone-600">
                {state.autoConnect
                  ? "Automatically connects to the current simulator game."
                  : "Automatic connection is paused."}
              </p>
              <Button
                className="w-full"
                disabled={busy || !state.connected || !state.simulator}
                onClick={() => void action("attach")}
              >
                Connect this game
              </Button>
              {(state.gameId || state.autoConnect) && (
                <Button
                  variant="outline"
                  className="w-full"
                  disabled={busy}
                  onClick={() => void action("disconnect")}
                >
                  Disconnect
                </Button>
              )}
              <Button
                variant="ghost"
                className="w-full"
                disabled={busy}
                onClick={() => void action("unpair")}
              >
                Unpair
              </Button>
            </div>
          )}
        </>
      )}
      {(failure || state?.error) && (
        <p
          role="alert"
          className="mt-3 rounded-md bg-red-50 p-3 text-sm text-red-800"
        >
          {failure || state?.error}
        </p>
      )}
      <footer className="mt-5 border-t border-stone-200 pt-3 text-xs leading-relaxed text-stone-500">
        Chess.com is not supported yet. Keep the attached simulator visible in Chrome.
        <span
          className="mt-1 block truncate"
          title={state?.relay}
        >
          {state?.relay}
        </span>
      </footer>
    </main>
  )
}
createRoot(document.getElementById("root")!).render(<Popup />)
