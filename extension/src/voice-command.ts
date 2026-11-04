import type { Chess, Move } from "chess.js"

const pieces: Record<string, string> = {
  pawn: "p",
  knight: "n",
  bishop: "b",
  rook: "r",
  queen: "q",
  king: "k",
}

class VoiceAmbiguityError extends Error {}
class VoiceIllegalError extends Error {}

// Deliberately a grammar, not fuzzy intent inference. Every word must be consumed.
export function resolveVoiceMove(chess: Chess, transcript: string): Move | null {
  let text = transcript
    .toLowerCase()
    .replace(/[.,!?]/g, " ")
    .trim()
  text = text
    .replace(/\bnight\b/g, "knight")
    .replace(/\bpon\b/g, "pawn")
    .replace(/\bkind side\b/g, "king side")
    .replace(/\bkingside\b/g, "king side")
    .replace(/\bqueenside\b/g, "queen side")
  const numbers: Record<string, string> = {
    one: "1",
    two: "2",
    three: "3",
    four: "4",
    five: "5",
    six: "6",
    seven: "7",
    eight: "8",
  }
  // Letter names are aliases only when immediately followed by a square rank.
  const files: Record<string, string> = {
    ay: "a",
    bee: "b",
    be: "b",
    cee: "c",
    see: "c",
    sea: "c",
    dee: "d",
    gee: "g",
    aitch: "h",
    haitch: "h",
  }
  text = text.replace(
    /\b(ay|bee|be|cee|see|sea|dee|gee|aitch|haitch)\s+(?=one\b|two\b|three\b|four\b|five\b|six\b|seven\b|eight\b|too\b|for\b|ate\b|[1-8]\b)/g,
    (_, file: string) => files[file]! + " ",
  )
  // Only normalize number homophones in square context, never globally ("to" is grammar).
  text = text
    .replace(
      /\b([a-h])\s*(one|two|three|four|five|six|seven|eight|too|for|ate|[1-8])\b/g,
      (_, file: string, rank: string) =>
        file + (numbers[rank] ?? { too: "2", for: "4", ate: "8" }[rank] ?? rank),
    )
    .replace(/\s+/g, " ")
  // A recognizer can retain a repeated destination before the actual command.
  // Consume only one square fragment, and require it to agree with the move.
  const fragment = /^([a-h][1-8]) (move\b.*)$/.exec(text)
  const repeatedSquare = fragment?.[1]
  if (fragment) text = fragment[2]!
  if (/^[a-h][1-8]$/.test(text)) text = `move ${text}`
  if (/^(pawn|knight|bishop|rook|queen|king)\b/.test(text)) text = `move ${text}`
  if (!/^(move|castle)\b/.test(text)) return null
  if ((text.match(/\b(move|castle)\b/g) ?? []).length > 1)
    throw new VoiceAmbiguityError("Repeat one move command.")
  const legal = chess.moves({ verbose: true })
  const castle = /^castle (king|queen) side$/.exec(text)
  let matches: Move[]
  if (castle) {
    matches = legal.filter((m) => m.flags.includes(castle[1] === "king" ? "k" : "q"))
  } else {
    const match =
      /^move (.+?)(?: (?:promote to|promote|promotion to|equals) (queen|rook|bishop|knight))?$/.exec(
        text,
      )
    if (!match)
      throw new Error("Say Rook D4, Knight F3, Pawn D4, or castle king side / queen side.")
    const tokens = match[1]!.split(" ").filter((t) => t !== "the" && t !== "from")
    const destination = tokens.pop()
    if (!destination || !/^[a-h][1-8]$/.test(destination))
      throw new Error("Name a destination square, for example Knight F3.")
    if (repeatedSquare && repeatedSquare !== destination)
      throw new VoiceAmbiguityError("Heard different destination squares. Repeat one move command.")
    let piece: string | undefined
    let source: string | undefined
    let capture = false
    for (const token of tokens) {
      if (token === "to") continue
      if (token === "takes" || token === "capture" || token === "captures") {
        if (capture) throw new VoiceAmbiguityError("Repeat one move command.")
        capture = true
      } else if (pieces[token] && !piece) piece = pieces[token]
      else if (/^(?:[a-h][1-8]|[a-h]|[1-8])$/.test(token) && !source) source = token
      else throw new Error("Command not understood. Name the piece and destination square.")
    }
    if (!piece) throw new VoiceAmbiguityError("Name the piece, for example Pawn D4 or Knight F3.")
    matches = legal.filter(
      (m) =>
        m.to === destination &&
        m.piece === piece &&
        (!source || (source.length === 2 ? m.from === source : m.from.includes(source))) &&
        (!capture || m.isCapture() || m.isEnPassant()),
    )
    const promotion = match[2] ? pieces[match[2]] : undefined
    if (!promotion && matches.some((m) => m.promotion))
      throw new VoiceAmbiguityError("Name the promotion piece: queen, rook, bishop, or knight.")
    matches = matches.filter((m) => m.promotion === promotion)
  }
  if (matches.length === 0) throw new VoiceIllegalError("That move is not legal in this position.")
  if (matches.length !== 1)
    throw new VoiceAmbiguityError(
      "More than one piece can move there. Name its starting square, for example Rook from B1 to B4.",
    )
  return matches[0]!
}

// Resolve every candidate against the same board before dispatching anything.
export function resolveVoiceAlternatives(chess: Chess, transcripts: string[]): Move | null {
  const matches = new Map<string, Move>()
  let failure: unknown
  for (const text of new Set(transcripts)) {
    try {
      const move = resolveVoiceMove(chess, text)
      if (move) matches.set(move.lan, move)
    } catch (error) {
      if (error instanceof VoiceAmbiguityError || error instanceof VoiceIllegalError) throw error
      failure ??= error
    }
  }
  if (matches.size > 1)
    throw new VoiceAmbiguityError(
      "Speech could mean different moves. Repeat with the starting and destination squares.",
    )
  if (matches.size === 1) return matches.values().next().value!
  if (failure) throw failure
  return null
}

export type VoiceCandidate = { id: string; description: string }
export type VoiceResolution = {
  state: "resolved" | "fallback" | "rejected"
  move?: string
  reason?: string
}

export function voiceCandidates(chess: Chess): VoiceCandidate[] {
  return chess.moves({ verbose: true }).map((m) => ({
    id: m.lan,
    description: `${Object.keys(pieces).find((name) => pieces[name] === m.piece)} from ${m.from} to ${m.to}; ${m.san}${m.promotion ? `; promote to ${Object.keys(pieces).find((name) => pieces[name] === m.promotion)}` : ""}`,
  }))
}

export function prepareVoiceMove(chess: Chess, transcripts: string[]): VoiceResolution {
  // Explicit negation and multiple instructions must never reach the AI fallback.
  if (
    transcripts.some(
      (text) =>
        /\b(don['’]?t|do not|not|never|cancel|instead|then|and)\b/i.test(text) ||
        (text.match(/\b(move|castle)\b/gi) ?? []).length > 1,
    )
  )
    return { state: "rejected", reason: "Repeat one affirmative move command." }
  try {
    const move = resolveVoiceAlternatives(chess, transcripts)
    return move ? { state: "resolved", move: move.lan } : { state: "fallback" }
  } catch (error) {
    return {
      state:
        error instanceof VoiceAmbiguityError || error instanceof VoiceIllegalError
          ? "rejected"
          : "fallback",
      reason: error instanceof Error ? error.message : "Command not understood.",
    }
  }
}
