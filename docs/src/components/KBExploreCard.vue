<script setup lang="ts">
// The explore page's card for the selected document: what it is and where it sits, its summary (a note's
// opening until it has one, else its abstract), what to do with it, and what links it and lies nearest.
import { computed } from 'vue'
import KBClampText from './KBClampText.vue'
import KBIcon from './KBIcon.vue'
import { exploreHref } from './kbLinks'
import type { Render } from './kbMarkdown'
import { KIND_COLOURS, byline, kindName, relation, type Detail, type Linked, type Near, type Node } from './kbExplore'

const props = defineProps<{ node: Node; detail: Detail | null; render: Render; colour: string; cluster: string
                            linked: Linked[]; nearest: Near[]; canGoBack: boolean; short: boolean }>()
defineEmits<{ close: []; back: []; open: []; cite: []; copyView: []; go: [node: Node] }>()

const shown = computed(() => (props.detail?.id === props.node.id ? props.detail : null))
const text = computed(() => shown.value ? shown.value.summary || shown.value.excerpt || shown.value.abstract : '')
const head = computed(() => shown.value?.summary ? 'Summary' : shown.value?.excerpt ? 'From the note' : 'Abstract')
const citable = computed(() => props.node.kind !== 'finding' && props.node.kind !== 'task')
</script>

<template>
  <aside :data-share-center="node.id" class="kbx-card" :class="{ short }">
    <button class="kbx-close" aria-label="Close" @click="$emit('close')">×</button>
    <p class="kbx-meta"><i class="kbx-swatch" :style="{ background: colour }"></i>{{ kindName(node.kind) }}<template
      v-if="node.year"> · {{ node.year }}</template><template v-if="node.read === false"> · abstract only</template></p>
    <p v-if="cluster" class="kbx-cluster" :title="cluster">{{ cluster }}</p>
    <h3><a :href="node.page" target="_blank" rel="noopener">{{ node.title }}</a></h3>
    <template v-if="shown">
      <p v-if="byline(shown)" class="kbx-byline">{{ byline(shown) }}</p>
      <KBClampText data-share-text v-if="text" :head="head" :html="render(text)" />
      <div v-if="shown.topics.length" class="kbx-topics"><span v-for="t in shown.topics" :key="t">{{ t }}</span></div>
    </template>
    <div class="kbx-actions kbx-tools">
      <button v-if="canGoBack" class="kbx-btn kbx-tool" title="Back to the document before (Backspace)" aria-label="Back" @click="$emit('back')">
        <KBIcon name="back" :size="16" /></button>
      <button class="kbx-btn kbx-tool" title="Open its page" aria-label="Open its page" @click="$emit('open')"><KBIcon name="open" :size="16" /></button>
      <button v-if="citable" class="kbx-btn kbx-tool" title="Copy its citation" aria-label="Copy its citation" @click="$emit('cite')">
        <KBIcon name="quote" :size="16" /></button>
      <a class="kbx-btn kbx-tool" :href="exploreHref(node.id)" title="Copy a link to this view" aria-label="Copy a link to this view"
         @click.prevent="$emit('copyView')"><KBIcon name="link" :size="16" /></a>
    </div>
    <template v-if="linked.length">
      <h4>Linked</h4>
      <ul class="kbx-list">
        <li v-for="l in linked" :key="l.node.id + l.kind">
          <i class="kbx-swatch" :style="{ background: KIND_COLOURS[l.node.kind] ?? '#999' }"></i>
          <a href="#" :title="l.node.title" @click.prevent="$emit('go', l.node)">{{ l.node.title }}</a>
          <span class="kbx-aside">{{ relation(l.kind, l.out) }}</span>
        </li>
      </ul>
    </template>
    <template v-if="nearest.length">
      <h4>Nearest in meaning</h4>
      <ul class="kbx-list">
        <li v-for="x in nearest" :key="x.node.id">
          <i class="kbx-swatch" :style="{ background: KIND_COLOURS[x.node.kind] ?? '#999' }"></i>
          <a href="#" :title="x.node.title" @click.prevent="$emit('go', x.node)">{{ x.node.title }}</a>
          <span class="kbx-aside"><span v-if="x.linked" class="kbx-tag">linked</span><span class="kbx-bar-track"><span class="kbx-bar-fill"
            :style="{ width: `${Math.max(4, Math.round(x.similarity * 100))}%` }"></span></span>{{ Math.round(x.similarity * 100) }}%</span>
        </li>
      </ul>
    </template>
  </aside>
</template>
