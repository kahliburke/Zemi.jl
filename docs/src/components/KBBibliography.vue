<!--
  The knowledge base as BibTeX, to download: what the person may see (records of their projects among
  it), from the service (`/api/bib`). Not on a static copy, which has no service to ask.
-->
<script setup lang="ts">
import { onMounted } from 'vue'
import { mode, api, connect } from './kbApi'

onMounted(connect)
</script>

<template>
  <a v-if="mode === 'live'" :href="`${api}/api/bib`" download="zemi.bib">Download BibTeX</a>
</template>
