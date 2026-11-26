<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vitepress'
import KBDialog from './KBDialog.vue'
import KBIcon from './KBIcon.vue'
import { currentShare, shareData, shareText, type ShareMode } from './kbShare'

defineProps<{ screenMenu?: boolean; dialogTarget?: HTMLElement }>()
const route = useRoute()
const draft = ref<ReturnType<typeof currentShare> | null>(null)
const mode = ref<ShareMode>('content')
const busy = ref(false), feedback = ref(''), manual = ref(false)
const copyField = ref<HTMLTextAreaElement | null>(null)
const data = computed(() => draft.value && shareData(mode.value, draft.value.url, draft.value.title, draft.value.text))
const native = computed(() => !!data.value && typeof navigator !== 'undefined' && typeof navigator.share === 'function' &&
  (!navigator.canShare || navigator.canShare(data.value)))
const empty = computed(() => mode.value === 'content' && !draft.value?.text.trim())

function show(e: MouseEvent) {
  draft.value = currentShare()
  ;(e.currentTarget as HTMLButtonElement).focus()
  mode.value = 'content'
  feedback.value = ''; manual.value = false
}
function close() { draft.value = null }
watch(() => route.path, close)
onMounted(() => window.addEventListener('hashchange', close))
onBeforeUnmount(() => window.removeEventListener('hashchange', close))
watch([mode, () => draft.value?.text], () => { manual.value = false; feedback.value = '' })

async function copy() {
  if (!data.value) return
  const text = shareText(data.value)
  try {
    await navigator.clipboard.writeText(text)
    feedback.value = mode.value === 'link' ? 'Link copied.' : 'Content and link copied.'
  } catch {
    manual.value = true
    await nextTick()
    copyField.value?.focus(); copyField.value?.select()
  }
}
async function send() {
  if (!data.value || busy.value) return
  busy.value = true
  try {
    await navigator.share(data.value)
    close()
  } catch (error) {
    if ((error as Error)?.name !== 'AbortError') feedback.value = 'Sharing is unavailable. You can copy instead.'
  } finally { busy.value = false }
}
</script>

<template>
  <button type="button" class="kbshare-trigger" :class="{ mobile: screenMenu }" aria-label="Share this page" title="Share this page"
          aria-haspopup="dialog" @mousedown.prevent @click="show"><KBIcon name="share" :size="19" /><span v-if="screenMenu">Share this page</span></button>
  <KBDialog v-if="draft" label="Share this page" :to="dialogTarget" width="min(29rem, 94vw)" @close="close">
    <div class="kbshare-head"><h2>Share this page</h2><button type="button" aria-label="Close" @click="close">×</button></div>
    <div class="kbshare-modes" role="group" aria-label="What to share">
      <button type="button" autofocus :aria-pressed="mode === 'content'" @click="mode = 'content'"><KBIcon name="paper" />Content and link</button>
      <button type="button" :aria-pressed="mode === 'link'" @click="mode = 'link'"><KBIcon name="link" />Link only</button>
    </div>
    <div v-if="mode === 'content'" class="kbshare-content">
      <strong>{{ draft.title }}</strong>
      <textarea v-model="draft.text" class="kb-field" rows="5" aria-label="Text to share" />
    </div>
    <div class="kbshare-url"><KBIcon name="link" /><span>{{ draft.url }}</span></div>
    <div class="kbshare-actions">
      <button type="button" :class="native ? 'kb-button' : 'kb-primary'" :disabled="empty || busy" @click="copy"><KBIcon name="copy" />{{ mode === 'link' ? 'Copy link' : 'Copy content and link' }}</button>
      <button v-if="native" type="button" class="kb-primary" :disabled="empty || busy" @click="send"><KBIcon name="share" />Share…</button>
    </div>
    <p v-if="feedback" role="status">{{ feedback }}</p>
    <label v-if="manual && data" class="kbshare-manual">Select and copy
      <textarea ref="copyField" class="kb-field" readonly :value="shareText(data)" rows="3" />
    </label>
  </KBDialog>
</template>

<style scoped>
.kbshare-trigger, .kbshare-actions button, .kbshare-modes button { display: inline-flex; align-items: center; justify-content: center; gap: .45rem; cursor: pointer; }
.kbshare-trigger { min-width: 40px; min-height: 44px; color: var(--vp-c-text-2); }
.kbshare-trigger:hover, .kbshare-trigger:focus-visible { color: var(--vp-c-brand-1); }
.kbshare-trigger.mobile { width: 100%; justify-content: flex-start; border-bottom: 1px solid var(--vp-c-divider); }
.kbshare-head, .kbshare-actions { display: flex; align-items: center; justify-content: space-between; gap: .6rem; }
.kbshare-head h2 { font-size: 1.18rem; font-weight: 650; }
.kbshare-head button { width: 36px; height: 36px; font-size: 1.4rem; }
.kbshare-modes { display: flex; gap: .2rem; padding: .25rem; margin: .85rem 0 1rem; border-radius: 9px; background: var(--vp-c-bg-soft); }
.kbshare-modes button { flex: 1; padding: .45rem .2rem; border-radius: 6px; color: var(--vp-c-text-2); }
.kbshare-modes button[aria-pressed=true] { background: var(--vp-c-bg); box-shadow: 0 0 0 1px var(--vp-c-divider); color: var(--vp-c-brand-1); font-weight: 600; }
.kbshare-content strong { display: block; margin-bottom: .6rem; }
textarea { display: block; width: 100%; resize: vertical; font: inherit; padding: .55rem .7rem; }
.kbshare-url { display: flex; align-items: flex-start; gap: .45rem; margin: .7rem 0 1rem; color: var(--vp-c-text-2); font-size: .8rem; overflow-wrap: anywhere; }
.kbshare-url svg { flex: none; margin-top: .1rem; }
.kbshare-actions { justify-content: flex-end; flex-wrap: wrap; }
.kbshare-actions button { min-height: 40px; }
.kbshare-manual, [role=status] { display: block; margin-top: .6rem; }
</style>
