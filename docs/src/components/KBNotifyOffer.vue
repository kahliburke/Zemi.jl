<!--
  The offer of notifications (see KBNotifications.vue), once in each browser, to a person who works
  on tasks: a browser asks its permission only from a click on the page, so the page asks first. It
  is never offered again in the browser once shown, whatever the answer, or none. On
  an iPhone or iPad outside the Home Screen it says how to add the site there; the Home Screen's
  copy keeps its own storage, so it is offered there again, where it can be turned on.
-->
<script setup lang="ts">
import { ref, watch } from 'vue'
import { me, can } from './kbApi'
import { pushSupported, needsHomeScreen, currentSubscription, turnOn, loadPush, sendTest } from './kbPush'

const KEY = 'zemi-notify-offer'
const shown = ref<'' | 'offer' | 'home' | 'done'>('')
const busy = ref(false)
const error = ref('')

// Decided once, when the page knows who is signed in.
let decided = false
watch(me, async m => {
  if (!m || decided) return
  decided = true
  if (localStorage.getItem(KEY) || m.via !== 'session' || !can('tasks.edit')) return
  if (location.pathname.includes('/service/account')) return            // the page has its own
  const show = needsHomeScreen() ? 'home' :
    pushSupported() && Notification.permission === 'default' && !(await currentSubscription()) ? 'offer' : ''
  if (!show) return
  localStorage.setItem(KEY, 'shown')
  shown.value = show
}, { immediate: true })

const close = () => { shown.value = '' }

async function on() {
  busy.value = true; error.value = ''
  try {
    const endpoint = await turnOn(await loadPush())
    await sendTest(endpoint)
    shown.value = 'done'
    setTimeout(() => { if (shown.value === 'done') shown.value = '' }, 6000)
  } catch (e: any) { error.value = e.message ?? String(e) }
  busy.value = false
}
</script>

<template>
  <Teleport to="body">
    <div v-if="shown" class="kbno" role="dialog" aria-label="Notifications">
      <template v-if="shown === 'offer'">
        <p class="kbno-head">Get notified when something waits on you?</p>
        <p class="kbno-text">Questions for you, plans and work to review, tasks assigned to you. Asked once: your
          Account page can turn them on later.</p>
        <div class="kbno-row">
          <button class="kb-primary" :disabled="busy" @click="on">Turn on</button>
          <button class="kb-link" :disabled="busy" @click="close">No thanks</button>
        </div>
      </template>
      <template v-else-if="shown === 'home'">
        <p class="kbno-head">Notifications on this phone</p>
        <p class="kbno-text">Add this site to the Home Screen (Share, then <em>Add to Home Screen</em>) and open it
          from there to turn them on.</p>
        <div class="kbno-row"><button class="kb-link" @click="close">Got it</button></div>
      </template>
      <p v-else class="kbno-head">On: one is on its way. The Account page changes what they are for.</p>
      <p v-if="error" class="kb-error">{{ error }}</p>
    </div>
  </Teleport>
</template>

<style scoped>
.kbno { position: fixed; right: 1.2rem; bottom: 1.2rem; z-index: 200; max-width: 22rem; padding: 0.9rem 1rem;
  border-radius: 12px; background: var(--vp-c-bg-elv); border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-3);
  font-size: 0.9rem; line-height: 1.45; }
.kbno p { margin: 0; }
.kbno-head { font-weight: 600; color: var(--vp-c-text-1); }
.kbno-text { margin-top: 0.3rem !important; color: var(--vp-c-text-2); }
.kbno-row { display: flex; align-items: center; gap: 0.9rem; margin-top: 0.7rem; }
.kbno .kb-error { margin-top: 0.5rem; }
</style>
