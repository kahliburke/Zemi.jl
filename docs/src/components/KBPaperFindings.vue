<!--
  On a paper's page, while the service serves it: the findings that rest on the paper, in the projects
  the reader can see, each with how it uses the paper (its page, a passage, a note on what it shows).
-->
<script setup lang="ts">
import { ref, shallowRef, onMounted } from 'vue'
import { findingHref } from './kbLinks'
import { mode, connect, can, getJSON } from './kbApi'
import { loadMarkdown, escapeText, type Render } from './kbMarkdown'

const props = defineProps<{ id: string }>()
type Use = { ref: string; project: string; claim: string; status: string; relation: string; page: number; excerpt: string; note: string }
const uses = ref<Use[]>([])
const markdown = shallowRef<Render>(escapeText)
const render = (s: string) => markdown.value(s, { refs: true })

onMounted(async () => {
  await connect()
  if (mode.value !== 'live' || !can('tasks.view')) return
  try { uses.value = await getJSON(`/api/findings?paper=${encodeURIComponent(props.id)}`) } catch { /* the page stands without them */ }
  if (uses.value.some(u => u.note)) markdown.value = await loadMarkdown()
})
const how = (u: Use) => u.relation === 'contradicts' ? 'contradicts it' : 'rests on it'
</script>

<template>
  <section v-if="uses.length" class="kbpf">
    <h2>In findings</h2>
    <ul>
      <li v-for="(u, i) in uses" :key="u.ref + i">
        <div class="kbpf-head">
          <a :href="findingHref(u.ref)" class="kbpf-ref">{{ u.ref }}</a>
          <span class="kbpf-claim">{{ u.claim }}</span>
        </div>
        <div class="kb-dim kbpf-dim">{{ how(u) }}<template v-if="u.page"> · p. {{ u.page }}</template> · {{ u.status }}</div>
        <blockquote v-if="u.excerpt" class="kbpf-excerpt">{{ u.excerpt }}</blockquote>
        <div v-if="u.note" class="kbpf-note kb-md" v-html="render(u.note)"></div>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.kbpf ul { list-style: none; padding: 0; }
.kbpf li { margin: 0 0 0.9rem; }
.kbpf-head { display: flex; gap: 0.5rem; align-items: baseline; }
.kbpf-ref { font-family: var(--vp-font-family-mono); font-size: 0.85rem; white-space: nowrap; }
.kbpf-claim { font-weight: 500; }
.kbpf-dim { font-size: 0.85rem; }
.kbpf-excerpt { margin: 0.3rem 0 0; padding-left: 0.6rem; border-left: 2px solid var(--vp-c-divider); color: var(--vp-c-text-2); font-size: 0.88rem; }
.kbpf-note { margin-top: 0.3rem; font-size: 0.9rem; }
</style>
