<!--
  The palette, on Cmd-K or Ctrl-K anywhere on the site while the knowledge base's service answers (a
  static copy keeps VitePress's own search): what was opened from it lately; as one types, what the
  knowledge base has of it (tasks, findings, papers and resources, records, notebooks, code), each to
  whoever may see it; and commands: search the knowledge base for the words, add the paper an arXiv
  id, DOI or address names, open a project, go to a page, switch between light and dark, sync now.
  ↑↓ choose, Enter opens, Esc closes.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted, onBeforeUnmount } from 'vue'
import { useData, useRouter } from 'vitepress'
import { taskResults, type TaskSearchHit } from './kbTaskResults'
import { markedSnippet } from './kbUtils'
import KBDialog from './KBDialog.vue'
import { mode, connect, can, shared, me, getJSON, post, followJobs } from './kbApi'
import { kbPage, pageLink } from './kbLinks'
import { href as refHref, type RefMatch } from './kbRefs'

type Item = { key: string; label: string; detail: string; group: string; snippet?: string; href?: string; run?: () => Promise<void> | void }

const props = defineProps<{ screenMenu?: boolean }>()
const open = ref(false)
const q = ref('')
const boardProject = ref('')
const project = ref('')
const commandsOnly = computed(() => q.value.startsWith('>'))
const terms = computed(() => (commandsOnly.value ? q.value.slice(1) : q.value).trim())
const selectedKey = ref<string | null>(null)
const found = ref<Item[]>([])
const lookup = ref<'idle' | 'loading' | 'done' | 'failed'>('idle')
const retry = ref(0)
const projects = ref<{ key: string; name: string }[]>([])
const said = ref('')
const input = ref<HTMLInputElement | null>(null)
const { isDark } = useData()
const router = useRouter()

// What was opened from it lately, kept in this browser.
const recentKey = () => shared.value ? 'kb-palette-recent:' + me.value?.id : 'kb-palette-recent'
const recent = ref<{ label: string; detail: string; href: string }[]>([])
const remember = (i: Item) => {
  if (!i.href) return
  recent.value = [{ label: i.label, detail: i.detail, href: i.href }, ...recent.value.filter(r => r.href !== i.href)].slice(0, 8)
  try { localStorage.setItem(recentKey(), JSON.stringify(recent.value)) } catch { /* storage is optional */ }
}

// The pages: the knowledge base's, the projects and findings, and the service's pages one's roles open.
const pages = computed(() => [
  ['Search', kbPage('index')], ['Paper of the Day', kbPage('daily')], ['Landscape', kbPage('landscape')], ['Explore', kbPage('explore')], ['Topics', kbPage('topics')],
  ['Authors', kbPage('authors')], ['Missing papers', kbPage('missing')], ['Paper watch', kbPage('watch')], ['Timeline', kbPage('timeline')],
  ['Status', kbPage('status')], ['Documents', kbPage('manage')], ['Codebases', kbPage('code/')],
  ['Projects', pageLink('/projects')], ['Findings', pageLink('/findings')],
  ...(shared.value ? [['Account', pageLink('/service/account')]] : []),
  ...(can('server.view') ? [['Operations', pageLink('/service/operations')]] : []),
  ...(can('config.view') ? [['Configuration', pageLink('/service/configuration')]] : []),
  ...(shared.value && (can('users.manage') || can('tokens.manage') || can('audit.view')) ? [['Administration', pageLink('/service/administration')]] : []),
] as [string, string][])

const KIND_LABEL: Record<string, string> = { task: 'Task', finding: 'Finding', paper: 'Paper', record: 'Record', author: 'Author',
                                             notebook: 'Notebook', code: 'Code' }
// An arXiv id, a DOI or a web address: something the knowledge base can add.
const addable = (s: string) => /^(arxiv:)?\d{4}\.\d{4,5}(v\d+)?$/i.test(s) || /^(doi:|https?:\/\/(dx\.)?doi\.org\/)?10\.\d{4,9}\/\S+$/i.test(s) || /^https?:\/\/\S+$/i.test(s)
const matches = (label: string) => { const w = terms.value.toLowerCase(); return !w || label.toLowerCase().includes(w) }

const items = computed<Item[]>(() => {
  const w = terms.value
  const out: Item[] = []
  if (!commandsOnly.value && !w) out.push(...recent.value.map(r => ({ key: `r${r.href}`, label: r.label, detail: r.detail, group: 'Lately', href: r.href })))
  if (!commandsOnly.value) out.push(...found.value)
  if (commandsOnly.value && w && addable(w) && can('paper.add')) out.push({ key: 'add', label: `Add ${w} to the knowledge base`, detail: 'Fetched and read in full', group: 'Commands',
    run: async () => {
      const r = await post('/api/documents', JSON.stringify({ arxiv: w }))
      followJobs(r.job)
      said.value = r.already?.length ? `Already here: ${r.already.join(', ')}` : `Adding ${r.ids.join(', ')}`
    } })
  if (commandsOnly.value && matches(isDark.value ? 'light theme' : 'dark theme')) out.push({ key: 'theme', label: isDark.value ? 'Light theme' : 'Dark theme',
    detail: 'Switch the site\'s colors', group: 'Commands', run: () => { isDark.value = !isDark.value } })
  if (commandsOnly.value && can('sync') && matches('sync now')) out.push({ key: 'sync', label: 'Sync now', detail: 'Bring the knowledge base up to date', group: 'Commands',
    run: async () => { followJobs((await post('/api/sync', '{}')).job); said.value = 'Syncing' } })
  if (!commandsOnly.value && !project.value && w) out.push(...projects.value.filter(p => matches(`${p.key} ${p.name}`))
    .map(p => ({ key: `p${p.key}`, label: `${p.key} ${p.name}`, detail: 'Open the project', group: 'Projects', href: `${pageLink('/projects')}#${p.key}` })))
  if (commandsOnly.value || (w && !project.value)) out.push(...pages.value.filter(([label]) => matches(label)).map(([label, href]) => ({ key: `g${href}`, label, detail: 'Go to the page', group: 'Pages', href })))
  return out
})
const chosen = computed(() => {
  const index = items.value.findIndex(i => i.key === selectedKey.value)
  return index < 0 && commandsOnly.value && items.value.length ? 0 : index
})
const groups = computed(() => {
  const g: { name: string; items: (Item & { n: number })[] }[] = []
  items.value.forEach((i, n) => { const last = g[g.length - 1]; last?.name === i.group ? last.items.push({ ...i, n }) : g.push({ name: i.group, items: [{ ...i, n }] }) })
  return g
})

// What the knowledge base has of the words: the answer to the last asked.
type Suggestions = {
  hits: { id: string; title: string; page: string; kind: string; passages?: { text: string }[] }[]
  findings: { ref: string; claim: string; snippet: string }[]
  tasks?: TaskSearchHit[]
  references?: RefMatch[]
}
const allResults = computed<Item>(() => ({ key: 'search', label: `All results for “${terms.value}”`, detail: '', group: '',
  href: `${kbPage('index')}?q=${encodeURIComponent(terms.value)}${project.value ? '&project=' + encodeURIComponent(project.value) : ''}` }))
watch([q, open, retry, project, mode], ([, visible], _, cleanup) => {
  selectedKey.value = null
  said.value = ''
  found.value = []
  lookup.value = 'idle'
  const w = terms.value
  if (!visible || commandsOnly.value || !w || mode.value !== 'live') return
  const controller = new AbortController()
  const options = { signal: controller.signal }
  lookup.value = 'loading'
  const timer = setTimeout(async () => {
    const query = encodeURIComponent(w)
    try {
      const data: Suggestions = await getJSON(`/api/search?q=${query}&view=suggestions&project=${encodeURIComponent(project.value)}&layers=none&keyword=1&limit=5`, options)
      const refs = data.references ?? []
      if (controller.signal.aborted) return
      const rows: Item[] = []
      const add = (href: string, label: string, detail: string, snippet = '') => {
        if (href && !rows.some(r => r.href === href)) rows.push({ key: href, href, label, detail, snippet, group: 'Results' })
      }
      const refItem = (r: RefMatch) => add(refHref(r.kind, r.target), r.label === r.target && r.detail ? r.detail : r.label,
        `${KIND_LABEL[r.kind] ?? r.kind} · ${r.target}`)
      for (const r of refs.filter(r => r.target.toLowerCase() === w.toLowerCase())) refItem(r)
      for (const t of taskResults(data.tasks ?? [], w)) add(t.href, t.label, t.detail, t.snippet)
      for (const f of data.findings) add(refHref('finding', f.ref), f.claim, 'Finding · ' + f.ref, f.snippet)
      for (const h of data.hits) add(kbPage(h.page), h.title, `${KIND_LABEL[h.kind] ?? h.kind} · ${h.id}`, h.passages?.[0]?.text)
      for (const r of refs) refItem(r)
      found.value = rows
      lookup.value = 'done'
    } catch {
      if (!controller.signal.aborted) lookup.value = 'failed'
    }
  }, 160)
  cleanup(() => { clearTimeout(timer); controller.abort() })
})

async function show(commands: boolean) {
  const onBoard = location.pathname === pageLink('/projects')
  boardProject.value = onBoard ? (/^#([a-z][a-z0-9]*)/i.exec(location.hash)?.[1]?.toUpperCase() ?? '') : ''
  project.value = ''
  open.value = true; q.value = commands ? '>' : ''; said.value = ''
  selectedKey.value = null
  try {
    const stored = JSON.parse(localStorage.getItem(recentKey()) ?? '[]')
    recent.value = Array.isArray(stored) ? stored.filter(r => r && typeof r.href === 'string' && r.href.startsWith('/') && !r.href.startsWith('//')) : []
  } catch { recent.value = [] }
  await nextTick(); input.value?.focus()
}
watch([open, mode, commandsOnly], async ([visible, service, commands], _, cleanup) => {
  if (!visible || commands) return
  if (service === 'static') {
    open.value = false
    if (terms.value) await router.go(allResults.value.href!)
    else document.querySelector<HTMLButtonElement>('.VPNavBarSearch .DocSearch-Button')?.click()
    return
  }
  if (service !== 'live' || !can('tasks.view')) return
  const ctl = new AbortController()
  cleanup(() => ctl.abort())
  try {
    const data = await getJSON('/api/projects', { signal: ctl.signal })
    if (!ctl.signal.aborted) projects.value = data.projects
  } catch { if (!ctl.signal.aborted) projects.value = [] }
})
async function pick(i: Item | undefined) {
  if (!i) return
  try {
    if (i.run) { await i.run(); if (!said.value) open.value = false; return }
    remember(i); open.value = false
    const target = new URL(i.href!, location.href)
    if (target.hash && target.pathname === location.pathname && target.search === location.search) location.hash = target.hash
    else await router.go(target.href)
  } catch (e: any) { said.value = e.message ?? String(e) }
}
function key(e: KeyboardEvent) {
  const n = items.value.length
  if (e.isComposing) return
  if (!n && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) { e.preventDefault(); return }
  if (e.key === 'ArrowDown') { selectedKey.value = items.value[(chosen.value + 1) % n].key; e.preventDefault() }
  else if (e.key === 'ArrowUp') { selectedKey.value = items.value[chosen.value <= 0 ? n - 1 : chosen.value - 1].key; e.preventDefault() }
  else if (e.key === 'Enter') { pick(!commandsOnly.value && terms.value && chosen.value < 0 ? allResults.value : items.value[chosen.value]); e.preventDefault() }
}
watch(chosen, async c => { await nextTick(); document.querySelector(`[data-palette="${c}"]`)?.scrollIntoView({ block: 'nearest' }) })

// The same header button serves the live palette and the static site's built-in search.
function onSearchClick(e: MouseEvent) {
  if (mode.value === 'static' || !(e.target instanceof Element) || !e.target.closest('.VPNavBarSearch .DocSearch-Button')) return
  e.preventDefault(); e.stopImmediatePropagation()
  show(false)
}
function onKey(e: KeyboardEvent) {
  if (mode.value === 'static' || e.altKey || e.isComposing) return
  const mod = e.metaKey || e.ctrlKey
  const slash = e.key === '/' && !mod && !(e.target as Element)?.closest('input, textarea, select, [contenteditable=true]')
  if (slash && document.querySelector('.kbts-field')) return
  const quick = slash || mod && !e.shiftKey && e.key.toLowerCase() === 'k'
  const commands = (mod && e.shiftKey && e.key.toLowerCase() === 'p') || (!mod && !e.shiftKey && e.key === 'F1')
  if (!quick && (!commands || mode.value !== 'live')) return
  e.preventDefault(); e.stopImmediatePropagation()
  if (e.repeat) return
  if (open.value && commandsOnly.value === commands) open.value = false
  else show(commands)
}
onMounted(() => {
  connect()
  if (props.screenMenu) return
  window.addEventListener('keydown', onKey, true)
  window.addEventListener('click', onSearchClick, true)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey, true)
  window.removeEventListener('click', onSearchClick, true)
})
</script>

<template>
  <KBDialog v-if="open" :label="commandsOnly ? 'Command palette' : 'Search Zemi'" width="min(42rem, 94vw)" top bare :shade="0.35" @close="open = false">
    <div class="kbpal">
      <h2 class="kbpal-title">{{ commandsOnly ? 'Command palette' : 'Search Zemi' }}</h2>
      <input ref="input" v-model="q" class="kbpal-input" :placeholder="commandsOnly ? 'Type a command or page name…' : 'Search by name, reference or words…'"
             :aria-label="commandsOnly ? 'Filter commands' : 'Search Zemi'" role="combobox" aria-expanded="true" aria-autocomplete="list"
             aria-controls="kbpal-results" :aria-activedescendant="items[chosen] ? 'kbpal-item-' + chosen : undefined"
             @keydown="key" />
      <label v-if="boardProject && !commandsOnly" class="kbpal-scope">
        <input v-model="project" type="checkbox" :true-value="boardProject" false-value="" @change="input?.focus()"> In project {{ boardProject }}
      </label>
      <div id="kbpal-results" class="kbpal-list" role="listbox" aria-label="Results">
        <template v-for="g in groups" :key="g.name">
          <div class="kbpal-group">{{ g.name }}</div>
          <button v-for="i in g.items" :key="i.key" :id="'kbpal-item-' + i.n" type="button" role="option" tabindex="-1" class="kbpal-item" :class="{ on: i.n === chosen }"
                  :aria-selected="i.n === chosen" :data-palette="i.n" @click="pick(i)">
            <span class="kbpal-label">{{ i.label }}<span v-if="i.snippet" class="kbpal-snippet" v-html="markedSnippet(i.snippet)"></span></span><span class="kbpal-detail">{{ i.detail }}</span>
          </button>
        </template>
      </div>
      <p v-if="!commandsOnly" class="kbpal-status" role="status">
        <template v-if="mode === 'checking'">Connecting to Zemi…</template>
        <template v-else-if="lookup === 'loading'">Searching…</template>
        <template v-else-if="lookup === 'failed'">Search unavailable. <button type="button" @click="retry++">Retry</button></template>
        <template v-else-if="lookup === 'done' && !items.length">No results for “{{ terms }}”.</template>
        <template v-else-if="!terms && !recent.length">Type to search, or enter &gt; for commands.</template>
      </p>
      <p v-if="commandsOnly && !items.length" class="kbpal-none">No matching commands or pages.</p>
      <div class="kbpal-foot">
        <button v-if="!commandsOnly && terms" type="button" @click="pick(allResults)">View all results</button>
        <span role="status">{{ said }}</span><span class="kbpal-keys">↑↓ choose · {{ !commandsOnly && terms && chosen < 0 ? 'Enter all results' : 'Enter open' }} · Esc close</span>
      </div>
    </div>
  </KBDialog>
</template>

<style scoped>
.kbpal-scope { display: flex; align-items: center; gap: .4rem; padding: .35rem 1.1rem; color: var(--vp-c-text-2); font-size: .85rem; }
.kbpal-snippet { display: block; overflow: hidden; text-overflow: ellipsis; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbpal-status:not(:empty) { padding: 0.5rem 1.1rem; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbpal-status button, .kbpal-foot button { color: var(--vp-c-brand-1); }
.kbpal-item:hover { background: var(--vp-c-brand-soft); }
.kbpal-title { margin: 0; padding: 0.75rem 1.1rem 0; color: var(--vp-c-text-2); font-size: 0.8rem; font-weight: 600; }
.kbpal { margin-top: 12vh; border-radius: 14px; background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-5);
  overflow: hidden; font-size: 0.9rem; }
.kbpal-input { width: 100%; padding: 0.9rem 1.1rem; border: none; border-bottom: 1px solid var(--vp-c-divider); background: transparent;
  color: var(--vp-c-text-1); font: inherit; font-size: 1rem; outline: none; }
.kbpal-list { max-height: min(60vh, 32rem); overflow-y: auto; padding: 0.3rem 0; }
.kbpal-group { padding: 0.5rem 1.1rem 0.2rem; font-size: 0.72rem; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase;
  color: var(--vp-c-text-3); }
.kbpal-item { display: flex; align-items: baseline; gap: 0.8rem; width: 100%; padding: 0.45rem 1.1rem; border: none; background: none;
  color: var(--vp-c-text-1); font: inherit; text-align: left; cursor: pointer; }
.kbpal-item.on { background: var(--vp-c-brand-soft); }
.kbpal-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbpal-detail { flex: none; max-width: 45%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--vp-c-text-3); font-size: 0.8rem; }
.kbpal-none { padding: 0.6rem 1.1rem; color: var(--vp-c-text-3); }
.kbpal-foot { display: flex; gap: 1rem; padding: 0.45rem 1.1rem; border-top: 1px solid var(--vp-c-divider); font-size: 0.78rem; color: var(--vp-c-text-2); }
.kbpal-keys { margin-left: auto; color: var(--vp-c-text-3); }
@media (pointer: coarse) { .kbpal-keys { display: none; } }
</style>
