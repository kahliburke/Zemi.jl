<!--
  A record's page, made from its data (see kbTemplates.ts and `record_page_json`), which the service
  sends only to those who may see it: where it came from and how it was made, its projects, its
  summary, its text with its figures in place, and its transcript. Those who manage documents choose
  here who sees it and link it to projects (see src/document_access.jl).
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { manageHref, projectHref } from './kbLinks'
import { api, mode, connect, can, post, getJSON } from './kbApi'
import KBChat from './KBChat.vue'
import KBPaperFindings from './KBPaperFindings.vue'
import KBCite from './KBCite.vue'

type Access = 'open' | 'projects'
type Project = { key: string; name: string }
type Segment = { speaker: string; start: number; end: number; text: string }
type Record = { id: string; slug: string; title: string; date: string; day: string; people: string[]; label: string; source: string
                url: string; access: Access; note: string; projects: Project[]; summary: string; topics: string[]; read: boolean
                sections: { heading: string; text: string }[]; figures: { name: string; caption: string; src: string; placed: boolean }[]
                transcript: Segment[]; cite?: { reference: string; citation: string; bibtex: string } }

const { data: r, error, render } = useTemplatedPage<Record>('records', 'No such record, or not one you may see.', { title: x => x.title })

// Its figures are sent by the service, at the API's address.
const shown = (text: string) => render.value(text.replace(/\]\(\/api\/figures\//g, `](${api.value}/api/figures/`))
const unplaced = computed(() => (r.value?.figures ?? []).filter(f => !f.placed))
const two = (n: number) => String(Math.floor(n)).padStart(2, '0')
const clock = (s: number) => s >= 3600 ? `${Math.floor(s / 3600)}:${two(s % 3600 / 60)}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`
// The transcript's turns, each saying whether it starts a run of one speaker's (where the name is shown).
const turns = computed(() => (r.value?.transcript ?? []).map((t, i, all) => ({ ...t, opens: i === 0 || all[i - 1].speaker !== t.speaker })))

// Who sees it, and the projects it is linked to, as last changed here, else as the page's data has them.
const changed = ref<{ id: string; access?: Access; projects?: string[] } | null>(null)
const mine = computed(() => changed.value && changed.value.id === r.value?.id ? changed.value : null)
const access = computed(() => mine.value?.access ?? r.value?.access)
const linked = computed(() => mine.value?.projects ?? (r.value?.projects ?? []).map(p => p.key))
const manages = computed(() => mode.value === 'live' && can('paper.manage'))
const all = ref<Project[]>([])
const name = (key: string) => all.value.find(p => p.key === key)?.name ?? r.value?.projects.find(p => p.key === key)?.name ?? key
const failed = ref('')
onMounted(async () => {
  await connect()
  if (manages.value) try { all.value = (await getJSON('/api/projects')).projects } catch { /* linking waits for the list */ }
})

async function choose(to: Access) {
  const id = r.value?.id
  if (!id || to === access.value) return
  failed.value = ''
  try {
    await post(`/api/documents/${encodeURIComponent(id)}/access`, JSON.stringify({ access: to }))
    changed.value = { ...mine.value, id, access: to }
  } catch (e: any) { failed.value = e.message ?? String(e) }
}
async function link(key: string, remove = false) {
  const id = r.value?.id
  if (!id || !key) return
  failed.value = ''
  try {
    const got = await post(`/api/documents/${encodeURIComponent(id)}/projects`, JSON.stringify({ project: key, remove }))
    changed.value = { ...mine.value, id, projects: got.projects }
  } catch (e: any) { failed.value = e.message ?? String(e) }
}
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!r" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="record-title">{{ r.title }}</h1>
    <p class="kbr-made"><span class="kb-chip">record</span> {{ r.day }}<template v-if="r.people.length"> · {{ r.people.join(', ') }}</template></p>
    <p class="kb-dim">{{ r.label }}.<template v-if="r.url"> <a :href="r.url" target="_blank" rel="noopener">The original</a>.</template></p>
    <div class="kb-buttons"><KBCite v-if="r.cite" :cite="r.cite" :title="r.title" /><a class="kb-button kb-live-only" :href="manageHref(r.id)">Manage</a></div>
    <p class="kbr-projects">
      <template v-if="linked.length">Linked to
        <span v-for="k in linked" :key="k" class="kbr-project"><a :href="projectHref(k)">{{ name(k) }}</a>
          <button v-if="manages" type="button" class="kb-link" :title="`Unlink ${k}`" @click="link(k, true)">×</button></span>
      </template>
      <template v-else>No project: visible to document managers only.</template>
      <select v-if="manages" class="kbr-select" @change="link(($event.target as HTMLSelectElement).value); ($event.target as HTMLSelectElement).value = ''">
        <option value="">link to a project…</option>
        <option v-for="p in all.filter(p => !linked.includes(p.key))" :key="p.key" :value="p.key">{{ p.name }} ({{ p.key }})</option>
      </select>
    </p>
    <p v-if="manages" class="kbr-projects">
      <label>Seen by
        <select class="kbr-select" :value="access" @change="choose(($event.target as HTMLSelectElement).value as Access)">
          <option value="open">every reader</option>
          <option value="projects">the members of its projects</option>
        </select>
      </label>
    </p>
    <p v-if="failed" class="kb-error">{{ failed }}</p>

    <template v-if="r.summary">
      <h2 id="summary">Summary</h2>
      <div v-html="render(r.summary)"></div>
      <p v-if="r.topics.length"><strong>Topics:</strong> {{ r.topics.join(' · ') }}</p>
    </template>
    <p v-else-if="!r.read" class="kb-dim">Not read yet.</p>
    <KBChat :id="r.id" :title="r.title" />
    <KBPaperFindings :id="r.id" />

    <template v-for="(s, i) in r.sections" :key="i">
      <h2 :id="`part-${i + 1}`">{{ s.heading }}</h2>
      <div class="kbr-text" v-html="shown(s.text)"></div>
    </template>
    <template v-if="unplaced.length">
      <h2 id="figures">Figures</h2>
      <figure v-for="f in unplaced" :key="f.name" class="kbr-figure">
        <img :src="`${api}${f.src}`" :alt="f.caption" /><figcaption v-if="f.caption">{{ f.caption }}</figcaption>
      </figure>
    </template>
    <template v-if="r.transcript.length">
      <h2 id="transcript">Transcript</h2>
      <details class="kbr-transcript">
        <summary>{{ r.transcript.length }} turns</summary>
        <div class="kbr-turns">
          <template v-for="(t, i) in turns" :key="i">
            <div v-if="t.opens && t.speaker" class="kbr-speaker">{{ t.speaker }}</div>
            <span class="kbr-clock">{{ clock(t.start) }}</span>
            <p class="kbr-said">{{ t.text }}</p>
          </template>
        </div>
      </details>
    </template>
  </template>
</template>

<style scoped>
.kbr-made { font-size: 0.95rem; }
.kb-chip { display: inline-block; padding: 0 0.4rem; border-radius: 4px; font-size: 0.75rem;
           background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbr-projects { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; font-size: 0.9rem; }
.kbr-project { display: inline-flex; gap: 0.2rem; align-items: center; }
.kbr-select { padding: 0.2rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
              background: var(--vp-c-bg); color: var(--vp-c-text-1); font: inherit; }
.kbr-text :deep(img), .kbr-figure img { max-width: 100%; border-radius: 6px; }
.kbr-figure figcaption { font-size: 0.85rem; color: var(--vp-c-text-2); }
.kbr-transcript summary { cursor: pointer; }
.kbr-turns { display: grid; grid-template-columns: max-content 1fr; column-gap: 1rem; row-gap: 0.25rem;
             margin-top: 0.75rem; font-size: 0.9rem; line-height: 1.55; }
.kbr-speaker { grid-column: 2; margin-top: 0.9rem; font-weight: 600; color: var(--vp-c-text-1); }
.kbr-speaker:first-child { margin-top: 0; }
.kbr-clock { grid-column: 1; text-align: right; font-variant-numeric: tabular-nums; color: var(--vp-c-text-3);
             font-size: 0.8rem; padding-top: 0.1rem; }
.kbr-said { grid-column: 2; margin: 0; }
</style>
