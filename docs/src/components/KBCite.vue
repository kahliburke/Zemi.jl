<!--
  How to cite what a page shows: a Cite button opening a panel with each form to copy (its `@`
  reference, its address, a Markdown link, and for a document its citation in prose and its BibTeX
  entry, from its data: see `cite_json`), and beside it an icon copying the reference at once. The
  address is the page's own, wherever the site is served; `link` gives another (a task on a board).
  `compact` draws the button small, for a panel's header.
-->
<script setup lang="ts">
import { ref, computed } from 'vue'
import KBDialog from './KBDialog.vue'
import KBIcon from './KBIcon.vue'
import { copyText } from './kbUtils'

type Cite = { reference: string; citation?: string; bibtex?: string }
const props = defineProps<{ cite: Cite; title: string; link?: string; compact?: boolean }>()

const open = ref(false)
const copied = ref('')
const failed = ref('')

const address = computed(() => typeof location === 'undefined' ? props.link ?? '' :
                                props.link ? new URL(props.link, location.href).href : location.origin + location.pathname)
const forms = computed(() => [
  { key: 'reference', label: 'Reference', note: 'in a task, note or finding here', text: props.cite.reference },
  { key: 'citation', label: 'Citation', note: 'APA', text: props.cite.citation ?? '' },
  { key: 'bibtex', label: 'BibTeX', note: '', text: props.cite.bibtex?.trim() ?? '' },
  { key: 'link', label: 'Link', note: '', text: address.value },
  { key: 'markdown', label: 'Markdown', note: '', text: `[${props.title.replace(/[[\]]/g, '\\$&')}](${address.value})` },
].filter(f => f.text))

async function copy(key: string, text: string) {
  failed.value = ''
  try {
    await copyText(text)
    copied.value = key
    setTimeout(() => { if (copied.value === key) copied.value = '' }, 1500)
  } catch (e: any) { failed.value = e.message ?? String(e) }
}
</script>

<template>
  <span class="kbct">
    <button :class="compact ? 'kbct-small' : 'kb-button'" type="button" @click="open = true">Cite</button>
    <button class="kbct-icon" type="button" :title="copied === 'quick' ? 'Copied' : `Copy ${cite.reference}`"
            :aria-label="`Copy the reference ${cite.reference}`" @click="copy('quick', cite.reference)">
      <KBIcon :name="copied === 'quick' ? 'check' : 'copy'" :size="15" />
    </button>
    <KBDialog v-if="open" width="min(42rem, 94vw)" @close="open = false">
      <h3 class="kbct-title">Cite <em>{{ title }}</em></h3>
      <div v-for="f in forms" :key="f.key" class="kbct-form">
        <div class="kbct-label">{{ f.label }}<span v-if="f.note" class="kbct-note"> · {{ f.note }}</span></div>
        <pre class="kbct-text" :class="{ code: f.key === 'bibtex' }">{{ f.text }}</pre>
        <button class="kbct-copy" type="button" :title="copied === f.key ? 'Copied' : 'Copy'" :aria-label="`Copy the ${f.label.toLowerCase()}`"
                @click="copy(f.key, f.text)">
          <KBIcon :name="copied === f.key ? 'check' : 'copy'" :size="16" />
        </button>
      </div>
      <p v-if="failed" class="kb-error">{{ failed }}</p>
      <div class="kbct-done"><button class="kb-button" type="button" @click="open = false">Done</button></div>
    </KBDialog>
  </span>
</template>

<style scoped>
.kbct { display: inline-flex; align-items: center; gap: 0.3rem; }
.kbct-icon, .kbct-copy { display: inline-flex; align-items: center; justify-content: center; border-radius: 6px; cursor: pointer;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-2); }
.kbct-icon { width: 28px; height: 28px; }
.kbct-small { font-size: 0.78rem; padding: 0.1rem 0.5rem; border-radius: 6px; cursor: pointer;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-2); }
.kbct-small:hover { color: var(--vp-c-brand-1); border-color: var(--vp-c-brand-1); }
.kbct-small + .kbct-icon { width: 24px; height: 24px; }
@media (pointer: coarse) { .kbct-icon, .kbct-small + .kbct-icon { width: 40px; height: 40px; } }
.kbct-copy { width: 30px; height: 30px; }
.kbct-icon:hover, .kbct-copy:hover { color: var(--vp-c-brand-1); border-color: var(--vp-c-brand-1); }
.kbct-title { margin: 0 0 0.8rem; font-size: 1rem; }
.kbct-form { display: grid; grid-template-columns: 1fr auto; gap: 0.2rem 0.6rem; margin: 0.7rem 0; }
.kbct-label { grid-column: 1 / -1; font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbct-note { color: var(--vp-c-text-3); }
.kbct-text { margin: 0; padding: 0.4rem 0.6rem; border-radius: 6px; background: var(--vp-c-bg-alt); font-size: 0.82rem;
  white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--vp-font-family-base); max-height: 14rem; overflow-y: auto; }
.kbct-text.code { font-family: var(--vp-font-family-mono); font-size: 0.78rem; }
.kbct-done { display: flex; justify-content: flex-end; margin-top: 0.8rem; }
</style>
