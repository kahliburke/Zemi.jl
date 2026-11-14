<!--
  On a codebase file's page: the tasks whose commits changed the file (see file_work in
  src/task_commits.jl), the latest first. Read from the service, so it shows only to those who may
  see the tasks, and never in a published copy of the site.
-->
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { connect, mode, can, getJSON } from './kbApi'
import { taskHref } from './kbLinks'
import { plainRefs } from './kbRefs'
import { statusLabel } from './kbLabels'
import { day, plural } from './kbFormat'

const props = defineProps<{ codebase: string; path: string }>()
type Work = { ref: string; title: string; status: string; commits: number; at: string }
const work = ref<Work[]>([])

onMounted(async () => {
  await connect()
  if (mode.value !== 'live' || !can('tasks.view')) return
  try { work.value = await getJSON(`/api/tasks/file-work?codebase=${encodeURIComponent(props.codebase)}&path=${encodeURIComponent(props.path)}`) }
  catch { /* the page stands without it */ }
})
</script>

<template>
  <section v-if="work.length" class="kbfw">
    <h2>Work on this file</h2>
    <ul>
      <li v-for="w in work" :key="w.ref">
        <a :href="taskHref(w.ref)" class="kbfw-ref">{{ w.ref }}</a> {{ plainRefs(w.title) }}
        <span class="kb-dim kbfw-dim">{{ statusLabel(w.status) }} · {{ plural(w.commits, 'commit') }} · {{ day(w.at) }}</span>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.kbfw ul { list-style: none; padding: 0; }
.kbfw li { margin: 0.25rem 0; }
.kbfw-ref { font-family: var(--vp-font-family-mono); font-size: 0.8rem; margin-right: 0.3rem; }
.kbfw-dim { font-size: 0.82rem; margin-left: 0.3rem; }
</style>
