// Pages made from a template: one page of the site is built for each kind (a paper, …), and every
// page of that kind is a copy of it, filled in the browser from the page's data file. A page added
// after the build is a copy written beside the others, with its data file, so no build is needed.
//
// VitePress finds the bundle of the page an address names in a table written at build time
// (`__VP_HASH_MAP__`). An address of a templated kind the table lacks is answered with its
// template's entry, so a link to a page added since opens it in place rather than "not found".
// This module is loaded with the theme's components, before the router resolves the first page.
import { ref, shallowRef, watch, nextTick, onScopeDispose } from 'vue'
import { useRoute, type Route } from 'vitepress'
import { siteJSON, RequestError } from './kbApi'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'

type Kind = { name: string; folder: string; template: string }

// Each kind's pages, `<folder>/<slug>.html`, its built template, and its data
// `kb-data/<name>/<slug>.json` at the site's root: `TEMPLATED` in src/site.jl, given by docs/make.jl.
// A folder with `*` holds a folder of pages for each name in its place (a codebase's files); the
// page's slug is then `<name>/<page>`.
declare const __KB_TEMPLATES__: Kind[]
export const KINDS: Kind[] = __KB_TEMPLATES__

// The table's key for a page: its path with `/` as `_`, lowercased, ending `.md`.
const keyOf = (path: string) => `${path.replace(/\//g, '_')}.md`.toLowerCase()

const escape = (s: string) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
// A page of the kind in the table: its folder's key, then the page's name. A flat kind's page names
// hold no `_`, which leaves out the pages beneath them (a paper's notebook pages are built pages). A
// key is the first kind's it fits, in the table's order, which puts a kind whose pages are beneath
// another's folders first (a codebase's files, then its page).
const keyPatterns = KINDS.map(k => ({
  kind: k,
  pattern: new RegExp(`^${k.folder.split('*').map(p => escape(p.replace(/\//g, '_').toLowerCase())).join('[^_]+')}_${k.folder.includes('*') ? '.+' : '[^_]+'}\\.md$`),
}))

function templateKey(key: string): string | undefined {
  const hit = keyPatterns.find(p => p.pattern.test(key))
  return hit && keyOf(hit.kind.template)
}

// A page's script is a copy of its template's, named `<page key>.<template's hash>.<COPY>.js` (see
// `stamp_templates!`, which names the same from `TEMPLATE_COPY`, given here by docs/make.jl). A
// script is cached for good under its name, so COPY changes whenever what a copy holds does, for
// browsers to fetch the new one.
declare const __KB_TEMPLATE_COPY__: string
export const COPY = __KB_TEMPLATE_COPY__

function aliased(table: Record<string, string>): Record<string, string> {
  return new Proxy(table, {
    get(t, key) {
      if (typeof key !== 'string' || key in t) return Reflect.get(t, key)
      const tk = templateKey(key)
      return tk === undefined || t[tk] === undefined ? undefined : `${t[tk]}.${COPY}`
    },
  })
}

declare global { interface Window { __VP_HASH_MAP__?: Record<string, string> } }

// The table is set by a script of the build's, before or after this module runs.
if (typeof window !== 'undefined') {
  let table = window.__VP_HASH_MAP__ ? aliased(window.__VP_HASH_MAP__) : undefined
  Object.defineProperty(window, '__VP_HASH_MAP__', {
    configurable: true,
    get: () => table,
    set: (v: Record<string, string>) => { table = v ? aliased(v) : v },
  })
}

/** The slug of the templated page at `path` (the router's), for `kind`, or '' when it is not one. */
export function slugOf(kind: string, path: string): string {
  const k = KINDS.find(x => x.name === kind)
  if (!k) return ''
  const nested = k.folder.includes('*')
  // A folder's address (`…/2026-10-02/`) is its index page's.
  const page = decodeURIComponent(path).replace(/\/$/, '/index')
  const m = page.match(new RegExp(`/${k.folder.split('*').map(escape).join('([^/]+)')}/([^/]+?)(?:\\.html)?$`))
  return !m ? '' : nested ? `${m[1]}/${m[2]}` : m[1]
}

/** The data file of `kind`'s page `slug`, from the site's root. */
export const dataPath = (kind: string, slug: string) => `/kb-data/${kind}/${slug}.json`

/**
 * Tell VitePress that the page drawn from data has changed: it titles the tab from the page's data
 * (with `title`, the page's), and reads the page's headings for its outline again when the page's
 * frontmatter changes. The page's data is frozen, so it is replaced, as VitePress replaces it on going
 * to another page. Call it once the page's headings are drawn.
 */
export function pageDrawn(route: Route, title?: string) {
  const data = route.data
  route.data = { ...data, title: title ?? data.title, frontmatter: { ...data.frontmatter, kbDrawn: Date.now() } }
}

/**
 * A templated page's data, read from its data file for the page's address, and again as the address
 * changes; and the Markdown renderer its texts are drawn with (`markdown: false` for a page without
 * any). Of the addresses gone through, only the last one's answer shows, its data or its error
 * (`notFound` for a page the knowledge base lacks). Once the page is drawn (`drawn` runs first),
 * VitePress is told, with the title `title` gives (see `pageDrawn`), and the heading the address
 * names is scrolled to. `slug` finds the page another way than by its address.
 */
export function useTemplatedPage<T>(kind: string, notFound: string, options: {
  title?: (data: T) => string | undefined; slug?: () => Promise<string>; drawn?: () => void; markdown?: boolean } = {}) {
  const route = useRoute()
  const data = shallowRef<T | null>(null)
  const error = ref('')
  const render = shallowRef<Render>(escapeText)
  let asked = 0
  async function load(path: string) {
    const mine = ++asked
    data.value = null; error.value = ''
    try {
      const slug = options.slug ? await options.slug() : slugOf(kind, path)
      if (!slug || mine !== asked) return
      // The renderer first: the page's text is drawn once, and what its components then do to it (a
      // figure's mentions made links, see KBFigures.vue) stays.
      const [d, md] = await Promise.all([siteJSON(dataPath(kind, slug)) as Promise<T>,
                                         options.markdown === false ? escapeText : loadMarkdown()])
      if (mine !== asked) return
      render.value = md
      data.value = d
      await nextTick()
      if (mine !== asked) return
      options.drawn?.()
      pageDrawn(route, options.title?.(d))
      const at = decodeURIComponent(location.hash.slice(1))
      if (at) document.getElementById(at)?.scrollIntoView()
    } catch (e) {
      if (mine === asked) error.value = e instanceof RequestError && e.status === 404 ? notFound : (e as Error).message ?? String(e)
    }
  }
  watch(() => route.path, load, { immediate: true })
  onScopeDispose(() => { asked++ })
  return { data, error, render }
}
