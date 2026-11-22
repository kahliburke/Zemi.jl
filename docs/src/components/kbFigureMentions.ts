// Mentions of a paper's figures and tables in running text ("Fig. 3", "Figs. 2 and 4", "Table II",
// "Fig. S2", "Supplementary Figure 1", "sheets S1 and S2"), as figures.jl's `FIGURE_MENTION` finds
// them: a figure's number in digits (with a panel letter), a table's in digits or Roman numerals, a
// number of a series of its own with that series' letter, several joined by commas, "and", "&" or "or".

export const MENTION = /\b((?:[Ss]upplement(?:ary|al)|SUPPLEMENT(?:ARY|AL)|[Ee]xtended\s+[Dd]ata|EXTENDED\s+DATA)\s+)?([Ff]ig(?:ure)?s?|FIG(?:URE)?S?|[Tt]ab(?:le)?s?|TABLES?|(?:[Pp]late|[Ss]heet|[Mm]ap|[Dd]rawing|[Ss]cheme|[Cc]hart|[Ee]xhibit)s?)\.?\s*((?:[A-Z]{0,2}\d+[a-z]?|[IVXLC]+)\b(?:\s*(?:,|and|&|or)\s*(?:[A-Z]{0,2}\d+[a-z]?|[IVXLC]+)\b)*)/g

const ROMAN: Record<string, number> = { I: 1, V: 5, X: 10, L: 50, C: 100 }

/** A figure or table's number, from its digits or Roman numerals; null for neither. */
export function numeral(s: string): number | null {
  if (/^\d+/.test(s)) return parseInt(s)
  if (!/^[IVXLC]+$/.test(s)) return null
  const v = [...s].map(c => ROMAN[c])
  return v.reduce((t, x, i) => t + (i + 1 < v.length && x < v[i + 1] ? -x : x), 0)
}

/**
 * The series a mention's number is in, as figures.jl's `figure_series` spells it: "" for the paper's
 * own, or from what qualifies it, the word for a drawing, map or plate, and the letters before its
 * number ("s" for "Fig. S2", "sheet s" for "sheet S1").
 */
export function series(qualifier: string, other: string, letters: string): string {
  const q = qualifier.toLowerCase(), parts: string[] = []
  if (q.includes('supplement')) parts.push('supplementary')
  if (/extended\s+data/.test(q)) parts.push('extended data')
  if (other) parts.push(other.toLowerCase().replace(/s$/, ''))
  if (letters) parts.push(letters.toLowerCase())
  return parts.join(' ')
}

/** A figure's key, as the paper's figures carry it (see figures.jl's `figures_json`): "figure::3", "table::2", "figure:sheet s:1". */
export const figureKey = (kind: string, series: string, n: number | null) => `${kind}:${series}:${n}`

export type Piece = { text: string; key?: string }

/**
 * `text` in pieces: plain text, and each mention's numbers as pieces with the `key` of a figure or
 * table, where `has(key)` says the paper has it. The first number of a mention takes its words with it
 * ("Figs. 2", then "4"); a number the paper has no figure for stays text.
 */
export function mentionPieces(text: string, has: (key: string) => boolean): Piece[] {
  const out: Piece[] = []
  const plain = (s: string) => { if (s) out.length && out.at(-1)!.key === undefined ? (out.at(-1)!.text += s) : out.push({ text: s }) }
  let last = 0
  for (const m of text.matchAll(MENTION)) {
    plain(text.slice(last, m.index))
    const whole = m[0], word = m[2].toLowerCase()
    const kind = word[0] === 't' ? 'table' : 'figure', other = 'ft'.includes(word[0]) ? '' : word
    const off = whole.length - m[3].length
    let pos = 0
    for (const n of m[3].matchAll(/[A-Z]{0,2}\d+[a-z]?|[IVXLC]+/g)) {
      const [, letters, digits] = /^([A-Z]*)(\d*)/.exec(n[0])!
      const start = off + n.index!, end = start + n[0].length
      if (pos > 0) plain(whole.slice(pos, start))
      // Roman numerals name tables; a figure's number is in digits.
      const key = !digits && kind === 'figure' ? undefined
        : figureKey(kind, series(m[1] ?? '', other, digits ? letters : ''), digits ? parseInt(digits) : numeral(letters))
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
