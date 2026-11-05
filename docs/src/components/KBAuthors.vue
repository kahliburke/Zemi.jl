<!--
  The knowledge base's authors (authors.json, written with the site): found by any words of their
  names, each with their papers here and the co-authors they share most. `?a=<key>` in the address
  opens one, as the names on the papers' pages do.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted } from 'vue'
import { paperHref, authorHref } from './kbLinks'
import { siteJSON } from './kbApi'
import { loadPapers, type Paper } from './kbData'
import { plural } from './kbFormat'

type Co = { key: string; name: string; count: number }
type Author = { key: string; name: string; variants: string[]; papers: string[]; coauthors: Co[] }
const people = ref<Author[]>([])
const papers = ref<Record<string, Readonly<Paper>>>({})
const query = ref('')
const picked = ref<string | null>(null)
const error = ref('')
const SHOWN = 40

onMounted(async () => {
  try {
    const [a, p] = await Promise.all([siteJSON('/authors.json'), loadPapers()])
    people.value = a
    papers.value = Object.fromEntries(p.map(x => [x.id, x]))
    picked.value = new URLSearchParams(location.search).get('a')
  } catch (e: any) { error.value = `Load failed: ${e.message ?? e}` }
})

// Every word typed begins a word of one of the names the author is written under.
const words = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().split(/[^\p{L}\p{N}'-]+/u).filter(Boolean)
const matches = (a: Author, q: string[]) => a.variants.some(v => { const w = words(v); return q.every(x => w.some(y => y.startsWith(x))) })
const found = computed(() => {
  const q = words(query.value)
  return (q.length ? people.value.filter(a => matches(a, q)) : people.value).slice(0, SHOWN)
})
const person = computed(() => people.value.find(a => a.key === picked.value) ?? null)
const theirs = computed(() => (person.value?.papers ?? []).map(id => papers.value[id]).filter(Boolean))

function close() {
  picked.value = null
  history.replaceState(null, '', location.pathname)
}
function open(key: string) {
  picked.value = key
  history.replaceState(null, '', `?a=${encodeURIComponent(key)}`)
  window.scrollTo({ top: 0 })
}
</script>

<template>
  <div class="kba">
    <p v-if="error" class="kb-error kba-error">{{ error }}</p>
    <div v-if="person" class="kba-person">
      <h2>{{ person.name }}</h2>
      <p v-if="person.variants.length > 1" class="kb-dim kba-dim">Also: {{ person.variants.filter(v => v !== person!.name).join(' · ') }}</p>
      <p class="kb-dim kba-dim">{{ plural(person.papers.length, 'paper') }} here</p>
      <ul class="kba-papers">
        <li v-for="p in theirs" :key="p.id">
          <a :href="paperHref(p.slug)"><KBTitle :text="p.title" /></a>
          <span class="kb-dim kba-dim"> · {{ p.published }}</span>
        </li>
      </ul>
      <p v-if="person.coauthors.length" class="kba-co">Co-authors:
        <template v-for="(c, i) in person.coauthors" :key="c.key"><span v-if="i">, </span><a :href="authorHref(c.key)" @click.prevent="open(c.key)">{{ c.name }}</a><span class="kb-dim kba-dim"> ({{ c.count }})</span></template>
      </p>
      <button type="button" class="kb-link kba-link" @click="close">all authors</button>
    </div>
    <input v-model="query" type="search" class="kb-field kba-input" placeholder="Find author…" />
    <p class="kb-dim kba-dim">{{ people.length }} authors{{ query ? ` · ${found.length < SHOWN ? found.length : SHOWN + '+'} matches` : '' }}</p>
    <ul class="kba-list">
      <li v-for="a in found" :key="a.key">
        <a :href="authorHref(a.key)" @click.prevent="open(a.key)">{{ a.name }}</a>
        <span class="kb-dim kba-dim"> · {{ a.papers.length }}</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.kba { margin: 1rem 0 2rem; }
.kba-person { padding: 0.2rem 1rem 0.8rem; margin-bottom: 1.5rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kba-person h2 { margin-top: 0.8rem; border-top: none; padding-top: 0; }
.kba-papers { margin: 0.6rem 0; }
.kba-co { font-size: 0.9rem; }
.kba-input { display: block; width: 100%; box-sizing: border-box; padding: 0.5rem 0.7rem; border-radius: 8px; }
.kba-list { columns: 3 14rem; margin-top: 0.6rem; padding-left: 1.1rem; }
.kba-list li { break-inside: avoid; }
.kba-dim { font-size: 0.88rem; }
</style>
