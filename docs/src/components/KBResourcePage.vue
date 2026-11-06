<!--
  A resource's page, made from its data (see kbTemplates.ts and `resource_json`): a data set, portal,
  law or work the group uses without reading it in full. Its type, who made it and when, its note,
  where it is, where it came from, and the libraries that keep it. Its PDF uploaded here, it is read
  in full as a paper (see `promote_resource!`); a resource that became a paper sends its readers there.
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { mode, can, post } from './kbApi'
import { kbPage } from './kbLinks'
import KBInLibraries from './KBInLibraries.vue'

type Resource = { id: string; slug: string; title: string; type: string; authors: string[]; date: string; note: string
                  url: string; doi: string; source: string; moved?: string }

const { data: r, error } = useTemplatedPage<Resource>('resources', 'No such resource.', { title: x => x.title })
watch(r, x => { if (x?.moved) location.replace(kbPage(x.moved)) })

const type = computed(() => (r.value?.type || 'resource').replace(/^./, c => c.toUpperCase()))
const uploads = computed(() => mode.value === 'live' && can('paper.add'))
const busy = ref(false)
const failed = ref('')
async function upload(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0]
  if (!file || !r.value) return
  busy.value = true; failed.value = ''
  try {
    const got = await post(`/api/resources/${encodeURIComponent(r.value.id)}/pdf`, file, 'application/pdf')
    location.assign(kbPage(got.page))
  } catch (err: any) { failed.value = err.message ?? String(err); busy.value = false }
}
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!r || r.moved" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="resource-title">{{ r.title }}</h1>
    <div class="kb-paper-head">
      <div class="kb-badges">
        <span class="kb-badge kb-badge-cat">{{ type }}</span>
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
    <p class="kb-dim">From {{ r.source }} · not read in full
      <template v-if="uploads"> ·
        <label class="kb-link kbrs-upload">{{ busy ? 'Reading its PDF…' : 'Upload its PDF' }}
          <input type="file" accept="application/pdf" :disabled="busy" @change="upload" /></label>
      </template></p>
    <p v-if="failed" class="kb-error">{{ failed }}</p>
    <KBInLibraries kind="paper" :target="r.id" />
  </template>
</template>

<style scoped>
.kbrs-where { overflow-wrap: anywhere; }
.kbrs-upload { cursor: pointer; }
.kbrs-upload input { display: none; }
</style>
