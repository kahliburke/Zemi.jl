<!--
  A dialog over the page, at the page's body: modal, named by its first heading (or `label`), the
  focus moved into it as it opens and back as it closes (see kbDialog.ts). Escape, or a click on the
  backdrop, emits `close`. `width` sizes it; `top` sets a long one at the top, the backdrop scrolling;
  `bare` leaves its look to what is in it; `shade` is how dark the page behind goes.
-->
<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { closeOnEscape, holdFocus, dialogId } from './kbDialog'

defineOptions({ inheritAttrs: false })
const props = withDefaults(defineProps<{ label?: string; width?: string; top?: boolean; bare?: boolean; shade?: number }>(),
                           { width: 'min(36rem, 92vw)', shade: 0.4 })
const emit = defineEmits<{ close: [] }>()

const box = ref<HTMLElement | null>(null)
const heading = ref<string | undefined>()
let stop = () => {}, release = () => {}
onMounted(() => {
  const h = props.label ? null : box.value!.querySelector<HTMLElement>('h1, h2, h3, h4')
  if (h) heading.value = h.id ||= dialogId()
  stop = closeOnEscape(() => emit('close'))
  release = holdFocus(box.value!)
})
onBeforeUnmount(() => { stop(); release() })
</script>

<template>
  <Teleport to="body">
    <div class="kb-dialog-backdrop" :class="{ top }" :style="{ background: `rgba(0, 0, 0, ${shade})` }" @click.self="emit('close')">
      <div ref="box" class="kb-dialog" :class="{ bare }" role="dialog" aria-modal="true" :aria-label="label" :aria-labelledby="heading"
           tabindex="-1" :style="{ width }" v-bind="$attrs"><slot /></div>
    </div>
  </Teleport>
</template>

<style>
/* Not scoped: the dialog is drawn at the page's body. What is in it is styled by the component it is in. */
.kb-dialog-backdrop { position: fixed; inset: 0; z-index: 200; display: flex; align-items: center; justify-content: center; padding: 1.5rem; }
.kb-dialog-backdrop.top { align-items: flex-start; padding: 4vh 2vw; overflow-y: auto; }
.kb-dialog { box-sizing: border-box; max-width: 96vw; max-height: 88vh; overflow-y: auto; padding: 1rem 1.2rem; border-radius: 12px;
  border: 1px solid var(--vp-c-divider); background: var(--vp-c-bg); color: var(--vp-c-text-1); box-shadow: var(--vp-shadow-5);
  font-size: 0.88rem; line-height: 1.5; white-space: normal; text-align: left; outline: none; }
.kb-dialog-backdrop.top .kb-dialog { max-height: none; overflow: visible; }
.kb-dialog.bare { padding: 0; border: none; border-radius: 0; background: none; box-shadow: none; max-height: none; overflow: visible; }
</style>
