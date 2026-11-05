<!--
  A title as text, with its mathematics (`$δf$`) set as mathematics: a paper's title from arXiv often
  has some. The Markdown renderer (kbMarkdown.ts) is loaded only for a title that has any.
-->
<script setup lang="ts">
import { shallowRef, computed, watch } from 'vue'
import { loadMarkdown, type Render } from './kbMarkdown'

const props = defineProps<{ text: string }>()
const render = shallowRef<Render | null>(null)
const math = computed(() => /\$[^$\n]+\$|\\\(.+?\\\)/.test(props.text ?? ''))
watch(math, async m => { if (m && !render.value && typeof window !== 'undefined') render.value = await loadMarkdown() }, { immediate: true })
const html = computed(() => math.value && render.value ? render.value(props.text, { inline: true }) : null)
</script>

<template>
  <span v-if="html" class="kb-title-math" v-html="html"></span><template v-else>{{ text }}</template>
</template>

<style scoped>
.kb-title-math :deep(svg) { vertical-align: -0.15em; }
</style>
