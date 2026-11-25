// A `zemi` code block in a note: what the knowledge base has, drawn each time the note is shown and
// never written into it. Each line is `name: value`; the first of `search`, `cited`, `tasks` or
// `findings` says what it shows:
//
//     ```zemi
//     search: tidal mixing in estuaries
//     limit: 5
//     ```
//
// `search: <words>` the documents found; `cited:` the documents the note cites, as references;
// `tasks: <PROJECT>` a project's tasks (`status:`, `milestone:`, `all: yes` for subtasks too);
// `findings: <PROJECT>` its findings (`status:`, accepted unless given).
import { MarkdownPostProcessorContext, MarkdownRenderChild, MarkdownRenderer, TFile } from 'obsidian'
import type ZemiPlugin from './main'
import { citations } from './cite_rule'
import { Refused, SignedOut } from './zemi'

export const BLOCK_KINDS = ['search', 'cited', 'tasks', 'findings'] as const

export const STARTER_BLOCK = '```zemi\nsearch: \nlimit: 5\n```\n'

/** A block's lines, `name: value`, by name. */
export function blockFields(source: string): Map<string, string> {
  const out = new Map<string, string>()
  for (const line of source.split('\n')) {
    const m = line.match(/^\s*([\w-]+)\s*:\s*(.*?)\s*$/)
    if (m && !out.has(m[1].toLowerCase())) out.set(m[1].toLowerCase(), m[2])
  }
  return out
}

const STATUS = (s: string) => s.replace('_', ' ')

export async function drawBlock(plugin: ZemiPlugin, source: string, el: HTMLElement, ctx: MarkdownPostProcessorContext) {
  const child = new MarkdownRenderChild(el)
  ctx.addChild(child)
  el.addClass('zemi-block')
  const f = blockFields(source)
  const kind = BLOCK_KINDS.find(k => f.has(k))
  const say = (text: string) => el.createEl('p', { cls: 'zemi-dim', text })
  try {
    if (kind === 'search') await drawSearch(plugin, el, f)
    else if (kind === 'cited') await drawCited(plugin, el, ctx, child)
    else if (kind === 'tasks') await drawTasks(plugin, el, f)
    else if (kind === 'findings') await drawFindings(plugin, el, f)
    else say('A zemi block says what it shows: search, cited, tasks or findings.')
  } catch (e: any) {
    el.empty()
    el.addClass('zemi-block')
    if (e instanceof SignedOut) say(e.message)
    else if (e instanceof Refused && e.status === 403) say('Zemi: this sign-in cannot see that. Sign in again from the plugin settings to show tasks and findings.')
    else say(`Zemi: ${e?.message ?? e}`)
  }
}

function limitOf(f: Map<string, string>, fallback: number) {
  const n = parseInt(f.get('limit') ?? '', 10)
  return Number.isFinite(n) && n > 0 ? Math.min(n, 50) : fallback
}

async function drawSearch(plugin: ZemiPlugin, el: HTMLElement, f: Map<string, string>) {
  const q = f.get('search') ?? ''
  if (!q) { el.createEl('p', { cls: 'zemi-dim', text: 'Search for what? Give words after search:' }); return }
  const got = await plugin.zemi.get(`/api/search?q=${encodeURIComponent(q)}&limit=${limitOf(f, 8)}`)
  const hits: any[] = got?.hits ?? []
  if (!hits.length) { el.createEl('p', { cls: 'zemi-dim', text: `Nothing in Zemi for “${q}”.` }); return }
  const list = el.createEl('ul', { cls: 'zemi-list' })
  for (const h of hits) {
    const li = list.createEl('li')
    li.createEl('a', { text: h.title, href: `${plugin.zemi.site}/${h.page}`, cls: 'external-link' })
    const by = (h.authors ?? []).slice(0, 3).join(', ')
    const meta = [h.kind !== 'paper' ? h.kind : '', by, (h.published ?? '').slice(0, 4)].filter(Boolean).join(' · ')
    if (meta) li.createSpan({ cls: 'zemi-dim', text: ` ${meta}` })
    const b = li.createEl('button', { text: 'cite', cls: 'zemi-small', attr: { title: 'Insert its citation where the cursor is' } })
    b.onclick = () => plugin.insertCitation(h.id)
  }
}

async function drawCited(plugin: ZemiPlugin, el: HTMLElement, ctx: MarkdownPostProcessorContext, child: MarkdownRenderChild) {
  const file = plugin.app.vault.getAbstractFileByPath(ctx.sourcePath)
  if (!(file instanceof TFile)) return
  // The note's prose: its code, this block among it, cites nothing.
  const text = (await plugin.app.vault.cachedRead(file)).replace(/^(```|~~~)[\s\S]*?^\1/gm, '').replace(/`[^`\n]*`/g, '')
  const keys = [...new Set(citations(text).map(c => c.key))]
  if (!keys.length) { el.createEl('p', { cls: 'zemi-dim', text: 'This note cites nothing yet.' }); return }
  const docs = await plugin.cited.resolve(keys)
  const found = keys.filter(k => docs.get(k))
  const refs = await Promise.all(found.map(async k => {
    const d = docs.get(k)!
    const c = await plugin.zemi.get(`/api/cite/${encodeURIComponent(d.id)}`)
    return { d, text: String(c?.citation ?? d.title) }
  }))
  refs.sort((a, b) => a.text.localeCompare(b.text))
  el.createEl('h4', { text: 'References' })
  const list = el.createEl('ul', { cls: 'zemi-list zemi-references' })
  for (const r of refs) {
    const li = list.createEl('li')
    const t = li.createSpan()
    await MarkdownRenderer.render(plugin.app, r.text, t, ctx.sourcePath, child)
    // A paragraph would break the line: its contents alone.
    const p = t.querySelector('p')
    if (p) t.replaceChildren(...Array.from(p.childNodes))
    li.createEl('a', { text: ' Zemi', href: r.d.page, cls: 'external-link zemi-small-link' })
  }
  const missing = keys.filter(k => !docs.get(k))
  if (missing.length) el.createEl('p', { cls: 'zemi-dim', text: `Not in Zemi: ${missing.map(k => '@' + k).join(', ')}` })
}

async function drawTasks(plugin: ZemiPlugin, el: HTMLElement, f: Map<string, string>) {
  const project = (f.get('tasks') ?? '').toUpperCase()
  if (!project) { el.createEl('p', { cls: 'zemi-dim', text: 'Which project? Give its key after tasks:' }); return }
  const q = new URLSearchParams({ project, limit: String(limitOf(f, 50)) })
  for (const k of ['status', 'milestone']) if (f.get(k)) q.set(k, f.get(k)!.replace(' ', '_'))
  if (/^(yes|true|1)$/i.test(f.get('all') ?? '')) q.set('all', '1')
  const tasks: any[] = (await plugin.zemi.get(`/api/tasks?${q}`)) ?? []
  if (!tasks.length) { el.createEl('p', { cls: 'zemi-dim', text: `No tasks in ${project} here.` }); return }
  const list = el.createEl('ul', { cls: 'zemi-list zemi-tasks' })
  for (const t of tasks) {
    const li = list.createEl('li')
    li.createSpan({ cls: `zemi-chip zemi-status-${t.status}`, text: STATUS(t.status) })
    li.appendText(' ')
    t.page ? li.createEl('a', { text: t.ref, href: t.page, cls: 'external-link' }) : li.createSpan({ text: t.ref })
    li.appendText(` ${t.title}`)
    if (t.subtasks) li.createSpan({ cls: 'zemi-dim', text: ` ${t.subtasks_done}/${t.subtasks}` })
  }
}

async function drawFindings(plugin: ZemiPlugin, el: HTMLElement, f: Map<string, string>) {
  const project = (f.get('findings') ?? '').toUpperCase()
  if (!project) { el.createEl('p', { cls: 'zemi-dim', text: 'Which project? Give its key after findings:' }); return }
  const status = f.get('status') || 'accepted'
  const found: any[] = ((await plugin.zemi.get(`/api/findings?${new URLSearchParams({ project, status })}`)) ?? []).slice(0, limitOf(f, 50))
  if (!found.length) { el.createEl('p', { cls: 'zemi-dim', text: `No ${status} findings in ${project}.` }); return }
  const list = el.createEl('ul', { cls: 'zemi-list' })
  for (const x of found) {
    const li = list.createEl('li')
    x.page ? li.createEl('a', { text: x.ref, href: x.page, cls: 'external-link' }) : li.createSpan({ text: x.ref })
    li.appendText(` ${x.claim}`)
  }
}
