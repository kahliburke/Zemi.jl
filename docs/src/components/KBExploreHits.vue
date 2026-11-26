<script setup lang="ts">
// What a search of the map found, before one is picked: its best matches, each with how strongly it
// matched, to go to; Enter goes to the first, Tab to the next.
import { KIND_COLOURS, kindName, type Node } from './kbExplore'

defineProps<{ query: string; hits: { node: Node; strength: number }[]; total: number; canMap: boolean }>()
defineEmits<{ go: [node: Node]; map: [] }>()
</script>

<template>
  <aside class="kbx-card kbx-hits" aria-label="Search results">
    <p class="kbx-meta">{{ total }} found for “{{ query }}”</p>
    <ul class="kbx-list">
      <li v-for="h in hits" :key="h.node.id">
        <i class="kbx-swatch" :style="{ background: KIND_COLOURS[h.node.kind] ?? '#999' }" :title="kindName(h.node.kind)"></i>
        <a href="#" :title="h.node.title" @click.prevent="$emit('go', h.node)">{{ h.node.title }}</a>
        <span class="kbx-aside"><span class="kbx-bar-track"><span class="kbx-bar-fill"
          :style="{ width: `${Math.max(4, Math.round(h.strength * 100))}%` }"></span></span></span>
      </li>
    </ul>
    <p class="kbx-hint">Enter goes to the first, Tab to the next.</p>
    <div v-if="canMap" class="kbx-actions">
      <button class="kbx-btn kbx-small" title="Lay out the documents this search finds as a map of their own" @click="$emit('map')">Map these</button>
    </div>
  </aside>
</template>
