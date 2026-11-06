<!--
  Managing the knowledge base's documents: find them by title, author or id, see how far each has
  been processed, and run any step again, for one document or a selection. A document whose access is
  set (a codebase, a record) is linked to projects and unlinked here.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted, watch } from 'vue'
import { mode, status, connect, post, getJSON, jobs, followJobs, finishedJobs, blockers, latest, isStale, type Job } from './kbApi'
import { kbPage } from './kbLinks'
import { isCodebase, hasAccess, isResource } from './kbKinds'
import { byline } from './kbFormat'
import KBJobs from './KBJobs.vue'

type Doc = { id: string; slug: string; page: string; title: string; authors: string[]; published: string; category: string; kind: string;
             access: 'open' | 'projects'; projects: string[]; posted: string; parsed: boolean; passages: number; layers: number; summaries: number }

const PAGE = 50
const q = ref('')
const state = ref('')
const offset = ref(0)
const total = ref(0)
const docs = ref<Doc[]>([])
const selected = ref<Set<string>>(new Set())
const loading = ref(false)
const error = ref('')

// `code`: what the action does for a codebase, where that differs; `access`: who sees a document,
// for kinds with access only (see src/document_access.jl).
type Action = { name: string; label: string; help: string; code?: string; access?: 'open' | 'projects' }
const ACTIONS: Action[] = [
  { name: 'ingest', label: 'Ingest', help: 'Fetch, parse, summarize and embed what is missing',
    code: 'Read the files again from the service\'s copy of the repository (current within 30 s); summarize and embed only those that changed. Linked codebases are also ingested nightly' },
  { name: 'reindex', label: 'Reindex', help: 'Parse and embed again',
    code: 'Read every file again, even when none changed; summarize and embed what differs' },
  { name: 'resummarize', label: 'Re-summarize', help: 'Summarize and embed again',
    code: 'Write every file\'s summary again, as for a new summary format, and embed them' },
  { name: 'classify', label: 'Classify', help: 'Set category (uploads: also authors, year, abstract)' },
  { name: 'refresh', label: 'Refresh metadata', help: 'Refetch the arXiv record, or reread an upload\'s metadata' },
  { name: 'share', label: 'Share', help: 'Include in the published dataset' },
  { name: 'unshare', label: 'Unshare', help: 'Exclude from the published dataset' },
  { name: 'open', label: 'Open to all', help: 'Let every reader see the document', access: 'open' },
  { name: 'close', label: 'Projects only', help: 'Let only the members of the projects linked to the document see it', access: 'projects' },
  { name: 'remove', label: 'Remove', help: 'Delete the document, its text, summaries and vectors' },
]

// Typing and paging ask in turn: the list shown answers the last.
const listing = latest()
async function load() {
  if (mode.value !== 'live') return
  loading.value = true; error.value = ''
  try {
    const params = new URLSearchParams({ q: q.value, state: state.value, limit: String(PAGE), offset: String(offset.value) })
    const data = await listing(signal => getJSON(`/api/documents?${params}`, { signal }))
    docs.value = data.documents; total.value = data.total
  } catch (e: any) {
    if (isStale(e)) return
    error.value = `Load failed: ${e.message ?? e}`
  }
  loading.value = false
}
// A document's page links here with `?id=`, to open with that document found and selected.
onMounted(async () => {
  const asked = new URLSearchParams(location.search)
  const id = asked.get('id')
  if (asked.get('state')) state.value = asked.get('state')!
  if (id) { q.value = id; selected.value = new Set([id]) }
  await connect(); followJobs(); load()
  try { projects.value = (await getJSON('/api/projects')).projects.map((p: { key: string }) => p.key) } catch { /* linking waits for the list */ }
})

// The projects a document may be linked to, and linking or unlinking one.
const projects = ref<string[]>([])
async function link(d: Doc, key: string, remove = false) {
  if (!key) return
  error.value = ''
  try { d.projects = (await post(`/api/documents/${encodeURIComponent(d.id)}/projects`, JSON.stringify({ project: key, remove }))).projects }
  catch (e: any) { error.value = e.message ?? String(e) }
}
let timer: ReturnType<typeof setTimeout> | undefined
watch([q, state], () => { clearTimeout(timer); timer = setTimeout(() => { offset.value = 0; load() }, 250) })
watch(offset, load)
watch(finishedJobs, load)

function toggle(id: string) {
  const s = new Set(selected.value)
  s.has(id) ? s.delete(id) : s.add(id)
  selected.value = s
}
const allShown = computed(() => docs.value.length > 0 && docs.value.every(d => selected.value.has(d.id)))
function toggleAll() {
  const s = new Set(selected.value)
  allShown.value ? docs.value.forEach(d => s.delete(d.id)) : docs.value.forEach(d => s.add(d.id))
  selected.value = s
}

async function run(action: string, ids: string[]) {
  if (!ids.length) return
  if (action === 'remove' && !confirm(`Remove ${ids.length === 1 ? ids[0] : `${ids.length} documents`}?`)) return
  error.value = ''
  const access = ACTIONS.find(a => a.name === action)?.access
  if (access) {
    try { for (const id of ids) await post(`/api/documents/${encodeURIComponent(id)}/access`, JSON.stringify({ access })) }
    catch (e: any) { error.value = e.message ?? String(e) }
    return load()
  }
  try {
    const r = await post('/api/actions', JSON.stringify({ action, ids }))
    followJobs(r.job)
    if (action === 'remove') selected.value = new Set([...selected.value].filter(id => !ids.includes(id)))
  } catch (e: any) { error.value = e.message ?? String(e) }
}

// A resource's PDF, uploaded to read it in full: the paper it becomes takes its place.
async function promote(e: Event, id: string) {
  const file = (e.target as HTMLInputElement).files?.[0]
  if (!file) return
  error.value = ''
  try { await post(`/api/resources/${encodeURIComponent(id)}/pdf`, file, 'application/pdf'); await load() }
  catch (err: any) { error.value = err.message ?? String(err) }
}

function rowAction(e: Event, id: string) {
  const menu = e.target as HTMLSelectElement
  const action = menu.value
  menu.value = ''
  if (action) run(action, [id])
}

// The running job, if any, that is working on each document.
const working = computed(() => {
  const m = new Map<string, Job>()
  for (const j of jobs.value) if (j.status === 'running') for (const id of j.ids ?? []) m.set(id, j)
  return m
})

// What this machine cannot do, said once above the list: the actions concerned are greyed out.
const unavailable = computed(() => [...new Set(Object.values(status.value?.cannot ?? {}).flatMap(c => Object.values(c).flat()))])
const codebases = (ids: string[]) => ids.length > 0 && ids.every(isCodebase)
const settable = (ids: string[]) => ids.length > 0 && ids.every(hasAccess)
const tip = (a: Action, ids: string[]) => {
  const why = blockers(a.name, ids)
  const help = a.code && codebases(ids) ? a.code : a.help
  return a.access && !settable(ids) ? `${help}. Only for documents whose access is set: codebases and records` : why.length ? `${help}. Unavailable here: ${why.join('; ')}` : help
}
// Whether an action cannot be run on these documents here.
const barred = (a: Action, ids: string[]) => blockers(a.name, ids).length > 0 || (!!a.access && !settable(ids))

const stateOf = (d: Doc) => d.parsed ? 'full text' : 'abstract only'
const who = (d: Doc) => byline(d.authors)
</script>

<template>
  <div class="kbm">
    <KBNeedsService>
      <div class="kbm-filters">
        <input v-model="q" type="search" class="kb-field kbm-input" placeholder="Title, author or id…" />
        <select v-model="state" class="kbm-select">
          <option value="">every document</option>
          <option value="read">full text</option>
          <option value="recorded">abstract only</option>
          <option value="unsummarized">no summaries</option>
          <option value="unembedded">not embedded</option>
          <option value="uploaded">uploaded PDFs</option>
          <option value="code">codebases</option>
          <option value="record">records</option>
        </select>
      </div>
      <p v-if="unavailable.length" class="kbm-dim kbm-unavailable">
        Unavailable here: {{ unavailable.join('; ') }}.
      </p>
      <div class="kbm-bar">
        <span>{{ total }} documents<span v-if="selected.size"> · {{ selected.size }} selected</span></span>
        <template v-if="selected.size">
          <button v-for="a in ACTIONS" :key="a.name" type="button" :title="tip(a, [...selected])"
                  :disabled="barred(a, [...selected])"
                  :class="['kbm-action', { danger: a.name === 'remove' }]" @click="run(a.name, [...selected])">{{ a.label }}</button>
          <button type="button" class="kb-link" @click="selected = new Set()">clear</button>
        </template>
      </div>
      <p v-if="error" class="kb-error kbm-error">{{ error }}</p>
      <KBJobs />
      <table class="kbm-table">
        <thead>
          <tr>
            <th><input type="checkbox" :checked="allShown" @change="toggleAll" /></th>
            <th>Document</th><th>Category</th><th>State</th><th>Posted</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="d in docs" :key="d.id" :class="{ picked: selected.has(d.id), busy: working.has(d.id) }">
            <td><input type="checkbox" :checked="selected.has(d.id)" @change="toggle(d.id)" /></td>
            <td>
              <a :href="kbPage(d.page)"><KBTitle :text="d.title" /></a>
              <div class="kbm-dim">{{ who(d) }}<span v-if="who(d)"> · </span><code>{{ d.id }}</code>
                <span v-if="d.access === 'projects'"> · its projects only</span>
                <template v-if="isResource(d.id)"> · <label class="kb-link kbm-upload">upload its PDF
                  <input type="file" accept="application/pdf" @change="promote($event, d.id)" /></label></template></div>
              <div v-if="hasAccess(d.id)" class="kbm-dim kbm-projects">
                <template v-if="d.projects.length">linked to
                  <span v-for="k in d.projects" :key="k">{{ k }}<button type="button" class="kb-link" :title="`Unlink ${k}`"
                        @click="link(d, k, true)">×</button></span></template>
                <template v-else>linked to no project</template>
                <select class="kbm-select small" @change="link(d, ($event.target as HTMLSelectElement).value); ($event.target as HTMLSelectElement).value = ''">
                  <option value="">link…</option>
                  <option v-for="k in projects.filter(k => !d.projects.includes(k))" :key="k" :value="k">{{ k }}</option>
                </select>
              </div>
            </td>
            <td class="kbm-dim">{{ d.category }}</td>
            <td>
              <template v-if="working.has(d.id)">
                <span class="kbm-state working">working</span>
                <div class="kbm-dim">{{ working.get(d.id)?.message }}</div>
              </template>
              <template v-else>
                <span :class="['kbm-state', d.parsed ? 'read' : 'recorded']">{{ stateOf(d) }}</span>
                <div v-if="d.parsed" class="kbm-dim">{{ d.passages }} passages · {{ d.summaries }} summaries ·
                  {{ d.layers ? `${d.layers} layers` : 'not embedded' }}</div>
              </template>
            </td>
            <td class="kbm-dim">{{ d.posted }}</td>
            <td>
              <select class="kbm-select small" @change="rowAction($event, d.id)">
                <option value="">actions…</option>
                <option v-for="a in ACTIONS" :key="a.name" :value="a.name" :title="tip(a, [d.id])"
                        :disabled="barred(a, [d.id])">{{ a.label }}</option>
              </select>
            </td>
          </tr>
        </tbody>
      </table>
      <div class="kbm-pages" v-if="total > PAGE">
        <button type="button" class="kb-link" :disabled="offset === 0" @click="offset = Math.max(0, offset - PAGE)">previous</button>
        <span class="kbm-dim">{{ offset + 1 }}–{{ Math.min(offset + PAGE, total) }} of {{ total }}</span>
        <button type="button" class="kb-link" :disabled="offset + PAGE >= total" @click="offset += PAGE">next</button>
      </div>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbm { margin: 1rem 0 2rem; font-size: 0.9rem; }
.kbm-filters { display: flex; gap: 0.6rem; }
.kbm-upload { cursor: pointer; }
.kbm-upload input { display: none; }
.kbm-input { flex: 1; padding: 0.5rem 0.8rem; border-radius: 8px; }
.kbm-select { padding: 0.4rem 0.5rem; font: inherit; border: 1px solid var(--vp-c-divider); border-radius: 8px;
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbm-select.small { font-size: 0.8rem; padding: 0.2rem 0.3rem; }
.kbm-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; margin: 0.8rem 0 0.4rem; color: var(--vp-c-text-2); }
.kbm-action { padding: 0.2rem 0.6rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-1); font: inherit; font-size: 0.82rem; cursor: pointer; }
.kbm-action:hover:not(:disabled) { border-color: var(--vp-c-brand-1); }
.kbm-action:disabled { opacity: 0.4; cursor: default; }
.kbm-unavailable { margin: 0.6rem 0 0; }
.kbm-action.danger { color: var(--vp-c-danger-1); }
.kbm-table { width: 100%; display: table; margin-top: 0.4rem; }
.kbm-table td, .kbm-table th { vertical-align: top; padding: 0.4rem 0.5rem; }
.kbm-table tr.picked { background: var(--vp-c-brand-soft); }
.kbm-state { display: inline-block; padding: 0 0.4rem; border-radius: 4px; font-size: 0.75rem; background: var(--vp-c-default-soft); }
.kbm-state.read { background: var(--vp-c-green-soft); color: var(--vp-c-green-1); }
.kbm-state.working { background: var(--vp-c-yellow-soft); color: var(--vp-c-yellow-1); animation: kbm-pulse 1.6s ease-in-out infinite; }
@keyframes kbm-pulse { 50% { opacity: 0.55; } }
.kbm-table tr.busy td:first-child { box-shadow: inset 3px 0 var(--vp-c-yellow-1); }
.kbm-dim { color: var(--vp-c-text-3); font-size: 0.8rem; }
.kbm-pages { display: flex; gap: 1rem; align-items: center; margin-top: 0.6rem; }
.kb-link:disabled { opacity: 0.4; cursor: default; }
</style>
