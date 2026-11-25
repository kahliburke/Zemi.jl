// The rule Zemi reads a note's citations by (`NOTE_CITATION` and `CITE_ITEM` in obsidian.jl): a bracket
// holding `@key`, several separated by `;`, each with words before or a locator after; not a link's text.
const CITATION = /\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()/g
const ITEM = /^(\s*(?:.*?[\s-])?)(-?)@([\p{L}\p{N}_](?:[\p{L}\p{N}_:.#$%&+?<>~/-]*[\p{L}\p{N}_])?)(.*)$/su

/** Where `text` cites: each `@key` (from its `@` to the key's end) and the key. */
export function citations(text: string): { from: number; to: number; key: string }[] {
  const out: { from: number; to: number; key: string }[] = []
  for (const m of text.matchAll(CITATION)) {
    let at = m.index! + 1
    for (const item of m[1].split(';')) {
      const i = item.match(ITEM)
      if (i) {
        const from = at + i[1].length + i[2].length
        out.push({ from, to: from + 1 + i[3].length, key: i[3] })
      }
      at += item.length + 1
    }
  }
  return out
}

