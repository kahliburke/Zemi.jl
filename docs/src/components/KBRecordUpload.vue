<!--
  Uploading records: files dropped or chosen here go to the source that reads them (a Markdown file
  to Zemi's own, one record each), dated as given here or, without a date, by the file's own. With
  `project`, as on a project's page, each record is linked to that project.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, onMounted } from 'vue'
import { connect, post } from './kbApi'

const props = defineProps<{ project?: string }>()
const emit = defineEmits<{ uploaded: [ids: string[]] }>()

const files = ref<File[]>([])
const date = ref('')
const busy = ref(false)
const over = ref(false)
const message = ref('')
const error = ref('')
onMounted(() => connect())

const take = (list: FileList | null | undefined) => { files.value = [...files.value, ...Array.from(list ?? [])] }
const onDrop = (e: DragEvent) => { over.value = false; take(e.dataTransfer?.files) }
const onPick = (e: Event) => take((e.target as HTMLInputElement).files)
// The day a file was last changed, in the reader's time, as the date of what it records.
const fileDay = (f: File) => { const d = new Date(f.lastModified); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10) }

async function upload() {
  error.value = ''; message.value = ''; busy.value = true
  const ids: string[] = [], failed: string[] = []
  for (const f of files.value) {
    const q = new URLSearchParams({ name: f.name, date: date.value || fileDay(f) })
    if (props.project) q.set('project', props.project)
    try {
      const r = await post(`/api/records/upload?${q}`, f, f.type || 'application/octet-stream')
      ids.push(...r.ids)
    } catch (e: any) { failed.push(`${f.name}: ${e.message ?? e}`) }
  }
  busy.value = false
  files.value = []
  message.value = ids.length ? `Added ${ids.join(', ')}; each is read in the background.` : ''
  error.value = failed.join('; ')
  if (ids.length) emit('uploaded', ids)
}
</script>

<template>
  <div class="kbru">
    <KBNeedsService permission="paper.add">
      <label :class="['kbru-drop', { over }]" @dragover.prevent="over = true" @dragleave="over = false" @drop.prevent="onDrop">
        <input type="file" multiple @change="onPick" />
        <span v-if="!files.length">Drop Markdown notes, one record per file</span>
        <span v-else>{{ files.map(f => f.name).join(', ') }}</span>
      </label>
      <div class="kbru-actions">
        <label class="kb-dim">Date <input v-model="date" type="date" class="kb-field kbru-date" /></label>
        <button type="button" class="kb-primary kbru-button" :disabled="busy || !files.length" @click="upload">
          {{ busy ? 'Adding…' : 'Add' }}</button>
        <button v-if="files.length" type="button" class="kb-link" @click="files = []">clear</button>
      </div>
      <p v-if="message" class="kb-dim kbru-dim">{{ message }}</p>
      <p v-if="error" class="kb-error">{{ error }}</p>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbru { margin: 1rem 0; }
.kbru-drop { display: block; padding: 1rem; text-align: center; border: 2px dashed var(--vp-c-divider); border-radius: 10px;
  color: var(--vp-c-text-2); cursor: pointer; }
.kbru-drop.over { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); }
.kbru-drop input { display: none; }
.kbru-actions { display: flex; align-items: center; gap: 1rem; margin-top: 0.6rem; }
.kbru-date { margin-left: 0.4rem; padding: 0.25rem 0.4rem; border-radius: 6px; }
.kbru-button:disabled { opacity: 0.5; cursor: default; }
.kbru-dim { font-size: 0.88rem; }
</style>
