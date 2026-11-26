<script setup lang="ts">
import { ref, shallowRef, computed, watch } from 'vue'
import { useRoute } from 'vitepress'
import KBPublicationHistory from './KBPublicationHistory.vue'
import KBNeedsService from './KBNeedsService.vue'
import KBPublicationEditor from './KBPublicationEditor.vue'
import { api, getJSON, onLive } from './kbApi'
import { pageLink, projectHref, taskHref } from './kbLinks'
import { onTaskRef } from './kbRefs'
import { escapeText, loadMarkdown } from './kbMarkdown'

type Work = { id: number; version: number; title: string; authors: string; project: string }
type History = InstanceType<typeof KBPublicationHistory>['$props']['entries']
type Edition = Work & { history: History; latest: number; abstract: string; body: string; revision: string; changes: string; audience: string;
  prepared_by: string; published_by: string; published_at: string; has_draft: boolean; pdf_hash: string | null; date: string; access: string; url: string }
const openTask = onTaskRef(ref => location.assign(taskHref(ref)))
const route = useRoute()
const works = ref<Work[]>([]), drafts = ref<Work[]>([]), project = ref(''), access = ref('')
const files = ref<{ address: string; name: string }[]>([])
const reader = shallowRef<Edition>(), editing = ref(false), draft = shallowRef<Edition>()
const loading = ref(true), error = ref(''), copied = ref(false), citationOpen = ref(false)
const render = shallowRef(escapeText)
const contributor = computed(() => ['maintainer', 'contributor'].includes(access.value))
const href = (id: number, v?: number) => pageLink(`/publications/${id}/${v ? 'v' + v + '/' : ''}`)
const citation = computed(() => {
  const e = reader.value
  return e ? `${e.authors}. ${e.title}. v${e.version}, ${e.published_at.slice(0, 10)}. ${new URL(href(e.id, e.version), location.href).href}` : ''
})

let request = 0
async function load() {
  const mine = ++request
  reader.value = undefined; draft.value = undefined; editing.value = false; loading.value = true
  copied.value = false; citationOpen.value = false; error.value = ''; files.value = []
  const match = location.pathname.match(/\/publications\/(\d+)\/(?:v(\d+)\/)?$/)
  project.value = new URLSearchParams(location.search).get('project') ?? ''
  try {
    render.value = await loadMarkdown()
    if (match) {
      const e = await getJSON(`/api/publications/${match[1]}` + (match[2] ? `?version=${match[2]}` : ''))
      if (mine !== request) return
      reader.value = e; project.value = e.project; access.value = e.access
      document.title = `${e.title} · v${e.version}`
    } else {
      const list = await getJSON('/api/publications?project=' + encodeURIComponent(project.value))
      if (mine !== request) return
      works.value = list.works; drafts.value = list.drafts; access.value = list.access
    }
  } catch (e) { if (mine === request) error.value = (e as Error).message }
  finally { if (mine === request) loading.value = false }
}
onLive(() => watch(() => route.path, load, { immediate: true }))
async function edit(id?: number, next = false) {
  error.value = ''
  try {
    const [board, e] = await Promise.all([getJSON('/api/projects/' + encodeURIComponent(project.value)),
      id ? getJSON(`/api/publications/${id}` + (next && !reader.value?.has_draft ? '' : '?draft=1')) : undefined])
    files.value = (board.files ?? []).filter((f: { name: string }) => /\.(md|pdf)$/i.test(f.name))
    draft.value = e; editing.value = true
  } catch (e) { error.value = (e as Error).message }
}
async function cite() {
  citationOpen.value = true
  try { await navigator.clipboard.writeText(citation.value); copied.value = true } catch { /* select the visible citation */ }
}
</script>
<template>
  <KBNeedsService permission="read">
    <p v-if="loading">Loading internal publications…</p>
    <p v-if="error" role="alert">{{ error }}</p>
    <KBPublicationEditor v-if="editing" :project="project" :edition="draft" :files="files" :maintainer="access === 'maintainer'" @close="load" />
    <article v-else-if="reader">
      <a :href="pageLink('/publications/')">Internal publications</a>
      <h1>{{ reader.title }}</h1>
      <p>{{ reader.authors }}</p>
      <p v-if="reader.date">Manuscript dated {{ reader.date }}</p>
      <p>v{{ reader.version }} · Published {{ reader.published_at.slice(0, 10) }} by {{ reader.published_by }}
        · {{ reader.audience === 'instance' ? 'Instance readers' : reader.project + ' members' }}</p>
      <p v-if="reader.prepared_by !== reader.published_by">Draft prepared by {{ reader.prepared_by }}</p>
      <button @click="cite">Cite this version</button>
      <p v-if="citationOpen" role="status"><span v-if="copied">Copied. </span>{{ citation }}</p>
      <KBPublicationHistory :key="reader.url" :work="reader.id" :version="reader.version" :latest="reader.latest"
        :entries="reader.history" :maintainer="access === 'maintainer'" @saved="entries => { if (reader) reader = { ...reader, history: entries } }" />
      <h2>Abstract</h2><p>{{ reader.abstract }}</p>
      <p v-if="reader.pdf_hash"><a :href="`${api}/api/publications/${reader.id}/${reader.version}/pdf`" target="_blank" rel="noopener">Read manuscript PDF</a></p>
      <p v-if="reader.body"><a :href="`${api}/api/publications/${reader.id}/${reader.version}/markdown`" download>Download manuscript Markdown</a></p>
      <div class="kb-md" @click="openTask" @keydown.enter="openTask" v-html="render(reader.body, { refs: true })"></div>
      <h2>Versions</h2>
      <nav class="versions" aria-label="Versions"><a v-for="v in reader.latest" :key="v" :href="href(reader.id, v)" :aria-current="v === reader.version ? 'page' : undefined">v{{ v }}</a></nav>
      <p v-if="reader.changes">{{ reader.changes }}</p>
      <button v-if="contributor && reader.version === reader.latest" @click="edit(reader.id, true)">{{ reader.has_draft ? 'Review draft' : 'Prepare next version' }}</button>
    </article>
    <template v-else-if="!loading && !error">
      <h1>Internal publications</h1>
      <p v-if="project"><a :href="projectHref(project)">{{ project }}</a></p>
      <button v-if="contributor" @click="edit()">New internal publication</button>
      <section v-if="drafts.length">
        <h2>Project drafts</h2>
        <ul><li v-for="d in drafts" :key="d.id"><button @click="edit(d.id)">{{ d.title }} · draft v{{ d.version }}</button></li></ul>
      </section>
      <h2 v-if="drafts.length">Published</h2>
      <ul v-if="works.length"><li v-for="w in works" :key="w.id"><a :href="href(w.id)">{{ w.title }}</a> · {{ w.authors }} · v{{ w.version }}</li></ul>
      <p v-else>No internal publications yet.</p>
    </template>
  </KBNeedsService>
</template>
<style scoped>
button { color: var(--vp-c-brand-1); text-decoration: underline; }
.versions { display: flex; flex-wrap: wrap; gap: .25rem 1rem; }
[aria-current="page"] { font-weight: bold; }
</style>
