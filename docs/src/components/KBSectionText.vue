<!--
  A section of a paper on its page, opened on demand: the service sends it when it is opened, so the
  site's build carries only the section's title and summary.

  A paper read from a PDF shows the pages the section is on, drawn by the service (in the dark theme
  recolored for it, or as printed with the switch), opened where the section starts, its own text
  clear and the rest of the pages dimmed. **Text** shows what the reading extracted instead, for
  copying and quoting: its paragraphs, equations, captions and references as the reading split them,
  a caption set apart with its label in bold. A document not read from a PDF has only the text.
  Beside the title, the whole PDF at the section's first page (see KBPdf.vue).
-->
<script setup lang="ts">
import { ref, computed, nextTick } from 'vue'
import { useData } from 'vitepress'
import { api, mode, connect, getJSON } from './kbApi'
import { originalFigures } from './kbDisplay'
import KBPdf from './KBPdf.vue'

const props = defineProps<{ id: string; section: number; label: string; page?: number | null; version?: string; local?: boolean }>()
type Block = { kind: string; text: string; page: number; box: [number, number, number, number]; label?: string }
type Page = { page: number; width: number; height: number }
type Region = { page: number; box: [number, number, number, number] }

const blocks = ref<Block[] | null>(null)
const pdf = ref(false)
const figures = ref<Region[]>([])
const pages = ref<Page[] | null>(null)
const error = ref('')
const pagesError = ref('')
const view = ref<'pages' | 'text'>('pages')
const printed = ref(originalFigures.value)
const { isDark } = useData()
const scroller = ref<HTMLElement | null>(null)
const width = ref(1200)
// Each instance's SVG masks need ids of their own on the page.
const uid = `kbst${Math.random().toString(36).slice(2, 8)}`

// A caption's label ("Figure 3.", "TABLE II:"), shown apart from the rest of its text.
const LABEL = /^((?:fig(?:ure)?|tab(?:le)?)\.?\s*(?:[A-Z]?\d+(?:\.\d+)*|[IVXLC]+)\s*[:.|–—]?)\s*/i
function withLabel(b: Block): Block {
  const m = b.kind === 'caption' ? b.text.match(LABEL) : null
  return m ? { ...b, label: m[1].trim(), text: b.text.slice(m[0].length) } : b
}

const text = computed(() => (blocks.value ?? []).filter(b => b.kind !== 'heading').map(withLabel))
const showPages = computed(() => pdf.value && view.value === 'pages' && !pagesError.value)
// What is the section's on page `p`: its blocks, and the figures and tables it has the captions of.
const onPage = (p: number): Region[] => [...(blocks.value ?? []), ...figures.value].filter(b => b.page === p)
const theme = computed(() => (isDark.value && !printed.value ? 'dark' : ''))
const pageSrc = (p: number) => `${api.value}/api/page-image?id=${encodeURIComponent(props.id)}&page=${p}&width=${width.value}${theme.value ? `&theme=${theme.value}` : ''}`
// A little room around each block's box, in points.
const PAD = 3

async function opened(e: Event) {
  if (!(e.target as HTMLDetailsElement).open || blocks.value) return
  await connect()
  if (mode.value !== 'live') { error.value = 'Needs a running Zemi server.'; return }
  try {
    const got = await getJSON(`/api/paper-text?id=${encodeURIComponent(props.id)}&section=${props.section}`)
    blocks.value = got.blocks
    figures.value = got.figures ?? []
    pdf.value = got.pdf && got.blocks.length > 0
  } catch (err: any) { error.value = err.message ?? String(err); return }
  if (pdf.value) await loadPages()
}

// The pages are drawn as wide as they are shown, in the screen's pixels.
async function loadPages() {
  await nextTick()
  if (scroller.value) width.value = Math.round(scroller.value.clientWidth * (window.devicePixelRatio || 1))
  const ps = [...blocks.value!, ...figures.value].map(b => b.page)
  try {
    pages.value = await getJSON(`/api/paper-pages?id=${encodeURIComponent(props.id)}&pages=${Math.min(...ps)}-${Math.max(...ps)}`)
  } catch (err: any) { pagesError.value = err.message ?? String(err); return }
  await nextTick()
  toStart()
}

// Scrolled to where the section starts: its first block, a little above it.
function toStart() {
  const el = scroller.value, first = blocks.value?.[0], p = pages.value?.find(q => q.page === first?.page)
  const at = el?.querySelector<HTMLElement>(`[data-page="${first?.page}"]`)
  if (!el || !first || !p || !at) return
  el.scrollTop = at.offsetTop + (first.box[1] / p.height) * at.clientHeight - 24
}

async function show(v: 'pages' | 'text') {
  view.value = v
  if (v === 'pages') { await nextTick(); toStart() }
}
</script>

<template>
  <details class="details custom-block kbst" @toggle="opened">
    <summary>{{ label }}<KBPdf v-if="page" :id="id" :page="page" :version="version" :local="local" :label="`PDF p. ${page}`" chip /></summary>
    <p v-if="error" class="kb-dim kbst-dim">{{ error }}</p>
    <p v-else-if="!blocks" class="kb-dim kbst-dim">Loading…</p>
    <template v-else>
      <div v-if="pdf" class="kbst-bar">
        <span class="kbst-views" role="group" aria-label="Show the section as">
          <button type="button" :class="{ on: view === 'pages' }" :aria-pressed="view === 'pages'" @click="show('pages')">Pages</button>
          <button type="button" :class="{ on: view === 'text' }" :aria-pressed="view === 'text'" @click="show('text')">Text</button>
        </span>
        <label v-if="showPages && isDark" class="kbst-printed"><input v-model="printed" type="checkbox" /> As printed</label>
        <span v-if="pagesError && view === 'pages'" class="kb-dim kbst-dim">The pages could not be shown: {{ pagesError }}</span>
      </div>
      <div v-if="showPages" ref="scroller" class="kbst-pages" :class="{ printed: !theme }">
        <p v-if="!pages" class="kb-dim kbst-dim">Loading the pages…</p>
        <div v-for="p in pages ?? []" :key="p.page" class="kbst-page" :data-page="p.page" :style="{ aspectRatio: `${p.width} / ${p.height}` }">
          <img :src="pageSrc(p.page)" :alt="`Page ${p.page}`" loading="lazy" decoding="async" />
          <svg :viewBox="`0 0 ${p.width} ${p.height}`" preserveAspectRatio="none" aria-hidden="true">
            <mask :id="`${uid}-${p.page}`">
              <rect :width="p.width" :height="p.height" fill="white" />
              <rect v-for="(b, i) in onPage(p.page)" :key="i" :x="b.box[0] - PAD" :y="b.box[1] - PAD"
                    :width="b.box[2] - b.box[0] + 2 * PAD" :height="b.box[3] - b.box[1] + 2 * PAD" fill="black" />
            </mask>
            <rect class="kbst-shade" :width="p.width" :height="p.height" :mask="`url(#${uid}-${p.page})`" />
          </svg>
          <span class="kbst-num">{{ p.page }}</span>
        </div>
      </div>
      <template v-else>
        <template v-for="(b, i) in text" :key="i">
          <pre v-if="b.kind === 'equation'" class="kbst-eq">{{ b.text }}</pre>
          <figure v-else-if="b.kind === 'caption'" class="kbst-cap">
            <figcaption><strong v-if="b.label">{{ b.label }}</strong> {{ b.text }}</figcaption>
          </figure>
          <p v-else-if="b.kind === 'reference'" class="kbst-ref">{{ b.text }}</p>
          <p v-else>{{ b.text }}</p>
        </template>
      </template>
    </template>
  </details>
</template>

<style scoped>
.kbst-dim { font-size: 0.9rem; }
.kbst-eq { white-space: pre-wrap; font-size: 0.85rem; background: var(--vp-c-bg-soft); padding: 0.5rem 0.7rem; border-radius: 6px; }
.kbst-ref { margin: 0.2rem 0; font-size: 0.9rem; }
.kbst-cap { margin: 1rem 0; padding: 0.4rem 0.8rem; border-left: 3px solid var(--vp-c-divider); background: var(--vp-c-bg-soft);
  border-radius: 0 6px 6px 0; }
.kbst-cap figcaption { font-size: 0.85rem; line-height: 1.5; color: var(--vp-c-text-2); }
.kbst-cap strong { color: var(--vp-c-text-1); }

.kbst-bar { display: flex; align-items: center; gap: 0.9rem; flex-wrap: wrap; margin: 0.4rem 0 0.6rem; }
.kbst-views { display: inline-flex; border: 1px solid var(--vp-c-divider); border-radius: 6px; overflow: hidden; }
.kbst-views button { padding: 0.15rem 0.7rem; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbst-views button + button { border-left: 1px solid var(--vp-c-divider); }
.kbst-views button.on { background: var(--vp-c-default-soft); color: var(--vp-c-text-1); font-weight: 600; }
.kbst-printed { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.8rem; color: var(--vp-c-text-2); cursor: pointer; }

.kbst-pages { position: relative; max-height: min(80vh, 1100px); overflow-y: auto; display: flex; flex-direction: column; gap: 10px;
  padding: 10px; border-radius: 6px; background: var(--vp-c-bg-alt); border: 1px solid var(--vp-c-divider); }
.kbst-page { position: relative; width: 100%; flex: none; background: var(--vp-c-bg); box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25); }
.kbst-pages.printed .kbst-page { background: #fff; }
.kbst-page img, .kbst-page svg { position: absolute; inset: 0; width: 100%; height: 100%; display: block; margin: 0; }
.kbst-shade { fill: var(--vp-c-bg); opacity: 0.6; }
.kbst-pages.printed .kbst-shade { fill: #fff; }
.kbst-num { position: absolute; right: 6px; bottom: 4px; font-size: 0.7rem; color: var(--vp-c-text-3); }
</style>
