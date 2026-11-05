<!--
  A text field where typing `@` offers what to refer to: tasks, findings, papers, authors, people,
  notebooks and code matching what follows it. Arrow keys move through them; Enter or Tab writes the chosen one as a
  reference (see kbRefs.ts), Escape closes the list. A `multiline` one is the Markdown editor
  (KBEditor.vue), which offers references the same way.
-->
<script setup lang="ts">
import { ref, nextTick } from 'vue'
import { refText, findReferences, type RefMatch } from './kbRefs'
import { referenceQuery } from './kbEditorSyntax'
import KBEditor from './KBEditor.vue'

const props = withDefaults(defineProps<{ modelValue: string; multiline?: boolean; rows?: number; placeholder?: string; project?: string;
                                          draft?: string; send?: string }>(),
                           { multiline: false, rows: 3, placeholder: '' })
const emit = defineEmits<{ 'update:modelValue': [string]; submit: [] }>()

const field = ref<HTMLInputElement | null>(null)
const items = ref<RefMatch[]>([])
const at = ref(-1)          // where the `@` being completed is
const chosen = ref(0)
const up = ref(false)       // the list opens above the field when there is no room below it
let timer: ReturnType<typeof setTimeout> | undefined
let asked = 0

function close() { items.value = []; at.value = -1 }
// After a click on the list has chosen.
const onBlur = () => setTimeout(close, 150)

function onInput(e: Event) {
  emit('update:modelValue', (e.target as HTMLInputElement).value)
  const el = field.value
  const t = el ? referenceQuery(el.value.slice(0, el.selectionStart ?? el.value.length)) : null
  if (!t) return close()
  clearTimeout(timer)
  timer = setTimeout(async () => {
    const n = ++asked
    try {
      const found = await findReferences(t.q, props.project)
      if (n !== asked) return
      // Words with spaces keep the list open only while something still matches.
      if (!found.length && /\s/.test(t.q)) return close()
      items.value = found; at.value = t.at; chosen.value = 0
      up.value = !!field.value && window.innerHeight - field.value.getBoundingClientRect().bottom < 240
    } catch { close() }
  }, 120)
}

async function choose(r: RefMatch) {
  const el = field.value
  if (!el || at.value < 0) return
  const end = el.selectionStart ?? el.value.length
  const text = refText(r) + ' '
  const value = el.value.slice(0, at.value) + text + el.value.slice(end)
  const caret = at.value + text.length
  emit('update:modelValue', value)
  close()
  await nextTick()
  el.focus(); el.setSelectionRange(caret, caret)
}

function onKey(e: KeyboardEvent) {
  if (!items.value.length) return
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    const n = items.value.length
    chosen.value = (chosen.value + (e.key === 'ArrowDown' ? 1 : n - 1)) % n
  } else if (e.key === 'Enter' || e.key === 'Tab') {
    e.preventDefault(); e.stopPropagation()
    choose(items.value[chosen.value])
  } else if (e.key === 'Escape') {
    e.preventDefault(); e.stopPropagation()
    close()
  }
}
</script>

<template>
  <KBEditor v-if="multiline" :model-value="modelValue" :rows="rows" :placeholder="placeholder" :project="project" :draft="draft" :send="send"
            @update:model-value="v => emit('update:modelValue', v)" @submit="emit('submit')" />
  <span v-else class="kbr">
    <input ref="field" :value="modelValue" :placeholder="placeholder" class="kb-field kbr-field"
           @input="onInput" @keydown="onKey" @blur="onBlur" />
    <ul v-if="items.length" class="kbr-menu" :class="{ up }" role="listbox">
      <li v-for="(r, i) in items" :key="r.kind + r.target" :class="{ on: i === chosen }" role="option" :aria-selected="i === chosen"
          @mousedown.prevent="choose(r)" @mouseenter="chosen = i">
        <span class="kbr-kind">{{ r.kind }}</span>
        <span class="kbr-label">{{ r.label }}</span>
        <span class="kbr-detail">{{ r.detail }}</span>
      </li>
    </ul>
  </span>
</template>

<style scoped>
.kbr { position: relative; display: inline-block; }
.kbr-field { width: 100%; box-sizing: border-box; }
.kbr-menu { position: absolute; z-index: 40; left: 0; top: calc(100% + 2px); min-width: 100%; max-width: 32rem; max-height: 18rem; overflow-y: auto;
  margin: 0; padding: 0.25rem; list-style: none; border: 1px solid var(--vp-c-divider); border-radius: 8px; background: var(--vp-c-bg); box-shadow: var(--vp-shadow-3); }
.kbr-menu.up { top: auto; bottom: calc(100% + 2px); }
.kbr-menu li { display: flex; gap: 0.5rem; align-items: baseline; padding: 0.3rem 0.5rem; border-radius: 6px; cursor: pointer; white-space: nowrap; }
.kbr-menu li.on { background: var(--vp-c-default-soft); }
.kbr-kind { flex: none; width: 4.2rem; font-size: 0.68rem; letter-spacing: 0.04em; text-transform: uppercase; color: var(--vp-c-text-3); }
.kbr-label { flex: none; color: var(--vp-c-text-1); }
.kbr-detail { overflow: hidden; text-overflow: ellipsis; color: var(--vp-c-text-2); font-size: 0.82em; }
</style>