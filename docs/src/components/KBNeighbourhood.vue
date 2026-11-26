<!--
  A document's neighbourhood, on its page: it, the documents nearest it in meaning and those linked to
  it, in a small map placed as the explore page places them (see KBExplore.vue), with a way there.
  Clicking a document opens its page. Shown with a running knowledge base, once the map has it.
-->
<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import { useData } from 'vitepress'
import { getJSON, onLive } from './kbApi'
import { kbPage } from './kbLinks'

const props = defineProps<{ id: string }>()
const { isDark } = useData()
type Node = { id: string; kind: string; title: string; page: string; links: number; x?: [number, number] }
type Graph = { nodes: Node[]; links: [number, number, string][]; similar: [number, number, number, boolean][] }

const KIND_COLOURS: Record<string, string> = { paper: '#5b8def', record: '#3dd68c', code: '#f0a35e', resource: '#c58af9',
                                               finding: '#f6d55c', task: '#ef6f6c' }
const box = ref<HTMLDivElement | null>(null)
const found = ref(false)
let graph: any = null

async function draw() {
  let g: Graph
  try { g = await getJSON(`/api/graph?center=${encodeURIComponent(props.id)}&depth=1&limit=40`) } catch { return }
  found.value = g.nodes.length > 1
  if (!found.value) return
  await nextTick()
  if (!box.value) return
  const ForceGraph = (await import('force-graph')).default as any
  const nodes = g.nodes.map(n => ({ ...n, ...(n.x ? { x: n.x[0] * 400, y: -n.x[1] * 400 } : {}) }))
  const links = [...g.links.map(([i, j, kind]) => ({ source: g.nodes[i].id, target: g.nodes[j].id, kind })),
                 ...g.similar.map(([i, j, s]) => ({ source: g.nodes[i].id, target: g.nodes[j].id, kind: 'similar', s }))]
  graph?._destructor?.()
  graph = new ForceGraph(box.value)
    .width(box.value.clientWidth).height(260).backgroundColor('rgba(0,0,0,0)')
    .graphData({ nodes, links }).nodeId('id')
    .nodeVal((n: Node) => (n.id === props.id ? 6 : 1.5 + Math.sqrt(n.links)))
    .nodeColor((n: Node) => (n.id === props.id ? (isDark.value ? '#ffffff' : '#111111') : KIND_COLOURS[n.kind] ?? '#999'))
    .nodeLabel((n: Node) => n.title.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!)))
    .linkColor((l: any) => (l.kind === 'similar' ? (isDark.value ? 'rgba(200,200,255,0.25)' : 'rgba(60,60,140,0.25)') : '#8ab4f8'))
    .linkLineDash((l: any) => (l.kind === 'similar' ? [2, 3] : null))
    .onNodeClick((n: Node) => { if (n.id !== props.id) location.href = n.page })
    .cooldownTicks(80)
  graph.d3Force('link')?.strength((l: any) => (l.kind === 'similar' ? l.s * 0.4 : 0.3))
  setTimeout(() => graph?.zoomToFit(400, 20), 400)
}

onLive(() => { draw(); return () => graph?._destructor?.() })
watch(() => props.id, () => draw())
const explore = () => `${kbPage('explore')}?center=${encodeURIComponent(props.id)}`
</script>

<template>
  <section v-show="found" class="kbn">
    <div class="kbn-head"><h2>Nearby</h2><a :href="explore()">Explore from here →</a></div>
    <div ref="box" class="kbn-map"></div>
  </section>
</template>

<style scoped>
.kbn { margin: 1.5rem 0; }
.kbn-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; }
.kbn-head h2 { margin: 0; border: 0; padding: 0; font-size: 1.1rem; }
.kbn-map { height: 260px; border: 1px solid var(--vp-c-divider); border-radius: 8px; overflow: hidden; margin-top: 0.5rem; }
</style>
