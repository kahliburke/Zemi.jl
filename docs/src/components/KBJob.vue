<!-- One background job: how it stands, when it started and finished and how long it took, what it is
  doing, and how it ended on request. -->
<script setup lang="ts">
import { ref } from 'vue'
import type { Job } from './kbApi'
import { clock, when } from './kbFormat'

withDefaults(defineProps<{ job: Job; named?: boolean }>(), { named: true })
const open = ref(false)
</script>

<template>
  <div class="kbjob">
    <span :class="['kbjob-status', job.status]">{{ job.status }}</span>
    <span v-if="named" class="kbjob-name">{{ job.name }}</span>
    <span class="kbjob-dim" :title="`Started ${when(job.started)}${job.finished ? `, finished ${when(job.finished)}` : ''}`">
      {{ job.finished ? `${clock(job.started)}–${clock(job.finished)}, ${job.elapsed}` : `since ${clock(job.started)}, ${job.elapsed}` }}</span>
    <span v-if="job.ids.length" class="kbjob-dim">{{ job.ids.length }} changed</span>
    <button v-if="job.result || job.error" type="button" class="kb-link" @click="open = !open">{{ open ? 'hide' : 'details' }}</button>
    <div v-if="job.status === 'running'" class="kbjob-dim kbjob-message">{{ job.message }}</div>
    <pre v-if="open" class="kbjob-detail">{{ job.error ?? job.result }}</pre>
  </div>
</template>

<style scoped>
.kbjob-status { display: inline-block; min-width: 5.5em; padding: 0 0.4rem; margin-right: 0.4rem; border-radius: 4px; font-size: 0.72rem;
  text-align: center; background: var(--vp-c-default-soft); }
.kbjob-status.running { background: var(--vp-c-yellow-soft); color: var(--vp-c-yellow-1); }
.kbjob-status.done { background: var(--vp-c-green-soft); color: var(--vp-c-green-1); }
.kbjob-status.failed { background: var(--vp-c-danger-soft); color: var(--vp-c-danger-1); }
.kbjob-name { margin-right: 0.4rem; }
.kbjob-dim { color: var(--vp-c-text-3); margin-right: 0.4rem; }
.kbjob-message { margin: 0.1rem 0 0 6.2em; }
.kbjob-detail { margin: 0.3rem 0 0; padding: 0.5rem; font-size: 0.78rem; white-space: pre-wrap; background: var(--vp-c-bg-soft); border-radius: 6px; }
</style>
