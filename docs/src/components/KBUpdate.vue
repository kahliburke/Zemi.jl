<!--
  The site's state in the top bar: while a new build is being made, that it is (pages stay as they are
  meanwhile), and once the service has switched to it, an offer to reload rather than reloading under
  the reader.
-->
<script setup lang="ts">
import { ref, computed } from 'vue'
import { status, refreshStatus, onLive, every } from './kbApi'

const loaded = ref('')
const building = computed(() => status.value?.building ?? null)       // seconds the build has run, while one does
const newer = computed(() => !!loaded.value && !!status.value?.build && status.value.build !== loaded.value)

// The status asked again, more often while a build runs, so its end shows soon after.
onLive(() => {
  loaded.value = status.value?.build ?? ''
  return every(() => building.value !== null ? 5000 : 20000, refreshStatus)
})
const reload = () => location.reload()
const minutes = (s: number) => s < 60 ? 'just started' : `${Math.floor(s / 60)} min`
</script>

<template>
  <button v-if="newer" type="button" class="kbu-chip kbu-new" title="Reload for the new build" @click="reload">Site updated · reload</button>
  <span v-else-if="building !== null" class="kbu-chip kbu-building" role="status"
        title="Offers a reload once the new build is ready">
    <span class="kbu-spin" aria-hidden="true"></span>Rebuilding the site · {{ minutes(building) }}</span>
</template>

<style scoped>
.kbu-chip { display: inline-flex; align-items: center; gap: 0.4rem; margin-left: 0.6rem; padding: 0.15rem 0.7rem; border-radius: 12px;
  font-size: 0.8rem; white-space: nowrap; }
.kbu-new { border: 1px solid var(--vp-c-brand-1); background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); cursor: pointer; }
.kbu-building { border: 1px solid var(--vp-c-divider); color: var(--vp-c-text-2); }
.kbu-spin { width: 10px; height: 10px; border-radius: 50%; border: 2px solid var(--vp-c-divider); border-top-color: var(--vp-c-brand-1);
  animation: kbu-spin 0.9s linear infinite; }
@keyframes kbu-spin { to { transform: rotate(360deg); } }
@media (max-width: 960px) { .kbu-building { font-size: 0; gap: 0; padding: 0.3rem; } }
</style>
