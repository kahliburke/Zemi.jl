<script setup lang="ts">
import KBBylineOrcid from './KBBylineOrcid.vue'
import KBTitle from './KBTitle.vue'
import { ref, shallowRef, computed, onMounted, onBeforeUnmount, watch } from 'vue'
import { paperHref, authorHref } from './kbLinks'
import { connect, liveOrSite, shared, api, can } from './kbApi'
import { plural } from './kbFormat'
import { authorIndex, sharedPublications, identity, type Byline, type Publication } from './kbCoauthors'

const papers = shallowRef<Publication[]>([])
const index = computed(() => authorIndex(papers.value))
const query = ref('')
const picked = ref('')
const graph = ref(false)
const edge = ref('')
const page = ref(0)
const perPage = 8
const error = ref('')
const loading = ref(true)
function readAddress() {
  const p = new URLSearchParams(location.search)
  picked.value = p.get('a') ?? ''
  graph.value = p.get('view') === 'coauthors'
}
onMounted(async () => {
  readAddress()
  addEventListener('popstate', readAddress)
  try {
    await connect()
    papers.value = await liveOrSite('/api/author-publications', '/author-publications.json', 1)
  } catch (e: any) { error.value = 'Could not load the authors: ' + e.message }
  finally { loading.value = false }
})
onBeforeUnmount(() => removeEventListener('popstate', readAddress))

const words = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().split(/[^\p{L}\p{N}'-]+/u).filter(Boolean)
const found = computed(() => {
  const q = words(query.value)
  return [...index.value.people.values()].filter(p => [...p.names, p.orcid ?? ''].some(s => {
    const w = words(s)
    return q.every(x => w.some(y => y.startsWith(x)))
  })).sort((a, b) => b.papers.length - a.papers.length || a.name.localeCompare(b.name))
})
// Old paper pages link by surname and initial. Offer the candidates if that link is ambiguous.
const candidates = computed(() => [...(index.value.aliases.get(picked.value) ?? [])].map(id => index.value.people.get(id)!))
const person = computed(() => index.value.people.get(picked.value) ?? (candidates.value.length === 1 ? candidates.value[0] : null))
const links = computed(() => person.value ? sharedPublications(person.value, index.value.people) : [])
const shown = computed(() => links.value.slice(page.value * perPage, (page.value + 1) * perPage))
const selected = computed(() => links.value.find(l => l.person.id === edge.value))
watch([picked, graph], () => { edge.value = ''; page.value = 0 })
const href = (id: string, network: boolean) => authorHref(id) + (network ? '&view=coauthors' : '')
function navigate(id: string, network: boolean) {
  const url = id ? href(id, network) : location.pathname
  history.pushState(null, '', url)
  readAddress()
}
function follow(event: MouseEvent, id: string, network: boolean) {
  if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button !== 0) return
  event.preventDefault()
  navigate(id, network)
  window.scrollTo({ top: 0 })
}
function turn(step: number) { page.value += step; edge.value = '' }
function saved(paper: Publication, byline: Byline, orcid: string | null) {
  const changed = { ...byline, orcid }
  const updated = { ...paper, authors: paper.authors.map(a => a === byline ? changed : a) }
  papers.value = papers.value.map(p => p === paper ? updated : p)
  navigate(identity(changed), false)
}
const rowY = (i: number) => i * 52 + 26
const midY = computed(() => shown.value.length * 26)
</script>

<template>
  <section class="kba">
    <p v-if="error" class="kb-error">{{ error }}</p>
    <p v-else-if="loading" class="kb-dim">Loading authors…</p>
    <template v-else>
      <template v-if="picked">
        <button class="kb-link" @click="navigate('', false)">All authors</button>
        <div v-if="person" class="kba-profile">
          <h2>{{ person.name }}</h2>
          <a v-if="person.orcid" :href="person.orcid">{{ person.orcid }}</a>
          <p v-else class="kb-dim">Grouped by exact byline. Different people can publish under the same name.</p>
          <p v-if="person.names.size > 1" class="kb-dim">Also published as {{ [...person.names].filter(n => n !== person!.name).join(', ') }}</p>
          <div class="kba-switch">
            <span>{{ plural(person.papers.length, 'publication') }} in your corpus</span>
            <a class="vp-raw" :href="href(person.id, !graph)" @click="follow($event, person.id, !graph)">{{ graph ? 'View publications' : 'Explore co-publications' }}</a>
          </div>
          <template v-if="graph">
            <p v-if="!links.length">No coauthors on the publications in this corpus.</p>
            <template v-else>
              <p class="kb-dim">Select a link to see the shared publications, or a name to explore that author.</p>
              <div class="kba-graph" aria-label="Co-publication network">
                <strong class="kba-center">{{ person.name }}</strong>
                <svg :viewBox="'0 0 160 ' + shown.length * 52" preserveAspectRatio="none" aria-hidden="true" class="kba-lines">
                  <g v-for="(l, i) in shown" :key="l.person.id" :class="{ chosen: edge === l.person.id }" @click="edge = l.person.id">
                    <path :d="`M 0 ${midY} C 75 ${midY}, 70 ${rowY(i)}, 160 ${rowY(i)}`" />
                    <path class="hit" :d="`M 0 ${midY} C 75 ${midY}, 70 ${rowY(i)}, 160 ${rowY(i)}`" />
                  </g>
                </svg>
                <div class="kba-neighbours">
                  <div v-for="l in shown" :key="l.person.id" class="kba-row">
                    <button class="kba-count" :aria-pressed="edge === l.person.id"
                            :aria-label="`${plural(l.papers.length, 'shared publication')} with ${l.person.name}`"
                            @click="edge = l.person.id">{{ l.papers.length }}</button>
                    <a class="vp-raw" :href="href(l.person.id, true)" @click="follow($event, l.person.id, true)">{{ l.person.name }}
                      <small v-if="l.person.orcid">{{ l.person.orcid.split('/').pop() }}</small></a>
                  </div>
                </div>
              </div>
              <div v-if="links.length > perPage" class="kba-switch">
                <button :disabled="page === 0" @click="turn(-1)">Previous</button>
                {{ page * perPage + 1 }}–{{ page * perPage + shown.length }} of {{ links.length }} coauthors
                <button :disabled="(page + 1) * perPage >= links.length" @click="turn(1)">Next</button>
              </div>
              <h3 v-if="selected">Shared publications with {{ selected.person.name }}</h3>
            </template>
          </template>
          <ul v-if="!graph || selected" class="kba-papers">
            <li v-for="p in (graph ? selected!.papers : person.papers)" :key="p.id">
              <a :href="paperHref(p.id)"><KBTitle :text="p.title" /></a> <span class="kb-dim">{{ p.published }}</span>
              <template v-if="!graph && can('paper.manage')">
                <KBBylineOrcid v-for="a in p.authors.filter(a => identity(a) === person!.id)" :key="a.position"
                  :paper="p.id" :byline="a" @saved="orcid => saved(p, a, orcid)" />
              </template>
            </li>
          </ul>
          <p v-if="!graph && links.length">Co-authors:
            <template v-for="(l, i) in links.slice(0, perPage)" :key="l.person.id"><span v-if="i">, </span><a class="vp-raw" :href="href(l.person.id, false)" @click="follow($event, l.person.id, false)">{{ l.person.name }}</a> ({{ l.papers.length }})</template>
          </p>
          <p class="kb-dim kba-correction">For attribution corrections, contact
            <a v-if="shared" :href="api + '/privacy'">the instance administrator</a><span v-else>the instance administrator</span>
            with the publication and byline.</p>
        </div>
        <template v-else-if="candidates.length">
          <h2>Select an author byline</h2>
          <p>Several entries match this author link.</p>
          <ul><li v-for="p in candidates" :key="p.id"><a class="vp-raw" :href="href(p.id, graph)" @click="follow($event, p.id, graph)">{{ p.name }} · {{ p.orcid ?? 'Byline only' }}</a></li></ul>
        </template>
        <p v-else>No matching author in your corpus.</p>
      </template>
      <label for="kba-search">Find an author by name or ORCID</label>
      <input id="kba-search" v-model="query" type="search" class="kb-field kba-input" />
      <p class="kb-dim">{{ plural(found.length, 'author entry', 'author entries') }}<span v-if="found.length > 40"> · showing 40</span></p>
      <ul class="kba-list">
        <li v-for="p in found.slice(0, 40)" :key="p.id">
          <a class="vp-raw" :href="href(p.id, graph)" @click="follow($event, p.id, graph)">{{ p.name }}</a>
          <small>{{ p.orcid?.split('/').pop() }} · {{ p.papers.length }}</small>
        </li>
      </ul>
    </template>
  </section>
</template>

<style scoped>
.kba { margin: 1rem 0 2rem; }
.kba h2 { margin-top: 1rem; }
.kba-input { display: block; width: 100%; max-width: 36rem; margin: .4rem 0; }
.kba-switch, .kba-row { display: flex; align-items: center; gap: .8rem; }
.kba-switch { justify-content: space-between; flex-wrap: wrap; margin: 1rem 0; }
.kba-switch button:disabled { opacity: .45; }
.kba-graph { display: grid; grid-template-columns: minmax(0, 1fr) minmax(2rem, .8fr) minmax(0, 1.8fr); align-items: center;
  padding: 1rem; border: 1px solid var(--vp-c-divider); border-radius: 10px; background: var(--vp-c-bg-soft); }
.kba-center { padding: .7rem; text-align: center; border: 1px solid var(--vp-c-brand-1); border-radius: 8px; overflow-wrap: anywhere; }
.kba-lines { width: 100%; height: 100%; overflow: visible; }
.kba-lines path { fill: none; stroke: var(--vp-c-text-3); vector-effect: non-scaling-stroke; }
.kba-lines .chosen path { stroke: var(--vp-c-brand-1); stroke-width: 2; }
.kba-lines path.hit { stroke: transparent; stroke-width: 14; cursor: pointer; }
.kba-row { height: 52px; line-height: 1.15; gap: .45rem; }
.kba-row a { min-width: 0; overflow-wrap: anywhere; }
.kba-row small { display: block; font-size: .7rem; color: var(--vp-c-text-2); }
.kba-count { border: 1px solid var(--vp-c-divider); border-radius: 1rem; min-width: 2rem; padding: .2rem .4rem; background: var(--vp-c-bg); }
.kba-count[aria-pressed=true] { border-color: var(--vp-c-brand-1); color: var(--vp-c-brand-1); }
.kba-list { columns: 2 15rem; }
.kba-list li { break-inside: avoid; }
.kba-correction { margin: 1.25rem 0; font-size: .875rem; }
</style>
