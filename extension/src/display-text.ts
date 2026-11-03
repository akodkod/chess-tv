// Keep sentence punctuation in diagnostics; omit a lone sentence's final period in UI.
export function displayText(value: string): string {
  const text = value.trim()
  if (!text.endsWith(".")) return text
  const sentences = [...new Intl.Segmenter("en", { granularity: "sentence" }).segment(text)]
  return sentences.length === 1 ? text.slice(0, -1) : text
}
