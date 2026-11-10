<!--
  Choosing the model that reads papers, for setup and the Configuration page: the choices grouped by
  where the model runs, each with its cost, speed and what it needs here (a key, Kaimon's agents,
  Ollama and a model), trying the one chosen on a short passage, and pulling a local model into
  Ollama with the disk's room checked first. `info` is the API's `/api/config/model`; the choice is
  the v-model, with a key typed for it.
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { post, followJobs, jobs } from './kbApi'

export type ModelInfo = {
  places: { id: string; label: string; detail: string }[]
  models: { id: string; place: string; label: string; detail: string; speed: string; needs: string; problem: string;
            agent: boolean; cost: number | null }[]
  machine: { opencode: string; openai: boolean; agents: boolean; memory_gb: number; disk_free_gb: number | null
             ollama: { installed: boolean; running: boolean; here: boolean; url: string; models: { name: string; gb: number }[] }
             local_models: { model: string; gb: number; memory_gb: number; note: string; fits: boolean; room: boolean;
                             pulled: boolean; recommended: boolean }[] }
  model: { id: string; model: string; url: string }
  failing: { summarizer: string; count: number; why: string; error: string } | null
}
export type Choice = { id: string; model: string; url: string; key: string }

const props = defineProps<{ info: ModelInfo; editable?: boolean }>()
const choice = defineModel<Choice>({ required: true })
const emit = defineEmits<{ refresh: [] }>()

const m = computed(() => props.info.machine)
const chosen = computed(() => props.info.models.find(x => x.id === choice.value.id))
const byPlace = computed(() => props.info.places.map(p => ({ ...p, models: props.info.models.filter(x => x.place === p.id) }))
  .filter(p => p.models.length))

// What a choice has here, in a few words, and whether it is ready without anything more.
function readiness(x: ModelInfo['models'][number]): { text: string; ready: boolean } {
  switch (x.needs) {
    case 'opencode':
      return m.value.opencode === 'saved' ? { text: 'OpenCode key saved here', ready: true } :
             m.value.opencode === 'login' ? { text: 'uses your OpenCode login', ready: true } :
             m.value.opencode === 'environment' ? { text: 'key from OPENCODE_API_KEY', ready: true } :
             { text: 'needs an OpenCode key', ready: false }
    case 'openai': return m.value.openai ? { text: 'OpenAI key saved here', ready: true } : { text: 'needs an OpenAI key', ready: false }
    case 'agents': return m.value.agents ? { text: 'Kaimon\'s agents are running', ready: true } :
                                         { text: 'needs Kaimon running here', ready: false }
    case 'ollama':
      return !m.value.ollama.running ? { text: m.value.ollama.installed ? 'Ollama is not running' : 'needs Ollama', ready: false } :
             m.value.ollama.models.length ? { text: `${m.value.ollama.models.length} model(s) in Ollama`, ready: true } :
             { text: 'Ollama has no chat model yet', ready: false }
    default: return { text: '', ready: true }
  }
}
const cost = (x: ModelInfo['models'][number]) =>
  x.agent ? 'your Claude plan' : x.cost === null ? '' : x.cost ? `≈ $${x.cost.toFixed(2)} a paper` : 'free'

// Another key offered at once when the key in use is the one refused.
const replaceKey = ref(/key/i.test(props.info.failing?.why ?? ''))

// Trying the choice: forgotten when the choice changes.
const trying = ref(false)
const tried = ref<{ ok: boolean; text?: string; seconds?: number; error?: string } | null>(null)
watch(choice, () => { tried.value = null }, { deep: true })
// A local model starts from the first Ollama has; another key is offered again for each choice.
watch(() => choice.value.id, id => {
  replaceKey.value = false
  if (id === 'ollama' && !choice.value.model) choice.value.model = props.info.machine.ollama.models[0]?.name ?? ''
})
async function tryIt() {
  trying.value = true; tried.value = null
  try {
    tried.value = await post('/api/config/model/try', JSON.stringify(choice.value))
    // A key refused: offer to enter another in its place.
    if (!tried.value!.ok && /key/i.test(tried.value!.error ?? '') && keyFor.value) replaceKey.value = true
  }
  catch (e: any) { tried.value = { ok: false, error: e.message } }
  finally { trying.value = false }
}
defineExpose({ tried })

// Pulling a local model: followed as a job, the choice made when it is done.
const pullName = ref('')
const pulling = ref<{ model: string; job: string } | null>(null)
const pullError = ref('')
const pullJob = computed(() => jobs.value.find(j => j.id === pulling.value?.job))
async function pull(model: string) {
  pullError.value = ''
  try {
    const r = await post('/api/config/model/pull', JSON.stringify({ model }))
    pulling.value = { model, job: r.job }
    followJobs(r.job)
  } catch (e: any) { pullError.value = e.message }
}
watch(() => pullJob.value?.status, s => {
  if (!pulling.value || !s || s === 'running') return
  if (s === 'done') choice.value = { ...choice.value, id: 'ollama', model: pulling.value.model }
  else pullError.value = pullJob.value?.error ?? 'The pull stopped'
  pulling.value = null
  emit('refresh')
})
const canTry = computed(() => choice.value.id !== '' && (choice.value.id !== 'ollama' || choice.value.model !== '') &&
  (choice.value.id !== 'custom' || (choice.value.url.trim() !== '' && choice.value.model.trim() !== '')))
// Whether a key can be typed for the choice: one it needs, or another in place of the one here.
const keyFor = computed(() => chosen.value?.needs === 'opencode' ? 'OpenCode' : chosen.value?.needs === 'openai' ? 'OpenAI' : '')
</script>

<template>
  <div class="kbmc">
    <p v-if="info.failing" class="kbmc-failing">
      Summaries keep failing with <strong>{{ info.failing.summarizer }}</strong>: {{ info.failing.why }}
      <span class="kbmc-help" :title="info.failing.error">Choose again below, or try it once fixed.</span>
    </p>
    <section v-for="p in byPlace" :key="p.id" class="kbmc-place">
      <h3>{{ p.label }}</h3>
      <p class="kbmc-help">{{ p.detail }}</p>
      <label v-for="x in p.models" :key="x.id" class="kbmc-model" :class="{ on: choice.id === x.id }">
        <input v-model="choice.id" type="radio" :value="x.id" :disabled="!editable" />
        <span class="kbmc-body">
          <span class="kbmc-head">
            <strong>{{ x.label }}</strong>
            <span v-if="cost(x)" class="kbmc-tag">{{ cost(x) }}</span>
            <span v-if="x.speed" class="kbmc-tag kbmc-dim">{{ x.speed }}</span>
            <span v-if="readiness(x).text" class="kbmc-tag" :class="readiness(x).ready ? 'kbmc-ok' : 'kbmc-warn'">{{ readiness(x).text }}</span>
          </span>
          <span class="kbmc-help">{{ x.detail }}</span>
          <span v-if="x.problem && readiness(x).ready" class="kbmc-warn-line">{{ x.problem }}</span>

          <template v-if="choice.id === x.id">
            <!-- A key: one it needs, or another in place of the one here (an expired one, say). -->
            <span v-if="keyFor && (!readiness(x).ready || replaceKey)" class="kbmc-sub">
              <input v-model="choice.key" type="password" :placeholder="`${keyFor} API key`" />
              <span class="kbmc-help">Saved beside the config, readable only by you.
                <a v-if="keyFor === 'OpenCode'" href="https://opencode.ai/zen" target="_blank" rel="noopener">Get a key from OpenCode Zen</a>
                <a v-else href="https://platform.openai.com/api-keys" target="_blank" rel="noopener">Get a key from OpenAI</a></span>
            </span>
            <button v-else-if="keyFor && editable" type="button" class="kb-link kbmc-link" @click="replaceKey = true">enter another key</button>

            <span v-if="x.needs === 'agents' && !m.agents" class="kbmc-sub kbmc-help">
              Run the knowledge base in Kaimon (<code>zemi kaimon</code>), with Claude Code signed in on this machine.
            </span>

            <span v-if="x.needs === 'custom'" class="kbmc-sub">
              <input v-model="choice.url" placeholder="Address: https://api.example.com/v1" />
              <input v-model="choice.model" placeholder="Model" />
              <input v-model="choice.key" type="password" placeholder="API key (if it needs one)" />
            </span>

            <span v-if="x.needs === 'ollama'" class="kbmc-sub">
              <span v-if="!m.ollama.installed" class="kbmc-help">
                Install Ollama from <a href="https://ollama.com/download" target="_blank" rel="noopener">ollama.com</a> and start it, then
                <button type="button" class="kb-link kbmc-link" @click="emit('refresh')">look again</button>.</span>
              <span v-else-if="!m.ollama.running" class="kbmc-help">
                Ollama is installed but not answering at {{ m.ollama.url }}: start it, then
                <button type="button" class="kb-link kbmc-link" @click="emit('refresh')">look again</button>.</span>
              <template v-else>
                <select v-if="m.ollama.models.length" v-model="choice.model">
                  <option value="" disabled>Choose a model</option>
                  <option v-for="o in m.ollama.models" :key="o.name" :value="o.name">{{ o.name }} ({{ o.gb }} GB)</option>
                </select>
                <span class="kbmc-help">
                  Models worth summarizing with, for this machine's {{ m.memory_gb }} GB of memory<template v-if="m.disk_free_gb !== null">
                  and {{ m.disk_free_gb }} GB free on the disk</template>:
                </span>
                <table class="kbmc-local">
                  <tr v-for="l in m.local_models" :key="l.model" :class="{ dim: !l.fits || !l.room }">
                    <td><code>{{ l.model }}</code><span v-if="l.recommended" class="kbmc-tag kbmc-ok">recommended</span></td>
                    <td>{{ l.gb }} GB</td>
                    <td class="kbmc-help">{{ l.note }}</td>
                    <td>
                      <span v-if="l.pulled" class="kbmc-help">pulled</span>
                      <span v-else-if="!l.fits" class="kbmc-help">needs {{ l.memory_gb }} GB of memory</span>
                      <span v-else-if="!l.room" class="kbmc-help">not enough disk</span>
                      <span v-else-if="!m.ollama.here" class="kbmc-help">pull it where Ollama runs</span>
                      <button v-else-if="editable" type="button" class="kb-link kbmc-link" :disabled="!!pulling" @click="pull(l.model)">pull</button>
                    </td>
                  </tr>
                </table>
                <span v-if="editable && m.ollama.here" class="kbmc-pull-other">
                  <input v-model="pullName" placeholder="Another model, by Ollama's name" @keydown.enter.prevent="pullName.trim() && pull(pullName.trim())" />
                  <button type="button" class="kb-link kbmc-link" :disabled="!!pulling || !pullName.trim()" @click="pull(pullName.trim())">pull</button>
                </span>
                <span v-if="pulling" class="kbmc-help">{{ pullJob?.message || `pulling ${pulling.model}` }}</span>
                <span v-if="pullError" class="kbmc-warn-line">{{ pullError }}</span>
              </template>
            </span>
          </template>
        </span>
      </label>
    </section>

    <div v-if="editable" class="kbmc-try">
      <button type="button" class="kbmc-try-button" :disabled="!canTry || trying" @click="tryIt">
        {{ trying ? 'Trying…' : 'Try it' }}</button>
      <span class="kbmc-help">{{ trying ? (chosen?.agent ? 'An agent starts first: this can take a minute.' : 'Summarizing a short passage.') :
        'Has the model summarize a short passage, to see that it works and how it writes.' }}</span>
      <div v-if="tried?.ok" class="kbmc-tried">
        <p>{{ tried.text }}</p>
        <span class="kbmc-help">Written in {{ tried.seconds }} s.</span>
      </div>
      <p v-else-if="tried" class="kbmc-warn-line">{{ tried.error }}</p>
    </div>
  </div>
</template>

<style scoped>
.kbmc-place { margin: 0 0 1.2rem; }
.kbmc-place h3 { margin: 0 0 0.1rem; font-size: 0.95rem; border: 0; padding: 0; }
.kbmc-help { display: block; font-size: 0.8rem; color: var(--vp-c-text-3); }
.kbmc-model { display: flex; gap: 0.6rem; align-items: baseline; margin: 0.4rem 0; padding: 0.5rem 0.7rem; border-radius: 8px;
  border: 1px solid transparent; font-size: 0.92rem; cursor: pointer; }
.kbmc-model.on { border-color: var(--vp-c-brand-1); background: var(--vp-c-bg-soft); }
.kbmc-body { flex: 1; min-width: 0; }
.kbmc-head { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; }
.kbmc-tag { font-size: 0.75rem; padding: 0 0.4rem; border-radius: 999px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbmc-dim { color: var(--vp-c-text-3); }
.kbmc-ok { background: var(--vp-c-green-soft, var(--vp-c-default-soft)); color: var(--vp-c-green-1, var(--vp-c-text-1)); }
.kbmc-warn { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbmc-warn-line { display: block; font-size: 0.82rem; color: var(--vp-c-warning-1); }
.kbmc-sub { display: block; margin: 0.5rem 0 0; }
.kbmc input:not([type=radio]) { display: block; width: 100%; box-sizing: border-box; margin-top: 0.3rem; padding: 0.4rem 0.6rem;
  border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; }
.kbmc select { margin: 0.3rem 0; padding: 0.3rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbmc-link { font-size: 0.85rem; }
.kbmc-local { margin: 0.4rem 0; font-size: 0.85rem; border-collapse: collapse; display: table; }
.kbmc-local td { padding: 0.2rem 0.6rem 0.2rem 0; border: 0; vertical-align: baseline; }
.kbmc-local tr { background: none !important; border: 0; }
.kbmc-local tr.dim td { opacity: 0.55; }
.kbmc-local .kbmc-tag { margin-left: 0.4rem; }
.kbmc-pull-other { display: flex; gap: 0.6rem; align-items: center; max-width: 26rem; }
.kbmc-try-button { padding: 0.3rem 0.9rem; border-radius: 6px; border: 1px solid var(--vp-c-brand-1); color: var(--vp-c-brand-1);
  background: none; font-size: 0.88rem; cursor: pointer; margin-bottom: 0.3rem; }
.kbmc-try-button:disabled { opacity: 0.5; cursor: default; }
.kbmc-try { margin-top: 0.6rem; padding-top: 0.6rem; border-top: 1px solid var(--vp-c-divider); }
.kbmc-tried { margin-top: 0.5rem; padding: 0.5rem 0.8rem; border-radius: 8px; background: var(--vp-c-bg-soft); font-size: 0.9rem; }
.kbmc-tried p { margin: 0 0 0.3rem; }
.kbmc-failing { padding: 0.5rem 0.8rem; border-radius: 8px; background: var(--vp-c-warning-soft); font-size: 0.9rem; }
</style>
