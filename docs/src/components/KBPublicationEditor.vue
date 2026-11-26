<script setup lang="ts">
import { ref, computed, shallowRef, onMounted } from 'vue'
import { post, uploadMedia, mediaUrl } from './kbApi'
import { readAttachment } from './kbFrontmatter'
import { escapeText, loadMarkdown } from './kbMarkdown'
import { pageLink } from './kbLinks'

type Manuscript = { id: number; version: number; latest: number; revision: string; title: string; authors: string;
  abstract: string; date: string; body: string; changes: string; pdf_hash: string | null; audience: string; published_at: string }
const props = defineProps<{ project: string; edition?: Manuscript; files: { name: string; address: string }[]; maintainer: boolean }>()
const emit = defineEmits<{ close: [] }>()
const initial = props.edition
const form = ref({ id: initial?.id ?? 0, revision: initial?.revision ?? '', title: initial?.title ?? '', authors: initial?.authors ?? '',
  abstract: initial?.abstract ?? '', date: initial?.date ?? '', body: initial?.body ?? '',
  changes: initial?.published_at ? '' : initial?.changes ?? '', source: initial?.pdf_hash ? `media/${initial.pdf_hash}/manuscript.pdf` : '' })
const preview = ref(!!initial && !initial.published_at)
const version = ref((initial?.latest ?? 0) + 1)
const audience = ref(initial?.audience ?? 'project')
const fixedAudience = !!initial?.latest
const allowed = computed(() => audience.value === 'project' || props.maintainer)
const busy = ref(false), error = ref('')
const render = shallowRef(escapeText)
onMounted(async () => { render.value = await loadMarkdown() })
async function action(work: () => Promise<void>) {
  busy.value = true; error.value = ''
  try { await work() } catch (e) { error.value = (e as Error).message }
  finally { busy.value = false }
}
function fillMarkdown(text: string, name: string) {
  const doc = readAttachment(text, name)
  form.value.title ||= doc.title
  form.value.date ||= doc.date
  form.value.body = doc.unparsed ? text : doc.body
  form.value.source = ''
}
async function fromFile(file?: File) {
  if (!file) return
  await action(async () => {
    if (/\.md$/i.test(file.name)) fillMarkdown(await file.text(), file.name)
    else {
      form.value.source = (await uploadMedia(file, undefined, props.project)).address
      form.value.title ||= file.name
    }
  })
}
async function fromProject(address: string) {
  if (!address) return
  await action(async () => {
    if (/\.pdf$/i.test(address)) {
      form.value.source = address
      form.value.title ||= address.split('/').pop()!
    } else {
      const r = await fetch(mediaUrl(address))
      if (!r.ok) throw new Error('Could not open the manuscript.')
      fillMarkdown(await r.text(), address.split('/').pop()!)
    }
  })
}
function save() {
  return action(async () => {
    const e = await post(`/api/projects/${encodeURIComponent(props.project)}/publications`, JSON.stringify(form.value))
    form.value.id = e.id; form.value.revision = e.revision
    version.value = e.version; preview.value = true
  })
}
function publish() {
  return action(async () => {
    const e = await post(`/api/publications/${form.value.id}/publish`, JSON.stringify({ revision: form.value.revision, audience: audience.value }))
    location.assign(pageLink(e.url))
  })
}
</script>
<template>
  <h1>{{ preview ? 'Review draft' : 'Prepare publication' }}</h1>
  <p>{{ project }} · v{{ version }}</p>
  <p v-if="error" role="alert">{{ error }}</p>
  <form v-if="!preview" @submit.prevent="save">
    <fieldset :disabled="busy">
      <label>Import manuscript <input type="file" accept=".md,.pdf" @change="fromFile(($event.target as HTMLInputElement).files?.[0])"></label>
      <label v-if="files.length">Use project file
        <select @change="fromProject(($event.target as HTMLSelectElement).value)">
          <option value="">Choose a file</option><option v-for="f in files" :value="f.address" :key="f.address">{{ f.name }}</option>
        </select>
      </label>
      <label>Title <input v-model="form.title" required></label>
      <label>Authors and contributions <input v-model="form.authors" placeholder="Names and roles of people or agents"></label>
      <label>Manuscript date <input v-model="form.date"></label>
      <label>Abstract <textarea v-model="form.abstract" rows="3"></textarea></label>
      <label>Manuscript (Markdown) <textarea v-model="form.body" rows="12"></textarea></label>
      <p v-if="form.source"><a :href="mediaUrl(form.source)" target="_blank" rel="noopener">Open manuscript PDF</a>
        <button type="button" @click="form.source = ''">Remove PDF</button></p>
      <label v-if="version > 1">What changed <textarea v-model="form.changes" rows="2"></textarea></label>
      <button type="submit">Save and preview</button>
    </fieldset>
  </form>
  <template v-else>
    <h2>{{ form.title }}</h2><p>{{ form.authors }}</p><p>{{ form.date }}</p>
    <p>{{ form.abstract }}</p>
    <div class="kb-md" v-html="render(form.body, { refs: true })"></div>
    <p v-if="form.source"><a :href="mediaUrl(form.source)" target="_blank" rel="noopener">Read manuscript PDF</a></p>
    <p v-if="form.changes">{{ form.changes }}</p>
    <fieldset :disabled="busy">
      <label v-if="maintainer && !fixedAudience">Audience
        <select v-model="audience"><option value="project">Project members</option><option value="instance">All instance readers</option></select>
      </label>
      <p v-else>Audience · {{ audience === 'instance' ? 'All instance readers' : project + ' members' }}</p>
      <button type="button" @click="preview = false">Edit draft</button>
      <button v-if="allowed" type="button" @click="publish">Publish v{{ version }} {{ audience === 'instance' ? 'to the instance' : 'in ' + project }}</button>
    </fieldset>
  </template>
  <button type="button" :disabled="busy" @click="emit('close')">Back to publications</button>
</template>
<style scoped>
fieldset { border: 0; padding: 0; }
label { display: grid; gap: .25rem; margin: .8rem 0; font-weight: 600; }
input, textarea, select { padding: .45rem .65rem; border: 1px solid var(--vp-c-divider); border-radius: 5px; background: var(--vp-c-bg); font: inherit; font-weight: 400; }
textarea { resize: vertical; }
button { color: var(--vp-c-brand-1); margin: .5rem 1rem .5rem 0; }
</style>
