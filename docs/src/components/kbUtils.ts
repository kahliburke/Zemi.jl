// Small helpers the components share: text as HTML, headings' anchors, code as Markdown, copies to edit.

/** Text as HTML text, quotes too, so it can stand in an attribute. */
export const escapeHtml = (s: string) =>
  s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!))

/** A search's snippet as HTML: its text escaped, the words it matched (between \x01 and \x02) marked. */
export const markedSnippet = (s: string) => escapeHtml(s).replace(/\x01/g, '<mark>').replace(/\x02/g, '</mark>')

/** Markdown as one line of plain text, for a line or two in a list: its marks dropped, list items as `·`. */
export const plainLine = (s: string) => s.replace(/\*\*|`/g, '').replace(/^\s*[-*]\s+/gm, '· ').replace(/\s*\n\s*/g, ' ')

/** A heading's words as an anchor (`Cited by` gives `cited-by`), or '' for a heading without any. */
export const anchorOf = (text: string) =>
  text.toLowerCase().replace(/<[^>]*>/g, '').replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '')

/** Anchors kept apart: one already `taken` (or given before) has `-2`, `-3`, … added. */
export function anchors(taken: Iterable<string> = []) {
  const seen = new Set(taken)
  return (base: string) => {
    let id = base
    for (let n = 2; seen.has(id); n++) id = `${base}-${n}`
    seen.add(id)
    return id
  }
}

/** Code as a fenced Markdown block, its fence longer than any run of backticks in it. */
export function fenced(code: string, language = '') {
  const fence = '`'.repeat(Math.max(3, ...[...code.matchAll(/`+/g)].map(m => m[0].length + 1)))
  return `${fence}${language}\n${code}\n${fence}`
}

/** A plain copy of a value, to edit apart from it (structuredClone cannot copy Vue's reactive objects). */
export const plainCopy = <T>(v: T): T => JSON.parse(JSON.stringify(v))

/**
 * Put `text` on the clipboard. Where the page is not served securely (an address on a network, over
 * http) the browser has no clipboard API, and a selected field is copied instead.
 */
export async function copyText(text: string): Promise<void> {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text)
  const field = document.createElement('textarea')
  field.value = text
  field.setAttribute('readonly', '')
  field.style.position = 'fixed'; field.style.opacity = '0'
  document.body.appendChild(field)
  field.select()
  try { if (!document.execCommand('copy')) throw new Error('The browser would not copy.') } finally { field.remove() }
}
