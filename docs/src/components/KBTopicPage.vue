<!--
  A topic's page (an arXiv category), made from the topic's data file (see kbTemplates.ts): its papers,
  newest first, from papers.json.
-->
<script setup lang="ts">
import { ref } from 'vue'
import { useTemplatedPage } from './kbTemplates'
import KBPaperList from './KBPaperList.vue'

type Topic = { id: string; title: string }
const { data: topic, error } = useTemplatedPage<Topic>('topics', 'No such topic in this knowledge base.',
                                                       { title: t => t.title, markdown: false })
const list = ref<InstanceType<typeof KBPaperList> | null>(null)
</script>

<template>
  <p v-if="error" class="kb-dim">{{ error }}</p>
  <p v-else-if="!topic" class="kb-dim">Loading…</p>
  <template v-else>
    <h1 id="topic-title">{{ topic.title }}</h1>
    <p><template v-if="list">{{ list.count }} papers</template><template v-else>Papers</template> in <code>{{ topic.id }}</code>, newest first.</p>
    <KBPaperList ref="list" :key="topic.id" :topic="topic.id" />
  </template>
</template>

<style scoped>
</style>
