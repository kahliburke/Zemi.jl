<!--
  A paper's PDF at a page, in the browser's own PDF viewer. With the service, a button opens it in a
  dialog over the page (Escape, Close or the backdrop closes it); the service sends the PDF, fetching
  an arXiv paper's from arXiv the first time. Without the service, an arXiv paper's is a link to
  arXiv's PDF in a new tab, and an upload's is not offered. `chip` draws it small, for a section.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { api, mode, connect } from './kbApi'
import { servicePdf, arxivPdf } from './kbPdf'
import KBDialog from './KBDialog.vue'

const props = defineProps<{ id: string; page?: number | null; version?: string; local?: boolean; label: string; chip?: boolean }>()

const src = computed(() => servicePdf(api.value, props.id))
const at = computed(() => servicePdf(api.value, props.id, props.page))
const arxiv = computed(() => arxivPdf(props.id, props.version, props.page))
const title = computed(() => (props.page ? `PDF, page ${props.page}` : 'PDF'))

const open = ref(false)
const state = ref<'loading' | 'ready' | 'error'>('loading')
const error = ref('')
let request: AbortController | null = null

// The PDF is asked for first, so a missing one is said plainly and the first fetch from arXiv shows
// as loading; the frame then has it from the browser's cache.
async function show() {
  open.value = true
  state.value = 'loading'
  error.value = ''
  request = new AbortController()
  try {
    const r = await fetch(src.value, { signal: request.signal })
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error ?? r.statusText)
    await r.blob()
    state.value = 'ready'
  } catch (e: any) {
    if (e.name === 'AbortError') return
    error.value = e.message ?? String(e)
    state.value = 'error'
  }
}
// (Keys pressed in the viewer stay in its frame: Escape closes the dialog when the focus is outside it.)
function close() {
  request?.abort()
  open.value = false
}
onMounted(() => connect())
onBeforeUnmount(() => request?.abort())
</script>

<template>
  <button v-if="mode === 'live'" type="button" :class="chip ? 'kbpdf-chip' : 'kb-button'"
          :title="`Open the ${title}`" @click.prevent.stop="show">{{ label }}</button>
  <a v-else-if="!local" :class="chip ? 'kbpdf-chip' : 'kb-button'" :href="arxiv" target="_blank" rel="noopener"
     :title="`arXiv's ${title}`" @click.stop>{{ label }}</a>
  <KBDialog v-if="open" :label="title" width="min(1100px, 96vw)" bare :shade="0.75" @close="close">
    <section class="kbpdf-box">
      <header class="kbpdf-head">
        <span class="kbpdf-title">{{ title }}</span>
        <a v-if="state === 'ready'" :href="at" target="_blank" rel="noopener">New tab</a>
        <button type="button" class="kbpdf-close" autofocus @click="close">Close</button>
      </header>
      <p v-if="state === 'loading'" class="kb-dim kbpdf-dim">Loading the PDF…</p>
      <p v-else-if="state === 'error'" class="kb-error kbpdf-error">{{ error }}</p>
      <iframe v-else class="kbpdf-frame" :src="at" :title="title"></iframe>
    </section>
  </KBDialog>
</template>

<style scoped>
.kbpdf-chip { display: inline-block; margin-left: 0.6rem; padding: 0 0.5rem; border: 1px solid var(--vp-c-divider); border-radius: 999px;
  background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.78rem; font-weight: 500; line-height: 1.5rem;
  text-decoration: none; cursor: pointer; vertical-align: middle; }
.kbpdf-chip:hover, .kbpdf-chip:focus-visible { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbpdf-box { background: var(--vp-c-bg); color: var(--vp-c-text-1); border-radius: 10px; padding: 0.7rem 1rem 1rem;
  height: 90vh; display: flex; flex-direction: column; gap: 0.6rem; box-shadow: var(--vp-shadow-5); }
.kbpdf-head { display: flex; gap: 0.9rem; align-items: center; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbpdf-title { font-weight: 600; color: var(--vp-c-text-1); }
.kbpdf-head a { color: var(--vp-c-brand-1); }
.kbpdf-close { margin-left: auto; padding: 0.2rem 0.7rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: none;
  color: var(--vp-c-text-1); font: inherit; cursor: pointer; }
.kbpdf-close:hover, .kbpdf-close:focus-visible { border-color: var(--vp-c-brand-1); }
.kbpdf-frame { flex: 1; width: 100%; border: 1px solid var(--vp-c-divider); border-radius: 6px; background: var(--vp-c-bg-soft); }
.kbpdf-dim { font-size: 0.9rem; }
.kbpdf-error { font-size: 0.9rem; }
</style>
