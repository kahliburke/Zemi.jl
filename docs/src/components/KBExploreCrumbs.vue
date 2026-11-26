<script setup lang="ts">
// Where a subset map lies: back to all documents, through each subset it was opened from, to this one,
// with how many documents it has; for a search's subset, how many of its documents are mapped.
import type { SetInfo } from './kbExplore'

defineProps<{ set?: SetInfo }>()
const size = defineModel<number>('size', { required: true })
defineEmits<{ leave: []; map: [spec: string]; resize: [] }>()
</script>

<template>
  <nav class="kbx-crumbs" aria-label="Where on the map">
    <a href="#" @click.prevent="$emit('leave')">All documents</a><span aria-hidden="true">›</span>
    <template v-for="t in set?.trail ?? []" :key="t.spec">
      <a href="#" class="kbx-crumb-up" :title="t.name" @click.prevent="$emit('map', t.spec)">{{ t.name }}</a><span aria-hidden="true">›</span>
    </template>
    <span class="kbx-crumb" :title="set?.name">{{ set?.name ?? '…' }}</span>
    <span v-if="set" class="kbx-key-count">{{ set.count }}</span>
    <label v-if="set?.kind === 'q'" class="kbx-top" title="How many of the search's documents are mapped">
      top <input v-model.number="size" type="number" min="20" max="500" step="10" @change="$emit('resize')">
    </label>
  </nav>
</template>
