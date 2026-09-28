import { observationSchema } from "../src/messages"
import { applyMove, fixture, squares, type Scenario } from "./fixtures"
let scenario: Scenario = "normal"
const params = new URLSearchParams(location.search)
let state = fixture(scenario, params.get("game") || crypto.randomUUID())
try {
  const saved = JSON.parse(sessionStorage.getItem("simulator") || "null") as {
    state: unknown
    scenario: Scenario
  } | null
  if (
    saved &&
    ["normal", "black", "castling", "en-passant", "promotion"].includes(saved.scenario)
  ) {
    const parsed = observationSchema.parse(saved.state)
    if (!params.get("game") || parsed.snapshot.gameId === params.get("game")) {
      state = parsed
      scenario = saved.scenario
    }
  }
} catch {
  /* Start a new fixture if local simulator state is unavailable. */
}
let source: string | null = null
let destination: string | null = null
let broken = false
let frozen = false
const node = <T extends HTMLElement>(id: string) => document.getElementById(id) as T
const glyph: Record<string, string> = {
  K: "♔",
  Q: "♕",
  R: "♖",
  B: "♗",
  N: "♘",
  P: "♙",
  k: "♚",
  q: "♛",
  r: "♜",
  b: "♝",
  n: "♞",
  p: "♟",
}
function publish() {
  sessionStorage.setItem("simulator", JSON.stringify({ state, scenario }))
  const current = new URL(location.href)
  if (current.searchParams.get("game") !== state.snapshot.gameId) {
    current.searchParams.set("game", state.snapshot.gameId)
    history.replaceState(null, "", current)
  }
  if (broken) {
    node("chess-tv-state").textContent = "unsupported"
    return
  }
  if (frozen) return
  state.updatedAt = Date.now()
  state.snapshot.clocks.observedAt = Date.now()
  node("chess-tv-state").textContent = JSON.stringify(state)
}
function render() {
  const board = node("board")
  board.replaceChildren()
  const order = state.snapshot.playerColor === "black" ? [...squares].reverse() : squares
  for (const square of order) {
    const i = squares.indexOf(square)
    const button = document.createElement("button")
    button.dataset.square = square
    button.className =
      (((i % 8) + Math.floor(i / 8)) % 2 ? "dark" : "light") +
      (source === square ? " selected" : "")
    button.textContent = glyph[state.snapshot.board[i] || ""] || ""
    button.setAttribute("aria-label", `${square} ${state.snapshot.board[i] || "empty"}`)
    button.addEventListener("click", () => select(square))
    board.append(button)
  }
  node("description").textContent =
    `${scenario} · ${state.snapshot.playerColor} orientation · ${state.snapshot.turn} to move · ${state.snapshot.result || "playing"}`
  publish()
}
function submit(promotion: "q" | "r" | "b" | "n" | null = null) {
  if (!source || !destination) return
  const from = source,
    to = destination
  source = destination = null
  node("promotions").hidden = true
  const delay = Number(node<HTMLSelectElement>("delay").value)
  if (delay === -1) {
    render()
    return
  }
  setTimeout(() => {
    state = applyMove(
      state,
      scenario,
      from,
      to,
      promotion,
      node<HTMLInputElement>("reject").checked,
    )
    render()
  }, delay)
}
function select(square: string) {
  if (!source) {
    source = square
    render()
    return
  }
  destination = square
  if (scenario === "promotion" && square === "a8") {
    node("promotions").hidden = false
    return
  }
  submit()
}
for (const button of document.querySelectorAll<HTMLButtonElement>("[data-promotion]"))
  button.onclick = () => submit(button.dataset.promotion as "q" | "r" | "b" | "n")
node<HTMLSelectElement>("scenario").onchange = () => {
  scenario = node<HTMLSelectElement>("scenario").value as Scenario
  state = fixture(scenario, crypto.randomUUID())
  source = destination = null
  render()
}
node("new-game").onclick = () => {
  state = fixture(scenario, crypto.randomUUID())
  source = destination = null
  render()
}
node("result").onclick = () => {
  state.snapshot.result = "draw"
  state.snapshot.clocks.white.running = state.snapshot.clocks.black.running = false
  render()
}
node("broken").onclick = () => {
  broken = !broken
  publish()
}
node("frozen").onclick = () => {
  frozen = !frozen
  publish()
}
let previous = performance.now()
setInterval(() => {
  const now = performance.now(),
    elapsed = now - previous
  previous = now
  for (const color of ["white", "black"] as const) {
    const clock = state.snapshot.clocks[color]
    if (!frozen && clock.running && clock.remainingMs !== null)
      clock.remainingMs = Math.max(0, clock.remainingMs - elapsed)
  }
  publish()
}, 500)
render()
