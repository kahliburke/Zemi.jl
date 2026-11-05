<!--
  The page of one file of a codebase, made from its data file (see kbTemplates.ts and
  `code_file_json`): its place in the tree, summary, the tasks that changed it, and its definitions
  with their source; a notebook's cells instead, for a notebook.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { codebaseHref } from './kbLinks'
import { anchorOf, anchors as unique, fenced } from './kbUtils'
import KBFileWork from './KBFileWork.vue'
import KBCodeNotebook from './KBCodeNotebook.vue'

type Definition = { name: string; doc: string; first_line: number; last_line: number; source: string }
type File = { codebase: { id: string; slug: string; title: string }; path: string; dirs: string[]; lines: number
              language: string; fence: string; summary: string; notebook: string | null; definitions: Definition[] }

const { data: file, error, render } = useTemplatedPage<File>('code', 'No such file in this knowledge base.', { title: f => f.path })

const named = computed(() => (file.value?.definitions ?? []).filter(d => d.name).length)
// Each definition's anchor: its name's words, or its lines, kept apart (operators share words).
const anchors = computed(() => {
  const anchor = unique()
  return (file.value?.definitions ?? []).map(d => anchor(anchorOf(d.name) || `lines-${d.first_line}`))
})
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!file" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="file-path">{{ file.path }}</h1>
    <p><a :href="codebaseHref(file.codebase.slug)">{{ file.codebase.title }}</a><template v-for="d in file.dirs" :key="d"> › {{ d }}</template></p>
    <p><em>{{ file.lines }} lines · {{ file.language }}<template v-if="named"> · {{ named }} definitions</template></em></p>

    <template v-if="file.summary">
      <h2 id="summary">Summary</h2>
      <div v-html="render(file.summary)"></div>
    </template>
    <KBFileWork :codebase="file.codebase.id" :path="file.path" />

    <template v-if="file.notebook">
      <h2 id="notebook">Notebook</h2>
      <KBCodeNotebook :src="file.notebook" />
    </template>
    <template v-else-if="file.definitions.length">
      <h2 :id="named ? 'definitions' : 'contents'">{{ named ? 'Definitions' : 'Contents' }}</h2>
      <template v-for="(d, i) in file.definitions" :key="i">
        <h3 :id="anchors[i]"><code v-if="d.name">{{ d.name }}</code><template v-else>Lines {{ d.first_line }}–{{ d.last_line }}</template></h3>
        <div v-if="d.doc" v-html="render(d.doc)"></div>
        <details class="details custom-block">
          <summary>Source, lines {{ d.first_line }}–{{ d.last_line }}</summary>
          <div v-html="render(fenced(d.source, file.fence))"></div>
        </details>
      </template>
    </template>
  </template>
</template>

<style scoped>
</style>
