<!--
  New arXiv papers in the watched categories (the knowledge base API's /api/watch while zemi serves it,
  else watch.json, written with the site), best placed first, each with the focus area it fits and the
  library papers nearest it. Any can be added (recorded) from here, one at a time or as shown.
  Above them, the papers the watch took in by their rating (see `take_watched!`): read in full or
  recorded, with the judge's reason; one recorded can be read in full, and any removed.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted, watch } from 'vue'
import { mode, connect, post, followJobs, finishedJobs, blockers, can, liveOrSite, recordPapers } from './kbApi'
import { paperHref } from './kbLinks'
import { RELEVANCE } from './kbLabels'
import { day, when, byline } from './kbFormat'
import KBJobs from './KBJobs.vue'

type Near = { id: string; slug: string; title: string; score: number }
type Paper = { id: string; title: string; authors: string[]; abstract: string; published: string; category: string;
               score: number; area: string; area_score: number; nearest: Near[]; relevance: number | null; reason: string }
type Taken = { id: string; slug: string; title: string; relevance: number; reason: string; taken: string; taken_at: string; read: boolean }
type Watch = { checked: string | null; categories: string[]; days: number; papers: Paper[]; taken?: Taken[] }
const data = ref<Watch | null>(null)
const area = ref('')
const shown = ref(25)
const open = ref(new Set<string>())
const added = ref(new Set<string>())
const checking = ref(false)
const error = ref('')
const cannot = computed(() => blockers('ingest', ['paper']))
const canAdd = computed(() => mode.value === 'live' && !cannot.value.length)

async function load() {
  try { data.value = await liveOrSite('/api/watch', '/watch.json'); error.value = '' }
  catch (e: any) { error.value = `Load failed: ${e.message ?? e}` }
}
onMounted(async () => { await connect(); load() })
watch(finishedJobs, () => load())

// Those the judge rated related (2) or central (3) to the group's work, most relevant first.
const promoted = computed(() => (data.value?.papers ?? []).filter(p => (p.relevance ?? 0) >= 2)
  .sort((a, b) => (b.relevance ?? 0) - (a.relevance ?? 0) || b.score - a.score))
const areas = computed(() => [...new Set((data.value?.papers ?? []).map(p => p.area))].sort())
const filtered = computed(() => (data.value?.papers ?? []).filter(p => !area.value || p.area === area.value))
const visible = computed(() => filtered.value.slice(0, shown.value))
const addable = computed(() => visible.value.filter(p => !added.value.has(p.id)))
function toggle(id: string) {
  const s = new Set(open.value); s.has(id) ? s.delete(id) : s.add(id); open.value = s
}

async function check() {
  error.value = ''; checking.value = true
  try { await followJobs((await post('/api/watch/check', '{}')).job) }
  catch (e: any) { error.value = e.message ?? String(e) }
  finally { checking.value = false }
}

const taken = computed(() => data.value?.taken ?? [])
const manages = computed(() => mode.value === 'live' && can('paper.manage'))
const acting = ref(new Set<string>())
// Read a recorded paper in full, or drop one the watch took in: removed, and kept out.
async function act(action: 'ingest' | 'drop', t: Taken) {
  if (action === 'drop' && !confirm(`Drop "${t.title}"? It is removed from the knowledge base and kept out.`)) return
  error.value = ''; acting.value = new Set([...acting.value, t.id])
  try { await followJobs((await post('/api/actions', JSON.stringify({ action, ids: [t.id] }))).job) }
  catch (e: any) { error.value = e.message ?? String(e) }
  finally { const s = new Set(acting.value); s.delete(t.id); acting.value = s; load() }
}

// Added papers are recorded, as from the missing papers: read in full later, by a sync or Manage.
async function add(ps: Paper[]) {
  ps = ps.filter(p => !added.value.has(p.id))
  if (!ps.length) return
  error.value = ''
  try {
    await recordPapers(ps.map(p => p.id), 'watch')
    added.value = new Set([...added.value, ...ps.map(p => p.id)])
  } catch (e: any) { error.value = e.message ?? String(e) }
}
</script>

<template>
  <div class="kbw">
    <p v-if="error" class="kb-error">{{ error }}</p>
    <p v-if="data" class="kbw-dim">
      Watching {{ data.categories.join(', ') }} (last {{ data.days }} days) · checked {{ when(data.checked, 'not yet') }}
      <button v-if="mode === 'live'" type="button" class="kb-outline kbw-add" :disabled="checking" @click="check">{{ checking ? 'Checking…' : 'Check now' }}</button>
    </p>
    <div v-if="taken.length" class="kbw-promoted kbw-taken">
      <h3>Taken in by the watch</h3>
      <div v-for="t in taken" :key="t.id" class="kbw-pick">
        <span :class="['kbw-rel', { central: t.relevance === 3 }]">{{ RELEVANCE[t.relevance] }}</span>
        <div>
          <a :href="paperHref(t.slug)" class="kbw-title"><KBTitle :text="t.title" /></a>
          <span class="kbw-meta"> · {{ t.read ? 'read in full' : 'recorded' }} · {{ day(t.taken_at) }}</span>
          <template v-if="manages">
            <button v-if="!t.read" type="button" class="kb-outline kbw-add" :disabled="acting.has(t.id)" @click="act('ingest', t)">Read in full</button>
            <button type="button" class="kb-outline kbw-add" :disabled="acting.has(t.id)" @click="act('drop', t)">Drop</button>
          </template>
          <div class="kbw-reason">{{ t.reason }}</div>
        </div>
      </div>
    </div>
    <div v-if="promoted.length" class="kbw-promoted">
      <h3>Worth reading</h3>
      <div v-for="p in promoted" :key="p.id" class="kbw-pick">
        <span :class="['kbw-rel', { central: p.relevance === 3 }]">{{ RELEVANCE[p.relevance ?? 0] }}</span>
        <div>
          <a :href="`https://arxiv.org/abs/${p.id}`" target="_blank" rel="noopener" class="kbw-title"><KBTitle :text="p.title" /></a>
          <span class="kbw-meta"> · {{ p.area }}</span>
          <button v-if="canAdd" type="button" class="kb-outline kbw-add" :disabled="added.has(p.id)" @click="add([p])">{{ added.has(p.id) ? 'Added' : 'Add' }}</button>
          <div class="kbw-reason">{{ p.reason }}</div>
        </div>
      </div>
    </div>
    <div v-if="areas.length" class="kbw-filter">
      <button type="button" :class="['kb-pill', { on: !area }]" @click="area = ''; shown = 25">All {{ data?.papers.length }}</button>
      <button v-for="a in areas" :key="a" type="button" :class="['kb-pill', { on: area === a }]" @click="area = a; shown = 25">
        {{ a }} {{ (data?.papers ?? []).filter(p => p.area === a).length }}</button>
    </div>
    <div v-if="canAdd && addable.length" class="kbw-bar">
      <button type="button" class="kb-outline kbw-add" @click="add(addable)">Add the {{ addable.length }} shown</button>
      <span>Added as abstract only.</span>
    </div>
    <p v-if="data && !data.papers.length" class="kbw-dim">{{ data.checked ? 'Nothing new.' : 'Not checked yet.' }}</p>
    <div v-for="p in visible" :key="p.id" class="kbw-paper">
      <div class="kbw-head">
        <span class="kbw-score" :title="`${p.area} ${p.area_score.toFixed(2)} · nearest paper ${(p.nearest[0]?.score ?? 0).toFixed(2)}`">{{ p.score.toFixed(2) }}</span>
        <div>
          <a :href="`https://arxiv.org/abs/${p.id}`" target="_blank" rel="noopener" class="kbw-title"><KBTitle :text="p.title" /></a>
          <div class="kbw-meta">{{ byline(p.authors, 4) }} · {{ p.published }} · {{ p.category }}
            · <span class="kbw-area">{{ p.area }}</span>
            <button type="button" class="kb-link" @click="toggle(p.id)">{{ open.has(p.id) ? 'hide abstract' : 'abstract' }}</button>
            <button v-if="canAdd" type="button" class="kb-outline kbw-add" :disabled="added.has(p.id)" @click="add([p])">{{ added.has(p.id) ? 'Added' : 'Add' }}</button>
          </div>
          <p v-if="open.has(p.id)" class="kbw-abstract">{{ p.abstract }}</p>
          <div v-if="p.nearest.length" class="kbw-near">similar:
            <template v-for="(n, i) in p.nearest" :key="n.id"><span v-if="i">, </span><a :href="paperHref(n.slug)"><KBTitle :text="n.title" /></a></template>
          </div>
        </div>
      </div>
    </div>
    <button v-if="filtered.length > shown" type="button" class="kb-link" @click="shown += 25">show more ({{ filtered.length - shown }} left)</button>
    <KBJobs v-if="mode === 'live'" />
  </div>
</template>

<style scoped>
.kbw { margin: 1rem 0 2rem; }
.kbw-dim, .kbw-bar { color: var(--vp-c-text-2); font-size: 0.88rem; }
.kbw-bar { display: flex; gap: 1rem; align-items: center; margin-bottom: 0.6rem; }
.kbw-filter { display: flex; gap: 0.5rem; flex-wrap: wrap; margin: 0.8rem 0; }
.kbw-paper { padding: 0.7rem 0; border-bottom: 1px solid var(--vp-c-divider); }
.kbw-head { display: flex; gap: 0.8rem; align-items: baseline; }
.kbw-score { flex: none; min-width: 2.4rem; text-align: right; font-weight: 700; color: var(--vp-c-brand-1); }
.kbw-title { font-weight: 600; }
.kbw-meta, .kbw-near { font-size: 0.82rem; color: var(--vp-c-text-2); display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; }
.kbw-near { display: block; margin-top: 0.2rem; }
.kbw-area { color: var(--vp-c-brand-1); }
.kbw-abstract { font-size: 0.88rem; margin: 0.4rem 0; }
.kbw-promoted { margin: 1rem 0 1.5rem; padding: 0.4rem 1rem 0.8rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbw-promoted h3 { margin: 0.6rem 0; }
.kbw-pick { display: flex; gap: 0.8rem; align-items: baseline; padding: 0.4rem 0; }
.kbw-rel { flex: none; font-size: 0.75rem; padding: 0 0.5rem; border-radius: 999px; border: 1px solid var(--vp-c-divider); color: var(--vp-c-text-2); }
.kbw-rel.central { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kbw-reason { font-size: 0.86rem; color: var(--vp-c-text-2); }
.kbw-add { font-size: 0.85rem; }
</style>
