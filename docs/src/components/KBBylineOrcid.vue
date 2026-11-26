<script setup lang="ts">
import { ref } from 'vue'
import { post } from './kbApi'
import type { Byline } from './kbCoauthors'
const props = defineProps<{ paper: string; byline: Byline }>()
const emit = defineEmits<{ saved: [orcid: string | null] }>()
const editing = ref(false), value = ref(''), busy = ref(false), error = ref('')
function edit() { value.value = props.byline.orcid ?? ''; error.value = ''; editing.value = true }
async function save() {
  busy.value = true; error.value = ''
  try {
    const { orcid } = await post('/api/author-orcid', JSON.stringify({
      paper: props.paper, name: props.byline.name, position: props.byline.position, previous: props.byline.orcid, orcid: value.value.trim(),
    }))
    editing.value = false
    emit('saved', orcid)
  } catch (e: any) { error.value = e.message }
  finally { busy.value = false }
}
</script>
<template>
  <button v-if="!editing" class="kb-link" @click="edit">Edit ORCID</button>
  <form v-else @submit.prevent="save">
    <label>ORCID for {{ byline.name }} on this publication
      <input v-model="value" class="kb-field" placeholder="https://orcid.org/…" :disabled="busy">
    </label>
    <button class="kb-link" :disabled="busy">Save</button>
    <button type="button" class="kb-link" :disabled="busy" @click="editing = false">Cancel</button>
    <span v-if="error" role="alert" class="kb-error">{{ error }}</span>
  </form>
</template>
<style scoped>
button, input { margin-inline-start: .5rem; }
form { margin: .4rem 0; }
</style>
