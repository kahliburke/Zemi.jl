<!--
  Explore the knowledge base (see src/explore.jl): every document the reader may see placed by what it
  is about, on a 2D map or in a 3D space, the clusters of the landscape labelled where they lie, the
  links people made drawn between documents (citations, references, a finding's evidence, a task's
  links), and the pairs close in meaning that no link joins yet. Clicking, searching and drifting
  move the view; in 3D, F flies freely. `?center=<id>` opens it at a document.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBIcon from './KBIcon.vue'
import KBShare from './KBShare.vue'
import KBExploreCard from './KBExploreCard.vue'
import KBExploreCrumbs from './KBExploreCrumbs.vue'
import KBExploreHits from './KBExploreHits.vue'
import KBExplorePairs from './KBExplorePairs.vue'
import KBExplorePanel from './KBExplorePanel.vue'
import KBExploreTrail from './KBExploreTrail.vue'
import { ref, shallowRef, triggerRef, computed, watch, nextTick } from 'vue'
import { useData } from 'vitepress'
import { can, getJSON, post, onLive } from './kbApi'
import { exploreHref, kbPage } from './kbLinks'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'
import { BRAND, CLUSTER_COLOURS, DIMMED, KIND_COLOURS, LINK_COLOURS, NODE_KINDS, TRAIL, WHOSE, WHOSE_COLOURS, kindName, mix, own,
         provideSettings, shortTitle, useExploreSettings, whose, READING, SCALES, ramp, reading,
         type Detail, type Graph, type LegendRow, type Linked, type Near, type Node, type Pair, type Step } from './kbExplore'
import { cameraMover, type View } from './exploreCamera'
import { SCALE_2D, SCALE_3D, capHeight, clusterCentres, discTexture, pixelSize, placeTheRest, spacing, measureRoom,
         type GLink, type GNode } from './exploreLayout'


const { isDark } = useData()

// How the map is drawn, as the reader set it, kept between visits; the panel takes it up.
const settings = useExploreSettings()
provideSettings(settings)
const { view, layout, colourBy, shadeBy, shownLinks, shownKinds, showUnlinked, threshold, abstracts, driftEvery, scope,
        panelOpen, settingsOpen } = settings
const fly = ref(false)
watch(abstracts, v => { if (data.value && data.value.abstracts !== v) load() })

const data = shallowRef<Graph | null>(null)
const selected = ref<Node | null>(null)
// What the card says of the document selected, asked for once each (see /api/graph/node).
const detail = ref<Detail | null>(null)
const details = new Map<string, Detail>()
const render = shallowRef<Render>(escapeText)
watch(selected, async n => {
  if (!n || n.kind === 'finding' || n.kind === 'task') { detail.value = null; return }
  detail.value = details.get(n.id) ?? null
  if (detail.value) return
  try {
    const d: Detail = await getJSON(`/api/graph/node?id=${encodeURIComponent(n.id)}`)
    details.set(n.id, d)
    if (selected.value?.id === n.id) detail.value = d
  } catch { /* the card stays as the map has it */ }
  render.value = await loadMarkdown()
})
const error = ref('')
const building = ref('')
const buildShare = ref<number | null>(null)          // how much of the map's making is done, where its job says
const loading = ref(true)
const box = ref<HTMLDivElement | null>(null)
let graph: any = null
// The view as the camera mover takes it (see exploreCamera.ts): the map's centre and log zoom, or the
// space's camera and the point it looks at.
function readView(): View | null {
  if (!graph) return null
  if (drawnView === '2d') { const c = graph.centerAt(); return [c.x, c.y, Math.log(graph.zoom())] }
  // The point turned about is the controls' target; the camera's own look-at answer is only a point
  // ahead of it, far off.
  const c = graph.camera().position, t = graph.controls()?.target ?? graph.cameraPosition().lookAt
  return [c.x, c.y, c.z, t.x, t.y, t.z]
}
function applyView(v: View) {
  if (!graph) return
  if (drawnView === '2d') { graph.zoom(Math.exp(v[2]), 0); graph.centerAt(v[0], v[1], 0) }
  else graph.cameraPosition({ x: v[0], y: v[1], z: v[2] }, { x: v[3], y: v[4], z: v[5] }, 0)
}
const camera = cameraMover(readView, applyView)
// The view the graph was drawn as, which a redraw in the same view starts from, and what was drawn in it.
let drawnView: '2d' | '3d' | null = null
let drawnShape = ''

// ── The graph's data ───────────────────────────────────────────────────────────────────────────────

const byId = computed(() => new Map((data.value?.nodes ?? []).map(n => [n.id, n])))
// Each node's nearest by meaning and whether a link joins them, and the links people made, both ways.
const nearOf = computed(() => {
  const out = new Map<string, Near[]>()
  const g = data.value
  if (!g) return out
  for (const [i, j, s, linked] of g.similar) {
    let a = g.nodes[i], b = g.nodes[j]
    if (own(b) && !own(a)) [a, b] = [b, a]                                     // the reader's own first
    ;(out.get(a.id) ?? out.set(a.id, []).get(a.id)!).push({ node: b, similarity: s, linked })
    ;(out.get(b.id) ?? out.set(b.id, []).get(b.id)!).push({ node: a, similarity: s, linked })
  }
  out.forEach(v => v.sort((x, y) => y.similarity - x.similarity))
  return out
})
const linksOf = computed(() => {
  const out = new Map<string, Linked[]>()
  const g = data.value
  if (!g) return out
  for (const [i, j, kind] of g.links) {
    const a = g.nodes[i], b = g.nodes[j]
    ;(out.get(a.id) ?? out.set(a.id, []).get(a.id)!).push({ node: b, kind, out: true })
    ;(out.get(b.id) ?? out.set(b.id, []).get(b.id)!).push({ node: a, kind, out: false })
  }
  return out
})
const clusterName = (id?: number) => data.value?.clusters.find(c => c.id === id)?.name ?? ''

// Pairs near in meaning that no link joins and no one judged unrelated: the strongest first, those across
// clusters or kinds a little ahead. By default those where one side is the reader's own work (a note, a
// record, a finding) and the other is not: what they might cite or rest on.
const work = (n: Node) => own(n) || n.kind === 'finding'
// Notes and papers are written differently and are less alike as text than two papers: the reader's own
// work is shown beside its nearest down to this, a few each, whatever the threshold.
const OWN_FLOOR = 0.5, OWN_EACH = 3
const pairs = computed<Pair[]>(() => {
  const g = data.value
  if (!g) return []
  const here = selected.value?.cluster
  const out: Pair[] = []
  const mine = scope.value === 'own'
  g.similar.forEach(([i, j, s, linked, dismissed], at) => {
    if (linked || dismissed || s < (mine ? OWN_FLOOR : threshold.value)) return
    let a = g.nodes[i], b = g.nodes[j]
    if (scope.value === 'cluster' && here !== undefined && a.cluster !== here && b.cluster !== here) return
    if (scope.value === 'own' && work(a) === work(b)) return
    if (work(b) && !work(a)) [a, b] = [b, a]                                  // the reader's own first
    const score = s + (a.cluster !== b.cluster ? 0.04 : 0) + (a.kind !== b.kind ? 0.04 : 0)
    out.push({ a, b, similarity: s, score, at })
  })
  out.sort((x, y) => y.score - x.score)
  if (!mine) return out.slice(0, 40)
  const each = new Map<string, number>()
  return out.filter(p => (each.set(p.a.id, (each.get(p.a.id) ?? 0) + 1).get(p.a.id)! <= OWN_EACH)).slice(0, 40)
})

// The subset mapped (see `explore_set` in src/explore_sets.jl), as the address names it, and how many a
// search's subset takes.
const subset = ref('')
let arrivedAt: string | null = null              // the address's document, once gone to
const setSize = ref(100)

async function load() {
  loading.value = true
  error.value = ''
  const q = new URLSearchParams({ links: 'cites,refers,related,evidence,task', kinds: 'paper,record,code,resource,finding,task',
                                  ...(abstracts.value ? { abstracts: '1' } : {}),
                                  ...(subset.value ? { set: subset.value, n: String(setSize.value) } : {}) })
  try {
    const g: Graph = await getJSON(`/api/graph?${q}`)
    data.value = g
    building.value = g.job ? (g.set ? `Mapping ${g.set.count.toLocaleString()} documents…` : 'Updating the map…') : ''
    buildShare.value = null
    if (g.job) watchJob(g.job)
  } catch (e: any) { error.value = `The map could not be loaded: ${e.message ?? e}` }
  loading.value = false
  await nextTick()
  draw()
  // A drift's map opened from its address draws the drift's path through the documents it names.
  const s = data.value?.set
  if (s?.kind === 'docs' && !driftTrail.value.length && data.value?.nodes.length) {
    driftTrail.value = s.spec.slice(5).split(',').map(id => byId.value.get(id)).filter((n): n is Node => !!n).map(node => ({ node }))
    restyle()
  }
  // The document the address names, gone to once on arriving: not again each time the data is refreshed.
  const center = new URLSearchParams(location.search).get('center')
  if (center === arrivedAt) return
  if (center && !byId.value.has(center) && !abstracts.value && data.value?.abstract_only) { abstracts.value = true; return }
  arrivedAt = center
  if (center) {
    const node = byId.value.get(center)
    if (node) {
      if (!shownKinds.value.includes(node.kind)) shownKinds.value.push(node.kind)
      setTimeout(() => go(node), 600)
    } else if (data.value) said.value = 'This document is unavailable in your map.'
  }
}

// Map subset `spec` by itself, or with none the full map again, keeping in the address where one is.
// A drift's own map keeps the drift's path; another starts afresh.
function mapSet(spec: string, center = '') {
  stopDrift()
  if (!spec.startsWith('docs:')) driftTrail.value = []
  selected.value = null
  litRow.value = null
  subset.value = spec
  const u = new URL(location.href)
  spec ? u.searchParams.set('set', spec) : u.searchParams.delete('set')
  center ? u.searchParams.set('center', center) : u.searchParams.delete('center')
  history.pushState({}, '', u)
  load()
}
// Back to the full map, the document selected here selected there.
const leaveSet = () => mapSet('', selected.value?.id ?? '')
const mapDrift = () => mapSet('docs:' + driftTrail.value.map(t => t.node.id).join(','))
function fromAddress() {
  subset.value = new URLSearchParams(location.search).get('set') ?? ''
  load()
}
// The projects whose libraries can be mapped, asked for once Show opens.
const projectList = ref<{ key: string; name: string }[] | null>(null)
async function loadProjects() {
  if (projectList.value || !can('tasks.view')) return
  try { projectList.value = (await getJSON('/api/projects')).projects } catch { projectList.value = [] }
}

let jobTimer: ReturnType<typeof setTimeout> | undefined
function watchJob(id: string) {
  clearTimeout(jobTimer)
  jobTimer = setTimeout(async () => {
    try {
      const j = await getJSON(`/api/jobs/${id}`)
      if (j.status === 'running') { building.value = j.message || building.value; buildShare.value = j.share ?? null; watchJob(id); return }
      building.value = ''; buildShare.value = null
      if (j.status === 'done') await load()
    } catch { building.value = ''; buildShare.value = null }
  }, 2000)
}

// ── Drawing ────────────────────────────────────────────────────────────────────────────────────────

const visibleNode = (n: Node) => shownKinds.value.includes(n.kind)
const hits = ref<Map<string, number>>(new Map())          // a search's hits, by id, with their strength
// A document pointed at with ⌥ (Alt) held: its links and nearest drawn over the map where the view is,
// without going to it, opening its card or fading the rest. `lit` is that one while it lasts, else the
// selected document.
const peek = shallowRef<Node | null>(null)
// The document under the pointer, ⌥ or not: named by its short title (see `drawFocus2d`).
const pointed = shallowRef<Node | null>(null)
const lit = computed(() => peek.value ?? selected.value)
const near = computed(() => new Set([...(nearOf.value.get(selected.value?.id ?? '') ?? []).map(x => x.node.id),
                                     ...(linksOf.value.get(selected.value?.id ?? '') ?? []).map(x => x.node.id)]))

// Coloured by a scale: each shown document's rank on it, 0 to 1, those with equal values sharing one.
const scaleRank = computed(() => {
  const s = SCALES[colourBy.value], out = new Map<string, number>()
  if (!s || !data.value) return out
  const vals = data.value.nodes.filter(visibleNode).map(n => [n.id, s.value(n)] as [string, number | undefined])
    .filter((x): x is [string, number] => x[1] !== undefined && !Number.isNaN(x[1])).sort((a, b) => a[1] - b[1])
  for (let i = 0; i < vals.length;) {
    let j = i
    while (j + 1 < vals.length && vals[j + 1][1] === vals[i][1]) j++
    const t = vals.length > 1 ? (i + j) / 2 / (vals.length - 1) : 0.5
    for (let k = i; k <= j; k++) out.set(vals[k][0], t)
    i = j + 1
  }
  return out
})
// arXiv categories, the commonest among those shown first: those coloured, the rest one colour as others.
const CATEGORIES_SHOWN = 10
const categories = computed(() => {
  const count = new Map<string, number>()
  for (const n of data.value?.nodes.filter(visibleNode) ?? []) if (n.category) count.set(n.category, (count.get(n.category) ?? 0) + 1)
  return [...count.entries()].sort((a, b) => b[1] - a[1]).slice(0, CATEGORIES_SHOWN).map(([c]) => c)
})
const categoryOf = (n: Node) => (n.category && categories.value.includes(n.category) ? n.category : 'other')
// A document with nothing to place it on the scale, or in no category coloured.
const NO_VALUE = '#5d626e'
function colour(n: Node) {
  const by = colourBy.value
  if (SCALES[by]) { const t = scaleRank.value.get(n.id); return t === undefined ? NO_VALUE : ramp(t) }
  if (by === 'reading') return READING.find(r => r[0] === reading(n))![2]
  if (by === 'category') { const c = categoryOf(n); return c === 'other' ? NO_VALUE : CLUSTER_COLOURS[categories.value.indexOf(c) % CLUSTER_COLOURS.length] }
  if (by === 'whose' && n.kind !== 'finding' && n.kind !== 'task') return WHOSE_COLOURS[whose(n)]
  if (by !== 'cluster' || n.cluster === undefined) return KIND_COLOURS[n.kind] ?? '#999'
  return CLUSTER_COLOURS[(n.cluster - 1) % CLUSTER_COLOURS.length]
}
// What each colour stands for as the map is coloured, among the documents shown, with how many of them.
const legend = computed<LegendRow[]>(() => {
  const g = data.value
  if (!g) return []
  const counts = new Map<string, number>(), sizes = new Map<string, number>()
  for (const n of g.nodes.filter(visibleNode)) counts.set(legendKey(n), (counts.get(legendKey(n)) ?? 0) + 1)
  for (const n of g.nodes) if (n.cluster !== undefined) sizes.set(`c${n.cluster}`, (sizes.get(`c${n.cluster}`) ?? 0) + 1)
  if (SCALES[colourBy.value]) return []                         // a scale has its bar, not rows
  const rows = [
    ...g.clusters.map(c => ({ key: `c${c.id}`, colour: CLUSTER_COLOURS[(c.id - 1) % CLUSTER_COLOURS.length], label: c.name || 'Unnamed' })),
    ...READING.map(([k, l, c]) => ({ key: `r${k}`, colour: c, label: l })),
    ...[...categories.value, 'other'].map((c, i) => ({ key: `a${c}`, colour: c === 'other' ? NO_VALUE : CLUSTER_COLOURS[i % CLUSTER_COLOURS.length],
                                                      label: c === 'other' ? 'Other or none' : c })),
    ...WHOSE.map(([k, l]) => ({ key: `w${k}`, colour: WHOSE_COLOURS[k], label: l })),
    ...NODE_KINDS.map(([k, l]) => ({ key: `k${k}`, colour: KIND_COLOURS[k] ?? '#999', label: l })),
  ]
  return rows.filter(r => counts.has(r.key)).map(r => ({ ...r, count: counts.get(r.key)!, size: sizes.get(r.key) }))
    .sort((a, b) => (a.key[0] === 'c' && b.key[0] === 'c' ? b.count - a.count : 0))
})
// The legend's row a node falls in, as it is coloured.
function legendKey(n: Node) {
  if (SCALES[colourBy.value]) return 's'
  if (colourBy.value === 'reading') return `r${reading(n)}`
  if (colourBy.value === 'category') return `a${categoryOf(n)}`
  if (colourBy.value === 'cluster' && n.cluster !== undefined) return `c${n.cluster}`
  if (colourBy.value === 'whose' && n.kind !== 'finding' && n.kind !== 'task') return `w${whose(n)}`
  return `k${n.kind}`
}
// A legend row gone to: its documents lit and the rest greyed, the view framing the middle of them, the
// seven in ten nearest their centre, so that outliers do not hold it far out. Again, or a click on the
// background, lets it go.
const litRow = ref<string | null>(null)
function goToRow(key: string) {
  if (litRow.value === key) { litRow.value = null; return }
  stopDrift()                                    // or it selects the next document a moment later
  selected.value = null
  litRow.value = key
  frameNodes((graph?.graphData().nodes ?? []).filter((n: GNode) => legendKey(n) === key && placed(n)), 0.7)
}
// The view framing nodes `ns`: the share `most` of them nearest their middle, so outliers do not hold it far out.
// The part of the map nothing is drawn over, in pixels from its corner: right of the card (or a search's
// matches, or the suggested links) on the left, left of the panel on the right, below the top row.
function uncovered() {
  const el = frame.value!, at = el.getBoundingClientRect()
  const edge = (sel: string, side: 'left' | 'right') => {
    const r = el.querySelector(sel)?.getBoundingClientRect()
    return r ? (side === 'left' ? r.right - at.left + 12 : r.left - at.left - 12) : null
  }
  const lefts = ['.kbx-card', '.kbx-pairs'].map(sel => edge(sel, 'left')).filter((x): x is number => x !== null)
  const left = Math.max(0, ...lefts), right = edge('.kbx-panel', 'right') ?? at.width
  // Too little left beside them: the whole of the map, as on a narrow screen.
  const narrow = right - left < at.width / 3
  return { left: narrow ? 0 : left, right: narrow ? at.width : right, top: barBottom.value, bottom: at.height, width: at.width, height: at.height }
}
// Where a node is fixed (every node is, see `graphData`): known as soon as it is drawn, before the graph's
// first tick gives it `x` and `y`, so a move just after a redraw finds it.
const placed = (n: GNode) => n.fx !== undefined
// The whole map, as the view first shows it: every document with a place by meaning, not those set on
// the ring around it.
const frameAll = (ms?: number) => {
  const ns: GNode[] = (graph?.graphData().nodes ?? []).filter(placed)
  const mapped = ns.filter(n => n.cluster !== undefined)
  frameNodes(mapped.length >= 3 ? mapped : ns, 1, ms)
}
const spot = (n: GNode): [number, number, number] => [n.fx!, n.fy!, n.fz ?? 0]
function frameNodes(ns: GNode[], most: number, ms = 1100) {
  if (!ns.length || !graph) return
  const mid = [0, 1, 2].map(a => ns.reduce((t, n) => t + spot(n)[a], 0) / ns.length)
  const apart = (n: GNode) => Math.hypot(...spot(n).map((v, a) => v - mid[a]))
  const core = ns.slice().sort((a, b) => apart(a) - apart(b)).slice(0, Math.max(3, Math.ceil(ns.length * most)))
  const open = uncovered()
  if (drawnView === '2d') {
    // Into the part of the map no card or panel covers.
    const xs = core.map(n => spot(n)[0]), ys = core.map(n => spot(n)[1]), pad = 30
    const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)]
    const k = Math.min((open.right - open.left) / (x1 - x0 + 2 * pad), (open.bottom - open.top) / (y1 - y0 + 2 * pad), 8)
    camera.to([(x0 + x1) / 2 - ((open.left + open.right) / 2 - open.width / 2) / k,
               (y0 + y1) / 2 - ((open.top + open.bottom) / 2 - open.height / 2) / k, Math.log(k)], ms)
    return
  }
  // From the side the camera is on: each document as the camera would see it, and the nearest distance
  // at which every one lies within the uncovered part of the view, across and up; the point looked at
  // then shifted so they sit in the middle of that part.
  const cam = graph.camera(), from = cam.position
  const unit = (v: number[]) => { const l = Math.hypot(...v) || 1; return v.map(x => x / l) }
  const cross = (a: number[], b: number[]) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
  const dot = (a: number[], b: number[]) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  const back = unit([from.x - mid[0], from.y - mid[1], from.z - mid[2]])
  const across = unit(cross([cam.up.x, cam.up.y, cam.up.z], back)), up = cross(back, across)
  const tanUp = Math.tan((cam.fov * Math.PI) / 360), tanAcross = tanUp * open.width / open.height
  const fitAcross = tanAcross * (open.right - open.left) / open.width, fitUp = tanUp * (open.bottom - open.top) / open.height
  // Centred on the middle of their spread as the camera sees it, not their average, which one far side pulls.
  const seen = core.map(n => { const p = spot(n).map((v, a) => v - mid[a]); return [dot(p, across), dot(p, up), dot(p, back)] })
  const cx = (Math.min(...seen.map(q => q[0])) + Math.max(...seen.map(q => q[0]))) / 2
  const cy = (Math.min(...seen.map(q => q[1])) + Math.max(...seen.map(q => q[1]))) / 2
  let d = 30
  for (const [x, y, z] of seen) d = Math.max(d, z + Math.abs(x - cx) / fitAcross, z + Math.abs(y - cy) / fitUp)
  d *= 1.04
  const shiftAcross = cx - (((open.left + open.right) / 2 - open.width / 2) / (open.width / 2)) * d * tanAcross
  const shiftUp = cy + (((open.top + open.bottom) / 2 - open.height / 2) / (open.height / 2)) * d * tanUp
  const look = [0, 1, 2].map(a => mid[a] + across[a] * shiftAcross + up[a] * shiftUp)
  camera.to([look[0] + back[0] * d, look[1] + back[1] * d, look[2] + back[2] * d, look[0], look[1], look[2]], ms)
}
watch(selected, n => { if (n) litRow.value = null })
// Back to the whole map in view, nothing lit; the selected document stays selected.
function resetView() {
  stopDrift()
  litRow.value = null
  frameAll()
}
// A legend row's documents shaded from faint to full by how much each stands out in it: its links among
// the documents here (the cluster's middle deciding among the unlinked), how central it is in meaning,
// or the rating the watch's judge gave it.
// Each lit document's standing, 0 to 1, by `shadeBy`.
const standing = computed(() => {
  const out = new Map<string, number>()
  const key = litRow.value
  if (!key || shadeBy.value === 'off' || !data.value) return out
  const ns = data.value.nodes.filter(n => visibleNode(n) && legendKey(n) === key)
  // By rank, since similarities to a cluster's middle bunch together.
  const middle = new Map(ns.slice().sort((a, b) => (a.central ?? 0) - (b.central ?? 0))
                           .map((n, i) => [n.id, ns.length > 1 ? i / (ns.length - 1) : 1]))
  const most = Math.max(0, ...ns.map(n => n.links))
  for (const n of ns) {
    const c = middle.get(n.id)!
    out.set(n.id, shadeBy.value === 'central' ? c
                : shadeBy.value === 'rated' ? (n.rating === undefined ? 0 : n.rating / 3)
                : most ? 0.8 * Math.log1p(n.links) / Math.log1p(most) + 0.2 * c : c)
  }
  return out
})
watch(settingsOpen, open => { if (open) loadProjects() }, { immediate: true })
function shade(n: Node) {
  const c = colour(n)
  if (hits.value.size) return hits.value.has(n.id) ? c : isDark.value ? '#3a3a44' : '#d8d8de'
  if (litRow.value) {
    if (legendKey(n) !== litRow.value) return isDark.value ? '#3a3a44' : '#d8d8de'
    const t = standing.value.get(n.id)
    return t === undefined ? c : mix(isDark.value ? '#111116' : '#fafafa', c, 0.38 + 0.62 * t)
  }
  // A document selected: the rest keep their colours, a little faded; its ring and lines mark it out.
  if (selected.value && selected.value.id !== n.id && !near.value.has(n.id)) return mix(isDark.value ? '#111116' : '#fafafa', c, 0.6)
  return c
}
const size = (n: Node) => (((n.kind === 'finding' ? 3 : 1.4) + Math.sqrt(n.links) * 1.2) * (n.read === false ? 0.6 : 1) +
                           (hits.value.get(n.id) ?? 0) * 3) * (n.id === selected.value?.id ? 2.5 : 1) *
                         (0.7 + 0.8 * (standing.value.get(n.id) ?? 0.375))

// Discs in proportion to how closely the layout packs documents, against t-SNE's spacing: UMAP and
// PaCMAP draw clusters tighter in the same extent, where t-SNE's discs would cover each other.
const packing = computed(() => {
  const nodes = data.value?.nodes ?? []
  if (layout.value === 'tsne' || !nodes.length) return 1
  const deep = view.value === '3d'
  const mine = nodes.map(n => (deep ? (layout.value === 'umap' ? n.up : n.pp) : (layout.value === 'umap' ? n.ux : n.px)))
                    .filter(Boolean) as number[][]
  const base = nodes.map(n => (deep ? n.p : n.x)).filter(Boolean) as number[][]
  const a = spacing(mine), b = spacing(base)
  return a > 0 && b > 0 ? Math.min(1, Math.max(0.35, a / b)) : 1
})
const flatSize = (n: Node) => size(n) * packing.value ** 2
// On the map, a disc's radius in the map's units: `√size × flatRel`, which grows with the zoom until a typical
// disc is `FLAT_MOST` pixels across on screen, and is held there, so close in, the space between
// documents keeps growing and the discs do not: a tight group comes apart (as `DISC_MOST` does in the space).
const FLAT_MOST = 12
let flatRel = 4
// No wider than its room (see `measureRoom`) lets it be, nor smaller than a quarter of its size: discs
// close together are drawn smaller rather than over each other.
const ROOM_FILL = 0.45, ROOM_LEAST = 0.25
const roomy = (r: number, n: Node) => Math.min(r, Math.max(ROOM_FILL * ((n as GNode).room ?? Infinity), ROOM_LEAST * r))
const flatRadius = (n: Node) => roomy(Math.sqrt(Math.max(0, flatSize(n))) * flatRel, n)
const flatVal = (n: Node) => (flatRadius(n) / flatRel) ** 2
function fitFlatDiscs(k: number) {
  const typical = Math.sqrt(1.4) * packing.value * 4                  // a document's radius at nodeRelSize 4
  const rel = 4 * Math.min(1, FLAT_MOST / 2 / (typical * k))
  if (Math.abs(rel - flatRel) < 1e-3 || !graph) return
  flatRel = rel
  graph.nodeRelSize(rel)
}


// The library's nodes and links: placed nodes fixed where the map puts them, the rest left to settle
// among those they link to; the nearest by meaning hold the unplaced, and are drawn only when no link
// joins a pair above the threshold.
function graphData() {
  const g = data.value!
  const deep = view.value === '3d'
  const nodes: GNode[] = g.nodes.filter(visibleNode).map(n => {
    const o: GNode = { ...n } as GNode
    const flat = layout.value === 'umap' && n.ux ? n.ux : layout.value === 'pacmap' && n.px ? n.px : n.x
    const space = layout.value === 'umap' && n.up ? n.up : layout.value === 'pacmap' && n.pp ? n.pp : n.p
    if (flat && !deep) { o.fx = flat[0] * SCALE_2D; o.fy = -flat[1] * SCALE_2D }
    if (space && deep) { o.fx = space[0] * SCALE_3D; o.fy = space[1] * SCALE_3D; o.fz = space[2] * SCALE_3D }
    return o
  })
  const ids = new Set(nodes.map(n => n.id))
  const links: GLink[] = []
  for (const [i, j, kind] of g.links) {
    const a = g.nodes[i].id, b = g.nodes[j].id
    if (ids.has(a) && ids.has(b) && shownLinks.value.includes(kind)) links.push({ source: a, target: b, kind })
  }
  for (const [i, j, s, linked] of g.similar) {
    const a = g.nodes[i].id, b = g.nodes[j].id
    // Only the pairs drawn: those close enough that no link joins, when they are shown.
    if (showUnlinked.value && !linked && s >= threshold.value && ids.has(a) && ids.has(b))
      links.push({ source: a, target: b, kind: 'similar', similarity: s })
  }
  placeTheRest(nodes, links, deep)
  measureRoom(nodes, deep)
  return { nodes, links }
}


function linkColour(l: GLink) {
  if (l.kind === 'similar') return isDark.value ? 'rgba(200,200,255,0.45)' : 'rgba(60,60,140,0.4)'
  const c = LINK_COLOURS[l.kind] ?? '#999'
  if (peek.value && touches(l, peek.value.id)) return c + 'ff'
  return selected.value && !touches(l, selected.value.id) ? c + '40' : c + 'b0'
}
// On the map, a peeked document's links twice as wide as the rest.
const linkWidth2d = (l: GLink) => (l.kind === 'similar' ? 0.8 : 1.2) * (peek.value && touches(l, peek.value.id) ? 2 : 1)
const endId = (e: any) => (typeof e === 'object' ? e.id : e) as string
const touches = (l: any, id: string) => endId(l.source) === id || endId(l.target) === id


// The 2D map's cluster names, where they are drawn.
let centres: ReturnType<typeof clusterCentres> = []
async function draw() {
  if (!box.value || !data.value) return
  // Another layout, map or theme in the same view carries on from where the view is.
  const was = drawnView === view.value ? readView() : null
  // The same map drawn again (its data refreshed, links or colours changed): the view stays as it is.
  const shape = `${view.value} ${layout.value} ${subset.value} ${data.value.abstracts}`
  const same = was !== null && shape === drawnShape
  drawnShape = shape
  if (!was) camera.stop()
  graph?._destructor?.()
  box.value.innerHTML = ''
  const el = box.value
  const { nodes, links } = graphData()
  const bg = isDark.value ? '#111116' : '#fafafa'
  if (view.value === '2d') {
    const ForceGraph = (await import('force-graph')).default as any
    centres = clusterCentres(nodes, clusterName)
    graph = new ForceGraph(el)
      .backgroundColor(bg).width(el.clientWidth).height(el.clientHeight)
      .graphData({ nodes, links }).nodeId('id')
      .nodeVal(flatVal).nodeRelSize(flatRel).nodeColor(shade).nodeLabel(() => "")
      .onZoom(({ k }: { k: number }) => fitFlatDiscs(k))
      .linkColor(linkColour)
      .linkWidth(linkWidth2d)
      .linkLineDash((l: GLink) => (l.kind === 'similar' ? [2, 3] : null))
      .linkDirectionalArrowLength((l: GLink) => (l.kind === 'cites' || l.kind === 'refers' ? 3 : 0))
      .linkDirectionalArrowRelPos(1)
      .onNodeClick(clicked).onBackgroundClick(() => { selected.value = null; litRow.value = null })
      .enableNodeDrag(false)                                                     // placed by meaning, not by hand
      .cooldownTicks(1)
      .onRenderFramePre((ctx: CanvasRenderingContext2D, scale: number) => { drawTrail2d(ctx, scale); drawNearest2d(ctx, scale) })
      .onRenderFramePost((ctx: CanvasRenderingContext2D, scale: number) => {
        drawNearestLabels2d(ctx, scale)
        drawFocus2d(ctx, scale)                                              // its title over the rest
        // Cluster names, a constant size on screen. Close in, those of what is in view stay; the rest fade
        // to `DIMMED`, as they do anywhere once something is in view.
        const fade = DIMMED + (1 - DIMMED) * Math.max(0, Math.min(1, (2.2 - scale) / 1.4))
        ctx.save()
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
        ctx.font = `600 ${14 / scale}px system-ui, sans-serif`
        const rel = relevantClusters.value
        // Placed in turn, those that matter here and the largest first: a name that would cover one placed
        // already moves a step up or down, and is left out while no step clears it.
        const placed: { x0: number; x1: number; y0: number; y1: number }[] = []
        const order = centres.filter(c => c.name)
          .sort((p, q) => Number(!!rel && rel.has(q.id)) - Number(!!rel && rel.has(p.id)) || q.size - p.size)
        const h = 20 / scale
        for (const c of order) {
          const a = rel ? (rel.has(c.id) ? 1 : DIMMED) : fade
          const w = ctx.measureText(c.name).width + 12 / scale
          const clear = (y: number) => placed.every(b => c.x + w / 2 < b.x0 || c.x - w / 2 > b.x1 || y + h / 2 < b.y0 || y - h / 2 > b.y1)
          const y = [0, -1.1, 1.1, -2.2, 2.2].map(k => c.y + k * h).find(clear)
          if (y === undefined) continue
          placed.push({ x0: c.x - w / 2 - 2 / scale, x1: c.x + w / 2 + 2 / scale, y0: y - h / 2, y1: y + h / 2 })
          // On a translucent backing, so the name reads over the discs and links beneath it.
          ctx.fillStyle = isDark.value ? `rgba(17,17,22,${0.62 * a})` : `rgba(250,250,250,${0.72 * a})`
          ctx.beginPath(); ctx.roundRect(c.x - w / 2, y - h / 2, w, h, 4 / scale); ctx.fill()
          ctx.fillStyle = isDark.value ? `rgba(235,235,245,${0.9 * a})` : `rgba(30,30,40,${0.85 * a})`
          ctx.fillText(c.name, c.x, y)
        }
        ctx.restore()
      })
    graph.d3Force('charge')?.strength(-12)
    graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? (l.similarity ?? 0) * 0.3 : 0.1))
    settle(was, same)
  } else {
    const ForceGraph3D = (await import('3d-force-graph')).default as any
    const SpriteText = (await import('three-spritetext')).default as any
    SpriteTextOf = SpriteText
    const THREE = await import('three')
    const disc = discTexture(THREE)
    sprites.clear()
    graph = new ForceGraph3D(el, { controlType: fly.value ? 'fly' : 'orbit' })
      .backgroundColor(bg).width(el.clientWidth).height(el.clientHeight)
      .graphData({ nodes, links }).nodeId('id')
      .nodeVal(size).nodeLabel(() => "")
      // Each node a disc facing the camera, shaded to read as a sphere: smooth at any distance, and cheap.
      .nodeThreeObject((n: GNode) => {
        const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: disc, color: shade(n), transparent: true, depthWrite: false }))
        const d = spriteSize(n)
        sprite.userData.d = d; sprite.scale.set(d, d, 1)
        sprite.onBeforeRender = (renderer: any, _scene: any, camera: any) => {
          fitDisc(sprite, n, renderer, camera)
          keepFocusInSight(sprite, n, renderer, camera)
        }
        if (n.id === selected.value?.id) { sprite.material.depthTest = false; sprite.renderOrder = 999 }
        sprites.set(n.id, { sprite, node: n })
        return sprite
      })
      .linkColor(linkColour).linkOpacity(0.55)
      // Plain lines, a pixel wide however near: tubes and arrowheads have a size in the space and swell up
      // close. Which way a link goes is in the card.
      .linkWidth(0)
      .onNodeClick(clicked).onNodeHover(hovered).onBackgroundClick(() => { selected.value = null; litRow.value = null })
      .enableNodeDrag(false)
      .cooldownTicks(1)
    graph.d3Force('charge')?.strength(-10)
    graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? (l.similarity ?? 0) * 0.3 : 0.1))
    const fog = (await import('three')).FogExp2
    // A little depth: a tenth faded across the space as first framed, a quarter beyond it.
    graph.scene().fog = new fog(isDark.value ? 0x111116 : 0xfafafa, 0.00035)
    clusterLabels.length = 0
    for (const c of clusterCentres(nodes, clusterName)) {
      if (!c.name) continue
      const s = new SpriteText(c.name, 6, isDark.value ? 'rgba(240,240,248,0.95)' : 'rgba(25,25,35,0.95)')
      s.fontWeight = '600'
      s.backgroundColor = isDark.value ? 'rgba(17,17,22,0.72)' : 'rgba(250,250,250,0.8)'
      s.padding = [3, 1.5]
      s.borderRadius = 3
      // Over every node, whatever is nearer: drawn last, and not hidden by depth.
      s.material.depthTest = false
      s.material.depthWrite = false
      s.renderOrder = 1000
      s.position.set(c.x, c.y, c.z)
      capHeight(s, 12, 20)
      clusterLabels.push({ sprite: s, id: c.id })
      graph.scene().add(s)
    }
    settle(was, same)
    three = THREE
    nearest3d = null
    ring3d = null
    title3d = null
    trail3d = null
    restyle()
  }
}

// The selected document's nearest in meaning, drawn from it: brighter and, on the map, wider the more
// alike, with how alike beside each. Their nodes are the ones left lit (see `shade`).
function nearestShown() {
  const s = lit.value
  if (!s || !graph) return []
  const at = new Map<string, GNode>(graph.graphData().nodes.map((n: GNode) => [n.id, n]))
  const from = at.get(s.id)
  if (!from) return []
  const xs = nearLit.value.filter(x => at.has(x.node.id))
  const lo = Math.min(...xs.map(x => x.similarity)), hi = Math.max(...xs.map(x => x.similarity))
  // Strength 0 to 1: mostly how alike the pair is, a little where it stands among these.
  return xs.map(x => ({ from, to: at.get(x.node.id)!, similarity: x.similarity,
                        t: 0.7 * Math.max(0, Math.min(1, (x.similarity - 0.4) / 0.5)) + 0.3 * (hi > lo ? (x.similarity - lo) / (hi - lo) : 1) }))
}
function drawNearest2d(ctx: CanvasRenderingContext2D, scale: number) {
  const lines = nearestShown()
  if (!lines.length) return
  ctx.save()
  ctx.lineCap = 'round'
  for (const { from, to, t } of lines) {
    ctx.strokeStyle = BRAND + Math.round((0.12 + 0.8 * t) * 255).toString(16).padStart(2, '0')
    ctx.lineWidth = (0.5 + 3 * t) / scale
    ctx.beginPath(); ctx.moveTo(from.x, from.y); ctx.lineTo(to.x, to.y); ctx.stroke()
  }
  ctx.restore()
}
// How alike each is, beside its node's edge on a backing: drawn after the nodes, so none covers it.
function drawNearestLabels2d(ctx: CanvasRenderingContext2D, scale: number) {
  const lines = nearestShown()
  if (!lines.length) return
  ctx.save()
  ctx.font = `600 ${11 / scale}px system-ui, sans-serif`
  ctx.textBaseline = 'middle'
  const pad = 3 / scale, h = 15 / scale
  // Most alike first, each beside its disc, and left out where an earlier one already is.
  const taken: { x0: number; x1: number; y0: number; y1: number }[] = []
  for (const { to, similarity } of [...lines].sort((p, q) => q.similarity - p.similarity)) {
    const text = `${Math.round(similarity * 100)}%`
    const x = to.x + flatRadius(to) + 3 / scale, w = ctx.measureText(text).width + 2 * pad
    const box = { x0: x, x1: x + w, y0: to.y - h / 2, y1: to.y + h / 2 }
    if (taken.some(b => box.x0 < b.x1 && box.x1 > b.x0 && box.y0 < b.y1 && box.y1 > b.y0)) continue
    taken.push(box)
    ctx.fillStyle = isDark.value ? 'rgba(17,17,22,0.75)' : 'rgba(250,250,250,0.8)'
    ctx.beginPath(); ctx.roundRect(x, to.y - h / 2, w, h, 3 / scale); ctx.fill()
    ctx.fillStyle = isDark.value ? 'rgba(235,235,248,0.95)' : 'rgba(30,30,45,0.95)'
    ctx.fillText(text, x + pad, to.y)
  }
  ctx.restore()
}
// The selected document kept in sight in the space: its disc drawn over whatever is nearer (see `restyle`),
// and the discs between it and the camera that overlap it on screen faded while they do. Where it lies on
// screen is found once a frame, by the first disc drawn.
let focusFrame = -1
let focus: { at: any; distance: number; radius: number } | null = null
let scratch: any = null
// A disc no wider on screen than `DISC_MOST` pixels (the selected one twice that): up close the space
// between documents keeps growing and the discs do not, so a tight group comes apart.
const DISC_MOST = 34
function fitDisc(sprite: any, n: GNode, renderer: any, camera: any) {
  const most = DISC_MOST * (n.id === selected.value?.id ? 2 : 1) * pixelSize(camera.position.distanceTo(sprite.position), renderer, camera)
  const k = Math.min(sprite.userData.d, most)
  if (sprite.scale.x !== k) { sprite.scale.set(k, k, 1); sprite.updateMatrixWorld() }
}
// How much of a disc in front of the selected one is left: enough to see it is there.
const FADED = 0.45
function keepFocusInSight(sprite: any, n: GNode, renderer: any, camera: any) {
  if (renderer.info.render.frame !== focusFrame) {
    focusFrame = renderer.info.render.frame
    const f = selected.value && sprites.get(selected.value.id)
    if (f) {
      const distance = camera.position.distanceTo(f.sprite.position)
      focus = { at: f.sprite.position.clone().project(camera), distance,
                radius: f.sprite.scale.x / 2 / pixelSize(distance, renderer, camera) }
    } else focus = null
  }
  let opacity = 1
  const distance = focus && n.id !== selected.value?.id ? camera.position.distanceTo(sprite.position) : Infinity
  if (focus && distance < focus.distance) {
    const at = (scratch ??= sprite.position.clone()).copy(sprite.position).project(camera), el = renderer.domElement
    const apart = Math.hypot((at.x - focus.at.x) * el.clientWidth / 2, (at.y - focus.at.y) * el.clientHeight / 2)
    if (apart < focus.radius + sprite.scale.x / 2 / pixelSize(distance, renderer, camera) + 4) opacity = FADED
  }
  // Eased toward it a frame at a time, so a disc passing in front fades and returns rather than blinking.
  const now = sprite.material.opacity
  if (Math.abs(now - opacity) > 0.01) sprite.material.opacity = now + (opacity - now) * 0.2
  else if (now !== opacity) sprite.material.opacity = opacity
}
// The clusters that matter to what one is looking at: a cluster gone to from the legend, or the selected
// document's and those of its nearest. Null when nothing is in view in particular. The other clusters'
// names are dimmed to `DIMMED`.
const relevantClusters = computed<Set<number> | null>(() => {
  if (litRow.value) return litRow.value.startsWith('c') ? new Set([Number(litRow.value.slice(1))]) : null
  const s = selected.value
  if (!s) return null
  return new Set([s.cluster, ...nearSelected.value.map(x => x.node.cluster)].filter((c): c is number => c !== undefined))
})
// The space's cluster names, with their clusters.
const clusterLabels: { sprite: any; id: number }[] = []
// The selected document marked where it is, its ring and short title, and the one peeked at its ring (the
// tooltip by the pointer names the one pointed at).
function drawFocus2d(ctx: CanvasRenderingContext2D, scale: number) {
  const nodes: GNode[] = graph?.graphData().nodes ?? []
  const at = (d: Node | null) => (d ? nodes.find(x => x.id === d.id && x.x !== undefined) : undefined)
  const s = at(selected.value), p = at(peek.value)
  ctx.save()
  if (s) { ring2d(ctx, s, scale); if (p !== s) title2d(ctx, s, scale) }
  if (p && p !== s) ring2d(ctx, p, scale)
  ctx.restore()
}
// A thin ring in the brand colour around a node, and a faint wider one.
function ring2d(ctx: CanvasRenderingContext2D, n: GNode, scale: number) {
  const r = flatRadius(n)
  ctx.strokeStyle = BRAND + 'c0'; ctx.lineWidth = 1.5 / scale
  ctx.beginPath(); ctx.arc(n.x, n.y, r + 3 / scale, 0, 2 * Math.PI); ctx.stroke()
  ctx.strokeStyle = BRAND + '26'; ctx.lineWidth = 3 / scale
  ctx.beginPath(); ctx.arc(n.x, n.y, r + 8 / scale, 0, 2 * Math.PI); ctx.stroke()
}
// A node's short title above where its ring is, on a backing, a constant size on screen.
function title2d(ctx: CanvasRenderingContext2D, n: GNode, scale: number) {
  const text = shortTitle(n.title)
  ctx.font = `600 ${13 / scale}px system-ui, sans-serif`
  ctx.textAlign = 'left'; ctx.textBaseline = 'middle'
  const w = ctx.measureText(text).width + 12 / scale, h = 20 / scale
  const { box, from, to } = callout(n, w, h, scale)
  // The leader, from the ring to the label.
  ctx.strokeStyle = BRAND + 'b0'; ctx.lineWidth = 1 / scale
  ctx.beginPath(); ctx.moveTo(from[0], from[1]); ctx.lineTo(to[0], to[1]); ctx.stroke()
  ctx.fillStyle = isDark.value ? 'rgba(17,17,22,0.88)' : 'rgba(250,250,250,0.92)'
  ctx.beginPath(); ctx.roundRect(box.x0, box.y0, w, h, 4 / scale); ctx.fill()
  ctx.strokeStyle = BRAND; ctx.stroke()
  ctx.fillStyle = isDark.value ? '#f0f0f8' : '#1a1a24'
  ctx.fillText(text, box.x0 + 6 / scale, box.y0 + h / 2)
}
// Where a node's callout goes: a label `w` by `h` set off from its ring, on the side whose box covers the
// fewest discs, the up and right sides first among equals; kept on that side until another covers
// clearly fewer, so it does not jump as the view moves. With the points the leader runs between.
const CALLOUT_SIDES = [-45, -135, 45, 135, -90, 90, 0, 180].map(d => (d * Math.PI) / 180)
let calloutSide = { id: '', side: 0 }
function callout(n: GNode, w: number, h: number, scale: number) {
  const r = flatRadius(n) + 9 / scale, reach = 26 / scale
  const place = (a: number) => {
    const dx = Math.cos(a), dy = Math.sin(a)
    const ax = n.x + (r + reach) * dx, ay = n.y + (r + reach) * dy
    const x0 = dx > 0.3 ? ax : dx < -0.3 ? ax - w : ax - w / 2
    const y0 = dy < -0.3 ? ay - h : dy > 0.3 ? ay : ay - h / 2
    return { box: { x0, y0, x1: x0 + w, y1: y0 + h }, from: [n.x + r * dx, n.y + r * dy], to: [ax, ay] }
  }
  const nodes: GNode[] = graph?.graphData().nodes ?? []
  const covered = (b: { x0: number; y0: number; x1: number; y1: number }) => {
    let k = 0
    for (const m of nodes) {
      if (m === n || m.x === undefined) continue
      const q = flatRadius(m)
      if (m.x + q > b.x0 && m.x - q < b.x1 && m.y + q > b.y0 && m.y - q < b.y1) k++
    }
    return k
  }
  // A side that puts the label under the card or the panel, or off the screen, is the worst there is.
  const open = uncovered()
  const hidden = (b: { x0: number; y0: number; x1: number; y1: number }) => {
    const p = graph.graph2ScreenCoords(b.x0, b.y0), q = graph.graph2ScreenCoords(b.x1, b.y1)
    return p.x < open.left || q.x > open.right || p.y < open.top || q.y > open.bottom
  }
  const counts = CALLOUT_SIDES.map(a => { const b = place(a).box; return hidden(b) ? 1e6 : covered(b) })
  let best = 0
  counts.forEach((c, i) => { if (c < counts[best]) best = i })
  if (calloutSide.id === n.id && counts[calloutSide.side] <= counts[best] + 1) best = calloutSide.side
  calloutSide = { id: n.id, side: best }
  return place(CALLOUT_SIDES[best])
}
// A title short enough to label a node with.
// In the space, the selected document's title, kept above its disc whichever way the camera turns.
let SpriteTextOf: any = null
let title3d: any = null
function showTitle3d() {
  const f = selected.value && sprites.get(selected.value.id)
  if (title3d && title3d.userData.id !== f?.node.id) {
    const leader = title3d.userData.leader
    graph?.scene().remove(title3d); title3d.material.map?.dispose(); title3d.material.dispose(); title3d = null
    if (leader) { graph?.scene().remove(leader); leader.geometry.dispose(); leader.material.dispose() }
  }
  if (!f || title3d || !SpriteTextOf || !graph) return
  const t = new SpriteTextOf(shortTitle(f.node.title), 5, isDark.value ? '#f0f0f8' : '#1a1a24')
  t.fontWeight = '600'
  t.backgroundColor = isDark.value ? 'rgba(17,17,22,0.85)' : 'rgba(250,250,250,0.9)'
  t.borderColor = BRAND; t.borderWidth = 0.4; t.borderRadius = 3; t.padding = [3, 1.5]
  t.material.depthTest = false; t.material.depthWrite = false
  t.renderOrder = 1002
  t.userData.id = f.node.id
  capHeight(t, 18, 22)
  // A callout: the label set off up and to the right of the disc on screen, a leader running to it, so it
  // does not lie over the documents around the disc.
  const leaderGeometry = new three.BufferGeometry()
  leaderGeometry.setAttribute('position', new three.Float32BufferAttribute([0, 0, 0, 0, 0, 0], 3))
  const leader = new three.Line(leaderGeometry, new three.LineBasicMaterial({ color: BRAND, transparent: true, opacity: 0.7, depthTest: false }))
  leader.renderOrder = 1001
  leader.frustumCulled = false
  t.userData.leader = leader
  const sized = t.onBeforeRender
  const up = new three.Vector3(), right = new three.Vector3(), dir = new three.Vector3(), from = new three.Vector3(), to = new three.Vector3()
  t.onBeforeRender = (renderer: any, scene: any, camera: any) => {
    sized(renderer, scene, camera)
    up.setFromMatrixColumn(camera.matrixWorld, 1).normalize()
    right.setFromMatrixColumn(camera.matrixWorld, 0).normalize()
    // Up and to the right where the label fits beside what the card and the panel leave open, else up
    // and to the left, else straight up and centred over the disc, so it stays in view.
    const px = pixelSize(camera.position.distanceTo(f.sprite.position), renderer, camera)
    const open = uncovered(), onScreen = f.sprite.position.clone().project(camera)
    const x = (onScreen.x + 1) / 2 * open.width, wide = t.scale.x / px + 40
    const side = x + wide <= open.right ? 1 : x - wide >= open.left ? -1 : 0
    right.multiplyScalar(side)
    dir.copy(up).add(right).normalize()
    const radius = f.sprite.scale.x / 2, reach = 26 * px
    from.copy(f.sprite.position).addScaledVector(dir, radius * 1.1)
    to.copy(f.sprite.position).addScaledVector(dir, radius * 1.1 + reach)
    // Its near corner at the leader's end, or its middle when it is centred.
    t.position.copy(to).addScaledVector(right, t.scale.x / 2).addScaledVector(up, t.scale.y / 2)
    t.updateMatrixWorld()
    const at = leaderGeometry.attributes.position
    at.setXYZ(0, from.x, from.y, from.z); at.setXYZ(1, to.x, to.y, to.z); at.needsUpdate = true
  }
  title3d = t
  graph.scene().add(t)
  graph.scene().add(leader)
}
// In the space, a ring sprite over the selected disc, drawn over everything but the labels, breathing slowly.
let ring3d: any = null
function showRing3d() {
  if (!graph || view.value !== '3d' || !three) return
  if (!ring3d) {
    const px = 128, c = document.createElement('canvas')
    c.width = c.height = px
    const ctx = c.getContext('2d')!
    ctx.strokeStyle = '#ffffff'
    ctx.lineWidth = 5; ctx.beginPath(); ctx.arc(px / 2, px / 2, px / 2 - 22, 0, 2 * Math.PI); ctx.stroke()
    ctx.globalAlpha = 0.15; ctx.lineWidth = 6; ctx.beginPath(); ctx.arc(px / 2, px / 2, px / 2 - 8, 0, 2 * Math.PI); ctx.stroke()
    const map = new three.CanvasTexture(c)
    map.colorSpace = three.SRGBColorSpace
    ring3d = new three.Sprite(new three.SpriteMaterial({ map, color: BRAND, transparent: true, opacity: 0.75, depthTest: false, depthWrite: false }))
    ring3d.renderOrder = 998
    ring3d.onBeforeRender = () => {
      const f = lit.value && sprites.get(lit.value.id)
      if (!f) return
      const k = f.sprite.scale.x * 1.8
      ring3d.position.copy(f.sprite.position)
      ring3d.scale.set(k, k, 1)
      ring3d.updateMatrixWorld()
    }
    graph.scene().add(ring3d)
  }
  ring3d.visible = !!(lit.value && sprites.has(lit.value.id))
  showTitle3d()
}
let three: any = null
let nearest3d: any = null
async function showNearest3d() {
  if (!graph || view.value !== '3d' || !three) return
  if (nearest3d) { graph.scene().remove(nearest3d); nearest3d.traverse((o: any) => { o.geometry?.dispose?.(); o.material?.map?.dispose?.(); o.material?.dispose?.() }) }
  nearest3d = null
  const lines = nearestShown()
  if (!lines.length) return
  const SpriteText = (await import('three-spritetext')).default as any
  const group = new three.Group()
  const pos: number[] = [], col: number[] = []
  const brand = new three.Color(BRAND), bg = new three.Color(isDark.value ? 0x111116 : 0xfafafa)
  for (const { from, to, t } of lines) {
    const c = bg.clone().lerp(brand, 0.15 + 0.85 * t)
    pos.push(from.x, from.y, from.z, to.x, to.y, to.z)
    col.push(c.r, c.g, c.b, c.r, c.g, c.b)
    const label = new SpriteText(`${Math.round(lines.find(l => l.to === to)!.similarity * 100)}%`, 4,
                                 isDark.value ? 'rgba(230,230,245,0.9)' : 'rgba(40,40,60,0.9)')
    label.material.depthTest = false
    label.renderOrder = 1001
    label.position.set(to.x, to.y + 6, to.z)
    capHeight(label, 10, 14)
    group.add(label)
  }
  const geometry = new three.BufferGeometry()
  geometry.setAttribute('position', new three.Float32BufferAttribute(pos, 3))
  geometry.setAttribute('color', new three.Float32BufferAttribute(col, 3))
  group.add(new three.LineSegments(geometry, new three.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.95 })))
  nearest3d = group
  graph.scene().add(group)
}
// One of a list of shown kinds turned on or off.
// The space's node discs, by id, with the nodes they draw.
const sprites = new Map<string, { sprite: any; node: GNode }>()
// A disc's width: a little smaller than the sphere 3d-force-graph would draw for the node (radius 4·∛val),
// as closely as the layout packs them.
const spriteSize = (n: GNode) => 2 * roomy(2.5 * Math.cbrt(size(n)) * packing.value, n)
// How a linked document stands to the one shown: what it does to this one, or this one to it.

// Redrawn as what is shown changes; recoloured as the selection, hits and colours do.
watch([view, fly, layout, isDark], () => draw())
// What is shown changing leaves the view where it is: only the data is given again, once a change settles.
let refreshTimer: ReturnType<typeof setTimeout> | undefined
watch([shownLinks, shownKinds, threshold, showUnlinked], () => {
  clearTimeout(refreshTimer)
  refreshTimer = setTimeout(refresh, 120)
}, { deep: true })
function refresh() {
  if (!graph) return
  // From an empty map, drawn afresh, which frames what is now shown.
  if (!graph.graphData().nodes.length) return draw()
  const { nodes, links } = graphData()
  if (view.value === '2d') centres = clusterCentres(nodes, clusterName)
  graph.graphData({ nodes, links })
  restyle()
}
watch([selected, peek, hits, colourBy, litRow, standing], restyle)
watch(colourBy, () => { litRow.value = null })
// Recoloured and resized in place: the space's discs directly, the map's through its accessors.
function restyle() {
  if (!graph) return
  graph.linkColor(linkColour)
  if (view.value === '2d') graph.linkWidth(linkWidth2d)
  showNearest3d()
  showRing3d()
  showTrail3d()
  const rel = relevantClusters.value
  for (const { sprite, id } of clusterLabels) sprite.material.opacity = !rel || rel.has(id) ? 1 : DIMMED
  if (view.value === '2d') { graph.nodeColor(shade).nodeVal(flatVal); return }
  for (const { sprite, node } of sprites.values()) {
    sprite.material.color.set(shade(node))
    const d = spriteSize(node)
    sprite.userData.d = d; sprite.scale.set(d, d, 1)
    const focused = node.id === selected.value?.id
    sprite.material.depthTest = !focused
    sprite.renderOrder = focused ? 999 : 0
  }
}

const resize = () => { if (graph && box.value) graph.width(box.value.clientWidth).height(box.value.clientHeight) }
// The explore frame filling the screen, and back.
const frame = ref<HTMLDivElement | null>(null)
const full = ref(false)
function fullScreen() {
  if (document.fullscreenElement) document.exitFullscreen()
  else frame.value?.requestFullscreen?.()
}
const onFullScreen = () => { full.value = document.fullscreenElement === frame.value; nextTick(resize) }
// Where the top row ends, however many lines it wraps to: the panels open below it.
const bar = ref<HTMLElement | null>(null)
const barBottom = ref(52)
onLive(() => {
  const measure = () => { if (bar.value) barBottom.value = bar.value.offsetTop + bar.value.offsetHeight + 8 }
  const watcher = new ResizeObserver(measure)
  if (bar.value) watcher.observe(bar.value)
  measure()
  return () => watcher.disconnect()
})
onLive(() => {
  const hold = () => camera.stop()
  box.value?.addEventListener('pointerdown', hold)
  box.value?.addEventListener('wheel', hold, { passive: true })
  return () => { box.value?.removeEventListener('pointerdown', hold); box.value?.removeEventListener('wheel', hold); camera.stop() }
})
onLive(() => {
  document.documentElement.classList.add('kbx-takeover')
  subset.value = new URLSearchParams(location.search).get('set') ?? ''
  load()
  addEventListener('popstate', fromAddress)
  addEventListener('resize', resize)
  document.addEventListener('fullscreenchange', onFullScreen)
  addEventListener('keydown', key)
  addEventListener('keydown', altKey); addEventListener('keyup', altKey); addEventListener('blur', altGone)
  box.value?.addEventListener('pointermove', altKey)
  box.value?.addEventListener('pointerleave', unpointed)
  return () => {
    removeEventListener('resize', resize); removeEventListener('keydown', key); removeEventListener('popstate', fromAddress)
    removeEventListener('keydown', altKey); removeEventListener('keyup', altKey); removeEventListener('blur', altGone)
    box.value?.removeEventListener('pointermove', altKey)
    box.value?.removeEventListener('pointerleave', unpointed)
    document.documentElement.classList.remove('kbx-takeover')
    document.removeEventListener('fullscreenchange', onFullScreen)
    clearTimeout(jobTimer); stopDrift(); graph?._destructor?.()
  }
})

// ── Travelling ─────────────────────────────────────────────────────────────────────────────────────

const trail: Node[] = []
let lastClick = { id: '', at: 0 }

function clicked(n: GNode, e?: MouseEvent) {
  const now = Date.now()
  if (lastClick.id === n.id && now - lastClick.at < 350) { open(n); return }
  lastClick = { id: n.id, at: now }
  const doc = byId.value.get(n.id) ?? n
  // With ⌥: chosen where it is, its card shown and the view left as it is.
  if (e?.altKey) {
    if (selected.value && selected.value.id !== doc.id) trail.push(selected.value)
    stopDrift()
    selected.value = doc
    return
  }
  go(doc)
}

// Peeking: the document under the pointer while ⌥ is held (see `peek`).
let altHeld = false
function peekNow() {
  const n = altHeld ? pointed.value : null
  if (n?.id !== peek.value?.id) peek.value = n
}
function hovered(n: GNode | null) {
  const d = n ? byId.value.get(n.id) ?? n : null
  if (d?.id !== pointed.value?.id) pointed.value = d
  peekNow()
}
// The map's document under the pointer, by where each is drawn and how large: force-graph's own hover
// reads a copy of the canvas it redraws at most every 800 ms, which misses for a moment after a zoom or pan.
function nodeAt(e: PointerEvent): GNode | null {
  if (!graph || !box.value) return null
  const r = box.value.getBoundingClientRect()
  const p = graph.screen2GraphCoords(e.clientX - r.left, e.clientY - r.top), k = graph.zoom()
  let best: GNode | null = null, apart = Infinity
  for (const n of graph.graphData().nodes as GNode[]) {
    if (n.x === undefined) continue
    const d = Math.hypot(n.x - p.x, n.y - p.y)
    if (d < flatRadius(n) + 3 / k && d < apart) { best = n; apart = d }
  }
  return best
}
// Where the pointer is over the map, for the tooltip of the document under it.
const tipAt = shallowRef({ x: 0, y: 0 })
function altKey(e: KeyboardEvent | PointerEvent) {
  if (e instanceof PointerEvent && frame.value) {
    const r = frame.value.getBoundingClientRect()
    tipAt.value = { x: e.clientX - r.left, y: e.clientY - r.top }
    if (drawnView === '2d') hovered(nodeAt(e))
  }
  if (e.altKey === altHeld) return
  altHeld = e.altKey
  peekNow()
}
const altGone = () => { altHeld = false; peekNow() }
const unpointed = () => hovered(null)

/** Move the view to `n` and show its card, keeping where one came from. */
// To document `n`: `remember`ed for Back; in the map, closer in where `zoomIn` asks (a person picking it).
function go(n: Node, remember = true, zoomIn = true) {
  if (remember && selected.value && selected.value.id !== n.id) trail.push(selected.value)
  selected.value = n
  const g = graph?.graphData().nodes.find((x: GNode) => x.id === n.id)
  if (!g || !placed(g)) return
  const [x, y, z] = spot(g)
  if (drawnView === '2d') camera.to([x, y, Math.log(zoomIn ? Math.max(graph.zoom(), 3) : graph.zoom())], moveMs(900))
  else {
    // From the side the view is turned to now, at the distance it is (not farther than a document's
    // neighbourhood needs): the view slides across and turns about the document, without swinging round.
    const v = readView()!, back = [v[0] - v[3], v[1] - v[4], v[2] - v[5]]
    const away = Math.hypot(...back) || 1, d = Math.min(Math.max(away, 60), 140)
    camera.to([x + back[0] / away * d, y + back[1] / away * d, z + back[2] / away * d, x, y, z], moveMs(1400))
  }
}
function back() { const n = trail.pop(); if (n) go(n, false) }
// A graph just drawn: shown first as the one before it was (`was`). The same map again stays there; another
// moves to the selected document, at the zoom it has, or to the whole map.
function settle(was: View | null, same = false) {
  drawnView = view.value
  if (was) applyView(was)
  if (same) { keepSelected(false); return }
  setTimeout(() => keepSelected() || frameAll(900), was ? 0 : 300)
}
// After the map is drawn again (another view, layout or theme), the selected document stays selected and
// in view; false when there is none on this map to keep.
function keepSelected(move = true) {
  const n = selected.value && byId.value.get(selected.value.id)
  if (!n || !graph?.graphData().nodes.some((x: GNode) => x.id === n.id && placed(x))) return false
  selected.value = n
  if (move) go(n, false, false)
  restyle()
  return true
}
const open = (n: Node) => window.open(n.page, '_blank', 'noopener')

// Searching: Zemi's search, its hits lit where they lie; Enter goes to the best, Tab to the next.
const query = ref('')
const order = ref<string[]>([])
let at = -1
let searchTimer: ReturnType<typeof setTimeout> | undefined
watch(query, q => {
  clearTimeout(searchTimer)
  if (!q.trim()) { hits.value = new Map(); order.value = []; return }
  searchTimer = setTimeout(async () => {
    try {
      const got = await getJSON(`/api/search?q=${encodeURIComponent(q)}&limit=25`)
      const found = (got.hits ?? []).filter((h: any) => byId.value.has(h.id))
      const top = found[0]?.score || 1
      hits.value = new Map(found.map((h: any) => [h.id, Math.max(0.25, h.score / top)]))
      order.value = found.map((h: any) => h.id)
      at = -1
      // A new search shows its matches: the selected document set down, the view moving to take them in.
      if (selected.value) selected.value = null
      await nextTick()                                     // the matches' list drawn, so the view frames beside it
      const shown = new Set(order.value.slice(0, 12))
      frameNodes((graph?.graphData().nodes ?? []).filter((n: GNode) => shown.has(n.id) && placed(n)), 0.9)
    } catch { /* left as it was */ }
  }, 350)
})
// A search's best matches, listed while none is selected.
const topHits = computed(() => order.value.slice(0, 8).map(id => ({ node: byId.value.get(id)!, strength: hits.value.get(id) ?? 0 }))
                                          .filter(h => h.node))
function next(step = 1) {
  if (!order.value.length) return
  at = (at + step + order.value.length) % order.value.length
  go(byId.value.get(order.value[at])!)
}

// Drifting: from where one is to its nearest not yet seen, pausing at each.
const drifting = ref(false)
let driftTimer: ReturnType<typeof setInterval> | undefined
const seen = new Set<string>()
// Where a drift has been, in order, with how alike each step was to the one before.
const driftTrail = ref<Step[]>([])
watch(() => driftTrail.value.length, () => showTrail3d())
// The trail drawn where it went: a line through each document in turn, the earliest steps faintest.
function trailNodes(): GNode[] {
  if (driftTrail.value.length < 2 || !graph) return []
  const at = new Map<string, GNode>(graph.graphData().nodes.map((n: GNode) => [n.id, n]))
  return driftTrail.value.map(t => at.get(t.node.id)).filter((n): n is GNode => !!n && n.x !== undefined)
}
function drawTrail2d(ctx: CanvasRenderingContext2D, scale: number) {
  const ns = trailNodes()
  if (ns.length < 2) return
  ctx.save()
  ctx.lineCap = 'round'; ctx.lineWidth = 2.5 / scale
  for (let i = 1; i < ns.length; i++) {
    ctx.strokeStyle = TRAIL + Math.round((0.25 + 0.75 * i / (ns.length - 1)) * 255).toString(16).padStart(2, '0')
    ctx.beginPath(); ctx.moveTo(ns[i - 1].x, ns[i - 1].y); ctx.lineTo(ns[i].x, ns[i].y); ctx.stroke()
  }
  ctx.fillStyle = TRAIL
  for (const n of ns) { ctx.beginPath(); ctx.arc(n.x, n.y, 2.5 / scale, 0, 2 * Math.PI); ctx.fill() }
  ctx.restore()
}
let trail3d: any = null
function showTrail3d() {
  if (!graph || view.value !== '3d' || !three) return
  if (trail3d) { graph.scene().remove(trail3d); trail3d.traverse((o: any) => { o.geometry?.dispose(); o.material?.dispose() }); trail3d = null }
  const ps = driftTrail.value.map(t => sprites.get(t.node.id)?.sprite.position).filter(Boolean)
  if (ps.length < 2) return
  const bg = new three.Color(isDark.value ? 0x111116 : 0xfafafa), c = new three.Color(TRAIL)
  const cols = ps.flatMap((_, i) => { const k = bg.clone().lerp(c, 0.3 + 0.7 * i / (ps.length - 1)); return [k.r, k.g, k.b] })
  const geometry = new three.BufferGeometry().setFromPoints(ps)
  geometry.setAttribute('color', new three.Float32BufferAttribute(cols, 3))
  // A line a pixel wide is lost among the others: a dot at each step, a constant size on screen, marks it.
  trail3d = new three.Group()
  const line = new three.Line(geometry, new three.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.95, depthTest: false }))
  const dots = new three.Points(geometry.clone(), new three.PointsMaterial({ vertexColors: true, size: 7, sizeAttenuation: false, depthTest: false }))
  line.renderOrder = dots.renderOrder = 997
  trail3d.add(line, dots)
  graph.scene().add(trail3d)
}
function drift() {
  if (drifting.value) { stopDrift(); return }
  const start = selected.value ?? data.value?.nodes.find(n => n.x) ?? null
  if (!start) return
  drifting.value = true
  seen.clear(); seen.add(start.id)
  driftTrail.value = [{ node: start }]
  go(start)
  driftTimer = setInterval(driftStep, driftEvery.value * 1000)
}
function driftStep() {
  const here = selected.value
  const nextOne = (nearOf.value.get(here?.id ?? '') ?? []).find(x => !seen.has(x.node.id) && visibleNode(x.node))
  if (!nextOne) { stopDrift(); return }
  seen.add(nextOne.node.id)
  driftTrail.value.push({ node: nextOne.node, similarity: nextOne.similarity })
  go(nextOne.node)
}
// How long a drift stays at each document, in seconds (a setting); changed while drifting, from the next step.
watch(driftEvery, v => {
  if (drifting.value) { clearInterval(driftTimer); driftTimer = setInterval(driftStep, v * 1000) }
})
// The view's move to a document: quicker when drifting fast, so it arrives before the next step.
const moveMs = (most: number) => (drifting.value ? Math.min(most, driftEvery.value * 600) : most)
function stopDrift() { drifting.value = false; clearInterval(driftTimer) }
// The trail as text: a numbered list of the documents, how alike each was to the one before, and their pages.
async function copyTrail() {
  const lines = driftTrail.value.map(({ node: n, similarity }, i) =>
    `${i + 1}. ${n.title} (${[kindName(n.kind), n.year].filter(Boolean).join(', ')})` +
    (similarity === undefined ? '' : `, ${Math.round(similarity * 100)}% alike`) + (n.page ? `\n   ${n.page}` : ''))
  try {
    await navigator.clipboard.writeText(`Drift from ${driftTrail.value[0].node.title}\n\n${lines.join('\n')}\n`)
    said.value = `Copied the trail of ${driftTrail.value.length}`
  } catch (e: any) { said.value = `Not copied: ${e.message ?? e}` }
}

function key(e: KeyboardEvent) {
  const typing = (e.target as HTMLElement)?.closest?.('input, textarea')
  if (e.key === 'Enter' && typing && order.value.length) { e.preventDefault(); at = -1; next() }
  else if (e.key === 'Tab' && order.value.length && (typing || !e.target || e.target === document.body)) { e.preventDefault(); next(e.shiftKey ? -1 : 1) }
  if (typing) return
  if (e.key === 'Backspace') { e.preventDefault(); back() }
  else if ((e.key === 'f' || e.key === 'F') && view.value === '3d') fly.value = !fly.value
  else if (e.key === 'Escape') { selected.value = null; stopDrift() }
}

// ── Acting on a pair ───────────────────────────────────────────────────────────────────────────────

const said = ref('')
async function copyView(n: Node) {
  try {
    await navigator.clipboard.writeText(new URL(exploreHref(n.id), window.location.href).href)
    said.value = 'Copied the link to this view'
  } catch (e: any) { said.value = `Not copied: ${e.message ?? e}` }
}
async function copyCitation(n: Node) {
  try {
    const c = await getJSON(`/api/cite/${encodeURIComponent(n.id)}`)
    await navigator.clipboard.writeText(c.cite)
    said.value = `Copied ${c.cite}`
  } catch (e: any) { said.value = `Not copied: ${e.message ?? e}` }
}
async function addEvidence(finding: Node, doc: Node) {
  try {
    await post(`/api/findings/${finding.id}/evidence`, JSON.stringify({ kind: doc.kind === 'record' ? 'record' : doc.kind === 'code' ? 'code' : 'paper', target: doc.id }))
    said.value = `Added to ${finding.id} as evidence`
    await load()
  } catch (e: any) { said.value = `Not added: ${e.message ?? e}` }
}
// A pair judged: related, made a link of the reader's; or not, no longer suggested.
async function judge(p: Pair, related: boolean) {
  const g = data.value
  if (!g) return
  try {
    await post('/api/graph/pair', JSON.stringify({ a: p.a.id, b: p.b.id, related }))
    const e = g.similar[p.at]
    if (related) { e[3] = true; g.links.push([e[0], e[1], 'related']) } else e[4] = true
    triggerRef(data)
    refresh()
    said.value = related ? `Linked as related: ${p.a.title} and ${p.b.title}` : 'No longer suggested'
  } catch (e: any) { said.value = `Not saved: ${e.message ?? e}` }
}
const showPairs = ref(false)
// The words each pair shown shares, fetched for the pairs on screen, by pair.
const shared = ref<Map<string, string[]>>(new Map())
const pairKey = (p: Pair) => `${p.a.id},${p.b.id}`
let sharedTimer: ReturnType<typeof setTimeout> | undefined
watch([pairs, showPairs], () => {
  clearTimeout(sharedTimer)
  if (!showPairs.value) return
  const todo = pairs.value.filter(p => !shared.value.has(pairKey(p)))
  if (!todo.length) return
  sharedTimer = setTimeout(async () => {
    try {
      const got = await getJSON(`/api/graph/shared?pairs=${encodeURIComponent(todo.map(pairKey).join(';'))}`)
      const next = new Map(shared.value)
      todo.forEach((p, i) => next.set(pairKey(p), got.shared?.[i] ?? []))
      shared.value = next
    } catch { /* left without */ }
  }, 200)
})
function goPair(p: Pair) { go(p.a); setTimeout(() => { selected.value = p.a }, 50) }
const nearSelected = computed(() => (nearOf.value.get(selected.value?.id ?? '') ?? []).slice(0, 8))
const nearLit = computed(() => (nearOf.value.get(lit.value?.id ?? '') ?? []).slice(0, 8))
const linkedSelected = computed(() => linksOf.value.get(selected.value?.id ?? '') ?? [])
</script>

<template>
  <KBNeedsService>
    <div ref="frame" class="kbx" :class="{ dark: isDark, full }" :style="{ '--kbx-top': barBottom + 'px' }">
      <div ref="box" class="kbx-canvas"></div>
      <div v-if="pointed && (peek || pointed.id !== selected?.id)" class="kbx-peek-tip" :style="{ left: tipAt.x + 'px', top: tipAt.y + 'px' }"
           role="tooltip">
        <b>{{ pointed.title }}</b>
        <template v-if="peek"><br>{{ [kindName(pointed.kind), pointed.year, clusterName(pointed.cluster)].filter(Boolean).join(' · ') }}</template>
      </div>
      <p v-if="loading" class="kbx-status">Loading the map…</p>
      <p v-else-if="error" class="kbx-status kb-error">{{ error }}</p>
      <p v-else-if="data?.set?.few" class="kbx-status">
        Only {{ data.set.count }} documents in {{ data.set.name }}: a map of its own needs at least {{ data.set.least }}.
        <button class="kbx-btn" @click="leaveSet">Back to all documents</button>
      </p>
      <p v-else-if="data && !data.nodes.length && !building" class="kbx-status">Nothing to map yet: documents appear here once they are embedded.</p>
      <p v-else-if="data && !data.nodes.some(visibleNode)" class="kbx-status">
        No documents of the kinds chosen in Show.
        <button class="kbx-btn" @click="shownKinds.splice(0, shownKinds.length, ...NODE_KINDS.map(([k]) => k))">Show all</button>
      </p>

      <div ref="bar" class="kbx-bar">
        <KBExploreCrumbs v-if="subset" v-model:size="setSize" :set="data?.set" @leave="leaveSet" @map="mapSet" @resize="load()" />
        <input v-model="query" type="search" class="kb-field kbx-search" placeholder="Search the map… (Enter to go, Tab for the next)" />
        <button v-if="query.trim() && order.length" class="kbx-btn" title="Lay out the documents this search finds as a map of their own"
                @click="mapSet('q:' + query.trim())">Map these</button>
        <div class="kbx-seg" role="group" aria-label="View">
          <button :class="{ on: view === '2d' }" @click="view = '2d'">Map</button>
          <button :class="{ on: view === '3d' }" @click="view = '3d'">Space</button>
        </div>
        <a class="kbx-btn" :href="kbPage('authors')">Explore authors</a>
        <button class="kbx-btn" :class="{ on: drifting }" title="Move from document to document along the nearest in meaning, one every few seconds" @click="drift">{{ drifting ? 'Stop' : 'Drift' }}</button>
        <label v-if="drifting" class="kbx-speed" title="Seconds at each document">
          <input v-model.number="driftEvery" type="range" min="0.1" max="10" step="0.1" aria-label="Seconds at each document">
          <span>{{ driftEvery }} s</span>
        </label>
        <button class="kbx-btn" :class="{ on: showPairs }" title="Pairs of documents close in meaning that nothing links yet" @click="showPairs = !showPairs">Suggested links</button>
        <button v-if="data?.abstract_only" class="kbx-btn" :class="{ on: abstracts }" :title="`${data.abstract_only} papers not read in full, placed by their title and abstract`"
                @click="abstracts = !abstracts">Include abstract only</button>
        <button class="kbx-btn kbx-icon" aria-label="Show the whole map" title="Show the whole map" @click="resetView">
          <KBIcon name="focus" :size="17" />
        </button>
        <button class="kbx-btn kbx-icon" :class="{ on: panelOpen }" aria-controls="kbx-panel" :aria-expanded="panelOpen"
                aria-label="The map's legend and settings" title="Legend, layout and what the map shows" @click="panelOpen = !panelOpen">
          <KBIcon name="tune" :size="17" />
        </button>
        <KBShare v-if="full && frame" :dialog-target="frame" />
        <button class="kbx-btn kbx-full" :title="full ? 'Leave full screen (Esc)' : 'Full screen'" :aria-label="full ? 'Leave full screen' : 'Full screen'"
                @click="fullScreen">{{ full ? '⤡' : '⤢' }}</button>
      </div>

      <KBExplorePanel v-if="panelOpen" :legend="legend" :lit-row="litRow" :subset="subset" :projects="projectList" :flying="fly"
                      :least="data?.least ?? 0" :here-row="selected ? legendKey(selected) : null"
                      :layouts="{ umap: !!data?.nodes.some(n => n.ux), pacmap: !!data?.nodes.some(n => n.px) }"
                      @go-to-row="goToRow" @map="mapSet" />

      <div v-if="building" class="kbx-building" role="status">
        <div class="kbx-building-card">
          <p><span class="kb-spinner"></span> {{ building }}</p>
          <div v-if="buildShare !== null" class="kbx-meter" role="progressbar" :aria-valuenow="Math.round(buildShare * 100)"
               aria-valuemin="0" aria-valuemax="100"><span :style="{ width: `${Math.round(buildShare * 100)}%` }"></span></div>
        </div>
      </div>
      <p v-if="said" class="kbx-said" @click="said = ''">{{ said }}</p>

      <KBExploreCard v-if="selected" :node="selected" :detail="detail" :render="render" :colour="colour(selected)"
                     :cluster="clusterName(selected.cluster)" :linked="linkedSelected" :nearest="nearSelected"
                     :can-go-back="trail.length > 0" :short="driftTrail.length > 1"
                     @close="selected = null" @back="back" @open="open(selected!)" @cite="copyCitation(selected!)" @copy-view="copyView(selected!)"
                     @go="go" />


      <KBExploreHits v-if="!selected && query.trim() && topHits.length" :query="query.trim()" :hits="topHits" :total="order.length"
                     :can-map="!subset" @go="go" @map="mapSet('q:' + query.trim())" />
      <KBExploreTrail v-if="driftTrail.length > 1" :steps="driftTrail" :here="selected?.id" :can-map="!subset.startsWith('docs:')"
                      @clear="driftTrail = []" @go="go" @copy="copyTrail" @map="mapDrift" />

      <KBExplorePairs v-if="showPairs" :pairs="pairs" :shared="shared" :has-selection="!!selected" :own-floor="OWN_FLOOR"
                      @close="showPairs = false" @go="go" @go-pair="goPair" @judge="judge" @evidence="addEvidence" @cite="copyCitation" />
    </div>
  </KBNeedsService>
</template>

<style src="./kbExplore.css"></style>
