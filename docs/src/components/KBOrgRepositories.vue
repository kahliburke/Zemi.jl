<!--
  On a project's board, under its codebases: a GitHub organization the project lists, and its
  repositories to choose from (see list_org! in src/project_codebases.jl). Those ticked are linked as
  the project's codebases and read; one unticked is unlinked and declined, so a later listing does not
  link it again. Forks and archived repositories wait behind their switches unless linked. With "link
  new ones", the repositories the organization gains are linked as they appear.
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { when } from './kbFormat'
import KBIcon from './KBIcon.vue'

export type OrgRepository = { name: string; remote: string; fork: boolean; archived: boolean; gone: boolean; declined: boolean
                              new: boolean; codebase: string }
export type ProjectOrg = { host: string; owner: string; forks: boolean; auto: boolean; listed_at: string; problem: string
                           repositories: OrgRepository[] }

const props = defineProps<{ org: ProjectOrg; manages: boolean; busy: boolean; open?: boolean }>()
const emit = defineEmits<{ send: [body: Record<string, unknown>, done?: () => void] }>()

const choosing = ref(!!props.open)
const filter = ref('')
const withForks = ref(false)
const withArchived = ref(false)
// What is ticked, by repository: linked ones start ticked.
const ticked = ref(new Set<string>())
const reset = () => { ticked.value = new Set(props.org.repositories.filter(r => r.codebase).map(r => r.remote)) }
watch(() => props.org.repositories, reset, { immediate: true })

const address = (r: OrgRepository) => r.remote.replace(/\.git$/, '')
const linked = computed(() => props.org.repositories.filter(r => r.codebase).length)
const fresh = computed(() => props.org.repositories.filter(r => r.new).length)
const shown = computed(() => {
  const q = filter.value.trim().toLowerCase()
  return props.org.repositories.filter(r => (r.codebase || ((withForks.value || !r.fork) && (withArchived.value || !r.archived))) &&
                                            (!q || r.name.toLowerCase().includes(q)))
})
const toLink = computed(() => props.org.repositories.filter(r => ticked.value.has(r.remote) && !r.codebase).map(r => r.remote))
const toUnlink = computed(() => props.org.repositories.filter(r => !ticked.value.has(r.remote) && r.codebase).map(r => r.codebase))
const tick = (r: OrgRepository, on: boolean) => { const t = new Set(ticked.value); on ? t.add(r.remote) : t.delete(r.remote); ticked.value = t }
const tickShown = (on: boolean) => { const t = new Set(ticked.value); for (const r of shown.value) on ? t.add(r.remote) : t.delete(r.remote); ticked.value = t }
const marks = (r: OrgRepository) => [r.new && 'new', r.fork && 'fork', r.archived && 'archived', r.gone && 'gone', r.declined && 'declined']
  .filter(Boolean) as string[]
const summary = computed(() => {
  const unlinking = toUnlink.value.length
  return [toLink.value.length && `Link ${toLink.value.length}`, unlinking && `unlink ${unlinking}`].filter(Boolean).join(', ') || 'Nothing to change'
})

function apply() {
  const n = toUnlink.value.length
  if (n && !confirm(`Unlink ${n} codebase${n === 1 ? '' : 's'}? Their commits stop being recorded against the project's tasks.`)) return
  const unlink = () => n ? emit('send', { codebases: toUnlink.value, remove: true }, () => { choosing.value = false }) : (choosing.value = false)
  toLink.value.length ? emit('send', { codebases: toLink.value }, unlink) : unlink()
}
const name = computed(() => `${props.org.host}/${props.org.owner}`)
const setAuto = (auto: boolean) => emit('send', { codebase: name.value, auto, forks: props.org.forks })
const setForks = (forks: boolean) => emit('send', { codebase: name.value, auto: props.org.auto, forks })
const relist = () => emit('send', { codebase: name.value, auto: props.org.auto, forks: props.org.forks })
const stop = () => confirm(`Stop listing ${name.value}'s repositories? Those linked stay linked.`) && emit('send', { codebase: name.value, remove: true })
</script>

<template>
  <div class="kbor">
    <div class="kbor-head">
      <span class="kb-dim">Repositories of</span>
      <a :href="`https://${name}`" target="_blank" rel="noopener">{{ name }}</a>
      <span class="kb-dim kbor-dim">{{ linked }} of {{ org.repositories.length }} linked</span>
      <span v-if="fresh" class="kbor-new">{{ fresh }} new</span>
      <span class="kb-dim kbor-dim" :title="org.listed_at">{{ org.listed_at ? `listed ${when(org.listed_at)}` : 'not listed yet' }}</span>
      <span v-if="org.auto" class="kb-dim kbor-dim">· new ones linked as they appear</span>
      <span v-if="org.problem" class="kbor-problem" :title="org.problem">could not be listed: {{ org.problem }}</span>
      <button v-if="manages" class="kbor-small" :aria-expanded="choosing" @click="choosing = !choosing; reset()">{{ choosing ? 'Close' : 'Choose' }}</button>
      <button v-if="manages" class="kbor-x" :title="`Stop listing ${org.owner}`" :aria-label="`Stop listing ${org.owner}`" :disabled="busy"
              @click="stop"><KBIcon name="close" :size="13" /></button>
    </div>
    <div v-if="choosing && manages" class="kbor-pick">
      <div class="kbor-tools">
        <input v-model="filter" class="kbor-filter" placeholder="Filter by name" aria-label="Filter the repositories by name" />
        <label><input v-model="withForks" type="checkbox" /> forks</label>
        <label><input v-model="withArchived" type="checkbox" /> archived</label>
        <button class="kb-link kbor-link" @click="tickShown(true)">tick all shown</button>
        <button class="kb-link kbor-link" @click="tickShown(false)">untick all shown</button>
        <button class="kb-link kbor-link" :disabled="busy" @click="relist">list again</button>
      </div>
      <ul class="kbor-list">
        <li v-for="r in shown" :key="r.remote" :class="{ faded: r.declined || r.gone || r.archived }">
          <label>
            <input type="checkbox" :checked="ticked.has(r.remote)" @change="tick(r, ($event.target as HTMLInputElement).checked)" />
            {{ r.name }}
          </label>
          <span v-for="m in marks(r)" :key="m" class="kbor-mark" :class="m">{{ m }}</span>
          <a :href="address(r)" target="_blank" rel="noopener" class="kb-dim kbor-dim" :aria-label="`${r.name} on GitHub`"><KBIcon name="open" :size="12" /></a>
        </li>
        <li v-if="!shown.length" class="kb-dim">No repositories{{ filter ? ' match' : '' }}.</li>
      </ul>
      <div class="kbor-actions">
        <button class="kbor-small" :disabled="busy || (!toLink.length && !toUnlink.length)" @click="apply">{{ summary }}</button>
        <label class="kbor-auto"><input type="checkbox" :checked="org.auto" :disabled="busy"
               @change="setAuto(($event.target as HTMLInputElement).checked)" /> link new ones as they appear</label>
        <label v-if="org.auto" class="kbor-auto"><input type="checkbox" :checked="org.forks" :disabled="busy"
               @change="setForks(($event.target as HTMLInputElement).checked)" /> forks too</label>
      </div>
    </div>
  </div>
</template>

<style scoped>
.kbor { flex-basis: 100%; font-size: 0.85rem; }
.kbor-head { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; }
.kbor-dim { font-size: 0.8rem; }
.kbor-new { font-size: 0.75rem; color: var(--vp-c-brand-1); }
.kbor-problem { font-size: 0.75rem; color: var(--vp-c-danger-1); max-width: 30rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.kbor-small { display: inline-flex; align-items: center; padding: 0.1rem 0.5rem; border-radius: 6px; cursor: pointer; align-self: center;
              border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2); font: inherit; font-size: 0.8rem; }
.kbor-small:hover:not(:disabled) { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbor-small:disabled { opacity: 0.5; cursor: default; }
.kbor-x { display: inline-flex; align-self: center; padding: 1px; border-radius: 4px; color: var(--vp-c-text-3); }
.kbor-x:hover { color: var(--vp-c-danger-1); background: var(--vp-c-danger-soft); }
.kbor-pick { margin: 0.4rem 0 0.2rem; padding: 0.5rem 0.6rem; border: 1px solid var(--vp-c-divider); border-radius: 8px; }
.kbor-tools, .kbor-actions { display: flex; flex-wrap: wrap; gap: 0.4rem 0.8rem; align-items: center; font-size: 0.8rem; }
.kbor-tools label, .kbor-auto { display: inline-flex; gap: 0.25rem; align-items: center; color: var(--vp-c-text-2); }
.kbor-filter { padding: 0.2rem 0.45rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft);
               color: var(--vp-c-text-1); font: inherit; min-width: 12rem; }
.kbor-link { font-size: 0.8rem; }
.kbor-list { list-style: none; margin: 0.4rem 0; padding: 0; max-height: 18rem; overflow-y: auto;
             display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.15rem 0.8rem; }
.kbor-list li { display: flex; gap: 0.35rem; align-items: center; margin: 0; min-width: 0; }
.kbor-list li label { display: inline-flex; gap: 0.3rem; align-items: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
.kbor-list li.faded label { color: var(--vp-c-text-2); }
.kbor-mark { font-size: 0.7rem; padding: 0 0.3rem; border-radius: 4px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbor-mark.new { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbor-mark.gone, .kbor-mark.archived { color: var(--vp-c-warning-1); }
@media (max-width: 640px) { .kbor-filter { min-width: 0; flex: 1; } }
</style>
