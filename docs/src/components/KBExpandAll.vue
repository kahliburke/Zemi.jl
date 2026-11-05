<!-- Opens or closes every collapsible block on the page at once. -->
<script setup lang="ts">
function setAll(open: boolean) {
  document.querySelectorAll<HTMLDetailsElement>('.vp-doc details').forEach(d => { d.open = open })
}
</script>

<template>
  <div class="kbx">
    <button type="button" class="kb-link kbx-link" @click="setAll(true)">expand all</button>
    <button type="button" class="kb-link kbx-link" @click="setAll(false)">collapse all</button>
  </div>
</template>

<style scoped>
.kbx { display: flex; gap: 1rem; margin: -0.4rem 0 0.8rem; font-size: 0.85rem; }
.kbx-link:hover { text-decoration: underline; }
</style>
