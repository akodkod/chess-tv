import { messageSchema, type Message } from "@chess-tv/protocol"
import { Chess } from "chess.js"
import { JSDOM } from "jsdom"
import { afterEach, expect, it, vi } from "vite-plus/test"

import { ChessComAdapter } from "../src/chesscom-adapter"
import { readGame } from "../src/chesscom-game"

function fixture(moves: string[] = []) {
  const dom = new JSDOM(
    '<wc-chess-board id="board-play-computer"></wc-chess-board><wc-simple-move-list board-id="board-play-computer"></wc-simple-move-list>',
    { pretendToBeVisual: true, url: "https://www.chess.com/play/computer/Zach-BOT" },
  )
  const doc = dom.window.document
  const board = doc.querySelector<HTMLElement>("wc-chess-board")!
  const chess = new Chess()
  for (const san of moves) chess.move(san)
  const render = () => {
    board.innerHTML = chess
      .board()
      .flat()
      .filter((p) => p !== null)
      .map(
        (p) =>
          `<div class="piece ${p.color}${p.type} square-${p.square.charCodeAt(0) - 96}${p.square[1]}"></div>`,
      )
      .join("")
    const history = chess.history()
    doc.querySelector("wc-simple-move-list")!.innerHTML = history
      .map(
        (san, i) =>
          `<div class="main-line-row" data-whole-move-number="${Math.floor(i / 2) + 1}"><div class="main-line-ply ${i % 2 ? "black" : "white"}-move" data-node="0-${i}"><span class="node-highlight-content ${i === history.length - 1 ? "selected" : ""}">${san}</span></div></div>`,
      )
      .join("")
    for (const p of board.querySelectorAll<HTMLElement>(".piece")) {
      const square = [...p.classList].find((c) => c.startsWith("square-"))!
      p.getBoundingClientRect = () =>
        new dom.window.DOMRect(
          (Number(square[7]) - 1) * 100,
          (8 - Number(square[8])) * 100,
          100,
          100,
        )
    }
  }
  board.getBoundingClientRect = () => new dom.window.DOMRect(0, 0, 800, 800)
  doc.elementFromPoint = () => board
  for (const [name, value] of Object.entries({
    document: doc,
    window: dom.window,
    MutationObserver: dom.window.MutationObserver,
    MouseEvent: dom.window.MouseEvent,
    PointerEvent: dom.window.MouseEvent,
  }))
    vi.stubGlobal(name, value)
  render()
  return { doc, board, chess, render, adapter: new ChessComAdapter(doc) }
}
afterEach(() => vi.unstubAllGlobals())
async function sync(adapter: ChessComAdapter, color = "white") {
  await adapter.handle({ kind: "inspect", color })
  const reply = await adapter.handle({ kind: "sync", generation: "generation", enabled: true })
  expect(reply.error).toBeNull()
  reply.messages.forEach((m) => expect(messageSchema.safeParse(m).success).toBe(true))
  return reply.messages.find((m) => m.type === "snapshot") as Extract<Message, { type: "snapshot" }>
}
function command(snapshot: Extract<Message, { type: "snapshot" }>, from = "e2", to = "e4") {
  return {
    kind: "move",
    move: {
      v: 2,
      type: "move",
      gameId: snapshot.gameId,
      generation: snapshot.generation,
      revision: snapshot.revision,
      commandId: crypto.randomUUID(),
      from,
      to,
    },
  }
}
it("publishes a complete initial position with selected player color", async () => {
  const { adapter } = fixture()
  const s = await sync(adapter, "black")
  expect(s.playerColor).toBe("black")
  expect(s.turn).toBe("white")
  expect(s.board.filter(Boolean)).toHaveLength(32)
  expect(s.board[60]).toBe("K")
})
it("refuses a board that disagrees with recorded history", () => {
  const { doc } = fixture(["e4", "e5"])
  doc.querySelector(".wp.square-54")!.classList.replace("square-54", "square-56")
  expect(() => readGame(doc)).toThrow("agree")
})
it("rejects illegal and stale moves before dispatch without locking later input", async () => {
  const { adapter, board, chess, render } = fixture()
  const click = vi.fn()
  board.addEventListener("mousedown", click)
  const s = await sync(adapter)
  const illegal = await adapter.handle(command(s, "e2", "e5"))
  expect(illegal.messages).toContainEqual(
    expect.objectContaining({
      type: "outcome",
      outcome: "rejected",
      reason: expect.stringContaining("not legal"),
    }),
  )
  chess.move("d4")
  chess.move("d5")
  render()
  const stale = await adapter.handle(command(s))
  expect(stale.messages).toContainEqual(
    expect.objectContaining({
      type: "outcome",
      outcome: "rejected",
      reason: expect.stringContaining("changed"),
    }),
  )
  expect(click).not.toHaveBeenCalled()
  expect(stale.messages).toContainEqual(
    expect.objectContaining({ type: "status", available: true }),
  )
})
it("dispatches a TV move, confirms board/history evidence and deduplicates it", async () => {
  const { adapter, board, chess, render } = fixture()
  const s = await sync(adapter)
  const request = command(s)
  let clicks = 0
  board.addEventListener("click", () => {
    clicks++
    if (clicks === 2) {
      chess.move("e4")
      chess.move("e5")
      render()
    }
  })
  const reply = await adapter.handle(request)
  expect(reply.messages).toContainEqual(
    expect.objectContaining({ type: "outcome", outcome: "observed-complete" }),
  )
  expect((await adapter.handle(request)).messages).toContainEqual(
    expect.objectContaining({ type: "outcome", outcome: "observed-complete" }),
  )
  expect(clicks).toBe(2)
  expect(chess.history()).toEqual(["e4", "e5"])
})
it("changes game identity after a restart and rejects a command from the old game", async () => {
  const { adapter, chess, render } = fixture(["e4", "e5"])
  const s = await sync(adapter)
  chess.reset()
  render()
  const changed = await adapter.handle({ kind: "sync", generation: "generation", enabled: true })
  expect(changed.error).toMatch(/^Game changed/)
  expect(changed.gameId).not.toBe(s.gameId)
  const old = await adapter.handle(command(s))
  expect(old.messages).toContainEqual(
    expect.objectContaining({ type: "outcome", outcome: "rejected" }),
  )
})
it("reconstructs castling and en passant and recognizes checkmate", () => {
  let f = fixture(["e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6", "O-O"])
  expect(readGame(f.doc).pieces.get("g1")?.code).toBe("wk")
  f = fixture(["e4", "a6", "e5", "d5", "exd6"])
  expect(readGame(f.doc).pieces.has("d5")).toBe(false)
  f = fixture(["f3", "e5", "g4", "Qh4#"])
  expect(readGame(f.doc).result).toBe("black-won")
})

it("publishes Chess.com's recorded result and disables moves after resignation", async () => {
  const { doc, adapter } = fixture(["e4", "e5"])
  doc
    .querySelector("wc-simple-move-list")!
    .insertAdjacentHTML(
      "beforeend",
      '<div class="result-row"><span class="game-result">0-1 <div class="move-info-icon"></div></span></div>',
    )
  const s = await sync(adapter)
  expect(s.result).toBe("black-won")
  const reply = await adapter.handle(command(s))
  expect(reply.messages).toContainEqual(
    expect.objectContaining({ type: "outcome", outcome: "rejected" }),
  )
})

it("confirms a capture even when the bot immediately recaptures the moved piece", async () => {
  const { adapter, board, chess, render } = fixture(["e4", "d5"])
  const s = await sync(adapter)
  let clicks = 0
  board.addEventListener("click", () => {
    if (++clicks === 2) {
      chess.move("exd5")
      chess.move("Qxd5")
      render()
    }
  })
  const reply = await adapter.handle(command(s, "e4", "d5"))
  expect(reply.messages).toContainEqual(
    expect.objectContaining({ type: "outcome", outcome: "observed-complete" }),
  )
})

it("returns fresh snapshots when acknowledging an old duplicate command", async () => {
  const { adapter, board, chess, render } = fixture()
  const s = await sync(adapter)
  const request = command(s)
  let clicks = 0
  board.addEventListener("click", () => {
    if (++clicks === 2) {
      chess.move("e4")
      render()
    }
  })
  await adapter.handle(request)
  chess.move("e5")
  render()
  const reply = await adapter.handle(request)
  const current = reply.messages.find((m) => m.type === "snapshot")!
  expect(current.type === "snapshot" && current.turn).toBe("white")
  expect(clicks).toBe(2)
})

it("reads figurine notation without depending on the selected piece font", () => {
  const { doc } = fixture(["e4", "e5", "Nf3", "Nc6", "Bb5"])
  for (const [node, piece, dest] of [
    ["0-2", "N", "f3"],
    ["0-3", "N", "c6"],
    ["0-4", "B", "b5"],
  ]) {
    doc.querySelector(`[data-node="${node}"] .node-highlight-content`)!.innerHTML =
      `<span class="icon-font-chess" data-figurine="${piece}"></span> ${dest} `
  }
  expect(readGame(doc).history).toEqual(["e4", "e5", "Nf3", "Nc6", "Bb5"])
})

it.each(["q", "r", "b", "n"] as const)(
  "selects %s promotion and confirms the chosen piece",
  async (promotion) => {
    const { adapter, doc, board, chess, render } = fixture([
      "a4",
      "h5",
      "a5",
      "h4",
      "a6",
      "h3",
      "axb7",
      "hxg2",
    ])
    const s = await sync(adapter)
    const request = command(s, "b7", "a8")
    let clicks = 0
    board.addEventListener("click", () => {
      if (++clicks !== 2) return
      const menu = doc.createElement("div")
      menu.className = "promotion-window promotion-window--visible"
      const choice = doc.createElement("div")
      choice.className = `promotion-piece w${promotion}`
      choice.getBoundingClientRect = () => new window.DOMRect(0, 0, 100, 100)
      choice.addEventListener("mousedown", () => {
        chess.move({ from: "b7", to: "a8", promotion })
        render()
        doc.elementFromPoint = () => board
      })
      menu.append(choice)
      board.append(menu)
      doc.elementFromPoint = () => choice
    })
    const reply = await adapter.handle({ ...request, move: { ...request.move, promotion } })
    expect(reply.messages).toContainEqual(
      expect.objectContaining({ type: "outcome", outcome: "observed-complete" }),
    )
    expect(chess.get("a8")?.type).toBe(promotion)
  },
)

it("never resends an unconfirmed move and requires explicit recovery", async () => {
  vi.useFakeTimers()
  try {
    const { adapter, board } = fixture()
    const s = await sync(adapter)
    const request = command(s)
    const click = vi.fn()
    board.addEventListener("click", click)
    const pending = adapter.handle(request)
    await vi.advanceTimersByTimeAsync(5000)
    const reply = await pending
    expect(reply.messages).toContainEqual(
      expect.objectContaining({ type: "outcome", outcome: "uncertain" }),
    )
    await adapter.handle(request)
    expect(click).toHaveBeenCalledTimes(2)
    const next = await adapter.handle(command(s, "d2", "d4"))
    expect(next.messages).toContainEqual(
      expect.objectContaining({ type: "outcome", outcome: "rejected" }),
    )
    expect(next.messages).toContainEqual(
      expect.objectContaining({ type: "status", available: false }),
    )
    expect(click).toHaveBeenCalledTimes(2)
  } finally {
    vi.useRealTimers()
  }
})

it.each([false, true])(
  "reads player names and clocks with flipped=%s without changing position revision",
  async (flipped) => {
    const { doc, board, adapter } = fixture(["e4", "e5"])
    board.classList.toggle("flipped", flipped)
    const row = (top: boolean, name: string, clock: string) =>
      `<div class="player-row-component ${top ? "player-row-top" : ""}"><img class="cc-avatar-img" src="https://images.chesscomfiles.com/${name}.png"><div data-test-element="user-tagline-username">${name}</div><div class="move-time-content">${clock}</div></div>`
    doc.body.insertAdjacentHTML(
      "beforeend",
      row(true, flipped ? "Human" : "Zach", flipped ? "9:42" : "10:00") +
        row(false, flipped ? "Zach" : "Human", flipped ? "10:00" : "9:42"),
    )
    const s = await sync(adapter)
    expect(s.players).toEqual({
      white: "Human",
      black: "Zach",
      whiteAvatar: "https://images.chesscomfiles.com/Human.png",
      blackAvatar: "https://images.chesscomfiles.com/Zach.png",
    })
    expect(s.clocks.white).toEqual({ remainingMs: 582000, running: true })
    expect(s.clocks.black).toEqual({ remainingMs: 600000, running: false })
    for (const c of doc.querySelectorAll(".move-time-content")) c.textContent = "0:09.8"
    const next = await adapter.handle({ kind: "sync", generation: "generation", enabled: true })
    const updated = next.messages.find((m) => m.type === "snapshot") as Extract<
      Message,
      { type: "snapshot" }
    >
    expect(updated.revision).toBe(s.revision)
    expect(updated.clocks.white.remainingMs).toBe(9800)
  },
)

it("publishes legal destinations including special moves without duplicate promotions", async () => {
  const initial = await sync(fixture().adapter)
  expect(initial.legalMoves).toHaveLength(20)
  expect(initial.legalMoves).toContainEqual({ from: "e2", to: "e4" })
  expect(initial.checkSquare).toBeNull()
  const castle = await sync(fixture(["e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6"]).adapter)
  expect(castle.legalMoves).toContainEqual({ from: "e1", to: "g1" })
  const ep = await sync(fixture(["e4", "a6", "e5", "d5"]).adapter)
  expect(ep.legalMoves).toContainEqual({ from: "e5", to: "d6" })
  const promotion = await sync(
    fixture(["a4", "h5", "a5", "h4", "a6", "h3", "axb7", "hxg2"]).adapter,
  )
  expect(promotion.legalMoves.filter((m) => m.from === "b7" && m.to === "a8")).toEqual([
    { from: "b7", to: "a8" },
  ])
})

it("excludes pinned moves and identifies checks and checkmate for either king", async () => {
  const pinned = await sync(fixture(["e4", "e5", "Nf3", "Nc6", "Bb5", "d6", "d3"]).adapter)
  expect(pinned.legalMoves.some((m) => m.from === "c6")).toBe(false)
  const checked = await sync(fixture(["e4", "d6", "Bb5+"]).adapter)
  expect(checked.checkSquare).toBe("e8")
  expect(checked.legalMoves).toContainEqual({ from: "c7", to: "c6" })
  expect(checked.legalMoves).not.toContainEqual({ from: "a7", to: "a6" })
  const mate = await sync(fixture(["f3", "e5", "g4", "Qh4#"]).adapter)
  expect(mate.checkSquare).toBe("e1")
  expect(mate.legalMoves).toEqual([])
  expect(mate.result).toBe("black-won")
})
