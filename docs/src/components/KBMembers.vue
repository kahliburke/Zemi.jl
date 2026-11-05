<!--
  A project's members (see src/project_access.jl): who belongs to it, each with a role there, as a
  line. For its owner and admins (`manages`), a dialog where roles are changed, people taken off,
  and people with accounts added.
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { getJSON, post } from './kbApi'
import { PROJECT_ROLES as ROLES } from './kbLabels'
import KBDialog from './KBDialog.vue'

const props = defineProps<{ project: string; manages: boolean }>()
type Member = { user_id: number; email: string; name: string; role: string }
type Person = { id: string; label: string; agent: boolean }

const members = ref<Member[]>([])
const people = ref<Person[] | null>(null)      // everyone with an account, once asked for
const open = ref(false)
const adding = ref({ who: '', role: 'contributor' })
const error = ref('')

async function load() {
  try { members.value = await getJSON(`/api/projects/${props.project}/members`) } catch (e: any) { error.value = e.message }
}
watch(() => props.project, () => { open.value = false; error.value = ''; load() }, { immediate: true })
async function openEditor() {
  open.value = true
  if (people.value === null) try { people.value = await getJSON('/api/tasks/people') } catch (e: any) { error.value = e.message }
}
// Those with accounts who are not members yet.
const others = computed(() => (people.value ?? []).filter(p => !p.agent && !members.value.some(m => m.email.toLowerCase() === p.id.toLowerCase())))
async function set(who: string, role: string) {
  try { members.value = await post(`/api/projects/${props.project}/members`, JSON.stringify({ who, role })); error.value = '' }
  catch (e: any) { error.value = e.message }
}
async function add() {
  if (!adding.value.who) return
  await set(adding.value.who, adding.value.role)
  adding.value.who = ''
}
const label = (m: Member) => m.name || m.email
</script>

<template>
  <div class="kbm">
    <span class="kbm-label">Members</span>
    <span v-if="!members.length" class="kbm-dim">None (admins only)</span>
    <span v-for="m in members" :key="m.user_id" class="kbm-chip" :title="m.email">{{ label(m) }} <span class="kbm-dim">{{ m.role }}</span></span>
    <button v-if="manages" class="kbm-small" @click="openEditor">Manage</button>
    <KBDialog v-if="open" width="min(34rem, 92vw)" top @close="open = false">
    <div class="kbm-editor">
      <div class="kbm-head"><h3>{{ project }} members</h3>
        <button class="kbm-close" aria-label="Close" @click="open = false">✕</button></div>
      <table>
        <tr v-for="m in members" :key="m.user_id">
          <td>{{ label(m) }} <span class="kbm-dim">{{ m.email }}</span></td>
          <td><select :value="m.role" :aria-label="`Role of ${label(m)}`" @change="set(m.email, ($event.target as HTMLSelectElement).value)">
            <option v-for="r in ROLES" :key="r" :value="r">{{ r }}</option></select></td>
          <td><button class="kbm-small" :aria-label="`Remove ${label(m)}`" title="Remove from the project" @click="set(m.email, '')">✕</button></td>
        </tr>
      </table>
      <form v-if="others.length" class="kbm-add" @submit.prevent="add">
        <select v-model="adding.who" aria-label="Person to add">
          <option value="">Add someone…</option>
          <option v-for="p in others" :key="p.id" :value="p.id">{{ p.label }}</option>
        </select>
        <select v-model="adding.role" aria-label="Their role"><option v-for="r in ROLES" :key="r" :value="r">{{ r }}</option></select>
        <button class="kbm-small" :disabled="!adding.who">Add</button>
      </form>
      <p v-if="error" class="kb-error kbm-error">{{ error }}</p>
    </div>
    </KBDialog>
    <p v-else-if="error" class="kb-error kbm-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbm { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; margin-top: 0.4rem; font-size: 0.85rem; }
.kbm-label { font-size: 0.72rem; letter-spacing: 0.05em; text-transform: uppercase; color: var(--vp-c-text-2); margin-right: 0.3rem; }
.kbm-dim { color: var(--vp-c-text-3); font-size: 0.8rem; }
.kbm-chip { padding: 0.05rem 0.5rem; border-radius: 999px; background: var(--vp-c-default-soft); }
.kbm-small { padding: 0.05rem 0.55rem; border-radius: 6px; border: 1px solid var(--vp-c-divider); background: none; color: var(--vp-c-text-2);
  font: inherit; font-size: 0.78rem; cursor: pointer; }
.kbm-small:disabled { opacity: 0.5; cursor: default; }
.kbm-editor { font-size: 0.85rem; }
.kbm-head { display: flex; align-items: center; margin-bottom: 0.5rem; }
.kbm-head h3 { flex: 1; margin: 0; border: none; padding: 0; font-size: 1rem; }
.kbm-close { border: none; background: none; color: var(--vp-c-text-2); cursor: pointer; }
.kbm-editor table { border-collapse: collapse; margin: 0 0 0.5rem; display: table; }
.kbm-editor td { padding: 0.15rem 0.6rem 0.15rem 0; border: none; }
.kbm-editor select { font: inherit; font-size: 0.82rem; padding: 0.1rem 0.3rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); }
.kbm-add { display: flex; gap: 0.4rem; align-items: center; }
.kbm-error { flex-basis: 100%; margin: 0.2rem 0 0; font-size: 0.82rem; }
</style>
