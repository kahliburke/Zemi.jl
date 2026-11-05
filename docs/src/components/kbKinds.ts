// The kinds of documents, told from their ids as src/kinds.jl tells them: a paper is an arXiv id or
// an upload's (`doc-…`), a codebase's id begins `code-`, a record's `rec-`. An id of no kind is
// neither a paper nor on arXiv. `access`: one may be open only to the members of its projects (see
// src/document_access.jl). `noun`: what one is called.

export type DocumentKind = 'paper' | 'code' | 'record'

const KINDS: Record<DocumentKind, { prefix: string; access: boolean; noun: string }> = {
  paper: { prefix: 'doc-', access: false, noun: 'paper' },
  code: { prefix: 'code-', access: true, noun: 'codebase' },
  record: { prefix: 'rec-', access: true, noun: 'record' },
}

/** What a document of `kind` is called (`codebase`), the kind's name for one of no kind listed. */
export const kindNoun = (kind: string) => KINDS[kind as DocumentKind]?.noun ?? kind
const PREFIXES = Object.entries(KINDS).map(([k, { prefix }]) => [prefix, k as DocumentKind] as const)
const ARXIV_ID = /^(\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?\/\d{7})$/

/** Whether `id` is an arXiv id (`2401.00001`, `hep-th/9901001`). */
export const isArxivId = (id: string) => ARXIV_ID.test(id)

/** The kind of the document `id` names, or `undefined` for an id of no kind. */
export function documentKind(id: string): DocumentKind | undefined {
  const p = PREFIXES.find(([prefix]) => id.startsWith(prefix))
  return p ? p[1] : isArxivId(id) ? 'paper' : undefined
}

/** Whether who sees document `id` may be set: whether its kind has access. */
export const hasAccess = (id: string) => { const k = documentKind(id); return !!k && KINDS[k].access }

/** Whether `id` names a codebase. */
export const isCodebase = (id: string) => documentKind(id) === 'code'

/** Whether `id` names a record. */
export const isRecord = (id: string) => documentKind(id) === 'record'

/** How a document is cited in text: `arXiv:` and its id for an arXiv paper, else its id. */
export const citedAs = (id: string) => isArxivId(id) ? `arXiv:${id}` : id

/** A code reference's target as its codebase and the path in it: `code-kb:src/x.jl#f`, or a path alone (codebase ''). */
export function splitCodeTarget(target: string): [string, string] {
  const m = target.match(/^([^:]+):(.*)$/)
  return m && isCodebase(m[1]) ? [m[1], m[2]] : ['', target]
}
