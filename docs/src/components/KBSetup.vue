<!--
  Setting up a new knowledge base: the group it is for, what it watches on arXiv, which model
  summarizes, and whether it reads alone, joins a group's dataset with a key, or starts one. With
  `prompt`, only a line on the front page leading here, while the knowledge base is not set up.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, computed, onMounted } from 'vue'
import { mode, connect, getJSON, post, can, followJobs, jobs } from './kbApi'
import { pageLink, kbPage } from './kbLinks'

const props = defineProps<{ prompt?: boolean }>()

type Area = { name: string; description: string }
type Setup = { needed: boolean; group: { name: string; field: string; description: string; focus_areas: Area[] };
               watch: string[]; contact: string; categories: { id: string; title: string }[];
               models: { id: string; label: string; detail: string; problem: string; agent: boolean; cost: number | null; needs_key: boolean }[];
               ollama_models: string[]; model: { id: string; model: string; url: string };
               machine: Record<string, string>; stream: string }
const setup = ref<Setup | null>(null)
const error = ref('')
const step = ref(0)
const steps = ['Group', 'arXiv', 'Model', 'Sharing']
const done = ref<{ job: string | null } | null>(null)

const group = ref({ name: '', field: '', description: '', focus_areas: [] as Area[] })
const watch = ref<string[]>([])
const contact = ref('')
const model = ref({ id: '', model: '', url: '', key: '' })
// The model as set up already: sent only when changed, so a rerun leaves it, and a judge set apart, alone.
let initialModel = ''
const share = ref({ mode: 'alone', key: '', stream: '', store: 'dir', dir: '', endpoint: '', bucket: '', prefix: 'kb',
                    access_key_id: '', secret_access_key: '' })

onMounted(async () => {
  await connect()
  if (mode.value !== 'live' || !can('config.view')) return
  if (props.prompt) {
    if (can('config.edit')) try { setup.value = await getJSON('/api/config/setup?needed=1') } catch {}
    return
  }
  try {
    const s: Setup = await getJSON('/api/config/setup')
    setup.value = s
    group.value = { ...s.group, focus_areas: s.group.focus_areas.length ? s.group.focus_areas : [{ name: '', description: '' }] }
    watch.value = [...s.watch]; contact.value = s.contact
    model.value = { ...s.model, key: '' }
    if (s.model.id !== 'ollama') model.value.model = s.ollama_models[0] ?? ''
    initialModel = JSON.stringify(model.value)
    share.value.stream = s.stream
  } catch (e: any) { error.value = e.message }
})

const query = ref('')
// A category chosen from those found: by a click, or Enter for the first.
function addCategory(id: string) { watch.value.includes(id) || watch.value.push(id); query.value = '' }
const found = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q || !setup.value) return []
  return setup.value.categories.filter(c => !watch.value.includes(c.id) &&
    (c.id.toLowerCase().includes(q) || c.title.toLowerCase().includes(q))).slice(0, 12)
})
const title = (id: string) => setup.value?.categories.find(c => c.id === id)?.title ?? id

const ready = computed(() => [
  group.value.name.trim() !== '',
  watch.value.length > 0,
  model.value.id !== '' && (model.value.id !== 'ollama' || model.value.model !== '') &&
    (model.value.id !== 'custom' || (model.value.url.trim() !== '' && model.value.model.trim() !== '')),
  share.value.mode === 'alone' || (share.value.mode === 'join' ? share.value.key.trim() !== '' :
    share.value.store === 'dir' ? share.value.dir.trim() !== '' :
    !!(share.value.endpoint && share.value.bucket && share.value.access_key_id && share.value.secret_access_key)),
][step.value])

async function readKey(e: Event) {
  const f = (e.target as HTMLInputElement).files?.[0]
  if (f) share.value.key = await f.text()
}

async function finish() {
  error.value = ''
  const s = share.value
  const dataset = s.mode === 'join' ? { mode: 'join', key: s.key } :
                  s.mode === 'start' ? { mode: 'start', stream: s.stream, store: s.store === 'dir' ? `dir:${s.dir.trim()}` : 's3',
                                         endpoint: s.endpoint, bucket: s.bucket, prefix: s.prefix,
                                         access_key_id: s.access_key_id, secret_access_key: s.secret_access_key } :
                  { mode: 'alone' }
  try {
    const r = await post('/api/config/setup', JSON.stringify({
      group: { ...group.value, focus_areas: group.value.focus_areas.filter(a => a.name.trim()) },
      watch: watch.value, contact: contact.value, dataset,
      ...(!setup.value?.needed && JSON.stringify(model.value) === initialModel ? {} : { model: model.value }) }))
    done.value = { job: r.job }
    if (r.job) followJobs(r.job)
  } catch (e: any) { error.value = e.message }
}
const job = computed(() => jobs.value.find(j => j.id === done.value?.job))
</script>

<template>
  <div v-if="props.prompt">
    <p v-if="setup?.needed && can('config.edit')" class="kbsu-prompt">
      Not set up yet. <a :href="pageLink('/service/setup')">Set up this knowledge base</a>
    </p>
  </div>
  <div v-else class="kbsu">
    <KBNeedsService permission="config.edit">
      <div v-if="done" class="kbsu-done">
        <p><strong>Done.</strong> The site will rebuild in a moment.</p>
        <p v-if="job" class="kb-dim">Importing the dataset: {{ job.status === 'running' ? job.message || 'starting' : job.result ?? job.error }}</p>
        <p><a :href="`${kbPage('status')}#add-documents`">Add papers</a> · <a :href="pageLink('/service/configuration')">Configuration</a></p>
      </div>
      <template v-else-if="setup">
        <p v-if="!setup.needed" class="kb-dim">Already set up. Saving replaces these settings.</p>
        <ol class="kbsu-steps">
          <li v-for="(s, i) in steps" :key="s" :class="{ on: i === step, past: i < step }" :aria-current="i === step ? 'step' : undefined">
          <button v-if="i < step" type="button" @click="step = i">{{ s }}</button><template v-else>{{ s }}</template></li>
        </ol>

        <section v-if="step === 0">
          <label class="kbsu-field">Name <input v-model="group.name" placeholder="Reef Ecology Lab" /></label>
          <label class="kbsu-field">Field <input v-model="group.field" placeholder="coral reef ecology" />
            <span class="kbsu-help">Agents act as experts in this field.</span></label>
          <label class="kbsu-field">Description <textarea v-model="group.description" rows="3"
            placeholder="What the group works on."></textarea></label>
          <div class="kbsu-field">Focus areas
            <span class="kbsu-help">Topics the landscape and the arXiv watch score papers against.</span>
            <div v-for="(a, i) in group.focus_areas" :key="i" class="kbsu-area">
              <input v-model="a.name" placeholder="Name" />
              <input v-model="a.description" placeholder="What it covers" />
              <button class="kb-link kbsu-link" @click="group.focus_areas.splice(i, 1)">remove</button>
            </div>
            <button class="kb-link kbsu-link" @click="group.focus_areas.push({ name: '', description: '' })">add an area</button>
          </div>
        </section>

        <section v-if="step === 1">
          <div class="kbsu-field">Categories watched
            <div class="kbsu-chips">
              <span v-for="c in watch" :key="c" class="kbsu-chip" :title="title(c)">{{ c }}
                <button class="kbsu-x" @click="watch = watch.filter(x => x !== c)">×</button></span>
            </div>
            <input v-model="query" placeholder="Find a category: ecology, q-bio, machine learning…"
                   @keydown.enter.prevent="found.length && addCategory(found[0].id)" />
            <ul v-if="found.length" class="kbsu-found">
              <li v-for="c in found" :key="c.id"><button type="button" @click="addCategory(c.id)"><code>{{ c.id }}</code> {{ c.title }}</button></li>
            </ul>
          </div>
          <label class="kbsu-field">Contact email <input v-model="contact" type="email" placeholder="lab@example.org" />
            <span class="kbsu-help">Sent with arXiv and OpenAlex requests, as their policies ask.</span></label>
        </section>

        <section v-if="step === 2">
          <div class="kbsu-field">The model that reads the papers
            <span class="kbsu-help">Summarizes, classifies and rates papers.</span>
            <label v-for="m in setup.models" :key="m.id" class="kbsu-choice kbsu-model" :class="{ on: model.id === m.id }">
              <input v-model="model.id" type="radio" :value="m.id" />
              <span>
                <strong>{{ m.label }}</strong>
                <span class="kbsu-cost">{{ m.agent ? 'your Claude subscription' : m.cost !== null ? (m.cost ? `≈ $${m.cost.toFixed(2)} a paper` : 'free') : '' }}</span>
                <span class="kbsu-help">{{ m.detail }}</span>
                <span v-if="m.problem && !(m.needs_key && model.id === m.id)" class="kbsu-warn">Not ready here: {{ m.problem }}</span>
                <span v-if="model.id === m.id && m.id === 'ollama' && setup.ollama_models.length" class="kbsu-sub">
                  <select v-model="model.model"><option v-for="o in setup.ollama_models" :key="o" :value="o">{{ o }}</option></select>
                </span>
                <span v-if="model.id === m.id && m.id === 'custom'" class="kbsu-sub">
                  <input v-model="model.url" placeholder="Address: https://api.example.com/v1" />
                  <input v-model="model.model" placeholder="Model" />
                  <input v-model="model.key" type="password" placeholder="API key (if it needs one)" />
                </span>
                <span v-if="model.id === m.id && m.needs_key" class="kbsu-sub">
                  <input v-model="model.key" type="password" placeholder="OpenAI API key" />
                </span>
              </span>
            </label>
          </div>
          <p v-for="(why, what) in setup.machine" :key="what" class="kbsu-warn">{{ why }}</p>
        </section>

        <section v-if="step === 3">
          <label class="kbsu-choice"><input v-model="share.mode" type="radio" value="alone" />
            <span><strong>Alone</strong> <span class="kb-dim">papers are read and kept here</span></span></label>
          <label class="kbsu-choice"><input v-model="share.mode" type="radio" value="join" />
            <span><strong>Join a group's dataset</strong> <span class="kb-dim">with the key file you were sent</span></span></label>
          <div v-if="share.mode === 'join'" class="kbsu-sub">
            <input type="file" accept=".toml,text/plain" @change="readKey" />
            <textarea v-model="share.key" rows="4" placeholder="or paste the key file"></textarea>
          </div>
          <label class="kbsu-choice"><input v-model="share.mode" type="radio" value="start" />
            <span><strong>Start a dataset</strong> <span class="kb-dim">for other members to import and publish to</span></span></label>
          <div v-if="share.mode === 'start'" class="kbsu-sub">
            <label class="kbsu-field">Your stream <input v-model="share.stream" /></label>
            <label class="kbsu-choice"><input v-model="share.store" type="radio" value="dir" /> a folder (a shared drive)</label>
            <label class="kbsu-choice"><input v-model="share.store" type="radio" value="s3" /> an S3-compatible bucket (R2, S3, B2, MinIO)</label>
            <input v-if="share.store === 'dir'" v-model="share.dir" placeholder="/path/to/the/folder" />
            <template v-else>
              <input v-model="share.endpoint" placeholder="Endpoint: https://<account>.r2.cloudflarestorage.com" />
              <input v-model="share.bucket" placeholder="Bucket" />
              <input v-model="share.prefix" placeholder="Prefix" />
              <input v-model="share.access_key_id" placeholder="Access key id" />
              <input v-model="share.secret_access_key" type="password" placeholder="Secret access key" />
            </template>
          </div>
        </section>

        <div class="kbsu-actions">
          <button v-if="step > 0" class="kb-link kbsu-link" @click="step--">back</button>
          <button v-if="step < steps.length - 1" class="kb-primary kbsu-button" :disabled="!ready" @click="step++">Next</button>
          <button v-else class="kb-primary kbsu-button" :disabled="!ready" @click="finish">Set up</button>
        </div>
      </template>
    </KBNeedsService>
    <p v-if="error" class="kb-error kbsu-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbsu-prompt { margin: 1.5rem auto 0; max-width: 40rem; padding: 0.7rem 1rem; border-radius: 10px; text-align: center;
  background: var(--vp-c-brand-soft); }
.kbsu-help { display: block; font-size: 0.8rem; color: var(--vp-c-text-3); }
.kbsu-warn { display: block; font-size: 0.82rem; color: var(--vp-c-warning-1); }
.kbsu-steps { display: flex; gap: 0.4rem; list-style: none; padding: 0; margin: 1rem 0 1.4rem; }
.kbsu-steps li + li { margin-top: 0; }
.kbsu-steps li { padding: 0.25rem 0.8rem; border-radius: 999px; font-size: 0.85rem; color: var(--vp-c-text-3); background: var(--vp-c-default-soft); }
.kbsu-steps li.on { color: var(--vp-c-white); background: var(--vp-c-brand-1); }
.kbsu-steps li.past { color: var(--vp-c-text-1); }
.kbsu-steps button { padding: 0; border: none; background: none; font: inherit; color: inherit; cursor: pointer; }
.kbsu-field { display: block; margin: 0 0 1rem; font-size: 0.92rem; }
.kbsu input:not([type=radio]):not([type=checkbox]):not([type=file]), .kbsu textarea {
  display: block; width: 100%; box-sizing: border-box; margin-top: 0.3rem; padding: 0.4rem 0.6rem; border-radius: 6px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; }
.kbsu-area { display: grid; grid-template-columns: 1fr 2fr auto; gap: 0.5rem; align-items: center; }
.kbsu-chips { display: flex; flex-wrap: wrap; gap: 0.35rem; margin: 0.3rem 0; }
.kbsu-chip { padding: 0.1rem 0.5rem; border-radius: 6px; font-size: 0.82rem; background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbsu-x { background: none; border: none; cursor: pointer; color: inherit; padding: 0 0 0 0.2rem; }
.kbsu-found { list-style: none; margin: 0.3rem 0 0; padding: 0; border: 1px solid var(--vp-c-divider); border-radius: 6px; }
.kbsu-found button { display: block; width: 100%; text-align: left; border: 0; background: none; color: inherit; padding: 0.3rem 0.6rem; cursor: pointer; font-size: 0.86rem; }
.kbsu-found button:hover, .kbsu-found button:focus-visible { background: var(--vp-c-default-soft); }
.kbsu-choice { display: flex; gap: 0.6rem; align-items: baseline; margin: 0.4rem 0; font-size: 0.92rem; cursor: pointer; }
.kbsu-sub { margin: 0.2rem 0 0.8rem 1.6rem; }
.kbsu-model { padding: 0.5rem 0.7rem; border-radius: 8px; border: 1px solid transparent; }
.kbsu-model.on { border-color: var(--vp-c-brand-1); background: var(--vp-c-bg-soft); }
.kbsu-model .kbsu-sub { display: block; margin: 0.4rem 0 0; }
.kbsu-model select { margin-top: 0.3rem; padding: 0.3rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbsu-cost { margin-left: 0.5rem; font-size: 0.8rem; color: var(--vp-c-brand-1); }
.kbsu-actions { display: flex; gap: 1rem; align-items: center; justify-content: flex-end; margin-top: 1.4rem; }
.kbsu-button { padding: 0.45rem 1.2rem; }
.kbsu-button:disabled { opacity: 0.5; cursor: default; }
</style>
