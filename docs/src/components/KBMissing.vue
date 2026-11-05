<!--
  The works the knowledge base's papers cite and it does not hold (missing.json, written with the
  site), most cited first, each with the papers citing it. One on arXiv can be added from here when
  zemi is serving the knowledge base API.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted, watch } from 'vue'
import { mode, connect, post, followJobs, finishedJobs, blockers, liveOrSite, recordPapers } from './kbApi'
import { paperHref } from './kbLinks'
import KBJobs from './KBJobs.vue'

type Citing = { id: string; slug: string; title: string }
type Work = { key: string; arxiv: string | null; doi: string | null; text: string; cited_by: Citing[] }
const works = ref<Work[]>([])
const kind = ref<'all' | 'arxiv' | 'doi' | 'ref'>('all')
const shown = ref(40)
const added = ref(new Set<string>())
const error = ref('')
const cannot = computed(() => blockers('ingest', ['paper']))

// From the knowledge base API while zemi serves it (current, lookups included), else the list written
// with the site.
async function load() {
  try { works.value = await liveOrSite('/api/missing', '/missing.json'); error.value = '' }
  catch (e: any) { error.value = `Load failed: ${e.message ?? e}` }
}
onMounted(async () => { await connect(); load() })
watch(finishedJobs, () => load())

// A work found on arXiv counts as on arXiv whatever its citations were grouped by.
const kindOf = (w: Work) => w.arxiv ? 'arxiv' : w.doi ? 'doi' : 'ref'
const filtered = computed(() => works.value.filter(w => kind.value === 'all' || kindOf(w) === kind.value))
const counts = computed(() => ({
  arxiv: works.value.filter(w => w.arxiv).length, doi: works.value.filter(w => !w.arxiv && w.doi).length,
  ref: works.value.filter(w => !w.arxiv && !w.doi).length }))

const tabs = computed(() => [
  { kind: 'all' as const, label: `All ${works.value.length}` },
  { kind: 'arxiv' as const, label: `On arXiv ${counts.value.arxiv}` },
  { kind: 'doi' as const, label: `By DOI ${counts.value.doi}` },
  { kind: 'ref' as const, label: `No id ${counts.value.ref}` }])

// Works cited only by DOI may be on arXiv: OpenAlex is asked, and the list loaded again with what it says.
const finding = ref(false)
async function find() {
  error.value = ''; finding.value = true
  try { await followJobs((await post('/api/missing/find', '{}')).job) }
  catch (e: any) { error.value = e.message ?? String(e) }
  finally { finding.value = false }
}

// Works on arXiv are added as recorded papers: their arXiv record and abstract, found by search and
// placed in the landscape. Reading one in full is a separate step (a sync reading unread papers, or Manage).
const canAdd = computed(() => mode.value === 'live' && !cannot.value.length)
const addable = computed(() => filtered.value.filter(w => w.arxiv && !added.value.has(w.key)))

async function add(ws: Work[]) {
  ws = ws.filter(w => w.arxiv && !added.value.has(w.key))
  if (!ws.length) return
  error.value = ''
  try {
    await recordPapers(ws.map(w => w.arxiv!), 'cited')
    added.value = new Set([...added.value, ...ws.map(w => w.key)])
  } catch (e: any) { error.value = e.message ?? String(e) }
}
</script>

<template>
  <div class="kbmi">
    <p v-if="error" class="kb-error">{{ error }}</p>
    <div class="kbmi-filter">
      <button v-for="t in tabs" :key="t.kind" type="button"
              :class="['kb-pill', { on: kind === t.kind }]" @click="kind = t.kind; shown = 40">{{ t.label }}</button>
    </div>
    <p v-if="kind === 'doi' && mode === 'live'" class="kb-dim kbmi-dim">
      <button type="button" class="kb-outline" :disabled="finding" @click="find">{{ finding ? 'Searching…' : 'Find on arXiv' }}</button>
    </p>
    <div v-if="canAdd && addable.length" class="kbmi-bar">
      <button type="button" class="kb-outline" @click="add(addable)">Add {{ addable.length }}</button>
      <span>Added as abstract only.</span>
    </div>
    <div v-for="w in filtered.slice(0, shown)" :key="w.key" class="kbmi-work">
      <div class="kbmi-head">
        <span class="kbmi-count" :title="`cited by ${w.cited_by.length} papers here`">{{ w.cited_by.length }}</span>
        <span class="kbmi-text">{{ w.text }}</span>
      </div>
      <div class="kbmi-links">
        <a v-if="w.arxiv" :href="`https://arxiv.org/abs/${w.arxiv}`" target="_blank" rel="noopener">arXiv:{{ w.arxiv }}</a>
        <a v-if="w.doi" :href="`https://doi.org/${w.doi}`" target="_blank" rel="noopener">doi:{{ w.doi }}</a>
        <button v-if="w.arxiv && canAdd" type="button" class="kb-outline"
                :disabled="added.has(w.key)" @click="add([w])">{{ added.has(w.key) ? 'Added' : 'Add' }}</button>
      </div>
      <div class="kbmi-cited">cited by
        <template v-for="(c, i) in w.cited_by" :key="c.id"><span v-if="i">, </span><a :href="paperHref(c.slug)"><KBTitle :text="c.title" /></a></template>
      </div>
    </div>
    <button v-if="filtered.length > shown" type="button" class="kb-link" @click="shown += 40">show more ({{ filtered.length - shown }} left)</button>
    <KBJobs v-if="mode === 'live'" />
  </div>
</template>

<style scoped>
.kbmi { margin: 1rem 0 2rem; }
.kbmi-filter { display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 1rem; }
.kbmi-work { padding: 0.7rem 0; border-bottom: 1px solid var(--vp-c-divider); }
.kbmi-head { display: flex; gap: 0.7rem; align-items: baseline; }
.kbmi-count { flex: none; min-width: 1.8rem; text-align: center; font-weight: 700; color: var(--vp-c-brand-1); }
.kbmi-text { font-size: 0.92rem; }
.kbmi-links, .kbmi-cited { margin-left: 2.5rem; font-size: 0.82rem; color: var(--vp-c-text-2); }
.kbmi-bar { display: flex; gap: 1.2rem; align-items: center; margin-bottom: 0.6rem; font-size: 0.88rem; color: var(--vp-c-text-2); }
.kbmi-links { display: flex; gap: 0.9rem; align-items: center; margin-top: 0.2rem; }
.kbmi-dim { font-size: 0.88rem; }
.kb-link { padding: 0.5rem 0; }
</style>
