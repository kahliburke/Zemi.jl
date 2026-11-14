<!--
  The Zotero groups a project's library is kept in step with (see src/zotero_links.jl): each with its
  items and when it was last read, linked and unlinked here by the project's maintainers. A private
  group's API key is given once, when it is linked, and never shown again.
-->
<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { getJSON, post } from './kbApi'
import { when } from './kbFormat'

const props = defineProps<{ project: string }>()
const emit = defineEmits<{ (e: 'read'): void }>()

type Group = { group: string; name: string; project: string; linked_by: string; linked_at: string; configured: boolean;
               private: boolean; read: string; items: number; error: string }
const groups = ref<Group[]>([])
const mayLink = ref(false)
const linking = ref<{ group: string; key: string } | null>(null)
const busy = ref(false)
const error = ref('')
const said = ref('')

async function load() {
  try {
    const r = await getJSON(`/api/projects/${encodeURIComponent(props.project)}/zotero`)
    const before = groups.value.map(g => g.read).join()
    groups.value = r.groups; mayLink.value = r.may_link
    if (before && before !== groups.value.map(g => g.read).join()) emit('read')
  } catch (e: any) { error.value = e.message }
}
// A group just linked is read in the background: look again until it has been.
let timer: ReturnType<typeof setInterval> | undefined
onMounted(() => { load(); timer = setInterval(() => { if (groups.value.some(g => !g.read)) load() }, 4000) })
onUnmounted(() => clearInterval(timer))

async function link() {
  if (!linking.value) return
  busy.value = true; error.value = ''; said.value = ''
  try {
    const r = await post(`/api/projects/${encodeURIComponent(props.project)}/zotero`,
                         JSON.stringify({ group: linking.value.group, key: linking.value.key }))
    said.value = `Linked ${r.name || 'group ' + r.group}: reading its ${r.items} item${r.items === 1 ? '' : 's'} now.`
    linking.value = null
    await load()
  } catch (e: any) { error.value = e.message }
  busy.value = false
}

async function unlink(g: Group) {
  if (!confirm(`Stop reading ${g.name || 'group ' + g.group}? What it brought in stays in the library.`)) return
  error.value = ''
  try {
    await post(`/api/projects/${encodeURIComponent(props.project)}/zotero/${g.group}/unlink`)
    await load()
  } catch (e: any) { error.value = e.message }
}
</script>

<template>
  <section v-if="groups.length || mayLink" class="kbz">
    <div class="kbz-head">
      <b>Zotero</b>
      <span v-if="!groups.length" class="kb-dim">Keep this library in step with a Zotero group's.</span>
      <span class="kbz-spacer"></span>
      <button v-if="mayLink && !linking" class="kbz-small" @click="linking = { group: '', key: '' }">Link a group</button>
    </div>
    <ul v-if="groups.length" class="kbz-list">
      <li v-for="g in groups" :key="g.group">
        <a :href="`https://www.zotero.org/groups/${g.group}`" target="_blank" rel="noopener">{{ g.name || `Group ${g.group}` }}</a>
        <span v-if="g.private" class="kbz-tag">private</span>
        <span class="kb-dim">
          {{ g.read ? `${g.items} item${g.items === 1 ? '' : 's'} · read ${when(g.read)}` : 'reading…' }}
          <template v-if="g.configured"> · set in the server's config</template>
          <template v-else-if="g.linked_by"> · linked by {{ g.linked_by }}</template>
        </span>
        <span v-if="g.error" class="kb-error kbz-error">{{ g.error }}</span>
        <button v-if="mayLink && !g.configured" class="kb-link kbz-unlink" @click="unlink(g)">unlink</button>
      </li>
    </ul>
    <form v-if="linking" class="kbz-form" @submit.prevent="link">
      <label>The group's address or number
        <input v-model="linking.group" placeholder="https://www.zotero.org/groups/6748949/…" required /></label>
      <label>API key, for a private group
        <input v-model="linking.key" type="password" autocomplete="off" placeholder="From zotero.org/settings/keys, with read access to the group" /></label>
      <div class="kbz-actions">
        <button class="kb-primary kbz-button" :disabled="!linking.group.trim() || busy">{{ busy ? 'Checking with Zotero…' : 'Link' }}</button>
        <button type="button" class="kbz-small" @click="linking = null">Cancel</button>
      </div>
    </form>
    <p v-if="said" class="kbz-said">{{ said }}</p>
    <p v-if="error" class="kb-error kbz-said">{{ error }}</p>
  </section>
</template>

<style scoped>
.kbz { margin: 1rem 0 0.2rem; padding: 0.7rem 1rem; border-radius: 12px; background: var(--vp-c-bg-soft); border: 1px solid var(--vp-c-divider); }
.kbz-head { display: flex; align-items: center; gap: 0.6rem; }
.kbz-spacer { flex: 1; }
.kbz-small { border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-1); border-radius: 8px;
  padding: 0.2rem 0.6rem; font: inherit; font-size: 0.82rem; cursor: pointer; }
.kbz-list { list-style: none; margin: 0.5rem 0 0; padding: 0; display: grid; gap: 0.3rem; }
.kbz-list li { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.5rem; }
.kbz-tag { font-size: 0.72rem; padding: 0 0.35rem; border-radius: 4px; background: var(--vp-c-default-soft); color: var(--vp-c-text-2); }
.kbz-error { font-size: 0.8rem; }
.kbz-unlink { margin-left: auto; font-size: 0.8rem; }
.kbz-form { display: grid; gap: 0.5rem; margin-top: 0.7rem; }
.kbz-form label { display: grid; gap: 0.25rem; font-size: 0.78rem; font-weight: 600; color: var(--vp-c-text-2); }
.kbz-form input { padding: 0.4rem 0.6rem; border-radius: 8px; border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg);
  color: var(--vp-c-text-1); font: inherit; font-size: 0.9rem; font-weight: 400; }
.kbz-actions { display: flex; gap: 0.5rem; }
.kbz-said { margin: 0.5rem 0 0; font-size: 0.85rem; }
</style>
