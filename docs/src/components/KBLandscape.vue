<!--
  The landscape of the papers (landscape.json, written by `landscape!` and published with the
  dataset): a map placing them by similarity, their clusters, their relevance over time, and the
  clusters against the group's focus areas. It needs no knowledge base API.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { kbPage } from './kbLinks'
import { RELEVANCE } from './kbLabels'
import { siteJSON } from './kbApi'

type Area = { name: string; description: string }
type Cluster = { id: number; name: string; description: string; named: boolean; size: number; x: number; y: number;
                 scores: number[]; relevance: number }
// A paper's dates: `published` (a year, month or day, as known) and `added` (when the group first had
// it); a landscape built before they were kept has `date`, the one or the other.
type Paper = { id: string; title: string; kind: string; category: string; page: string; published?: string; added?: string; date?: string;
               x: number; y: number;
               cluster: number; scores: number[]; relevance: number; area: number; llm_relevance: number | null;
               one_line: string | null }
type Landscape = { built_at: string; layer: string; named_by: string; focus_areas: Area[]; clusters: Cluster[]; papers: Paper[] }

const data = ref<Landscape | null>(null)
const missing = ref(false)
onMounted(async () => {
  try {
    data.value = await siteJSON('/landscape.json')
  } catch { missing.value = true }
})

type Tab = 'map' | 'clusters' | 'time' | 'areas'
const TABS: [Tab, string][] = [['map', 'Map'], ['clusters', 'Clusters'], ['time', 'Over time'], ['areas', 'Focus areas']]
const tab = ref<Tab>('map')
const colourBy = ref<'cluster' | 'area' | 'relevance'>('cluster')
const picked = ref<number | null>(null)
const find = ref('')
const hover = ref<{ p: Paper; x: number; y: number; w: number; h: number } | null>(null)
const expanded = ref<Record<number, boolean>>({})

const CLUSTER_COLOURS = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7',
                         '#9c755f', '#a0cbe8', '#ffbe7d', '#8cd17d', '#86bcb6', '#f1ce63', '#d4a6c8', '#bab0ac']
const AREA_COLOURS = ['#e15759', '#4e79a7', '#59a14f', '#edc948', '#b07aa1', '#76b7b2', '#f28e2b', '#ff9da7']

const papers = computed(() => data.value?.papers ?? [])
const clusters = computed(() => data.value?.clusters ?? [])
const areas = computed(() => data.value?.focus_areas ?? [])
const cluster = (p: Paper) => clusters.value[p.cluster - 1]

// Relevance is a paper's similarity to its nearest focus area; shown against the range in the data.
const range = computed(() => {
  const r = papers.value.map(p => p.relevance)
  return r.length ? [Math.min(...r), Math.max(...r)] : [0, 1]
})
const level = (r: number) => (r - range.value[0]) / Math.max(range.value[1] - range.value[0], 1e-9)
const heat = (t: number) => `hsl(${215 - 175 * t}, ${35 + 55 * t}%, ${38 + 24 * t}%)`
const colour = (p: Paper) => colourBy.value === 'cluster' ? CLUSTER_COLOURS[(p.cluster - 1) % CLUSTER_COLOURS.length]
  : colourBy.value === 'area' ? AREA_COLOURS[(p.area - 1) % AREA_COLOURS.length] : heat(level(p.relevance))
const clusterColour = (c: Cluster) => CLUSTER_COLOURS[(c.id - 1) % CLUSTER_COLOURS.length]
const nearestArea = (scores: number[]) => scores.indexOf(Math.max(...scores))

const found = computed(() => {
  const words = find.value.toLowerCase().split(/\s+/).filter(Boolean)
  return words.length ? new Set(papers.value.filter(p => words.every(w => p.title.toLowerCase().includes(w))).map(p => p.id)) : null
})
const faded = (p: Paper) => (picked.value !== null && p.cluster !== picked.value) || (found.value !== null && !found.value.has(p.id))
const pick = (id: number) => { picked.value = picked.value === id ? null : id }

const link = (p: Paper) => kbPage(p.page)
// A paper's dot is a link to its page: the pointer on it, or the focus, shows the paper.
function show(e: MouseEvent | FocusEvent, p: Paper) {
  const dot = e.currentTarget as SVGElement
  const box = dot.ownerSVGElement!.parentElement!.getBoundingClientRect()
  const r = dot.getBoundingClientRect()
  const [x, y] = e instanceof MouseEvent ? [e.clientX, e.clientY] : [r.left + r.width / 2, r.top + r.height / 2]
  hover.value = { p, x: x - box.left, y: y - box.top, w: box.width, h: box.height }
}
// The tip opens away from the plot's nearer edges, so it stays inside the plot: one that spilled out
// would change the page's size, move the dot from under the pointer, and close again.
const tipStyle = computed(() => {
  const t = hover.value
  if (!t) return {}
  return { ...(t.x < t.w / 2 ? { left: `${t.x + 14}px` } : { right: `${t.w - t.x + 14}px` }),
           ...(t.y < t.h / 2 ? { top: `${t.y + 10}px` } : { bottom: `${t.h - t.y + 10}px` }) }
})

// The map: papers laid out by similarity, drawn larger the more relevant. Sizes are in the map's units,
// which it scales to its width (about half): the fewer the papers, the larger each is drawn.
const W = 1000, H = 640, PAD = 24
const mx = (x: number) => PAD + x * (W - 2 * PAD)
const my = (y: number) => PAD + (1 - y) * (H - 2 * PAD)
const dotSize = computed(() => papers.value.length < 60 ? 9 : papers.value.length < 400 ? 6 : 4)
const radius = (p: Paper) => dotSize.value * (0.55 + 0.9 * level(p.relevance))
// A cluster's name above its centre, kept inside the map: half its width estimated from its length.
const LABEL = 22
const labelX = (c: Cluster) => {
  const half = 0.29 * LABEL * c.name.length
  return Math.min(Math.max(mx(c.x), PAD + half), W - PAD - half)
}
const labelY = (c: Cluster) => Math.min(Math.max(my(c.y) - 2 * dotSize.value, PAD + LABEL), H - PAD)
// Drawn faded first, so the papers in view sit on top.
const drawn = computed(() => [...papers.value].sort((a, b) => Number(faded(b)) - Number(faded(a)) || a.relevance - b.relevance))

// Over time: date against relevance, by when papers were published or when the group had them. A few
// old papers would squeeze the rest into the last years, so the axis starts at a chosen year (by
// default the one that leaves out the oldest twentieth), and papers before it are drawn hollow at its
// left edge.
const by = ref<'published' | 'added'>('published')
const dateOf = (p: Paper) => (by.value === 'published' ? p.published : p.added) ?? p.date ?? ''
const dated = computed(() => papers.value.filter(p => /^\d{4}/.test(dateOf(p))))
const undated = computed(() => papers.value.length - dated.value.length)
// A year is placed at its middle, a month at its middle.
const time = (d: string) => new Date(d.length === 4 ? `${d}-07-01` : d.length === 7 ? `${d}-15` : d).getTime()
const yearOf = (p: Paper) => parseInt(dateOf(p).slice(0, 4))
const allYears = computed(() => [...new Set(dated.value.map(yearOf))].sort((a, b) => a - b))
const defaultFrom = computed(() => {
  const ys = dated.value.map(yearOf).sort((a, b) => a - b)
  return ys.length ? ys[Math.floor(ys.length * 0.05)] : 0
})
const fromYear = ref<number | null>(null)
const from = computed(() => fromYear.value ?? defaultFrom.value)
const earlier = (p: Paper) => yearOf(p) < from.value
const earlierCount = computed(() => dated.value.filter(earlier).length)
const DAY = 864e5
const span = computed(() => {
  const t = dated.value.filter(p => !earlier(p)).map(p => time(dateOf(p)))
  if (!t.length) return [0, 1]
  // From the chosen year's start when earlier papers are drawn at its edge; else from the first paper.
  const [a, b] = [Math.min(earlierCount.value ? time(`${from.value}-01-01`) : Infinity, ...t), Math.max(...t)]
  return b - a < 2 * DAY ? [a - DAY, b + DAY] : [a, b]
})
const tx = (d: string) => tt(time(d))
const tt = (t: number) => PAD + 40 + Math.max(0, t - span.value[0]) / Math.max(span.value[1] - span.value[0], 1) * (W - 2 * PAD - 40)
const ty = (r: number) => PAD + (1 - level(r)) * (H - 2 * PAD - 20)
// The axis's ticks, about a dozen at most: years over a few years, months over a few months, else days.
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const ticks = computed(() => {
  const [lo, hi] = span.value, days = (hi - lo) / DAY
  const out: { t: number; label: string }[] = []
  const first = new Date(lo)
  if (days > 3 * 365) {
    const [a, b] = [first.getUTCFullYear(), new Date(hi).getUTCFullYear()]
    const step = Math.max(1, Math.ceil((b - a + 1) / 12))
    for (let y = a; y <= b + 1; y += step) out.push({ t: Date.UTC(y, 0, 1), label: `${y}` })
  } else if (days > 60) {
    const step = Math.max(1, Math.ceil(days / 30 / 12))
    for (let m = first.getUTCFullYear() * 12 + first.getUTCMonth(); ; m += step) {
      const t = Date.UTC(Math.floor(m / 12), m % 12, 1)
      if (t > hi) break
      out.push({ t, label: m % 12 === 0 || !out.length ? `${MONTHS[m % 12]} ${Math.floor(m / 12)}` : MONTHS[m % 12] })
    }
  } else {
    const step = Math.max(1, Math.ceil(days / 12))
    for (let t = Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), first.getUTCDate()); t <= hi; t += step * DAY) {
      const d = new Date(t)
      out.push({ t, label: `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}` })
    }
  }
  return out.filter(x => x.t >= lo && x.t <= hi)
})

// Clusters, most relevant first, each with its papers most relevant first.
const ranked = computed(() => [...clusters.value].sort((a, b) => b.relevance - a.relevance))
const membersOf = (c: Cluster) => papers.value.filter(p => p.cluster === c.id).sort((a, b) => b.relevance - a.relevance)

// The matrix: each cluster's mean similarity to each area, shaded against the whole matrix.
const cells = computed(() => clusters.value.flatMap(c => c.scores))
const shade = (s: number) => {
  const lo = Math.min(...cells.value), hi = Math.max(...cells.value)
  return (s - lo) / Math.max(hi - lo, 1e-9)
}
const nearestCount = (a: number) => papers.value.filter(p => p.area === a + 1).length
</script>

<template>
  <div class="kbl">
    <p v-if="missing" class="kbl-dim">
      No landscape yet. Run a sync.
    </p>
    <p v-else-if="!data" class="kbl-dim">Loading…</p>
    <template v-else>
      <div class="kbl-bar">
        <span class="kbl-tabs">
          <button v-for="t in TABS"
                  :key="t[0]" type="button" :class="['kbl-tab', { on: tab === t[0] }]" @click="tab = t[0]">{{ t[1] }}</button>
        </span>
        <span class="kbl-dim">{{ papers.length }} papers · {{ clusters.length }} clusters</span>
      </div>

      <template v-if="tab === 'map' || tab === 'time'">
        <div class="kbl-controls">
          <label>colour
            <select v-model="colourBy" class="kbl-select">
              <option value="cluster">cluster</option>
              <option value="area">nearest focus area</option>
              <option value="relevance">relevance</option>
            </select>
          </label>
          <input v-model="find" type="search" class="kbl-input" placeholder="Find titles…" />
          <label v-if="tab === 'time'">by
            <select v-model="by" class="kbl-select" @change="fromYear = null">
              <option value="published">when published</option>
              <option value="added">when the group had it</option>
            </select>
          </label>
          <label v-if="tab === 'time'">from
            <select :value="from" class="kbl-select" @change="fromYear = Number(($event.target as HTMLSelectElement).value)">
              <option v-for="y in allYears" :key="y" :value="y">{{ y }}</option>
            </select>
          </label>
          <span v-if="tab === 'time' && earlierCount" class="kbl-dim">{{ earlierCount }} earlier (hollow)</span>
          <span v-if="tab === 'time' && undated" class="kbl-dim">{{ undated }} without a date, not shown</span>
          <button v-if="picked !== null" type="button" class="kb-link kbl-link" @click="picked = null">all clusters</button>
        </div>
        <div class="kbl-plot">
          <svg v-if="tab === 'map'" :viewBox="`0 0 ${W} ${H}`" class="kbl-svg">
            <a v-for="p in drawn" :key="p.id" :href="link(p)" :aria-label="p.title" @focus="show($event, p)" @blur="hover = null">
              <circle :cx="mx(p.x)" :cy="my(p.y)" :r="radius(p)" :fill="colour(p)" :class="['kbl-dot', { faded: faded(p) }]"
                      @mouseenter="show($event, p)" @mouseleave="hover = null" /></a>
            <text v-for="c in clusters" v-show="colourBy === 'cluster' && (picked === null || picked === c.id)" :key="c.id"
                  :x="labelX(c)" :y="labelY(c)" class="kbl-label">{{ c.name }}</text>
          </svg>
          <svg v-else :viewBox="`0 0 ${W} ${H}`" class="kbl-svg">
            <line :x1="PAD + 40" :x2="W - PAD" :y1="H - PAD - 20" :y2="H - PAD - 20" class="kbl-axis" />
            <line :x1="PAD + 40" :x2="PAD + 40" :y1="PAD" :y2="H - PAD - 20" class="kbl-axis" />
            <text v-for="k in ticks" :key="k.t" :x="tt(k.t)" :y="H - PAD + 2" class="kbl-tick">{{ k.label }}</text>
            <text :x="PAD" :y="PAD + 6" class="kbl-tick start">more relevant</text>
            <text :x="PAD" :y="H - PAD - 24" class="kbl-tick start">less relevant</text>
            <a v-for="p in dated" :key="p.id" :href="link(p)" :aria-label="p.title" @focus="show($event, p)" @blur="hover = null">
              <circle :cx="tx(dateOf(p))" :cy="ty(p.relevance)" :r="0.8 * dotSize" :fill="colour(p)"
                      :style="earlier(p) ? { fill: 'none', stroke: colour(p), strokeWidth: 1.5 } : undefined"
                      :class="['kbl-dot', { faded: faded(p) }]" @mouseenter="show($event, p)" @mouseleave="hover = null" /></a>
          </svg>
          <div v-if="hover" class="kbl-tip" :style="tipStyle">
            <div class="kbl-tip-title">{{ hover.p.title }}</div>
            <div class="kbl-dim">{{ hover.p.published ?? hover.p.date }}<template v-if="hover.p.added"> · added {{ hover.p.added }}</template>
              · {{ hover.p.category }}</div>
            <div>{{ cluster(hover.p)?.name }}</div>
            <div class="kbl-dim">{{ areas[hover.p.area - 1]?.name }} {{ hover.p.relevance.toFixed(2) }}<span
              v-if="hover.p.llm_relevance !== null"> · judged {{ RELEVANCE[hover.p.llm_relevance] }}</span></div>
            <div v-if="hover.p.one_line" class="kbl-tip-line">{{ hover.p.one_line }}</div>
          </div>
        </div>
        <div class="kbl-legend">
          <template v-if="colourBy === 'cluster'">
            <button v-for="c in clusters" :key="c.id" type="button" :class="['kbl-key', { off: picked !== null && picked !== c.id }]"
                    :title="c.description" @click="pick(c.id)">
              <span class="kbl-swatch" :style="{ background: clusterColour(c) }"></span>{{ c.name }} <span class="kbl-dim">{{ c.size }}</span>
            </button>
          </template>
          <template v-else-if="colourBy === 'area'">
            <span v-for="(a, i) in areas" :key="a.name" class="kbl-key" :title="a.description">
              <span class="kbl-swatch" :style="{ background: AREA_COLOURS[i % AREA_COLOURS.length] }"></span>{{ a.name }}
              <span class="kbl-dim">{{ nearestCount(i) }}</span>
            </span>
          </template>
          <span v-else class="kbl-key">less <span class="kbl-gradient"></span> more relevant</span>
        </div>
      </template>

      <div v-else-if="tab === 'clusters'" class="kbl-clusters">
        <div v-for="c in ranked" :key="c.id" class="kbl-card">
          <div class="kbl-card-head">
            <span class="kbl-swatch" :style="{ background: clusterColour(c) }"></span>
            <strong>{{ c.name }}</strong>
            <span class="kbl-dim">{{ c.size }} papers · nearest {{ areas[nearestArea(c.scores)]?.name }}</span>
            <span class="kbl-bar-track" :title="`mean relevance ${c.relevance.toFixed(2)}`">
              <span :style="{ width: `${Math.round(100 * level(c.relevance))}%` }"></span></span>
          </div>
          <p v-if="c.description" class="kbl-desc">{{ c.description }}</p>
          <ol class="kbl-papers">
            <li v-for="p in (expanded[c.id] ? membersOf(c) : membersOf(c).slice(0, 6))" :key="p.id">
              <span class="kbl-bar-track small"><span :style="{ width: `${Math.round(100 * level(p.relevance))}%`, background: heat(level(p.relevance)) }"></span></span>
              <a :href="link(p)">{{ p.title }}</a>
              <span v-if="p.published ?? p.date" class="kbl-dim"> · {{ p.published ?? p.date }}</span>
              <span v-if="p.llm_relevance !== null" class="kbl-chip">{{ RELEVANCE[p.llm_relevance] }}</span>
            </li>
          </ol>
          <button v-if="c.size > 6" type="button" class="kb-link kbl-link" @click="expanded[c.id] = !expanded[c.id]">
            {{ expanded[c.id] ? 'fewer' : `all ${c.size}` }}</button>
        </div>
      </div>

      <div v-else class="kbl-matrix-wrap">
        <table class="kbl-matrix">
          <thead>
            <tr><th></th><th v-for="a in areas" :key="a.name" :title="a.description">{{ a.name }}</th></tr>
            <tr class="kbl-dim"><td>papers</td><td v-for="(a, i) in areas" :key="a.name">{{ nearestCount(i) }}</td></tr>
          </thead>
          <tbody>
            <tr v-for="c in ranked" :key="c.id">
              <th :title="c.description"><span class="kbl-swatch" :style="{ background: clusterColour(c) }"></span>{{ c.name }}
                <span class="kbl-dim">{{ c.size }}</span></th>
              <td v-for="(s, i) in c.scores" :key="i" :style="{ background: `color-mix(in srgb, var(--vp-c-brand-1) ${Math.round(80 * shade(s))}%, transparent)` }"
                  :title="`mean similarity ${s.toFixed(3)}`">{{ s.toFixed(2) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </div>
</template>

<style scoped>
.kbl { margin: 1rem 0 2rem; font-size: 0.9rem; }
.kbl-dim { color: var(--vp-c-text-3); font-size: 0.8rem; }
.kbl-bar { display: flex; align-items: center; justify-content: space-between; gap: 1rem; margin-bottom: 0.6rem; }
.kbl-tabs { display: flex; gap: 0.3rem; }
.kbl-tab { padding: 0.25rem 0.75rem; border: 1px solid var(--vp-c-divider); border-radius: 6px; background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-2); font: inherit; cursor: pointer; }
.kbl-tab.on { color: var(--vp-c-text-1); border-color: var(--vp-c-brand-1); }
.kbl-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 0.7rem; margin-bottom: 0.5rem; color: var(--vp-c-text-2); }
.kbl-select, .kbl-input { padding: 0.25rem 0.5rem; font: inherit; border: 1px solid var(--vp-c-divider); border-radius: 6px;
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbl-input { flex: 1; min-width: 12rem; }
.kbl-plot { position: relative; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg-alt); }
.kbl-svg { display: block; width: 100%; height: auto; }
.kbl-dot { stroke: var(--vp-c-bg); stroke-width: 0.6; opacity: 0.85; cursor: pointer; transition: opacity 0.15s; }
.kbl-dot:hover, a:focus-visible .kbl-dot { stroke: var(--vp-c-text-1); stroke-width: 1.5; opacity: 1; }
.kbl-svg a { outline: none; }
.kbl-dot.faded { opacity: 0.1; }
.kbl-label { font-size: 22px; font-weight: 600; fill: var(--vp-c-text-1); text-anchor: middle; pointer-events: none;
  paint-order: stroke; stroke: var(--vp-c-bg-alt); stroke-width: 6px; stroke-linejoin: round; }
.kbl-axis { stroke: var(--vp-c-divider); }
.kbl-tick { font-size: 18px; fill: var(--vp-c-text-3); text-anchor: middle; }
.kbl-tick.start { text-anchor: start; }
.kbl-tip { position: absolute; max-width: 22rem; padding: 0.5rem 0.7rem; border: 1px solid var(--vp-c-divider); border-radius: 8px;
  background: var(--vp-c-bg); box-shadow: var(--vp-shadow-3); pointer-events: none; font-size: 0.8rem; line-height: 1.4; z-index: 5; }
.kbl-tip-title { font-weight: 600; margin-bottom: 0.2rem; }
.kbl-tip-line { margin-top: 0.3rem; color: var(--vp-c-text-2); }
.kbl-legend { display: flex; flex-wrap: wrap; gap: 0.3rem 0.9rem; margin-top: 0.6rem; }
.kbl-key { display: inline-flex; align-items: center; gap: 0.35rem; padding: 0; border: none; background: none; font: inherit;
  font-size: 0.82rem; color: var(--vp-c-text-1); cursor: pointer; }
.kbl-key.off { opacity: 0.35; }
.kbl-swatch { display: inline-block; width: 0.7rem; height: 0.7rem; border-radius: 50%; margin-right: 0.35rem; flex: none; }
.kbl-gradient { display: inline-block; width: 8rem; height: 0.5rem; border-radius: 3px;
  background: linear-gradient(to right, hsl(215, 35%, 38%), hsl(127, 62%, 50%), hsl(40, 90%, 62%)); }
.kbl-clusters { display: grid; gap: 0.8rem; }
.kbl-card { padding: 0.7rem 0.9rem; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg-soft); }
.kbl-card-head { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
.kbl-desc { margin: 0.3rem 0 0; color: var(--vp-c-text-2); font-size: 0.85rem; }
.kbl-papers { list-style: none; margin: 0.5rem 0 0.2rem; padding: 0; }
.kbl-papers li { margin: 0.2rem 0; }
.kbl-bar-track { display: inline-block; width: 90px; height: 6px; border-radius: 3px; background: var(--vp-c-default-soft);
  overflow: hidden; vertical-align: middle; margin-left: auto; }
.kbl-bar-track.small { width: 40px; margin: 0 0.5rem 0 0; }
.kbl-bar-track > span { display: block; height: 100%; background: var(--vp-c-brand-1); }
.kbl-chip { display: inline-block; margin-left: 0.35rem; padding: 0 0.4rem; border-radius: 4px; font-size: 0.72rem;
  background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbl-link { font-size: 0.82rem; }
/* A fixed layout shares the width among the areas, and long names wrap rather than push the table
   past the page. */
.kbl-matrix { display: table; width: 100%; table-layout: fixed; margin: 0; font-size: 0.8rem; }
.kbl-matrix th, .kbl-matrix td { padding: 0.3rem 0.35rem; text-align: center; overflow-wrap: anywhere; }
.kbl-matrix thead th { font-size: 0.75rem; font-weight: 600; vertical-align: bottom; line-height: 1.25; }
.kbl-matrix thead th:first-child { width: 32%; }
.kbl-matrix tbody th { text-align: left; font-weight: 500; line-height: 1.3; }
</style>
