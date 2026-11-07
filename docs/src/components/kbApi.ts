// The knowledge base API that serves this site: whether it answers, who it answers as and what they
// may do, and the requests the pages make of it (src/routes.jl lists them). Every request goes
// through here, so each fails the same way: with the message the API gave.
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { withBase } from 'vitepress'
import { documentKind } from './kbKinds'

export type Layer = { name: string; label: string; description: string; model: string; unit: string;
                      source: string; dim: number | null; vectors: number; papers: number; default: boolean }
// Who the API is answering and what they may do: in the shared service the person signed in, with
// their roles' permissions and today's allowances (null: no limit); run for one person, everything.
export type Me = { name: string; email: string; via: 'local' | 'session' | 'token' | 'anonymous';
                   permissions: string[]; quotas: Record<string, number | null>; admin?: string | null }
// `build`: the site's build served; `building`: how long a new one has been building (seconds).
export type Status = { papers: number; processed: number; passages: number;
                       keyword: { default: boolean; description: string }; layers: Layer[];
                       cannot: Record<string, Record<string, string[]>>; me?: Me;
                       build?: string; building?: number | null }

// The knowledge base API that serves this site, set by docs/make.jl.
declare const __KB_API__: string
export const api = ref(__KB_API__)
export const mode = ref<'checking' | 'live' | 'static'>('checking')
export const status = ref<Status | null>(null)
export const me = computed<Me | null>(() => status.value?.me ?? null)
// Whether the person may do what `permission` allows (see PERMISSIONS in src/accounts.jl). Run for one
// person, the knowledge base answers with every permission.
export const can = (permission: string) => !!me.value?.permissions.includes(permission)
// Whether this is the shared service, with accounts, rather than the knowledge base of whoever runs it.
export const shared = computed(() => !!me.value && me.value.via !== 'local')

// Where the shared service signs people in, to come back to this page.
export const signInUrl = () =>
  `${api.value}/auth/sign-in?return_to=${encodeURIComponent(location.pathname + location.search + location.hash)}`

async function fetchWithin(url: string, ms: number) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), ms)
  try { return await fetch(url, { signal: ctl.signal }) } finally { clearTimeout(timer) }
}

// A status request that fails for a while, as while the service starts (or a connection drops), is
// asked again every `every` ms for up to `within` ms, the pages saying they are connecting meanwhile.
// An answer without the API, as a static copy of the site gives, means there is none.
export const RECONNECT = { every: 3000, within: 120_000 }

// One status request however many components ask; `retry` asks again.
let pending: Promise<void> | null = null
export function connect(retry = false): Promise<void> {
  if (pending && !retry) return pending
  mode.value = 'checking'
  pending = (async () => {
    const until = Date.now() + RECONNECT.within
    for (;;) {
      let passing = false
      try {
        const r = await fetchWithin(`${api.value}/api/status`, 10_000)
        if (r.ok) { status.value = await r.json(); mode.value = 'live'; break }
        // The shared service, not signed in: its sign-in, returning here. (A built site is behind the
        // sign-in already; under `zemi dev --shared` the pages are the development server's.)
        if (r.status === 401) { location.href = signInUrl(); return }
        passing = r.status >= 500
      } catch { passing = true }
      if (!passing || Date.now() + RECONNECT.every > until) break
      await new Promise(done => setTimeout(done, RECONNECT.every))
    }
    if (mode.value !== 'live') mode.value = 'static'
    document.documentElement.classList.toggle('kb-live', mode.value === 'live')
  })()
  return pending
}

// Ask for the status again (the top bar's build, what the person may do), keeping the last on failure.
export async function refreshStatus() {
  try { status.value = await getJSON('/api/status') } catch { /* the API is away for a moment */ }
}

// Why this machine cannot run an action on these documents (none when it can), as the API reports it.
export function blockers(action: string, ids: string[]): string[] {
  const c = status.value?.cannot?.[action]
  if (!c) return []
  return [...new Set(ids.flatMap(id => c[documentKind(id) ?? ''] ?? []))]
}

// ── Requests ─────────────────────────────────────────────────────────────────────────────────────

// A request refused or failed: the message the API gave (or the status, for an answer without one).
export class RequestError extends Error {
  status: number
  // A document dropped here, when that is why the request was refused (409).
  dropped?: { id: string; title: string; kind: string; by: string; at: string; why: string }
  constructor(message: string, status: number, dropped?: RequestError['dropped']) { super(message); this.status = status; this.dropped = dropped }
}

// An answer's JSON, or a RequestError.
async function answer(r: Response) {
  if (r.status === 204) return null
  const body = await r.json().catch(() => null)
  if (!r.ok) throw new RequestError(body?.error ?? `HTTP ${r.status}${r.statusText ? ` ${r.statusText}` : ''}`, r.status, body?.dropped)
  if (body === null) throw new Error(`${r.url}: not JSON (HTTP ${r.status})`)
  return body
}

// A GET of the API: its JSON.
export async function getJSON(path: string, init: { signal?: AbortSignal } = {}) {
  return answer(await fetch(`${api.value}${path}`, init))
}

// A change: it carries the header the API requires of writes, which a page elsewhere cannot send.
export async function post(path: string, body: BodyInit = '{}', contentType = 'application/json') {
  return answer(await fetch(`${api.value}${path}`, { method: 'POST', body, headers: { 'Content-Type': contentType, 'X-Zemi': '1' } }))
}

// One of the site's own JSON files (`/papers.json`), built with it: what a static copy of the site has.
export async function siteJSON(path: string, init: RequestInit = {}) {
  return answer(await fetch(withBase(path), init))
}

// The API's answer while it is live, else the site's copy of it as last built. While the site
// rebuilds its files are briefly not served, so a failed load is tried again, `tries` times in all.
export async function liveOrSite(apiPath: string, file: string, tries = 6) {
  for (let i = 1; ; i++) {
    try { return mode.value === 'live' ? await getJSON(apiPath) : await siteJSON(file, { cache: 'no-store' }) }
    catch (e) { if (i >= tries) throw e; await new Promise(done => setTimeout(done, 5000)) }
  }
}

/** Sign out of the shared service, and go to its sign-in. */
export async function signOut() {
  await post('/auth/sign-out')
  location.href = `${api.value}/auth/sign-in`
}

// An answer to a request that a later one of its kind replaced (see `latest`).
class Stale extends Error { constructor() { super('replaced by a later request') } }
export const isStale = (e: unknown) => e instanceof Stale || (e instanceof DOMException && e.name === 'AbortError')

// Requests of one kind of which only the latest counts, such as opening one task of several clicked
// in turn: asking aborts the one before, whose answer then throws `isStale` instead of arriving.
// `cancel()` drops the one on its way, as when what it was for is closed.
export function latest() {
  let ctl: AbortController | null = null
  const ask = async <T>(request: (signal: AbortSignal) => Promise<T>): Promise<T> => {
    ctl?.abort()
    const mine = (ctl = new AbortController())
    const v = await request(mine.signal)
    if (mine.signal.aborted) throw new Stale()
    return v
  }
  return Object.assign(ask, { cancel: () => { ctl?.abort(); ctl = null } })
}

// ── A component's life ───────────────────────────────────────────────────────────────────────────

// Start what a component does with the API once it answers, only if the component is still there
// then: `start` may return a function that stops it (a timer, a listener), run when the component
// goes. Registered before any wait, so nothing it starts outlives the page.
export function onLive(start: () => void | (() => void) | Promise<void | (() => void)>) {
  let alive = true
  let stop: void | (() => void)
  onMounted(async () => {
    await connect()
    if (!alive || mode.value !== 'live') return
    stop = await start()
    if (!alive) stop?.()
  })
  onBeforeUnmount(() => { alive = false; stop?.() })
}

// Run `step` again `ms` after each run ends (or after what `ms()` says then), never two at once,
// until the returned function stops it.
export function every(ms: number | (() => number), step: () => Promise<unknown> | unknown): () => void {
  let timer: ReturnType<typeof setTimeout> | undefined
  let stopped = false
  const run = async () => {
    try { await step() } catch { /* the next run tries again */ }
    if (!stopped) timer = setTimeout(run, typeof ms === 'function' ? ms() : ms)
  }
  timer = setTimeout(run, typeof ms === 'function' ? ms() : ms)
  return () => { stopped = true; clearTimeout(timer) }
}

// ── Jobs ─────────────────────────────────────────────────────────────────────────────────────────

export type Job = { id: string; name: string; status: string; message: string; elapsed: string; ids: string[];
                    result: string | null; error: string | null }
export const jobs = ref<Job[]>([])
// Bumped whenever a job finishes, so lists of documents know to load again.
export const finishedJobs = ref(0)

let polling: ReturnType<typeof setInterval> | undefined
const watched = new Set<string>()
// The jobs: all of them where the person may see them (jobs.view), else each one they started.
async function jobList(): Promise<Job[]> {
  try { return await getJSON('/api/jobs') } catch { /* not theirs to see: only their own */ }
  const own = await Promise.all([...watched].map(id => getJSON(`/api/jobs/${id}`).catch(() => null)))
  return own.filter((j): j is Job => j !== null)
}
async function poll() {
  try {
    const list = await jobList()
    jobs.value = list.slice(0, 12)
    for (const id of [...watched]) {
      const j = list.find(x => x.id === id)
      if (!j || j.status !== 'running') { watched.delete(id); finishedJobs.value++ }
    }
    if (!list.some(j => j.status === 'running') && !watched.size) { clearInterval(polling); polling = undefined }
  } catch { clearInterval(polling); polling = undefined }
}
// Record papers by their arXiv ids, as a job followed here: found by search and placed in the
// landscape, and read in full later (a sync reading unread papers, or Manage). `source` is how they came.
export async function recordPapers(ids: string[], source: string) {
  const r = await post('/api/documents', JSON.stringify({ arxiv: ids.join(' '), read: false, source }))
  followJobs(r.job)
  return r
}

// Follow jobs until none is running. Pass the id of a job just started to be told when it ends
// (through `finishedJobs`), however quickly it does. Resolves once the job list has been read.
export function followJobs(id?: string): Promise<void> {
  if (id) watched.add(id)
  const first = poll()
  if (!polling) polling = setInterval(poll, 1500)
  return first
}

// ── Files ────────────────────────────────────────────────────────────────────────────────────────

export type Media = { hash: string; name: string; type: string; size: number; address: string }

/** Upload a file to keep with what is written in `project` (see src/media.jl), reporting the share sent so far. */
export function uploadMedia(file: File, progress: (share: number) => void = () => {}, project = ''): Promise<Media> {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest()
    x.open('POST', `${api.value}/api/media?name=${encodeURIComponent(file.name)}${project ? `&project=${encodeURIComponent(project)}` : ''}`)
    x.setRequestHeader('Content-Type', file.type || 'application/octet-stream')
    x.setRequestHeader('X-Zemi', '1')
    x.upload.onprogress = e => e.lengthComputable && progress(e.loaded / e.total)
    x.onload = () => {
      const data = (() => { try { return JSON.parse(x.responseText) } catch { return {} } })()
      x.status < 300 ? resolve(data) : reject(new Error(data.error ?? `HTTP ${x.status}`))
    }
    x.onerror = () => reject(new Error('The upload failed'))
    x.send(file)
  })
}

/** Where a file's address in text (`media/<hash>/<name>`) is served from. */
export const mediaUrl = (address: string) => `${api.value}/api/${address}`
