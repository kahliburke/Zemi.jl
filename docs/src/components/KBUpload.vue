<!--
  Adding documents from the site: PDFs dropped or chosen here, arXiv ids and links, or a codebase by
  its repository's address or a folder on the service's machine (in a shared service, a folder by
  someone who may change its configuration). Each goes through the whole pipeline (parse, summarize,
  embed) as a job of the knowledge base API. With `codebases`, only a codebase, as on the Codebases
  page; with `manage` too, a link to managing those there are.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, computed, onMounted } from 'vue'
import { connect, post, followJobs, blockers, shared, can, RequestError } from './kbApi'
import { kbPage } from './kbLinks'
import KBJobs from './KBJobs.vue'

const props = defineProps<{ codebases?: boolean; manage?: boolean }>()

const files = ref<File[]>([])
const title = ref('')
const arxiv = ref('')
const codebase = ref('')
const busy = ref(false)
const message = ref('')
const error = ref('')
// Documents are added to be read; where they cannot be, the form says why instead.
const cannot = computed(() => blockers('ingest', ['paper']))
const over = ref(false)
// A document dropped here, refused: who dropped it and why, to add it anyway (which restores it).
type Drop = { id: string; title: string; by: string; at: string; why: string }
const dropped = ref<Drop | null>(null)

onMounted(() => { connect(); followJobs() })

function take(list: FileList | null) {
  const pdfs = Array.from(list ?? []).filter(f => f.type === 'application/pdf' || f.name.toLowerCase().endsWith('.pdf'))
  files.value = [...files.value, ...pdfs]
  if (list && pdfs.length < list.length) error.value = 'PDFs only.'
}
const onDrop = (e: DragEvent) => { over.value = false; take(e.dataTransfer?.files ?? null) }
const onPick = (e: Event) => take((e.target as HTMLInputElement).files)

async function add(anyway = false) {
  error.value = ''; message.value = ''; dropped.value = null; busy.value = true
  const added: string[] = [], already: string[] = []
  try {
    // Each added is taken off the form, so adding anyway after a refusal sends only what is left.
    const titled = files.value.length === 1 ? title.value.trim() : ''
    while (files.value.length) {
      const f = files.value[0]
      const params = new URLSearchParams({ name: f.name })
      if (titled) params.set('title', titled)
      if (anyway) params.set('anyway', 'true')
      const r = await post(`/api/documents?${params}`, f, 'application/pdf')
      added.push(...r.ids); already.push(...(r.already ?? [])); followJobs(r.job)
      files.value = files.value.slice(1)
    }
    if (arxiv.value.trim()) {
      const r = await post('/api/documents', JSON.stringify({ arxiv: arxiv.value, anyway }))
      added.push(...r.ids); already.push(...(r.already ?? [])); followJobs(r.job)
      arxiv.value = ''
    }
    if (codebase.value.trim()) {
      const r = await post('/api/documents', JSON.stringify({ codebase: codebase.value, anyway }))
      added.push(...r.ids); already.push(...(r.already ?? [])); followJobs(r.job)
      codebase.value = ''
    }
    const adding = added.filter(id => !already.includes(id))
    message.value = [adding.length ? `Adding ${adding.join(', ')}.` : '',
                     already.length ? `Already in the knowledge base: ${already.join(', ')}.` : ''].filter(Boolean).join(' ') || 'Nothing to add.'
    files.value = []; title.value = ''; arxiv.value = ''; codebase.value = ''
  } catch (e: any) {
    if (e instanceof RequestError && e.status === 409 && e.dropped) dropped.value = e.dropped
    else error.value = e.message ?? String(e)
  } finally { busy.value = false }
}
</script>

<template>
  <div class="kbu">
    <KBNeedsService permission="paper.add">
      <p v-if="cannot.length" class="kb-dim kbu-dim">Unavailable here: {{ cannot.join('; ') }}.</p>
      <template v-else>
        <template v-if="!props.codebases">
          <label :class="['kbu-drop', { over }]" @dragover.prevent="over = true" @dragleave="over = false" @drop.prevent="onDrop">
            <input type="file" accept=".pdf,application/pdf" multiple @change="onPick" />
            <span v-if="!files.length">Drop or choose PDFs</span>
            <span v-else>{{ files.map(f => f.name).join(', ') }}</span>
          </label>
          <input v-if="files.length === 1" v-model="title" class="kb-field kbu-input" placeholder="Title (optional)" />
          <textarea v-model="arxiv" class="kb-field kbu-input" rows="2" placeholder="arXiv ids or links"></textarea>
        </template>
        <input v-model="codebase" class="kb-field kbu-input" @keydown.enter="add()"
               :placeholder="shared && !can('config.edit') ? 'A codebase: its repository, https://github.com/owner/repo' : 'A codebase: its repository (https://github.com/owner/repo) or a folder here'" />
        <div class="kbu-actions">
          <button type="button" class="kb-primary kbu-button" :disabled="busy || (!files.length && !arxiv.trim() && !codebase.trim())" @click="add()">
            {{ busy ? 'Adding…' : 'Add' }}</button>
          <button v-if="files.length" type="button" class="kb-link" @click="files = []">clear files</button>
          <a v-if="props.codebases && props.manage && can('paper.manage')" class="kb-link" :href="`${kbPage('manage')}?state=code`">Manage codebases</a>
        </div>
        <p v-if="message" class="kb-dim kbu-dim">{{ message }}</p>
        <p v-if="error" class="kb-error kbu-error">{{ error }}</p>
        <p v-if="dropped" class="kb-error kbu-error">{{ dropped.title }} ({{ dropped.id }}) was dropped by {{ dropped.by }}
          on {{ dropped.at.slice(0, 10) }}<template v-if="dropped.why">: {{ dropped.why }}</template>.
          <button type="button" class="kb-link" :disabled="busy" @click="add(true)">Add it anyway</button>, which restores it.</p>
        <KBJobs />
      </template>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbu { margin: 1rem 0 2rem; }
.kbu-drop { display: block; padding: 1.4rem; text-align: center; border: 2px dashed var(--vp-c-divider); border-radius: 10px;
  color: var(--vp-c-text-2); cursor: pointer; }
.kbu-drop.over { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); }
.kbu-drop input { display: none; }
.kbu-input { display: block; width: 100%; box-sizing: border-box; margin-top: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 8px; }
.kbu-actions { display: flex; align-items: center; gap: 1rem; margin-top: 0.6rem; }
.kbu-button:disabled { opacity: 0.5; cursor: default; }
.kbu-dim { font-size: 0.9rem; }
</style>
