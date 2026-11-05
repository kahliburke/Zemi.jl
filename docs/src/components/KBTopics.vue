<!--
  The topics (primary arXiv categories) of the knowledge base's papers, most papers first, from
  papers.json, so a paper added counts without a build.
-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { topicHref } from './kbLinks'
import { loadPapers, type Paper } from './kbData'

const papers = ref<readonly Paper[] | null>(null)
const error = ref('')

const topics = computed(() => {
  const by = new Map<string, { id: string; title: string; papers: number; read: number }>()
  for (const p of papers.value ?? []) {
    if (!p.category) continue
    const t = by.get(p.category) ?? by.set(p.category, { id: p.category, title: p.category_title, papers: 0, read: 0 }).get(p.category)!
    t.papers++
    if (p.processed) t.read++
  }
  return [...by.values()].sort((a, b) => b.papers - a.papers)
})

onMounted(async () => {
  try { papers.value = await loadPapers() }
  catch (e: any) { error.value = `The topics could not be listed: ${e.message ?? e}` }
})
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!papers" class="kb-dim">Loading…</p>
  <table v-else>
    <thead><tr><th style="text-align: left">Topic</th><th style="text-align: right">Papers</th><th style="text-align: right">Read in full</th></tr></thead>
    <tbody>
      <tr v-for="t in topics" :key="t.id">
        <td><a :href="topicHref(t.id)">{{ t.title }}</a></td>
        <td style="text-align: right">{{ t.papers }}</td><td style="text-align: right">{{ t.read }}</td>
      </tr>
    </tbody>
  </table>
</template>

<style scoped>
</style>
