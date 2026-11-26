<!--
  Where codebases are added (KBUpload): the GitHub organizations the knowledge base lists for itself,
  each with its repositories to choose from (KBOrgRepositories, see src/project_codebases.jl), as a
  project's board lists its own. Those chosen are added to the knowledge base, linked to no project.
  `listed` names the organization just listed, whose repositories open to choose from; `reload()`
  fetches them again.
-->
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getJSON, post, followJobs } from './kbApi'
import KBOrgRepositories, { type ProjectOrg } from './KBOrgRepositories.vue'

const props = defineProps<{ listed?: string }>()

const orgs = ref<ProjectOrg[]>([])
const busy = ref(false)
const error = ref('')

async function reload() {
  try { orgs.value = (await getJSON('/api/code-orgs')).orgs } catch (e: any) { error.value = e.message }
}
async function act(o: ProjectOrg, body: Record<string, unknown>, done?: () => void) {
  if (busy.value) return
  busy.value = true; error.value = ''
  try {
    const r = await post('/api/code-orgs', JSON.stringify({ org: `${o.host}/${o.owner}`, ...body }))
    orgs.value = r.orgs
    if (r.taken?.length) followJobs()
    done?.()
  } catch (e: any) { error.value = e.message }
  finally { busy.value = false }
}
onMounted(reload)
defineExpose({ reload })
</script>

<template>
  <div v-if="orgs.length || error" class="kbco">
    <KBOrgRepositories v-for="o in orgs" :key="o.owner" :org="o" manages library :busy="busy"
                       :open="o.owner.toLowerCase() === (props.listed ?? '').toLowerCase()" @act="(body, done) => act(o, body, done)" />
    <p v-if="error" class="kb-error kbco-error">{{ error }}</p>
  </div>
</template>

<style scoped>
.kbco { display: flex; flex-direction: column; gap: 0.5rem; margin-top: 0.8rem; }
.kbco-error { margin: 0; font-size: 0.85rem; }
</style>
