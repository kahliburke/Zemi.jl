<!--
  A list of the knowledge base's papers, drawn from papers.json (which the service rewrites as papers
  are added, see `refresh_site!`), so a paper added shows without a build: the `recent` latest, those
  in a `topic` (an arXiv category), or every paper `by="month"` it was added, each month a heading.
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue'
import { useRoute } from 'vitepress'
import { pageDrawn } from './kbTemplates'
import { paperHref } from './kbLinks'
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
  <ul v-else class="kbpl">
    <li v-for="p in shown" :key="p.id">
      <a :href="paperHref(p.slug)">{{ p.title }}</a><template v-if="firstAuthor(p)"> · {{ firstAuthor(p) }}</template><template v-if="arrival(p)"> · {{ arrival(p) }}</template><em v-if="!p.processed"> (record only)</em>
    </li>
  </ul>
</template>

<style scoped>
</style>
