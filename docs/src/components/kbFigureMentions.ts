// Mentions of a paper's figures and tables in running text ("Fig. 3", "Figs. 2 and 4", "Table II"),
// as figures.jl's `FIGURE_MENTION` finds them: a figure's number in digits (with a panel letter), a
// table's in digits or Roman numerals, several joined by commas, "and", "&" or "or".

export const MENTION = /\b([Ff]ig(?:ure)?s?|FIG(?:URE)?S?|[Tt]ab(?:le)?s?|TABLES?)\.?\s*((?:\d+[a-z]?|[IVXLC]+)\b(?:\s*(?:,|and|&|or)\s*(?:\d+[a-z]?|[IVXLC]+)\b)*)/g

const ROMAN: Record<string, number> = { I: 1, V: 5, X: 10, L: 50, C: 100 }

/** A figure or table's number, from its digits or Roman numerals; null for neither. */
export function numeral(s: string): number | null {
  if (/^\d+/.test(s)) return parseInt(s)
  if (!/^[IVXLC]+$/.test(s)) return null
  const v = [...s].map(c => ROMAN[c])
  return v.reduce((t, x, i) => t + (i + 1 < v.length && x < v[i + 1] ? -x : x), 0)
}

/** A figure's key, as `find` is asked for it: its kind and number ("figure:3", "table:2"). */
export const figureKey = (kind: string, n: number | null) => `${kind}:${n}`

export type Piece = { text: string; key?: string }

/**
 * `text` in pieces: plain text, and each mention's numbers as pieces with the `key` of a figure or
 * table, where `has(key)` says the paper has it. The first number of a mention takes its word with it
 * ("Figs. 2", then "4"); a number the paper has no figure for stays text.
 */
export function mentionPieces(text: string, has: (key: string) => boolean): Piece[] {
  const out: Piece[] = []
  const plain = (s: string) => { if (s) out.length && out.at(-1)!.key === undefined ? (out.at(-1)!.text += s) : out.push({ text: s }) }
  let last = 0
  for (const m of text.matchAll(MENTION)) {
    plain(text.slice(last, m.index))
    const whole = m[0], kind = m[1][0].toLowerCase() === 'f' ? 'figure' : 'table'
    const off = whole.length - m[2].length
    let pos = 0
    for (const n of m[2].matchAll(/\d+[a-z]?|[IVXLC]+/g)) {
      const start = off + n.index!, end = start + n[0].length
      if (pos > 0) plain(whole.slice(pos, start))
      const key = kind === 'figure' && !/^\d/.test(n[0]) ? undefined : figureKey(kind, numeral(n[0]))
      const piece = whole.slice(pos === 0 ? 0 : start, end)
      key !== undefined && has(key) ? out.push({ text: piece, key }) : plain(piece)
      pos = end
    }
    plain(whole.slice(pos))
    last = m.index! + whole.length
  }
  plain(text.slice(last))
  return out
}
