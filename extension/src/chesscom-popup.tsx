import { useEffect, useState } from "react"

import type { PopupState } from "./messages"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

export function ChessComPopup() {
  const [state, setState] = useState<PopupState>()
  const [code, setCode] = useState("")
  const [color, setColor] = useState("white")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  useEffect(() => {
    let live = true
    void chrome.storage.local.get("playerColor").then((s) => {
      if (live && s.playerColor === "black") setColor("black")
    })
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
      const action =
        kind === "pair" ? { kind, code } : kind === "attach" ? { kind, color } : { kind }
      setState((await chrome.runtime.sendMessage(action)) as PopupState)
    } catch (e) {
      setError(e instanceof Error ? e.message : "Connection failed.")
    } finally {
      setBusy(false)
    }
  }
  return (
    <main className="w-[360px] space-y-4 bg-stone-50 p-5 text-stone-900">
      <h1 className="text-xl font-semibold">Chess TV</h1>
      {!state?.paired ? (
        <>
          <p className="text-sm">
            Open Chess TV on Apple TV and enter its six-digit code. Confirm the pairing on your TV.
          </p>
          <label className="block">
            TV code
            <Input
              value={code}
              maxLength={6}
              placeholder="123456"
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            />
          </label>
          <Button
            disabled={busy || !/^\d{6}$/.test(code) || state?.pairing}
            onClick={() => void act("pair")}
          >
            Pair TV
          </Button>
        </>
      ) : (
        <>
          <p className="text-sm">
            Start a Chess.com bot game, select your playing color, then connect it. Keep the game
            tab visible while playing on TV.
          </p>
          <label className="block">
            Your color{" "}
            <select
              value={color}
              onChange={(e) => setColor(e.target.value)}
            >
              <option value="white">White</option>
              <option value="black">Black</option>
            </select>
          </label>
          <Button
            disabled={busy || !state.connected}
            onClick={() => void act("attach")}
          >
            {state.gameId ? "Reconnect this game" : "Connect this game"}
          </Button>
          {state.gameId && (
            <p className="text-xs">
              If a move was interrupted, inspect the board in Chrome before reconnecting.
            </p>
          )}
          <div className="flex flex-wrap gap-2">
            <Button
              disabled={busy}
              onClick={() => void act("reconnect")}
            >
              Reconnect relay
            </Button>
            <Button
              disabled={busy || !state.gameId}
              onClick={() => void act("disconnect")}
            >
              Disconnect game
            </Button>
            <Button
              disabled={busy}
              onClick={() => void act("unpair")}
            >
              Unpair
            </Button>
          </div>
        </>
      )}
      <p
        role="status"
        className="text-sm"
      >
        {error ?? state?.error ?? state?.status ?? "Connecting…"}
      </p>
      <p className="text-xs break-all">Relay: {state?.relay ?? "…"}</p>
    </main>
  )
}
