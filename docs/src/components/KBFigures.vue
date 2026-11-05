<!--
  A paper's figures and tables, cut from its PDF when it was read, while zemi serves the knowledge
  base API: a collapsible gallery under the page's "Figures and tables" heading, closed until opened
  or reached from the page's contents, of thumbnails in the paper's order, each opening large with
  its caption, with previous and next (arrow keys) and Escape. The service sends each image as it is
  looked at, in the reader's theme (or as the paper drew it, with that setting), so the site's build
  carries none of them. `figures` and `tables` are how many there are; `discussed` names the files an
  analysis discusses, which are marked.

  It also makes the page's mentions of them ("Fig. 3", "Figs. 2 and 4", "Table II"), in its analysis
  and summaries, into links: a preview on hover or focus, the large view on a click.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { useData } from 'vitepress'
import { api, mode, connect, getJSON } from './kbApi'
import { originalFigures } from './kbDisplay'
import { MENTION, numeral, figureKey, mentionPieces } from './kbFigureMentions'
import { plural } from './kbFormat'
import KBDialog from './KBDialog.vue'

const props = defineProps<{ id: string; figures?: number; tables?: number; discussed?: string }>()
type Figure = { kind: string; label: string; caption: string; file: string; src: string }
const figures = ref<Figure[]>([])
const at = ref(-1)
const current = computed(() => (at.value >= 0 ? figures.value[at.value] : null))
const picked = computed(() => new Set((props.discussed ?? '').split(' ').filter(Boolean)))
const { isDark } = useData()
const shown = ref(false)
const what = computed(() => [props.figures ? plural(props.figures, 'figure') : '', props.tables ? plural(props.tables, 'table') : '']
  .filter(Boolean).join(' and '))

const src = (f: Figure) => `${api.value}${f.src}${originalFigures.value ? '' : `?theme=${isDark.value ? 'dark' : 'light'}`}`
const close = () => { at.value = -1 }
const step = (d: number) => { const n = figures.value.length; at.value = (at.value + d + n) % n }
// Arrow keys step through the figures while one is open large (Escape closes it, see KBDialog).
function key(e: KeyboardEvent) {
  if (at.value < 0) return
  if (e.key === 'ArrowRight') step(1)
  else if (e.key === 'ArrowLeft') step(-1)
}

// Opened from the page's contents: its heading is what the link leads to.
const anchor = ref<HTMLElement | null>(null)
function heading(): Element | null {
  // The nearest heading before the gallery, at its own level or its wrapper's.
  for (let at: Element | null | undefined = anchor.value; at && !at.classList.contains('vp-doc'); at = at.parentElement) {
    for (let el = at.previousElementSibling; el; el = el.previousElementSibling)
      if (/^H[1-6]$/.test(el.tagName)) return el
  }
  return null
}
function fromContents() {
  const h = heading()
  if (h && location.hash && h.id === decodeURIComponent(location.hash.slice(1))) open()
}
async function load() {
  if (figures.value.length) return
  await connect()
  if (mode.value !== 'live') return
  try { figures.value = await getJSON(`/api/figures?id=${encodeURIComponent(props.id)}`) }
  catch { /* no figures shown */ }
}
function open() { shown.value = true; load() }
function toggled(e: Event) { (e.target as HTMLDetailsElement).open ? open() : (shown.value = false) }

// ── Mentions in the page's text (see kbFigureMentions.ts) ──────────────────────────────────────
// Where a figure is in the list, by its key.
const index = computed(() => new Map(figures.value.map((f, i) => [figureKey(f.kind, numeral(f.label.split(/\s+/).pop() ?? '')), i])))
// Text that is not discussion: headings, code, links, the gallery and the paper's full text.
const SKIP = 'h1,h2,h3,h4,h5,h6,a,code,pre,button,.kbf,.kbfig,.kbst,.kb-paper-head,.kbfig-overlay,.kbfig-preview'
function linkMentions() {
  const doc = anchor.value?.closest('.vp-doc')
  if (!doc || !figures.value.length) return
  const walker = document.createTreeWalker(doc, NodeFilter.SHOW_TEXT)
  const nodes: Text[] = []
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n as Text
    MENTION.lastIndex = 0
    if (MENTION.test(t.data) && !t.parentElement?.closest(SKIP)) nodes.push(t)
  }
  for (const t of nodes) {
    const pieces = mentionPieces(t.data, key => index.value.has(key))
    if (pieces.some(p => p.key))
      t.replaceWith(...pieces.map(p => (p.key ? mentionLink(p.text, index.value.get(p.key)!) : p.text)))
  }
}
// A button that reads as a link: a link to "#" is the router's to follow, to the top of the page.
function mentionLink(text: string, i: number): HTMLElement {
  const a = document.createElement('button')
  a.type = 'button'
  a.className = 'kbfig-mention'
  a.textContent = text
  a.addEventListener('click', () => { hidePreview(); at.value = i })
  a.addEventListener('mouseenter', () => showPreview(a, i))
  a.addEventListener('focus', () => showPreview(a, i))
  a.addEventListener('mouseleave', hidePreview)
  a.addEventListener('blur', hidePreview)
  return a
}
const preview = ref<{ i: number; x: number; y: number } | null>(null)
const previewed = computed(() => (preview.value ? figures.value[preview.value.i] : null))
function showPreview(a: HTMLElement, i: number) {
  const r = a.getBoundingClientRect()
  // Below the mention, or above it near the bottom of the window; kept within the window's width.
  const below = r.bottom + 330 < window.innerHeight
  preview.value = { i, x: Math.min(Math.max(8, r.left), window.innerWidth - 428), y: below ? r.bottom + 6 : r.top - 6 }
  previewBelow.value = below
}
const previewBelow = ref(true)
function hidePreview() { preview.value = null }

onMounted(async () => {
  window.addEventListener('keydown', key)
  window.addEventListener('hashchange', fromContents)
  fromContents()
  await load()
  linkMentions()
})
onBeforeUnmount(() => { window.removeEventListener('keydown', key); window.removeEventListener('hashchange', fromContents) })
</script>

<template>
  <details ref="anchor" class="details custom-block kbfig" :open="shown" @toggle="toggled">
    <summary>{{ what || 'Figures' }}</summary>
    <p v-if="shown && mode !== 'live'" class="kb-dim kbfig-dim">Needs a running Zemi server.</p>
    <div v-if="shown && figures.length" class="kbfig-grid">
      <button v-for="(f, i) in figures" :key="f.file" type="button" class="kbfig-item" :class="{ 'kbfig-pick': picked.has(f.file) }"
              @click="at = i">
        <span class="kbfig-thumb"><img :src="src(f)" :alt="f.label" loading="lazy"></span>
        <span class="kbfig-label">{{ f.label }}<template v-if="picked.has(f.file)"> · discussed</template></span>
      </button>
    </div>
    <ClientOnly>
      <Teleport to="body">
        <div v-if="previewed && preview" class="kbfig-preview" :class="{ 'kbfig-preview-above': !previewBelow }"
             :style="{ left: preview.x + 'px', top: preview.y + 'px' }">
          <img :src="src(previewed)" :alt="previewed.label">
          <p>{{ (previewed.caption || previewed.label).split(/(?<=\.)\s/)[0] }}</p>
        </div>
      </Teleport>
    </ClientOnly>
    <KBDialog v-if="current" :label="current.label" width="auto" bare :shade="0.75" @close="close">
      <div class="kbfig-frame">
        <img class="kbfig-large" :src="src(current)" :alt="current.label">
        <p class="kbfig-caption">{{ current.caption || current.label }}</p>
        <div class="kbfig-nav">
          <button type="button" @click="step(-1)">← Previous</button>
          <span>{{ at + 1 }} of {{ figures.length }}</span>
          <button type="button" @click="step(1)">Next →</button>
          <button type="button" class="kbfig-close" @click="close">Close</button>
        </div>
      </div>
    </KBDialog>
  </details>
</template>

<style scoped>
.kbfig-dim { font-size: 0.9rem; }
.kbfig-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 0.8rem; margin: 1rem 0; }
.kbfig-item { padding: 0.4rem; cursor: zoom-in; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg-soft);
  display: flex; flex-direction: column; gap: 0.35rem; font: inherit; color: inherit; }
.kbfig-item:hover, .kbfig-item:focus-visible { border-color: var(--vp-c-brand-1); outline: none; }
.kbfig-pick { border-color: var(--vp-c-brand-2); }
.kbfig-thumb { display: flex; align-items: center; justify-content: center; height: 140px; overflow: hidden; }
.kbfig-thumb img { max-height: 140px; max-width: 100%; width: auto; height: auto; }
.kbfig-label { font-size: 0.8rem; line-height: 1.3; color: var(--vp-c-text-2); text-align: center; }
.kbfig-frame { background: var(--vp-c-bg); color: var(--vp-c-text-1); border-radius: 10px; padding: 1rem 1.2rem;
  max-width: 96vw; max-height: 94vh; overflow: auto; display: flex; flex-direction: column; gap: 0.6rem; }
.kbfig-large { align-self: center; max-width: min(92vw, 1400px); max-height: 72vh; width: auto; height: auto; }
.kbfig-caption { margin: 0; font-size: 0.9rem; line-height: 1.45; max-width: 90ch; }
.kbfig-nav { display: flex; gap: 0.8rem; align-items: center; font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbfig-nav button { padding: 0.2rem 0.7rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: none;
  color: var(--vp-c-text-1); font: inherit; cursor: pointer; }
.kbfig-nav button:hover { border-color: var(--vp-c-brand-1); }
.kbfig-close { margin-left: auto; }
.kbfig-preview { position: fixed; z-index: 150; width: 420px; max-width: calc(100vw - 16px); background: var(--vp-c-bg);
  border: 1px solid var(--vp-c-divider); border-radius: 8px; box-shadow: var(--vp-shadow-3); padding: 0.5rem; pointer-events: none; }
.kbfig-preview-above { transform: translateY(-100%); }
.kbfig-preview img { display: block; max-width: 100%; max-height: 300px; margin: 0 auto; }
.kbfig-preview p { margin: 0.4rem 0 0; font-size: 0.8rem; line-height: 1.35; color: var(--vp-c-text-2); }
</style>

<style>
/* The mentions are made in the page's own text, outside this component's scoped styles. */
.vp-doc button.kbfig-mention { display: inline; padding: 0; border: 0; background: none; font: inherit; color: var(--vp-c-brand-1);
  text-decoration: underline dotted; text-underline-offset: 3px; cursor: zoom-in; }
.vp-doc button.kbfig-mention:hover { color: var(--vp-c-brand-2); }
</style>
