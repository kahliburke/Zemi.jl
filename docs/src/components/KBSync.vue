<!--
  Bringing the knowledge base up to date: what is unfinished or out of date and why, and a button that
  does all of it as one job, with its progress shown here.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBTitle from './KBTitle.vue'
import KBJob from './KBJob.vue'
import { ref, computed, onMounted, watch } from 'vue'
import { mode, connect, post, getJSON, can, jobs, followJobs, finishedJobs } from './kbApi'
import { kbPage } from './kbLinks'
import { when, plural } from './kbFormat'

type Task = { id: string; title: string; action: string; reason: string; page: string }
type Dataset = { role: string; stream: string | null; published_at: string | null; pulled: string | null; checked: string | null }
const tasks = ref<Task[]>([])
const dataset = ref<Dataset | null>(null)
const unread = ref(0)
const readUnread = ref(false)
const jobId = ref<string | null>(null)
const loaded = ref(false)
const error = ref('')
const showAll = ref(false)

const SHOWN = 8
const VERBS: Record<string, string> = { ingest: 'read', classify: 'classify', metadata: 'fetch record', embed: 'embed abstract',
                                        missing: 'cannot sync' }

async function load() {
  if (mode.value !== 'live' || !can('sync')) return
  try {
    const data = await getJSON('/api/sync')
    tasks.value = data.tasks; unread.value = data.unread; dataset.value = data.dataset ?? null
    if (data.job) { jobId.value = data.job; followJobs(data.job) }
    loaded.value = true
  } catch (e: any) { error.value = `Status failed: ${e.message ?? e}` }
}
onMounted(async () => { await connect(); load() })
watch(finishedJobs, load)

const job = computed(() => jobs.value.find(j => j.id === jobId.value) ?? null)
// Busy from the click: while the request is out, and until the job list has the job it started.
const starting = ref(false)
const running = computed(() => starting.value || job.value?.status === 'running')
const documents = computed(() => new Set(tasks.value.filter(t => t.action !== 'missing').map(t => t.id)).size)
const shown = computed(() => showAll.value ? tasks.value : tasks.value.slice(0, SHOWN))

async function start(path: string, body: object) {
  if (running.value) return
  error.value = ''; starting.value = true
  try {
    const r = await post(path, JSON.stringify(body))
    jobId.value = r.job
    await followJobs(r.job)
  } catch (e: any) { error.value = e.message ?? String(e) }
  finally { starting.value = false }
}
const sync = () => start('/api/sync', { unread: readUnread.value })
const publish = () => start('/api/publish', {})
</script>

<template>
  <div class="kbs">
    <KBNeedsService permission="sync">
      <template v-if="loaded">
        <p v-if="!tasks.length" class="kbs-ok">✓ Up to date.</p>
        <template v-else>
          <p class="kbs-head">{{ plural(documents, 'document') }} out of date</p>
          <div v-for="t in shown" :key="t.id + t.action" class="kbs-task">
            <span :class="['kbs-verb', t.action]">{{ VERBS[t.action] ?? t.action }}</span>
            <a :href="kbPage(t.page)"><KBTitle :text="t.title" /></a>
            <span class="kbs-dim"> · {{ t.reason }}</span>
          </div>
          <button v-if="tasks.length > SHOWN" type="button" class="kb-link" @click="showAll = !showAll">
            {{ showAll ? 'show fewer' : `show all ${tasks.length}` }}</button>
        </template>
        <label v-if="unread" class="kbs-unread">
          <input v-model="readUnread" type="checkbox" :disabled="running" />
          Also read the {{ unread }} abstract-only papers <span class="kbs-dim">(slow, uses tokens)</span>
        </label>
        <div class="kbs-bar">
          <button type="button" class="kb-primary kbs-button" :disabled="running" @click="sync">{{ running ? 'Working…' : 'Sync' }}</button>
          <button v-if="dataset?.role === 'publish'" type="button" class="kb-primary kbs-button secondary" :disabled="running"
                  @click="publish">Publish</button>
          <span class="kbs-dim">Also checks arXiv for new versions.</span>
        </div>
        <p v-if="dataset?.role === 'publish'" class="kbs-dim kbs-dataset">
          Publishes the stream {{ dataset.stream }} · last published {{ when(dataset.published_at, 'never') }} · imported {{ when(dataset.pulled, 'never') }}.
        </p>
        <p v-else-if="dataset?.role === 'consume'" class="kbs-dim kbs-dataset">
          Imports the dataset first · imported {{ when(dataset.pulled, 'never') }} · checked {{ when(dataset.checked, 'never') }}.
        </p>
        <KBJob v-if="job" :job="job" :named="false" class="kbs-job" />
        <p v-if="error" class="kb-error kbs-error">{{ error }}</p>
      </template>
      <p v-else-if="error" class="kb-error kbs-error">{{ error }}</p>
      <p v-else class="kbs-dim">Checking…</p>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbs { margin: 1rem 0 2rem; padding: 0.8rem 1rem; border: 1px solid var(--vp-c-divider); border-radius: 10px; font-size: 0.9rem; }
.kbs-head { margin: 0 0 0.4rem; font-weight: 600; }
.kbs-ok { margin: 0 0 0.4rem; color: var(--vp-c-green-1); }
.kbs-task { padding: 0.25rem 0; border-top: 1px solid var(--vp-c-divider); line-height: 1.45; }
.kbs-verb { display: inline-block; min-width: 6.5em; margin-right: 0.5rem; padding: 0 0.4rem; border-radius: 4px; font-size: 0.72rem;
  text-align: center; background: var(--vp-c-default-soft); }
.kbs-verb.ingest { background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbs-verb.missing { background: var(--vp-c-danger-soft); color: var(--vp-c-danger-1); }
.kbs-unread { display: block; margin: 0.8rem 0 0; }
.kbs-bar { display: flex; align-items: center; gap: 0.8rem; margin-top: 0.8rem; }
.kbs-button { padding: 0.35rem 1.1rem; border: 1px solid var(--vp-c-brand-1); font: inherit; }
.kbs-button:disabled { opacity: 0.6; cursor: default; }
.kbs-button.secondary { background: none; color: var(--vp-c-brand-1); }
.kbs-dataset { margin: 0.5rem 0 0; }
.kbs-dim { color: var(--vp-c-text-3); font-size: 0.82rem; }
.kb-link { font-size: 0.85rem; }
.kbs-job { margin-top: 0.7rem; }
</style>
