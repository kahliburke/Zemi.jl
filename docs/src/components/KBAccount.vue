<!--
  The top bar's menu of the service's own pages: those the person's roles open (their account and
  tokens, operations, configuration, setup, administration). In the shared service it is the account
  menu, under the person's initials, with who is signed in and signing out; an admin viewing the
  service as someone (see view_as! in src/accounts.jl) sees whom, with the way back. Run for one
  person there are no accounts, and it has the pages alone.
-->
<script setup lang="ts">
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { mode, connect, me, can, shared, post, signOut } from './kbApi'
import { pageLink } from './kbLinks'
import { offerInstall } from './kbPush'

const open = ref(false)
const root = ref<HTMLElement | null>(null)
const link = (p: string) => pageLink(`/service/${p}`)
const initials = computed(() => (me.value?.name || me.value?.email || '?').split(/[\s@.]+/).filter(Boolean).slice(0, 2)
  .map(w => w[0].toUpperCase()).join(''))
const pages = computed(() => [
  shared.value && { label: 'Account', href: link('account') },
  can('server.view') && { label: 'Operations', href: link('operations') },
  can('config.view') && { label: 'Configuration', href: link('configuration') },
  can('config.edit') && { label: 'Setup', href: link('setup') },
  shared.value && (can('users.manage') || can('tokens.manage') || can('audit.view')) && { label: 'Administration', href: link('administration') },
].filter(Boolean) as { label: string; href: string }[])

function away(e: MouseEvent) { if (root.value && !root.value.contains(e.target as Node)) open.value = false }
onMounted(() => { connect(); document.addEventListener('click', away) })
// Signed in to the service, the site can be installed: an iPhone shows notifications only so.
watch([mode, shared], () => { if (mode.value === 'live' && shared.value) offerInstall() }, { immediate: true })
onBeforeUnmount(() => document.removeEventListener('click', away))

async function stopViewing() {
  await post('/api/me/view-as', JSON.stringify({ user_id: null }))
  location.reload()
}
</script>

<template>
  <div v-if="mode === 'live' && me && (shared || pages.length)" ref="root" class="kba">
    <button class="kba-button" :class="{ viewing: me.admin }" :title="shared ? me.email : 'The service'" :aria-expanded="open"
            @click="open = !open">
      <span v-if="shared" class="kba-initials">{{ initials }}</span>
      <span v-else class="kba-initials" aria-label="The service">
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path fill="currentColor" d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm0 2c-3.3 0-8 1.7-8 5v1h16v-1c0-3.3-4.7-5-8-5Z"/>
        </svg>
      </span>
    </button>
    <div v-if="open" class="kba-menu">
      <div v-if="shared" class="kba-who">
        <div class="kba-name">{{ me.name || me.email }}</div>
        <div class="kba-email">{{ me.email }}</div>
      </div>
      <a v-for="p in pages" :key="p.href" :href="p.href" class="kba-item" @click="open = false">{{ p.label }}</a>
      <button v-if="me.admin" class="kba-item" @click="stopViewing">Back to {{ me.admin }}</button>
      <button v-if="shared" class="kba-item kba-out" @click="signOut">Sign out</button>
    </div>
  </div>
</template>

<style scoped>
.kba { position: relative; display: flex; align-items: center; margin-left: 0.4rem; }
.kba-button { display: flex; align-items: center; background: none; border: none; cursor: pointer; padding: 0 0.3rem; height: 100%; }
.kba-initials { display: inline-grid; place-items: center; width: 1.9rem; height: 1.9rem; border-radius: 50%; font-size: 0.75rem;
  font-weight: 700; background: var(--vp-c-brand-soft); color: var(--vp-c-brand-1); }
.kba-menu { position: absolute; top: 44px; right: 0; min-width: 15rem; z-index: 100; padding: 0.4rem; border-radius: 10px;
  background: var(--vp-c-bg-elv); border: 1px solid var(--vp-c-divider); box-shadow: var(--vp-shadow-3); white-space: normal; line-height: 1.5; }
.kba-who { padding: 0.4rem 0.6rem 0.6rem; border-bottom: 1px solid var(--vp-c-divider); margin-bottom: 0.3rem; }
.kba-name { font-weight: 600; color: var(--vp-c-text-1); }
.kba-email { font-size: 0.82rem; color: var(--vp-c-text-2); }
.kba-item { display: block; width: 100%; text-align: left; padding: 0.35rem 0.6rem; border-radius: 6px; font-size: 0.9rem;
  color: var(--vp-c-text-1); background: none; border: none; cursor: pointer; text-decoration: none; }
.kba-item:hover { background: var(--vp-c-default-soft); }
.kba-out { color: var(--vp-c-text-2); }
.kba-button.viewing .kba-initials { box-shadow: 0 0 0 1.5px var(--vp-c-warning-1); }
</style>
