<!--
  What needs the knowledge base service, shown once it answers and allows it: while connecting, or
  with no service, or without the `permission` (or with `allowed` false), a line saying so instead.
  With `shared`, only in the shared service, with accounts.
-->
<script setup lang="ts">
import { onMounted } from 'vue'
import { mode, connect, can, shared as isShared } from './kbApi'

const props = withDefaults(defineProps<{ permission?: string; shared?: boolean; allowed?: boolean }>(), { allowed: true })
onMounted(() => connect())
</script>

<template>
  <p v-if="mode !== 'live'" class="kb-dim">
    {{ mode === 'checking' ? 'Connecting…' : props.shared ? 'Shared mode only.' : 'Needs a running Zemi server.' }}</p>
  <p v-else-if="props.shared && !isShared" class="kb-dim">Shared mode only.</p>
  <p v-else-if="(props.permission && !can(props.permission)) || !props.allowed" class="kb-dim">Not permitted.</p>
  <slot v-else />
</template>
