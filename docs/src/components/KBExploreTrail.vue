<script setup lang="ts">
// The documents a drift passed through, in order, with how alike each was to the one before: to go back
// to one, copy them as text, or map them by themselves.
import type { Step, Node } from './kbExplore'

defineProps<{ steps: Step[]; here?: string; canMap: boolean }>()
defineEmits<{ clear: []; go: [node: Node]; copy: []; map: [] }>()
</script>

<template>
  <aside class="kbx-trail">
    <button class="kbx-close" aria-label="Clear the trail" title="Clear the trail" @click="$emit('clear')">×</button>
    <h4>Drift trail</h4>
    <ol>
      <li v-for="(t, i) in steps" :key="t.node.id" :class="{ here: t.node.id === here }">
        <a href="#" :title="t.node.title" @click.prevent="$emit('go', t.node)">{{ t.node.title }}</a>
        <span v-if="i" class="kbx-key-count">{{ Math.round((t.similarity ?? 0) * 100) }}%</span>
      </li>
    </ol>
    <div class="kbx-actions">
      <button class="kbx-btn kbx-small" @click="$emit('copy')">Copy as text</button>
      <button v-if="canMap" class="kbx-btn kbx-small" title="Lay out the drift's documents and their nearest as a map of their own"
              @click="$emit('map')">Map this drift</button>
    </div>
  </aside>
</template>
