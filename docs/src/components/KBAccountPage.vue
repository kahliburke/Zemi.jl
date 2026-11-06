<!--
  A person's own account in the shared service: who they are (the name they are shown by, theirs to
  change), their roles, what they may do and
  today's allowances, and their API tokens, for scripts and for Claude: made with the permissions
  chosen (never more than their own), shown once, and revoked here.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import KBPermissionPicker, { type PermissionGroup } from './KBPermissionPicker.vue'
import { ref, computed, onMounted } from 'vue'
import { mode, connect, getJSON, post } from './kbApi'
import { day } from './kbFormat'

type Token = { id: number; name: string; prefix: string; permissions: string[]; created_at: string; expires_at: string;
               last_used: string; revoked: boolean }
type Account = { name: string; email: string; via: string; permissions: string[]; quotas: Record<string, number | null>;
                 accounts: boolean; roles: string[]; tokens: Token[]; permission_groups: PermissionGroup[] }
const acct = ref<Account | null>(null)
const error = ref('')
const name = ref('')
const days = ref(90)
// A new token's permissions: one of the usual sets, of those the person has, or chosen one by one.
const PRESETS = [
  { key: 'read', label: 'Read only', permissions: ['read'] },
  { key: 'tasks', label: 'Read and work on tasks', permissions: ['read', 'tasks.view', 'tasks.edit'] },
  { key: 'all', label: 'Everything you may do', permissions: null },
]
const preset = ref('read')
const chosen = ref<string[]>(['read'])
function pick(key: string) {
  preset.value = key
  const p = PRESETS.find(x => x.key === key)
  if (p) chosen.value = p.permissions ? p.permissions.filter(x => acct.value?.permissions.includes(x)) : [...(acct.value?.permissions ?? [])]
}
// The name they are shown by, as edited here.
const shownAs = ref('')
const savedName = ref(false)
async function saveName() {
  error.value = ''
  try {
    await post('/api/me', JSON.stringify({ name: shownAs.value }))
    await load()
    savedName.value = true
    setTimeout(() => { savedName.value = false }, 1500)
  } catch (e: any) { error.value = e.message }
}
const made = ref<{ token: string } | null>(null)
// Which of the new token's lines was copied last, to mark its button for a moment.
const copied = ref('')

async function load() {
  try {
    acct.value = await getJSON('/api/me')
    shownAs.value = acct.value?.name ?? ''
    if (preset.value !== 'choose') pick(preset.value)
  } catch (e: any) { error.value = e.message }
}
onMounted(async () => { await connect(); if (mode.value === 'live') await load() })

async function create() {
  error.value = ''
  try {
    made.value = await post('/api/me/tokens', JSON.stringify({ name: name.value, days: days.value, permissions: chosen.value }))
    name.value = ''
    await load()
  } catch (e: any) { error.value = e.message }
}
async function revoke(t: Token) {
  if (!confirm(`Revoke ${t.name}?`)) return
  try { await post(`/api/me/tokens/${t.id}/revoke`, '{}'); await load() } catch (e: any) { error.value = e.message }
}
async function copy(key: string, text: string) {
  await navigator.clipboard.writeText(text)
  copied.value = key
  setTimeout(() => { if (copied.value === key) copied.value = '' }, 1500)
}
const origin = computed(() => typeof location === 'undefined' ? '' : location.origin)
// The new token, and the commands that use it, each to copy.
const lines = computed(() => made.value ? [
  { key: 'token', label: 'Token', text: made.value.token },
  { key: 'mcp', label: 'Claude Code', text: `claude mcp add --transport http kb ${origin.value}/mcp --header "Authorization: Bearer ${made.value.token}"` },
  { key: 'curl', label: 'curl', text: `curl -H "Authorization: Bearer ${made.value.token}" ${origin.value}/api/status` },
] : [])
const live = computed(() => (acct.value?.tokens ?? []).filter(t => !t.revoked))
</script>

<template>
  <div class="kbac">
    <KBNeedsService shared>
      <template v-if="acct">
        <h2>{{ acct.name || acct.email }}</h2>
        <p class="kb-dim">{{ acct.email }} · {{ acct.roles.join(', ') || 'no role' }}</p>
        <form v-if="acct.accounts" class="kbac-name" @submit.prevent="saveName">
          <label>Shown as <input v-model="shownAs" maxlength="100" required /></label>
          <button class="kb-primary kbac-button" :disabled="!shownAs.trim() || shownAs.trim() === acct.name">{{ savedName ? 'Saved' : 'Save' }}</button>
        </form>
        <p class="kb-dim">Left today: tutor {{ acct.quotas.tutor ?? '∞' }} · notebooks {{ acct.quotas.notebook ?? '∞' }}</p>
        <details class="kbac-perms"><summary>Permissions ({{ acct.permissions.length }})</summary>
          <code v-for="p in acct.permissions" :key="p">{{ p }}</code>
        </details>

        <h2>Tokens</h2>
        <p class="kb-dim">Keep secret.</p>
        <table v-if="live.length" class="kbac-table">
          <thead><tr><th>Name</th><th>Begins</th><th>Permissions</th><th>Made</th><th>Last used</th><th>Expires</th><th></th></tr></thead>
          <tbody>
            <tr v-for="t in live" :key="t.id">
              <td>{{ t.name }}</td><td><code>{{ t.prefix }}…</code></td><td class="kbac-small">{{ t.permissions.join(', ') }}</td>
              <td>{{ day(t.created_at, '—') }}</td><td>{{ day(t.last_used, '—') }}</td><td>{{ day(t.expires_at, 'never') }}</td>
              <td><button class="kb-link kbac-link" @click="revoke(t)">revoke</button></td>
            </tr>
          </tbody>
        </table>
        <p v-else class="kb-dim">No tokens.</p>

        <div v-if="made" class="kbac-made">
          <p><strong>New token</strong> · shown once</p>
          <div v-for="l in lines" :key="l.key" class="kbac-line">
            <span class="kbac-line-label">{{ l.label }}</span>
            <code class="kbac-secret">{{ l.text }}</code>
            <button class="kbac-copy" :title="copied === l.key ? 'Copied' : 'Copy'" :aria-label="`Copy ${l.label}`" @click="copy(l.key, l.text)">
              <svg v-if="copied === l.key" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/></svg>
              <svg v-else viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M16 1H4a2 2 0 0 0-2 2v14h2V3h12V1zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H8V7h11v14z"/></svg>
            </button>
          </div>
          <button class="kb-link kbac-link" @click="made = null">done</button>
        </div>
        <form v-else class="kbac-form" @submit.prevent="create">
          <input v-model="name" placeholder="Name" required />
          <label>Expires (days, 0 = never) <input v-model.number="days" type="number" min="0" class="kbac-days" /></label>
          <div class="kbac-presets">
            <label v-for="p in PRESETS" :key="p.key"><input type="radio" :checked="preset === p.key" @change="pick(p.key)" /> {{ p.label }}</label>
            <label><input type="radio" :checked="preset === 'choose'" @change="preset = 'choose'" /> Choose…</label>
          </div>
          <KBPermissionPicker v-if="preset === 'choose'" v-model="chosen" :groups="acct.permission_groups" :available="acct.permissions" />
          <button class="kb-primary kbac-button" :disabled="!name.trim() || !chosen.length">Create token</button>
        </form>
      </template>
    </KBNeedsService>
    <p v-if="error" class="kb-error kbac-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbac-name { display: flex; align-items: center; gap: 0.6rem; margin: 0.4rem 0 0.8rem; }
.kbac-name input { margin-left: 0.4rem; padding: 0.3rem 0.6rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbac-perms code { margin: 0 0.3rem 0.3rem 0; display: inline-block; }
.kbac-table { width: 100%; font-size: 0.88rem; }
.kbac-small { font-size: 0.78rem; color: var(--vp-c-text-2); }
.kbac-form { display: flex; flex-direction: column; gap: 0.6rem; max-width: 36rem; margin-top: 1rem; }
.kbac-form input:not([type]) { padding: 0.45rem 0.7rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbac-days { width: 5rem; padding: 0.2rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbac-button { align-self: flex-start; }
.kbac-button:disabled { opacity: 0.5; cursor: default; }
.kbac-made { margin-top: 1rem; padding: 0.8rem 1rem; border-radius: 10px; background: var(--vp-c-bg-soft); }
.kbac-line { display: grid; grid-template-columns: 6.5rem 1fr auto; gap: 0.6rem; align-items: start; margin: 0.5rem 0; }
.kbac-line-label { color: var(--vp-c-text-2); font-size: 0.82rem; padding-top: 0.35rem; }
.kbac-secret { display: block; overflow-wrap: anywhere; font-size: 0.8rem; padding: 0.3rem 0.5rem; border-radius: 6px;
  background: var(--vp-c-bg-alt); }
.kbac-copy { display: flex; align-items: center; justify-content: center; width: 30px; height: 30px; border-radius: 6px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-2); cursor: pointer; }
.kbac-copy:hover { color: var(--vp-c-brand-1); border-color: var(--vp-c-brand-1); }
.kbac-presets { display: flex; flex-wrap: wrap; gap: 0.4rem 1.2rem; font-size: 0.9rem; }
</style>
