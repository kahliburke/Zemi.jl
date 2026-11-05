<!--
  A codebase's page, made from its data file (see kbTemplates.ts and `codebase_page_json`): what it
  is, its facts and summary, the libraries holding it, its tree of files and its classification.
  Those who manage documents choose here who sees it (see src/document_access.jl).
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { manageHref } from './kbLinks'
import { mode, connect, can, post } from './kbApi'
import KBInLibraries from './KBInLibraries.vue'
import KBCodeTree from './KBCodeTree.vue'

type Access = 'open' | 'projects'
type Codebase = { id: string; slug: string; title: string; one_line: string; commit: string; files: number; lines: number
                  definitions: number; languages: { language: string; files: number }[]; summary: string; topics: string[]
                  access: Access; classification: { label: string; value: string }[]; tree: string; pages: string }

const { data: c, error, render } = useTemplatedPage<Codebase>('codebase', 'No such codebase in this knowledge base.', { title: x => x.title })

const languages = computed(() => (c.value?.languages ?? []).map(l => `${l.files} ${l.language}`).join(', '))

// Who sees it, as last chosen here, else as the page's data has it.
const chosen = ref<{ id: string; access: Access } | null>(null)
const access = computed(() => chosen.value && chosen.value.id === c.value?.id ? chosen.value.access : c.value?.access)
const manages = computed(() => mode.value === 'live' && can('paper.manage'))
const saving = ref(false)
const said = ref('')
const failed = ref('')
onMounted(connect)

async function choose(to: Access) {
  const id = c.value?.id
  if (!id || to === access.value) return
  saving.value = true; said.value = ''; failed.value = ''
  try {
    await post(`/api/documents/${encodeURIComponent(id)}/access`, JSON.stringify({ access: to }))
    chosen.value = { id, access: to }
    said.value = to === 'open' ? 'Every reader sees it once the site is refreshed.' : 'Only the members of its projects see it now.'
  } catch (e: any) { failed.value = e.message ?? String(e) }
  finally { saving.value = false }
}
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!c" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="codebase-title">{{ c.title }}</h1>
    <p v-if="c.one_line"><em>{{ c.one_line }}</em></p>
    <p><template v-if="c.commit">commit <code>{{ c.commit }}</code> · </template>{{ c.files }} files · {{ c.lines }} lines ·
      {{ c.definitions }} definitions<template v-if="languages"> · {{ languages }}</template></p>
    <div class="kb-buttons"><a class="kb-button kb-live-only" :href="manageHref(c.id)">Manage</a></div>
    <p v-if="manages" class="kbcb-access">
      <label>Seen by
        <select :value="access" :disabled="saving" @change="choose(($event.target as HTMLSelectElement).value as Access)">
          <option value="open">every reader</option>
          <option value="projects">the members of its projects</option>
        </select>
      </label>
      <span v-if="said" class="kb-dim">{{ said }}</span>
      <span v-if="failed" class="kb-error">{{ failed }}</span>
    </p>
    <p v-else-if="access === 'projects'" class="kb-dim">Visible to its projects' members only.</p>
    <KBInLibraries kind="codebase" :target="c.id" />

    <template v-if="c.summary">
      <h2 id="summary">Summary</h2>
      <div v-html="render(c.summary)"></div>
    </template>
    <p v-if="c.topics.length"><strong>Topics:</strong> {{ c.topics.join(' · ') }}</p>

    <h2 id="structure">Structure</h2>
    <KBCodeTree :key="c.id" :src="c.tree" :pages="c.pages" />

    <template v-if="c.classification.length">
      <h2 id="classification">Classification</h2>
      <ul><li v-for="x in c.classification" :key="x.label"><strong>{{ x.label }}:</strong> {{ x.value }}</li></ul>
    </template>
  </template>
</template>

<style scoped>
.kbcb-access { display: flex; flex-wrap: wrap; align-items: center; gap: 0.8rem; font-size: 0.9rem; }
.kbcb-access select { margin-left: 0.4rem; padding: 0.2rem 0.4rem; border-radius: 6px; border: 1px solid var(--vp-c-divider);
                      background: var(--vp-c-bg); color: var(--vp-c-text-1); font: inherit; }
</style>
