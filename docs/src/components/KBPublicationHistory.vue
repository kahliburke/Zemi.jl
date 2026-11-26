<script setup lang="ts">
import { ref } from 'vue'
import { post } from './kbApi'
import { pageLink } from './kbLinks'

const stages = { preprint: 'Preprint posted', submitted: 'Submitted', accepted: 'Accepted', published: 'Version of record published',
  declined: 'Declined', withdrawn: 'Withdrawn' }
type Stage = keyof typeof stages
type Entry = { version: number; stage: Stage; venue: string; happened: string; url: string; recorded_by: string }
const props = defineProps<{ work: number; version: number; latest: number; entries: Entry[]; maintainer: boolean }>()
const emit = defineEmits<{ saved: [entries: Entry[]] }>()
const form = ref({ version: props.version, stage: 'preprint' as Stage, venue: '', date: '', reference: '' })
const opened = ref(false), busy = ref(false), error = ref('')
async function record() {
  busy.value = true
  error.value = ''
  try {
    const entries = await post(`/api/publications/${props.work}/history`, JSON.stringify(form.value))
    emit('saved', entries)
    opened.value = false
    form.value = { version: props.version, stage: 'preprint', venue: '', date: '', reference: '' }
  } catch (e) { error.value = (e as Error).message }
  finally { busy.value = false }
}
</script>
<template>
  <section v-if="entries.length || maintainer">
    <h2>Publication history</h2>
    <ol v-if="entries.length">
      <li v-for="(event, i) in entries" :key="i">
        <time>{{ event.happened }}</time> · <strong>{{ stages[event.stage] }}</strong> ·
        <a v-if="event.url" :href="event.url">{{ event.venue }}</a><span v-else>{{ event.venue }}</span>
        · <a :href="pageLink(`/publications/${work}/v${event.version}/`)">Internal v{{ event.version }}</a>
      </li>
    </ol>
    <button v-if="maintainer && !opened" @click="opened = true">Record milestone</button>
    <form v-if="maintainer && opened" @submit.prevent="record">
      <fieldset :disabled="busy">
        <label>Milestone <select v-model="form.stage"><option v-for="(label, value) in stages" :key="value" :value="value">{{ label }}</option></select></label>
        <label>Internal edition <select v-model="form.version"><option v-for="v in latest" :key="v" :value="v">v{{ v }}</option></select></label>
        <label>Repository, journal or conference <input v-model="form.venue" required></label>
        <label>Event date <input v-model="form.date" type="date" required></label>
        <label>External link, DOI or preprint ID <input v-model="form.reference" :required="['preprint','published'].includes(form.stage)"></label>
        <p v-if="error" role="alert">{{ error }}</p>
        <button type="submit">Save milestone</button>
        <button type="button" @click="opened = false">Cancel</button>
      </fieldset>
    </form>
  </section>
</template>
<style scoped>
fieldset { border: 0; padding: 0; }
label { display: grid; gap: .25rem; margin: .65rem 0; }
input, select { padding: .45rem .65rem; border: 1px solid var(--vp-c-divider); border-radius: 5px; }
button { color: var(--vp-c-brand-1); margin-right: 1rem; }
</style>
