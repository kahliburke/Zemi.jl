<!-- Recent background jobs in the knowledge base: what each is doing, and how it ended. -->
<script setup lang="ts">
import { jobs } from './kbApi'
import KBJob from './KBJob.vue'
</script>

<template>
  <div v-if="jobs.length" class="kbj">
    <div class="kbj-head">Jobs</div>
    <KBJob v-for="j in jobs" :key="j.id" :job="j" class="kbj-job" />
  </div>
</template>

<style scoped>
.kbj { margin: 1rem 0; padding: 0.6rem 0.8rem; border: 1px solid var(--vp-c-divider); border-radius: 8px; font-size: 0.85rem; }
.kbj-head { font-weight: 600; margin-bottom: 0.3rem; }
.kbj-job { padding: 0.3rem 0; border-top: 1px solid var(--vp-c-divider); }
</style>
