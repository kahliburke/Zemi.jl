<!--
  A document's neighbourhood, on its page: it, the documents nearest it in meaning and those linked to
  it, in a small map with a way to the explore page. The document, those linked to it and its nearest
  are named on the map, as far as there is room; pointing at any names it in full. Links are drawn in
  their kind's colour, pairs alike in meaning that nothing links dashed, and a legend says which is
  which. Clicking a document opens its page. The map is shown with a running knowledge base, once the
  map has it; the related papers the page was written with are listed below it, folded, and open where
  there is no map (a published site).
-->
<script setup lang="ts">
import { ref, shallowRef, computed, watch, nextTick } from 'vue'
import { useData } from 'vitepress'
import { getJSON, onLive } from './kbApi'
import { exploreHref, kbPage } from './kbLinks'
import { KIND_COLOURS, LINK_COLOURS, LINK_KINDS, NODE_KINDS, kindName } from './kbExplore'

const props = withDefaults(defineProps<{ id: string; related?: { title: string; slug: string; page: string }[]; anchor?: string }>(),
                           { related: () => [], anchor: 'nearby' })
const { isDark } = useData()
type Node = { id: string; kind: string; title: string; page: string; links: number; year?: string; x?: [number, number] }
type Graph = { nodes: Node[]; links: [number, number, string][]; similar: [number, number, number, boolean][] }
type GNode = Omit<Node, 'x'> & { x?: any; y?: any }
type GLink = { source: any; target: any; kind: string; s?: number }

// The most documents named on the map besides this one: its links first, then its nearest.
const NAMED = 7
const HEIGHT = 380
const box = ref<HTMLDivElement | null>(null)
const found = ref(false)
const shown = shallowRef<{ kinds: string[]; links: string[]; similar: boolean }>({ kinds: [], links: [], similar: false })
const named = new Set<string>()
const pointed = shallowRef<GNode | null>(null)
const tipAt = ref({ x: 0, y: 0 })
let graph: any = null

// Discs a steady size on screen however far apart the neighbours lie: drawn at `rel` per unit of
// √value, which the fit sets against the zoom it ends at (see `draw`).
const radiusVal = (n: { id: string; links: number }) => (n.id === props.id ? 5 : 1.8 + Math.sqrt(n.links) * 0.6)
let rel = 4
const radius = (n: { id: string; links: number }) => Math.sqrt(radiusVal(n)) * rel
const short = (t: string) => (t.length > 34 ? t.slice(0, 32).trimEnd() + '…' : t)
const selfColour = () => (isDark.value ? '#ffffff' : '#111111')
const similarColour = (s: number) => (isDark.value ? `rgba(200,200,255,${0.15 + 0.35 * s})` : `rgba(60,60,140,${0.15 + 0.35 * s})`)

async function draw() {
  let g: Graph
  try { g = await getJSON(`/api/graph?center=${encodeURIComponent(props.id)}&depth=1&limit=40`) } catch { return }
  found.value = g.nodes.length > 1
  if (!found.value) return
  await nextTick()
  if (!box.value) return
  const ForceGraph = (await import('force-graph')).default as any
  const nodes: GNode[] = g.nodes.map(({ x, ...n }) => ({ ...n, ...(x ? { x: x[0] * 400, y: -x[1] * 400 } : {}) }))
  const links: GLink[] = [...g.links.map(([i, j, kind]) => ({ source: g.nodes[i].id, target: g.nodes[j].id, kind })),
                          // Alike in meaning: this document to each of its nearest that nothing links it to, not
                          // the nearest among themselves, which tangle the map.
                          ...g.similar.filter(([i, j, , linked]) => !linked && (g.nodes[i].id === props.id || g.nodes[j].id === props.id))
                                      .map(([i, j, s]) => ({ source: g.nodes[i].id, target: g.nodes[j].id, kind: 'similar', s }))]
  // Named: those linked to this document, then those most alike, up to `NAMED`.
  const touching = (l: { source: string; target: string }) => l.source === props.id ? l.target : l.target === props.id ? l.source : null
  const linked = links.filter(l => l.kind !== 'similar').map(touching).filter((x): x is string => !!x)
  const alike = links.filter(l => l.kind === 'similar').sort((a, b) => (b.s ?? 0) - (a.s ?? 0)).map(touching).filter((x): x is string => !!x)
  named.clear()
  for (const id of [...new Set([...linked, ...alike])].slice(0, NAMED)) named.add(id)
  shown.value = { kinds: NODE_KINDS.map(([k]) => k).filter(k => nodes.some(n => n.id !== props.id && n.kind === k)),
                  links: LINK_KINDS.map(([k]) => k).filter(k => links.some(l => l.kind === k)),
                  similar: links.some(l => l.kind === 'similar') }
  graph?._destructor?.()
  graph = new ForceGraph(box.value)
    .width(box.value.clientWidth).height(HEIGHT).backgroundColor('rgba(0,0,0,0)')
    .graphData({ nodes, links }).nodeId('id')
    .nodeVal(radiusVal)
    .nodeColor((n: GNode) => (n.id === props.id ? selfColour() : KIND_COLOURS[n.kind] ?? '#999'))
    .nodeLabel(() => '')
    .onNodeHover((n: GNode | null) => { pointed.value = n })
    .linkColor((l: GLink) => (l.kind === 'similar' ? similarColour(l.s ?? 0) : LINK_COLOURS[l.kind] ?? '#999'))
    .linkWidth((l: GLink) => (l.kind === 'similar' ? 0.8 : 1.4))
    .linkLineDash((l: GLink) => (l.kind === 'similar' ? [2, 3] : null))
    .linkDirectionalArrowLength((l: GLink) => (l.kind === 'cites' || l.kind === 'refers' ? 4 : 0))
    .linkDirectionalArrowRelPos(1)
    .onNodeClick((n: GNode) => { if (n.id !== props.id) location.href = n.page })
    .onRenderFramePost(names)
    .cooldownTicks(80)
  // The more alike, the closer: a neighbour's distance from this document says how alike they are.
  graph.d3Force('link')?.strength((l: GLink) => (l.kind === 'similar' ? 0.8 : 0.3))
    .distance((l: GLink) => (l.kind === 'similar' ? 20 + (1 - (l.s ?? 0)) * 220 : 50))
  rel = 4
  setTimeout(() => {
    graph?.zoomToFit(400, 40)
    setTimeout(() => { if (graph) { rel = 4 / graph.zoom(); graph.nodeRelSize(rel) } }, 420)
  }, 400)
}

// The named documents' short titles beside them, a constant size on screen: each on the right of its node,
// else its left, above or below, clear of the names placed and the named discs, and left out where none is.
// This document is the page's, so it goes unnamed.
function names(ctx: CanvasRenderingContext2D, scale: number) {
  const nodes: GNode[] = (graph?.graphData().nodes ?? []).filter((n: GNode) => n.x !== undefined)
  const order = nodes.filter(n => named.has(n.id))
  const taken = nodes.filter(n => n.id === props.id || named.has(n.id)).map(n => {
    const r = radius(n)
    return { x0: n.x - r, x1: n.x + r, y0: n.y - r, y1: n.y + r }
  })
  const h = 15 / scale, pad = 4 / scale
  ctx.save()
  ctx.textBaseline = 'middle'
  ctx.font = `500 ${11 / scale}px system-ui, sans-serif`
  for (const n of order) {
    const text = short(n.title), w = ctx.measureText(text).width + 2 * pad
    const r = radius(n) + 3 / scale
    const spots = [[n.x + r, n.y - h / 2], [n.x - r - w, n.y - h / 2], [n.x - w / 2, n.y - r - h], [n.x - w / 2, n.y + r]]
    const clear = ([x, y]: number[]) => taken.every(b => x + w < b.x0 || x > b.x1 || y + h < b.y0 || y > b.y1)
    const at = spots.find(clear)
    if (!at) continue
    const [x, y] = at
    taken.push({ x0: x, x1: x + w, y0: y, y1: y + h })
    ctx.fillStyle = isDark.value ? 'rgba(17,17,22,0.78)' : 'rgba(250,250,250,0.86)'
    ctx.beginPath(); ctx.roundRect(x, y, w, h, 3 / scale); ctx.fill()
    ctx.fillStyle = isDark.value ? 'rgba(230,230,240,0.92)' : 'rgba(35,35,45,0.9)'
    ctx.fillText(text, x + pad, y + h / 2)
  }
  ctx.restore()
}

function moved(e: PointerEvent) {
  const r = box.value?.getBoundingClientRect()
  if (r) tipAt.value = { x: e.clientX - r.left, y: e.clientY - r.top }
}
const linkName = computed(() => Object.fromEntries(LINK_KINDS) as Record<string, string>)
const nodeName = computed(() => Object.fromEntries(NODE_KINDS) as Record<string, string>)

onLive(() => { draw(); return () => graph?._destructor?.() })
watch(() => props.id, () => draw())
watch(isDark, () => graph?.nodeColor(graph.nodeColor()))
</script>

<template>
  <section v-show="found || related.length" class="kbn">
    <div class="kbn-head"><h2 :id="anchor">Nearby</h2><a v-if="found" :href="exploreHref(props.id)">Explore from here →</a></div>
    <div v-show="found" class="kbn-frame" @pointermove="moved" @pointerleave="pointed = null">
      <div ref="box" class="kbn-map"></div>
      <div v-if="pointed" class="kbn-tip" :style="{ left: tipAt.x + 'px', top: tipAt.y + 'px' }" role="tooltip">
        <b>{{ pointed.title }}</b><br>{{ [pointed.id === props.id ? 'this document' : kindName(pointed.kind), pointed.year].filter(Boolean).join(' · ') }}
      </div>
    </div>
    <ul v-show="found" class="kbn-legend" aria-label="Legend">
      <li><i class="kbn-dot" :style="{ background: selfColour() }"></i>This document</li>
      <li v-for="k in shown.kinds" :key="k"><i class="kbn-dot" :style="{ background: KIND_COLOURS[k] }"></i>{{ nodeName[k] }}</li>
      <li v-for="k in shown.links" :key="k"><i class="kbn-line" :style="{ borderColor: LINK_COLOURS[k] }"></i>{{ linkName[k] }}</li>
      <li v-if="shown.similar"><i class="kbn-line kbn-dashed"></i>Alike in meaning, not linked</li>
    </ul>
    <details v-if="related.length" class="kbn-related" :open="!found">
      <summary>Related papers ({{ related.length }})</summary>
      <ul><li v-for="r in related" :key="r.slug"><a :href="kbPage(r.page)">{{ r.title }}</a></li></ul>
    </details>
  </section>
</template>

<style scoped>
.kbn { margin: 1.5rem 0; }
.kbn-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; }
.kbn-head h2 { margin: 0; border: 0; padding: 0; font-size: 1.1rem; }
.kbn-frame { position: relative; margin-top: 0.5rem; }
.kbn-map { height: 380px; border: 1px solid var(--vp-c-divider); border-radius: 8px; overflow: hidden; }
.kbn-tip { position: absolute; z-index: 5; transform: translate(14px, 14px); max-width: 22rem; padding: 5px 9px; pointer-events: none;
           border: 1px solid var(--vp-c-divider); border-radius: 6px; background: var(--vp-c-bg-elv); box-shadow: var(--vp-shadow-2);
           color: var(--vp-c-text-1); font: 12px/1.4 system-ui, sans-serif; }
.kbn-legend { display: flex; flex-wrap: wrap; gap: 4px 14px; list-style: none; margin: 6px 0 0; padding: 0; font-size: 12px; color: var(--vp-c-text-2); }
.kbn-legend li { display: inline-flex; align-items: center; gap: 6px; margin: 0; }
.kbn-dot { width: 9px; height: 9px; border-radius: 50%; }
.kbn-line { width: 18px; border-top: 2px solid; }
.kbn-dashed { border-top: 2px dashed var(--vp-c-text-3); }
.kbn-related { margin-top: 0.6rem; }
.kbn-related summary { cursor: pointer; color: var(--vp-c-text-2); font-size: 0.9rem; }
.kbn-related ul { margin: 0.4rem 0 0; }
</style>
