<!--
  What the knowledge base holds, on the status page: its papers, layers, summaries, who shared papers
  and when, from status.json (see `contents_json`), which the service rewrites as papers are added.
-->
<script setup lang="ts">
import { nextTick, onMounted, ref } from 'vue'
import { useRoute } from 'vitepress'
import { pageDrawn } from './kbTemplates'
import { siteJSON } from './kbApi'

type Contents = {
  at: string
  papers: { recorded: number; full: number; uploaded: number; sections: number; passages: number }
  layers: { name: string; embeds: string; model: string; papers: number; vectors: number }[]
  summaries: { summarizer: string; model: string; papers: number; summaries: number; input: number; output: number }[]
  shared_by: { who: string; papers: number }[]
  years: { year: string; papers: number }[]
}
const route = useRoute()
const c = ref<Contents | null>(null)
const error = ref('')
const num = (n: number) => n.toLocaleString('en-GB')

onMounted(async () => {
  try {
    c.value = await siteJSON('/status.json')
    await nextTick()
    pageDrawn(route)                                   // its headings, for the page's outline
  } catch (e: any) { error.value = `The contents could not be read: ${e.message ?? e}` }
})
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!c" class="kb-dim">Loading…</p>
  <template v-else>
    <p>{{ c.at }}</p>
    <table>
      <thead><tr><th style="text-align: left">Papers</th><th></th></tr></thead>
      <tbody>
        <tr><td>Recorded</td><td style="text-align: right">{{ num(c.papers.recorded) }}</td></tr>
        <tr><td>Full text</td><td style="text-align: right">{{ num(c.papers.full) }}</td></tr>
        <tr><td>Uploaded as PDFs</td><td style="text-align: right">{{ num(c.papers.uploaded) }}</td></tr>
        <tr><td>Sections</td><td style="text-align: right">{{ num(c.papers.sections) }}</td></tr>
        <tr><td>Passages</td><td style="text-align: right">{{ num(c.papers.passages) }}</td></tr>
      </tbody>
    </table>

    <h3 id="embedding-layers">Embedding layers</h3>
    <table>
      <thead><tr><th style="text-align: left">Layer</th><th style="text-align: left">Embeds</th><th style="text-align: left">Model</th>
        <th style="text-align: right">Papers</th><th style="text-align: right">Vectors</th></tr></thead>
      <tbody><tr v-for="l in c.layers" :key="l.name"><td><code>{{ l.name }}</code></td><td>{{ l.embeds }}</td><td>{{ l.model }}</td>
        <td style="text-align: right">{{ num(l.papers) }}</td><td style="text-align: right">{{ num(l.vectors) }}</td></tr></tbody>
    </table>

    <template v-if="c.summaries.length">
      <h3 id="summaries">Summaries</h3>
      <table>
        <thead><tr><th style="text-align: left">Summarizer</th><th style="text-align: left">Model</th><th style="text-align: right">Papers</th>
          <th style="text-align: right">Summaries</th><th style="text-align: right">Input tokens</th><th style="text-align: right">Output tokens</th></tr></thead>
        <tbody><tr v-for="s in c.summaries" :key="s.summarizer"><td>{{ s.summarizer }}</td><td>{{ s.model }}</td>
          <td style="text-align: right">{{ num(s.papers) }}</td><td style="text-align: right">{{ num(s.summaries) }}</td>
          <td style="text-align: right">{{ num(s.input) }}</td><td style="text-align: right">{{ num(s.output) }}</td></tr></tbody>
      </table>
    </template>

    <template v-if="c.shared_by.length">
      <h3 id="shared-by">Shared by</h3>
      <table>
        <thead><tr><th style="text-align: left">Who</th><th style="text-align: right">Papers</th></tr></thead>
        <tbody><tr v-for="p in c.shared_by" :key="p.who"><td>{{ p.who }}</td><td style="text-align: right">{{ num(p.papers) }}</td></tr></tbody>
      </table>
    </template>

    <template v-if="c.years.length">
      <h3 id="added-per-year">Added per year</h3>
      <table>
        <thead><tr><th style="text-align: left">Year</th><th style="text-align: right">Papers</th></tr></thead>
        <tbody><tr v-for="y in c.years" :key="y.year"><td>{{ y.year }}</td><td style="text-align: right">{{ num(y.papers) }}</td></tr></tbody>
      </table>
    </template>
  </template>
</template>

<style scoped>
</style>
