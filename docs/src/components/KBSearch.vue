<!--
  Search box for the knowledge base. With the knowledge base API running (`zemi` starts it), it
  runs the full hybrid search: keyword and every embedding layer, with the passages that matched.
  Without one (the site as deployed), it searches the titles, summaries and topics in papers.json,
  which the docs build writes. Live, the projects' findings that match come first, and what is found
  may be kept to papers, codebases or records; a record says how it was made and when.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, shallowRef, computed, onMounted, watch } from 'vue'
import { mode, connect, getJSON, latest, isStale } from './kbApi'
import { loadPapers, type Paper } from './kbData'
import { byline } from './kbFormat'
import { current, vectorless } from './kbSearchPrefs'
import { kbPage, findingHref } from './kbLinks'
import { markedSnippet } from './kbUtils'


type Evidence = { ranking: string; ranking_label: string; rank: number; matched: string; contribution: number }
type Passage = { section: string; page_start: number; page_end: number; page?: string | null; text: string; score: number; evidence: Evidence[] }
type Hit = { id: string; slug: string; kind?: string; page?: string; title: string; authors: string[]; published: string; category: string;
             record?: { label: string; day: string; source: string } | null;
             score?: number; max_score?: number; evidence?: Evidence[]; passages?: Passage[];
             summary?: string; topics?: string[] }

const query = ref('')
// The kinds of document found: every kind, or one (see src/kinds.jl).
const KINDS = [{ id: '', label: 'everything' }, { id: 'paper', label: 'papers' }, { id: 'code', label: 'codebases' },
               { id: 'record', label: 'records' }]
const kind = ref('')
const hits = ref<Hit[]>([])
type Found = { ref: string; claim: string; status: string; snippet: string }
const found = ref<Found[]>([])
const busy = ref(false)
const error = ref('')
const seconds = ref<number | null>(null)
// Showing the keyword matches while those by meaning are still coming.
const partial = ref(false)
const papers = shallowRef<readonly Paper[]>([])

// Live when the knowledge base API answers (see kbApi), otherwise the paper list written with
// the site.
async function start(retry = false) {
  await connect(retry)
  if (mode.value === 'static' && !papers.value.length) {
    try {
      papers.value = await loadPapers()
    } catch { error.value = 'Paper list unavailable.' }
  }
}
onMounted(() => start())

// Words of two or more letters or digits, lower-cased.
const words = (s: string) => (s.toLowerCase().match(/[\p{L}\p{N}]{2,}/gu) ?? [])

// A paper the query names by its arXiv id goes above the findings too, not only above the other papers.
const idFirst = computed(() => hits.value.some(h => h.evidence?.[0]?.ranking === 'id'))
function searchStatic(q: string): Hit[] {
  const terms = words(q)
  if (!terms.length) return []
  // A paper named by its arXiv id (with or without its version) comes first.
  const ids = (q.match(/\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?\/\d{7}/gi) ?? []).map(x => x.toLowerCase())
  const scored = papers.value.map(p => {
    const title = p.title.toLowerCase(), summary = p.summary.toLowerCase()
    const topics = p.topics.join(' ').toLowerCase(), authors = p.authors.join(' ').toLowerCase()
    let score = ids.includes(p.id.toLowerCase()) ? 100 : 0
    for (const t of terms) {
      if (title.includes(t)) score += 3
      if (topics.includes(t)) score += 2
      if (authors.includes(t)) score += 2
      if (summary.includes(t)) score += 1
    }
    return { p, score }
  }).filter(x => x.score > 0).sort((a, b) => b.score - a.score).slice(0, 15)
  return scored.map(({ p }) => ({ ...p }))
}

let timer: ReturnType<typeof setTimeout> | undefined
// The hits shown answer the last query typed: one asked before it is dropped. Keyword matches come
// back at once and are shown until the search by meaning, which waits on its query being embedded,
// replaces them.
const searching = latest()
const keywords = latest()
function runSearch(q: string, delay = 350) {
  clearTimeout(timer)
  error.value = ''
  if (!q.trim()) { searching.cancel(); keywords.cancel(); busy.value = false; partial.value = false; hits.value = []; found.value = []; seconds.value = null; return }
  if (mode.value === 'static') { hits.value = searchStatic(q); return }
  timer = setTimeout(async () => {
    busy.value = true
    partial.value = false
    const c = current.value
    const kinds = kind.value ? `&kinds=${kind.value}` : ''
    const url = (layers: string, keyword: boolean) =>
      `/api/search?q=${encodeURIComponent(q)}&limit=8&layers=${encodeURIComponent(layers)}&keyword=${keyword ? 1 : 0}${kinds}`
    let answered = false
    if (c.layers.length && c.keyword)
      keywords(signal => getJSON(url('none', true), { signal })).then(data => {
        if (answered) return
        hits.value = data.hits; found.value = data.findings ?? []; seconds.value = null; partial.value = true
      }).catch(() => {})
    try {
      const data = await searching(signal => getJSON(url(c.layers.length ? c.layers.join(',') : 'none', c.keyword), { signal }))
      answered = true
      hits.value = data.hits; found.value = data.findings ?? []; seconds.value = data.seconds; partial.value = false
    } catch (e: any) {
      if (isStale(e)) return
      error.value = `Search failed: ${e.message ?? e}`
    }
    busy.value = false
  }, delay)
}
watch(query, q => runSearch(q))
watch(kind, () => runSearch(query.value, 0))
// A change in the settings button's choice searches again.
watch(current, () => runSearch(query.value, 0), { deep: true })

const rankings = computed(() => current.value.layers.length + (current.value.keyword ? 1 : 0))
const note = computed(() => mode.value === 'live'
  ? vectorless.value
    ? 'Searching by keyword'
    : `${rankings.value} method${rankings.value === 1 ? '' : 's'} (⚙)`
  : mode.value === 'static'
    ? `Titles, summaries, topics (${papers.value.length} papers). Semantic search needs zemi.`
    : 'Connecting…')

// How strong a match is: its fused score against a first place in every ranking of the search.
const strength = (h: Hit) => h.score && h.max_score ? h.score / h.max_score : 0
const share = (h: Hit, e: Evidence) => h.score ? Math.round(100 * e.contribution / h.score) : 0
const open = ref<Record<string, boolean>>({})
const clip = (s: string, n = 420) => s.length > n ? s.slice(0, n).replace(/\s+\S*$/, '') + ' …' : s
const pagesOf = (p: Passage) => p.page_start === p.page_end ? `p. ${p.page_start}` : `pp. ${p.page_start}–${p.page_end}`
</script>

<template>
  <div class="kb-search">
    <input v-model="query" type="search" class="kb-field kb-input" placeholder="Search…" autofocus />
    <div class="kb-note">
      <span :class="['kb-mode', mode]">{{ mode === 'live' ? 'live' : mode === 'static' ? 'offline' : '…' }}</span>
      {{ note }}<button type="button" v-if="mode === 'static'" class="kb-link kb-retry" @click="start(true)">retry</button>
      <span v-if="busy && partial"> · keyword matches; searching by meaning…</span><span v-else-if="busy"> · searching…</span><span v-else-if="seconds !== null"> · {{ seconds.toFixed(2) }} s</span>
      <span v-if="mode === 'live'" class="kb-kinds">
        <button v-for="k in KINDS" :key="k.id" type="button" :class="['kb-link', { on: kind === k.id }]" @click="kind = k.id">{{ k.label }}</button>
      </span>
    </div>
    <p v-if="error" class="kb-error">{{ error }}</p>
    <div class="kb-results" :class="{ 'id-first': idFirst }">
    <div v-if="found.length" class="kb-findings">
      <div class="kb-findings-head">Findings</div>
      <a v-for="f in found" :key="f.ref" class="kb-finding" :href="findingHref(f.ref)">
        <span class="kb-finding-claim">{{ f.claim }}</span>
        <span class="kb-meta"><span class="kb-finding-ref">{{ f.ref }}</span> · {{ f.status }}
          <template v-if="!f.snippet.replace(/[\x01\x02]/g, '').startsWith(f.claim.slice(0, 40))"> · <span v-html="markedSnippet(f.snippet)"></span></template></span>
      </a>
    </div>
    <ol class="kb-hits">
      <li v-for="h in hits" :key="h.id" class="kb-hit">
        <a class="kb-title" :href="kbPage(h.page ?? `papers/${h.slug}`)"><KBTitle :text="h.title" /></a>
        <span v-if="h.record" class="kb-chip kb-chip-record" :title="h.record.label">record · {{ h.record.day }}</span>
        <span v-else-if="h.kind && h.kind !== 'paper'" class="kb-chip">{{ h.kind }}</span>
        <div v-if="h.record" class="kb-meta">{{ h.authors.join(', ') }} · {{ h.record.label }}</div>
        <div v-else class="kb-meta">
          {{ byline(h.authors, 3) }}
          · {{ h.published }} · {{ h.category }}
        </div>
        <div v-if="h.evidence" class="kb-score" :title="`score ${h.score?.toFixed(4)} / ${h.max_score?.toFixed(4)}`">
          <span class="kb-rank">#{{ hits.indexOf(h) + 1 }}</span>
          <span class="kb-bar"><span :style="{ width: `${Math.round(100 * strength(h))}%` }"></span></span>
          <span class="kb-strength">{{ Math.round(100 * strength(h)) }}%</span>
          <span class="kb-found">{{ h.evidence.length }} methods</span>
          <button type="button" class="kb-link kb-why" @click="open[h.id] = !open[h.id]">{{ open[h.id] ? 'hide' : 'why' }}</button>
        </div>
        <table v-if="h.evidence && open[h.id]" class="kb-evidence">
          <thead><tr><th>method</th><th>rank</th><th>matched</th><th>share</th></tr></thead>
          <tbody>
            <tr v-for="e in h.evidence" :key="e.ranking">
              <td>{{ e.ranking_label }}</td><td>#{{ e.rank }}</td><td>{{ e.matched }}</td>
              <td><span class="kb-bar small"><span :style="{ width: `${share(h, e)}%` }"></span></span> {{ share(h, e) }}%</td>
            </tr>
          </tbody>
        </table>
        <p v-if="h.summary" class="kb-text">{{ clip(h.summary) }}</p>
        <div v-for="(p, i) in h.passages ?? []" :key="i" class="kb-passage">
          <div class="kb-where">
            <a v-if="p.page" :href="kbPage(p.page)">{{ p.section }}</a>
            <template v-else>{{ p.section }} · {{ pagesOf(p) }}</template>
            <span v-for="e in p.evidence" :key="e.ranking" class="kb-chip" :title="e.ranking_label">{{ e.ranking_label.split(' · ')[1] ?? e.ranking_label }} #{{ e.rank }}</span>
          </div>
          <p class="kb-text">{{ clip(p.text) }}</p>
        </div>
      </li>
    </ol>
    </div>
    <p v-if="query.trim() && !busy && !hits.length && !found.length && !error" class="kb-note">Nothing found.</p>
  </div>
</template>

<style scoped>
.kb-search { margin: 1rem 0 2rem; }
.kb-input { width: 100%; box-sizing: border-box; padding: 0.7rem 1rem; font-size: 1.05rem; border-radius: 8px; }
.kb-input:focus { outline: none; border-color: var(--vp-c-brand-1); }
.kb-note { margin-top: 0.5rem; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kb-mode { display: inline-block; padding: 0 0.45rem; margin-right: 0.35rem; border-radius: 4px; font-size: 0.75rem;
  text-transform: uppercase; letter-spacing: 0.04em; background: var(--vp-c-default-soft); }
.kb-mode.live { background: var(--vp-c-green-soft); color: var(--vp-c-green-1); }
.kb-mode.static { background: var(--vp-c-yellow-soft); color: var(--vp-c-yellow-1); }
.kb-retry { margin-left: 0.4rem; }
.kb-hits { list-style: none; padding: 0; margin: 1rem 0 0; }
.kb-results { display: flex; flex-direction: column; }
.kb-results.id-first .kb-findings { order: 1; }
.kb-findings { margin: 1rem 0 0; padding: 0.5rem 0.8rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kb-findings-head { font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); }
.kb-finding { display: block; padding: 0.35rem 0; color: inherit; text-decoration: none; }
.kb-finding:hover .kb-finding-claim { text-decoration: underline; }
.kb-finding-claim { display: block; font-weight: 600; color: var(--vp-c-brand-1); }
.kb-finding-ref { font-family: var(--vp-font-family-mono); }
.kb-finding :deep(mark) { background: var(--vp-c-yellow-soft); color: inherit; }
.kb-hit { padding: 0.9rem 0; border-top: 1px solid var(--vp-c-divider); margin: 0; }
.kb-title { font-weight: 600; font-size: 1.02rem; }
.kb-meta { font-size: 0.82rem; color: var(--vp-c-text-2); margin-top: 0.2rem; }
.kb-chip { display: inline-block; margin-left: 0.35rem; padding: 0 0.4rem; border-radius: 4px; font-size: 0.72rem;
  background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kb-chip-record { background: var(--vp-c-yellow-soft); color: var(--vp-c-text-1); }
.kb-kinds { margin-left: 0.6rem; }
.kb-kinds .kb-link { margin-right: 0.45rem; font-size: 0.8rem; }
.kb-kinds .kb-link.on { font-weight: 600; text-decoration: underline; }
.kb-score { display: flex; align-items: center; gap: 0.5rem; margin-top: 0.35rem; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kb-rank { font-weight: 600; color: var(--vp-c-text-1); }
.kb-bar { display: inline-block; width: 120px; height: 6px; border-radius: 3px; background: var(--vp-c-default-soft); overflow: hidden; vertical-align: middle; }
.kb-bar.small { width: 60px; }
.kb-bar > span { display: block; height: 100%; background: var(--vp-c-brand-1); }
.kb-why { margin-left: auto; }
.kb-evidence { margin: 0.5rem 0 0; font-size: 0.8rem; }
.kb-evidence th, .kb-evidence td { padding: 0.2rem 0.6rem; }
.kb-passage { margin: 0.5rem 0 0 0.8rem; padding-left: 0.7rem; border-left: 2px solid var(--vp-c-divider); }
.kb-where { font-size: 0.8rem; color: var(--vp-c-text-2); }
.kb-text { margin: 0.25rem 0 0; font-size: 0.9rem; line-height: 1.5; }

</style>
