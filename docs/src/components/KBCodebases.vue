<!--
  On the Codebases page, while the service serves it: the codebases the site is built without that
  the reader may see, those open only to the members of the projects linked to them (see
  src/document_access.jl). With `none`, the site lists no open codebase, and this says there are none
  when the reader sees none either.
-->
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { mode, connect, getJSON } from './kbApi'
import { codebaseHref } from './kbLinks'

const props = defineProps<{ none?: boolean }>()

type Codebase = { id: string; slug: string; title: string; one_line: string; files: number; commit: string; access: string }
const closed = ref<Codebase[]>([])
const loaded = ref(false)

onMounted(async () => {
  await connect()
  if (mode.value === 'live')
    try { closed.value = (await getJSON('/api/codebases') as Codebase[]).filter(c => c.access === 'projects') }
    catch { /* the page stands without them */ }
  loaded.value = true
})
</script>

<template>
  <template v-if="closed.length">
    <h2 id="of-your-projects">Of your projects</h2>
    <ul>
      <li v-for="c in closed" :key="c.id"><a :href="codebaseHref(c.slug)">{{ c.title }}</a><template v-if="c.one_line">: {{ c.one_line }}</template>
        <em> ({{ c.files }} files<template v-if="c.commit">, commit <code>{{ c.commit }}</code></template>)</em></li>
    </ul>
  </template>
  <p v-else-if="props.none && loaded">No codebases yet.</p>
</template>
