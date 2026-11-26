<!--
  A GitHub organization listed for a project (on its board) or for the knowledge base itself (on the
  Codebases page, `library`), and its repositories to choose from (see list_org! in
  src/project_codebases.jl). Those ticked are taken: linked as the project's codebases, or added to the
  knowledge base, and read. For a project, one unticked is unlinked and declined, so a later listing
  does not link it again; the knowledge base's own are dropped on the Documents page instead. Declining
  a candidate not taken keeps it out the same way. Forks and archived repositories wait behind their
  switches unless taken. With "take new ones", the repositories the organization gains are taken as
  they appear. Each change is sent as `act` with what the organization routes take (see org_request!
  in src/task_api.jl).
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { when } from './kbFormat'
import KBIcon from './KBIcon.vue'

export type OrgRepository = { name: string; remote: string; fork: boolean; archived: boolean; gone: boolean; declined: boolean
                              new: boolean; codebase: string }
export type ProjectOrg = { host: string; owner: string; forks: boolean; auto: boolean; listed_at: string; problem: string
                           repositories: OrgRepository[] }

const props = defineProps<{ org: ProjectOrg; manages: boolean; busy: boolean; open?: boolean; library?: boolean }>()
const emit = defineEmits<{ act: [body: Record<string, unknown>, done?: () => void] }>()

const verb = computed(() => props.library ? 'added' : 'linked')
const choosing = ref(!!props.open)
watch(() => props.open, o => { if (o) choosing.value = true })
const filter = ref('')
const withForks = ref(false)
const withArchived = ref(false)
// What is ticked, by repository: those taken start ticked.
const ticked = ref(new Set<string>())
const reset = () => { ticked.value = new Set(props.org.repositories.filter(r => r.codebase).map(r => r.remote)) }
watch(() => props.org.repositories, reset, { immediate: true })

const address = (r: OrgRepository) => r.remote.replace(/\.git$/, '')
const taken = computed(() => props.org.repositories.filter(r => r.codebase).length)
const fresh = computed(() => props.org.repositories.filter(r => r.new).length)
const shown = computed(() => {
  const q = filter.value.trim().toLowerCase()
  return props.org.repositories.filter(r => (r.codebase || ((withForks.value || !r.fork) && (withArchived.value || !r.archived))) &&
                                            (!q || r.name.toLowerCase().includes(q)))
})
// The knowledge base's own codebases are not taken back here: they are dropped on the Documents page.
const fixed = (r: OrgRepository) => !!props.library && !!r.codebase
const toTake = computed(() => props.org.repositories.filter(r => ticked.value.has(r.remote) && !r.codebase).map(r => r.remote))
const toUntake = computed(() => props.org.repositories.filter(r => !ticked.value.has(r.remote) && r.codebase && !fixed(r)).map(r => r.codebase))
const tick = (r: OrgRepository, on: boolean) => { const t = new Set(ticked.value); on ? t.add(r.remote) : t.delete(r.remote); ticked.value = t }
const tickShown = (on: boolean) => {
  const t = new Set(ticked.value)
  for (const r of shown.value) if (!fixed(r)) on ? t.add(r.remote) : t.delete(r.remote)
  ticked.value = t
}
const marks = (r: OrgRepository) => [r.new && 'new', r.fork && 'fork', r.archived && 'archived', r.gone && 'gone', r.declined && 'declined']
  .filter(Boolean) as string[]
const summary = computed(() => {
  const take = toTake.value.length, untake = toUntake.value.length
  return [take && `${props.library ? 'Add' : 'Link'} ${take}`, untake && `unlink ${untake}`].filter(Boolean).join(', ') || 'Nothing to change'
})

function apply() {
  const n = toUntake.value.length
  if (n && !confirm(`Unlink ${n} codebase${n === 1 ? '' : 's'}? Their commits stop being recorded against the project's tasks.`)) return
  emit('act', { take: toTake.value, untake: toUntake.value }, () => { choosing.value = false })
}
const name = computed(() => `${props.org.host}/${props.org.owner}`)
const decline = (r: OrgRepository, on: boolean) => emit('act', on ? { decline: [r.remote] } : { undecline: [r.remote] })
const settings = (s: { auto?: boolean; forks?: boolean }) => emit('act', { auto: props.org.auto, forks: props.org.forks, ...s })
const stop = () => confirm(`Stop listing ${name.value}'s repositories? Those ${verb.value} stay.`) && emit('act', { remove: true })
</script>

<template>
  <div class="kbor">
    <div class="kbor-head">
      <span class="kb-dim">Repositories of</span>
      <a :href="`https://${name}`" target="_blank" rel="noopener">{{ name }}</a>
      <span class="kb-dim kbor-dim">{{ taken }} of {{ org.repositories.length }} {{ verb }}</span>
      <span v-if="fresh" class="kbor-new">{{ fresh }} new</span>
      <span class="kb-dim kbor-dim" :title="org.listed_at">{{ org.listed_at ? `listed ${when(org.listed_at)}` : 'not listed yet' }}</span>
      <span v-if="org.auto" class="kb-dim kbor-dim">· new ones {{ verb }} as they appear</span>
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
        <button class="kb-link kbor-link" :disabled="busy" @click="settings({})">list again</button>
      </div>
      <ul class="kbor-list">
        <li v-for="r in shown" :key="r.remote" :class="{ faded: r.declined || r.gone || r.archived }">
          <label>
            <input type="checkbox" :checked="ticked.has(r.remote)" :disabled="fixed(r)" :title="fixed(r) ? 'In the knowledge base: dropped on the Documents page' : ''"
                   @change="tick(r, ($event.target as HTMLInputElement).checked)" />
            {{ r.name }}
          </label>
          <span v-for="m in marks(r)" :key="m" class="kbor-mark" :class="m">{{ m }}</span>
          <button v-if="!r.codebase" class="kb-link kbor-link kbor-decline" :disabled="busy"
                  :title="r.declined ? 'Offer it again' : 'Keep it out: not taken by itself, nor marked new'"
                  @click="decline(r, !r.declined)">{{ r.declined ? 'undecline' : 'decline' }}</button>
          <a :href="address(r)" target="_blank" rel="noopener" class="kb-dim kbor-dim" :aria-label="`${r.name} on GitHub`"><KBIcon name="open" :size="12" /></a>
        </li>
        <li v-if="!shown.length" class="kb-dim">No repositories{{ filter ? ' match' : '' }}.</li>
      </ul>
      <div class="kbor-actions">
        <button class="kbor-small" :disabled="busy || (!toTake.length && !toUntake.length)" @click="apply">{{ summary }}</button>
        <label class="kbor-auto"><input type="checkbox" :checked="org.auto" :disabled="busy"
               @change="settings({ auto: ($event.target as HTMLInputElement).checked })" /> {{ library ? 'add' : 'link' }} new ones as they appear</label>
        <label v-if="org.auto" class="kbor-auto"><input type="checkbox" :checked="org.forks" :disabled="busy"
               @change="settings({ forks: ($event.target as HTMLInputElement).checked })" /> forks too</label>
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
.kbor-decline { font-size: 0.72rem; opacity: 0; }
.kbor-list li:hover .kbor-decline, .kbor-decline:focus-visible, .kbor-list li.faded .kbor-decline { opacity: 1; }
@media (hover: none) { .kbor-decline { opacity: 1; } }
.kbor-mark { font-size: 0.7rem; padding: 0 0.3rem; border-radius: 4px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbor-mark.new { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbor-mark.gone, .kbor-mark.archived { color: var(--vp-c-warning-1); }
@media (max-width: 640px) { .kbor-filter { min-width: 0; flex: 1; } }
</style>
