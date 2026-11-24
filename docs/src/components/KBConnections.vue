<!--
  On the Configuration page of a knowledge base run for one person: the clients its owner connected by
  OAuth (a notebook citing it, `zemi connect`), each with what it may do and when it was last used,
  and Revoke, which ends its token and its refresh (see src/oauth.jl). The shared service lists a
  person's under Your account, Tokens.
-->
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getJSON, post } from './kbApi'
import { when } from './kbFormat'

type Connection = { id: number; name: string; scope: string; created_at: string; last_used: string; revoked: boolean }
const list = ref<Connection[] | null>(null)
const error = ref('')
const SCOPES: Record<string, string> = { read: 'reads it', library: 'keeps your library in step with a folder' }

async function load() {
  try { list.value = (await getJSON('/api/connections') as Connection[]).filter(c => !c.revoked) }
  catch (e: any) { error.value = e.message ?? String(e) }
}
async function revoke(c: Connection) {
  try { await post(`/api/connections/${c.id}/revoke`); await load() }
  catch (e: any) { error.value = e.message ?? String(e) }
}
onMounted(load)
</script>

<template>
  <h2>Connections</h2>
  <p class="kb-dim">Clients you allowed to reach this knowledge base, a notebook citing it, say. Revoking one ends its access; it asks you again to connect.</p>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!list" class="kb-dim">Loading…</p>
  <p v-else-if="!list.length" class="kb-dim">None yet.</p>
  <ul v-else class="kbcn">
    <li v-for="c in list" :key="c.id">
      <b>{{ c.name.replace(/ \(connected\)$/, '') }}</b> {{ SCOPES[c.scope] ?? c.scope }} ·
      connected {{ when(c.created_at) }}<template v-if="c.last_used"> · last used {{ when(c.last_used) }}</template>
      · <button type="button" class="kb-link" @click="revoke(c)">revoke</button>
    </li>
  </ul>
</template>

<style scoped>
.kbcn { padding-left: 1.2rem; }
.kbcn li { margin: 0.3rem 0; }
</style>
