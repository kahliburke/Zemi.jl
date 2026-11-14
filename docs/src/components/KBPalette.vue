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
import KBDialog from './KBDialog.vue'
import { mode, connect, can, shared, getJSON, post, followJobs, latest, isStale } from './kbApi'
import { kbPage, pageLink, taskHref } from './kbLinks'
import { href as refHref, type RefMatch } from './kbRefs'

type Item = { key: string; label: string; detail: string; group: string; href?: string; run?: () => Promise<void> | void }

const open = ref(false)
const q = ref('')
const chosen = ref(0)
const found = ref<RefMatch[]>([])
const projects = ref<{ key: string; name: string }[]>([])
const said = ref('')
const input = ref<HTMLInputElement | null>(null)
const { isDark } = useData()
const router = useRouter()

// What was opened from it lately, kept in this browser.
const RECENT = 'kb-palette-recent'
const recent = ref<{ label: string; detail: string; href: string }[]>([])
const remember = (i: Item) => {
  if (!i.href) return
  recent.value = [{ label: i.label, detail: i.detail, href: i.href }, ...recent.value.filter(r => r.href !== i.href)].slice(0, 8)
  localStorage.setItem(RECENT, JSON.stringify(recent.value))
}

// The pages: the knowledge base's, the projects and findings, and the service's pages one's roles open.
const pages = computed(() => [
  ['Search', kbPage('index')], ['Paper of the Day', kbPage('daily')], ['Landscape', kbPage('landscape')], ['Topics', kbPage('topics')],
  ['Authors', kbPage('authors')], ['Missing papers', kbPage('missing')], ['New on arXiv', kbPage('watch')], ['Timeline', kbPage('timeline')],
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
const matches = (label: string) => { const w = q.value.trim().toLowerCase(); return !w || label.toLowerCase().includes(w) }

const items = computed<Item[]>(() => {
  const w = q.value.trim()
  const out: Item[] = []
  if (!w) out.push(...recent.value.map(r => ({ key: `r${r.href}`, label: r.label, detail: r.detail, group: 'Lately', href: r.href })))
  // What the knowledge base has: shown by its title (a task's, a paper's), with its kind and id beside it.
  out.push(...found.value.filter(r => r.kind !== 'person').map(r => {
    const href = r.kind === 'task' ? taskHref(r.target) : refHref(r.kind, r.target)
    const named = r.label === r.target && r.detail
    return { key: `f${r.kind}${r.target}`, label: named ? r.detail : r.label,
             detail: `${KIND_LABEL[r.kind] ?? r.kind} · ${named ? r.target : r.detail || r.target}`, group: 'In the knowledge base', href }
  }).filter(i => i.href))
  if (w && addable(w) && can('paper.add')) out.push({ key: 'add', label: `Add ${w} to the knowledge base`, detail: 'Fetched and read in full', group: 'Commands',
    run: async () => {
      const r = await post('/api/documents', JSON.stringify({ arxiv: w }))
      followJobs(r.job)
      said.value = r.already?.length ? `Already here: ${r.already.join(', ')}` : `Adding ${r.ids.join(', ')}`
    } })
  if (matches(isDark.value ? 'light theme' : 'dark theme')) out.push({ key: 'theme', label: isDark.value ? 'Light theme' : 'Dark theme',
    detail: 'Switch the site\'s colors', group: 'Commands', run: () => { isDark.value = !isDark.value } })
  if (can('sync') && matches('sync now')) out.push({ key: 'sync', label: 'Sync now', detail: 'Bring the knowledge base up to date', group: 'Commands',
    run: async () => { followJobs((await post('/api/sync', '{}')).job); said.value = 'Syncing' } })
  out.push(...projects.value.filter(p => matches(`${p.key} ${p.name}`))
    .map(p => ({ key: `p${p.key}`, label: `${p.key} ${p.name}`, detail: 'Open the project', group: 'Projects', href: `${pageLink('/projects')}#${p.key}` })))
  out.push(...pages.value.filter(([label]) => matches(label)).map(([label, href]) => ({ key: `g${href}`, label, detail: 'Go to the page', group: 'Pages', href })))
  // Last, as what Enter does when nothing else matches: the words searched for on the Search page.
  if (w) out.push({ key: 'search', label: `Search the knowledge base for “${w}”`, detail: 'Papers by meaning and words, and findings', group: 'Search',
                    href: `${kbPage('index')}?q=${encodeURIComponent(w)}` })
  return out
})
const groups = computed(() => {
  const g: { name: string; items: (Item & { n: number })[] }[] = []
  items.value.forEach((i, n) => { const last = g[g.length - 1]; last?.name === i.group ? last.items.push({ ...i, n }) : g.push({ name: i.group, items: [{ ...i, n }] }) })
  return g
})

// What the knowledge base has of the words: the answer to the last asked.
const asking = latest()
watch(q, async w => {
  chosen.value = 0; said.value = ''
  if (w.trim().length < 2 || !can('tasks.view')) { found.value = []; return }
  try { found.value = await asking(signal => getJSON(`/api/tasks/references?q=${encodeURIComponent(w.trim())}`, { signal })) }
  catch (e) { if (!isStale(e)) found.value = [] }
})

async function show() {
  open.value = true; q.value = ''; said.value = ''; chosen.value = 0
  try { recent.value = JSON.parse(localStorage.getItem(RECENT) ?? '[]') } catch { recent.value = [] }
  await nextTick(); input.value?.focus()
  if (can('tasks.view')) try { projects.value = (await getJSON('/api/projects')).projects } catch { /* none listed */ }
}
async function pick(i: Item | undefined) {
  if (!i) return
  try {
    if (i.run) { await i.run(); if (!said.value) open.value = false; return }
    remember(i); open.value = false
    i.href!.startsWith('http') ? (location.href = i.href!) : router.go(i.href!)
  } catch (e: any) { said.value = e.message ?? String(e) }
}
function key(e: KeyboardEvent) {
  const n = items.value.length
  if (e.key === 'ArrowDown') { chosen.value = n ? (chosen.value + 1) % n : 0; e.preventDefault() }
  else if (e.key === 'ArrowUp') { chosen.value = n ? (chosen.value - 1 + n) % n : 0; e.preventDefault() }
  else if (e.key === 'Enter') { pick(items.value[chosen.value]); e.preventDefault() }
}
watch(chosen, async c => { await nextTick(); document.querySelector(`[data-palette="${c}"]`)?.scrollIntoView({ block: 'nearest' }) })

// Cmd-K and Ctrl-K, taken before VitePress's search sees them while the service answers.
function onKey(e: KeyboardEvent) {
  if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'k' || e.altKey || e.shiftKey || mode.value !== 'live') return
  e.preventDefault(); e.stopImmediatePropagation()
  open.value ? (open.value = false) : show()
}
onMounted(() => { connect(); window.addEventListener('keydown', onKey, true) })
onBeforeUnmount(() => window.removeEventListener('keydown', onKey, true))
</script>

<template>
  <KBDialog v-if="open" label="Go to or do" width="min(42rem, 94vw)" top bare :shade="0.35" @close="open = false">
    <div class="kbpal">
      <input ref="input" v-model="q" class="kbpal-input" placeholder="A task, finding, paper, page or command…" aria-label="Go to or do"
             @keydown="key" />
      <div class="kbpal-list" role="listbox">
        <template v-for="g in groups" :key="g.name">
          <div class="kbpal-group">{{ g.name }}</div>
          <button v-for="i in g.items" :key="i.key" type="button" role="option" class="kbpal-item" :class="{ on: i.n === chosen }"
                  :aria-selected="i.n === chosen" :data-palette="i.n" @mousemove="chosen = i.n" @click="pick(i)">
            <span class="kbpal-label">{{ i.label }}</span><span class="kbpal-detail">{{ i.detail }}</span>
          </button>
        </template>
        <p v-if="!items.length" class="kbpal-none">Nothing matches.</p>
      </div>
      <div class="kbpal-foot"><span>{{ said }}</span><span class="kbpal-keys">↑↓ choose · Enter open · Esc close</span></div>
    </div>
  </KBDialog>
</template>

<style scoped>
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
</style>
