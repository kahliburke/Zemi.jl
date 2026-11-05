// Markdown as the editor reads it (see KBEditor.vue): the renderer's math (kbMarkdown.ts), `$…$`
// inline and `$$…$$` displayed, as nodes of their own, so the LaTeX inside can be highlighted.
import { parser, type MarkdownConfig, type InlineContext } from '@lezer/markdown'
import { tags } from '@lezer/highlight'

const DOLLAR = 36, BACKSLASH = 92, SPACE = 32, NEWLINE = 10

export const mathTags = { math: tags.special(tags.content), mark: tags.processingInstruction }

// `$x$` (not `$ x$`, nor `$5 and $6`: no space just inside a single dollar, as the renderer has it),
// and `$$…$$`, which may span the lines of a paragraph.
export const mathSyntax: MarkdownConfig = {
  defineNodes: [{ name: 'Math', style: mathTags.math }, { name: 'MathMark', style: mathTags.mark }],
  parseInline: [{
    name: 'Math',
    before: 'Escape',
    parse(cx: InlineContext, next: number, pos: number) {
      if (next !== DOLLAR || (pos > cx.offset && cx.char(pos - 1) === BACKSLASH)) return -1
      const display = cx.char(pos + 1) === DOLLAR
      const open = display ? 2 : 1
      if (!display && (cx.char(pos + 1) === SPACE || cx.char(pos + 1) === NEWLINE)) return -1
      for (let i = pos + open; i < cx.end; i++) {
        const c = cx.char(i)
        if (c === BACKSLASH) { i++; continue }
        if (!display && c === NEWLINE && cx.char(i + 1) === NEWLINE) return -1
        if (c !== DOLLAR || (display && cx.char(i + 1) !== DOLLAR)) continue
        if (i === pos + open || (!display && cx.char(i - 1) === SPACE)) return -1
        return cx.addElement(cx.elt('Math', pos, i + open, [cx.elt('MathMark', pos, pos + open), cx.elt('MathMark', i, i + open)]))
      }
      return -1
    },
  }],
}

// Markdown with it, to read a text's structure outside the editor.
export const markdownParser = parser.configure([mathSyntax])

// What `@` and the words after it, up to the caret, ask the reference picker for (see kbRefs.ts):
// where the `@` is and the query, or null when the text before the caret is not a reference being typed.
export function referenceQuery(before: string): { at: number; q: string } | null {
  const m = before.match(/(?:^|[\s(])@([^\n@[\]()]{0,40})$/)
  return m ? { at: before.length - m[1].length - 1, q: m[1] } : null
}

// Markdown marks around the selection, or taken off when it already has them: `**bold**`, `*italic*`, `` `code` ``.
export function toggleMark(text: string, from: number, to: number, mark: string): { text: string; from: number; to: number } {
  const n = mark.length
  if (text.slice(from - n, from) === mark && text.slice(to, to + n) === mark)
    return { text: text.slice(0, from - n) + text.slice(from, to) + text.slice(to + n), from: from - n, to: to - n }
  return { text: text.slice(0, from) + mark + text.slice(from, to) + mark + text.slice(to), from: from + n, to: to + n }
}
