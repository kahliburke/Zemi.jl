// The rule Zemi reads a note's citations by (`NOTE_CITATION` and `CITE_ITEM` in obsidian.jl): a bracket
// holding `@key`, several separated by `;`, each with words before or a locator after; not a link's text.
const CITATION = /\[([^\[\]\n]*@[^\[\]\n]*)\](?!\()/g
const ITEM = /^(\s*(?:.*?[\s-])?)(-?)@([\p{L}\p{N}_](?:[\p{L}\p{N}_:.#$%&+?<>~/-]*[\p{L}\p{N}_])?)(.*)$/su

/** One part of a citation, `see @key, p. 2`: its words before and after the key, the key, and where
 *  `@key` is (from its `@`); a part naming no key has only `before`, its text. */
export type CiteItem = { before: string; key: string | null; after: string; from: number; to: number }

/** A citation, `[see @a, p. 2; @b]`: where it is, its brackets included, and its parts. */
export type Citation = { from: number; to: number; items: CiteItem[] }

/** The citations in `text`. */
export function citationGroups(text: string): Citation[] {
  const out: Citation[] = []
  for (const m of text.matchAll(CITATION)) {
    let at = m.index! + 1
    const items: CiteItem[] = []
    for (const item of m[1].split(';')) {
      const i = item.match(ITEM)
      if (i) {
        const from = at + i[1].length + i[2].length
        items.push({ before: i[1].trimStart(), key: i[3], after: i[4].trimEnd(), from, to: from + 1 + i[3].length })
      } else items.push({ before: item.trim(), key: null, after: '', from: at, to: at })
      at += item.length + 1
    }
    if (items.some(i => i.key)) out.push({ from: m.index!, to: m.index! + m[0].length, items })
  }
  return out
}

/** Where `text` cites: each `@key` (from its `@` to the key's end) and the key. */
export function citations(text: string): { from: number; to: number; key: string }[] {
  return citationGroups(text).flatMap(g => g.items.filter(i => i.key).map(i => ({ from: i.from, to: i.to, key: i.key! })))
}
