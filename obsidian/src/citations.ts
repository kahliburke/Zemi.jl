// A note's citations (`[@key]`, as Pandoc writes them and Zemi reads them) made into links to the
// documents they name: in reading view by a post-processor, and in the editor by marks that open the
// document on Cmd/Ctrl-click and show it on hover. The note's text is left as it is.
import { syntaxTree } from '@codemirror/language'
import { RangeSetBuilder, StateEffect } from '@codemirror/state'
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, hoverTooltip } from '@codemirror/view'
import type { MarkdownPostProcessorContext } from 'obsidian'
import type { Zemi } from './zemi'
import { citations } from './cite_rule'

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

// ── Reading view ──────────────────────────────────────────────────────────────────────────────────

const SKIPPED = 'a, code, pre, .math'

/** Make the citations in rendered `el` links to their documents' pages in Zemi. */
export async function linkCitations(el: HTMLElement, _ctx: MarkdownPostProcessorContext, keys: CitedKeys) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  const found: { node: Text; cites: ReturnType<typeof citations> }[] = []
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n as Text
    if (!t.data.includes('@') || t.parentElement?.closest(SKIPPED)) continue
    const cites = citations(t.data)
    if (cites.length) found.push({ node: t, cites })
  }
  if (!found.length) return
  let docs: Map<string, Cited | null>
  try { docs = await keys.resolve(found.flatMap(f => f.cites.map(c => c.key))) } catch { return }
  for (const { node, cites } of found) {
    const text = node.data
    const frag = document.createDocumentFragment()
    let at = 0
    for (const c of cites) {
      const d = docs.get(c.key)
      if (!d) continue
      frag.append(text.slice(at, c.from))
      const a = frag.createEl('a', { text: text.slice(c.from, c.to), href: d.page, cls: 'zemi-cite external-link' })
      a.setAttr('aria-label', describe(d))
      a.setAttr('target', '_blank')
      a.setAttr('rel', 'noopener')
      at = c.to
    }
    if (at === 0) continue
    frag.append(text.slice(at))
    node.replaceWith(frag)
  }
}

// ── The editor ────────────────────────────────────────────────────────────────────────────────────

const resolved = StateEffect.define<null>()

// Inside code, a citation is text: Obsidian's Markdown names its code nodes so.
function inCode(view: EditorView, pos: number) {
  const name = syntaxTree(view.state).resolveInner(pos, 1).name
  return /code|math/i.test(name)
}

/** The citations of the visible text that name documents: `[@key]`'s `@key`, with its document. */
function visibleCitations(view: EditorView, keys: CitedKeys) {
  const out: { from: number; to: number; key: string }[] = []
  for (const { from, to } of view.visibleRanges) {
    const text = view.state.sliceDoc(from, to)
    for (const c of citations(text)) {
      if (!inCode(view, from + c.from)) out.push({ from: from + c.from, to: from + c.to, key: c.key })
    }
  }
  return out
}

/** Marks the citations in the editor, Cmd/Ctrl-click opening a document's page, hover showing it. */
export function citationExtension(keys: CitedKeys) {
  const marks = ViewPlugin.fromClass(class {
    decorations: DecorationSet = Decoration.none
    constructor(private view: EditorView) { this.build() }

    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.transactions.some(t => t.effects.some(e => e.is(resolved)))) this.build()
    }

    private build() {
      const cites = visibleCitations(this.view, keys)
      const unknown = cites.filter(c => keys.get(c.key) === undefined).map(c => c.key)
      if (unknown.length) {
        keys.resolve(unknown).then(() => this.view.dispatch({ effects: resolved.of(null) })).catch(() => {})
      }
      const b = new RangeSetBuilder<Decoration>()
      for (const c of cites) {
        const d = keys.get(c.key)
        if (d) b.add(c.from, c.to, Decoration.mark({ class: 'zemi-cite', attributes: { 'data-zemi-page': d.page } }))
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
