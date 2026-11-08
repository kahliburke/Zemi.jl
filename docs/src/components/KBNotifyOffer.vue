<!--
  The offer of notifications (see KBNotifications.vue), once in each browser, to a person who sees
  the projects: a browser asks its permission only from a click on the page, so the page asks first.
  It is never offered again in the browser once shown, whatever the answer, or none, and it must be
  answered to go on. On an iPhone or iPad outside the Home Screen it says how to add the site there; the Home Screen's
  copy keeps its own storage, so it is offered there again, where it can be turned on.
-->
<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import { me, can } from './kbApi'
import { pushSupported, needsHomeScreen, currentSubscription, turnOn, loadPush, sendTest, OFFERED, markOffered } from './kbPush'

const shown = ref<'' | 'offer' | 'home' | 'done'>('')
const busy = ref(false)
const error = ref('')

// Each step's main button takes the focus, so Enter answers it.
watch(shown, async v => { if (v) { await nextTick(); document.querySelector<HTMLButtonElement>('.kbno-yes')?.focus() } })

// Whether notifications are on here: the browser subscribed, and the service has the subscription
// (a device removed from another one's Account page keeps its browser's).
async function subscribed() {
  const sub = await currentSubscription()
  return !!sub && (await loadPush()).devices.some(d => d.endpoint === sub.endpoint)
}

// Decided once, when the page knows who is signed in.
let decided = false
watch(me, async m => {
  if (!m || decided) return
  decided = true
  if (localStorage.getItem(OFFERED) || m.via !== 'session' || !can('tasks.view')) return
  if (location.pathname.includes('/service/account')) return            // the page has its own
  const show = needsHomeScreen() ? 'home' :
    pushSupported() && Notification.permission !== 'denied' && !(await subscribed()) ? 'offer' : ''
  if (!show) return
  markOffered('shown')
  shown.value = show
}, { immediate: true })

const close = () => { shown.value = '' }

async function on() {
  busy.value = true; error.value = ''
  try {
    const endpoint = await turnOn(await loadPush())
    await sendTest(endpoint)
    shown.value = 'done'
  } catch (e: any) { error.value = e.message ?? String(e) }
  busy.value = false
}
</script>

<template>
  <Teleport to="body">
    <!-- A choice to make before going on: it closes only by one of its buttons. -->
    <div v-if="shown" class="kbno-shade">
      <div class="kbno" role="dialog" aria-modal="true" aria-labelledby="kbno-head">
        <template v-if="shown === 'offer'">
          <h2 id="kbno-head">Get notified when something waits on you?</h2>
          <p>Questions for you, plans and work to review, and tasks assigned to you, on this device. You are asked
            once: the Account page can turn them on later.</p>
          <div class="kbno-row">
            <button class="kbno-no" :disabled="busy" @click="close">No thanks</button>
            <button class="kbno-yes" :disabled="busy" @click="on">Turn on</button>
          </div>
        </template>
        <template v-else-if="shown === 'home'">
          <h2 id="kbno-head">Notifications on this phone</h2>
          <p>Add this site to the Home Screen (Share, then <em>Add to Home Screen</em>) and open it from there: it
            offers to turn them on.</p>
          <div class="kbno-row"><button class="kbno-yes" @click="close">Got it</button></div>
        </template>
        <template v-else>
          <h2 id="kbno-head">Notifications are on</h2>
          <p>The first is on its way. The Account page changes what they are for.</p>
          <div class="kbno-row"><button class="kbno-yes" @click="close">OK</button></div>
        </template>
        <p v-if="error" class="kb-error">{{ error }}</p>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.kbno-shade { position: fixed; inset: 0; z-index: 300; display: grid; place-items: center; padding: 1rem;
  background: rgba(0, 0, 0, 0.5); }
.kbno { width: min(28rem, 100%); padding: 1.4rem 1.5rem 1.2rem; border-radius: 14px; background: var(--vp-c-bg-elv);
  border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-5); line-height: 1.5; }
.kbno h2 { margin: 0 0 0.5rem; padding: 0; border: none; font-size: 1.15rem; font-weight: 650; color: var(--vp-c-text-1); }
.kbno p { margin: 0; color: var(--vp-c-text-2); font-size: 0.95rem; }
.kbno-row { display: flex; justify-content: flex-end; gap: 0.7rem; margin-top: 1.2rem; }
.kbno-row button { padding: 0.45rem 1.1rem; border-radius: 8px; font-size: 0.95rem; font-weight: 600; cursor: pointer; }
.kbno-yes { background: var(--vp-c-brand-1); color: var(--vp-c-white); border: 1px solid var(--vp-c-brand-1); }
.kbno-yes:hover { background: var(--vp-c-brand-2); }
.kbno-no { background: none; color: var(--vp-c-text-1); border: 1px solid var(--vp-c-divider); }
.kbno-no:hover { background: var(--vp-c-default-soft); }
.kbno-row button:disabled { opacity: 0.5; cursor: default; }
.kbno .kb-error { margin-top: 0.8rem; }
</style>
