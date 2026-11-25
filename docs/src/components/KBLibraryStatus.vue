<!--
  One's library on the account page (see library_overview in src/library_reading.jl): each folder kept
  in step with it, what it holds and when it last changed, its bibliographies (the entries linking PDFs
  that are not synced, and what could not be read), how much of the space it uses, and the
  `zemi connect` sign-ins that reach it, each disconnected here. Sharing what it holds is on the
  Documents page.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { getJSON, post, api } from './kbApi'
import { kbPage } from './kbLinks'
import { bytes, when } from './kbFormat'

// A .bib file of the folder: its entries, the documents they came in as, those linking files not synced, and what could not be read.
type Bibliography = { path: string; entries: number; documents: number; missing: { key: string; files: string[] }[]; problems: string[] }
type Folder = { name: string; files: number; bytes: number; vault: boolean; bibliographies: Bibliography[]; documents: number; changed: string }
type Connection = { id: number; name: string; created_at: string; last_used: string }
type Library = { folders: Folder[]; used: number; limit: number; reading: boolean; connections: Connection[] }

const lib = ref<Library | null>(null)
const error = ref('')
async function load() {
  try { lib.value = await getJSON('/api/library') } catch (e: any) { error.value = e.message }
}
// Looked at again now and then: while it is being read, to show when it is done, and to keep which
// machines are syncing current.
let timer: ReturnType<typeof setInterval> | undefined
let ticks = 0
onMounted(async () => {
  await load()
  timer = setInterval(() => { ticks++; if (lib.value?.reading || ticks % 6 === 0) load() }, 5000)
})
onUnmounted(() => clearInterval(timer))

async function disconnect(c: Connection) {
  if (!confirm(`Sign out ${machine(c)}? It stops syncing until it signs in again.`)) return
  try { await post(`/api/me/tokens/${c.id}/revoke`, '{}'); await load() } catch (e: any) { error.value = e.message }
}

// The machine a sign-in is from, as zemi connect names it ("zemi connect on <machine>").
const machine = (c: Connection) => c.name.replace(/^zemi connect on /, '').replace(/ \(connected\)$/, '')
// A running zemi connect reaches the library every 10 seconds, which is recorded to the minute: one
// heard from in the last two minutes is syncing now.
const RUNNING_MS = 2 * 60 * 1000
const syncing = (c: Connection) => !!c.last_used && Date.now() - new Date(c.last_used).getTime() < RUNNING_MS
const bibliographies = computed(() => (lib.value?.folders ?? []).flatMap(f => f.bibliographies ?? []))
const share = computed(() => lib.value && lib.value.limit ? Math.min(100, (100 * lib.value.used) / lib.value.limit) : 0)
const command = computed(() => `zemi connect ${new URL(api.value || '/', location.href).origin} ~/Documents/Notes`)
</script>

<template>
  <section class="kbl">
    <h2>Your library</h2>
    <p class="kb-dim">Notes and files synced from your machines, private until you share them on
      <a :href="`${kbPage('manage')}?state=mine`">Documents</a>.</p>
    <p v-if="error" class="kb-error">{{ error }}</p>
    <template v-if="lib">
      <div class="kbl-usage" :title="`${bytes(lib.used)} of ${bytes(lib.limit)}`">
        <div class="kbl-bar"><div :style="{ width: `${share}%` }" /></div>
        <span class="kb-dim">{{ bytes(lib.used) }} of {{ bytes(lib.limit) }}</span>
        <span v-if="lib.reading" class="kbl-reading">reading changes…</span>
      </div>

      <table v-if="lib.folders.length" class="kbl-table">
        <thead><tr><th>Folder</th><th>Files</th><th>Documents</th><th>Last changed</th></tr></thead>
        <tbody>
          <tr v-for="f in lib.folders" :key="f.name">
            <td><code>{{ f.name || '(top level)' }}</code><span v-if="f.vault" class="kbl-tag">Obsidian vault</span><span
                v-if="f.bibliographies?.length" class="kbl-tag">BibTeX</span></td>
            <td>{{ f.files }} · {{ bytes(f.bytes) }}</td>
            <td>{{ f.documents }}</td>
            <td>{{ when(f.changed, '—') }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else class="kb-dim">Empty.</p>

      <template v-for="b in bibliographies" :key="b.path">
        <h3><code>{{ b.path }}</code></h3>
        <p class="kb-dim">{{ b.entries }} entries, {{ b.documents }} brought in as documents. Each is cited by its key in your notes
          and notebooks.</p>
        <details v-if="b.missing.length" class="kbl-missing">
          <summary>{{ b.missing.length }} {{ b.missing.length === 1 ? 'entry links a PDF' : 'entries link PDFs' }} not in your library</summary>
          <p class="kb-dim">Each came in by its DOI or arXiv id, or as a resource. To read the PDF, keep it in the folder you sync.</p>
          <ul><li v-for="m in b.missing" :key="m.key"><code>{{ m.key }}</code> <span class="kb-dim">{{ m.files.join(', ') }}</span></li></ul>
        </details>
        <details v-if="b.problems.length" class="kbl-missing">
          <summary>{{ b.problems.length }} could not be read</summary>
          <ul><li v-for="p in b.problems" :key="p">{{ p }}</li></ul>
        </details>
      </template>

      <h3>Machines</h3>
      <p class="kb-dim">Each syncs while <code>zemi connect</code> runs on it.</p>
      <table v-if="lib.connections.length" class="kbl-table">
        <thead><tr><th>Machine</th><th>Now</th><th>Last synced</th><th>Signed in</th><th></th></tr></thead>
        <tbody>
          <tr v-for="c in lib.connections" :key="c.id">
            <td>{{ machine(c) }}</td>
            <td><span :class="['kbl-state', { on: syncing(c) }]">{{ syncing(c) ? 'syncing' : 'not running' }}</span></td>
            <td>{{ when(c.last_used, 'never') }}</td>
            <td>{{ when(c.created_at, '—') }}</td>
            <td><button class="kb-link" :title="`Revoke ${machine(c)}'s sign-in`" @click="disconnect(c)">sign out</button></td>
          </tr>
        </tbody>
      </table>
      <p v-else class="kb-dim">None signed in.</p>
      <p class="kb-dim kbl-how">To sync a folder, such as an Obsidian vault or a folder with a <code>.bib</code> file and its PDFs:
        <code>{{ command }}</code></p>
    </template>
  </section>
</template>

<style scoped>
.kbl { margin-top: 1.5rem; }
.kbl-usage { display: flex; align-items: center; gap: 0.8rem; margin: 0.6rem 0 0.8rem; font-size: 0.88rem; }
.kbl-bar { width: 12rem; height: 6px; border-radius: 3px; background: var(--vp-c-bg-soft); overflow: hidden; }
.kbl-bar > div { height: 100%; background: var(--vp-c-brand-1); }
.kbl-reading { color: var(--vp-c-brand-1); font-size: 0.85rem; }
.kbl-table { width: 100%; font-size: 0.88rem; }
.kbl-tag { margin-left: 0.5rem; padding: 0.05rem 0.4rem; border-radius: 4px; font-size: 0.75rem;
  background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbl-state { color: var(--vp-c-text-3); }
.kbl-state::before { content: ''; display: inline-block; width: 7px; height: 7px; margin-right: 0.4rem; border-radius: 50%;
  background: var(--vp-c-text-3); vertical-align: 0.05em; }
.kbl-state.on { color: var(--vp-c-text-1); }
.kbl-state.on::before { background: var(--vp-c-brand-1); }
.kbl-how { margin-top: 0.8rem; }
.kbl-missing { margin: 0.4rem 0; font-size: 0.88rem; }
.kbl-missing summary { cursor: pointer; }
.kbl-missing ul { margin: 0.3rem 0 0; }
.kbl-how code { overflow-wrap: anywhere; }
</style>
