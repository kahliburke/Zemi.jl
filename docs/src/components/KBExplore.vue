<!--
  Explore the knowledge base (see src/explore.jl): every document the reader may see placed by what it
  is about, on a 2D map or in a 3D space, the clusters of the landscape labelled where they lie, the
  links people made drawn between documents (citations, references, a finding's evidence, a task's
  links), and the pairs close in meaning that no link joins yet. Clicking, searching and drifting
  move the view; in 3D, F flies freely. `?center=<id>` opens it at a document.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, shallowRef, computed, watch, nextTick } from 'vue'
import { useData } from 'vitepress'
import { getJSON, post, can, onLive } from './kbApi'

type Node = { id: string; kind: string; title: string; year?: string; page: string; links: number; status?: string; project?: string
              access?: 'open' | 'projects' | 'private'; mine?: boolean; read?: boolean
              x?: [number, number]; p?: [number, number, number]; cluster?: number }
type Cluster = { id: number; name: string; description: string; size: number }
type Graph = { nodes: Node[]; links: [number, number, string][]; similar: [number, number, number, boolean][]; clusters: Cluster[];
               built_at: string | null; job: string | null; abstracts: boolean; abstract_only: number }
type Near = { node: Node; similarity: number; linked: boolean }
type Pair = { a: Node; b: Node; similarity: number; score: number }

const { isDark } = useData()

const LINK_KINDS = [['cites', 'Citations'], ['refers', 'References'], ['evidence', 'Evidence'], ['task', 'Tasks']] as const
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
const LINK_COLOURS: Record<string, string> = { cites: '#8ab4f8', refers: '#3dd68c', evidence: '#f6d55c', task: '#ef6f6c' }
const SCALE_2D = 700, SCALE_3D = 360

// What is drawn, kept between visits.
const stored = <T,>(key: string, fallback: T): T => {
  try { const v = localStorage.getItem(`kb-explore-${key}`); return v === null ? fallback : JSON.parse(v) } catch { return fallback }
}
const keep = (key: string, v: unknown) => { try { localStorage.setItem(`kb-explore-${key}`, JSON.stringify(v)) } catch { /* private mode */ } }
const view = ref<'2d' | '3d'>(stored('view', '2d'))
const fly = ref(false)
const colourBy = ref<'cluster' | 'kind' | 'whose'>(stored('colour', 'cluster'))
const shownLinks = ref<string[]>(stored('links', ['cites', 'refers', 'evidence']))
const shownKinds = ref<string[]>(stored('kinds', ['paper', 'record', 'code', 'resource', 'finding']))
const threshold = ref<number>(stored('threshold', 0.8))
const showUnlinked = ref<boolean>(stored('unlinked', true))
// The papers known only by their abstract (the watch's, and those recorded but not yet read): left out
// unless asked for, the map then being of every document.
const abstracts = ref<boolean>(stored('abstracts', false))
watch(abstracts, v => { keep('abstracts', v); if (data.value && data.value.abstracts !== v) load() })
watch(view, v => keep('view', v)); watch(colourBy, v => keep('colour', v)); watch(shownLinks, v => keep('links', v), { deep: true })
watch(shownKinds, v => keep('kinds', v), { deep: true }); watch(threshold, v => keep('threshold', v)); watch(showUnlinked, v => keep('unlinked', v))

const data = shallowRef<Graph | null>(null)
const selected = ref<Node | null>(null)
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

// Pairs near in meaning that no link joins: the strongest first, those across clusters or kinds a little ahead.
const scope = ref<'all' | 'cluster' | 'own'>('all')
const pairs = computed<Pair[]>(() => {
  const g = data.value
  if (!g) return []
  const here = selected.value?.cluster
  const out: Pair[] = []
  for (const [i, j, s, linked] of g.similar) {
    if (linked || s < threshold.value) continue
    const a = g.nodes[i], b = g.nodes[j]
    if (scope.value === 'cluster' && here !== undefined && a.cluster !== here && b.cluster !== here) continue
    if (scope.value === 'own' && own(a) === own(b)) continue
    const score = s + (a.cluster !== b.cluster ? 0.04 : 0) + (a.kind !== b.kind ? 0.04 : 0)
    out.push({ a, b, similarity: s, score })
  }
  return out.sort((x, y) => y.score - x.score).slice(0, 40)
})

async function load() {
  loading.value = true
  error.value = ''
  const q = new URLSearchParams({ links: 'cites,refers,evidence,task', kinds: 'paper,record,code,resource,finding,task',
                                  ...(abstracts.value ? { abstracts: '1' } : {}) })
  try {
    const g: Graph = await getJSON(`/api/graph?${q}`)
    data.value = g
    building.value = g.job ? 'Placing what is new here…' : ''
    if (g.job) watchJob(g.job)
  } catch (e: any) { error.value = `The map could not be loaded: ${e.message ?? e}` }
  loading.value = false
  await nextTick()
  draw()
  const center = new URLSearchParams(location.search).get('center')
  if (center && !byId.value.has(center) && !abstracts.value && data.value?.abstract_only) { abstracts.value = true; return }
  if (center && byId.value.has(center)) setTimeout(() => go(byId.value.get(center)!), 600)
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
function shade(n: Node) {
  const c = colour(n)
  if (hits.value.size) return hits.value.has(n.id) ? c : isDark.value ? '#3a3a44' : '#d8d8de'
  if (selected.value && selected.value.id !== n.id && !near.value.has(n.id)) return isDark.value ? '#55555f' : '#c8c8ce'
  return c
}
const size = (n: Node) => ((n.kind === 'finding' ? 3 : 1.4) + Math.sqrt(n.links) * 1.2) * (n.read === false ? 0.6 : 1) +
                           (hits.value.get(n.id) ?? 0) * 3

type GNode = Node & { fx?: number; fy?: number; fz?: number; x?: any; y?: any; z?: any }
type GLink = { source: string; target: string; kind: string; similarity?: number; unlinked?: boolean }

// The library's nodes and links: placed nodes fixed where the map puts them, the rest left to settle
// among those they link to; the nearest by meaning hold the unplaced, and are drawn only when no link
// joins a pair above the threshold.
function graphData() {
  const g = data.value!
  const deep = view.value === '3d'
  const nodes: GNode[] = g.nodes.filter(visibleNode).map(n => {
    const o: GNode = { ...n } as GNode
    if (n.x && !deep) { o.fx = n.x[0] * SCALE_2D; o.fy = -n.x[1] * SCALE_2D }
    if (n.p && deep) { o.fx = n.p[0] * SCALE_3D; o.fy = n.p[1] * SCALE_3D; o.fz = n.p[2] * SCALE_3D }
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
    if (ids.has(a) && ids.has(b)) links.push({ source: a, target: b, kind: 'similar', similarity: s, unlinked: !linked && s >= threshold.value })
  }
  return { nodes, links }
}

const linkShown = (l: GLink) => l.kind !== 'similar' || (showUnlinked.value && !!l.unlinked)
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
  return [...sums].filter(([, s]) => s.n >= 3).map(([id, s]) => ({ id, name: clusterName(id), x: s.x / s.n, y: s.y / s.n, z: s.z / s.n }))
}

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
    const centres = clusterCentres(nodes)
    graph = new ForceGraph(el)
      .backgroundColor(bg).width(el.clientWidth).height(el.clientHeight)
      .graphData({ nodes, links }).nodeId('id')
      .nodeVal(size).nodeColor(shade).nodeLabel(label)
      .linkVisibility(linkShown).linkColor(linkColour)
      .linkWidth((l: GLink) => (l.kind === 'similar' ? 0.8 : 1.2))
      .linkLineDash((l: GLink) => (l.kind === 'similar' ? [2, 3] : null))
      .linkDirectionalArrowLength((l: GLink) => (l.kind === 'cites' || l.kind === 'refers' ? 3 : 0))
      .linkDirectionalArrowRelPos(1)
      .onNodeClick(clicked).onBackgroundClick(() => { selected.value = null })
      .cooldownTicks(120)
      .onRenderFramePost((ctx: CanvasRenderingContext2D, scale: number) => {
        // Cluster names, a constant size on screen; faded out as one comes close.
        const fade = Math.max(0, Math.min(1, (2.2 - scale) / 1.4))
        if (!fade) return
        ctx.save()
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
        ctx.font = `600 ${14 / scale}px system-ui, sans-serif`
        for (const c of centres) {
          if (!c.name) continue
          ctx.fillStyle = isDark.value ? `rgba(235,235,245,${0.85 * fade})` : `rgba(30,30,40,${0.8 * fade})`
          ctx.fillText(c.name, c.x, c.y)
        }
        ctx.restore()
      })
    graph.d3Force('charge')?.strength(-12)
    graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? (l.similarity ?? 0) * 0.3 : 0.1))
    setTimeout(() => graph?.zoomToFit(600, 40), 300)
  } else {
    const ForceGraph3D = (await import('3d-force-graph')).default as any
    const SpriteText = (await import('three-spritetext')).default as any
    graph = new ForceGraph3D(el, { controlType: fly.value ? 'fly' : 'orbit' })
      .backgroundColor(bg).width(el.clientWidth).height(el.clientHeight)
      .graphData({ nodes, links }).nodeId('id')
      .nodeVal(size).nodeColor(shade).nodeLabel(label).nodeOpacity(0.92).nodeResolution(10)
      .linkVisibility(linkShown).linkColor(linkColour).linkOpacity(0.55)
      .linkWidth((l: GLink) => (l.kind === 'similar' ? 0 : 0.6))
      .linkDirectionalParticles((l: GLink) => (l.kind === 'similar' ? 2 : 0))
      .linkDirectionalParticleWidth(1.2).linkDirectionalParticleSpeed(0.004)
      .linkDirectionalArrowLength((l: GLink) => (l.kind === 'cites' || l.kind === 'refers' ? 2.5 : 0))
      .linkDirectionalArrowRelPos(1)
      .onNodeClick(clicked).onBackgroundClick(() => { selected.value = null })
      .cooldownTicks(120)
    graph.d3Force('charge')?.strength(-10)
    graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? (l.similarity ?? 0) * 0.3 : 0.1))
    const fog = (await import('three')).FogExp2
    graph.scene().fog = new fog(isDark.value ? 0x111116 : 0xfafafa, 0.0011)
    for (const c of clusterCentres(nodes)) {
      if (!c.name) continue
      const s = new SpriteText(c.name, 10, isDark.value ? 'rgba(235,235,245,0.85)' : 'rgba(30,30,40,0.8)')
      s.fontWeight = '600'
      s.position.set(c.x, c.y + 18, c.z)
      graph.scene().add(s)
    }
    setTimeout(() => graph?.zoomToFit(800, 30), 300)
  }
}
const esc = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!))
const kindName = (k: string) => ({ paper: 'paper', record: 'note or record', code: 'codebase', resource: 'resource', finding: 'finding', task: 'task' }[k] ?? k)

// Redrawn as what is shown changes; recoloured as the selection, hits and colours do.
watch([view, fly, shownLinks, shownKinds, threshold, showUnlinked, isDark], () => draw(), { deep: true })
watch([selected, hits, colourBy], () => graph?.nodeColor(shade).linkColor(linkColour).nodeVal(size))

const resize = () => { if (graph && box.value) graph.width(box.value.clientWidth).height(box.value.clientHeight) }
onLive(() => {
  load()
  addEventListener('resize', resize)
  addEventListener('keydown', key)
  return () => {
    removeEventListener('resize', resize); removeEventListener('keydown', key)
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
    graph.centerAt(g.x, g.y, 900)
    graph.zoom(Math.max(graph.zoom(), 3), 900)
  } else {
    const d = 90, r = Math.hypot(g.x, g.y, g.z) || 1
    graph.cameraPosition({ x: g.x * (1 + d / r), y: g.y * (1 + d / r), z: g.z * (1 + d / r) }, g, 1400)
  }
}
function back() { const n = trail.pop(); if (n) go(n, false) }
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
function drift() {
  if (drifting.value) { stopDrift(); return }
  const start = selected.value ?? data.value?.nodes.find(n => n.x) ?? null
  if (!start) return
  drifting.value = true
  seen.clear(); seen.add(start.id)
  go(start)
  driftTimer = setInterval(() => {
    const here = selected.value
    const nextOne = (nearOf.value.get(here?.id ?? '') ?? []).find(x => !seen.has(x.node.id) && visibleNode(x.node))
    if (!nextOne) { stopDrift(); return }
    seen.add(nextOne.node.id)
    go(nextOne.node)
  }, 4500)
}
function stopDrift() { drifting.value = false; clearInterval(driftTimer) }

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
function goPair(p: Pair) { go(p.a); setTimeout(() => { selected.value = p.a }, 50) }
const nearSelected = computed(() => (nearOf.value.get(selected.value?.id ?? '') ?? []).slice(0, 8))
const linkedSelected = computed(() => linksOf.value.get(selected.value?.id ?? '') ?? [])
const showPairs = ref(false)
</script>

<template>
  <KBNeedsService>
    <div class="kbx" :class="{ dark: isDark }">
      <div ref="box" class="kbx-canvas"></div>
      <p v-if="loading" class="kbx-status">Loading the map…</p>
      <p v-else-if="error" class="kbx-status kb-error">{{ error }}</p>
      <p v-else-if="data && !data.nodes.length" class="kbx-status">Nothing to map yet: documents appear here once they are embedded.</p>

      <div class="kbx-bar">
        <input v-model="query" type="search" class="kb-field kbx-search" placeholder="Search the map… (Enter to go, Tab for the next)" />
        <div class="kbx-seg" role="group" aria-label="View">
          <button :class="{ on: view === '2d' }" @click="view = '2d'">Map</button>
          <button :class="{ on: view === '3d' }" @click="view = '3d'">Space</button>
        </div>
        <button class="kbx-btn" :class="{ on: drifting }" title="Wander from here along the nearest documents" @click="drift">{{ drifting ? 'Stop' : 'Drift' }}</button>
        <button class="kbx-btn" :class="{ on: showPairs }" title="Documents close in meaning that no link joins" @click="showPairs = !showPairs">Close, but not linked</button>
      </div>

      <details class="kbx-settings">
        <summary>Show</summary>
        <div class="kbx-row"><span>Colour by</span>
          <label><input v-model="colourBy" type="radio" value="cluster"> cluster</label>
          <label><input v-model="colourBy" type="radio" value="kind"> kind</label>
          <label><input v-model="colourBy" type="radio" value="whose"> whose</label></div>
        <div v-if="colourBy === 'whose'" class="kbx-row"><span></span>
          <label v-for="[k, l] in WHOSE" :key="k"><i class="kbx-swatch" :style="{ background: WHOSE_COLOURS[k] }"></i>{{ l }}</label></div>
        <div class="kbx-row"><span>Links</span>
          <label v-for="[k, l] in LINK_KINDS" :key="k"><input v-model="shownLinks" type="checkbox" :value="k">
            <i class="kbx-swatch" :style="{ background: LINK_COLOURS[k] }"></i>{{ l }}</label></div>
        <div class="kbx-row"><span>Documents</span>
          <label v-for="[k, l] in NODE_KINDS" :key="k"><input v-model="shownKinds" type="checkbox" :value="k">
            <i class="kbx-swatch" :style="{ background: KIND_COLOURS[k] }"></i>{{ l }}</label></div>
        <div class="kbx-row"><label title="Papers recorded or watched whose text has not been read in full: placed by their title and abstract">
          <input v-model="abstracts" type="checkbox"> Papers known only by their abstract</label></div>
        <div class="kbx-row"><label><input v-model="showUnlinked" type="checkbox"> Close but unlinked pairs, from</label>
          <input v-model.number="threshold" type="range" min="0.5" max="0.98" step="0.01"> {{ Math.round(threshold * 100) }}% alike</div>
        <p v-if="view === '3d'" class="kb-dim">Drag to turn, scroll to come closer; F flies (WASD, mouse to steer).{{ fly ? ' Flying: F to stop.' : '' }}</p>
      </details>

      <p v-if="building" class="kbx-building"><span class="kb-spinner"></span> {{ building }}</p>
      <p v-else-if="data && !data.abstracts && data.abstract_only" class="kbx-building kbx-left-out">
        The documents read in full. {{ data.abstract_only }} papers known only by their abstract are left out:
        <a href="#" @click.prevent="abstracts = true">include them</a></p>
      <p v-if="said" class="kbx-said" @click="said = ''">{{ said }}</p>

      <aside v-if="selected" class="kbx-card">
        <button class="kbx-close" aria-label="Close" @click="selected = null">×</button>
        <p class="kbx-kind"><i class="kbx-swatch" :style="{ background: colour(selected) }"></i>{{ kindName(selected.kind) }}<template v-if="selected.read === false"> · known by its abstract</template><template v-if="selected.year"> · {{ selected.year }}</template>
          <template v-if="clusterName(selected.cluster)"> · {{ clusterName(selected.cluster) }}</template></p>
        <h3><a :href="selected.page" target="_blank" rel="noopener">{{ selected.title }}</a></h3>
        <div class="kbx-actions">
          <button class="kbx-btn" @click="open(selected)">Open</button>
          <button v-if="selected.kind !== 'finding' && selected.kind !== 'task'" class="kbx-btn" @click="copyCitation(selected)">Copy citation</button>
          <button v-if="trail.length" class="kbx-btn" @click="back">Back</button>
        </div>
        <template v-if="linkedSelected.length">
          <h4>Linked</h4>
          <ul><li v-for="l in linkedSelected" :key="l.node.id + l.kind"><a href="#" @click.prevent="go(l.node)">{{ l.node.title }}</a>
            <span class="kb-dim"> {{ l.out ? l.kind : `${l.kind} it` }}</span></li></ul>
        </template>
        <template v-if="nearSelected.length">
          <h4>Nearest in meaning</h4>
          <ul><li v-for="x in nearSelected" :key="x.node.id"><a href="#" @click.prevent="go(x.node)">{{ x.node.title }}</a>
            <span class="kb-dim"> {{ Math.round(x.similarity * 100) }}%</span><span v-if="!x.linked" class="kbx-new">not linked</span></li></ul>
        </template>
      </aside>

      <aside v-if="showPairs" class="kbx-pairs">
        <button class="kbx-close" aria-label="Close" @click="showPairs = false">×</button>
        <h4>Close, but not linked</h4>
        <div class="kbx-row"><label><input v-model="scope" type="radio" value="all"> everywhere</label>
          <label><input v-model="scope" type="radio" value="cluster" :disabled="!selected"> in this cluster</label>
          <label title="Your notes and documents, and the shared ones close to them"><input v-model="scope" type="radio" value="own"> yours and the rest</label></div>
        <p v-if="!pairs.length" class="kb-dim">None at {{ Math.round(threshold * 100) }}% alike or more.</p>
        <ul>
          <li v-for="p in pairs" :key="p.a.id + p.b.id">
            <a href="#" @click.prevent="goPair(p)">{{ p.a.title }}</a> <span class="kb-dim">and</span>
            <a href="#" @click.prevent="go(p.b)">{{ p.b.title }}</a>
            <span class="kb-dim"> {{ Math.round(p.similarity * 100) }}%</span>
            <span v-if="p.a.kind === 'finding' && p.b.kind !== 'finding' && can('tasks.edit')"> · <a href="#" @click.prevent="addEvidence(p.a, p.b)">add as evidence</a></span>
            <span v-else-if="p.b.kind === 'finding' && p.a.kind !== 'finding' && can('tasks.edit')"> · <a href="#" @click.prevent="addEvidence(p.b, p.a)">add as evidence</a></span>
            <span v-else-if="p.a.kind === 'record' && p.b.kind === 'paper'"> · <a href="#" @click.prevent="copyCitation(p.b)">copy its citation</a></span>
            <span v-else-if="p.b.kind === 'record' && p.a.kind === 'paper'"> · <a href="#" @click.prevent="copyCitation(p.a)">copy its citation</a></span>
          </li>
        </ul>
      </aside>
    </div>
  </KBNeedsService>
</template>

<style scoped>
.kbx { position: relative; height: calc(100vh - var(--vp-nav-height, 64px) - 120px); min-height: 480px; border-radius: 10px;
       overflow: hidden; border: 1px solid var(--vp-c-divider); background: #fafafa; }
.kbx.dark { background: #111116; }
.kbx-canvas { position: absolute; inset: 0; }
.kbx-status { position: absolute; top: 45%; width: 100%; text-align: center; color: var(--vp-c-text-2); }
.kbx-bar { position: absolute; top: 10px; left: 10px; right: 10px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; pointer-events: none; }
.kbx-bar > * { pointer-events: auto; }
.kbx-search { flex: 1 1 18rem; max-width: 30rem; background: var(--vp-c-bg); }
.kbx-seg { display: inline-flex; border: 1px solid var(--vp-c-divider); border-radius: 8px; overflow: hidden; background: var(--vp-c-bg); }
.kbx-seg button { padding: 4px 12px; font-size: 13px; color: var(--vp-c-text-2); }
.kbx-seg button.on { background: var(--vp-c-brand-soft); color: var(--vp-c-text-1); font-weight: 600; }
.kbx-btn { padding: 4px 10px; font-size: 13px; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg); color: var(--vp-c-text-1); }
.kbx-btn.on { background: var(--vp-c-brand-soft); }
.kbx-settings { position: absolute; top: 52px; left: 10px; max-width: 34rem; background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider);
                border-radius: 8px; padding: 4px 10px; font-size: 13px; }
.kbx-settings summary { cursor: pointer; color: var(--vp-c-text-2); }
.kbx-row { display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: center; margin: 6px 0; }
.kbx-row > span { color: var(--vp-c-text-2); min-width: 5.5rem; }
.kbx-row label { display: inline-flex; align-items: center; gap: 4px; }
.kbx-swatch { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 2px; }
.kbx-building { position: absolute; bottom: 10px; left: 10px; font-size: 13px; color: var(--vp-c-text-2); background: var(--vp-c-bg);
                padding: 3px 10px; border-radius: 8px; border: 1px solid var(--vp-c-divider); display: flex; gap: 6px; align-items: center; }
.kbx-said { position: absolute; bottom: 10px; left: 50%; transform: translateX(-50%); font-size: 13px; background: var(--vp-c-bg);
            padding: 3px 12px; border-radius: 8px; border: 1px solid var(--vp-c-divider); cursor: pointer; }
.kbx-card, .kbx-pairs { position: absolute; top: 52px; right: 10px; width: min(24rem, 45%); max-height: calc(100% - 64px); overflow: auto;
                        background: var(--vp-c-bg); border: 1px solid var(--vp-c-divider); border-radius: 10px; padding: 10px 14px; font-size: 13px;
                        box-shadow: 0 4px 18px rgba(0, 0, 0, 0.18); }
.kbx-pairs { right: auto; left: 10px; top: auto; bottom: 46px; max-height: 45%; }
.kbx-card h3 { margin: 4px 0 8px; font-size: 16px; line-height: 1.35; }
.kbx-card h4, .kbx-pairs h4 { margin: 10px 0 4px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--vp-c-text-2); }
.kbx-card ul, .kbx-pairs ul { padding-left: 1rem; margin: 0; }
.kbx-card li, .kbx-pairs li { margin: 3px 0; }
.kbx-kind { color: var(--vp-c-text-2); margin: 0; }
.kbx-actions { display: flex; gap: 6px; flex-wrap: wrap; }
.kbx-close { position: absolute; top: 4px; right: 8px; font-size: 18px; color: var(--vp-c-text-2); }
.kbx-new { margin-left: 6px; font-size: 11px; padding: 0 5px; border-radius: 4px; background: var(--vp-c-brand-soft); color: var(--vp-c-text-1); }
:deep(.kbx-tip) { font: 12px system-ui, sans-serif; max-width: 22rem; }
</style>
