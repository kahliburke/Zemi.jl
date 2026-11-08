<!--
  Notifications of what newly waits on the person (see src/notify.jl), on the account page: turning
  them on or off in this browser, which parts of Waiting on you they come for, a test, and the other
  devices they come to.
-->
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { day } from './kbFormat'
import { type PushSettings, pushSupported, needsHomeScreen, currentSubscription, turnOn, turnOff, loadPush, saveSections, sendTest, forget } from './kbPush'

const settings = ref<PushSettings | null>(null)
const here = ref('')             // this browser's subscription's endpoint, when it has one
const busy = ref(false)
const said = ref('')
const error = ref('')
const supported = ref(false)
const homeScreen = ref(false)

async function load() {
  settings.value = await loadPush()
  const sub = await currentSubscription()
  here.value = sub && settings.value.devices.some(d => d.endpoint === sub.endpoint) ? sub.endpoint : ''
}
onMounted(async () => {
  supported.value = pushSupported(); homeScreen.value = needsHomeScreen()
  try { await load() } catch (e: any) { error.value = e.message ?? String(e) }
})

async function act(f: () => Promise<unknown>, done = '') {
  busy.value = true; error.value = ''; said.value = ''
  try { await f(); await load(); said.value = done } catch (e: any) { error.value = e.message ?? String(e) }
  busy.value = false
}
const on = () => act(() => turnOn(settings.value!), 'On in this browser.')
const off = () => act(turnOff, 'Off in this browser.')
const test = () => act(async () => {
  const r = await sendTest()
  if (!r.sent) throw new Error('No device took it.')
}, 'Sent: it should show in a moment.')
function toggle(id: string, want: boolean) {
  const s = settings.value!
  const next = want ? [...s.sections, id] : s.sections.filter(x => x !== id)
  act(() => saveSections(next))
}
const others = computed(() => (settings.value?.devices ?? []).filter(d => d.endpoint !== here.value))
</script>

<template>
  <section v-if="settings" class="kbn">
    <h2>Notifications</h2>
    <p class="kb-dim">On your phone or computer, of what newly waits on you: questions asked of you, answers to yours, tasks
      assigned to you, and plans and work to review that are yours. Not while you have a board in view.</p>
    <p v-if="homeScreen" class="kbn-hint">On an iPhone or iPad, add this site to the Home Screen first (Share, then
      <em>Add to Home Screen</em>), open it from there, and turn notifications on here.</p>
    <p v-else-if="!supported" class="kb-dim">This browser cannot show them.</p>
    <div v-else class="kbn-row">
      <button v-if="!here" class="kb-primary" :disabled="busy" @click="on">Turn on in this browser</button>
      <template v-else>
        <span class="kbn-on">On in this browser</span>
        <button class="kb-link" :disabled="busy" @click="test">send a test</button>
        <button class="kb-link" :disabled="busy" @click="off">turn off</button>
      </template>
    </div>
    <fieldset v-if="settings.devices.length" class="kbn-sections">
      <legend>For</legend>
      <label v-for="s in settings.all_sections" :key="s.id">
        <input type="checkbox" :checked="settings.sections.includes(s.id)" :disabled="busy"
               @change="toggle(s.id, ($event.target as HTMLInputElement).checked)" /> {{ s.label }}</label>
    </fieldset>
    <ul v-if="others.length" class="kbn-devices">
      <li v-for="d in others" :key="d.id">{{ d.label || 'A device' }} <span class="kb-dim">· since {{ day(d.created_at) }}<template
        v-if="d.last_sent"> · last {{ day(d.last_sent) }}</template></span>
        <button class="kb-link" :disabled="busy" @click="act(() => forget(d.endpoint))">remove</button></li>
    </ul>
    <p v-if="said" class="kb-dim">{{ said }}</p>
    <p v-if="error" class="kb-error">{{ error }}</p>
  </section>
</template>

<style scoped>
.kbn-row { display: flex; align-items: center; gap: 0.9rem; margin: 0.6rem 0; }
.kbn-on { color: var(--vp-c-brand-1); font-weight: 600; }
.kbn-hint { padding: 0.5rem 0.8rem; border-radius: 8px; background: var(--vp-c-bg-soft); font-size: 0.9rem; }
.kbn-sections { display: flex; flex-wrap: wrap; gap: 0.3rem 1.1rem; border: none; padding: 0; margin: 0.6rem 0; font-size: 0.9rem; }
.kbn-sections legend { float: left; margin-right: 0.8rem; color: var(--vp-c-text-2); }
.kbn-devices { padding-left: 1.1rem; font-size: 0.9rem; }
</style>
