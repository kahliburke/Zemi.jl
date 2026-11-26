<!--
  Explore the knowledge base (see src/explore.jl): every document the reader may see placed by what it
  is about, on a 2D map or in a 3D space, the clusters of the landscape labelled where they lie, the
  links people made drawn between documents (citations, references, a finding's evidence, a task's
  links), and the pairs close in meaning that no link joins yet. Clicking, searching and drifting
  move the view; in 3D, F flies freely. `?center=<id>` opens it at a document.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, shallowRef, triggerRef, computed, watch, nextTick } from 'vue'
import { useData } from 'vitepress'
import { getJSON, post, can, onLive } from './kbApi'
import { exploreHref } from './kbLinks'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'

type Node = { id: string; kind: string; title: string; year?: string; page: string; links: number; status?: string; project?: string
              access?: 'open' | 'projects' | 'private'; mine?: boolean; read?: boolean
              x?: [number, number]; p?: [number, number, number]; ux?: [number, number]; up?: [number, number, number]; px?: [number, number]; pp?: [number, number, number]
              cluster?: number
              central?: number; rating?: number }
type Cluster = { id: number; name: string; description: string; size: number }
// A subset mapped by itself (`?set=`): what it is, how many documents it has, and whether too few to map.
type SetInfo = { spec: string; kind: string; name: string; count: number; least: number; few: boolean; trail: { spec: string; name: string }[] }
type Graph = { nodes: Node[]; links: [number, number, string][]; similar: [number, number, number, boolean, boolean][]; clusters: Cluster[];
               built_at: string | null; job: string | null; abstracts: boolean; abstract_only: number; set?: SetInfo }
type Near = { node: Node; similarity: number; linked: boolean }
type Pair = { a: Node; b: Node; similarity: number; score: number; at: number }

const { isDark } = useData()

const LINK_KINDS = [['cites', 'Citations'], ['refers', 'References'], ['related', 'Related'], ['evidence', 'Evidence'], ['task', 'Tasks']] as const
const NODE_KINDS = [['paper', 'Papers'], ['record', 'Notes and records'], ['code', 'Codebases'], ['resource', 'Resources'],
                    ['finding', 'Findings'], ['task', 'Tasks']] as const
const KIND_COLOURS: Record<string, string> = { paper: '#5b8def', record: '#3dd68c', code: '#f0a35e', resource: '#c58af9',
                                               finding: '#f6d55c', task: '#ef6f6c' }
const CLUSTER_COLOURS = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7',
                         '#9c755f', '#bab0ac', '#86bcb6', '#d37295', '#8cd17d', '#b6992d', '#499894', '#fabfd2']
// Whose a document is: held for the reader, shared with projects' members, everyone's.
const WHOSE = [['mine', 'Yours'], ['projects', 'Projects\u2019'], ['open', 'Everyone\u2019s']] as const
const WHOSE_COLOURS: Record<string, string> = { mine: '#ff7ab6', projects: '#f0a35e', open: '#5b8def' }
const whose = (n: Node) => (n.mine || n.access === 'private' ? 'mine' : n.access === 'projects' ? 'projects' : 'open')
// A reader's own: what is held for them, and notes and records (on a knowledge base of one, held for no one).
const own = (n: Node) => !!n.mine || n.access === 'private' || n.kind === 'record'
const LINK_COLOURS: Record<string, string> = { cites: '#8ab4f8', refers: '#3dd68c', related: '#c58af9', evidence: '#f6d55c', task: '#ef6f6c' }
const SCALE_2D = 700, SCALE_3D = 360

// What is drawn, kept between visits.
const stored = <T,>(key: string, fallback: T): T => {
  try { const v = localStorage.getItem(`kb-explore-${key}`); return v === null ? fallback : JSON.parse(v) } catch { return fallback }
}
const keep = (key: string, v: unknown) => { try { localStorage.setItem(`kb-explore-${key}`, JSON.stringify(v)) } catch { /* private mode */ } }
const view = ref<'2d' | '3d'>(stored('view', '2d'))
const fly = ref(false)
// Where documents are placed: by t-SNE (close neighbourhoods kept) or UMAP (more of how groups lie to each other).
const layout = ref<'tsne' | 'umap' | 'pacmap'>(stored('layout', 'tsne'))
watch(layout, v => keep('layout', v))
const colourBy = ref<'cluster' | 'kind' | 'whose'>(stored('colour', 'cluster'))
const shownLinks = ref<string[]>(stored('links', ['cites', 'refers', 'related', 'evidence']))
const shownKinds = ref<string[]>(stored('kinds', ['paper', 'record', 'code', 'resource', 'finding']))
const threshold = ref<number>(stored('threshold', 0.8))
// Pairs close in meaning across the whole map: off at first, the selected document's own being drawn from it.
const showUnlinked = ref<boolean>(stored('pairs', false))
// The papers known only by their abstract (the watch's, and those recorded but not yet read): left out
// unless asked for, the map then being of every document.
const abstracts = ref<boolean>(stored('abstracts', false))
watch(abstracts, v => { keep('abstracts', v); if (data.value && data.value.abstracts !== v) load() })
watch(view, v => keep('view', v)); watch(colourBy, v => keep('colour', v)); watch(shownLinks, v => keep('links', v), { deep: true })
watch(shownKinds, v => keep('kinds', v), { deep: true }); watch(threshold, v => keep('threshold', v)); watch(showUnlinked, v => keep('pairs', v))

const data = shallowRef<Graph | null>(null)
const selected = ref<Node | null>(null)
// What the card says of the document selected, asked for once each (see /api/graph/node).
type Detail = { id: string; title: string; authors: string[]; published: string; venue: string; abstract: string; summary: string; excerpt?: string;
                topics: string[]; read: boolean }
const detail = ref<Detail | null>(null)
// What the card reads out: the summary, or a note's opening until it has one, or the abstract.
const cardText = computed(() => detail.value ? detail.value.summary || detail.value.excerpt || detail.value.abstract : '')
const details = new Map<string, Detail>()
const more = ref(false)
const render = shallowRef<Render>(escapeText)
watch(selected, async n => {
  more.value = false
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
const byline = (d: Detail) => [d.authors.length > 3 ? `${d.authors.slice(0, 3).join(', ')} et al.` : d.authors.join(', '),
                               d.venue || d.published.slice(0, 10)].filter(Boolean).join(' · ')
const error = ref('')
const building = ref('')
const loading = ref(true)
const box = ref<HTMLDivElement | null>(null)
let graph: any = null

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
  const out = new Map<string, { node: Node; kind: string; out: boolean }[]>()
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
const scope = ref<'all' | 'cluster' | 'own'>(stored('scope', 'own'))
watch(scope, v => keep('scope', v))
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
    building.value = g.job ? (g.set ? `Laying out ${g.set.count} documents by themselves…` : 'Placing what is new here…') : ''
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
  const center = new URLSearchParams(location.search).get('center')
  if (center && !byId.value.has(center) && !abstracts.value && data.value?.abstract_only) { abstracts.value = true; return }
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
      if (j.status === 'running') { building.value = j.message || building.value; watchJob(id); return }
      building.value = ''
      if (j.status === 'done') await load()
    } catch { building.value = '' }
  }, 2000)
}

// ── Drawing ────────────────────────────────────────────────────────────────────────────────────────

const visibleNode = (n: Node) => shownKinds.value.includes(n.kind)
const hits = ref<Map<string, number>>(new Map())          // a search's hits, by id, with their strength
const near = computed(() => new Set([...(nearOf.value.get(selected.value?.id ?? '') ?? []).map(x => x.node.id),
                                     ...(linksOf.value.get(selected.value?.id ?? '') ?? []).map(x => x.node.id)]))

function colour(n: Node) {
  if (colourBy.value === 'whose' && n.kind !== 'finding' && n.kind !== 'task') return WHOSE_COLOURS[whose(n)]
  if (colourBy.value !== 'cluster' || n.cluster === undefined) return KIND_COLOURS[n.kind] ?? '#999'
  return CLUSTER_COLOURS[(n.cluster - 1) % CLUSTER_COLOURS.length]
}
// What each colour stands for as the map is coloured, among the documents shown, with how many of them.
const legend = computed(() => {
  const g = data.value
  if (!g) return []
  const counts = new Map<string, number>()
  for (const n of g.nodes.filter(visibleNode)) counts.set(legendKey(n), (counts.get(legendKey(n)) ?? 0) + 1)
  const rows = [
    ...g.clusters.map(c => ({ key: `c${c.id}`, colour: CLUSTER_COLOURS[(c.id - 1) % CLUSTER_COLOURS.length], label: c.name || 'Unnamed' })),
    ...WHOSE.map(([k, l]) => ({ key: `w${k}`, colour: WHOSE_COLOURS[k], label: l })),
    ...NODE_KINDS.map(([k, l]) => ({ key: `k${k}`, colour: KIND_COLOURS[k] ?? '#999', label: l })),
  ]
  return rows.filter(r => counts.has(r.key)).map(r => ({ ...r, count: counts.get(r.key)! }))
    .sort((a, b) => (a.key[0] === 'c' && b.key[0] === 'c' ? b.count - a.count : 0))
})
// The legend's row a node falls in, as it is coloured.
function legendKey(n: Node) {
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
  frameNodes((graph?.graphData().nodes ?? []).filter((n: GNode) => legendKey(n) === key && n.x !== undefined), 0.7)
}
// The view framing nodes `ns`: the share `most` of them nearest their middle, so outliers do not hold it far out.
function frameNodes(ns: GNode[], most: number) {
  if (!ns.length || !graph) return
  const mid = ['x', 'y', 'z'].map(a => ns.reduce((t, n) => t + ((n as any)[a] ?? 0), 0) / ns.length)
  const apart = (n: GNode) => Math.hypot(n.x - mid[0], n.y - mid[1], (n.z ?? 0) - mid[2])
  const core = new Set(ns.slice().sort((a, b) => apart(a) - apart(b)).slice(0, Math.max(3, Math.ceil(ns.length * most))).map(n => n.id))
  if (view.value === '2d') { graph.zoomToFit(900, 20, (n: GNode) => core.has(n.id)); return }
  // The space's own fitting aims at the origin; this looks at the middle, from where the camera is.
  const r = Math.max(20, ...ns.filter(n => core.has(n.id)).map(apart))
  const cam = graph.camera(), from = cam.position
  const away = Math.hypot(from.x - mid[0], from.y - mid[1], from.z - mid[2]) || 1
  const d = (r / Math.sin((cam.fov * Math.PI) / 360)) * 1.05
  graph.cameraPosition({ x: mid[0] + (from.x - mid[0]) * d / away, y: mid[1] + (from.y - mid[1]) * d / away,
                         z: mid[2] + (from.z - mid[2]) * d / away }, { x: mid[0], y: mid[1], z: mid[2] }, 1200)
}
watch(selected, n => { if (n) litRow.value = null })
// Back to the whole map in view, nothing lit; the selected document stays selected.
function resetView() {
  stopDrift()
  litRow.value = null
  frameNodes((graph?.graphData().nodes ?? []).filter((n: GNode) => n.x !== undefined), 1)
}
// A legend row's documents shaded from faint to full by how much each stands out in it: its links among
// the documents here (the cluster's middle deciding among the unlinked), how central it is in meaning,
// or the rating the watch's judge gave it.
type ShadeBy = 'off' | 'linked' | 'central' | 'rated'
const SHADE_BY = [['off', 'Off', 'Every document in its full colour'],
                  ['linked', 'Linked', 'Most cited and referred to among the documents here'],
                  ['central', 'Central', 'Nearest in meaning to the middle of the cluster'],
                  ['rated', 'Rated', 'How relevant the watch judged it, 0 to 3; unrated faintest']] as const
const shadeBy = ref<ShadeBy>(stored('shade', 'linked'))
watch(shadeBy, v => keep('shade', v))
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
// `a` towards `b` by `t`, both #rrggbb.
function mix(a: string, b: string, t: number) {
  const ch = (h: string, i: number) => parseInt(h.slice(1 + 2 * i, 3 + 2 * i), 16)
  return '#' + [0, 1, 2].map(i => Math.round(ch(a, i) + (ch(b, i) - ch(a, i)) * t).toString(16).padStart(2, '0')).join('')
}
// The panel on the right: the legend, or what the map shows; open or folded away.
const panelOpen = ref<boolean>(stored('legend', typeof window === 'undefined' || window.innerWidth > 640))
watch(panelOpen, v => keep('legend', v))
const panel = ref<'colours' | 'show'>(stored('panel', 'colours'))
watch(panel, v => keep('panel', v))
const settingsOpen = computed(() => panelOpen.value && panel.value === 'show')
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

// How closely a layout packs its documents, as the median distance from one to its nearest, over a
// sample of them.
function spacing(points: number[][]) {
  if (points.length < 2) return 0
  const step = Math.max(1, Math.floor(points.length / 300)), d: number[] = []
  for (let i = 0; i < points.length; i += step) {
    let least = Infinity
    for (let j = 0; j < points.length; j++) {
      if (j === i) continue
      let s = 0
      for (let k = 0; k < points[i].length; k++) s += (points[i][k] - points[j][k]) ** 2
      if (s < least) least = s
    }
    d.push(Math.sqrt(least))
  }
  d.sort((a, b) => a - b)
  return d[d.length >> 1]
}
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

type GNode = Node & { fx?: number; fy?: number; fz?: number; x?: any; y?: any; z?: any }
type GLink = { source: string; target: string; kind: string; similarity?: number }

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
  return { nodes, links }
}

// The nodes with no place by meaning (findings, tasks, documents only linked to), fixed where they stand
// among those linked to them, a little aside; those linked to none on a ring just outside the map.
// Every node fixed, nothing drifts once drawn.
function placeTheRest(nodes: GNode[], links: GLink[], deep: boolean) {
  const at = new Map(nodes.map(n => [n.id, n]))
  const neighbours = new Map<string, string[]>()
  for (const l of links) {
    if (l.kind === 'similar') continue
    neighbours.set(l.source, [...(neighbours.get(l.source) ?? []), l.target])
    neighbours.set(l.target, [...(neighbours.get(l.target) ?? []), l.source])
  }
  const loose = nodes.filter(n => n.fx === undefined)
  const scale = deep ? SCALE_3D : SCALE_2D
  for (let pass = 0; pass < 3; pass++) {                    // those linked only to the unplaced, once those are
    for (const n of loose) {
      if (n.fx !== undefined) continue
      const placed = (neighbours.get(n.id) ?? []).map(id => at.get(id)!).filter(m => m && m.fx !== undefined)
      if (!placed.length) continue
      const mean = (k: 'fx' | 'fy' | 'fz') => placed.reduce((t, m) => t + (m[k] ?? 0), 0) / placed.length
      const turn = hashTurn(n.id), aside = scale * 0.03
      n.fx = mean('fx') + aside * Math.cos(turn); n.fy = mean('fy') + aside * Math.sin(turn)
      if (deep) n.fz = mean('fz') + aside * Math.sin(2 * turn)
    }
  }
  const rest = loose.filter(n => n.fx === undefined)
  rest.forEach((n, i) => {
    const turn = (2 * Math.PI * i) / Math.max(rest.length, 1)
    n.fx = scale * 1.15 * Math.cos(turn); n.fy = scale * 1.15 * Math.sin(turn)
    if (deep) n.fz = 0
  })
}
// A steady angle from an id, so a node stands on the same side of its neighbours each time.
const hashTurn = (id: string) => [...id].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) / 0xffffffff * 2 * Math.PI

function linkColour(l: GLink) {
  if (l.kind === 'similar') return isDark.value ? 'rgba(200,200,255,0.45)' : 'rgba(60,60,140,0.4)'
  const c = LINK_COLOURS[l.kind] ?? '#999'
  return selected.value && !touches(l, selected.value.id) ? c + '40' : c + 'b0'
}
const endId = (e: any) => (typeof e === 'object' ? e.id : e) as string
const touches = (l: any, id: string) => endId(l.source) === id || endId(l.target) === id

// Each cluster's middle, from its placed nodes, for its label.
function clusterCentres(nodes: GNode[]) {
  const sums = new Map<number, { x: number; y: number; z: number; n: number }>()
  for (const n of nodes) {
    if (n.cluster === undefined || n.fx === undefined) continue
    const s = sums.get(n.cluster) ?? { x: 0, y: 0, z: 0, n: 0 }
    s.x += n.fx; s.y += n.fy!; s.z += n.fz ?? 0; s.n++
    sums.set(n.cluster, s)
  }
  return [...sums].filter(([, s]) => s.n >= 3).map(([id, s]) => ({ id, name: clusterName(id), x: s.x / s.n, y: s.y / s.n, z: s.z / s.n, size: s.n }))
}

// The 2D map's cluster names, where they are drawn.
let centres: ReturnType<typeof clusterCentres> = []
async function draw() {
  if (!box.value || !data.value) return
  graph?._destructor?.()
  box.value.innerHTML = ''
  const el = box.value
  const { nodes, links } = graphData()
  const bg = isDark.value ? '#111116' : '#fafafa'
  const label = (n: Node) => `<div class="kbx-tip"><b>${esc(n.title)}</b><br>${esc([kindName(n.kind), n.year, clusterName(n.cluster)].filter(Boolean).join(' · '))}</div>`
  if (view.value === '2d') {
    const ForceGraph = (await import('force-graph')).default as any
    centres = clusterCentres(nodes)
    graph = new ForceGraph(el)
      .backgroundColor(bg).width(el.clientWidth).height(el.clientHeight)
      .graphData({ nodes, links }).nodeId('id')
      .nodeVal(flatSize).nodeColor(shade).nodeLabel(label)
      .linkColor(linkColour)
      .linkWidth((l: GLink) => (l.kind === 'similar' ? 0.8 : 1.2))
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
    setTimeout(() => keepSelected() || graph?.zoomToFit(600, 40), 300)
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
      .nodeVal(size).nodeLabel(label)
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
      .onNodeClick(clicked).onBackgroundClick(() => { selected.value = null; litRow.value = null })
      .enableNodeDrag(false)
      .cooldownTicks(1)
    graph.d3Force('charge')?.strength(-10)
    graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? (l.similarity ?? 0) * 0.3 : 0.1))
    const fog = (await import('three')).FogExp2
    // A little depth: a tenth faded across the space as first framed, a quarter beyond it.
    graph.scene().fog = new fog(isDark.value ? 0x111116 : 0xfafafa, 0.00035)
    clusterLabels.length = 0
    for (const c of clusterCentres(nodes)) {
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
    setTimeout(() => keepSelected() || graph?.zoomToFit(800, 30), 300)
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
const BRAND = '#8b7cf6'
function nearestShown() {
  const s = selected.value
  if (!s || !graph) return []
  const at = new Map<string, GNode>(graph.graphData().nodes.map((n: GNode) => [n.id, n]))
  const from = at.get(s.id)
  if (!from) return []
  const xs = nearSelected.value.filter(x => at.has(x.node.id))
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
  for (const { to, similarity } of lines) {
    const text = `${Math.round(similarity * 100)}%`
    const x = to.x + Math.sqrt(Math.max(0, size(to))) * 4 + 3 / scale, w = ctx.measureText(text).width + 2 * pad
    ctx.fillStyle = isDark.value ? 'rgba(17,17,22,0.75)' : 'rgba(250,250,250,0.8)'
    ctx.beginPath(); ctx.roundRect(x, to.y - h / 2, w, h, 3 / scale); ctx.fill()
    ctx.fillStyle = isDark.value ? 'rgba(235,235,248,0.95)' : 'rgba(30,30,45,0.95)'
    ctx.fillText(text, x + pad, to.y)
  }
  ctx.restore()
}
// A text sprite in the space kept between `least` and `most` pixels tall on screen: smaller with distance
// within that, never too small to read nor growing past `most` as the camera nears it. Set as it is drawn,
// from the camera's distance and the canvas's height.
function capHeight(sprite: any, least: number, most: number) {
  const base = sprite.scale.clone()
  const at = new (sprite.position.constructor)()
  sprite.onBeforeRender = (renderer: any, _scene: any, camera: any) => {
    const d = camera.position.distanceTo(sprite.getWorldPosition(at))
    const perPixel = 2 * d * Math.tan((camera.fov * Math.PI) / 360) / renderer.domElement.clientHeight
    const px = Math.max(least, Math.min(most, base.y / perPixel))
    sprite.scale.copy(base).multiplyScalar((px * perPixel) / base.y)
    sprite.updateMatrixWorld()
  }
}
// The selected document kept in sight in the space: its disc drawn over whatever is nearer (see `restyle`),
// and the discs between it and the camera that overlap it on screen faded while they do. Where it lies on
// screen is found once a frame, by the first disc drawn.
const pixelSize = (d: number, renderer: any, camera: any) =>
  2 * d * Math.tan((camera.fov * Math.PI) / 360) / renderer.domElement.clientHeight
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
    if (apart < focus.radius + sprite.scale.x / 2 / pixelSize(distance, renderer, camera) + 4) opacity = 0.12
  }
  if (sprite.material.opacity !== opacity) sprite.material.opacity = opacity
}
// The clusters that matter to what one is looking at: a cluster gone to from the legend, or the selected
// document's and those of its nearest. Null when nothing is in view in particular. The other clusters'
// names are dimmed to `DIMMED`.
const DIMMED = 0.4
const relevantClusters = computed<Set<number> | null>(() => {
  if (litRow.value) return litRow.value.startsWith('c') ? new Set([Number(litRow.value.slice(1))]) : null
  const s = selected.value
  if (!s) return null
  return new Set([s.cluster, ...nearSelected.value.map(x => x.node.cluster)].filter((c): c is number => c !== undefined))
})
// The space's cluster names, with their clusters.
const clusterLabels: { sprite: any; id: number }[] = []
// The selected document marked where it is: a thin ring in the brand colour around its node, and a faint wider one.
function drawFocus2d(ctx: CanvasRenderingContext2D, scale: number) {
  const n: GNode | undefined = selected.value ? graph?.graphData().nodes.find((x: GNode) => x.id === selected.value!.id) : undefined
  if (!n || n.x === undefined) return
  const r = Math.sqrt(flatSize(n)) * 4
  ctx.save()
  ctx.strokeStyle = BRAND + 'c0'; ctx.lineWidth = 1.5 / scale
  ctx.beginPath(); ctx.arc(n.x, n.y, r + 3 / scale, 0, 2 * Math.PI); ctx.stroke()
  ctx.strokeStyle = BRAND + '26'; ctx.lineWidth = 3 / scale
  ctx.beginPath(); ctx.arc(n.x, n.y, r + 8 / scale, 0, 2 * Math.PI); ctx.stroke()
  // Its title above the ring, on a backing, a constant size on screen.
  const text = shortTitle(n.title)
  ctx.font = `600 ${13 / scale}px system-ui, sans-serif`
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
  const w = ctx.measureText(text).width + 12 / scale, h = 20 / scale, y = n.y - r - 14 / scale - h / 2
  ctx.fillStyle = isDark.value ? 'rgba(17,17,22,0.85)' : 'rgba(250,250,250,0.9)'
  ctx.beginPath(); ctx.roundRect(n.x - w / 2, y - h / 2, w, h, 4 / scale); ctx.fill()
  ctx.strokeStyle = BRAND; ctx.lineWidth = 1 / scale; ctx.stroke()
  ctx.fillStyle = isDark.value ? '#f0f0f8' : '#1a1a24'
  ctx.fillText(text, n.x, y)
  ctx.restore()
}
// A title short enough to label a node with.
const shortTitle = (t: string) => (t.length > 70 ? t.slice(0, 68).trimEnd() + '…' : t)
// In the space, the selected document's title, kept above its disc whichever way the camera turns.
let SpriteTextOf: any = null
let title3d: any = null
function showTitle3d() {
  const f = selected.value && sprites.get(selected.value.id)
  if (title3d && title3d.userData.id !== f?.node.id) {
    graph?.scene().remove(title3d); title3d.material.map?.dispose(); title3d.material.dispose(); title3d = null
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
  const sized = t.onBeforeRender
  const up = new three.Vector3()
  t.onBeforeRender = (renderer: any, scene: any, camera: any) => {
    sized(renderer, scene, camera)
    // Above the disc on screen: along the camera's up, by the disc's radius and half the label's height.
    up.setFromMatrixColumn(camera.matrixWorld, 1).normalize()
    t.position.copy(f.sprite.position).addScaledVector(up, f.sprite.scale.y * 1.1 + t.scale.y / 2)
    t.updateMatrixWorld()
  }
  title3d = t
  graph.scene().add(t)
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
      const f = selected.value && sprites.get(selected.value.id)
      if (!f) return
      const k = f.sprite.scale.x * 1.8
      ring3d.position.copy(f.sprite.position)
      ring3d.scale.set(k, k, 1)
      ring3d.updateMatrixWorld()
    }
    graph.scene().add(ring3d)
  }
  ring3d.visible = !!(selected.value && sprites.has(selected.value.id))
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
const COLOUR_BY = [['cluster', 'Cluster'], ['kind', 'Kind'], ['whose', 'Whose']] as const
// One of a list of shown kinds turned on or off.
const toggle = (list: string[], k: string) => { const i = list.indexOf(k); i < 0 ? list.push(k) : list.splice(i, 1) }
// Every one of a list's kinds on, or, all on already, none.
const all = (list: string[], kinds: readonly (readonly [string, string])[]) =>
  list.splice(0, list.length, ...(list.length === kinds.length ? [] : kinds.map(([k]) => k)))
// The space's node discs, by id, with the nodes they draw.
const sprites = new Map<string, { sprite: any; node: GNode }>()
// A disc's width: a little smaller than the sphere 3d-force-graph would draw for the node (radius 4·∛val),
// as closely as the layout packs them.
const spriteSize = (n: GNode) => 5 * Math.cbrt(size(n)) * packing.value
// A white disc, lighter at the centre and a little darker towards its antialiased rim, tinted per node.
function discTexture(THREE: any) {
  const px = 128, c = document.createElement('canvas')
  c.width = c.height = px
  const ctx = c.getContext('2d')!
  const g = ctx.createRadialGradient(px * 0.4, px * 0.38, px * 0.04, px / 2, px / 2, px / 2)
  g.addColorStop(0, '#ffffff'); g.addColorStop(0.7, '#d9d9d9'); g.addColorStop(1, '#b0b0b0')
  ctx.fillStyle = g
  ctx.beginPath(); ctx.arc(px / 2, px / 2, px / 2 - 2, 0, Math.PI * 2); ctx.fill()
  const t = new THREE.CanvasTexture(c)
  t.colorSpace = THREE.SRGBColorSpace
  t.anisotropy = 4
  return t
}
const esc = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!))
// How a linked document stands to the one shown: what it does to this one, or this one to it.
const RELATIONS: Record<string, [string, string]> = { cites: ['cites', 'cited by'], refers: ['refers to', 'referred to by'],
                                                     related: ['related to', 'related to'],
                                                     evidence: ['rests on', 'evidence for'], task: ['linked to', 'task on'] }
const relation = (kind: string, out: boolean) => (RELATIONS[kind] ?? [kind, kind])[out ? 0 : 1]
const kindName = (k: string) => ({ paper: 'paper', record: 'note or record', code: 'codebase', resource: 'resource', finding: 'finding', task: 'task' }[k] ?? k)

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
  if (view.value === '2d') centres = clusterCentres(nodes)
  graph.graphData({ nodes, links })
  restyle()
}
watch([selected, hits, colourBy, litRow, standing], restyle)
watch(colourBy, () => { litRow.value = null })
// Recoloured and resized in place: the space's discs directly, the map's through its accessors.
function restyle() {
  if (!graph) return
  graph.linkColor(linkColour)
  showNearest3d()
  showRing3d()
  showTrail3d()
  const rel = relevantClusters.value
  for (const { sprite, id } of clusterLabels) sprite.material.opacity = !rel || rel.has(id) ? 1 : DIMMED
  if (view.value === '2d') { graph.nodeColor(shade).nodeVal(flatSize); return }
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
  document.documentElement.classList.add('kbx-takeover')
  subset.value = new URLSearchParams(location.search).get('set') ?? ''
  load()
  addEventListener('popstate', fromAddress)
  addEventListener('resize', resize)
  document.addEventListener('fullscreenchange', onFullScreen)
  addEventListener('keydown', key)
  return () => {
    removeEventListener('resize', resize); removeEventListener('keydown', key); removeEventListener('popstate', fromAddress)
    document.documentElement.classList.remove('kbx-takeover')
    document.removeEventListener('fullscreenchange', onFullScreen)
    clearTimeout(jobTimer); stopDrift(); graph?._destructor?.()
  }
})

// ── Travelling ─────────────────────────────────────────────────────────────────────────────────────

const trail: Node[] = []
let lastClick = { id: '', at: 0 }

function clicked(n: GNode) {
  const now = Date.now()
  if (lastClick.id === n.id && now - lastClick.at < 350) { open(n); return }
  lastClick = { id: n.id, at: now }
  go(byId.value.get(n.id) ?? n)
}

/** Move the view to `n` and show its card, keeping where one came from. */
function go(n: Node, remember = true) {
  if (remember && selected.value && selected.value.id !== n.id) trail.push(selected.value)
  selected.value = n
  const g = graph?.graphData().nodes.find((x: GNode) => x.id === n.id)
  if (!g || g.x === undefined) return
  if (view.value === '2d') {
    graph.centerAt(g.x, g.y, moveMs(900))
    graph.zoom(Math.max(graph.zoom(), 3), moveMs(900))
  } else {
    const d = 90, r = Math.hypot(g.x, g.y, g.z) || 1
    graph.cameraPosition({ x: g.x * (1 + d / r), y: g.y * (1 + d / r), z: g.z * (1 + d / r) }, g, moveMs(1400))
  }
}
function back() { const n = trail.pop(); if (n) go(n, false) }
// After the map is drawn again (another view, layout or theme), the selected document stays selected and
// in view; false when there is none on this map to keep.
function keepSelected() {
  const n = selected.value && byId.value.get(selected.value.id)
  if (!n || !graph?.graphData().nodes.some((x: GNode) => x.id === n.id && x.x !== undefined)) return false
  selected.value = n
  go(n, false)
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
    } catch { /* left as it was */ }
  }, 350)
})
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
const driftTrail = ref<{ node: Node; similarity?: number }[]>([])
watch(() => driftTrail.value.length, () => showTrail3d())
// The trail drawn where it went: a line through each document in turn, the earliest steps faintest.
const TRAIL = '#ffb454'
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
// How long a drift stays at each document, in seconds; changed while drifting, from the next step.
const driftEvery = ref<number>(stored('drift', 4.5))
watch(driftEvery, v => {
  keep('drift', v)
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
const judgeable = (p: Pair) => can('paper.add') && ![p.a.kind, p.b.kind].some(k => k === 'finding' || k === 'task')
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
const linkedSelected = computed(() => linksOf.value.get(selected.value?.id ?? '') ?? [])
</script>

<template>
  <KBNeedsService>
    <div ref="frame" class="kbx" :class="{ dark: isDark, full }" :style="{ '--kbx-top': barBottom + 'px' }">
      <div ref="box" class="kbx-canvas"></div>
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
        <nav v-if="subset" class="kbx-crumbs" aria-label="Where on the map">
          <a href="#" @click.prevent="leaveSet">All documents</a><span aria-hidden="true">›</span>
          <template v-for="t in data?.set?.trail ?? []" :key="t.spec">
            <a href="#" class="kbx-crumb-up" :title="t.name" @click.prevent="mapSet(t.spec)">{{ t.name }}</a><span aria-hidden="true">›</span>
          </template>
          <span class="kbx-crumb" :title="data?.set?.name">{{ data?.set?.name ?? '…' }}</span>
          <span v-if="data?.set" class="kbx-key-count">{{ data.set.count }}</span>
          <label v-if="data?.set?.kind === 'q'" class="kbx-top" title="How many of the search's documents are mapped">
            top <input v-model.number="setSize" type="number" min="20" max="500" step="10" @change="load()">
          </label>
        </nav>
        <input v-model="query" type="search" class="kb-field kbx-search" placeholder="Search the map… (Enter to go, Tab for the next)" />
        <button v-if="query.trim() && order.length" class="kbx-btn" title="Lay out the documents this search finds as a map of their own"
                @click="mapSet('q:' + query.trim())">Map these</button>
        <div class="kbx-seg" role="group" aria-label="View">
          <button :class="{ on: view === '2d' }" @click="view = '2d'">Map</button>
          <button :class="{ on: view === '3d' }" @click="view = '3d'">Space</button>
        </div>
        <button class="kbx-btn" :class="{ on: drifting }" title="Move from document to document along the nearest in meaning, one every few seconds" @click="drift">{{ drifting ? 'Stop' : 'Drift' }}</button>
        <label v-if="drifting" class="kbx-speed" title="Seconds at each document">
          <input v-model.number="driftEvery" type="range" min="0.1" max="10" step="0.1" aria-label="Seconds at each document">
          <span>{{ driftEvery }} s</span>
        </label>
        <button class="kbx-btn" :class="{ on: showPairs }" title="Pairs of documents close in meaning that nothing links yet" @click="showPairs = !showPairs">Suggested links</button>
        <button v-if="data?.abstract_only" class="kbx-btn" :class="{ on: abstracts }" :title="`${data.abstract_only} papers not read in full, placed by their title and abstract`"
                @click="abstracts = !abstracts">Include abstract only</button>
        <button class="kbx-btn kbx-icon" aria-label="Show the whole map" title="Show the whole map" @click="resetView">
          <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
               stroke-linejoin="round"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/><circle cx="12" cy="12" r="2.5"/></svg>
        </button>
        <button class="kbx-btn kbx-icon" :class="{ on: panelOpen }" aria-controls="kbx-panel" :aria-expanded="panelOpen"
                aria-label="The map's legend and settings" title="Legend, layout and what the map shows" @click="panelOpen = !panelOpen">
          <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"
               stroke-linecap="round"><path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/></svg>
        </button>
        <button class="kbx-btn kbx-full" :title="full ? 'Leave full screen (Esc)' : 'Full screen'" :aria-label="full ? 'Leave full screen' : 'Full screen'"
                @click="fullScreen">{{ full ? '⤡' : '⤢' }}</button>
      </div>

      <section v-if="panelOpen" id="kbx-panel" class="kbx-panel" :class="{ wide: panel === 'show' }" aria-label="The map's legend and settings">
        <div class="kbx-panel-head">
          <div class="kbx-seg kbx-seg-small" role="tablist" aria-label="Panel">
            <button role="tab" :aria-selected="panel === 'colours'" :class="{ on: panel === 'colours' }" @click="panel = 'colours'">Legend</button>
            <button role="tab" :aria-selected="panel === 'show'" :class="{ on: panel === 'show' }" @click="panel = 'show'">Settings</button>
          </div>
        </div>
        <div v-if="panel === 'colours'" class="kbx-key" role="tabpanel">
          <div class="kbx-shade">
            <span>Colour by</span>
            <div class="kbx-seg kbx-seg-small" role="group" aria-label="Colour by">
              <button v-for="[k, l] in COLOUR_BY" :key="k" :class="{ on: colourBy === k }" @click="colourBy = k">{{ l }}</button>
            </div>
          </div>
          <div v-if="litRow" class="kbx-shade">
            <span>Shade by</span>
            <div class="kbx-seg kbx-seg-small" role="group" aria-label="Shade by">
              <button v-for="[k, l, t] in SHADE_BY" :key="k" :class="{ on: shadeBy === k }" :title="t" @click="shadeBy = k">{{ l }}</button>
            </div>
          </div>
          <ul>
            <li v-for="r in legend" :key="r.key"><button :class="{ on: litRow === r.key }" :title="`Go to ${r.label}`" @click="goToRow(r.key)">
              <i class="kbx-swatch" :style="{ background: r.colour }"></i>
              <span class="kbx-key-label">{{ r.label }}</span><span class="kbx-key-count">{{ r.count }}</span></button>
              <button v-if="r.key[0] === 'c'" class="kbx-map-row" :title="`Map ${r.label} by itself`"
                      :aria-label="`Map ${r.label} by itself`" @click="mapSet('cluster:' + r.key.slice(1) + (subset ? '@' + subset : ''))">⤢</button></li>
          </ul>
        </div>
        <div v-if="panel === 'show'" role="tabpanel">
          <div class="kbx-grid">
            <template v-if="data?.nodes.some(n => n.ux)">
              <span class="kbx-label">Layout</span>
              <div class="kbx-seg kbx-seg-small kbx-wide" role="group" aria-label="Layout">
                <button :class="{ on: layout === 'tsne' }" title="Keeps each document's close neighbourhood" @click="layout = 'tsne'">t-SNE</button>
                <button :class="{ on: layout === 'umap' }" title="Keeps more of how the groups lie to each other" @click="layout = 'umap'">UMAP</button>
                <button v-if="data?.nodes.some(n => n.px)" :class="{ on: layout === 'pacmap' }"
                        title="Keeps the neighbourhoods and how the groups lie to each other, the most evenly" @click="layout = 'pacmap'">PaCMAP</button>
              </div>
            </template>
            <template v-if="can('tasks.view') && projectList?.length">
              <span class="kbx-label">Map</span>
              <select class="kb-field kbx-wide kbx-pick" aria-label="Map a project's library by itself"
                      @change="e => { const k = (e.target as HTMLSelectElement).value; if (k) mapSet('project:' + k) }">
                <option value="">A project's library…</option>
                <option v-for="p in projectList" :key="p.key" :value="p.key">{{ p.name }} ({{ p.key }})</option>
              </select>
            </template>
            <span class="kbx-label">Links</span>
            <button class="kbx-all" @click="all(shownLinks, LINK_KINDS)">{{ shownLinks.length === LINK_KINDS.length ? 'None' : 'All' }}</button>
            <div class="kbx-chips">
              <button v-for="[k, l] in LINK_KINDS" :key="k" class="kbx-chip" :class="{ on: shownLinks.includes(k) }" :aria-pressed="shownLinks.includes(k)"
                      @click="toggle(shownLinks, k)"><i class="kbx-swatch" :style="{ background: LINK_COLOURS[k] }"></i>{{ l }}</button>
            </div>
            <span class="kbx-label">Documents</span>
            <button class="kbx-all" @click="all(shownKinds, NODE_KINDS)">{{ shownKinds.length === NODE_KINDS.length ? 'None' : 'All' }}</button>
            <div class="kbx-chips">
              <button v-for="[k, l] in NODE_KINDS" :key="k" class="kbx-chip" :class="{ on: shownKinds.includes(k) }" :aria-pressed="shownKinds.includes(k)"
                      @click="toggle(shownKinds, k)"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[k] }"></i>{{ l }}</button>
            </div>
            <span class="kbx-label">Unlinked pairs</span>
            <div class="kbx-pairs-row kbx-wide">
              <button class="kbx-chip" :class="{ on: showUnlinked }" :aria-pressed="showUnlinked" title="Draw the pairs close in meaning that no link joins"
                      @click="showUnlinked = !showUnlinked">{{ showUnlinked ? 'Shown' : 'Hidden' }}</button>
              <input v-model.number="threshold" type="range" min="0.5" max="0.98" step="0.01" :disabled="!showUnlinked" aria-label="How alike">
              <span class="kbx-value">≥ {{ Math.round(threshold * 100) }}%</span>
            </div>
          </div>
          <p v-if="view === '3d'" class="kbx-hint">Drag to turn, scroll to come closer. F flies: WASD to move, the mouse to steer.{{ fly ? ' Flying: F to stop.' : '' }}</p>
        </div>
      </section>

      <div v-if="building" class="kbx-building" role="status">
        <div class="kbx-building-card">
          <p><span class="kb-spinner"></span> {{ building }}</p>
          <p class="kbx-building-then">The map redraws when this is done.</p>
        </div>
      </div>
      <p v-if="said" class="kbx-said" @click="said = ''">{{ said }}</p>

      <aside v-if="selected" class="kbx-card" :class="{ short: driftTrail.length > 1 }">
        <button class="kbx-close" aria-label="Close" @click="selected = null">×</button>
        <p class="kbx-meta"><i class="kbx-swatch" :style="{ background: colour(selected) }"></i>{{ kindName(selected.kind) }}<template
          v-if="selected.year"> · {{ selected.year }}</template><template v-if="selected.read === false"> · abstract only</template></p>
        <p v-if="clusterName(selected.cluster)" class="kbx-cluster" :title="clusterName(selected.cluster)">{{ clusterName(selected.cluster) }}</p>
        <h3><a :href="selected.page" target="_blank" rel="noopener">{{ selected.title }}</a></h3>
        <template v-if="detail && detail.id === selected.id">
          <p v-if="byline(detail)" class="kbx-byline">{{ byline(detail) }}</p>
          <div v-if="cardText" class="kbx-summary" :class="{ open: more }">
            <p class="kbx-sum-head">{{ detail.summary ? 'Summary' : detail.excerpt ? 'From the note' : 'Abstract' }}</p>
            <div class="kbx-sum-text" v-html="render(cardText)"></div>
          </div>
          <button v-if="cardText.length > 420" class="kbx-more" @click="more = !more">{{ more ? 'Less' : 'More' }}</button>
          <div v-if="detail.topics.length" class="kbx-topics"><span v-for="t in detail.topics" :key="t">{{ t }}</span></div>
        </template>
        <div class="kbx-actions kbx-tools">
          <button v-if="trail.length" class="kbx-btn kbx-tool" title="Back to the document before (Backspace)" aria-label="Back" @click="back">
            <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5M12 19l-7-7 7-7"/></svg>
          </button>
          <button class="kbx-btn kbx-tool" title="Open its page" aria-label="Open its page" @click="open(selected)">
            <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>
          </button>
          <button v-if="selected.kind !== 'finding' && selected.kind !== 'task'" class="kbx-btn kbx-tool" title="Copy its citation"
                  aria-label="Copy its citation" @click="copyCitation(selected)">
            <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7h4v5H6V9a2 2 0 0 1 1-2zM6 12c0 3 1 5 4 6M15 7h4v5h-5V9a2 2 0 0 1 1-2zM14 12c0 3 1 5 4 6"/></svg>
          </button>
          <a class="kbx-btn kbx-tool" :href="exploreHref(selected.id)" title="Copy a link to this view" aria-label="Copy a link to this view"
             @click.prevent="copyView(selected)">
            <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a4 4 0 0 0 6 0l3-3a4 4 0 0 0-6-6l-1 1M14 10a4 4 0 0 0-6 0l-3 3a4 4 0 0 0 6 6l1-1"/></svg>
          </a>
        </div>
        <template v-if="linkedSelected.length">
          <h4>Linked</h4>
          <ul class="kbx-list">
            <li v-for="l in linkedSelected" :key="l.node.id + l.kind">
              <i class="kbx-swatch" :style="{ background: KIND_COLOURS[l.node.kind] ?? '#999' }"></i>
              <a href="#" :title="l.node.title" @click.prevent="go(l.node)">{{ l.node.title }}</a>
              <span class="kbx-aside">{{ relation(l.kind, l.out) }}</span>
            </li>
          </ul>
        </template>
        <template v-if="nearSelected.length">
          <h4>Nearest in meaning</h4>
          <ul class="kbx-list">
            <li v-for="x in nearSelected" :key="x.node.id">
              <i class="kbx-swatch" :style="{ background: KIND_COLOURS[x.node.kind] ?? '#999' }"></i>
              <a href="#" :title="x.node.title" @click.prevent="go(x.node)">{{ x.node.title }}</a>
              <span class="kbx-aside"><span v-if="x.linked" class="kbx-tag">linked</span><span class="kbx-bar-track"><span class="kbx-bar-fill"
                :style="{ width: `${Math.max(4, Math.round(x.similarity * 100))}%` }"></span></span>{{ Math.round(x.similarity * 100) }}%</span>
            </li>
          </ul>
        </template>
      </aside>


      <aside v-if="driftTrail.length > 1" class="kbx-trail">
        <button class="kbx-close" aria-label="Clear the trail" title="Clear the trail" @click="driftTrail = []">×</button>
        <h4>Drift trail</h4>
        <ol>
          <li v-for="(t, i) in driftTrail" :key="t.node.id" :class="{ here: t.node.id === selected?.id }">
            <a href="#" :title="t.node.title" @click.prevent="go(t.node)">{{ t.node.title }}</a>
            <span v-if="i" class="kbx-key-count">{{ Math.round((t.similarity ?? 0) * 100) }}%</span>
          </li>
        </ol>
        <div class="kbx-actions">
          <button class="kbx-btn kbx-small" @click="copyTrail">Copy as text</button>
          <button v-if="!subset.startsWith('docs:')" class="kbx-btn kbx-small" title="Lay out the drift's documents and their nearest as a map of their own"
                  @click="mapDrift">Map this drift</button>
        </div>
      </aside>

      <aside v-if="showPairs" class="kbx-pairs">
        <button class="kbx-close" aria-label="Close" @click="showPairs = false">×</button>
        <h4>Suggested links</h4>
        <div class="kbx-seg kbx-seg-small kbx-scope" role="group" aria-label="Where">
          <button :class="{ on: scope === 'own' }" title="Your notes, records and findings, beside what they do not link to yet"
                  @click="scope = 'own'">Yours</button>
          <button :class="{ on: scope === 'cluster' }" :disabled="!selected" :title="selected ? '' : 'Select a document first'"
                  @click="scope = 'cluster'">This cluster</button>
          <button :class="{ on: scope === 'all' }" @click="scope = 'all'">Everywhere</button>
        </div>
        <p class="kbx-pairs-hint">{{ scope === 'own' ? `Your notes, records and findings, each beside the library documents nearest it that it does not link to, ${Math.round(OWN_FLOOR * 100)}% alike or more.` :
          `Documents close in meaning that nothing links, ${Math.round(threshold * 100)}% alike or more.` }}</p>
        <p v-if="!pairs.length" class="kbx-pairs-hint">None.</p>
        <ul class="kbx-list kbx-pair-list">
          <li v-for="p in pairs" :key="p.a.id + p.b.id">
            <div class="kbx-pair">
              <div class="kbx-pair-doc"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[p.a.kind] ?? '#999' }"></i>
                <a href="#" :title="p.a.title" @click.prevent="goPair(p)">{{ p.a.title }}</a></div>
              <div class="kbx-pair-doc"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[p.b.kind] ?? '#999' }"></i>
                <a href="#" :title="p.b.title" @click.prevent="go(p.b)">{{ p.b.title }}</a></div>
              <p v-if="shared.get(pairKey(p))?.length" class="kbx-pair-why">Shared: {{ shared.get(pairKey(p))!.join(' · ') }}</p>
              <div class="kbx-pair-act">
                <a v-if="(p.a.kind === 'finding') !== (p.b.kind === 'finding') && can('tasks.edit')" href="#"
                   @click.prevent="p.a.kind === 'finding' ? addEvidence(p.a, p.b) : addEvidence(p.b, p.a)">Add as evidence</a>
                <template v-else-if="judgeable(p)">
                  <a href="#" title="Link the two as related: a line on the map, and in both cards" @click.prevent="judge(p, true)">Link</a>
                  <a href="#" title="Stop suggesting this pair" @click.prevent="judge(p, false)">Not related</a>
                </template>
                <a v-if="(p.a.kind === 'record' && p.b.kind === 'paper') || (p.b.kind === 'record' && p.a.kind === 'paper')" href="#"
                   @click.prevent="copyCitation(p.a.kind === 'paper' ? p.a : p.b)">Copy the citation</a>
              </div>
            </div>
            <span class="kbx-aside"><span class="kbx-bar-track"><span class="kbx-bar-fill"
              :style="{ width: `${Math.max(4, Math.round(p.similarity * 100))}%` }"></span></span>{{ Math.round(p.similarity * 100) }}%</span>
          </li>
        </ul>
      </aside>
    </div>
  </KBNeedsService>
</template>

<style scoped>
:global(.kbx-page) { padding: 8px 12px !important; max-width: none !important; }
/* The page is the map: the window does not scroll, and the footer is not drawn beneath it. */
:global(html.kbx-takeover), :global(html.kbx-takeover body) { overflow: hidden; overscroll-behavior: none; }
:global(html.kbx-takeover .VPFooter) { display: none; }
.kbx { position: relative; height: calc(100dvh - var(--vp-nav-height, 64px) - 16px); min-height: 320px; border-radius: 10px;
       overflow: hidden; border: 1px solid var(--vp-c-divider); background: #fafafa; }
.kbx.dark { background: #111116; }
.kbx.full { height: 100vh; border-radius: 0; border: 0; }
.kbx-full { margin-left: auto; font-size: 15px; line-height: 1; padding: 4px 9px; }
.kbx-canvas { position: absolute; inset: 0; }
.kbx-status { position: absolute; top: 45%; width: 100%; text-align: center; color: var(--vp-c-text-2); }
.kbx-bar { position: absolute; top: 10px; left: 10px; right: 10px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; pointer-events: none; }
.kbx-bar > * { pointer-events: auto; }
.kbx-crumbs { display: inline-flex; align-items: center; gap: 6px; max-width: 36rem; padding: 4px 10px; font-size: 13px; border-radius: 8px;
              border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); }
.kbx-crumbs a { color: var(--vp-c-brand-1); white-space: nowrap; }
.kbx-crumb-up { max-width: 10rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbx-crumb { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.kbx-top { display: inline-flex; align-items: center; gap: 4px; color: var(--vp-c-text-2); white-space: nowrap; }
.kbx-top input { width: 4rem; padding: 0 4px; border: 1px solid var(--vp-c-divider); border-radius: 4px; background: var(--vp-c-bg); }
.kbx-map-row { padding: 0 6px; font-size: 12px; color: var(--vp-c-text-3); border-radius: 4px; }
.kbx-map-row:hover { color: var(--vp-c-brand-1); background: var(--vp-c-default-soft); }
.kbx-pick { font-size: 12px; padding: 2px 6px; }
.kbx-search { flex: 1 1 18rem; max-width: 30rem; background: var(--vp-c-bg); }
.kbx-seg { display: inline-flex; border: 1px solid var(--vp-c-divider); border-radius: 8px; overflow: hidden; background: var(--vp-c-bg); }
.kbx-seg button { padding: 4px 12px; font-size: 13px; color: var(--vp-c-text-2); }
.kbx-seg button.on { background: var(--vp-c-brand-soft); color: var(--vp-c-text-1); font-weight: 600; }
.kbx-speed { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--vp-c-text-2); font-variant-numeric: tabular-nums; }
.kbx-speed input { width: 6rem; accent-color: var(--vp-c-brand-1); }
.kbx-speed span { min-width: 2.6rem; }
.kbx-btn { padding: 4px 10px; font-size: 13px; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg); color: var(--vp-c-text-1); }
.kbx-btn.on { background: var(--vp-c-brand-soft); }
.kbx-panel { position: absolute; top: var(--kbx-top, 52px); right: 10px; max-height: calc(100% - var(--kbx-top, 52px) - 12px); overflow: auto; border: 1px solid var(--vp-c-divider);
              background: color-mix(in srgb, var(--vp-c-bg) 72%, transparent); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px);
              border-radius: 8px; padding: 4px 10px; font-size: 12px; }
.kbx-panel { width: 18rem; padding: 6px 12px 10px; }
.kbx-panel.wide { width: min(31rem, calc(100% - 20px)); }
.kbx-panel-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.kbx-panel-head .kbx-seg button { padding: 2px 10px; }
.kbx-icon { display: inline-flex; align-items: center; justify-content: center; padding: 5px 8px; margin-left: auto; }
.kbx-icon + .kbx-icon, .kbx-icon + .kbx-full { margin-left: 0; }
.kbx-shade { display: flex; align-items: center; justify-content: space-between; gap: 6px; margin: 6px 0 4px; color: var(--vp-c-text-2); }
.kbx-shade .kbx-seg button { padding: 2px 7px; }
.kbx-key ul { list-style: none; margin: 4px 0 2px; padding: 0; }
.kbx-key li { display: flex; align-items: center; }
.kbx-key li button:not(.kbx-map-row) { flex: 1; min-width: 0; width: 100%; display: grid; grid-template-columns: 9px 1fr auto; align-items: center; column-gap: 7px;
                     padding: 1px 4px; margin: 0 -4px; border-radius: 4px; text-align: left; }
.kbx-key li button:not(.kbx-map-row):hover { background: var(--vp-c-default-soft); }
.kbx-key li button:not(.kbx-map-row).on { background: var(--vp-c-brand-soft); }
.kbx-key-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--vp-c-text-1); }
.kbx-key-count { color: var(--vp-c-text-3); font-variant-numeric: tabular-nums; }
.kbx-trail { position: absolute; left: 10px; bottom: 46px; width: min(20rem, 40%); max-height: 38%; overflow: auto; font-size: 12px;
             border: 1px solid var(--vp-c-divider); border-radius: 10px; padding: 8px 12px 10px;
             background: color-mix(in srgb, var(--vp-c-bg) 80%, transparent); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); }
.kbx-trail h4 { margin: 0 0 4px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--vp-c-text-2); }
.kbx-trail ol { margin: 0 0 8px; padding-left: 1.4rem; }
.kbx-trail li { margin: 2px 0; }
.kbx-trail li > * { vertical-align: middle; }
.kbx-trail li a { display: inline-block; max-width: calc(100% - 3rem); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
                  color: var(--vp-c-text-1); text-decoration: none; }
.kbx-trail li.here a { color: var(--vp-c-brand-1); font-weight: 600; }
.kbx-trail li .kbx-key-count { margin-left: 6px; }
.kbx-card.short { max-height: calc(62% - 64px); }
.kbx-grid { display: grid; grid-template-columns: auto 2.4rem 1fr; gap: 8px 8px; align-items: start; margin-top: 8px; font-size: 12px; }
.kbx-wide { grid-column: 2 / -1; }
.kbx-label { color: var(--vp-c-text-2); padding-top: 2px; white-space: nowrap; }
.kbx-seg-small button { padding: 2px 10px; font-size: 12px; }
.kbx-grid > .kbx-seg { justify-self: start; }
.kbx-grid > .kbx-label { padding-right: 4px; }
.kbx-chips { display: flex; flex-wrap: wrap; gap: 4px; }
.kbx-chip { display: inline-flex; align-items: center; gap: 5px; padding: 1px 8px; font-size: 11.5px; line-height: 1.6; border-radius: 999px;
            border: 1px solid var(--vp-c-divider); color: var(--vp-c-text-3); background: transparent; transition: background 0.15s, color 0.15s; }
.kbx-chip .kbx-swatch { opacity: 0.35; }
.kbx-chip.on { color: var(--vp-c-text-1); background: var(--vp-c-default-soft); border-color: transparent; }
.kbx-chip.on .kbx-swatch { opacity: 1; }
.kbx-all { font-size: 11px; color: var(--vp-c-brand-1); padding: 2px 0; text-align: left; justify-self: start; }
.kbx-pairs-row { display: flex; align-items: center; gap: 10px; }
.kbx-pairs-row input[type=range] { flex: 1; min-width: 6rem; accent-color: var(--vp-c-brand-1); }
.kbx-pairs-row input:disabled { opacity: 0.4; }
.kbx-value { font-size: 12px; color: var(--vp-c-text-2); font-variant-numeric: tabular-nums; min-width: 3.2rem; }
.kbx-hint { margin: 10px 0 0; font-size: 12px; color: var(--vp-c-text-3); }
.kbx-row { display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: center; margin: 6px 0; }
.kbx-row > span { color: var(--vp-c-text-2); min-width: 5.5rem; }
.kbx-row label { display: inline-flex; align-items: center; gap: 4px; }
.kbx-swatch { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 2px; }
.kbx-building { position: absolute; inset: 0; z-index: 5; display: flex; align-items: center; justify-content: center;
                background: color-mix(in srgb, var(--vp-c-bg) 70%, transparent); backdrop-filter: blur(2px); }
.kbx-building-card { background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); border-radius: 12px; padding: 18px 26px;
                     box-shadow: 0 8px 30px rgba(0, 0, 0, 0.25); text-align: center; max-width: min(32rem, 90%); }
.kbx-building-card p { margin: 0; font-size: 15px; display: flex; gap: 10px; align-items: center; justify-content: center; }
.kbx-building-card .kbx-building-then { margin-top: 6px; font-size: 13px; color: var(--vp-c-text-2); }
.kbx-said { position: absolute; bottom: 10px; left: 50%; transform: translateX(-50%); font-size: 13px; background: var(--vp-c-bg);
            padding: 3px 12px; border-radius: 8px; border: 1px solid var(--vp-c-divider); cursor: pointer; }
.kbx-card, .kbx-pairs { position: absolute; top: var(--kbx-top, 52px); left: 10px; width: min(24rem, 45%); max-height: calc(100% - var(--kbx-top, 52px) - 12px); overflow: auto;
                        background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); border-radius: 10px; padding: 10px 14px; font-size: 13px;
                        box-shadow: 0 4px 18px rgba(0, 0, 0, 0.18); }
.kbx-pairs { left: auto; right: 10px; top: auto; bottom: 46px; max-height: 45%; }
.kbx-card h3 { margin: 6px 0 10px; font-size: 16px; line-height: 1.35; padding-right: 1.2rem; }
.kbx-card h3 a { color: var(--vp-c-text-1); text-decoration: none; }
.kbx-card h3 a:hover { color: var(--vp-c-brand-1); }
.kbx-meta { margin: 0; font-size: 12px; color: var(--vp-c-text-2); display: flex; align-items: center; gap: 6px; padding-right: 1.2rem; }
.kbx-cluster { margin: 2px 0 0; font-size: 12px; color: var(--vp-c-text-3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.kbx-small { padding: 2px 9px; font-size: 12px; border-radius: 6px; }
.kbx-tool { display: inline-flex; align-items: center; justify-content: center; padding: 5px 7px; border-radius: 6px; color: var(--vp-c-text-2); }
.kbx-tool:hover { color: var(--vp-c-text-1); background: var(--vp-c-default-soft); }
.kbx-list { list-style: none; padding: 0 !important; margin: 0; }
.kbx-list li { display: grid; grid-template-columns: 9px 1fr auto; align-items: baseline; column-gap: 8px; margin: 0 !important;
               padding: 4px 0; font-size: 13px; line-height: 1.35; border-bottom: 1px solid var(--vp-c-divider); }
.kbx-list li:last-child { border-bottom: 0; }
.kbx-list a { color: var(--vp-c-text-1); text-decoration: none; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.kbx-list a:hover { color: var(--vp-c-brand-1); }
.kbx-byline { margin: -4px 0 8px; font-size: 12px; color: var(--vp-c-text-2); }
.kbx-summary { position: relative; max-height: 9.5em; overflow: hidden; font-size: 13px; line-height: 1.5; }
.kbx-summary:not(.open)::after { content: ''; position: absolute; left: 0; right: 0; bottom: 0; height: 2.5em;
                                 background: linear-gradient(transparent, var(--vp-c-bg)); }
.kbx-summary.open { max-height: none; }
.kbx-sum-head { margin: 0 0 2px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--vp-c-text-3); }
.kbx-sum-text :deep(p) { margin: 0 0 6px; }
.kbx-sum-text :deep(ul) { margin: 0 0 6px; padding-left: 1.1rem; }
.kbx-more { font-size: 12px; color: var(--vp-c-brand-1); margin: 2px 0 6px; }
.kbx-topics { display: flex; flex-wrap: wrap; gap: 4px; margin: 4px 0 8px; }
.kbx-topics span { font-size: 11px; padding: 1px 7px; border-radius: 999px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbx-bar-track { display: inline-block; width: 44px; height: 4px; margin-right: 6px; border-radius: 2px; vertical-align: middle;
                 background: var(--vp-c-default-soft); overflow: hidden; }
.kbx-bar-fill { display: block; height: 100%; border-radius: 2px; background: #8b7cf6; }
.kbx-aside { font-size: 12px; color: var(--vp-c-text-2); white-space: nowrap; font-variant-numeric: tabular-nums; }
.kbx-tag { margin-right: 6px; font-size: 10px; padding: 0 5px; border-radius: 4px; border: 1px solid var(--vp-c-divider); color: var(--vp-c-text-3); }
.kbx-card h4, .kbx-pairs h4 { margin: 14px 0 2px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--vp-c-text-2); }
.kbx-card ul, .kbx-pairs ul { padding-left: 1rem; margin: 0; }
.kbx-card li, .kbx-pairs li { margin: 3px 0; }
.kbx-scope { margin-top: 8px; }
.kbx-scope button:disabled { opacity: 0.45; cursor: default; }
.kbx-pairs-hint { margin: 8px 0 4px; font-size: 12px; color: var(--vp-c-text-3); }
.kbx-pair-list li { grid-template-columns: 1fr auto; align-items: center; padding: 6px 0; }
.kbx-pair { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.kbx-pair-doc { display: grid; grid-template-columns: 9px 1fr; align-items: baseline; column-gap: 8px; }
.kbx-pair-doc a { -webkit-line-clamp: 1; }
.kbx-pair-act { padding-left: 17px; font-size: 12px; display: flex; gap: 12px; }
.kbx-pair-act:empty { display: none; }
.kbx-pair-why { margin: 1px 0 0; padding-left: 17px; font-size: 11.5px; color: var(--vp-c-text-3); }
.kbx-pair-act a { color: var(--vp-c-brand-1) !important; }
.kbx-actions { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 4px; }
.kbx-close { position: absolute; top: 4px; right: 8px; font-size: 18px; color: var(--vp-c-text-2); }
:deep(.kbx-tip) { font: 12px system-ui, sans-serif; max-width: 22rem; }
</style>
