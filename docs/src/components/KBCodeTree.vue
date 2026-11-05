<!--
  A codebase's files and directories as a tree to browse: each with its summary, directories opening
  and closing, and a filter that matches names, paths and summaries. Reads the tree the docs build
  writes (see `write_code_site`), so it works on a static site too.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { pageLink } from './kbLinks'
import { siteJSON } from './kbApi'

const props = defineProps<{ src: string; pages: string }>()

type Node = { name: string; path: string; kind: 'dir' | 'file'; summary: string | null; lines?: number;
              definitions?: number; page?: string; children: Node[] }
type Row = { node: Node; depth: number }

const tree = ref<Node | null>(null)
const error = ref('')
const filter = ref('')
const open = ref<Set<string>>(new Set())
const shown = ref<Set<string>>(new Set())   // directories whose whole summary is shown

onMounted(async () => {
  try {
    tree.value = (await siteJSON(props.src)).tree
    open.value = new Set((tree.value?.children ?? []).filter(c => c.kind === 'dir').map(c => c.path))
  } catch (e: any) { error.value = `Load failed: ${e.message ?? e}` }
})

const files = (n: Node): number => n.kind === 'file' ? 1 : n.children.reduce((s, c) => s + files(c), 0)
const matches = (n: Node, q: string): boolean =>
  `${n.path} ${n.summary ?? ''}`.toLowerCase().includes(q) || n.children.some(c => matches(c, q))

const rows = computed<Row[]>(() => {
  const out: Row[] = []
  const q = filter.value.trim().toLowerCase()
  const walk = (n: Node, depth: number) => {
    for (const c of n.children) {
      if (q && !matches(c, q)) continue
      out.push({ node: c, depth })
      if (c.kind === 'dir' && (q || open.value.has(c.path))) walk(c, depth + 1)
    }
  }
  if (tree.value) walk(tree.value, 0)
  return out
})

function toggle(path: string) {
  const s = new Set(open.value)
  s.has(path) ? s.delete(path) : s.add(path)
  open.value = s
}
function toggleSummary(path: string) {
  const s = new Set(shown.value)
  s.has(path) ? s.delete(path) : s.add(path)
  shown.value = s
}
const allDirs = (n: Node): string[] => n.children.filter(c => c.kind === 'dir').flatMap(c => [c.path, ...allDirs(c)])
const expandAll = () => { if (tree.value) open.value = new Set(allDirs(tree.value)) }
const collapseAll = () => { open.value = new Set() }

const firstSentence = (s: string | null) => (s ?? '').match(/^.*?[.!?](?=\s|$)/s)?.[0] ?? (s ?? '')
</script>

<template>
  <div class="kbt">
    <p v-if="error" class="kb-error kbt-error">{{ error }}</p>
    <template v-else-if="tree">
      <div class="kbt-bar">
        <input v-model="filter" type="search" class="kb-field kbt-filter" placeholder="Filter…" />
        <button type="button" class="kb-link" @click="expandAll">expand all</button>
        <button type="button" class="kb-link" @click="collapseAll">collapse all</button>
      </div>
      <div v-for="r in rows" :key="r.node.path" class="kbt-row" :style="{ paddingLeft: `${r.depth * 1.3}rem` }">
        <template v-if="r.node.kind === 'dir'">
          <button type="button" class="kbt-dir" @click="toggle(r.node.path)">
            <span class="kbt-caret">{{ filter.trim() || open.has(r.node.path) ? '▾' : '▸' }}</span>{{ r.node.name }}
          </button>
          <span class="kbt-dim">{{ files(r.node) }} files</span>
          <div v-if="r.node.summary" class="kbt-summary">
            {{ shown.has(r.node.path) ? r.node.summary : firstSentence(r.node.summary) }}
            <button v-if="firstSentence(r.node.summary) !== r.node.summary" type="button" class="kb-link"
                    @click="toggleSummary(r.node.path)">{{ shown.has(r.node.path) ? 'less' : 'more' }}</button>
          </div>
        </template>
        <template v-else>
          <a class="kbt-file" :href="pageLink(props.pages + r.node.page)">{{ r.node.name }}</a>
          <span class="kbt-dim">{{ r.node.lines }} lines<span v-if="r.node.definitions"> · {{ r.node.definitions }} definitions</span></span>
          <div v-if="r.node.summary" class="kbt-summary" :title="r.node.summary">{{ firstSentence(r.node.summary) }}</div>
        </template>
      </div>
      <p v-if="!rows.length" class="kbt-dim">Nothing matches.</p>
    </template>
    <p v-else class="kbt-dim">Loading…</p>
  </div>
</template>

<style scoped>
.kbt { margin: 1rem 0 2rem; font-size: 0.9rem; }
.kbt-bar { display: flex; align-items: center; gap: 0.8rem; margin-bottom: 0.6rem; }
.kbt-filter { flex: 1; padding: 0.45rem 0.8rem; border-radius: 8px; }
.kbt-row { padding: 0.35rem 0; border-top: 1px solid var(--vp-c-divider); }
.kbt-dir { background: none; border: none; padding: 0; font: inherit; font-weight: 600; color: var(--vp-c-text-1); cursor: pointer; }
.kbt-caret { display: inline-block; width: 1.1rem; color: var(--vp-c-text-3); }
.kbt-file { font-family: var(--vp-font-family-mono); font-size: 0.86rem; margin-left: 1.1rem; }
.kbt-dim { color: var(--vp-c-text-3); font-size: 0.8rem; margin-left: 0.6rem; }
.kbt-summary { color: var(--vp-c-text-2); margin: 0.15rem 0 0 1.1rem; line-height: 1.45; }
.kb-link { font-size: 0.85rem; }
</style>
