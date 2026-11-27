<script setup lang="ts">
// The explore page's panel: the legend (what the colours stand for, a row to go to or to map by itself)
// and the settings (layout, a project's library to map, the links and documents drawn, unlinked pairs).
// The settings are the page's (see `useExploreSettings`), taken up here.
import { computed } from 'vue'
import { can } from './kbApi'
import KBIcon from './KBIcon.vue'
import { COLOUR_BY, RAMP_CSS, SCALES, KIND_COLOURS, LINK_COLOURS, LINK_KINDS, NODE_KINDS, SHADE_BY, all, toggle, useSettings,
         type LegendRow } from './kbExplore'

const props = defineProps<{ legend: LegendRow[]; litRow: string | null; hereRow: string | null; subset: string; projects: { key: string; name: string }[] | null
                            layouts: { umap: boolean; pacmap: boolean }; flying: boolean; least: number }>()
const emit = defineEmits<{ goToRow: [key: string]; map: [spec: string] }>()
const { panel, colourBy, shadeBy, layout, shownLinks, shownKinds, showUnlinked, threshold, view } = useSettings()
const scale = computed(() => SCALES[colourBy.value])
const alt = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform) ? '⌥' : 'Alt'
// A cluster with too few documents for a map of its own: its lens is greyed, and its tip says why.
const few = (r: LegendRow) => (r.size ?? r.count) < props.least
const mapTip = (r: LegendRow) => few(r)
  ? `Too few to map by itself: ${r.size ?? r.count} documents, and a map of its own needs at least ${props.least}`
  : `Map ${r.label} by itself, into its subtopics`
function mapRow(r: LegendRow) {
  if (!few(r)) emit('map', 'cluster:' + r.key.slice(1) + (props.subset ? '@' + props.subset : ''))
}
</script>

<template>
  <section id="kbx-panel" class="kbx-panel" :class="{ wide: panel === 'show' }" aria-label="The map's legend and settings">
    <div class="kbx-panel-head">
      <div class="kbx-seg kbx-seg-small" role="tablist" aria-label="Panel">
        <button role="tab" :aria-selected="panel === 'colours'" :class="{ on: panel === 'colours' }" @click="panel = 'colours'">Legend</button>
        <button role="tab" :aria-selected="panel === 'show'" :class="{ on: panel === 'show' }" @click="panel = 'show'">Settings</button>
      </div>
    </div>
    <div v-if="panel === 'colours'" class="kbx-key" role="tabpanel">
      <div class="kbx-shade">
        <span>Colour by</span>
        <select v-model="colourBy" class="kb-field kbx-pick kbx-colour-by" aria-label="Colour by">
          <option v-for="[k, l] in COLOUR_BY" :key="k" :value="k">{{ l }}</option>
        </select>
      </div>
      <div v-if="scale" class="kbx-scale">
        <div class="kbx-scale-bar" :style="{ background: RAMP_CSS }"></div>
        <div class="kbx-scale-ends"><span>{{ scale.low }}</span><span>{{ scale.high }}</span></div>
        <p class="kbx-hint">{{ scale.about }} Coloured by rank; grey has no value.</p>
      </div>
      <div v-if="litRow" class="kbx-shade">
        <span>Shade by</span>
        <div class="kbx-seg kbx-seg-small" role="group" aria-label="Shade by">
          <button v-for="[k, l, t] in SHADE_BY" :key="k" :class="{ on: shadeBy === k }" :title="t" @click="shadeBy = k">{{ l }}</button>
        </div>
      </div>
      <ul>
        <li v-for="r in legend" :key="r.key"><button :class="{ on: litRow === r.key, here: hereRow === r.key }" :title="`Go to ${r.label}`" @click="$emit('goToRow', r.key)">
          <i class="kbx-swatch" :style="{ background: r.colour }"></i>
          <span class="kbx-key-label">{{ r.label }}</span><span class="kbx-key-count">{{ r.count }}</span></button>
          <button v-if="r.key[0] === 'c'" class="kbx-map-row" :class="{ few: few(r) }" :data-tip="mapTip(r)"
                  :aria-label="`Map ${r.label} by itself`" :aria-disabled="few(r) || undefined" :aria-description="few(r) ? mapTip(r) : undefined"
                  @click="mapRow(r)"><KBIcon name="zoom_in" :size="15" /></button></li>
      </ul>
    </div>
    <div v-if="panel === 'show'" role="tabpanel">
      <div class="kbx-grid">
        <template v-if="layouts.umap">
          <span class="kbx-label">Layout</span>
          <div class="kbx-seg kbx-seg-small kbx-wide" role="group" aria-label="Layout">
            <button :class="{ on: layout === 'tsne' }" title="Keeps each document's close neighbourhood" @click="layout = 'tsne'">t-SNE</button>
            <button :class="{ on: layout === 'umap' }" title="Keeps more of how the groups lie to each other" @click="layout = 'umap'">UMAP</button>
            <button v-if="layouts.pacmap" :class="{ on: layout === 'pacmap' }"
                    title="Keeps the neighbourhoods and how the groups lie to each other, the most evenly" @click="layout = 'pacmap'">PaCMAP</button>
          </div>
        </template>
        <template v-if="can('tasks.view') && projects?.length">
          <span class="kbx-label">Map</span>
          <select class="kb-field kbx-wide kbx-pick" aria-label="Map a project's library by itself"
                  @change="e => { const k = (e.target as HTMLSelectElement).value; if (k) $emit('map', 'project:' + k) }">
            <option value="">A project's library…</option>
            <option v-for="p in projects" :key="p.key" :value="p.key">{{ p.name }} ({{ p.key }})</option>
          </select>
        </template>
        <span class="kbx-label">Links</span>
        <button class="kbx-all" @click="all(shownLinks, LINK_KINDS)">{{ shownLinks.length === LINK_KINDS.length ? 'None' : 'All' }}</button>
        <div class="kbx-chips">
          <button v-for="[k, l] in LINK_KINDS" :key="k" class="kbx-chip" :class="{ on: shownLinks.includes(k) }" :aria-pressed="shownLinks.includes(k)"
                  @click="toggle(shownLinks, k)"><i class="kbx-swatch" :style="{ background: LINK_COLOURS[k] }"></i>{{ l }}</button>
        </div>
        <span class="kbx-label">Documents</span>
        <button class="kbx-all" @click="all(shownKinds, NODE_KINDS)">{{ shownKinds.length === NODE_KINDS.length ? 'None' : 'All' }}</button>
        <div class="kbx-chips">
          <button v-for="[k, l] in NODE_KINDS" :key="k" class="kbx-chip" :class="{ on: shownKinds.includes(k) }" :aria-pressed="shownKinds.includes(k)"
                  @click="toggle(shownKinds, k)"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[k] }"></i>{{ l }}</button>
        </div>
        <span class="kbx-label">Unlinked pairs</span>
        <div class="kbx-pairs-row kbx-wide">
          <button class="kbx-chip" :class="{ on: showUnlinked }" :aria-pressed="showUnlinked" title="Draw the pairs close in meaning that no link joins"
                  @click="showUnlinked = !showUnlinked">{{ showUnlinked ? 'Shown' : 'Hidden' }}</button>
          <input v-model.number="threshold" type="range" min="0.5" max="0.98" step="0.01" :disabled="!showUnlinked" aria-label="How alike">
          <span class="kbx-value">≥ {{ Math.round(threshold * 100) }}%</span>
        </div>
      </div>
      <p class="kbx-hint">Hold {{ alt }} over a document to see its links and nearest where you are; {{ alt }}-click chooses it without moving.</p>
      <p v-if="view === '3d'" class="kbx-hint">Drag to turn, scroll to come closer. F flies: WASD to move, the mouse to steer.{{ flying ? ' Flying: F to stop.' : '' }}</p>
    </div>
  </section>
</template>
