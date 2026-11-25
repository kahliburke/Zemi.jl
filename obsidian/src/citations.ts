// A note's citations (`[@key]`, as Pandoc writes them and Zemi reads them) shown by the titles of the
// documents they name, linked to their pages: in reading view by a post-processor, in live preview by
// a widget in their place, and in source mode by marks that open the document on Cmd/Ctrl-click and
// show it on hover. The note's text is left as it is.
import { syntaxTree } from '@codemirror/language'
import { RangeSetBuilder, StateEffect } from '@codemirror/state'
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType, hoverTooltip } from '@codemirror/view'
import { editorLivePreviewField, type MarkdownPostProcessorContext } from 'obsidian'
import type { Zemi } from './zemi'
import { type Citation, citationGroups, citations } from './cite_rule'

/** A document a key names, as `/api/cited` gives it. */
export type Cited = { id: string; kind: string; title: string; authors: string[]; year: string; label: string; page: string }

const AGAIN_MS = 60_000        // how long a key naming nothing is taken to name nothing: it may be read soon

/** The documents keys name, asked of the knowledge base in batches and kept. */
export class CitedKeys {
  private known = new Map<string, { doc: Cited | null; at: number }>()

  constructor(private zemi: Zemi) {}

  clear() { this.known.clear() }

  get(key: string): Cited | null | undefined {
    const k = this.known.get(key)
    return k && (k.doc || Date.now() - k.at < AGAIN_MS) ? k.doc : undefined
  }

  /** The documents `keys` name, asking only for those not known. */
  async resolve(keys: string[]): Promise<Map<string, Cited | null>> {
    const asked = [...new Set(keys)].filter(k => this.get(k) === undefined)
    for (let i = 0; i < asked.length; i += 100) {
      const part = asked.slice(i, i + 100)
      const got = (await this.zemi.get(`/api/cited?keys=${part.map(encodeURIComponent).join(',')}`)) ?? {}
      for (const k of part) this.known.set(k, { doc: got[k] ?? null, at: Date.now() })
    }
    return new Map(keys.map(k => [k, this.get(k) ?? null]))
  }
}

/** How a document cited is described on hover: its title, then its authors and year. */
export function describe(d: Cited): string {
  const by = d.authors.slice(0, 3).join(', ') + (d.authors.length > 3 ? ' et al.' : '')
  return [d.title, [by, d.year].filter(Boolean).join(', ')].filter(Boolean).join('\n')
}

// ── A citation shown ──────────────────────────────────────────────────────────────────────────────

/** Citation `g` as it reads, into `el`: in parentheses, each document it names by its title, linked to
 *  its page, keeping the words around it (`(see Tidal mixing, p. 2)`); a key naming nothing as written. */
export function renderCitation(el: HTMLElement, g: Citation, docs: (key: string) => Cited | null | undefined) {
  const box = el.createSpan({ cls: 'zemi-citation' })
  box.appendText('(')
  g.items.forEach((item, i) => {
    if (i) box.appendText('; ')
    box.appendText(item.before)
    const d = item.key ? docs(item.key) : null
    if (d) {
      const a = box.createEl('a', { text: d.title, href: d.page, cls: 'zemi-cite external-link' })
      a.setAttr('aria-label', describe(d) + `\n@${item.key}`)
      a.setAttr('target', '_blank')
      a.setAttr('rel', 'noopener')
    } else if (item.key) box.appendText('@' + item.key)
    box.appendText(item.after)
  })
  box.appendText(')')
  return box
}

const names = (g: Citation, docs: (key: string) => Cited | null | undefined) => g.items.some(i => i.key && docs(i.key))

// ── Reading view ──────────────────────────────────────────────────────────────────────────────────

const SKIPPED = 'a, code, pre, .math'

/** Show the citations in rendered `el` by the titles of what they cite, linked to their pages in Zemi. */
export async function linkCitations(el: HTMLElement, _ctx: MarkdownPostProcessorContext, keys: CitedKeys) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  const found: { node: Text; groups: Citation[] }[] = []
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n as Text
    if (!t.data.includes('@') || t.parentElement?.closest(SKIPPED)) continue
    const groups = citationGroups(t.data)
    if (groups.length) found.push({ node: t, groups })
  }
  if (!found.length) return
  try { await keys.resolve(found.flatMap(f => f.groups.flatMap(g => g.items.flatMap(i => i.key ? [i.key] : [])))) } catch { return }
  const docs = (k: string) => keys.get(k)
  for (const { node, groups } of found) {
    const text = node.data
    const shown = groups.filter(g => names(g, docs))
    if (!shown.length) continue
    const holder = createSpan()
    let at = 0
    for (const g of shown) {
      holder.appendText(text.slice(at, g.from))
      renderCitation(holder, g, docs)
      at = g.to
    }
    holder.appendText(text.slice(at))
    node.replaceWith(...Array.from(holder.childNodes))
  }
}

// ── The editor ────────────────────────────────────────────────────────────────────────────────────

const resolved = StateEffect.define<null>()

// Inside code, a citation is text: Obsidian's Markdown names its code nodes so.
function inCode(view: EditorView, pos: number) {
  const name = syntaxTree(view.state).resolveInner(pos, 1).name
  return /code|math/i.test(name)
}

/** The citations of the visible text, outside code. */
function visibleCitations(view: EditorView): Citation[] {
  const out: Citation[] = []
  for (const { from, to } of view.visibleRanges) {
    for (const g of citationGroups(view.state.sliceDoc(from, to))) {
      if (inCode(view, from + g.from)) continue
      out.push({ from: from + g.from, to: from + g.to, items: g.items.map(i => ({ ...i, from: from + i.from, to: from + i.to })) })
    }
  }
  return out
}

/** A citation in live preview, shown as it reads (see `renderCitation`): its titles open their pages,
 *  and a click elsewhere on it puts the cursor in, showing it as written. */
class CitationWidget extends WidgetType {
  constructor(private g: Citation, private docs: Map<string, Cited | null>) { super() }
  eq(other: CitationWidget) {
    return other.g.from === this.g.from && other.g.to === this.g.to && JSON.stringify(other.g.items.map(i => [i.before, i.key, i.after, i.key && other.docs.get(i.key)?.id])) ===
      JSON.stringify(this.g.items.map(i => [i.before, i.key, i.after, i.key && this.docs.get(i.key)?.id]))
  }
  toDOM() {
    const holder = createSpan()
    const box = renderCitation(holder, this.g, k => this.docs.get(k))
    box.querySelectorAll('a').forEach(a => a.addEventListener('click', e => { e.preventDefault(); window.open(a.href) }))
    return box
  }
  ignoreEvent(e: Event) { return (e.target as HTMLElement).closest?.('a') != null }
}

/** Shows the citations in the editor: in live preview by the titles of what they cite, except where
 *  the cursor is; in source mode with their keys marked, Cmd/Ctrl-click opening a document's page and
 *  hover showing it. */
export function citationExtension(keys: CitedKeys) {
  const marks = ViewPlugin.fromClass(class {
    decorations: DecorationSet = Decoration.none
    constructor(private view: EditorView) { this.build() }

    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.selectionSet || u.transactions.some(t => t.effects.some(e => e.is(resolved)))) this.build()
    }

    private build() {
      const view = this.view
      const groups = visibleCitations(view)
      const unknown = groups.flatMap(g => g.items.flatMap(i => i.key && keys.get(i.key) === undefined ? [i.key] : []))
      if (unknown.length) {
        keys.resolve(unknown).then(() => view.dispatch({ effects: resolved.of(null) })).catch(() => {})
      }
      const preview = view.state.field(editorLivePreviewField, false) ?? false
      const docs = (k: string) => keys.get(k)
      const b = new RangeSetBuilder<Decoration>()
      for (const g of groups) {
        if (!names(g, docs)) continue
        const touched = view.state.selection.ranges.some(r => r.from <= g.to && r.to >= g.from)
        if (preview && !touched) {
          const known = new Map(g.items.flatMap(i => i.key ? [[i.key, keys.get(i.key) ?? null] as const] : []))
          b.add(g.from, g.to, Decoration.replace({ widget: new CitationWidget(g, known) }))
          continue
        }
        for (const i of g.items) {
          const d = i.key ? keys.get(i.key) : null
          if (d) b.add(i.from, i.to, Decoration.mark({ class: 'zemi-cite', attributes: { 'data-zemi-page': d.page } }))
        }
      }
      this.decorations = b.finish()
    }
  }, {
    decorations: v => v.decorations,
    eventHandlers: {
      mousedown(e: MouseEvent) {
        if (!(e.metaKey || e.ctrlKey)) return false
        const page = (e.target as HTMLElement).closest('.zemi-cite')?.getAttribute('data-zemi-page')
        if (!page) return false
        e.preventDefault()
        window.open(page)
        return true
      },
    },
  })
  const hover = hoverTooltip((view, pos) => {
    const line = view.state.doc.lineAt(pos)
    const c = citations(line.text).find(c => line.from + c.from <= pos && pos <= line.from + c.to)
    const d = c && keys.get(c.key)
    if (!c || !d) return null
    return {
      pos: line.from + c.from, end: line.from + c.to, above: true,
      create() {
        const dom = createDiv({ cls: 'zemi-cite-tip' })
        dom.createDiv({ text: d.title, cls: 'zemi-cite-title' })
        const by = describe(d).split('\n')[1]
        if (by) dom.createDiv({ text: by, cls: 'zemi-dim' })
        dom.createDiv({ text: `${navigator.platform.startsWith('Mac') ? 'Cmd' : 'Ctrl'}-click to open in Zemi`, cls: 'zemi-dim' })
        return { dom }
      },
    }
  })
  return [marks, hover]
}
