<!--
  A paper's figure as the site serves it, from `dir`: the copy for each theme where it has them
  (`light`, `dark`, one of which may be the original `file`), else the original in both; the reader
  can keep to the originals (see the figure styles in overrides.css and kbDisplay.ts).
-->
<script setup lang="ts">
import { withBase } from 'vitepress'

const props = defineProps<{ dir: string; file: string; light?: string; dark?: string; width?: number; label: string }>()
const src = (f: string) => withBase(`${props.dir}/${f}`)
</script>

<template>
  <p class="kb-figure">
    <template v-if="dark && light">
      <img class="kb-for-light" :class="{ 'kb-original': light === file }" :src="src(light)" :alt="label" :width="width">
      <img class="kb-for-dark" :class="{ 'kb-original': dark === file }" :src="src(dark)" :alt="label" :width="width">
    </template>
    <img v-else class="kb-for-both kb-original" :src="src(file)" :alt="label" :width="width">
  </p>
</template>
