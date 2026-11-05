<!--
  The Paper of the Day's controls, while zemi serves the knowledge base API: today's state, and a
  button that picks and analyses today's paper, or another one. On a past day's page (`day`), only
  that day's paper analysed again. The page itself is written with the site, which rebuilds when the
  job is done.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted, watch } from 'vue'
import { mode, connect, post, followJobs, finishedJobs, blockers, can, getJSON } from './kbApi'
import KBJobs from './KBJobs.vue'
import { todayUtc } from './kbFormat'

type Day = { day: string; id: string; title: string; status: string; error: string; computable: boolean; notebook: string }
const props = defineProps<{ day?: string }>()
const days = ref<Day[]>([])
const busy = ref(false)
const error = ref('')
const cannot = computed(() => blockers('ingest', ['paper']))

async function load() {
  if (mode.value !== 'live') return
  try { days.value = await getJSON('/api/daily') }
  catch (e: any) { error.value = e.message ?? String(e) }
}
onMounted(async () => { await connect(); load() })
watch(finishedJobs, load)

// A past day's page works on its own day only.
const past = computed(() => !!props.day && props.day !== todayUtc())
const today = computed(() => days.value.find(x => x.day === (props.day || todayUtc())) ?? null)

// A notebook computing from the paper, made by an agent working in Slate: long, so only when asked.
async function notebook() {
  if (!today.value) return
  error.value = ''; busy.value = true
  try { await followJobs((await post('/api/daily/notebook', JSON.stringify({ day: today.value.day }))).job) }
  catch (e: any) { error.value = e.message ?? String(e) }
  finally { busy.value = false }
}
const canNotebook = computed(() => today.value?.status === 'done' && today.value.computable &&
                                   (!today.value.notebook || today.value.notebook.startsWith('failed')))

async function run(another: boolean, again = false) {
  error.value = ''; busy.value = true
  const day = again && past.value ? props.day : ''
  try { await followJobs((await post('/api/daily', JSON.stringify({ another, again, day }))).job) }
  catch (e: any) { error.value = e.message ?? String(e) }
  finally { busy.value = false }
}
</script>

<template>
  <div v-if="mode === 'live'" class="kbd">
    <p v-if="cannot.length" class="kb-dim kbd-dim">Unavailable here: {{ cannot.join('; ') }}.</p>
    <template v-else>
      <p class="kb-dim kbd-dim">
        <template v-if="!today">{{ past ? 'No paper this day.' : 'None picked today.' }}</template>
        <template v-else-if="today.status === 'done'"></template>
        <template v-else-if="today.status === 'failed'">Failed: {{ today.error }}</template>
        <template v-else>{{ today.status === 'analysing' ? 'Analysing' : 'Reading' }} <KBTitle :text="today.title" />…</template>
        <button v-if="!past && can('daily')" type="button" class="kb-outline kbd-button" :disabled="busy || (today !== null && !['done', 'failed'].includes(today.status))"
                @click="run(today !== null)">{{ today ? 'Pick another' : 'Pick' }}</button>
        <button v-if="today && ['done', 'failed'].includes(today.status) && can('daily')" type="button" class="kb-outline kbd-button"
                :disabled="busy" @click="run(false, true)">Analyse again</button>
        <button v-if="canNotebook && !past && can('notebook.create')" type="button" class="kb-outline kbd-button" :disabled="busy" @click="notebook">Make notebook</button>
        <span v-if="today?.notebook === 'making'">Making notebook…</span>
        <span v-else-if="today?.notebook?.startsWith('failed')">Notebook {{ today.notebook }}</span>
      </p>
      <p v-if="error" class="kb-error kbd-error">{{ error }}</p>
      <KBJobs />
    </template>
  </div>
</template>

<style scoped>
.kbd { margin: 0.5rem 0 1.5rem; }
.kbd-dim { font-size: 0.9rem; display: flex; gap: 0.8rem; align-items: center; flex-wrap: wrap; }
.kbd-button { padding: 0.25rem 0.8rem; border-radius: 8px; }
</style>
