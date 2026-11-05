<!--
  A Slate notebook in a codebase's pages, read as a notebook: its Markdown cells rendered, its code
  cells highlighted, in order (see `notebook_cells` in src/site.jl, which writes them as JSON beside
  the codebase's tree). Its outputs are not shown: a codebase's notebooks are not run to build pages.
-->
<script setup lang="ts">
import { ref, shallowRef, onMounted } from 'vue'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'
import { siteJSON } from './kbApi'
import { fenced } from './kbUtils'

const props = defineProps<{ src: string }>()
type Cell = { kind: string; id: string; source: string }
const cells = ref<Cell[]>([])
const error = ref('')
const markdown = shallowRef<Render>(escapeText)
const render = (c: Cell) => markdown.value(c.kind === 'md' ? c.source : fenced(c.source, 'julia'))

onMounted(async () => {
  try {
    cells.value = (await siteJSON(props.src)).cells
    markdown.value = await loadMarkdown()
  } catch (e: any) { error.value = e.message }
})
</script>

<template>
  <div class="kbn">
    <p v-if="error" class="kb-error kbn-error">{{ error }}</p>
    <section v-for="c in cells" :id="c.id ? `cell-${c.id}` : undefined" :key="c.id || c.source" class="kbn-cell" :class="c.kind">
      <a v-if="c.id" class="kbn-id" :href="`#cell-${c.id}`">{{ c.id }}</a>
      <div class="kb-md" v-html="render(c)"></div>
    </section>
  </div>
</template>

<style scoped>
.kbn { margin: 1rem 0; }
.kbn-cell { position: relative; margin: 0.4rem 0; }
.kbn-cell.code :deep(pre) { margin: 0.2rem 0; }
.kbn-cell:not(.md) { padding-left: 0.6rem; border-left: 2px solid var(--vp-c-divider); }
.kbn-id { position: absolute; right: 0.4rem; top: 0.3rem; z-index: 1; font-family: var(--vp-font-family-mono); font-size: 0.7rem;
  color: var(--vp-c-text-3); text-decoration: none; opacity: 0; transition: opacity 0.15s; }
.kbn-cell:hover .kbn-id { opacity: 1; }
.kbn-error { font-size: 0.85rem; }
</style>
