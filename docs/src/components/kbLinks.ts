// Links to the site's pages, each kind of page built in one place.
import { withBase } from 'vitepress'

// Whether the site's addresses leave out `.html`, as docs/make.jl configures VitePress.
declare const __KB_CLEAN_URLS__: boolean

// A link to one of the site's pages, as VitePress writes its own: with `.html` unless the site uses
// clean URLs. A directory's page (ending in `/`) needs neither.
export function pageLink(path: string) {
  return withBase(path.endsWith('/') || __KB_CLEAN_URLS__ ? path : `${path}.html`)
}

const KB = '/generated/kb/'

/** A page of the knowledge base's, as the API and the site's data name them: `papers/2401-00001`, `code/code-kb/`. */
export const kbPage = (path: string) => pageLink(KB + path)

/** A paper's or topic's page name: its id with dots and slashes as dashes (`page_slug` in src/site.jl). */
export const pageSlug = (id: string) => id.replace(/[./]/g, '-')
/** A codebase file's page name: its path with each run of other characters as `_` (`file_slug` in src/code.jl). */
export const fileSlug = (path: string) => path.replace(/\/+$/, '').replace(/[^A-Za-z0-9]+/g, '_')

/** A paper's page, by its id or its page name. */
export const paperHref = (id: string) => id.startsWith('res-') ? resourceHref(id) : kbPage(`papers/${pageSlug(id)}`)
/** A resource's page: a data set, a portal, a law or a work not read in full. */
export const resourceHref = (id: string) => kbPage(`resources/${pageSlug(id)}`)
/** A notebook's page, under its paper's (`page` as the site names it). */
export const notebookHref = (paper: string, page: string) => kbPage(`papers/${pageSlug(paper)}/${page}`)
/** A codebase's page. */
export const codebaseHref = (codebase: string) => kbPage(`code/${pageSlug(codebase)}/`)
/** A codebase file's page, at a definition in it with `name`. */
export const codeHref = (codebase: string, path: string, name?: string) =>
  kbPage(`code/${pageSlug(codebase)}/files/${fileSlug(path)}`) + (name ? `#${encodeURIComponent(name)}` : '')
/** A record's page. */
export const recordHref = (id: string) => kbPage(`records/${pageSlug(id)}`)
/** A day's paper of the day (`2026-10-08`). */
export const dayHref = (day: string) => kbPage(`daily/${day}/`)
/** A topic's page: the papers in an arXiv category. */
export const topicHref = (category: string) => kbPage(`topics/${pageSlug(category)}`)
/** An author's papers and co-authors, on the authors' page. */
export const authorHref = (key: string) => `${kbPage('authors')}?a=${encodeURIComponent(key)}`
/** A document on the page that manages them, found and selected. */
export const manageHref = (id: string) => `${kbPage('manage')}?id=${encodeURIComponent(id)}`

/** A project's board. */
export const projectHref = (key: string) => `${pageLink('/projects')}#${key}`
/** A task, open on its project's board. */
export const taskHref = (ref: string) => `${pageLink('/projects')}#${ref}`
/** A finding, or what the findings page's address names (`KB` for a project's, `new/KB-12` for a new one). */
export const findingHref = (ref: string) => `${pageLink('/findings')}#${ref}`
