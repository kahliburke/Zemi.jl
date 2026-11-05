<!--
  On a paper's, notebook's or codebase's page, while the service serves it: the projects whose library
  holds it, and putting it in the library of a project the reader works on, with why it matters there.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { projectHref } from './kbLinks'
import { mode, connect, can, getJSON, post } from './kbApi'

const props = defineProps<{ kind: 'paper' | 'notebook' | 'codebase'; target: string }>()
type Item = { id: number; status: string; why: string }
type Project = { key: string; name: string; access: string; library: Item | null }
const projects = ref<Project[]>([])
const adding = ref<{ project: string; why: string } | null>(null)
const sending = ref(false)
const error = ref('')

async function load() {
  const q = `kind=${props.kind}&target=${encodeURIComponent(props.target)}`
  projects.value = (await getJSON(`/api/projects?${q}`)).projects
}
onMounted(async () => {
  await connect()
  if (mode.value !== 'live' || !can('tasks.view')) return
  try { await load() } catch { /* the page stands without it */ }
})

const holding = computed(() => projects.value.filter(p => p.library))
const open = computed(() => can('tasks.edit') ? projects.value.filter(p => !p.library && ['contributor', 'maintainer'].includes(p.access)) : [])
const source = () => props.kind === 'codebase' ? props.target : `@[${props.target}](${props.kind}:${props.target})`

function start() { adding.value = { project: open.value[0]?.key ?? '', why: '' }; error.value = '' }
async function add() {
  const a = adding.value
  if (!a?.project || sending.value) return
  sending.value = true
  try {
    await post(`/api/projects/${a.project}/library`, JSON.stringify({ source: source(), why: a.why }))
    adding.value = null
    await load()
  } catch (e: any) { error.value = e.message }
  finally { sending.value = false }
}
</script>

<template>
  <section v-if="holding.length || open.length" class="kbil">
    <span class="kbil-label">In libraries:</span>
    <span v-if="!holding.length" class="kbil-dim">none yet</span>
    <a v-for="p in holding" :key="p.key" class="kbil-project" :class="{ proposed: p.library?.status === 'proposed' }"
       :href="projectHref(p.key)" :title="[p.name, p.library?.why, p.library?.status === 'proposed' ? 'proposed' : ''].filter(Boolean).join(' · ')">{{ p.key }}</a>
    <button v-if="open.length && !adding" class="kbil-small" @click="start">+ Add to a library</button>
    <form v-if="adding" class="kbil-add" @submit.prevent="add">
      <select v-model="adding.project" aria-label="Project">
        <option v-for="p in open" :key="p.key" :value="p.key">{{ p.key }} · {{ p.name }}</option>
      </select>
      <input v-model="adding.why" placeholder="Why it matters to the project" aria-label="Why it matters" />
      <button class="kb-primary kbil-button" :disabled="!adding.project || sending">Add</button>
      <button type="button" class="kbil-small" @click="adding = null">Cancel</button>
    </form>
    <p v-if="error" class="kb-error kbil-error">{{ error }}</p>
  </section>
</template>

<style scoped>
.kbil { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; margin: 0.6rem 0 1rem; font-size: 0.88rem; }
.kbil-label { color: var(--vp-c-text-2); }
.kbil-dim { color: var(--vp-c-text-3); }
.kbil-project { font-family: var(--vp-font-family-mono); font-size: 0.8rem; padding: 0.05rem 0.5rem; border-radius: 999px;
                background: var(--vp-c-brand-soft); text-decoration: none; }
.kbil-project.proposed { background: var(--vp-c-warning-soft); color: var(--vp-c-warning-1); }
.kbil-add { display: flex; flex-wrap: wrap; gap: 0.4rem; width: 100%; }
.kbil-add select, .kbil-add input { padding: 0.25rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
                                    background: var(--vp-c-bg); color: var(--vp-c-text-1); font: inherit; }
.kbil-add input { flex: 1; min-width: 14rem; }
.kbil-button { padding: 0.25rem 0.8rem; border-radius: 6px; }
.kbil-button:disabled { opacity: 0.6; cursor: default; }
.kbil-small { padding: 0.1rem 0.6rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2); cursor: pointer; font: inherit; font-size: 0.8rem; }
.kbil-error { width: 100%; margin: 0; }
</style>
