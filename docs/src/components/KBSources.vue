<!--
  The sources of records, for those who look after the documents: each source's label, where it runs,
  its last run (what it added, changed and skipped, or why it failed) and its next, and its records;
  a source whose package is not loaded is shown as such, and a plugin that failed to load with its
  error. Run now, pause and resume a source; those who may remove a source's records are asked to
  confirm how many first.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref } from 'vue'
import { getJSON, post, can, onLive, every, followJobs, RequestError } from './kbApi'
import { when, plural } from './kbFormat'

type Source = { name: string; registered: boolean; plugin: string; label: string; modes: string[]; here: boolean; polls: boolean
                every: number; uploads: boolean; records: number; running: boolean; paused: boolean; started: string | null
                finished: string | null; outcome: string | null; added: number; changed: number; skipped: number; error: string
                failures: number; next: string | null }
type Plugin = { name: string; loaded: boolean; error: string; sources: string[] }
type Sources = { sources: Source[]; plugins?: Plugin[]; mode: string }
const data = ref<Sources | null>(null)
const error = ref('')
const note = ref('')

async function load() {
  try { data.value = await getJSON('/api/sources'); error.value = '' } catch (e: any) { error.value = e.message ?? String(e) }
}
onLive(async () => { if (!can('paper.manage')) return; await load(); return every(10_000, load) })

async function act(s: Source, what: 'run' | 'pause' | 'resume') {
  note.value = ''; error.value = ''
  try {
    const r = await post(`/api/sources/${s.name}/${what}`, '{}')
    if (r.job) followJobs(r.job)
    note.value = what === 'run' ? `Running ${s.name}.` : what === 'pause' ? `Paused ${s.name}.` : `Resumed ${s.name}.`
    await load()
  } catch (e: any) { error.value = e.message ?? String(e) }
}

// Removing a source's records is confirmed by their count, which the service checks is still theirs.
async function purge(s: Source) {
  if (!confirm(`Remove the ${plural(s.records, 'record')} ${s.name} made, with everything made from them?` +
               (s.polls && s.registered ? ' The source is paused until it is resumed.' : ''))) return
  note.value = ''; error.value = ''
  try {
    const r = await post(`/api/sources/${s.name}/purge`, JSON.stringify({ count: s.records }))
    note.value = `Removed ${plural(r.removed, 'record')} from ${s.name}.`
  } catch (e: any) {
    error.value = e instanceof RequestError && e.status === 409 ? `${s.name} has a different number of records now; look again and confirm.` : e.message ?? String(e)
  }
  await load()
}

// A period in seconds as people read it.
function period(s: number) {
  return s >= 86400 ? plural(Math.round(s / 86400), 'day') : s >= 3600 ? plural(Math.round(s / 3600), 'hour')
       : s >= 60 ? plural(Math.round(s / 60), 'minute') : plural(Math.round(s), 'second')
}
const OUTCOMES: Record<string, string> = { ok: 'done', spent: 'stopped at its budget', stopped: 'stopped', failed: 'failed' }
</script>

<template>
  <div class="kbsrc">
    <KBNeedsService permission="paper.manage">
      <p v-if="note" class="kbsrc-note">{{ note }}</p>
      <p v-if="error" class="kb-error">{{ error }}</p>
      <ul v-if="data?.plugins?.some(p => !p.loaded)" class="kbsrc-plugins">
        <li v-for="p in data.plugins.filter(p => !p.loaded)" :key="p.name" class="kb-error">Plugin {{ p.name }} did not load: {{ p.error }}</li>
      </ul>
      <table v-if="data?.sources.length" class="kbsrc-table">
        <thead><tr><th>Source</th><th>Runs</th><th>Last run</th><th>Next</th><th>Records</th><th></th></tr></thead>
        <tbody>
          <tr v-for="s in data.sources" :key="s.name" :class="{ 'kbsrc-off': !s.registered || !s.here }">
            <td><strong>{{ s.name }}</strong>
              <div class="kbsrc-s">{{ s.registered ? s.label : 'not registered: its package is not loaded' }}</div>
              <div v-if="s.plugin" class="kbsrc-s">from {{ s.plugin }}</div></td>
            <td class="kbsrc-s">
              <template v-if="s.registered">
                <template v-if="s.polls">every {{ period(s.every) }}</template><template v-if="s.polls && s.uploads">; </template>
                <template v-if="s.uploads">reads uploads</template>
                <div>{{ s.modes.includes('local') && s.modes.includes('shared') ? 'both modes' : `${s.modes[0]} mode only` }}<template
                  v-if="!s.here"> · not here</template></div>
              </template></td>
            <td class="kbsrc-s">
              <template v-if="s.running"><span class="kbsrc-running">running</span> since {{ when(s.started) }}</template>
              <template v-else-if="s.outcome">
                <span :class="'kbsrc-' + s.outcome">{{ OUTCOMES[s.outcome] ?? s.outcome }}</span> {{ when(s.finished) }}
                <div>{{ s.added }} added, {{ s.changed }} changed, {{ s.skipped }} skipped</div>
                <div v-if="s.error" :class="{ 'kb-error': s.outcome === 'failed' }">{{ s.error }}<template
                  v-if="s.failures > 1"> ({{ s.failures }} failures in a row)</template></div>
              </template>
              <template v-else>never</template></td>
            <td class="kbsrc-s">{{ s.paused ? 'paused' : when(s.next, '') }}</td>
            <td>{{ s.records }}</td>
            <td class="kbsrc-actions">
              <template v-if="s.registered && s.polls && s.here">
                <button v-if="!s.running" class="kb-link" @click="act(s, 'run')">run now</button>
                <button class="kb-link" @click="act(s, s.paused ? 'resume' : 'pause')">{{ s.paused ? 'resume' : 'pause' }}</button>
              </template>
              <button v-if="s.records && can('records.purge')" class="kb-link kbsrc-danger" @click="purge(s)">remove records</button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else-if="data" class="kb-dim">No sources.</p>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbsrc { margin: 1rem 0 2rem; }
.kbsrc-table { width: 100%; font-size: 0.88rem; }
.kbsrc-s { font-size: 0.8rem; color: var(--vp-c-text-2); }
.kbsrc-off { opacity: 0.6; }
.kbsrc-note { padding: 0.4rem 0.8rem; border-radius: 8px; background: var(--vp-c-brand-soft); }
.kbsrc-plugins { padding-left: 1.2rem; }
.kbsrc-running, .kbsrc-ok { color: var(--vp-c-brand-1); }
.kbsrc-failed { color: var(--vp-c-danger-1); }
.kbsrc-spent, .kbsrc-stopped { color: var(--vp-c-warning-1); }
.kbsrc-actions { white-space: nowrap; }
.kbsrc-actions .kb-link { margin-right: 0.6rem; font-size: 0.85rem; }
.kbsrc-danger { color: var(--vp-c-danger-1); }
</style>
