<!--
  A paper of the day, made from the day's data file (see kbTemplates.ts and `day_json`): why it was
  picked, its analysis with the picked figures beside the paragraphs that discuss them, the gallery
  of all its figures, its notebooks, and the days either side. Each day's address is a copy of one
  built page holding this; with `latest`, on the Paper of the Day page, it shows the latest day.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { paperHref, notebookHref, dayHref, kbPage } from './kbLinks'
import { loadDays } from './kbData'
import { anchorOf, anchors } from './kbUtils'
import KBDayCalendar from './KBDayCalendar.vue'
import KBDaily from './KBDaily.vue'
import KBFigures from './KBFigures.vue'
import KBFigureImage from './KBFigureImage.vue'

const props = defineProps<{ latest?: boolean }>()

type Figure = { label: string; why?: string; file: string; light?: string; dark?: string; width?: number }
type Neighbour = { day: string; title: string } | null
type Day = {
  day: string; id: string; slug: string; title: string; local: boolean; source: string; why: string
  relevance: { level: number; label: string; note: string } | null; figures: Figure[]
  analysis: ({ text: string } | { figure: number })[]
  gallery: { figures: number; tables: number; discussed: string[] }
  notebooks: { title: string; page: string; summary: string; by: string }[]; idea: string | null
  before: Neighbour; after: Neighbour
}

const body = ref<HTMLElement | null>(null)
// With `latest`, the page is the latest day's, whatever the address.
const { data: d, error, render } = useTemplatedPage<Day>('daily', 'No paper of the day here.', {
  slug: props.latest ? async () => { const days = await loadDays(); return days.length ? `${days[0].day}/index` : '' } : undefined,
  title: day => props.latest ? undefined : `${day.day}: ${day.title}`,
  drawn: () => { if (body.value) anchorHeadings(body.value) },
})

// The analysis, its figures in place.
const pieces = computed(() => (d.value?.analysis ?? []).map(p => 'text' in p ? p : { figure: d.value!.figures[p.figure] }))

// The latest day's page has the page's own heading above it, so its headings are a level down.
const title = computed(() => (props.latest ? 'h2' : 'h1'))
const section = computed(() => (props.latest ? 'h3' : 'h2'))

// The analysis's headings, as anchors for the page's outline: their words, kept apart from every
// other on the page.
function anchorHeadings(root: HTMLElement) {
  const anchor = anchors([...document.querySelectorAll('[id]')].map(e => e.id))
  for (const h of root.querySelectorAll<HTMLElement>('h2,h3,h4,h5,h6'))
    if (!h.id) h.id = anchor(anchorOf(h.textContent ?? '') || 'section')
}
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!d" class="kb-dim">Loading…</p>
  <div v-else ref="body">
    <KBDayCalendar :day="d.day" />
    <KBDaily v-if="!latest" :day="d.day" />
    <component :is="title" id="day-title"><a :href="paperHref(d.slug)" v-html="render(d.title, { inline: true })"></a></component>
    <p><em>Paper of the day, {{ d.day }} · {{ d.source }}<template v-if="!d.local"> · <a :href="`https://arxiv.org/abs/${d.id}`">arXiv:{{ d.id }}</a></template></em></p>
    <div v-if="d.relevance" class="kb-badges">
      <span :class="['kb-badge', `kb-rel-${d.relevance.level}`]" :title="d.relevance.note">{{ d.relevance.label }} to our work</span>
    </div>
    <blockquote v-if="d.why"><p>{{ d.why }}</p></blockquote>

    <template v-for="(piece, i) in pieces" :key="i">
      <div v-if="'text' in piece" v-html="render(piece.text)"></div>
      <template v-else>
        <KBFigureImage :dir="`/kb-data/figures/${d.slug}`" :file="piece.figure.file" :light="piece.figure.light" :dark="piece.figure.dark"
                       :width="piece.figure.width" :label="piece.figure.label" />
        <p><em>{{ piece.figure.label }}.</em> {{ piece.figure.why }}</p>
      </template>
    </template>

    <template v-if="d.gallery.figures + d.gallery.tables > 0">
      <component :is="section" id="figures-and-tables">{{ d.gallery.figures && d.gallery.tables ? 'Figures and tables' : d.gallery.figures ? 'Figures' : 'Tables' }}</component>
      <KBFigures :id="d.id" :figures="d.gallery.figures" :tables="d.gallery.tables" :discussed="d.gallery.discussed.join(' ') || undefined" />
    </template>

    <template v-if="d.notebooks.length">
      <component :is="section" id="notebooks-from-this-paper">Notebooks from this paper</component>
      <ul>
        <li v-for="nb in d.notebooks" :key="nb.page"><a :href="notebookHref(d.slug, nb.page)">{{ nb.title }}</a>
          · {{ nb.by }}<template v-if="nb.summary"> · {{ nb.summary }}</template></li>
      </ul>
    </template>
    <div v-else-if="d.idea" class="tip custom-block"><p class="custom-block-title">A notebook from this paper</p><p>{{ d.idea }}</p></div>

    <template v-if="!latest && (d.before || d.after)">
      <hr>
      <p>
        <template v-if="d.before">← <a :href="dayHref(d.before.day)">{{ d.before.day }}: {{ d.before.title.slice(0, 60) }}</a> · </template>
        <a :href="kbPage('daily')">Latest paper of the day</a>
        <template v-if="d.after"> · <a :href="dayHref(d.after.day)">{{ d.after.day }}: {{ d.after.title.slice(0, 60) }}</a> →</template>
      </p>
    </template>
  </div>
</template>

<style scoped>
</style>
