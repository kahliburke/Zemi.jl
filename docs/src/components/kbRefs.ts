// @-references in task text (see src/at_references.jl): `@KB-12`, `@arXiv:2401.00001`, `@doc-5f13926ae1`,
// `@rec-notes-2026-10-02` (a record), `@code:src/tasks.jl#update_project!` (in the project's codebase), and
// `@[label](kind:target)` for any kind. Rendered, each becomes a link: a paper, author, notebook or
// finding or record to its page, a task to open in the panel (`data-task`), a person as a name. Code is left alone.
// The tutor cites papers as `[arXiv:2401.00001]` (several: `[arXiv:…; arXiv:…]`), each a link to its
// page here, or to arXiv for one the knowledge base does not hold.
import { getJSON, mediaUrl } from './kbApi'
import { escapeHtml } from './kbUtils'
import { paperHref, codeHref, codebaseHref, notebookHref, authorHref, findingHref, taskHref, recordHref } from './kbLinks'
import { citedAs, isArxivId, splitCodeTarget } from './kbKinds'

const FULL = /@\[([^\]\n]+)\]\((task|paper|record|author|person|notebook|code|finding):([^)\n]+)\)/g
const TASK = /(?<![\w@/\[])@([A-Z][A-Z0-9]*-\d+)\b/g
const PAPER = /(?<![\w@/\[])@arXiv:(\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?\/\d{7})/gi
const CODE_REF = /(?<![\w@/\[])@code:([\w./-]*\w)(?:#([\w!?]+(?:\.[\w!?]+)*))?/g
const FINDING = /(?<![\w@/\[])@([A-Za-z][A-Za-z0-9]*-F\d+)\b/gi
const DOC = /(?<![\w@/\[])@(doc-[0-9a-f]{10})\b/g
const RECORD = /(?<![\w@/\[])@(rec-[a-z0-9]+(?:-[a-z0-9]+)*)/g
const CITE = /\[(arXiv:[^\]\n]+)\](?!\()/gi
const CODE = /```[\s\S]*?```|`[^`\n]*`/g

export type RefMatch = { kind: string; target: string; label: string; detail: string }

// The codebase `@code:` references in the text shown are in: the open project's (see setCodebase).
let codebase = ''
export const setCodebase = (id: string) => { codebase = id }

// A reference as the picker writes one: the short form where there is one. Code is named in the
// project's codebase, so a target's codebase (`code-kb:path`) is left out.
export function refFor(kind: string, target: string, label = target): string {
  if (kind === 'code') return `@code:${splitCodeTarget(target)[1]}`
  return kind === 'task' || kind === 'finding' || kind === 'record' ? `@${target}` :
         kind === 'paper' ? `@${citedAs(target)}` : `@[${label}](${kind}:${target})`
}
export const refText = (r: RefMatch) => refFor(r.kind, r.target, r.label)

// What can be referred to that matches `q`, as the picker offers it: in `project`, with its codebase.
export const findReferences = (q: string, project = ''): Promise<RefMatch[]> =>
  getJSON(`/api/tasks/references?q=${encodeURIComponent(q)}${project ? `&project=${encodeURIComponent(project)}` : ''}`)

const link = (label: string, kind: string, target: string) => `[${label.replace(/[[\]]/g, '\\$&')}](kbref:${kind}:${encodeURIComponent(target)})`

// The references in Markdown `text` as links the renderer keeps, for `refsHtml` to finish; a cited
// paper in `titles` (by its id) named by its title.
export function refsToMarkdown(text: string, titles: ReadonlyMap<string, string> = new Map()): string {
  const cite = (group: string) => '(' + group.split(/;\s*/).map(c => {
    const id = c.replace(/^arXiv:\s*/i, '').trim(), title = titles.get(id)
    return title ? link(title, 'paper', id) : `[arXiv:${id}](https://arxiv.org/abs/${id})`
  }).join('; ') + ')'
  let out = '', i = 0
  const prose = (s: string) => s.replace(FULL, (_, label, kind, target) => link(label.trim(), kind, target.trim()))
    .replace(FINDING, (_, ref) => link(ref.toUpperCase(), 'finding', ref.toUpperCase()))
    .replace(TASK, (_, ref) => link(ref, 'task', ref))
    .replace(PAPER, (_, id) => link(`arXiv:${id}`, 'paper', id))
    .replace(DOC, (_, id) => link(id, 'paper', id))
    .replace(RECORD, (_, id) => link(id, 'record', id))
    .replace(CODE_REF, (_, path, name) => link(name ?? path, 'code', name ? `${path}#${name}` : path))
    .replace(CITE, (_, group) => cite(group))
  for (const m of text.matchAll(CODE)) {
    out += prose(text.slice(i, m.index)) + m[0]
    i = m.index! + m[0].length
  }
  return out + prose(text.slice(i))
}

// Where a reference leads: its page, or '' for what has none (a person).
export function href(kind: string, target: string): string {
  if (kind === 'paper') return paperHref(target)
  if (kind === 'code') {
    // `codebase:path#name` as a task's link has it, or `path#name` in the open project's codebase.
    const [named, rest] = splitCodeTarget(target)
    const cb = named || codebase
    if (!cb) return ''
    const [path, name] = rest.split('#')
    return codeHref(cb, path, name)
  }
  if (kind === 'task') return taskHref(target)
  if (kind === 'finding') return findingHref(target.toUpperCase())
  if (kind === 'codebase') return codebaseHref(target)
  if (kind === 'record') return recordHref(target)
  if (kind === 'author') return authorHref(target)
  // A notebook's page is under its paper's: notebooks/papers/<paper>/<name>.jl.
  const m = kind === 'notebook' ? target.match(/papers\/([^/]+)\/([^/]+)\.jl$/) : null
  return m ? notebookHref(m[1], m[2]) : ''
}

// Where a task's link or a finding's source leads: as `href`, but a paper the knowledge base does not
// hold (named by its id rather than its title) on arXiv, a web page as itself, and a result (a file
// attached) where it is served.
export function sourceHref(kind: string, target: string, label = ''): string {
  if (kind === 'paper') return !isArxivId(target) || (label && label !== target) ? href(kind, target) : `https://arxiv.org/abs/${target}`
  if (kind === 'url') return /^https?:\/\//.test(target) ? target : ''
  if (kind === 'result') return target.startsWith('media/') ? mediaUrl(target) : ''
  return href(kind, target)
}

// A handler for clicks and Enter on rendered text, opening the task a reference in it names.
export const onTaskRef = (open: (ref: string) => void) => (e: Event) => {
  const el = (e.target as HTMLElement).closest<HTMLElement>('[data-task]')
  if (!el || (e.type === 'keydown' && (e as KeyboardEvent).key !== 'Enter')) return
  e.preventDefault()
  open(el.dataset.task!)
}


// Rendered HTML with the reference links `refsToMarkdown` left made into the references' links.
export function refsHtml(html: string): string {
  return html.replace(/<a href="kbref:(\w+):([^"]*)">([\s\S]*?)<\/a>/g, (_, kind, enc, label) => {
    const target = decodeURIComponent(enc.replace(/&amp;/g, '&'))
    if (kind === 'task') return `<span class="kb-ref kb-ref-task" role="link" tabindex="0" data-task="${escapeHtml(target)}">${label}</span>`
    const to = href(kind, target)
    return to ? `<a class="kb-ref kb-ref-${kind}" href="${escapeHtml(to)}">${label}</a>`
              : `<span class="kb-ref kb-ref-${kind}" title="${escapeHtml(target)}">${label}</span>`
  })
}
