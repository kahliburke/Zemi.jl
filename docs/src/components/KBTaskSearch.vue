<!--
  Searching the project's tasks (see src/task_search.jl): what is typed matches titles, plans and
  everything said on the tasks, with filters mixed in (`status:ready`, `is:open`, `assignee:me`, …),
  results coming as it is typed. `@` and the beginning of a name offers people, and choosing one finds
  the tasks they took part in (`person:`). `/` puts the cursor here; arrow keys and Enter choose a
  result, which is opened at the comment that matched.
-->
<script setup lang="ts">
import { ref, watch, onMounted, onBeforeUnmount } from 'vue'
import { getJSON } from './kbApi'
import { findReferences } from './kbRefs'
import { markedSnippet, plainLine } from './kbUtils'
import { statusLabel } from './kbLabels'
import { shortDay } from './kbFormat'

const props = defineProps<{ project: string }>()
const emit = defineEmits<{ open: [ref: string, event: number] }>()

type Match = { field: string; snippet: string; event: number; who: string; at: string; kind: string }
type Hit = { ref: string; title: string; status: string; parent: string; milestone: string; matches: Match[] }
type Person = { target: string; label: string; detail: string }

const q = ref('')
const hits = ref<Hit[]>([])
const chosen = ref(0)
const shown = ref(false)
const help = ref(false)
const field = ref<HTMLInputElement | null>(null)
let timer: ReturnType<typeof setTimeout> | undefined
let asked = 0

const FILTERS = [
  ['status:ready', 'a column (also is:review, is:done …)'], ['is:open', 'not done'], ['is:blocked', 'blocked'],
  ['is:sent-back', 'sent back from review'], ['is:archived', 'in the archive'], ['is:declined', 'declined plans'],
  ['assignee:me', 'yours (agent, none, or a name)'], ['milestone:"UI Improvements"', 'in a milestone'],
  ['person:Ada', 'what someone created, commented on, moved or is assigned (or @ and a name)'],
  ['project:KB', 'another project'], ['"exact words"', 'a phrase'], ['KB-12', 'a task by its reference'],
]

// An example from the guide, put in the query to try or edit.
function useExample(f: string) {
  q.value = (q.value.trim() ? q.value.trim() + ' ' : '') + f + ' '
  help.value = false
  field.value?.focus()
}

// A person being picked: `@` and the beginning of a name, at the end of the query.
const people = ref<Person[]>([])
const AT = /(^|\s)@([^\s@"]*)$/
let askedPeople = 0
async function suggestPeople(v: string) {
  const m = v.match(AT)
  if (!m) { people.value = []; return false }
  const n = ++askedPeople
  try {
    const found = await findReferences(m[2], props.project)
    if (n !== askedPeople) return true
    people.value = found.filter(r => r.kind === 'person' && r.detail !== 'agent').slice(0, 8)
    chosen.value = 0; shown.value = true
  } catch { people.value = [] }
  return true
}
function pick(p: Person) {
  const name = /\s/.test(p.label) ? `"${p.label}"` : p.label
  q.value = q.value.replace(AT, `$1person:${name} `)
  people.value = []
  field.value?.focus()
}

// Someone the query names (a name alone, or `person:`) who took part in none of this project's tasks.
const absent = ref('')
async function nameOnly(v: string, found: Hit[]) {
  absent.value = ''
  if (found.some(h => h.matches.some(m => m.field === 'person'))) return
  const m = v.trim().match(/^(?:person:"?([^"]+?)"?|([\p{L}][\p{L}\s.'-]{2,}))$/u)
  const name = (m?.[1] ?? m?.[2] ?? '').trim()
  if (!name || name.includes('@')) return
  try {
    const refs = await findReferences(name.split(/\s+/)[0])
    const who = refs.find(r => r.kind === 'person' && r.detail !== 'agent')
    if (who && q.value === v) absent.value = who.label
  } catch { /* the hint is only a hint */ }
}

watch(q, v => {
  clearTimeout(timer)
  help.value = false                        // typing is searching: the guide gives way to the results
  if (!v.trim()) { hits.value = []; people.value = []; absent.value = ''; return }
  timer = setTimeout(async () => {
    if (await suggestPeople(v)) return
    const n = ++asked
    try {
      const found: Hit[] = await getJSON(`/api/tasks/search?project=${encodeURIComponent(props.project)}&q=${encodeURIComponent(v)}`)
      if (n !== asked) return
      hits.value = found; chosen.value = 0; shown.value = true
      nameOnly(v, found)
    } catch { /* a query being typed may not parse yet */ }
  }, 140)
})

// A snippet, escaped, with the matched words marked and Markdown's marks dropped.
const snippet = (s: string) => markedSnippet(plainLine(s))
// Where a match is; one without marked words was found by meaning.
const where = (m: Match) => m.field === 'person' ? `${m.who} · ${shortDay(m.at)}` : (m.field === 'note'
  ? `${m.who}, ${m.kind === 'comment' ? 'comment' : m.kind === 'question' ? 'question' : 'note'} · ${shortDay(m.at)}`
  : m.field) + (m.snippet.includes('\x01') ? '' : ' · by meaning')

// After a click on a result has chosen it.
const hideSoon = () => setTimeout(() => (shown.value = false), 150)
function choose(h: Hit) {
  const m = h.matches.find(x => x.event)
  emit('open', h.ref, m?.event ?? 0)
  shown.value = false
}
function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape') { shown.value = false; field.value?.blur(); return }
  if (people.value.length && shown.value) {
    const n = people.value.length
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); chosen.value = (chosen.value + (e.key === 'ArrowDown' ? 1 : n - 1)) % n }
    else if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); pick(people.value[chosen.value]) }
    return
  }
  if (!hits.value.length) return
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    const n = hits.value.length
    chosen.value = (chosen.value + (e.key === 'ArrowDown' ? 1 : n - 1)) % n
  } else if (e.key === 'Enter') {
    e.preventDefault()
    choose(hits.value[chosen.value])
  }
}
// "/" anywhere but in a field puts the cursor in the search. On this page it is the tasks' search
// rather than the site's (which ⌘K / Ctrl K still opens), so it is caught before the site sees it.
function onSlash(e: KeyboardEvent) {
  const t = e.target as HTMLElement
  if (e.key !== '/' || t.closest('input, textarea, select, [contenteditable]')) return
  e.preventDefault(); e.stopImmediatePropagation()
  field.value?.focus()
}
onMounted(() => window.addEventListener('keydown', onSlash, true))
onBeforeUnmount(() => window.removeEventListener('keydown', onSlash, true))
</script>

<template>
  <div class="kbts">
    <input ref="field" v-model="q" class="kb-field kbts-field" type="search" placeholder="Search tasks  /" aria-label="Search tasks"
           @keydown="onKey" @focus="shown = !!hits.length" @blur="hideSoon" />
    <button class="kbts-help" type="button" title="How to search" aria-label="How to search" @click="help = !help">?</button>
    <div v-if="help" class="kbts-panel kbts-guide" @mousedown.prevent>
      <p>Titles, plans and notes. Filters:</p>
      <dl><template v-for="[f, d] in FILTERS" :key="f">
        <dt><button type="button" class="kbts-example" :title="`Search with ${f}`" @click="useExample(f)"><code>{{ f }}</code></button></dt><dd>{{ d }}</dd>
      </template></dl>
    </div>
    <ul v-else-if="shown && people.length" class="kbts-panel kbts-people" role="listbox" aria-label="People">
      <li v-for="(p, i) in people" :key="p.target" :class="{ on: i === chosen }" role="option" :aria-selected="i === chosen"
          @mousedown.prevent="pick(p)" @mouseenter="chosen = i">
        <span class="kbts-title">{{ p.label }}</span> <span v-if="p.detail" class="kbts-status">{{ p.detail }}</span>
      </li>
    </ul>
    <ul v-else-if="shown && q.trim()" class="kbts-panel" role="listbox">
      <li v-if="absent" class="kbts-none">{{ absent }} took part in no task in {{ project }}.</li>
      <li v-if="!hits.length && !absent" class="kbts-none">Nothing matches.</li>
      <li v-for="(h, i) in hits" :key="h.ref" :class="{ on: i === chosen }" role="option" :aria-selected="i === chosen"
          @mousedown.prevent="choose(h)" @mouseenter="chosen = i">
        <div class="kbts-head"><span class="kbts-ref">{{ h.ref }}</span> <span class="kbts-title">{{ h.title }}</span>
          <span class="kbts-status">{{ statusLabel(h.status) }}</span></div>
        <div v-for="(m, j) in h.matches.filter(m => m.field !== 'title')" :key="j" class="kbts-snip">
          <span class="kbts-where">{{ where(m) }}</span> <span v-if="m.field === 'person'" class="kbts-did">{{ m.snippet }}</span>
          <span v-else v-html="snippet(m.snippet)"></span>
        </div>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.kbts { position: relative; display: inline-flex; align-items: center; gap: 0.3rem; flex: 1; max-width: 32rem; }
.kbts-field { flex: 1; min-width: 10rem; padding: 0.3rem 0.6rem; }
.kbts-field:focus { outline: none; border-color: var(--vp-c-brand-1); }
.kbts-help { width: 22px; height: 22px; border-radius: 50%; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2);
  font: inherit; font-size: 0.75rem; cursor: pointer; }
.kbts-panel { position: absolute; z-index: 45; top: calc(100% + 4px); left: 0; width: min(44rem, 92vw); max-height: 65vh; overflow-y: auto;
  margin: 0; padding: 0.3rem; list-style: none; border: 1px solid var(--vp-c-divider); border-radius: 10px; background: var(--vp-c-bg);
  box-shadow: var(--vp-shadow-3); }
.kbts-panel li { padding: 0.45rem 0.6rem; border-radius: 8px; cursor: pointer; }
.kbts-panel li.on { background: var(--vp-c-default-soft); }
.kbts-none { color: var(--vp-c-text-2); cursor: default !important; }
.kbts-head { display: flex; gap: 0.4rem; align-items: baseline; }
.kbts-ref { font-family: var(--vp-font-family-mono); font-size: 0.75rem; color: var(--vp-c-text-2); }
.kbts-title { flex: 1; color: var(--vp-c-text-1); }
.kbts-status { font-size: 0.7rem; color: var(--vp-c-text-3); white-space: nowrap; }
.kbts-snip { margin: 0.15rem 0 0 1rem; font-size: 0.82rem; color: var(--vp-c-text-2); display: -webkit-box; -webkit-line-clamp: 2;
  -webkit-box-orient: vertical; overflow: hidden; }
.kbts-where { font-size: 0.72rem; color: var(--vp-c-text-3); margin-right: 0.3rem; }
.kbts-snip :deep(mark), .kbts-title :deep(mark) { background: var(--vp-c-brand-soft); color: var(--vp-c-text-1); border-radius: 3px; padding: 0 1px; }
.kbts-did { color: var(--vp-c-text-1); }
.kbts-people { width: min(24rem, 92vw); }
.kbts-guide { padding: 0.6rem 0.8rem; font-size: 0.82rem; }
.kbts-guide p { margin: 0 0 0.4rem; color: var(--vp-c-text-2); }
.kbts-guide dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.2rem 0.8rem; margin: 0; }
.kbts-guide dd { margin: 0; color: var(--vp-c-text-2); }
.kbts-example { padding: 0; border: none; background: none; cursor: pointer; text-align: left; }
.kbts-example:hover code { color: var(--vp-c-brand-1); }
</style>
