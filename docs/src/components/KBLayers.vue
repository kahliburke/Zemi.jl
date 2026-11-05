<!--
  The embedding layers, as models and the kinds of text each embeds: chunks, sections, papers, and
  section or paper summaries. A cell is off, on, or a trial (kept for comparison: not built by a sync,
  searched only when chosen). Saving keeps each existing layer's name, and so its vectors; new layers
  are built from here, and vectors of layers no longer configured can be dropped.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { mode, connect, getJSON, post, can, followJobs } from './kbApi'
import { plainCopy as copy } from './kbUtils'

type LayerCell = { name?: string; kind: string; source?: string; trial: boolean; vectors?: number; papers?: number }
type Model = { model: string; url: string; key: string; query_prefix: string; doc_prefix: string; max_chars: number; layers: LayerCell[] }
type Kind = { kind: string; label: string; summary: boolean }
type Data = { models: Model[]; kinds: Kind[]; summarizers: string[]; summarizer: string; presets: Omit<Model, 'layers'>[];
              papers: number; orphans: { name: string; vectors: number }[] }

const data = ref<Data | null>(null)
const draft = ref<Model[]>([])
const error = ref('')
const note = ref('')
const adding = ref(false)
const preset = ref('')
const custom = ref({ model: '', url: '', key: '', query_prefix: '', doc_prefix: '', max_chars: 8000 })
const editable = computed(() => can('config.edit'))

async function load() {
  try { data.value = await getJSON('/api/config/layers'); draft.value = copy(data.value!.models) } catch (e: any) { error.value = e.message }
}
onMounted(async () => { await connect(); if (mode.value === 'live') await load() })

// The grid's columns: each kind of text, and the summary kinds once for each summarizer whose summaries
// are embedded (the configured one first, as "default"), and any added here.
type Column = { kind: string; source: string; label: string; key: string }
const extraSources = ref<string[]>([])
const sources = computed(() => ['default', ...new Set([...draft.value.flatMap(m => m.layers.map(l => l.source ?? '')),
  ...extraSources.value].filter(s => s && s !== 'default'))])
const columns = computed<Column[]>(() => (data.value?.kinds ?? []).flatMap(k => k.summary
  ? sources.value.map(s => ({ kind: k.kind, source: s, label: k.label + (s === 'default' ? '' : ` (${s})`), key: `${k.kind}|${s}` }))
  : [{ kind: k.kind, source: '', label: k.label, key: k.kind }]))
const otherSummarizers = computed(() => (data.value?.summarizers ?? []).filter(s => s !== data.value!.summarizer && !sources.value.includes(s)))
const addSource = ref('')

const cell = (m: Model, c: Column) => m.layers.find(l => l.kind === c.kind && (l.source ?? '') === c.source)
const state = (m: Model, c: Column) => { const l = cell(m, c); return !l ? 'off' : l.trial ? 'trial' : 'on' }
// A cell goes off → on → trial → off.
function cycle(m: Model, c: Column) {
  if (!editable.value) return
  const l = cell(m, c)
  if (!l) m.layers.push({ kind: c.kind, trial: false, ...(c.source ? { source: c.source } : {}) })
  else if (!l.trial) l.trial = true
  else m.layers = m.layers.filter(x => x !== l)
}
// Columns no active (non-trial) layer embeds.
const unbuilt = computed(() => new Set(columns.value.filter(c => !draft.value.some(m => m.layers.some(l =>
  l.kind === c.kind && (l.source ?? '') === c.source && !l.trial))).map(c => c.key)))
const dirty = computed(() => data.value !== null && JSON.stringify(strip(draft.value)) !== JSON.stringify(strip(data.value.models)))
const strip = (ms: Model[]) => ms.map(m => ({ ...m, layers: m.layers.map(l => ({ kind: l.kind, source: l.source ?? '', trial: l.trial })) }))

function addModel() {
  const p = preset.value === 'custom' ? custom.value : data.value!.presets.find(x => x.model === preset.value)
  if (!p || !p.model.trim()) return
  draft.value.push({ ...copy(p), layers: [] })
  adding.value = false; preset.value = ''
}
const removeModel = (m: Model) => draft.value = draft.value.filter(x => x !== m)

async function save() {
  error.value = ''; note.value = ''
  try {
    data.value = await post('/api/config/layers', JSON.stringify({ models: strip(draft.value) }))
    draft.value = copy(data.value!.models)
    note.value = 'Saved.'
  } catch (e: any) { error.value = e.message }
}
async function build(name: string) {
  try { const r = await post(`/api/config/layers/${name}/build`, '{}'); followJobs(r.job); note.value = `Building ${name}.` } catch (e: any) { error.value = e.message }
}
async function drop(name: string) {
  if (!confirm(`Drop the vectors of ${name}?`)) return
  try { data.value = await post(`/api/config/layers/${name}/drop`, '{}'); note.value = `Dropped ${name}.` } catch (e: any) { error.value = e.message }
}
const host = (m: Model) => m.url ? new URL(m.url).host : 'Ollama'
</script>

<template>
  <section v-if="mode === 'live' && can('config.view') && data" class="kbly">
    <h2>Embedding layers</h2>
    <p class="kbly-dim">Cells: off → on → trial · {{ data.papers }} papers read</p>
    <table class="kbly-table">
      <thead><tr><th>Model</th>
        <th v-for="c in columns" :key="c.key" :class="{ unbuilt: unbuilt.has(c.key) }"
            :title="unbuilt.has(c.key) ? 'No active layer' : ''">{{ c.label }}</th><th></th></tr></thead>
      <tbody>
        <tr v-for="(m, i) in draft" :key="i">
          <td><strong>{{ m.model }}</strong><div class="kbly-s">{{ host(m) }}</div></td>
          <td v-for="c in columns" :key="c.key" :class="['kbly-cell', state(m, c), { ro: !editable }]">
            <button type="button" class="kbly-state" :disabled="!editable" :aria-label="`${m.model}, ${c.label}: ${state(m, c)}`"
                    @click="cycle(m, c)">{{ state(m, c) === 'off' ? '' : state(m, c) }}</button>
            <template v-if="cell(m, c)?.name">
              <div class="kbly-s">{{ cell(m, c)!.vectors?.toLocaleString() }}</div>
              <button v-if="!cell(m, c)!.vectors && editable && !dirty" class="kb-link kbly-link" @click="build(cell(m, c)!.name!)">build</button>
            </template>
          </td>
          <td><button v-if="editable" class="kb-link kbly-link" title="Remove model" @click="removeModel(m)">✕</button></td>
        </tr>
      </tbody>
    </table>
    <div v-if="editable" class="kbly-actions">
      <template v-if="adding">
        <select v-model="preset">
          <option value="" disabled>Model…</option>
          <option v-for="p in data.presets" :key="p.model" :value="p.model">{{ p.model }}</option>
          <option value="custom">Custom…</option>
        </select>
        <template v-if="preset === 'custom'">
          <input v-model="custom.model" placeholder="Model" />
          <input v-model="custom.url" placeholder="API URL (empty = Ollama)" />
          <details><summary>details</summary>
            <input v-model="custom.key" placeholder="Key (env:NAME or file:PATH)" />
            <input v-model="custom.query_prefix" placeholder="Query prefix" />
            <input v-model="custom.doc_prefix" placeholder="Document prefix" />
            <label>Max chars <input v-model.number="custom.max_chars" type="number" min="500" /></label>
          </details>
        </template>
        <button class="kb-primary kbly-button" :disabled="!preset" @click="addModel">Add</button>
        <button class="kb-link kbly-link" @click="adding = false">cancel</button>
      </template>
      <button v-else class="kb-link kbly-link" @click="adding = true">+ model</button>
      <select v-if="otherSummarizers.length" v-model="addSource" @change="addSource && extraSources.push(addSource); addSource = ''">
        <option value="">+ summaries by…</option>
        <option v-for="s in otherSummarizers" :key="s" :value="s">{{ s }}</option>
      </select>
      <span class="kbly-spacer"></span>
      <button v-if="dirty" class="kb-link kbly-link" @click="draft = copy(data.models)">undo</button>
      <button class="kb-primary kbly-button" :disabled="!dirty" @click="save">Save layers</button>
    </div>
    <p v-if="note" class="kbly-note">{{ note }}</p>
    <p v-if="error" class="kb-error">{{ error }}</p>
    <template v-if="data.orphans.length">
      <h3>Unconfigured</h3>
      <p v-for="o in data.orphans" :key="o.name" class="kbly-s"><code>{{ o.name }}</code> · {{ o.vectors.toLocaleString() }} vectors
        <button v-if="editable" class="kb-link kbly-link" @click="drop(o.name)">drop</button></p>
    </template>
  </section>
</template>

<style scoped>
.kbly-dim, .kbly-s { color: var(--vp-c-text-2); }
.kbly-s { font-size: 0.75rem; }
.kbly-note { color: var(--vp-c-brand-1); }
.kbly-table { width: 100%; font-size: 0.85rem; display: block; overflow-x: auto; }
.kbly-table td:first-child { white-space: nowrap; }
.kbly-table th.unbuilt { color: var(--vp-c-warning-1); }
.kbly-table th.unbuilt::after { content: ' · none'; font-weight: 400; }
.kbly-cell { text-align: center; user-select: none; min-width: 6rem; }
.kbly-state { display: block; width: 100%; min-height: 1.5em; padding: 0; border: none; background: none; font: inherit; color: inherit; cursor: pointer; }
.kbly-state:disabled { cursor: default; }
.kbly-cell.off { color: var(--vp-c-text-3); }
.kbly-cell.on { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); font-weight: 600; }
.kbly-cell.trial { background: var(--vp-c-default-soft); color: var(--vp-c-text-2); font-style: italic; }
.kbly-actions { display: flex; flex-wrap: wrap; gap: 0.6rem; align-items: center; margin-top: 0.8rem; }
.kbly-actions input, .kbly-actions select { padding: 0.3rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.85rem; }
.kbly-spacer { flex: 1; }
.kbly-button { padding: 0.4rem 0.9rem; }
.kbly-button:disabled { opacity: 0.5; cursor: default; }
.kbly-link { font-size: 0.85rem; }
</style>
