<script setup lang="ts">
// A paper's reference list, folded, after the papers of the knowledge base it cites ("Here").
import KBTitle from './KBTitle.vue'
import { computed } from 'vue'
import { kbPage } from './kbLinks'

type Link = { id: string; slug: string; title: string; page: string }
type Reference = { label: string; text: string; doi: string | null; arxiv: string | null; cites: Link | null }
const props = defineProps<{ references: Reference[]; here: (Link & { label: string })[] }>()
const numbered = computed(() => props.references.every(r => r.label !== ''))
const linkHref = (l: Link) => kbPage(l.page)
</script>

<template>
  <p v-if="here.length"><strong>Here:</strong>
    <template v-for="(h, j) in here" :key="h.slug + j"><template v-if="j"> · </template>
      <a :href="linkHref(h)"><KBTitle :text="h.title" /></a><template v-if="h.label"> (ref. {{ h.label }})</template></template>
  </p>
  <details class="details custom-block">
    <summary>{{ references.length }} references<template v-if="here.length"> · {{ here.length }} here</template></summary>
    <component :is="numbered ? 'ol' : 'ul'" class="kb-refs">
      <li v-for="(r, j) in references" :key="j" :value="numbered ? r.label : undefined">{{ r.text }}
        <span v-if="r.doi || r.arxiv" class="kb-ref-links">
          <a v-if="r.doi" :href="`https://doi.org/${r.doi}`">DOI</a>
          <a v-if="r.arxiv" :href="`https://arxiv.org/abs/${r.arxiv}`">arXiv</a></span>
        <template v-if="r.cites"><br><a class="kb-ref-kb" :href="linkHref(r.cites)">Here: <KBTitle :text="r.cites.title" /></a></template>
      </li>
    </component>
  </details>
</template>
