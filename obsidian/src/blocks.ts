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
import { MarkdownPostProcessorContext, MarkdownRenderChild, MarkdownRenderer, TFile, setIcon } from 'obsidian'
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

const ICONS: Record<string, string> = { search: 'search', cited: 'quote', tasks: 'list-checks', findings: 'lightbulb' }

/** What a block shows, as its heading says it: the search's words, the project and its filters. */
function heading(kind: string, f: Map<string, string>): string {
  const filters = ['status', 'milestone'].filter(k => f.get(k)).map(k => STATUS(f.get(k)!)).join(', ')
  if (kind === 'search') return f.get('search') ? `“${f.get('search')}”` : 'Search'
  if (kind === 'cited') return 'References'
  const project = (f.get(kind) ?? '').toUpperCase()
  return `${kind === 'tasks' ? 'Tasks' : 'Findings'}${project ? ' · ' + project : ''}${filters ? ` (${filters})` : ''}`
}

/** The part of a block a drawing fills: its `body`, and `info`, beside its heading, said when done. */
type Parts = { body: HTMLElement; info: (text: string) => void }

export async function drawBlock(plugin: ZemiPlugin, source: string, el: HTMLElement, ctx: MarkdownPostProcessorContext) {
  const child = new MarkdownRenderChild(el)
  ctx.addChild(child)
  el.addClass('zemi-block')
  const f = blockFields(source)
  const kind = BLOCK_KINDS.find(k => f.has(k))
  if (!kind) { el.createEl('p', { cls: 'zemi-dim', text: 'A zemi block says what it shows: search, cited, tasks or findings.' }); return }
  const head = el.createDiv({ cls: 'zemi-block-head' })
  setIcon(head.createSpan({ cls: 'zemi-block-icon' }), ICONS[kind])
  head.createSpan({ cls: 'zemi-block-title', text: heading(kind, f) })
  const status = head.createSpan({ cls: 'zemi-block-info' })
  const again = head.createEl('button', { cls: 'clickable-icon zemi-block-again', attr: { 'aria-label': 'Ask Zemi again' } })
  setIcon(again, 'refresh-cw')
  const body = el.createDiv({ cls: 'zemi-block-body' })
  const say = (text: string) => body.createEl('p', { cls: 'zemi-dim', text })
  const run = async () => {
    body.empty()
    status.empty()
    status.createSpan({ cls: 'zemi-spinner' })
    status.appendText(kind === 'search' ? ' Searching…' : ' Asking Zemi…')
    again.disabled = true
    el.addClass('is-loading')
    skeleton(body, Math.min(limitOf(f, kind === 'search' ? 5 : 3), 5))
    const parts: Parts = { body, info: text => status.setText(text) }
    try {
      if (kind === 'search') await drawSearch(plugin, parts, f)
      else if (kind === 'cited') await drawCited(plugin, parts, ctx, child)
      else if (kind === 'tasks') await drawTasks(plugin, parts, f)
      else await drawFindings(plugin, parts, f)
    } catch (e: any) {
      body.empty()
      status.setText('')
      if (e instanceof SignedOut) say(e.message)
      else if (e instanceof Refused && e.status === 403) say('Zemi: this sign-in cannot see that. Sign in again from the plugin settings to show tasks and findings.')
      else say(`Zemi: ${e?.message ?? e}`)
    } finally {
      el.removeClass('is-loading')
      again.disabled = false
    }
  }
  again.onclick = () => { run() }
  await run()
}

/** Rows standing in for what is coming. */
function skeleton(body: HTMLElement, n: number) {
  const box = body.createDiv({ cls: 'zemi-skeleton', attr: { 'aria-hidden': 'true' } })
  for (let i = 0; i < n; i++) {
    const row = box.createDiv({ cls: 'zemi-skeleton-row' })
    row.createDiv({ cls: 'zemi-skeleton-bar', attr: { style: `width: ${55 + ((i * 17) % 35)}%` } })
    row.createDiv({ cls: 'zemi-skeleton-bar is-short' })
  }
}

/** A drawing's results replace the rows standing in for them. */
function ready(body: HTMLElement) { body.empty(); return body }

function limitOf(f: Map<string, string>, fallback: number) {
  const n = parseInt(f.get('limit') ?? '', 10)
  return Number.isFinite(n) && n > 0 ? Math.min(n, 50) : fallback
}

const plural = (n: number, one: string, many = one + 's') => `${n} ${n === 1 ? one : many}`

// A passage's references (`@[label](paper:id)`) as their labels, and its words run together.
const plainText = (t: string) => t.replace(/@\[([^\]]*)\]\([\w-]+:[^)]*\)/g, '$1').replace(/[#*_`>]+/g, '').replace(/\s+/g, ' ').trim()

/** `text` cut to about `n` characters around where the first of `words` is, each of them marked. */
function excerpt(el: HTMLElement, text: string, words: string[], n = 220) {
  const lower = text.toLowerCase()
  const first = Math.min(...words.map(w => lower.indexOf(w)).filter(i => i >= 0), Infinity)
  let from = Number.isFinite(first) ? Math.max(0, first - 60) : 0
  if (from > 0) from = text.indexOf(' ', from) + 1 || from
  let cut = text.slice(from, from + n)
  if (from + n < text.length) cut = cut.slice(0, cut.lastIndexOf(' ') > 0 ? cut.lastIndexOf(' ') : cut.length) + ' …'
  if (from > 0) cut = '… ' + cut
  const pattern = words.length ? new RegExp(`(${words.map(w => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi') : null
  for (const part of pattern ? cut.split(pattern) : [cut]) {
    pattern && words.includes(part.toLowerCase()) ? el.createEl('mark', { text: part }) : el.appendText(part)
  }
}

type Evidence = { ranking: string; ranking_label: string; rank: number; matched: string; contribution: number }

/** Why a hit is where it is: each ranking that found it, its place there, what it matched and its share. */
function whyCard(li: HTMLElement, h: any, place: number) {
  const card = li.createDiv({ cls: 'zemi-why', attr: { role: 'tooltip' } })
  const strength = h.score && h.max_score ? Math.round(100 * h.score / h.max_score) : 0
  card.createDiv({ cls: 'zemi-why-head', text: `#${place} · ${strength}% of a first place in every ranking` })
  const evidence: Evidence[] = h.evidence ?? []
  if (!evidence.length) { card.createDiv({ cls: 'zemi-dim', text: 'Named in the search.' }); return }
  const table = card.createEl('table')
  for (const e of evidence) {
    const tr = table.createEl('tr')
    tr.createEl('td', { text: e.ranking_label })
    tr.createEl('td', { text: `#${e.rank}`, cls: 'zemi-why-rank' })
    const share = h.score ? Math.round(100 * e.contribution / h.score) : 0
    const bar = tr.createEl('td').createSpan({ cls: 'zemi-meter is-small' })
    bar.createSpan({ attr: { style: `width: ${share}%` } })
    tr.createEl('td', { text: `${share}%`, cls: 'zemi-dim' })
    if (e.matched) table.createEl('tr').createEl('td', { text: `matched ${e.matched}`, cls: 'zemi-dim zemi-why-matched', attr: { colspan: '4' } })
  }
  const p = h.passages?.[0]
  if (p?.section) card.createDiv({ cls: 'zemi-dim', text: `Best passage: ${p.section}` })
}

async function drawSearch(plugin: ZemiPlugin, { body, info }: Parts, f: Map<string, string>) {
  const q = f.get('search') ?? ''
  if (!q) { ready(body).createEl('p', { cls: 'zemi-dim', text: 'Search for what? Give words after search:' }); info(''); return }
  const got = await plugin.zemi.get(`/api/search?q=${encodeURIComponent(q)}&limit=${limitOf(f, 8)}`)
  const hits: any[] = got?.hits ?? []
  info([plural(hits.length, 'result'), typeof got?.seconds === 'number' ? `${got.seconds.toFixed(2)} s` : ''].filter(Boolean).join(' · '))
  ready(body)
  if (!hits.length) { body.createEl('p', { cls: 'zemi-dim', text: 'Nothing in Zemi for these words.' }); return }
  const words = [...new Set((q.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) ?? []))]
  const list = body.createEl('ol', { cls: 'zemi-hits' })
  hits.forEach((h, i) => {
    const li = list.createEl('li', { cls: 'zemi-hit' })
    const top = li.createDiv({ cls: 'zemi-hit-top' })
    top.createEl('a', { text: h.title, href: h.link, cls: 'external-link zemi-hit-title' })
    const b = top.createEl('button', { text: 'cite', cls: 'zemi-small', attr: { 'aria-label': 'Insert its citation where the cursor is' } })
    b.onclick = () => plugin.insertCitation(h.id)
    const meta = li.createDiv({ cls: 'zemi-hit-meta' })
    const strength = h.score && h.max_score ? h.score / h.max_score : 0
    const meter = meta.createSpan({ cls: 'zemi-meter' })
    meter.createSpan({ attr: { style: `width: ${Math.round(100 * strength)}%` } })
    meta.createSpan({ cls: 'zemi-why-hint', text: `${Math.round(100 * strength)}% · why` })
    if (h.record) meta.createSpan({ cls: 'zemi-chip', text: `${h.record.label}${h.record.day ? ' · ' + h.record.day : ''}` })
    else if (h.kind && h.kind !== 'paper') meta.createSpan({ cls: 'zemi-chip', text: h.kind })
    const by = (h.authors ?? []).slice(0, 3).join(', ') + ((h.authors ?? []).length > 3 ? ' et al.' : '')
    const line = [by, h.record ? '' : (h.published ?? '').slice(0, 4)].filter(Boolean).join(' · ')
    if (line) meta.createSpan({ cls: 'zemi-dim', text: line })
    const p = h.passages?.[0]
    if (p?.text) excerpt(li.createDiv({ cls: 'zemi-excerpt' }), plainText(p.text), words)
    whyCard(li, h, i + 1)
  })
}

async function drawCited(plugin: ZemiPlugin, { body, info }: Parts, ctx: MarkdownPostProcessorContext, child: MarkdownRenderChild) {
  const file = plugin.app.vault.getAbstractFileByPath(ctx.sourcePath)
  if (!(file instanceof TFile)) { ready(body); info(''); return }
  // The note's prose: its code, this block among it, cites nothing.
  const text = (await plugin.app.vault.cachedRead(file)).replace(/^(```|~~~)[\s\S]*?^\1/gm, '').replace(/`[^`\n]*`/g, '')
  const keys = [...new Set(citations(text).map(c => c.key))]
  if (!keys.length) { ready(body).createEl('p', { cls: 'zemi-dim', text: 'This note cites nothing yet.' }); info(''); return }
  const docs = await plugin.cited.resolve(keys)
  const found = keys.filter(k => docs.get(k))
  const refs = await Promise.all(found.map(async k => {
    const d = docs.get(k)!
    const c = await plugin.zemi.get(`/api/cite/${encodeURIComponent(d.id)}`)
    return { d, text: String(c?.citation ?? d.title) }
  }))
  refs.sort((a, b) => a.text.localeCompare(b.text))
  const missing = keys.filter(k => !docs.get(k))
  info(plural(refs.length, 'reference') + (missing.length ? ` · ${missing.length} not in Zemi` : ''))
  const list = ready(body).createEl('ul', { cls: 'zemi-list zemi-references' })
  for (const r of refs) {
    const li = list.createEl('li')
    const t = li.createSpan()
    await MarkdownRenderer.render(plugin.app, r.text, t, ctx.sourcePath, child)
    // A paragraph would break the line: its contents alone.
    const p = t.querySelector('p')
    if (p) t.replaceChildren(...Array.from(p.childNodes))
    li.createEl('a', { text: ' Zemi', href: r.d.page, cls: 'external-link zemi-small-link' })
  }
  if (missing.length) body.createEl('p', { cls: 'zemi-dim', text: `Not in Zemi: ${missing.map(k => '@' + k).join(', ')}` })
}

async function drawTasks(plugin: ZemiPlugin, { body, info }: Parts, f: Map<string, string>) {
  const project = (f.get('tasks') ?? '').toUpperCase()
  if (!project) { ready(body).createEl('p', { cls: 'zemi-dim', text: 'Which project? Give its key after tasks:' }); info(''); return }
  const q = new URLSearchParams({ project, limit: String(limitOf(f, 50)) })
  for (const k of ['status', 'milestone']) if (f.get(k)) q.set(k, f.get(k)!.replace(' ', '_'))
  if (/^(yes|true|1)$/i.test(f.get('all') ?? '')) q.set('all', '1')
  const tasks: any[] = (await plugin.zemi.get(`/api/tasks?${q}`)) ?? []
  info(plural(tasks.length, 'task'))
  if (!tasks.length) { ready(body).createEl('p', { cls: 'zemi-dim', text: `No tasks in ${project} here.` }); return }
  const list = ready(body).createEl('ul', { cls: 'zemi-list zemi-tasks' })
  for (const t of tasks) {
    const li = list.createEl('li')
    li.createSpan({ cls: `zemi-chip zemi-status-${t.status}`, text: STATUS(t.status) })
    li.appendText(' ')
    t.page ? li.createEl('a', { text: t.ref, href: t.page, cls: 'external-link' }) : li.createSpan({ text: t.ref })
    li.appendText(` ${t.title}`)
    if (t.subtasks) li.createSpan({ cls: 'zemi-dim', text: ` ${t.subtasks_done}/${t.subtasks}` })
  }
}

async function drawFindings(plugin: ZemiPlugin, { body, info }: Parts, f: Map<string, string>) {
  const project = (f.get('findings') ?? '').toUpperCase()
  if (!project) { ready(body).createEl('p', { cls: 'zemi-dim', text: 'Which project? Give its key after findings:' }); info(''); return }
  const status = f.get('status') || 'accepted'
  const found: any[] = ((await plugin.zemi.get(`/api/findings?${new URLSearchParams({ project, status })}`)) ?? []).slice(0, limitOf(f, 50))
  info(plural(found.length, `${status} finding`))
  if (!found.length) { ready(body).createEl('p', { cls: 'zemi-dim', text: `No ${status} findings in ${project}.` }); return }
  const list = ready(body).createEl('ul', { cls: 'zemi-list' })
  for (const x of found) {
    const li = list.createEl('li')
    x.page ? li.createEl('a', { text: x.ref, href: x.page, cls: 'external-link' }) : li.createSpan({ text: x.ref })
    li.appendText(` ${x.claim}`)
  }
}
