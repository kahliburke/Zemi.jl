<!--
  A paper's page, made from the paper's data file (see kbTemplates.ts and `paper_json`): every
  paper's address is a copy of one built page holding this component, which reads the paper from the
  address. Texts are Markdown with mathematics, rendered here; the parts that talk to the service
  (the tutor, notebooks, findings, figures, a section's text) are its components, as on other pages.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import { kbPage, topicHref, authorHref, manageHref, dayHref, notebookHref } from './kbLinks'
import { anchorOf, anchors as unique } from './kbUtils'
import KBChat from './KBChat.vue'
import KBNotebook from './KBNotebook.vue'
import KBInLibraries from './KBInLibraries.vue'
import KBPaperFindings from './KBPaperFindings.vue'
import KBFigures from './KBFigures.vue'
import KBExpandAll from './KBExpandAll.vue'
import KBSectionText from './KBSectionText.vue'
import KBPdf from './KBPdf.vue'
import { mode } from './kbApi'

type Link = { id: string; slug: string; title: string; page: string }
type Post = { source: string; author: string | null; where: string; on: string; rating?: string; reason?: string; day?: string }
type Section = { ord: number; level: number; title: string; summary: string; references?: boolean; text?: string; page?: number | null }
type Reference = { label: string; text: string; doi: string | null; arxiv: string | null; cites: Link | null }
type Paper = {
  id: string; slug: string; title: string; local: boolean; version: string; authors: { name: string; key: string }[]
  category: { id: string; title: string; slug: string } | null; published: string; venue: string | null
  document_type: string | null; relevance: { level: number; label: string; note: string } | null
  one_line: string | null; doi: string | null; daily: string; posts: Post[]
  summary: string; topics: string[]; abstract: string; processed: boolean
  notebooks: { title: string; page: string; summary: string; by: string }[]
  figures: number; tables: number; sections: Section[]; references: Reference[]; here: (Link & { label: string })[]
  cited_by: Link[]; classification: { label: string; value: string }[]; related: Link[]
}

const { data: paper, error, render } = useTemplatedPage<Paper>('papers', 'No such paper in this knowledge base.', { title: p => p.title })

const linkHref = (l: Link) => kbPage(l.page)

// Headings' anchors, as the outline and links to a heading use them: the heading's words, kept apart.
const anchors = computed(() => {
  const kept = unique()
  const anchor = (text: string) => kept(anchorOf(text) || 'section')
  const p = paper.value
  const fixed = Object.fromEntries(['Notebooks', 'Abstract', 'Figures', 'Sections', 'Cited by', 'Classification', 'Related papers']
    .map(h => [h, anchor(h)]))
  return { fixed, sections: (p?.sections ?? []).map(s => anchor(s.title)) }
})
const figuresTitle = computed(() => {
  const p = paper.value
  return !p ? '' : p.figures && p.tables ? 'Figures and tables' : p.figures ? 'Figures' : 'Tables'
})
const shownAuthors = computed(() => {
  const a = paper.value?.authors ?? []
  return a.length <= 12 ? { list: a, more: 0 } : { list: a.slice(0, 10), more: a.length - 10 }
})
const numbered = computed(() => (paper.value?.references ?? []).every(r => r.label !== ''))
const sectionTag = (level: number) => `h${Math.min(2 + level, 6)}`

</script>

<template>
  <div class="kbpp">
    <p v-if="error" class="kb-dim">{{ error }}</p>
    <p v-else-if="!paper" class="kb-dim">Loading…</p>
    <template v-else>
      <h1 id="paper-title" v-html="render(paper.title, { inline: true })"></h1>

      <div class="kb-paper-head">
        <div class="kb-badges">
          <a v-if="paper.category" class="kb-badge kb-badge-cat" :href="topicHref(paper.category.slug)">{{ paper.category.title }}</a>
          <span v-if="paper.published" class="kb-badge">{{ paper.published }}</span>
          <span v-if="paper.venue" class="kb-badge">{{ paper.venue }}</span>
          <span v-if="paper.document_type" class="kb-badge">{{ paper.document_type }}</span>
          <span v-if="paper.relevance" :class="['kb-badge', `kb-rel-${paper.relevance.level}`]" :title="paper.relevance.note">{{ paper.relevance.label }}</span>
        </div>
        <p v-if="paper.authors.length" class="kb-authors">
          <template v-for="(a, i) in shownAuthors.list" :key="a.key + i"><template v-if="i">, </template>
            <a class="kb-author" :href="authorHref(a.key)">{{ a.name }}</a></template>
          <template v-if="shownAuthors.more"> and {{ shownAuthors.more }} more</template>
        </p>
        <p v-if="paper.one_line" class="kb-oneline">{{ paper.one_line }}</p>
        <div class="kb-buttons">
          <template v-if="!paper.local">
            <a class="kb-button kb-button-brand" :href="`https://arxiv.org/abs/${paper.id}`">arXiv {{ paper.id }}</a>
            <KBPdf :id="paper.id" :version="paper.version" label="PDF" />
          </template>
          <KBPdf v-else-if="mode === 'live'" :id="paper.id" local label="Uploaded PDF" />
          <span v-else class="kb-button kb-button-plain">Uploaded PDF</span>
          <a v-if="paper.doi" class="kb-button" :href="`https://doi.org/${paper.doi}`">DOI</a>
          <a class="kb-button kb-live-only" :href="manageHref(paper.id)">Manage</a>
        </div>
        <p v-for="(m, i) in paper.posts" :key="i" class="kb-posted">
          <a v-if="m.day" :href="dayHref(m.day)">{{ m.where }}</a>
          <span v-else-if="m.rating" :title="m.reason">{{ m.where }}, rated {{ m.rating }}</span>
          <template v-else>{{ m.where }}</template>
          <template v-if="m.author"> by <strong>{{ m.author }}</strong></template> on {{ m.on }}
        </p>
      </div>

      <KBChat :id="paper.id" :title="paper.title" />

      <template v-if="paper.summary">
        <div class="tip custom-block"><p class="custom-block-title">Summary</p><div v-html="render(paper.summary)"></div></div>
        <div v-if="paper.topics.length" class="kb-tags"><span v-for="t in paper.topics" :key="t" class="kb-tag">{{ t }}</span></div>
      </template>

      <template v-if="paper.notebooks.length">
        <h2 :id="anchors.fixed['Notebooks']">Notebooks</h2>
        <ul>
          <li v-for="nb in paper.notebooks" :key="nb.page"><a :href="notebookHref(paper.slug, nb.page)">{{ nb.title }}</a>
            · {{ nb.by }}<template v-if="nb.summary"> · {{ nb.summary }}</template></li>
        </ul>
      </template>
      <KBNotebook :id="paper.id" />
      <KBInLibraries kind="paper" :target="paper.id" />
      <KBPaperFindings :id="paper.id" />

      <template v-if="paper.abstract">
        <h2 :id="anchors.fixed['Abstract']">Abstract</h2>
        <div v-html="render(paper.abstract)"></div>
      </template>

      <template v-if="paper.figures + paper.tables > 0">
        <h2 :id="anchors.fixed['Figures']">{{ figuresTitle }}</h2>
        <KBFigures :id="paper.id" :figures="paper.figures" :tables="paper.tables" />
      </template>

      <template v-if="paper.sections.length">
        <h2 :id="anchors.fixed['Sections']">Sections</h2>
        <KBExpandAll />
        <template v-for="(s, i) in paper.sections" :key="s.ord">
          <component :is="sectionTag(s.level)" :id="anchors.sections[i]" v-html="render(s.title, { inline: true })" />
          <div v-if="s.summary" v-html="render(s.summary)"></div>
          <template v-if="s.references">
            <p v-if="paper.here.length"><strong>Here:</strong>
              <template v-for="(h, j) in paper.here" :key="h.slug + j"><template v-if="j"> · </template>
                <a :href="linkHref(h)">{{ h.title }}</a><template v-if="h.label"> (ref. {{ h.label }})</template></template>
            </p>
            <details class="details custom-block">
              <summary>{{ paper.references.length }} references<template v-if="paper.here.length"> · {{ paper.here.length }} here</template></summary>
              <component :is="numbered ? 'ol' : 'ul'" class="kb-refs">
                <li v-for="(r, j) in paper.references" :key="j" :value="numbered ? r.label : undefined">{{ r.text }}
                  <span v-if="r.doi || r.arxiv" class="kb-ref-links">
                    <a v-if="r.doi" :href="`https://doi.org/${r.doi}`">DOI</a>
                    <a v-if="r.arxiv" :href="`https://arxiv.org/abs/${r.arxiv}`">arXiv</a></span>
                  <template v-if="r.cites"><br><a class="kb-ref-kb" :href="linkHref(r.cites)">Here: {{ r.cites.title }}</a></template>
                </li>
              </component>
            </details>
          </template>
          <KBSectionText v-else-if="s.text" :id="paper.id" :section="s.ord" :label="s.text" :page="s.page"
                         :version="paper.version" :local="paper.local" />
        </template>
      </template>

      <template v-if="paper.cited_by.length">
        <h2 :id="anchors.fixed['Cited by']">Cited by</h2>
        <ul><li v-for="c in paper.cited_by" :key="c.slug"><a :href="linkHref(c)">{{ c.title }}</a></li></ul>
      </template>

      <template v-if="paper.classification.length">
        <h2 :id="anchors.fixed['Classification']">Classification</h2>
        <ul><li v-for="c in paper.classification" :key="c.label"><strong>{{ c.label }}:</strong> {{ c.value }}</li></ul>
      </template>

      <template v-if="paper.related.length">
        <h2 :id="anchors.fixed['Related papers']">Related papers</h2>
        <ul><li v-for="r in paper.related" :key="r.slug"><a :href="linkHref(r)">{{ r.title }}</a></li></ul>
      </template>

      <div v-if="!paper.processed" class="tip custom-block"><p class="custom-block-title">Abstract only</p><p>Not read in full yet.</p></div>
    </template>
  </div>
</template>

<style scoped>
</style>
