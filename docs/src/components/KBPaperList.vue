<!--
  A list of the knowledge base's papers, drawn from papers.json (which the service rewrites as papers
  are added, see `refresh_site!`), so a paper added shows without a build: the `recent` latest, those
  in a `topic` (an arXiv category), or every paper `by="month"` it was added, each month a heading.
  The `recent` list follows the kind of document the page's search is set to (kbSearchPrefs), asked of
  the service for that kind: codebases and records are not in papers.json.
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vitepress'
import { pageDrawn } from './kbTemplates'
import { paperHref, kbPage } from './kbLinks'
import { getJSON } from './kbApi'
import { searchKind } from './kbSearchPrefs'
import { loadPapers, type Paper } from './kbData'
import { monthName } from './kbCalendar'
import { byline } from './kbFormat'

const props = defineProps<{ recent?: number; topic?: string; by?: 'month' }>()

const route = useRoute()
const papers = ref<readonly Paper[] | null>(null)
const error = ref('')

const shown = computed(() => {
  const all = papers.value ?? []
  if (props.topic !== undefined) return all.filter(p => p.category === props.topic)
  return props.recent ? all.slice(0, props.recent) : all
})
// Every month a paper came in, newest first, with the papers that came then (a paper added twice is in both).
const months = computed(() => {
  const by = new Map<string, Paper[]>()
  for (const p of papers.value ?? [])
    for (const m of new Set(p.arrivals.map(a => a.month))) (by.get(m) ?? by.set(m, []).get(m)!).push(p)
  return [...by.entries()].sort(([a], [b]) => b.localeCompare(a))
    .map(([m, ps]) => ({ id: m, title: monthName(m), papers: ps }))
})

// The recent documents of the kind the search is set to, while it is set to one (findings are not documents).
type Recent = { id: string; page: string; title: string; authors: string[]; kind: string; posted: string }
const ofKind = ref<Recent[] | null>(null)
let asked = 0
watch(searchKind, async k => {
  const n = ++asked
  if (!props.recent || !k || k === 'finding') { ofKind.value = null; return }
  try {
    const got = await getJSON(`/api/recent?kind=${encodeURIComponent(k)}&limit=${props.recent}`) as Recent[]
    if (n === asked) ofKind.value = got
  } catch (e: any) { if (n === asked) { ofKind.value = []; error.value = `The documents could not be listed: ${e.message ?? e}` } }
}, { immediate: true })

const firstAuthor = (p: Paper) => byline(p.authors, 1, p.authors_total)
const arrival = (p: Paper) => p.arrivals.at(-1)?.text ?? ''

onMounted(async () => {
  try {
    papers.value = await loadPapers()
    // The months are headings, for the page's outline.
    if (props.by === 'month') { await nextTick(); pageDrawn(route) }
  } catch (e: any) { error.value = `The papers could not be listed: ${e.message ?? e}` }
})

defineExpose({ count: computed(() => shown.value.length) })
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!papers" class="kb-dim">Loading…</p>
  <template v-else-if="by === 'month'">
    <template v-for="m in months" :key="m.id">
      <h2 :id="m.id">{{ m.title }}</h2>
      <ul class="kbpl">
        <li v-for="p in m.papers" :key="p.id">
          <a :href="paperHref(p.slug)">{{ p.title }}</a><template v-if="firstAuthor(p)"> · {{ firstAuthor(p) }}</template><template v-if="arrival(p)"> · {{ arrival(p) }}</template><em v-if="!p.processed"> (record only)</em>
        </li>
      </ul>
    </template>
  </template>
  <ul v-else-if="ofKind" class="kbpl">
    <li v-for="d in ofKind" :key="d.id">
      <a :href="kbPage(d.page)">{{ d.title }}</a><template v-if="d.authors.length"> · {{ byline(d.authors, 1, d.authors.length) }}</template><template v-if="d.posted"> · {{ d.posted }}</template>
    </li>
    <li v-if="!ofKind.length" class="kb-dim">None of this kind yet.</li>
  </ul>
  <ul v-else class="kbpl">
    <li v-for="p in shown" :key="p.id">
      <a :href="paperHref(p.slug)">{{ p.title }}</a><template v-if="firstAuthor(p)"> · {{ firstAuthor(p) }}</template><template v-if="arrival(p)"> · {{ arrival(p) }}</template><em v-if="!p.processed"> (record only)</em>
    </li>
  </ul>
</template>

<style scoped>
</style>
