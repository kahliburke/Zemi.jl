<script setup lang="ts">
// A block of rendered text cut to a few lines, its end faded, with More to read the rest: only where it
// runs well past them. Text that runs two lines or less past is shown whole, since More would hide no
// more than it takes. Measured at the cut height each time the text changes.
import { ref, watch, nextTick, onMounted } from 'vue'

const props = defineProps<{ html: string; head?: string; lines?: number }>()

const box = ref<HTMLElement | null>(null)
const more = ref(false)
const clipped = ref(false)
const whole = ref(false)

function measure() {
  const el = box.value
  if (!el) return
  const over = el.scrollHeight - el.clientHeight, line = parseFloat(getComputedStyle(el).lineHeight) || 20
  if (over > 2.2 * line) clipped.value = true
  else if (over > 1) whole.value = true
}
function again() {
  more.value = whole.value = clipped.value = false
  nextTick(measure)
}
watch(() => props.html, again)
onMounted(measure)
</script>

<template>
  <div class="kbc">
    <div ref="box" class="kbc-box" :class="{ open: more || whole, clipped }" :style="{ '--kbc-lines': lines ?? 6 }">
      <p v-if="head" class="kbc-head">{{ head }}</p>
      <div class="kbc-text" v-html="html"></div>
    </div>
    <button v-if="clipped || more" class="kbc-more" :aria-expanded="more" @click="more = !more">{{ more ? 'Less' : 'More' }}</button>
  </div>
</template>

<style scoped>
.kbc-box { position: relative; max-height: calc(var(--kbc-lines) * 1.5em + 1.6em); overflow: hidden; font-size: 13px; line-height: 1.5; }
.kbc-box.clipped:not(.open)::after { content: ''; position: absolute; left: 0; right: 0; bottom: 0; height: 2.5em;
                                     background: linear-gradient(transparent, var(--vp-c-bg)); }
.kbc-box.open { max-height: none; }
.kbc-head { margin: 0 0 2px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--vp-c-text-3); }
.kbc-text :deep(p) { margin: 0 0 6px; }
.kbc-text :deep(ul) { margin: 0 0 6px; padding-left: 1.1rem; }
.kbc-more { font-size: 12px; color: var(--vp-c-brand-1); margin: 2px 0 6px; }
</style>
