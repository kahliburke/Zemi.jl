<!--
  A paper's notebooks, on its page, while zemi serves the knowledge base API: those being made or that
  failed, a button that has an agent make one (what to compute can be said, or left to the agent), and
  one that attaches a notebook of your own. The notebooks themselves are shown below by the site's
  build.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount, watch } from 'vue'
import { mode, connect, post, jobs, followJobs, finishedJobs, blockers, can, shared, getJSON } from './kbApi'

const props = defineProps<{ id: string }>()
type Notebook = { path: string; title: string; kind: string; status: string; idea: string; summary: string; added_by: string;
                  live: string | null }
const notebooks = ref<Notebook[]>([])
const asking = ref<'make' | 'upload' | null>(null)
const idea = ref('')
const file = ref<File | null>(null)
const title = ref('')
const by = ref('')        // remembered in the browser (read on mount: the page is first rendered on the server)
const busy = ref(false)
const message = ref('')
const error = ref('')
const cannot = computed(() => blockers('ingest', ['paper']))

async function load() {
  if (mode.value !== 'live') return
  try {
    notebooks.value = await getJSON(`/api/notebooks/${encodeURIComponent(props.id)}`)
    if (notebooks.value.some(n => n.status === 'making')) followJobs()       // to show the agent's steps
  } catch (e: any) { error.value = e.message ?? String(e) }
}
onMounted(async () => { by.value = localStorage.getItem('kb-name') ?? ''; await connect(); load() })
watch(finishedJobs, load)

const making = computed(() => notebooks.value.filter(n => n.status === 'making'))
// While one is made, its list is fetched again now and then, for the address to watch it at once the agent has it open.
let refetch: ReturnType<typeof setInterval> | undefined
watch(() => notebooks.value.some(n => n.status === 'making' && !n.live), (waiting) => {
  clearInterval(refetch)
  if (waiting) refetch = setInterval(load, 5000)
})
onBeforeUnmount(() => clearInterval(refetch))
// The job making one: its latest step ("running cell `setup` · 9 cells added, 12 runs, 2 fixes") and how long so far.
const job = computed(() => jobs.value.find(j => j.status === 'running' && j.name === `notebook from ${props.id}`) ?? null)
const failed = computed(() => notebooks.value.filter(n => n.status.startsWith('failed')))
const done = computed(() => notebooks.value.filter(n => n.status === 'done'))

async function make() {
  error.value = ''; busy.value = true
  try {
    const r = await post('/api/notebook', JSON.stringify({ id: props.id, idea: idea.value.trim() }))
    asking.value = null; idea.value = ''
    message.value = 'Making notebook…'
    await followJobs(r.job); load()
  } catch (e: any) { error.value = e.message ?? String(e) }
  finally { busy.value = false }
}

async function upload() {
  if (!file.value) return
  error.value = ''; busy.value = true
  try {
    localStorage.setItem('kb-name', by.value.trim())
    const params = new URLSearchParams({ id: props.id, name: file.value.name, title: title.value.trim(), by: by.value.trim() })
    await post(`/api/notebooks/upload?${params}`, await file.value.text(), 'text/plain')
    asking.value = null; file.value = null; title.value = ''
    message.value = 'Attached. Shown after the next rebuild.'
    load()
  } catch (e: any) { error.value = e.message ?? String(e) }
  finally { busy.value = false }
}
const pick = (e: Event) => { file.value = (e.target as HTMLInputElement).files?.[0] ?? null }
</script>

<template>
  <div v-if="mode === 'live'" class="kbn">
    <div v-for="n in making" :key="n.path" class="kbn-making">
      <div>Making notebook{{ n.idea ? `: ${n.idea}` : '…' }}</div>
      <div v-if="job" class="kbn-step"><span class="kbn-pulse"></span>{{ job.message }} <span class="kbn-dim">· {{ job.elapsed }}</span></div>
      <a v-if="n.live" :href="n.live" target="_blank" rel="noopener" class="kbn-watch">Watch in Slate ↗</a>
    </div>
    <div v-for="n in failed" :key="n.path">Notebook {{ n.status }}</div>
    <div class="kbn-row">
      <span v-if="done.length">{{ done.length }} notebook{{ done.length === 1 ? '' : 's' }} below.</span>
      <button v-if="!cannot.length && !making.length && can('notebook.create')" type="button" class="kb-outline kbn-button" @click="asking = asking === 'make' ? null : 'make'">
        {{ failed.length ? 'Retry notebook' : done.length ? 'New notebook' : 'Make notebook' }}</button>
      <button v-if="can('notebook.upload')" type="button" class="kb-outline kbn-button" @click="asking = asking === 'upload' ? null : 'upload'">Attach notebook</button>
    </div>
    <div v-if="asking === 'make'" class="kbn-ask">
      <textarea v-model="idea" rows="3" class="kb-field kbn-input"
                placeholder="What to compute (optional)"></textarea>
      <div class="kbn-row">
        <button type="button" class="kb-outline kbn-button" :disabled="busy" @click="make">{{ busy ? 'Starting…' : 'Start' }}</button>
        <span class="kbn-dim">Built and run in Slate.</span>
      </div>
    </div>
    <div v-if="asking === 'upload'" class="kbn-ask">
      <input type="file" accept=".jl" @change="pick" />
      <input v-model="title" class="kb-field kbn-input" placeholder="Title (optional)" />
      <input v-if="!shared" v-model="by" class="kb-field kbn-input" placeholder="Your name" />
      <div class="kbn-row">
        <button type="button" class="kb-outline kbn-button" :disabled="busy || !file" @click="upload">{{ busy ? 'Attaching…' : 'Attach' }}</button>
        <span class="kbn-dim">Slate notebook (.jl)</span>
      </div>
    </div>
    <p v-if="message" class="kbn-dim">{{ message }}</p>
    <p v-if="error" class="kb-error kbn-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbn { margin: 0.6rem 0 1rem; color: var(--vp-c-text-2); font-size: 0.9rem; }
.kbn-row { display: flex; gap: 0.8rem; align-items: center; margin-top: 0.4rem; flex-wrap: wrap; }
.kbn-ask { margin-top: 0.5rem; display: flex; flex-direction: column; gap: 0.4rem; }
.kbn-input { display: block; width: 100%; box-sizing: border-box; padding: 0.5rem 0.7rem; border-radius: 8px; }
.kbn-dim { font-size: 0.85rem; }
.kbn-making { padding: 0.5rem 0.8rem; border-radius: 8px; background: var(--vp-c-bg-soft); }
.kbn-step { margin-top: 0.3rem; color: var(--vp-c-text-1); }
.kbn-watch { display: inline-block; margin-top: 0.4rem; font-weight: 600; }
.kbn-pulse { display: inline-block; width: 0.5rem; height: 0.5rem; margin-right: 0.5rem; border-radius: 50%;
  background: var(--vp-c-brand-1); animation: kbn-pulse 1.2s ease-in-out infinite; }
@keyframes kbn-pulse { 50% { opacity: 0.25; } }
.kbn-button { padding: 0.2rem 0.8rem; border-radius: 8px; }
</style>
