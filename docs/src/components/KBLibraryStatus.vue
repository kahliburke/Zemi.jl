<!--
  One's library on the account page (see library_overview in src/library_reading.jl): each folder kept
  in step with it, what it holds and when it last changed, how much of the space it uses, and the
  `zemi connect` sign-ins that reach it, each disconnected here. Sharing what it holds is on the
  Documents page.
-->
<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { getJSON, post, api } from './kbApi'
import { kbPage } from './kbLinks'
import { bytes, when } from './kbFormat'

type Folder = { name: string; files: number; bytes: number; vault: boolean; documents: number; changed: string }
type Connection = { id: number; name: string; created_at: string; last_used: string }
type Library = { folders: Folder[]; used: number; limit: number; reading: boolean; connections: Connection[] }

const lib = ref<Library | null>(null)
const error = ref('')
async function load() {
  try { lib.value = await getJSON('/api/library') } catch (e: any) { error.value = e.message }
}
// While it is being read, look again now and then, to show when it is done.
let timer: ReturnType<typeof setInterval> | undefined
onMounted(async () => {
  await load()
  timer = setInterval(() => { if (lib.value?.reading) load() }, 5000)
})
onUnmounted(() => clearInterval(timer))

async function disconnect(c: Connection) {
  if (!confirm(`Disconnect ${c.name}? It stops keeping its folders in step until it signs in again.`)) return
  try { await post(`/api/me/tokens/${c.id}/revoke`, '{}'); await load() } catch (e: any) { error.value = e.message }
}

// The machine a sign-in is from, as zemi connect names it ("zemi connect on <machine>").
const machine = (c: Connection) => c.name.replace(/^zemi connect on /, '').replace(/ \(connected\)$/, '')
const share = computed(() => lib.value && lib.value.limit ? Math.min(100, (100 * lib.value.used) / lib.value.limit) : 0)
const command = computed(() => `zemi connect ${new URL(api.value || '/', location.href).origin} ~/Documents/Notes`)
</script>

<template>
  <section class="kbl">
    <h2>Your library</h2>
    <p class="kb-dim">Your notes and files, kept in step from folders on your machines. Only you see them until you share
      them on <a :href="`${kbPage('manage')}?state=mine`">Documents</a>.</p>
    <p v-if="error" class="kb-error">{{ error }}</p>
    <template v-if="lib">
      <div class="kbl-usage" :title="`${bytes(lib.used)} of ${bytes(lib.limit)}`">
        <div class="kbl-bar"><div :style="{ width: `${share}%` }" /></div>
        <span class="kb-dim">{{ bytes(lib.used) }} of {{ bytes(lib.limit) }}</span>
        <span v-if="lib.reading" class="kbl-reading">reading what changed…</span>
      </div>

      <table v-if="lib.folders.length" class="kbl-table">
        <thead><tr><th>Folder</th><th>Files</th><th>Documents</th><th>Last changed</th></tr></thead>
        <tbody>
          <tr v-for="f in lib.folders" :key="f.name">
            <td><code>{{ f.name || '(top level)' }}</code><span v-if="f.vault" class="kbl-tag">Obsidian vault</span></td>
            <td>{{ f.files }} · {{ bytes(f.bytes) }}</td>
            <td>{{ f.documents }}</td>
            <td>{{ when(f.changed, '—') }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else class="kb-dim">Nothing is in it yet.</p>

      <h3>Connected</h3>
      <table v-if="lib.connections.length" class="kbl-table">
        <thead><tr><th>Machine</th><th>Connected</th><th>Last synced</th><th></th></tr></thead>
        <tbody>
          <tr v-for="c in lib.connections" :key="c.id">
            <td>{{ machine(c) }}</td>
            <td>{{ when(c.created_at, '—') }}</td>
            <td>{{ when(c.last_used, 'never') }}</td>
            <td><button class="kb-link" @click="disconnect(c)">disconnect</button></td>
          </tr>
        </tbody>
      </table>
      <p v-else class="kb-dim">No machine keeps a folder in step with it.</p>
      <p class="kb-dim kbl-how">To keep a folder in step, an Obsidian vault say, run on your machine:
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
.kbl-how { margin-top: 0.8rem; }
.kbl-how code { overflow-wrap: anywhere; }
</style>
