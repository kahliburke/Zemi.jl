<!--
  The tutoring profile survey: a few questions about the learner's background and preferences, any of
  which can be skipped, each with room for a note. It is kept in this browser and passed to the tutor
  without anything identifying; it can be retaken or cleared from the settings panel.
-->
<script setup lang="ts">
import { ref } from 'vue'
import { QUESTIONS, saveProfile, optOut } from './kbProfile'

const emit = defineEmits<{ done: [] }>()
// Always begun blank: answers once given are not shown again, here or anywhere else.
const answers = ref<Record<string, string[]>>({})
const notes = ref<Record<string, string>>({})
const noting = ref(new Set<string>())

function choose(id: string, option: string, many: boolean | undefined) {
  const now = answers.value[id] ?? []
  answers.value = { ...answers.value, [id]: many ? (now.includes(option) ? now.filter(o => o !== option) : [...now, option])
                                                : (now[0] === option ? [] : [option]) }
}
const chosen = (id: string, option: string) => (answers.value[id] ?? []).includes(option)
function note(id: string) { const s = new Set(noting.value); s.add(id); noting.value = s }

function save() {
  saveProfile({ version: 1, answers: answers.value, notes: notes.value, updated: new Date().toISOString() })
  emit('done')
}
function decline() { optOut(); emit('done') }
</script>

<template>
  <div class="kbp">
    <h3>About you</h3>
    <p>
      For the tutor. Optional, about two minutes.
    </p>
    <p class="kbp-note">
      Your answers stay in this browser and are not sent to the people who run this site. They go to the AI tutor
      (a hosted language model) with your questions, without anything identifying you, and only shape its
      explanations. Leave out your name and personal details. Change, clear or turn them off in settings (the gear
      in the top bar).
    </p>
    <div v-for="q in QUESTIONS" :key="q.id" class="kbp-q">
      <div class="kbp-text">{{ q.text }}</div>
      <div class="kbp-options">
        <button v-for="o in q.options" :key="o" type="button" :class="['kbp-option', { on: chosen(q.id, o) }]"
                :aria-pressed="chosen(q.id, o)" @click="choose(q.id, o, q.many)">{{ o }}</button>
      </div>
      <textarea v-if="noting.has(q.id)" v-model="notes[q.id]" rows="2" class="kb-field kbp-input"
                placeholder="Anything to add (optional)"></textarea>
      <button v-else type="button" class="kb-link kbp-link" @click="note(q.id)">add a note</button>
    </div>
    <div class="kbp-actions">
      <button type="button" class="kb-primary kbp-save" @click="save">Save</button>
      <button type="button" class="kb-link kbp-link" @click="decline">Skip</button>
    </div>
  </div>
</template>

<style scoped>
.kbp { font-size: 0.92rem; line-height: 1.6; white-space: normal; max-width: 100%; overflow-wrap: anywhere; }
.kbp h3 { margin: 0.4rem 0 0.6rem; font-size: 1.2rem; font-weight: 600; line-height: 1.4; color: var(--vp-c-text-1); }
.kbp p { color: var(--vp-c-text-2); margin: 0.4rem 0; }
.kbp-note { padding: 0.5rem 0.7rem; border-radius: 8px; background: var(--vp-c-bg-soft); font-size: 0.85rem; }
.kbp-q { margin: 1rem 0; }
.kbp-text { font-weight: 600; margin-bottom: 0.4rem; }
.kbp-options { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.kbp-option { max-width: 100%; padding: 0.3rem 0.7rem; border-radius: 14px; border: 1px solid var(--vp-c-divider); background: none;
  color: var(--vp-c-text-1); font: inherit; font-size: 0.85rem; line-height: 1.35; cursor: pointer; text-align: left;
  white-space: normal; height: auto; }
.kbp-option.on { border-color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kbp-input { display: block; width: 100%; box-sizing: border-box; margin-top: 0.4rem; padding: 0.4rem 0.6rem; font-size: 0.85rem; border-radius: 8px; }
.kbp-link { margin-top: 0.3rem; font-size: 0.82rem; }
.kbp-actions { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; margin: 1.2rem 0 0.4rem; }
</style>
