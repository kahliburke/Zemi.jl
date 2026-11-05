<!--
  The top bar's settings button: which rankings the knowledge base search uses, each with what it
  embeds, the model, and how much it holds; the tutoring profile; and how papers' figures are shown.
  The choices are kept in this browser.
-->
<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { mode, status, connect } from './kbApi'
import { current, customised, toggleLayer, toggleKeyword, reset } from './kbSearchPrefs'
import { QUESTIONS, profile, optedOut, loadProfile, clearProfile, optOut } from './kbProfile'
import KBProfileSurvey from './KBProfileSurvey.vue'
import KBDialog from './KBDialog.vue'
import { originalFigures, loadDisplay, setOriginalFigures } from './kbDisplay'
import { day } from './kbFormat'

const open = ref(false)
// The rankings' descriptions and figures, shown on request: one line each otherwise.
const details = ref(false)
const root = ref<HTMLElement | null>(null)
const onDocClick = (e: MouseEvent) => { if (open.value && root.value && !root.value.contains(e.target as Node)) open.value = false }
const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') open.value = false }
onMounted(() => { connect(); loadProfile(); loadDisplay(); document.addEventListener('click', onDocClick); document.addEventListener('keydown', onKey) })
onBeforeUnmount(() => { document.removeEventListener('click', onDocClick); document.removeEventListener('keydown', onKey) })

const n = (x: number) => x.toLocaleString()
const onFigures = (e: Event) => setOriginalFigures((e.target as HTMLInputElement).checked)
// The tutoring profile: retaken here in a dialog (the tutor's drawer shows it in its own place).
const retaking = ref(false)
const answered = () => QUESTIONS.value.filter(q => (profile.value?.answers[q.id] ?? []).length || (profile.value?.notes[q.id] ?? '').trim())
</script>

<template>
  <div ref="root" class="kbs">
    <button class="kbs-button" :aria-expanded="open" title="Settings" @click="open = !open">
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
        <path fill="currentColor" d="M19.4 13a7.7 7.7 0 0 0 0-2l2.1-1.6-2-3.5-2.5 1a7.6 7.6 0 0 0-1.7-1L15 3.3h-4l-.4 2.6a7.6 7.6 0 0 0-1.7 1l-2.5-1-2 3.5L6.6 11a7.7 7.7 0 0 0 0 2l-2.2 1.6 2 3.5 2.5-1c.5.4 1.1.7 1.7 1l.4 2.6h4l.4-2.6c.6-.3 1.2-.6 1.7-1l2.5 1 2-3.5L19.4 13ZM13 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z" transform="translate(-1 0)"/>
      </svg>
    </button>
    <div v-if="open" class="kbs-panel">
      <section class="kbs-section">
        <div class="kbs-head">
          <span class="kbs-label">Search</span>
          <span class="kbs-tools">
            <button v-if="mode === 'live' && status" type="button" class="kb-link" @click="details = !details">{{ details ? 'hide details' : 'details' }}</button>
            <button v-if="customised" type="button" class="kb-link" @click="reset">reset</button>
          </span>
        </div>
        <p v-if="mode === 'checking'" class="kb-dim kbs-dim">Connecting…</p>
        <template v-else-if="mode === 'static'">
          <p class="kb-dim kbs-dim">Offline: keyword search only.
            <button type="button" class="kb-link" @click="connect(true)">retry</button></p>
        </template>
        <template v-else-if="status">
          <p class="kb-dim kbs-dim">{{ n(status.processed) }} of {{ n(status.papers) }} papers in full text.</p>
          <ul class="kbs-list">
            <li>
              <label class="kbs-row" :title="status.keyword.description">
                <input type="checkbox" :checked="current.keyword" @change="toggleKeyword" />
                <span class="kbs-name">Keyword</span>
                <span class="kbs-tag"><span v-if="status.keyword.default" class="kbs-chip">default</span></span>
                <span class="kbs-count">{{ n(status.passages) }}</span>
              </label>
              <p v-if="details" class="kbs-desc">{{ status.keyword.description }} {{ n(status.passages) }} passages.</p>
            </li>
            <li v-for="l in status.layers" :key="l.name" :class="{ empty: !l.vectors }">
              <label class="kbs-row" :title="l.description">
                <input type="checkbox" :checked="current.layers.includes(l.name)" :disabled="!l.vectors" @change="toggleLayer(l.name)" />
                <span class="kbs-name">{{ l.label }}</span>
                <span class="kbs-tag"><span v-if="l.default" class="kbs-chip">default</span></span>
                <span class="kbs-count">{{ n(l.vectors) }}</span>
              </label>
              <p v-if="details" class="kbs-desc">{{ l.description }}
                <span class="kbs-stats">{{ n(l.vectors) }} vectors · {{ n(l.papers) }} papers<template v-if="l.dim"> · {{ n(l.dim) }} dims</template> · <code>{{ l.name }}</code></span></p>
            </li>
          </ul>
        </template>
      </section>
      <section class="kbs-section">
        <div class="kbs-head"><span class="kbs-label">Figures</span></div>
        <label class="kbs-row kbs-plain">
          <input type="checkbox" :checked="originalFigures" @change="onFigures" />
          <span class="kbs-name">Always show originals</span>
        </label>
      </section>
      <section class="kbs-section">
        <div class="kbs-head"><span class="kbs-label">Tutoring</span></div>
        <p class="kb-dim kbs-dim" v-if="profile">
          Profile: {{ answered().length }}/{{ QUESTIONS.length }} answered, {{ day(profile.updated) }}. Stored in this browser, sent anonymously.
        </p>
        <p class="kb-dim kbs-dim" v-else-if="optedOut">No profile (declined).</p>
        <p class="kb-dim kbs-dim" v-else>No profile yet.</p>
        <div class="kbs-actions">
          <button type="button" class="kb-link" @click="retaking = true; open = false">{{ profile ? 'Retake survey' : 'Take survey' }}</button>
          <button v-if="profile" type="button" class="kb-link" @click="clearProfile">Clear</button>
          <button v-if="!optedOut" type="button" class="kb-link" @click="optOut">No profile</button>
        </div>
      </section>
      <p class="kbs-foot">Kept in this browser.</p>
    </div>
    <KBDialog v-if="retaking" width="min(44rem, 94vw)" :shade="0.5" @close="retaking = false">
      <KBProfileSurvey @done="retaking = false" />
    </KBDialog>
  </div>
</template>

<style scoped>
.kbs { position: relative; display: flex; align-items: center; margin-left: 0.5rem; }
.kbs-button { display: flex; align-items: center; justify-content: center; width: 36px; height: 36px; border-radius: 8px;
  color: var(--vp-c-text-2); background: transparent; border: none; cursor: pointer; }
.kbs-button:hover, .kbs-button[aria-expanded="true"] { color: var(--vp-c-text-1); background: var(--vp-c-default-soft); }
/* The nav bar keeps its text on one line; the panel's wraps. */
.kbs-panel { position: absolute; top: 44px; right: 0; width: min(420px, 92vw); max-height: min(80vh, 44rem); overflow-y: auto;
  z-index: 100; padding: 0.35rem 0; border: 1px solid var(--vp-c-divider); border-radius: 12px; background: var(--vp-c-bg-elv);
  box-shadow: var(--vp-shadow-3); font-size: 0.82rem; line-height: 1.45; white-space: normal; text-align: left; }
.kbs-section { padding: 0.6rem 1rem 0.7rem; }
.kbs-section + .kbs-section { border-top: 1px solid var(--vp-c-divider); }
.kbs-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 0.3rem; }
.kbs-label { font-size: 0.7rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--vp-c-text-2); }
.kbs-tools { display: flex; gap: 0.8rem; font-size: 0.78rem; }
.kbs-dim { margin: 0 0 0.4rem; }
.kbs-list { list-style: none; margin: 0; padding: 0; }
.kbs-list li { padding: 0.12rem 0; }
.kbs-list li.empty { opacity: 0.45; }
.kbs-row { display: flex; align-items: center; gap: 0.55rem; padding: 0.22rem 0.4rem; margin: 0 -0.4rem; border-radius: 6px;
  cursor: pointer; color: var(--vp-c-text-1); }
.kbs-row:hover { background: var(--vp-c-default-soft); }
.kbs-row input { margin: 0; flex: none; accent-color: var(--vp-c-brand-1); }
.kbs-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* The default chip and the count in columns of their own, so they line up row to row. */
.kbs-tag { flex: none; width: 3.6rem; display: flex; justify-content: flex-end; }
.kbs-count { flex: none; min-width: 3.4rem; text-align: right; color: var(--vp-c-text-3); font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.kbs-chip { flex: none; padding: 0 0.4rem; border-radius: 4px; font-size: 0.68rem; font-weight: 500; line-height: 1.5;
  background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbs-desc { margin: 0.05rem 0 0.35rem 1.4rem; color: var(--vp-c-text-2); font-size: 0.78rem; }
.kbs-stats { display: block; color: var(--vp-c-text-3); font-size: 0.72rem; margin-top: 0.1rem; }
.kbs-stats code { font-size: 0.7rem; }
.kbs-actions { display: flex; gap: 1rem; flex-wrap: wrap; }
.kbs-foot { margin: 0; padding: 0.4rem 1rem 0.3rem; border-top: 1px solid var(--vp-c-divider); color: var(--vp-c-text-3); font-size: 0.72rem; }
</style>
