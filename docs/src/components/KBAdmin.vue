<!--
  Administering the shared service: people (their roles and sign-ins, and invitations), roles (their
  permissions and daily allowances), everyone's tokens, the dataset's keys, and the audit log. Each
  tab is there for those whose roles allow it.
-->
<script setup lang="ts">
import KBNeedsService from './KBNeedsService.vue'
import { ref, computed, onMounted, watch } from 'vue'
import KBMembers from './KBMembers.vue'
import KBPermissionPicker, { type PermissionGroup } from './KBPermissionPicker.vue'
import { mode, connect, getJSON, post, can, me } from './kbApi'
import { pageLink } from './kbLinks'
import { PROJECT_ROLES } from './kbLabels'
import { when } from './kbFormat'
import { plainCopy } from './kbUtils'

type User = { id: number; email: string; name: string; created_at: string; last_seen: string; disabled: boolean; roles: string[]; sign_ins: string[] }
type Invitation = { email: string; roles: string[]; created_at: string; accepted_at: string; projects: Record<string, string> }
type Role = { name: string; description: string; permissions: string[]; quotas: Record<string, number> }
type Token = { id: number; email: string; name: string; prefix: string; permissions: string[]; created_at: string; last_used: string; expires_at: string; revoked: boolean }
type Entry = { id: number; at: string; who: string; action: string; target: string; detail: Record<string, any> }

const tabs = computed(() => [
  can('users.manage') && { id: 'people', label: 'People' },
  can('users.manage') && { id: 'projects', label: 'Projects' },
  can('users.manage') && { id: 'roles', label: 'Roles' },
  can('tokens.manage') && { id: 'tokens', label: 'Tokens' },
  can('tokens.manage') && { id: 'keys', label: 'Dataset keys' },
  can('audit.view') && { id: 'audit', label: 'Audit log' },
].filter(Boolean) as { id: string; label: string }[])
const tab = ref('')
const error = ref('')
const note = ref('')

const users = ref<User[]>([]); const invitations = ref<Invitation[]>([]); const roleNames = ref<string[]>([])
const rolePermissions = ref<Record<string, string[]>>({})
const roles = ref<Role[]>([]); const permissionGroups = ref<PermissionGroup[]>([])
const allTokens = ref<Token[]>([]); const keys = ref<{ name: string; status: string }[]>([]); const audit = ref<Entry[]>([])
const keysWhy = ref('')   // why keys cannot be issued here, if they cannot
const invite = ref({ email: '', roles: ['Reader'], projects: {} as Record<string, string> })
// The projects an invitation can name, each joined with a role (see src/project_access.jl).
const projectKeys = ref<{ key: string; name: string }[]>([])
const editing = ref<Role | null>(null)
const issue = ref({ who: '', write: false }); const issued = ref<any>(null)

async function load(which = tab.value) {
  error.value = ''
  try {
    if (which === 'people') {
      ({ users: users.value, invitations: invitations.value, roles: roleNames.value,
         role_permissions: rolePermissions.value } = await getJSON('/api/admin/users'))
      projectKeys.value = (await getJSON('/api/projects')).projects.map((p: any) => ({ key: p.key, name: p.name }))
    }
    if (which === 'projects') projectKeys.value = (await getJSON('/api/projects')).projects.map((p: any) => ({ key: p.key, name: p.name }))
    if (which === 'roles') ({ roles: roles.value, permission_groups: permissionGroups.value } = await getJSON('/api/admin/roles'))
    if (which === 'tokens') allTokens.value = (await getJSON('/api/admin/tokens')).tokens
    if (which === 'keys') { const k = await getJSON('/api/admin/keys'); keys.value = k.keys; keysWhy.value = k.available ? '' : k.why }
    if (which === 'audit') audit.value = (await getJSON('/api/admin/audit')).entries
  } catch (e: any) { error.value = e.message }
}
watch(tab, t => load(t))
onMounted(async () => { await connect(); if (mode.value === 'live' && tabs.value.length) tab.value = tabs.value[0].id })

// The answer, or undefined when the request was refused (its error shown), so a form is kept to correct.
async function act(path: string, body: any, done: string) {
  error.value = ''; note.value = ''
  try { const r = await post(path, JSON.stringify(body)); note.value = done; await load(); return r ?? {} } catch (e: any) { error.value = e.message }
}
// Which roles include which: a role includes another whose permissions are all its own. With the
// roles a service starts with, each includes those before it (Admin ⊃ Curator ⊃ Learner ⊃ Reader).
function includes(a: string, b: string) {
  const pa = new Set(rolePermissions.value[a] ?? []), pb = rolePermissions.value[b] ?? []
  return a !== b && pb.length > 0 && pb.every(p => pa.has(p))
}
// The role a chosen set already gives through another of its roles.
const coveredBy = (chosen: string[], r: string) => chosen.find(c => includes(c, r))
// Choosing a role drops those it includes, which would add nothing.
const choose = (chosen: string[], r: string) => chosen.includes(r) ? chosen.filter(x => x !== r) : [...chosen.filter(x => !includes(r, x)), r]
function inclusionNote(chosen: string[]) {
  return chosen.map(c => { const inc = roleNames.value.filter(r => includes(c, r)); return inc.length ? `${c} includes ${inc.join(', ')}` : '' })
    .filter(Boolean).join('; ')
}
const setRoles = (u: User, r: string[]) => act(`/api/admin/users/${u.id}`, { roles: r }, `${u.email}: ${r.join(', ') || 'no role'}.`)
const toggleRole = (u: User, r: string) => setRoles(u, choose(u.roles, r))
const toggleInviteRole = (r: string) => invite.value.roles = choose(invite.value.roles, r)
const editRole = (r: Role) => editing.value = plainCopy(r)
// Trying the service as someone else: an account to view it as, and test accounts no one signs in to.
async function viewAs(u: User) {
  try { await post('/api/me/view-as', JSON.stringify({ user_id: u.id })); location.href = pageLink('/projects') }
  catch (e: any) { error.value = e.message }
}
const testAccount = ref({ name: '', role: 'Reader' })
async function addTestAccount() {
  if (await act('/api/admin/users/test', { name: testAccount.value.name, roles: [testAccount.value.role] }, `Added ${testAccount.value.name}.`))
    testAccount.value = { name: '', role: 'Reader' }
}
async function sendInvite() {
  if (await act('/api/admin/invite', invite.value, `Invited ${invite.value.email}.`))
    invite.value = { email: '', roles: ['Reader'], projects: {} }
}
// An allowance typed in, or none (no limit) when the field is emptied.
function setQuota(kind: string, e: Event) {
  const v = (e.target as HTMLInputElement).value
  const q = { ...editing.value!.quotas }
  if (v === '') delete q[kind]; else q[kind] = Number(v)
  editing.value!.quotas = q
}
function newRole() { editing.value = { name: '', description: '', permissions: ['read'], quotas: { tutor: 0, notebook: 0 } } }
async function saveRole() {
  const r = editing.value!
  if (await act('/api/admin/roles', r, `Saved ${r.name}.`)) editing.value = null
}
async function issueKey() { issued.value = await act('/api/admin/keys', issue.value, `Issued.`) }
async function olderAudit() {
  const before = audit.value.at(-1)?.id
  if (before) audit.value = [...audit.value, ...(await getJSON(`/api/admin/audit?before=${before}`)).entries]
}
const brief = (d: Record<string, any>) => Object.entries(d).filter(([k]) => k !== 'status')
  .map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`).join(' · ')
</script>

<template>
  <div class="kbad">
    <KBNeedsService shared :allowed="tabs.length > 0">
      <nav class="kbad-tabs"><button v-for="t in tabs" :key="t.id" :class="{ on: tab === t.id }" @click="tab = t.id">{{ t.label }}</button></nav>
      <p v-if="note" class="kbad-note">{{ note }}</p>
      <p v-if="error" class="kb-error">{{ error }}</p>

      <section v-if="tab === 'people'">
        <table class="kbad-table">
          <thead><tr><th>Person</th><th>Roles</th><th>Signs in with</th><th>Last seen</th><th></th></tr></thead>
          <tbody>
            <tr v-for="u in users" :key="u.id" :class="{ off: u.disabled }">
              <td>{{ u.name || u.email }}<div class="kbad-s">{{ u.email }}</div></td>
              <td><button v-for="r in roleNames" :key="r" :class="['kbad-chip', { on: u.roles.includes(r), inc: coveredBy(u.roles, r) }]"
                          :disabled="(u.email === me?.email && r === 'Admin') || !!coveredBy(u.roles, r)"
                          :title="u.email === me?.email && r === 'Admin' ? 'Can\'t remove your own admin'
                                  : coveredBy(u.roles, r) ? `Included in ${coveredBy(u.roles, r)}` : ''"
                          @click="toggleRole(u, r)">{{ r }}</button></td>
              <td class="kbad-s">{{ u.sign_ins.join(', ') }}</td><td class="kbad-s">{{ when(u.last_seen, '—') }}</td>
              <td><button v-if="u.email !== me?.email && !u.disabled" class="kb-link kbad-link" @click="viewAs(u)">view as</button>
                <button v-if="u.email !== me?.email" class="kb-link kbad-link"
                          @click="act(`/api/admin/users/${u.id}`, { disabled: !u.disabled }, `${u.disabled ? 'Enabled' : 'Disabled'} ${u.email}.`)">
                {{ u.disabled ? 'enable' : 'disable' }}</button></td>
            </tr>
          </tbody>
        </table>
        <form class="kbad-form" @submit.prevent="addTestAccount">
          <input v-model="testAccount.name" placeholder="Test account" required />
          <select v-model="testAccount.role" aria-label="Role"><option v-for="r in roleNames" :key="r" :value="r">{{ r }}</option></select>
          <button class="kb-primary kbad-button" :disabled="!testAccount.name.trim()">Add</button>
        </form>
        <h3>Invite someone</h3>
        <form class="kbad-form" @submit.prevent="sendInvite">
          <input v-model="invite.email" type="email" placeholder="Email" required />
          <div><button v-for="r in roleNames" :key="r" type="button" :class="['kbad-chip', { on: invite.roles.includes(r), inc: coveredBy(invite.roles, r) }]"
                       :disabled="!!coveredBy(invite.roles, r)" :title="coveredBy(invite.roles, r) ? `Included in ${coveredBy(invite.roles, r)}` : ''"
                       @click="toggleInviteRole(r)">{{ r }}</button>
            <div v-if="inclusionNote(invite.roles)" class="kbad-s">{{ inclusionNote(invite.roles) }}.</div></div>
          <div v-if="projectKeys.length" class="kbad-projects">
            <span class="kbad-s">Projects</span>
            <label v-for="p in projectKeys" :key="p.key" class="kbad-project">{{ p.key }}
              <select :value="invite.projects[p.key] ?? ''" :aria-label="`Role in ${p.key}`"
                      @change="(e: Event) => { const v = (e.target as HTMLSelectElement).value; v ? invite.projects[p.key] = v : delete invite.projects[p.key] }">
                <option value="">—</option><option v-for="r in PROJECT_ROLES" :key="r" :value="r">{{ r }}</option>
              </select></label>
          </div>
          <button class="kb-primary kbad-button" :disabled="!invite.email || !invite.roles.length">Invite</button>
        </form>
        <template v-if="invitations.length">
          <h3>Invitations</h3>
          <table class="kbad-table">
            <tbody><tr v-for="i in invitations" :key="i.email"><td>{{ i.email }}</td><td>{{ i.roles.join(', ') }}<span v-if="Object.keys(i.projects ?? {}).length" class="kbad-s">
              · {{ Object.entries(i.projects).map(([k, r]) => `${k} ${r}`).join(', ') }}</span></td>
              <td class="kbad-s">{{ i.accepted_at ? 'accepted ' + when(i.accepted_at) : 'invited ' + when(i.created_at) }}</td>
              <td><button v-if="!i.accepted_at" class="kb-link kbad-link" @click="act('/api/admin/uninvite', { email: i.email }, `Withdrew ${i.email}.`)">withdraw</button></td></tr></tbody>
          </table>
        </template>
      </section>

      <section v-if="tab === 'projects'">
        <div v-for="p in projectKeys" :key="p.key" class="kbad-project-block">
          <h3>{{ p.key }} · {{ p.name }}</h3>
          <KBMembers :project="p.key" manages />
        </div>
        <p v-if="!projectKeys.length" class="kbad-s">No projects yet.</p>
      </section>

      <section v-if="tab === 'roles'">
        <div v-if="editing" class="kbad-editor">
          <input v-model="editing.name" placeholder="Name" />
          <input v-model="editing.description" placeholder="Description" />
          <KBPermissionPicker v-model="editing.permissions" :groups="permissionGroups" />
          <p class="kbad-s">Daily limits (empty = none)</p>
          <label>Tutor <input :value="editing.quotas.tutor" type="number" min="0" class="kbad-n" @input="setQuota('tutor', $event)" /></label>
          <label>Notebooks <input :value="editing.quotas.notebook" type="number" min="0" class="kbad-n" @input="setQuota('notebook', $event)" /></label>
          <div class="kbad-row"><button class="kb-primary kbad-button" :disabled="!editing.name.trim()" @click="saveRole">Save</button>
            <button class="kb-link kbad-link" @click="editing = null">cancel</button></div>
        </div>
        <template v-else>
          <table class="kbad-table">
            <thead><tr><th>Role</th><th>Permissions</th><th>Daily limits</th><th></th></tr></thead>
            <tbody><tr v-for="r in roles" :key="r.name">
              <td><strong>{{ r.name }}</strong><div class="kbad-s">{{ r.description }}</div></td>
              <td class="kbad-s">{{ r.permissions.join(', ') }}</td>
              <td class="kbad-s">tutor {{ r.quotas.tutor ?? '∞' }} · notebooks {{ r.quotas.notebook ?? '∞' }}</td>
              <td><button class="kb-link kbad-link" @click="editRole(r)">edit</button>
                <button v-if="r.name !== 'Admin'" class="kb-link kbad-link" @click="act('/api/admin/roles', { name: r.name, delete: true }, `Removed ${r.name}.`)">remove</button></td>
            </tr></tbody>
          </table>
          <button class="kb-primary kbad-button" @click="newRole">Add role</button>
        </template>
      </section>

      <section v-if="tab === 'tokens'">
        <table v-if="allTokens.length" class="kbad-table">
          <thead><tr><th>Whose</th><th>Name</th><th>Permissions</th><th>Last used</th><th>Expires</th><th></th></tr></thead>
          <tbody><tr v-for="t in allTokens" :key="t.id" :class="{ off: t.revoked }">
            <td>{{ t.email }}</td><td>{{ t.name }} <code>{{ t.prefix }}…</code></td><td class="kbad-s">{{ t.permissions.join(', ') }}</td>
            <td class="kbad-s">{{ when(t.last_used, '—') }}</td><td class="kbad-s">{{ when(t.expires_at, 'never') }}</td>
            <td><span v-if="t.revoked" class="kbad-s">revoked</span>
              <button v-else class="kb-link kbad-link" @click="act(`/api/admin/tokens/${t.id}/revoke`, {}, `Revoked ${t.name}.`)">revoke</button></td>
          </tr></tbody>
        </table>
        <p v-else class="kbad-dim">No tokens.</p>
      </section>

      <section v-if="tab === 'keys'">
        <p class="kbad-dim">R2 dataset keys<span v-if="keysWhy">: unavailable ({{ keysWhy }})</span></p>
        <table v-if="keys.length" class="kbad-table"><tbody>
          <tr v-for="k in keys" :key="k.name"><td>{{ k.name }}</td><td class="kbad-s">{{ k.status }}</td>
            <td><button class="kb-link kbad-link" @click="act('/api/admin/keys', { who: k.name.split(': ').slice(1).join(': '), revoke: true }, `Revoked ${k.name}.`)">revoke</button></td></tr>
        </tbody></table>
        <div v-if="issued" class="kbad-issued">
          <p><strong>{{ issued.name }}</strong> (shown once): send the file; they install it with <code>zemi token add {{ issued.file_name }}</code></p>
          <a class="kb-primary kbad-button" :href="'data:application/toml;charset=utf-8,' + encodeURIComponent(issued.file)" :download="issued.file_name">Save {{ issued.file_name }}</a>
          <button class="kb-link kbad-link" @click="issued = null">done</button>
        </div>
        <form v-else-if="!keysWhy" class="kbad-form" @submit.prevent="issueKey">
          <input v-model="issue.who" placeholder="Name" required />
          <label><input v-model="issue.write" type="checkbox" /> publishes</label>
          <button class="kb-primary kbad-button" :disabled="!issue.who.trim()">Issue key</button>
        </form>
      </section>

      <section v-if="tab === 'audit'">
        <table class="kbad-table">
          <thead><tr><th>When</th><th>Who</th><th>What</th><th>Details</th></tr></thead>
          <tbody><tr v-for="e in audit" :key="e.id">
            <td class="kbad-s">{{ when(e.at, '—') }}</td><td>{{ e.who }}</td>
            <td><code>{{ e.action }}</code><span v-if="e.detail.status >= 400" class="kb-error"> refused</span></td>
            <td class="kbad-s">{{ brief(e.detail) }}</td></tr></tbody>
        </table>
        <button v-if="audit.length >= 200" class="kb-link kbad-link" @click="olderAudit">older</button>
      </section>
    </KBNeedsService>
  </div>
</template>

<style scoped>
.kbad-dim, .kbad-s { color: var(--vp-c-text-2); }
.kbad-s { font-size: 0.8rem; }
.kbad-note { padding: 0.4rem 0.8rem; border-radius: 8px; background: var(--vp-c-brand-soft); }
.kbad-tabs { display: flex; gap: 0.3rem; border-bottom: 1px solid var(--vp-c-divider); margin: 1rem 0; flex-wrap: wrap; }
.kbad-tabs button { background: none; border: none; padding: 0.5rem 0.9rem; cursor: pointer; color: var(--vp-c-text-2); font: inherit; border-bottom: 2px solid transparent; }
.kbad-tabs button.on { color: var(--vp-c-brand-1); border-bottom-color: var(--vp-c-brand-1); }
.kbad-table { width: 100%; font-size: 0.88rem; }
.kbad-table tr.off { opacity: 0.5; }
.kbad-chip { margin: 0.1rem 0.3rem 0.1rem 0; padding: 0.1rem 0.6rem; border-radius: 12px; border: 1px solid var(--vp-c-divider);
  background: none; color: var(--vp-c-text-2); cursor: pointer; font-size: 0.8rem; }
.kbad-chip:disabled { cursor: not-allowed; opacity: 0.7; }
.kbad-chip.inc { border-style: dashed; color: var(--vp-c-brand-1); opacity: 0.6; }
.kbad-chip.inc::before { content: '✓ '; }
.kbad-chip.on { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbad-link { margin-right: 0.6rem; }
.kbad-button { padding: 0.4rem 0.9rem; }
.kbad-button:disabled { opacity: 0.5; cursor: default; }
.kbad-form, .kbad-editor { display: flex; flex-direction: column; gap: 0.6rem; max-width: 40rem; margin: 0.8rem 0; }
.kbad-form input:not([type=checkbox]), .kbad-editor > input { padding: 0.4rem 0.7rem; border-radius: 8px; border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbad-n { width: 5rem; margin-left: 0.4rem; padding: 0.2rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbad-row { display: flex; gap: 1rem; align-items: center; }
.kbad-issued { padding: 0.8rem 1rem; border-radius: 10px; background: var(--vp-c-bg-soft); overflow-wrap: anywhere; }
.kbad-projects { display: flex; flex-wrap: wrap; gap: 0.6rem; align-items: center; }
.kbad-project { display: inline-flex; gap: 0.3rem; align-items: center; font-size: 0.85rem; }
.kbad-project-block { margin: 0.6rem 0 1rem; }
.kbad-project-block h3 { margin: 0 0 0.2rem; }
</style>
