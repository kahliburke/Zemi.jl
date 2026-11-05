<!--
  A section's full text on a paper's page, opened on demand: the service sends it when it is opened,
  so the site's build carries only the section's title and summary. Its paragraphs, equations,
  captions and references are shown as the paper's reading split them, a caption set apart from the
  running text with its label in bold. Beside its title, the PDF at the section's first page (see
  KBPdf.vue).
-->
<script setup lang="ts">
import { ref } from 'vue'
import { mode, connect, getJSON } from './kbApi'
import KBPdf from './KBPdf.vue'

const props = defineProps<{ id: string; section: number; label: string; page?: number | null; version?: string; local?: boolean }>()
type Block = { kind: string; text: string; label?: string }
const blocks = ref<Block[] | null>(null)
const error = ref('')

// A caption's label ("Figure 3.", "TABLE II:"), shown apart from the rest of its text.
const LABEL = /^((?:fig(?:ure)?|tab(?:le)?)\.?\s*(?:[A-Z]?\d+(?:\.\d+)*|[IVXLC]+)\s*[:.|–—]?)\s*/i
function withLabel(b: Block): Block {
  const m = b.kind === 'caption' ? b.text.match(LABEL) : null
  return m ? { ...b, label: m[1].trim(), text: b.text.slice(m[0].length) } : b
}

async function opened(e: Event) {
  if (!(e.target as HTMLDetailsElement).open || blocks.value) return
  await connect()
  if (mode.value !== 'live') { error.value = 'Needs a running Zemi server.'; return }
  try {
    blocks.value = (await getJSON(`/api/paper-text?id=${encodeURIComponent(props.id)}&section=${props.section}`)).map(withLabel)
  } catch (err: any) { error.value = err.message ?? String(err) }
}
</script>

<template>
  <details class="details custom-block kbst" @toggle="opened">
    <summary>{{ label }}<KBPdf v-if="page" :id="id" :page="page" :version="version" :local="local" :label="`PDF p. ${page}`" chip /></summary>
    <p v-if="error" class="kb-dim kbst-dim">{{ error }}</p>
    <p v-else-if="!blocks" class="kb-dim kbst-dim">Loading…</p>
    <template v-else>
      <template v-for="(b, i) in blocks" :key="i">
        <pre v-if="b.kind === 'equation'" class="kbst-eq">{{ b.text }}</pre>
        <figure v-else-if="b.kind === 'caption'" class="kbst-cap">
          <figcaption><strong v-if="b.label">{{ b.label }}</strong> {{ b.text }}</figcaption>
        </figure>
        <p v-else-if="b.kind === 'reference'" class="kbst-ref">{{ b.text }}</p>
        <p v-else>{{ b.text }}</p>
      </template>
    </template>
  </details>
</template>

<style scoped>
.kbst-dim { font-size: 0.9rem; }
.kbst-eq { white-space: pre-wrap; font-size: 0.85rem; background: var(--vp-c-bg-soft); padding: 0.5rem 0.7rem; border-radius: 6px; }
.kbst-ref { margin: 0.2rem 0; font-size: 0.9rem; }
.kbst-cap { margin: 1rem 0; padding: 0.4rem 0.8rem; border-left: 3px solid var(--vp-c-divider); background: var(--vp-c-bg-soft);
  border-radius: 0 6px 6px 0; }
.kbst-cap figcaption { font-size: 0.85rem; line-height: 1.5; color: var(--vp-c-text-2); }
.kbst-cap strong { color: var(--vp-c-text-1); }
</style>
