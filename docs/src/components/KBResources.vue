<!--
  The resources (resources.json, see `resources_json`): the data sets, portals, laws and works the
  group uses without reading them in full, by type, each with who made it and when.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { siteJSON } from './kbApi'
import { kbPage } from './kbLinks'

type Item = { id: string; slug: string; page: string; title: string; type: string; authors: string[]; date: string; source: string }
const items = ref<Item[]>([])
const error = ref('')
onMounted(async () => {
  try { items.value = await siteJSON('/resources.json', { cache: 'no-store' }) } catch (e: any) { error.value = e.message }
})
// By type, the types in alphabetical order with those of none last.
const groups = computed(() => {
  const by = new Map<string, Item[]>()
  for (const x of items.value) by.set(x.type, [...(by.get(x.type) ?? []), x])
  return [...by.entries()].sort(([a], [b]) => (a === '') !== (b === '') ? (a === '' ? 1 : -1) : a.localeCompare(b))
})
</script>

<template>
  <p v-if="error" class="kb-error">{{ error }}</p>
  <p v-else-if="!items.length" class="kb-dim">No resources yet.</p>
  <section v-for="[type, xs] in groups" :key="type">
    <h2>{{ type || 'Other' }}</h2>
    <ul class="kbrl">
      <li v-for="x in xs" :key="x.id"><a :href="kbPage(x.page)">{{ x.title }}</a>
        <span class="kb-dim"><template v-if="x.authors.length"> · {{ x.authors.join(', ') }}</template><template v-if="x.date"> · {{ x.date }}</template></span></li>
    </ul>
  </section>
</template>

<style scoped>
.kbrl { padding-left: 1.1rem; }
.kbrl li { margin: 0.25rem 0; }
</style>
