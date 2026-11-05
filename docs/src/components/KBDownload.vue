<!--
  A link to a file the site serves from its root (a notebook, say), made with the
  site's base so it works wherever the site is published.
-->
<script setup lang="ts">
import { withBase } from 'vitepress'
defineProps<{ src: string; name?: string }>()
</script>

<template>
  <a :href="withBase(src)" :download="name ?? src.split('/').pop()"><slot /></a>
</template>
