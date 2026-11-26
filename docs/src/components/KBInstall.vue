<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue'

interface InstallPrompt extends Event {
  prompt(): Promise<unknown>
}
let prompt: InstallPrompt | undefined
const visible = ref(false)
const help = ref('')
const french = ref(false)

function ready(event: Event) {
  // Keep the browser's address-bar action and also offer it from the home page.
  prompt = event as InstallPrompt
}
function installed() { visible.value = false; prompt = undefined }
onMounted(() => {
  const standalone = matchMedia('(display-mode: standalone)').matches ||
    (navigator as Navigator & { standalone?: boolean }).standalone
  visible.value = window.isSecureContext && !standalone
  french.value = navigator.language.startsWith('fr')
  window.addEventListener('beforeinstallprompt', ready)
  window.addEventListener('appinstalled', installed)
})
onBeforeUnmount(() => {
  window.removeEventListener('beforeinstallprompt', ready)
  window.removeEventListener('appinstalled', installed)
})
async function install() {
  if (prompt) {
    const event = prompt
    prompt = undefined
    try { await event.prompt(); return } catch { /* Show the browser menu instructions. */ }
  }
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  help.value = ios
    ? (french.value ? 'Dans Safari, ouvre Partager puis « Sur l’écran d’accueil ».' : 'In Safari, open Share and choose Add to Home Screen.')
    : (french.value ? 'Dans le menu de Chrome ou Edge, cherche « Installer » dans les options de la page ou des applications.' : 'In the Chrome or Edge menu, look for Install in the page or apps options.')
}
</script>

<template>
  <div v-if="visible" class="kb-install">
    <button type="button" @click="install">{{ french ? 'Installer Zemi' : 'Install Zemi' }}</button>
    <p role="status">{{ help }}</p>
  </div>
</template>

<style scoped>
.kb-install { margin: 1rem 0; text-align: center; }
.kb-install button { color: var(--vp-c-brand-1); font-weight: 600; text-decoration: underline; }
.kb-install p:empty { display: none; }
</style>
