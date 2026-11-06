<!--
  What this machine cannot do, and why, from the API's status (`cannot`, each action's reasons for
  each kind of document): each reason once, with the actions it stops. Nothing is shown when all can run.
-->
<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { mode, status, connect } from './kbApi'

onMounted(connect)
const problems = computed(() => {
  const by = new Map<string, Set<string>>()
  for (const [action, kinds] of Object.entries(status.value?.cannot ?? {}))
    for (const reasons of Object.values(kinds))
      for (const r of reasons) by.set(r, (by.get(r) ?? new Set()).add(action))
  return [...by.entries()].map(([reason, actions]) => ({ reason, actions: [...actions].sort() }))
})
</script>

<template>
  <template v-if="mode === 'live'">
    <p v-if="!problems.length" class="kb-dim">Every service this knowledge base uses is reachable.</p>
    <ul v-else class="kbsv">
      <li v-for="p in problems" :key="p.reason">{{ p.reason }} <span class="kb-dim">(stops {{ p.actions.join(', ') }})</span></li>
    </ul>
  </template>
</template>

<style scoped>
.kbsv { padding-left: 1.1rem; }
</style>
