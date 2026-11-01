import { useState } from "react"

import type { BotReply } from "./chesscom-move"
import { Button } from "./ui/button"
import { Input } from "./ui/input"

export function ChessComPopup() {
  const [state, setState] = useState<BotReply>({
    message: "Open your bot game, then inspect its position.",
  })
  const [binding, setBinding] = useState<{ tabId: number; token: string }>()
  const [color, setColor] = useState("white")
  const [from, setFrom] = useState("")
  const [to, setTo] = useState("")
  const [busy, setBusy] = useState(false)
  async function act(move: boolean) {
    setBusy(true)
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true })
      if (!tab?.id || !tab.url?.startsWith("https://www.chess.com/play/computer/"))
        throw new Error("Select a Chess.com bot-game tab.")
      if (move && (!binding || binding.tabId !== tab.id)) throw new Error("Inspect this tab first.")
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] })
      const reply = (await chrome.tabs.sendMessage(
        tab.id,
        move
          ? {
              kind: "bot-move",
              id: crypto.randomUUID(),
              token: binding!.token,
              from: from.toLowerCase(),
              to: to.toLowerCase(),
              color,
            }
          : { kind: "bot-inspect" },
        { frameId: 0 },
      )) as BotReply
      setState(reply)
      setBinding(reply.token ? { tabId: tab.id, token: reply.token } : undefined)
    } catch (e) {
      setBinding(undefined)
      setState({ message: e instanceof Error ? e.message : "Could not reach the game." })
    } finally {
      setBusy(false)
    }
  }
  return (
    <main className="w-[360px] space-y-4 bg-stone-50 p-5 text-stone-900">
      <h1 className="text-xl font-semibold">Chess TV</h1>
      <p className="text-sm">
        Enter your own move. Moves target your Chess.com bot game. Live move execution is still
        being verified.
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
        disabled={busy}
        onClick={() => void act(false)}
      >
        Inspect position
      </Button>
      <label className="block">
        From
        <Input
          value={from}
          placeholder="e4"
          maxLength={2}
          onChange={(e) => setFrom(e.target.value)}
        />
      </label>
      <label className="block">
        To
        <Input
          value={to}
          placeholder="e5"
          maxLength={2}
          onChange={(e) => setTo(e.target.value)}
        />
      </label>
      <Button
        disabled={busy || !binding || !/^[a-h][1-8]$/i.test(from) || !/^[a-h][1-8]$/i.test(to)}
        onClick={() => void act(true)}
      >
        {busy ? "Checking…" : "Play move"}
      </Button>
      <p
        role="status"
        className="text-sm"
      >
        {state.message}
      </p>
      <p className="text-xs">
        Requires recorded move history. Promotion, castling and TV relay control are not supported
        yet.
      </p>
    </main>
  )
}
