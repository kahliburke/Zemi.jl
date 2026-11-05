<!--
  The records the reader may see, newest first, from the service (`GET /api/records`), found by
  project and by source. With `project`, a project's alone, without the filters (its board shows
  them). With `none`, the knowledge base has no record at all, and this says so. Records are
  uploaded on a project's board (KBRecordUpload.vue), so each is its project's from the start.
-->
<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { mode, connect, getJSON } from './kbApi'
import { recordHref, projectHref } from './kbLinks'
import KBNeedsService from './KBNeedsService.vue'

const props = defineProps<{ none?: boolean; project?: string }>()

type Rec = { id: string; title: string; date: string; day: string; people: string[]; label: string; source: string
             projects: string[]; access: string; read: boolean }
const records = ref<Rec[]>([])
const loaded = ref(false)
const failed = ref('')
const project = ref(props.project ?? '')
const source = ref('')
// What the filters offer: the projects and sources of the records seen unfiltered.
const offered = ref<{ projects: string[]; sources: string[] }>({ projects: [], sources: [] })

async function load() {
  if (mode.value !== 'live') return
  failed.value = ''
  try {
    const q = new URLSearchParams({ project: project.value, source: source.value })
    records.value = await getJSON(`/api/records?${q}`)
    if (!project.value && !source.value)
      offered.value = { projects: [...new Set(records.value.flatMap(r => r.projects))].sort(),
                        sources: [...new Set(records.value.map(r => r.source))].sort() }
  } catch (e: any) { failed.value = e.message ?? String(e) }
  loaded.value = true
}
// Seen unfiltered first, for the filters' choices; `?project=KEY` (a board's "more") then picks one.
onMounted(async () => {
  await connect()
  await load()
  const asked = props.project ? '' : new URLSearchParams(location.search).get('project') ?? ''
  if (asked) project.value = asked
})
watch([project, source], load)
watch(() => props.project, p => { project.value = p ?? '' })
const filtered = computed(() => !props.project && (offered.value.projects.length > 1 || offered.value.sources.length > 1))
</script>

<template>
  <p v-if="props.none && !props.project" class="kb-dim">No records yet.</p>
  <KBNeedsService v-else>
    <div v-if="filtered" class="kbrs-filters">
      <select v-model="project" class="kbrs-select">
        <option value="">every project</option>
        <option v-for="p in offered.projects" :key="p" :value="p">{{ p }}</option>
      </select>
      <select v-model="source" class="kbrs-select">
        <option value="">every source</option>
        <option v-for="s in offered.sources" :key="s" :value="s">{{ s }}</option>
      </select>
    </div>
    <p v-if="failed" class="kb-error">{{ failed }}</p>
    <ul v-if="records.length" class="kbrs-list">
      <li v-for="r in records" :key="r.id">
        <a :href="recordHref(r.id)">{{ r.title }}</a>
        <div class="kb-dim">{{ r.day }}<template v-if="r.people.length"> · {{ r.people.join(', ') }}</template> · {{ r.label }}
          <template v-if="!props.project"> ·
            <template v-if="r.projects.length"><a v-for="(k, i) in r.projects" :key="k" :href="projectHref(k)">{{ i ? ', ' : '' }}{{ k }}</a></template>
            <template v-else>no project yet</template></template>
          <template v-if="!r.read"> · not read yet</template></div>
      </li>
    </ul>
    <p v-else-if="loaded" class="kb-dim">{{ props.project ? 'No records linked to this project.' : 'No records you may see.' }}</p>
  </KBNeedsService>
</template>

<style scoped>
.kbrs-filters { display: flex; gap: 0.6rem; margin: 0.8rem 0; }
.kbrs-select { padding: 0.3rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
               background: var(--vp-c-bg); color: var(--vp-c-text-1); font: inherit; }
.kbrs-list { list-style: none; padding: 0; }
.kbrs-list li { margin: 0.7rem 0; }
.kbrs-list .kb-dim { font-size: 0.85rem; }
</style>
