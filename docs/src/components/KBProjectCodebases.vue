<!--
  On a project's board: its codebases (see src/project_codebases.jl), the main one first, and the
  GitHub organizations it takes repositories from. Agents working in any of them find the project, and
  the commits in each are recorded against its tasks. A maintainer links another (a codebase the
  knowledge base has, a repository's address, a folder on the service's machine, or an organization),
  unlinks one, or makes one main. One not yet in the knowledge base is added only by someone who may add
  sources, and a folder, in a shared service, by someone who may change its configuration.
-->
<script setup lang="ts">
import { ref, computed } from 'vue'
import { getJSON, post, can, shared } from './kbApi'
import { when } from './kbFormat'
import KBIcon from './KBIcon.vue'

export type ProjectCodebase = { id: string; title: string; rev: string; remote: string; page: string; main: boolean
                                org: string; gone: boolean; archived: boolean }
export type ProjectOrg = { host: string; owner: string; forks: boolean; listed_at: string; problem: string }

const props = defineProps<{ project: string; codebases: ProjectCodebase[]; orgs: ProjectOrg[]; manages: boolean }>()
const emit = defineEmits<{ changed: [] }>()

// Past this many, the rest wait behind "more", as an organization's repositories may be many.
const SHOWN = 6
const all = ref(false)
const shown = computed(() => all.value ? props.codebases : props.codebases.slice(0, SHOWN))

const known = ref<{ id: string; title: string }[] | null>(null)
const draft = ref<string | null>(null)
const NEW = '+new'
const address = ref('')
const forks = ref(false)
const error = ref('')
const busy = ref(false)
const adds = computed(() => can('paper.add'))
const linkable = computed(() => (known.value ?? []).filter(c => !props.codebases.some(x => x.id === c.id)))
const hint = computed(() => (!shared.value || can('config.edit') ? 'https://github.com/owner/repo, a folder (~/code/project)' : 'https://github.com/owner/repo') +
  ', or github.com/organization')
// An organization, as the service reads one: github.com/<owner> or org:<owner>.
const isOrg = computed(() => draft.value === NEW && /^(org:|(https?:\/\/)?(www\.)?github\.com\/)[A-Za-z0-9][A-Za-z0-9-]*\/?$/i.test(address.value.trim()))
const remoteName = (u: string) => u.replace(/^https:\/\//, '')

async function start() {
  draft.value = adds.value ? NEW : ''
  address.value = ''; forks.value = false; error.value = ''
  if (!known.value) try { known.value = await getJSON('/api/tasks/codebases') } catch (e: any) { error.value = e.message }
  if (linkable.value.length) draft.value = linkable.value[0].id
}
async function send(body: Record<string, unknown>) {
  if (busy.value) return
  busy.value = true; error.value = ''
  try { await post(`/api/projects/${props.project}/codebases`, JSON.stringify(body)); emit('changed'); return true }
  catch (e: any) { error.value = e.message; return false }
  finally { busy.value = false }
}
async function save() {
  const codebase = draft.value === NEW ? address.value.trim() : draft.value
  if (!codebase) return
  if (await send({ codebase, forks: isOrg.value && forks.value })) { draft.value = null; known.value = null }
}
const remove = (c: ProjectCodebase) => confirm(`Unlink ${c.title} from ${props.project}? Its commits stop being recorded against the project's tasks.`) &&
  send({ codebase: c.id, remove: true })
const removeOrg = (o: ProjectOrg) => confirm(`Stop taking in ${o.host}/${o.owner}, and unlink the codebases it brought?`) &&
  send({ codebase: `${o.host}/${o.owner}`, remove: true })
const makeMain = (c: ProjectCodebase) => send({ codebase: c.id, main: true })
const marks = (c: ProjectCodebase) => [c.archived && 'archived', c.gone && `no longer in ${c.org}`].filter(Boolean).join(' · ')
</script>

<template>
  <div class="kbpc">
    <span class="kbpc-label">Code</span>
    <ul v-if="codebases.length" class="kbpc-list">
      <li v-for="c in shown" :key="c.id" class="kbpc-item" :class="{ main: c.main, faded: c.archived || c.gone }">
        <button v-if="manages && !c.main" class="kbpc-star" title="Make this the main codebase, the one @code: refers to"
                aria-label="Make this the main codebase" :disabled="busy" @click="makeMain(c)"><KBIcon name="star_outline" :size="14" /></button>
        <span v-else-if="c.main && codebases.length > 1" class="kbpc-star on" title="The main codebase, the one @code: refers to"><KBIcon name="star" :size="14" /></span>
        <a :href="c.page">{{ c.title }}</a>
        <code v-if="c.rev" class="kb-dim kbpc-dim" :title="c.rev.endsWith('+') ? 'with changes not committed' : 'checked out'">{{ c.rev }}</code>
        <a v-if="c.remote" :href="c.remote" target="_blank" rel="noopener" class="kb-dim kbpc-dim">{{ remoteName(c.remote) }}</a>
        <span v-if="marks(c)" class="kbpc-mark">{{ marks(c) }}</span>
        <button v-if="manages" class="kbpc-x" :title="`Unlink ${c.title}`" :aria-label="`Unlink ${c.title}`" :disabled="busy"
                @click="remove(c)"><KBIcon name="close" :size="13" /></button>
      </li>
      <li v-if="codebases.length > SHOWN"><button class="kb-link kbpc-more" @click="all = !all">{{ all ? 'fewer' : `${codebases.length - SHOWN} more` }}</button></li>
    </ul>
    <span v-else class="kb-dim kbpc-dim">No codebase linked</span>
    <button v-if="manages && draft === null" class="kbpc-icon" title="Link a codebase or an organization" aria-label="Link a codebase or an organization"
            @click="start"><KBIcon name="plus" :size="15" /></button>
    <div v-for="o in orgs" :key="o.owner" class="kbpc-org">
      <span class="kb-dim">Repositories of</span>
      <a :href="`https://${o.host}/${o.owner}`" target="_blank" rel="noopener">{{ o.host }}/{{ o.owner }}</a>
      <span class="kb-dim kbpc-dim">{{ o.forks ? 'with forks · ' : '' }}{{ o.listed_at ? `listed ${when(o.listed_at)}` : 'not listed yet' }}</span>
      <span v-if="o.problem" class="kbpc-problem" :title="o.problem">could not be listed: {{ o.problem }}</span>
      <button v-if="manages" class="kbpc-x" :title="`Stop taking in ${o.owner}`" :aria-label="`Stop taking in ${o.owner}`" :disabled="busy"
              @click="removeOrg(o)"><KBIcon name="close" :size="13" /></button>
    </div>
    <div v-if="draft !== null" class="kbpc-add">
      <select v-model="draft" class="kbpc-select" aria-label="Codebase">
        <option v-for="c in linkable" :key="c.id" :value="c.id">{{ c.title }}</option>
        <option v-if="adds" :value="NEW">Another: a repository, folder or organization…</option>
      </select>
      <input v-if="draft === NEW" v-model="address" class="kbpc-new" aria-label="A repository's address, a folder or an organization"
             :placeholder="hint" @keydown.enter="save" />
      <label v-if="isOrg" class="kbpc-forks"><input v-model="forks" type="checkbox" /> with forks</label>
      <button class="kbpc-small" :disabled="busy || (draft === NEW && !address.trim()) || !draft" @click="save">{{ isOrg ? 'Link its repositories' : 'Link' }}</button>
      <button class="kbpc-small" @click="draft = null">Cancel</button>
    </div>
    <p v-if="error" class="kbpc-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbpc { display: flex; flex-wrap: wrap; gap: 0.4rem 0.5rem; align-items: baseline; margin-top: 0.5rem; font-size: 0.85rem; }
.kbpc-label { font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); margin-right: 0.3rem; }
.kbpc-icon { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border-radius: 6px;
             border: none; background: none; cursor: pointer; color: var(--vp-c-text-2); align-self: center; }
.kbpc-icon:hover { background: var(--vp-c-default-soft); }
.kbpc-select, .kbpc-new { padding: 0.3rem 0.5rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
                          background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font: inherit; }
.kbpc-small { display: inline-flex; align-items: center; gap: 0.2rem; padding: 0.15rem 0.55rem; border-radius: 6px; cursor: pointer;
              border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.8rem; }
.kbpc-small:hover:not(:disabled) { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbpc-small:disabled { opacity: 0.5; cursor: default; }
@media (max-width: 640px) { .kbpc-icon { width: 40px; height: 40px; } .kbpc-new { min-width: 0; } }
.kbpc-list { display: contents; list-style: none; }
.kbpc-item { display: inline-flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; margin: 0; padding: 0.1rem 0.45rem;
             border: 1px solid var(--vp-c-divider); border-radius: 6px; }
.kbpc-item.main { border-color: var(--vp-c-brand-soft); }
.kbpc-item.faded > a:first-of-type { color: var(--vp-c-text-2); }
.kbpc-item code { font-size: 0.75rem; }
.kbpc-dim { font-size: 0.8rem; }
.kbpc-star, .kbpc-x { display: inline-flex; align-self: center; padding: 1px; border-radius: 4px; color: var(--vp-c-text-3); }
.kbpc-star:hover { color: var(--vp-c-brand-1); }
.kbpc-star.on { color: var(--vp-c-brand-1); }
.kbpc-x:hover { color: var(--vp-c-danger-1); background: var(--vp-c-danger-soft); }
.kbpc-mark { font-size: 0.75rem; color: var(--vp-c-warning-1); }
.kbpc-more { font-size: 0.8rem; }
.kbpc-org { flex-basis: 100%; display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; }
.kbpc-problem { font-size: 0.75rem; color: var(--vp-c-danger-1); max-width: 30rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbpc-add { flex-basis: 100%; display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; }
.kbpc-new { min-width: 18rem; flex: 1; font-size: 0.85rem; }
.kbpc-forks { font-size: 0.8rem; display: inline-flex; gap: 0.25rem; align-items: center; }
.kbpc-error { flex-basis: 100%; margin: 0; font-size: 0.8rem; color: var(--vp-c-danger-1); }
</style>
