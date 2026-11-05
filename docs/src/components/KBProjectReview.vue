<!--
  A project's review (see src/task_review.jl): what its work has done, as figures and over time, and
  the history of what it finished (milestones done, archived work), which a milestone can be
  reopened from. Shown as a dialog over the board; Escape or the backdrop closes it.
-->
<script setup lang="ts">
import { ref, shallowRef, computed, onMounted } from 'vue'
import { getJSON, post } from './kbApi'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'
import KBIcon from './KBIcon.vue'
import KBDialog from './KBDialog.vue'
import { TASK_STATUSES as LABEL } from './kbLabels'
import { day } from './kbFormat'

const props = defineProps<{ project: string; editable: boolean }>()
const emit = defineEmits<{ close: []; open: [ref: string]; changed: []; library: [] }>()

type Bucket = { start: string; created: number; done: number; sent_back: number; commits: number; columns: Record<string, number> }
type Mile = { name: string; created_at: string; closed: boolean; closed_at: string; due: string; total: number; done: number }
type Review = { stats: Record<string, number | null>; step: string; buckets: Bucket[]; milestones: Mile[]; now: string }
type Task = { ref: string; title: string; subtasks: number; milestone: string }
type History = { milestones: { name: string; description: string; closed_at: string; tasks: Task[] }[]; archived: { day: string; tasks: Task[] }[] }

const review = ref<Review | null>(null)
const history = ref<History | null>(null)
// What the project works from, counted here; the library itself opens from the board (KBLibrary).
const library = ref<{ kind: 'paper' | 'notebook' | 'codebase'; status: string }[] | null>(null)
const LIBRARY_KINDS = [{ kind: 'paper', title: 'papers' }, { kind: 'notebook', title: 'notebooks' }, { kind: 'codebase', title: 'codebases' }] as const
const error = ref('')
const opened = ref<Set<string>>(new Set())

async function load() {
  try {
    ;[review.value, history.value] = await Promise.all([getJSON(`/api/projects/${props.project}/review`),
                                                          getJSON(`/api/projects/${props.project}/history`)])
    library.value = await getJSON(`/api/projects/${props.project}/library`)
  } catch (e: any) { error.value = e.message }
}
const markdown = shallowRef<Render>(escapeText)
onMounted(async () => { load(); loadCode(); markdown.value = await loadMarkdown() })
async function reopen(name: string) {
  try { await post(`/api/projects/${props.project}/milestone-done`, JSON.stringify({ name, reopen: true })); emit('changed'); await load() }
  catch (e: any) { error.value = e.message }
}
const toggle = (k: string) => { const s = new Set(opened.value); s.has(k) ? s.delete(k) : s.add(k); opened.value = s }

// ── Figures ─────────────────────────────────────────────────────────────────────────────────────
const W = 640, H = 170, PAD = { l: 34, r: 18, t: 10, b: 22 }
const COLUMNS = ['done', 'review', 'in_progress', 'ready', 'backlog', 'proposed'] as const
const COLOR: Record<string, string> = { done: '#3fb67c', review: '#a77de8', in_progress: '#4b8de8', ready: '#2fb3b3', backlog: '#8b93a1', proposed: '#e0a43a' }

const buckets = computed(() => review.value?.buckets ?? [])
const tick = (s: string) => {
  const d = new Date(s)
  return review.value?.step === 'hour' ? d.toLocaleTimeString(undefined, { hour: 'numeric' }) : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}
const xAt = (i: number, n: number) => PAD.l + (n <= 1 ? 0 : i * (W - PAD.l - PAD.r) / (n - 1))
const ticks = computed(() => { const n = buckets.value.length, every = Math.max(1, Math.ceil(n / 8)); return buckets.value.map((b, i) => ({ i, b })).filter(x => x.i % every === 0) })

// Finished and created per step, as paired bars.
const flowMax = computed(() => Math.max(1, ...buckets.value.map(b => Math.max(b.done, b.created, b.commits ?? 0))))
const bars = computed(() => {
  const n = buckets.value.length, slot = (W - PAD.l - PAD.r) / Math.max(1, n), bw = Math.max(2, slot * 0.26)
  const y = (v: number) => H - PAD.b - v * (H - PAD.t - PAD.b) / flowMax.value
  return buckets.value.map((b, i) => {
    const x = PAD.l + i * slot + slot * 0.12
    const c = b.commits ?? 0
    return { done: { x, y: y(b.done), h: H - PAD.b - y(b.done), w: bw }, created: { x: x + bw + 1, y: y(b.created), h: H - PAD.b - y(b.created), w: bw },
             commits: { x: x + 2 * (bw + 1), y: y(c), h: H - PAD.b - y(c), w: bw },
             label: `${tick(b.start)}: ${b.done} done, ${b.created} created, ${c} commit${c === 1 ? '' : 's'}${b.sent_back ? `, ${b.sent_back} sent back` : ''}` }
  })
})

// Cumulative flow: how many tasks stood in each column at the end of each step, stacked.
const cfdMax = computed(() => Math.max(1, ...buckets.value.map(b => COLUMNS.reduce((n, c) => n + (b.columns[c] ?? 0), 0))))
const areas = computed(() => {
  const n = buckets.value.length
  const y = (v: number) => H - PAD.b - v * (H - PAD.t - PAD.b) / cfdMax.value
  const below = buckets.value.map(() => 0)
  return COLUMNS.map(c => {
    const lower = below.slice()
    buckets.value.forEach((b, i) => { below[i] += b.columns[c] ?? 0 })
    const top = buckets.value.map((_, i) => `${xAt(i, n)},${y(below[i])}`)
    const bottom = buckets.value.map((_, i) => `${xAt(i, n)},${y(lower[i])}`).reverse()
    return { c, points: [...top, ...bottom].join(' ') }
  })
})

// Milestones as spans from their start to when they were done (or now), on a date axis.
const TW = 1100, TL = 190, TR = 46, ROW = 24
const span = computed(() => {
  const ms = review.value?.milestones ?? []
  if (!ms.length || !review.value) return { rows: [], ticks: [], now: 0, height: 0 }
  const now = +new Date(review.value.now)
  const t0 = Math.min(...ms.map(m => +new Date(m.created_at)), ...buckets.value.map(b => +new Date(b.start)))
  const t1 = Math.max(now, ...ms.map(m => m.due ? +new Date(m.due + 'T23:59:59Z') : 0))
  const x = (t: number) => TL + (t - t0) / Math.max(1, t1 - t0) * (TW - TL - TR)
  const rows = ms.map((m, i) => ({ m, y: 6 + i * ROW, x0: x(+new Date(m.created_at)),
    x1: x(m.closed ? +new Date(m.closed_at || m.created_at) : now), due: m.due ? x(+new Date(m.due + 'T12:00:00Z')) : null }))
  // Ticks on round hours or days, about eight of them.
  const HOUR = 3_600_000, DAY = 24 * HOUR
  const steps = [HOUR, 2 * HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR, DAY, 2 * DAY, 7 * DAY, 14 * DAY, 30 * DAY]
  const every = steps.find(s => (t1 - t0) / s <= 9) ?? 60 * DAY
  const ticks: { x: number; label: string }[] = []
  for (let t = Math.ceil(t0 / every) * every; t <= t1; t += every) {
    const d = new Date(t)
    ticks.push({ x: x(t), label: every < DAY ? d.toLocaleTimeString(undefined, { hour: 'numeric' }) : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) })
  }
  return { rows, ticks, now: x(now), height: 6 + ms.length * ROW + 22 }
})

// ── The codebase's activity (see code_activity in src/task_commits.jl) ────────────────────────────
type Code = { totals: Record<string, number>; step: string; buckets: { start: string; commits: number; added: number; removed: number }[];
              authors: { name: string; commits: number; added: number; removed: number; first: string; last: string }[];
              calendar: { day: string; commits: number }[]; today: string }
const SPANS = [{ days: 28, label: '4 weeks' }, { days: 90, label: '3 months' }, { days: 365, label: 'Year' }, { days: 0, label: 'All' }]
const codeSpan = ref(90)
const code = ref<Code | null>(null)
async function loadCode() {
  try { code.value = await getJSON(`/api/projects/${props.project}/code${codeSpan.value ? `?days=${codeSpan.value}` : ''}`) } catch { /* no codebase, or none read */ }
}
const pickSpan = (d: number) => { codeSpan.value = d; loadCode() }
const num = (n: number) => n >= 10000 ? `${Math.round(n / 1000)}k` : n.toLocaleString()

// A year of days, a column a week (Sunday first), shaded by the day's commits.
const CELL = 11, GAP = 3, CAL_L = 28, CAL_T = 16
const calendar = computed(() => {
  if (!code.value) return { cells: [], months: [], width: 0, max: 0 }
  const counts = new Map(code.value.calendar.map(d => [d.day, d.commits]))
  const today = new Date(code.value.today + 'T12:00:00Z')
  const start = new Date(today); start.setUTCDate(start.getUTCDate() - 364 - start.getUTCDay())
  const max = Math.max(1, ...code.value.calendar.map(d => d.commits))
  const cells = [], months: { x: number; label: string }[] = []
  let lastMonth = -1
  for (let d = new Date(start), i = 0; d <= today; d.setUTCDate(d.getUTCDate() + 1), i++) {
    const key = d.toISOString().slice(0, 10), week = Math.floor(i / 7), n = counts.get(key) ?? 0
    const level = n === 0 ? 0 : Math.min(4, Math.ceil(4 * n / max))
    cells.push({ x: CAL_L + week * (CELL + GAP), y: CAL_T + d.getUTCDay() * (CELL + GAP), level, title: `${n} commit${n === 1 ? '' : 's'} on ${day(key)}` })
    if (d.getUTCDate() <= 7 && d.getUTCDay() === 0 && d.getUTCMonth() !== lastMonth) {
      lastMonth = d.getUTCMonth()
      months.push({ x: CAL_L + week * (CELL + GAP), label: d.toLocaleDateString(undefined, { month: 'short', timeZone: 'UTC' }) })
    }
  }
  return { cells, months, width: CAL_L + 54 * (CELL + GAP), max }
})
const LEVEL = ['var(--vp-c-default-soft)', 'rgba(63,182,124,0.35)', 'rgba(63,182,124,0.55)', 'rgba(63,182,124,0.78)', 'rgba(63,182,124,1)']

// Code frequency: lines added above the axis, removed below, each step.
const FH = 150
const frequency = computed(() => {
  const bs = code.value?.buckets ?? []
  const n = bs.length, slot = (W - PAD.l - PAD.r) / Math.max(1, n), bw = Math.max(2, slot * 0.7)
  const max = Math.max(1, ...bs.map(b => Math.max(b.added, b.removed)))
  const mid = FH / 2, scale = (FH / 2 - 8) / max
  return { mid, max, bars: bs.map((b, i) => ({ x: PAD.l + i * slot + (slot - bw) / 2, w: bw, up: b.added * scale, down: b.removed * scale,
    label: `${codeTick(b.start)}: +${b.added} −${b.removed} in ${b.commits} commit${b.commits === 1 ? '' : 's'}` })),
    ticks: bs.map((b, i) => ({ i, b })).filter(x => x.i % Math.max(1, Math.ceil(n / 8)) === 0).map(x => ({ x: PAD.l + (x.i + 0.5) * slot, label: codeTick(x.b.start) })) }
})
const codeTick = (s: string) => new Date(s).toLocaleDateString(undefined, code.value?.step === 'month' ? { month: 'short', year: '2-digit' } : { month: 'short', day: 'numeric' })
const topAuthor = computed(() => Math.max(1, ...(code.value?.authors ?? []).map(a => a.commits)))

const pct = (v: number | null | undefined) => v == null ? '—' : `${Math.round(v * 100)}%`
const hours = (v: number | null | undefined) => v == null ? '—' : v < 48 ? `${v} h` : `${Math.round(v / 24)} d`
</script>

<template>
  <KBDialog width="min(72rem, 96vw)" top bare @close="emit('close')">
    <section class="kbr-box">
      <header class="kbr-head">
        <h2>{{ project }} review</h2>
        <span class="kb-dim kbr-dim" v-if="review">by {{ review.step }}, to now</span>
        <span class="kbr-spacer"></span>
        <button class="kbr-close" aria-label="Close" @click="emit('close')">✕</button>
      </header>
      <p v-if="error" class="kb-error kbr-error">{{ error }}</p>
      <p v-else-if="!review" class="kb-dim kbr-dim">Reading the project…</p>
      <template v-else>
        <div class="kbr-stats">
          <div><b>{{ review.stats.done }}</b><span>done</span><small>{{ review.stats.done_week }} in the last week</small></div>
          <div><b>{{ review.stats.open }}</b><span>open</span><small>{{ review.stats.in_review }} in review</small></div>
          <div><b>{{ hours(review.stats.cycle_hours as number) }}</b><span>start to done</span><small>median</small></div>
          <div><b>{{ pct(review.stats.rework as number) }}</b><span>sent back</span><small>from review</small></div>
          <div><b>{{ pct(review.stats.by_agents as number) }}</b><span>by agents</span><small>of work done</small></div>
          <div><b>{{ review.stats.questions }}</b><span>questions</span><small>{{ review.stats.questions_open }} open</small></div>
          <div><b>{{ review.stats.commits ?? 0 }}</b><span>commits</span><small>naming its tasks</small></div>
        </div>

        <div class="kbr-charts">
          <figure>
            <figcaption>Each {{ review.step }}: <span class="kbr-legend"><i class="kbr-key" :style="{ background: COLOR.done }"></i>finished</span><span class="kbr-legend"><i class="kbr-key kbr-created"></i>created</span><span class="kbr-legend"><i class="kbr-key" :style="{ background: COLOR.in_progress }"></i>commits</span></figcaption>
            <svg :viewBox="`0 0 ${W} ${H}`" role="img" aria-label="Tasks finished and created over time">
              <line :x1="PAD.l" :x2="W - PAD.r" :y1="H - PAD.b" :y2="H - PAD.b" class="kbr-axis" />
              <text :x="PAD.l - 6" :y="PAD.t + 8" class="kbr-tick" text-anchor="end">{{ flowMax }}</text>
              <g v-for="(b, i) in bars" :key="i">
                <rect :x="b.done.x" :y="b.done.y" :width="b.done.w" :height="b.done.h" :fill="COLOR.done" rx="1.5"><title>{{ b.label }}</title></rect>
                <rect :x="b.created.x" :y="b.created.y" :width="b.created.w" :height="b.created.h" class="kbr-created-bar" rx="1.5"><title>{{ b.label }}</title></rect>
                <rect :x="b.commits.x" :y="b.commits.y" :width="b.commits.w" :height="b.commits.h" :fill="COLOR.in_progress" rx="1.5"><title>{{ b.label }}</title></rect>
              </g>
              <text v-for="t in ticks" :key="t.i" :x="PAD.l + (t.i + 0.5) * (W - PAD.l - PAD.r) / Math.max(1, buckets.length)" :y="H - 6"
                    class="kbr-tick" text-anchor="middle">{{ tick(t.b.start) }}</text>
            </svg>
          </figure>
          <figure>
            <figcaption>Where the work stood
              <span v-for="c in COLUMNS" :key="c" class="kbr-legend"><i class="kbr-key" :style="{ background: COLOR[c] }"></i>{{ LABEL[c] }}</span></figcaption>
            <svg :viewBox="`0 0 ${W} ${H}`" role="img" aria-label="Tasks in each column over time">
              <polygon v-for="a in areas" :key="a.c" :points="a.points" :fill="COLOR[a.c]" fill-opacity="0.78"><title>{{ LABEL[a.c] }}</title></polygon>
              <line :x1="PAD.l" :x2="W - PAD.r" :y1="H - PAD.b" :y2="H - PAD.b" class="kbr-axis" />
              <text :x="PAD.l - 6" :y="PAD.t + 8" class="kbr-tick" text-anchor="end">{{ cfdMax }}</text>
              <text v-for="t in ticks" :key="t.i" :x="xAt(t.i, buckets.length)" :y="H - 6" class="kbr-tick" text-anchor="middle">{{ tick(t.b.start) }}</text>
            </svg>
          </figure>
          <figure v-if="span.rows.length" class="kbr-wide">
            <figcaption>Milestones · dashed: open · red tick: due</figcaption>
            <svg :viewBox="`0 0 ${TW} ${span.height}`" role="img" aria-label="Milestones over time">
              <g v-for="t in span.ticks" :key="t.x">
                <line :x1="t.x" :x2="t.x" :y1="0" :y2="span.height - 18" class="kbr-grid" />
                <text :x="t.x" :y="span.height - 4" class="kbr-tick" text-anchor="middle">{{ t.label }}</text>
              </g>
              <line :x1="span.now" :x2="span.now" :y1="0" :y2="span.height - 18" class="kbr-now" />
              <g v-for="r in span.rows" :key="r.m.name">
                <text :x="TL - 10" :y="r.y + 13" class="kbr-row" text-anchor="end">{{ r.m.name }}</text>
                <rect :x="r.x0" :y="r.y + 3" :width="Math.max(3, r.x1 - r.x0)" height="14" rx="3"
                      :fill="r.m.closed ? COLOR.done : COLOR.in_progress" :fill-opacity="r.m.closed ? 0.9 : 0.55">
                  <title>{{ r.m.name }}: {{ r.m.done }}/{{ r.m.total }} done{{ r.m.closed ? `, completed ${day(r.m.closed_at)}` : '' }}</title></rect>
                <text :x="Math.max(r.x1, r.x0 + 3) + 6" :y="r.y + 14" class="kbr-tick">{{ r.m.done }}/{{ r.m.total }}</text>
                <line v-if="r.due" :x1="r.due" :x2="r.due" :y1="r.y + 1" :y2="r.y + 19" class="kbr-due"><title>due {{ day(r.m.due) }}</title></line>
              </g>
            </svg>
          </figure>
        </div>

        <template v-if="code">
          <div class="kbr-code-head">
            <h3>Code</h3>
            <span class="kbr-spacer"></span>
            <button v-for="sp in SPANS" :key="sp.days" class="kb-pill kbr-pill" :class="{ on: codeSpan === sp.days }" @click="pickSpan(sp.days)">{{ sp.label }}</button>
          </div>
          <div class="kbr-stats">
            <div><b>{{ num(code.totals.commits) }}</b><span>commits</span><small>{{ code.totals.commits ? Math.round(100 * code.totals.with_tasks / code.totals.commits) : 0 }}% name a task</small></div>
            <div><b class="kbr-add">+{{ num(code.totals.added) }}</b><span>lines added</span></div>
            <div><b class="kbr-del">−{{ num(code.totals.removed) }}</b><span>lines removed</span></div>
            <div><b>{{ num(code.totals.files) }}</b><span>files changed</span></div>
            <div><b>{{ code.totals.contributors }}</b><span>contributor{{ code.totals.contributors === 1 ? '' : 's' }}</span></div>
          </div>
          <div class="kbr-charts">
            <figure class="kbr-wide">
              <figcaption>Commits, the last year</figcaption>
              <svg :viewBox="`0 0 ${calendar.width} ${CAL_T + 7 * (CELL + GAP)}`" class="kbr-calendar" role="img" aria-label="Commits each day of the last year">
                <text v-for="m in calendar.months" :key="m.x" :x="m.x" :y="10" class="kbr-tick">{{ m.label }}</text>
                <text v-for="[r, l] in [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']]" :key="l" :x="0" :y="CAL_T + (r as number) * (CELL + GAP) + 9" class="kbr-tick">{{ l }}</text>
                <rect v-for="(c, i) in calendar.cells" :key="i" :x="c.x" :y="c.y" :width="CELL" :height="CELL" rx="2" :fill="LEVEL[c.level]"><title>{{ c.title }}</title></rect>
              </svg>
            </figure>
            <figure>
              <figcaption>Lines <span class="kbr-legend"><i class="kbr-key" style="background:#3fb67c"></i>added</span>
                <span class="kbr-legend"><i class="kbr-key" style="background:#e5534b"></i>removed</span>, each {{ code.step }}</figcaption>
              <svg :viewBox="`0 0 ${W} ${FH + 18}`" role="img" aria-label="Lines added and removed over time">
                <line :x1="PAD.l" :x2="W - PAD.r" :y1="frequency.mid" :y2="frequency.mid" class="kbr-axis" />
                <text :x="PAD.l - 6" :y="12" class="kbr-tick" text-anchor="end">+{{ num(frequency.max) }}</text>
                <text :x="PAD.l - 6" :y="FH - 4" class="kbr-tick" text-anchor="end">−{{ num(frequency.max) }}</text>
                <g v-for="(b, i) in frequency.bars" :key="i">
                  <rect :x="b.x" :y="frequency.mid - b.up" :width="b.w" :height="b.up" fill="#3fb67c" rx="1"><title>{{ b.label }}</title></rect>
                  <rect :x="b.x" :y="frequency.mid" :width="b.w" :height="b.down" fill="#e5534b" rx="1"><title>{{ b.label }}</title></rect>
                </g>
                <text v-for="t in frequency.ticks" :key="t.x" :x="t.x" :y="FH + 14" class="kbr-tick" text-anchor="middle">{{ t.label }}</text>
              </svg>
            </figure>
            <figure>
              <figcaption>Contributors</figcaption>
              <p v-if="!code.authors.length" class="kb-dim kbr-dim">No commits in this span.</p>
              <ul class="kbr-authors">
                <li v-for="a in code.authors" :key="a.name">
                  <div class="kbr-author-head"><b>{{ a.name }}</b><span class="kb-dim kbr-dim">{{ a.commits }} commit{{ a.commits === 1 ? '' : 's' }}</span>
                    <span class="kbr-add">+{{ num(a.added) }}</span><span class="kbr-del">−{{ num(a.removed) }}</span></div>
                  <div class="kbr-author-bar"><span :style="{ width: (100 * a.commits / topAuthor) + '%' }"></span></div>
                  <div class="kb-dim kbr-dim kbr-author-span">{{ day(a.first) }} – {{ day(a.last) }}</div>
                </li>
              </ul>
            </figure>
          </div>
        </template>

        <div v-if="library" class="kbr-library">
          <h3>Library</h3>
          <button class="kbr-library-open" @click="emit('library')">
            <span v-for="k in LIBRARY_KINDS" :key="k.kind" class="kbr-library-kind"><KBIcon :name="k.kind" :size="15" />
              <b>{{ library.filter(x => x.kind === k.kind && x.status === 'kept').length }}</b> {{ k.title }}</span>
            <span v-if="library.some(x => x.status === 'proposed')" class="kbr-library-proposed">
              {{ library.filter(x => x.status === 'proposed').length }} proposed</span>
            <span class="kbr-spacer"></span><span class="kb-dim kbr-dim">Open the library →</span>
          </button>
        </div>

        <h3>History</h3>
        <p v-if="history && !history.milestones.length && !history.archived.length" class="kb-dim kbr-dim">Nothing finished yet.</p>
        <ol v-if="history" class="kbr-timeline">
          <li v-for="m in history.milestones" :key="'m:' + m.name" class="done">
            <div class="kbr-tl-head">
              <span class="kbr-when">{{ day(m.closed_at) || 'some time ago' }}</span>
              <button class="kb-link kbr-link" @click="toggle('m:' + m.name)">{{ m.name }}</button>
              <span class="kb-dim kbr-dim">milestone done · {{ m.tasks.length }} task{{ m.tasks.length === 1 ? '' : 's' }}</span>
              <span class="kbr-spacer"></span>
              <button v-if="editable" class="kbr-small" @click="reopen(m.name)">Reopen</button>
            </div>
            <div v-if="m.description" class="kb-dim kbr-dim kbr-desc kb-md" v-html="markdown(m.description, { refs: true })"></div>
            <ul v-if="opened.has('m:' + m.name)">
              <li v-for="t in m.tasks" :key="t.ref"><button class="kbr-ref" @click="emit('open', t.ref)">{{ t.ref }}</button> {{ t.title }}
                <span v-if="t.subtasks" class="kb-dim kbr-dim">· {{ t.subtasks }} subtasks</span></li>
            </ul>
          </li>
          <li v-for="a in history.archived" :key="'d:' + a.day">
            <div class="kbr-tl-head">
              <span class="kbr-when">{{ day(a.day) }}</span>
              <button class="kb-link kbr-link" @click="toggle('d:' + a.day)">{{ a.tasks.length }} task{{ a.tasks.length === 1 ? '' : 's' }} archived</button>
            </div>
            <ul v-if="opened.has('d:' + a.day)">
              <li v-for="t in a.tasks" :key="t.ref"><button class="kbr-ref" @click="emit('open', t.ref)">{{ t.ref }}</button> {{ t.title }}
                <span v-if="t.milestone" class="kb-dim kbr-dim">· {{ t.milestone }}</span></li>
            </ul>
          </li>
        </ol>
      </template>
    </section>
  </KBDialog>
</template>

<style scoped>
.kbr-box { font-size: 0.88rem; padding: 1rem 1.4rem 1.6rem; border-radius: 14px; background: var(--vp-c-bg);
  border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-5); }
.kbr-head { display: flex; align-items: baseline; gap: 0.7rem; }
.kbr-head h2 { margin: 0; border: none; padding: 0; font-size: 1.3rem; }
.kbr-spacer { flex: 1; }
.kbr-close { border: none; background: none; color: var(--vp-c-text-2); font-size: 1rem; cursor: pointer; }
.kbr-dim { font-size: 0.85rem; }
.kbr-library-open { display: flex; align-items: center; flex-wrap: wrap; gap: 0.5rem 1.2rem; width: 100%; padding: 0.65rem 0.9rem; border-radius: 10px;
  border: 1px solid transparent; background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; cursor: pointer; text-align: left; }
.kbr-library-open:hover { border-color: var(--vp-c-brand-1); }
.kbr-library-kind { display: inline-flex; align-items: center; gap: 0.35rem; color: var(--vp-c-text-2); }
.kbr-library-kind b { color: var(--vp-c-text-1); }
.kbr-library-proposed { padding: 0 0.5rem; border-radius: 999px; background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); font-size: 0.8rem; }
.kbr-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr)); gap: 0.6rem; margin: 0.9rem 0; }
.kbr-stats > div { display: flex; flex-direction: column; padding: 0.6rem 0.8rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbr-stats b { font-size: 1.5rem; font-weight: 650; line-height: 1.2; }
.kbr-stats span { font-size: 0.85rem; color: var(--vp-c-text-1); }
.kbr-stats small { font-size: 0.72rem; color: var(--vp-c-text-3); }
.kbr-charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(26rem, 1fr)); gap: 0.8rem; }
.kbr-charts figure { margin: 0; padding: 0.6rem 0.7rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbr-charts figure.kbr-wide { grid-column: 1 / -1; }
.kbr-charts figcaption { font-size: 0.8rem; color: var(--vp-c-text-2); margin-bottom: 0.3rem; }
.kbr-charts svg { width: 100%; height: auto; display: block; }
.kbr-legend { margin-left: 0.6rem; white-space: nowrap; }
.kbr-key { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin: 0 0.25rem 0 0.15rem; vertical-align: baseline; }
.kbr-created, .kbr-created-bar { background: var(--vp-c-text-3); fill: var(--vp-c-text-3); fill-opacity: 0.55; }
.kbr-axis { stroke: var(--vp-c-divider); }
.kbr-due { stroke: var(--vp-c-danger-1); stroke-width: 2; }
.kbr-tick { font-size: 10px; fill: var(--vp-c-text-3); }
.kbr-row { font-size: 12px; fill: var(--vp-c-text-1); }
.kbr-grid { stroke: var(--vp-c-divider); stroke-opacity: 0.5; }
.kbr-now { stroke: var(--vp-c-text-2); stroke-dasharray: 3 3; }
.kbr-code-head { display: flex; align-items: baseline; gap: 0.35rem; }
.kbr-add { color: #3fb67c; }
.kbr-del { color: #e5534b; }
.kbr-calendar { max-width: 780px; }
.kbr-authors { list-style: none; margin: 0; padding: 0; max-height: 170px; overflow-y: auto; }
.kbr-authors li { padding: 0.3rem 0; }
.kbr-author-head { display: flex; gap: 0.5rem; align-items: baseline; font-size: 0.85rem; }
.kbr-author-head b { flex: 1; font-weight: 500; }
.kbr-author-bar { height: 5px; margin-top: 0.25rem; border-radius: 3px; background: var(--vp-c-default-soft); overflow: hidden; }
.kbr-author-bar span { display: block; height: 100%; background: #3fb67c; }
.kbr-author-span { font-size: 0.72rem; }
.kbr-box h3 { margin: 1.2rem 0 0.4rem; font-size: 0.75rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); border: none; padding: 0; }
.kbr-timeline { list-style: none; margin: 0; padding: 0 0 0 0.9rem; border-left: 2px solid var(--vp-c-divider); }
.kbr-timeline > li { position: relative; padding: 0.3rem 0; }
.kbr-timeline > li::before { content: ''; position: absolute; left: -1.25rem; top: 0.75rem; width: 8px; height: 8px; border-radius: 50%; background: var(--vp-c-divider); }
.kbr-timeline > li.done::before { background: var(--vp-c-brand-1); }
.kbr-timeline ul { list-style: none; margin: 0.2rem 0 0 8rem; padding: 0; font-size: 0.85rem; }
.kbr-desc { margin-left: 8rem; font-size: 0.8rem; }
.kbr-tl-head { display: flex; gap: 0.5rem; align-items: baseline; }
.kbr-when { width: 7.5rem; flex: none; font-size: 0.78rem; color: var(--vp-c-text-2); }
.kbr-link { font-weight: 500; }
.kbr-ref { background: none; border: none; padding: 0; font-family: var(--vp-font-family-mono); font-size: 0.75rem; color: var(--vp-c-brand-1); cursor: pointer; }
.kbr-small { padding: 0.15rem 0.55rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2);
  font: inherit; font-size: 0.8rem; cursor: pointer; }
.kbr-small:hover { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbr-pill { padding: 0.1rem 0.6rem; font-size: 0.75rem; }
.kbr-pill.on { background: var(--vp-c-brand-soft); }
</style>
