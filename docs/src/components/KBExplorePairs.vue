<script setup lang="ts">
// Suggested links: pairs of documents near in meaning that nothing links yet, with the words they share,
// and what can be done with each (link them, set them aside, add one as a finding's evidence, cite it).
import { can } from './kbApi'
import { KIND_COLOURS, useSettings, type Node, type Pair } from './kbExplore'

defineProps<{ pairs: Pair[]; shared: Map<string, string[]>; hasSelection: boolean; ownFloor: number }>()
const emit = defineEmits<{ close: []; go: [node: Node]; goPair: [pair: Pair]; judge: [pair: Pair, related: boolean]
                           evidence: [finding: Node, doc: Node]; cite: [node: Node] }>()
const { scope, threshold } = useSettings()

const key = (p: Pair) => `${p.a.id},${p.b.id}`
const judgeable = (p: Pair) => can('paper.add') && ![p.a.kind, p.b.kind].some(k => k === 'finding' || k === 'task')
const evidence = (p: Pair) => (p.a.kind === 'finding' ? emit('evidence', p.a, p.b) : emit('evidence', p.b, p.a))
</script>

<template>
  <aside class="kbx-pairs">
    <button class="kbx-close" aria-label="Close" @click="$emit('close')">×</button>
    <h4>Suggested links</h4>
    <div class="kbx-seg kbx-seg-small kbx-scope" role="group" aria-label="Where">
      <button :class="{ on: scope === 'own' }" title="Your notes, records and findings, beside what they do not link to yet"
              @click="scope = 'own'">Yours</button>
      <button :class="{ on: scope === 'cluster' }" :disabled="!hasSelection" :title="hasSelection ? '' : 'Select a document first'"
              @click="scope = 'cluster'">This cluster</button>
      <button :class="{ on: scope === 'all' }" @click="scope = 'all'">Everywhere</button>
    </div>
    <p class="kbx-pairs-hint">{{ scope === 'own' ? `Your notes, records and findings, each beside the library documents nearest it that it does not link to, ${Math.round(ownFloor * 100)}% alike or more.` :
      `Documents close in meaning that nothing links, ${Math.round(threshold * 100)}% alike or more.` }}</p>
    <p v-if="!pairs.length" class="kbx-pairs-hint">None.</p>
    <ul class="kbx-list kbx-pair-list">
      <li v-for="p in pairs" :key="p.a.id + p.b.id">
        <div class="kbx-pair">
          <div class="kbx-pair-doc"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[p.a.kind] ?? '#999' }"></i>
            <a href="#" :title="p.a.title" @click.prevent="$emit('goPair', p)">{{ p.a.title }}</a></div>
          <div class="kbx-pair-doc"><i class="kbx-swatch" :style="{ background: KIND_COLOURS[p.b.kind] ?? '#999' }"></i>
            <a href="#" :title="p.b.title" @click.prevent="$emit('go', p.b)">{{ p.b.title }}</a></div>
          <p v-if="shared.get(key(p))?.length" class="kbx-pair-why">Shared: {{ shared.get(key(p))!.join(' · ') }}</p>
          <div class="kbx-pair-act">
            <a v-if="(p.a.kind === 'finding') !== (p.b.kind === 'finding') && can('tasks.edit')" href="#" @click.prevent="evidence(p)">Add as evidence</a>
            <template v-else-if="judgeable(p)">
              <a href="#" title="Link the two as related: a line on the map, and in both cards" @click.prevent="$emit('judge', p, true)">Link</a>
              <a href="#" title="Stop suggesting this pair" @click.prevent="$emit('judge', p, false)">Not related</a>
            </template>
            <a v-if="(p.a.kind === 'record' && p.b.kind === 'paper') || (p.b.kind === 'record' && p.a.kind === 'paper')" href="#"
               @click.prevent="$emit('cite', p.a.kind === 'paper' ? p.a : p.b)">Copy the citation</a>
          </div>
        </div>
        <span class="kbx-aside"><span class="kbx-bar-track"><span class="kbx-bar-fill"
          :style="{ width: `${Math.max(4, Math.round(p.similarity * 100))}%` }"></span></span>{{ Math.round(p.similarity * 100) }}%</span>
      </li>
    </ul>
  </aside>
</template>
