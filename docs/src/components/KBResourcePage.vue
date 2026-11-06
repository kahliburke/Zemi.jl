<!--
  A resource's page, made from its data (see kbTemplates.ts and `resource_json`): a data set, portal,
  law or work the group uses without reading it in full. Its type, who made it and when, its note,
  where it is, where it came from, and the libraries that keep it.
-->
<script setup lang="ts">
import { useTemplatedPage } from './kbTemplates'
import KBInLibraries from './KBInLibraries.vue'

type Resource = { id: string; slug: string; title: string; type: string; authors: string[]; date: string; note: string
                  url: string; doi: string; source: string }

const { data: r, error } = useTemplatedPage<Resource>('resources', 'No such resource.', { title: x => x.title })
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!r" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="resource-title">{{ r.title }}</h1>
    <div class="kb-paper-head">
      <div class="kb-badges">
        <span class="kb-badge kb-badge-cat">{{ (r.type || 'resource').replace(/^./, c => c.toUpperCase()) }}</span>
        <span v-if="r.date" class="kb-badge">{{ r.date }}</span>
      </div>
      <p v-if="r.authors.length" class="kb-authors">{{ r.authors.join(', ') }}</p>
    </div>
    <p v-if="r.note">{{ r.note }}</p>
    <p class="kbrs-where">
      <a v-if="r.url" :href="r.url" target="_blank" rel="noopener">{{ r.url }}</a>
      <template v-if="r.url && r.doi"> · </template>
      <a v-if="r.doi" :href="`https://doi.org/${r.doi}`" target="_blank" rel="noopener">doi:{{ r.doi }}</a>
    </p>
    <p class="kb-dim">From {{ r.source }} · not read in full</p>
    <KBInLibraries kind="paper" :target="r.id" />
  </template>
</template>

<style scoped>
.kbrs-where { overflow-wrap: anywhere; }
</style>
