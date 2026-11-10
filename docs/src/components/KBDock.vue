<!--
  A panel that docks on the right or at the bottom of the window, or floats: docked, it reports the
  space it covers (`space`, in pixels from the window's right and bottom edges) so the page can make
  room, and the edge toward the page drags to resize; floating, the header drags to move it and the corner to resize.
  On a narrow window (a phone) it takes the whole screen under the top bar, closed by a back arrow.
  Where it is and its sizes are kept in this browser, under `name`. Escape closes it.
-->
<script setup lang="ts">
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { closeOnEscape } from './kbDialog'

const props = defineProps<{ name: string }>()
const emit = defineEmits<{ close: []; space: [{ right: number; bottom: number }] }>()

type Placement = 'right' | 'bottom' | 'float'
type State = { placement: Placement; width: number; height: number; float: { x: number; y: number; w: number; h: number } }
const KEY = `kb-dock-${props.name}`
const state = ref<State>({ placement: 'right', width: 576, height: 360, float: { x: 0, y: 0, w: 560, h: 520 } })
// A window too narrow for a panel beside the page, or one below it, takes it full screen.
const NARROW = '(max-width: 767px)'
const narrow = ref(false)
const navHeight = () => typeof document === 'undefined' ? 64 : parseInt(getComputedStyle(document.documentElement).getPropertyValue('--vp-nav-height')) || 64

function load() {
  try { const s = JSON.parse(localStorage.getItem(KEY) ?? 'null'); if (s) state.value = { ...state.value, ...s } } catch { /* the defaults */ }
  if (!state.value.float.x) state.value.float = { ...state.value.float, x: window.innerWidth - state.value.float.w - 40, y: navHeight() + 40 }
}
const save = () => localStorage.setItem(KEY, JSON.stringify(state.value))

const width = () => Math.min(state.value.width, window.innerWidth - 200)
const height = () => Math.min(state.value.height, window.innerHeight - navHeight() - 120)
const placed = computed(() => narrow.value ? 'full' : state.value.placement)
const reserve = () => emit('space', { right: placed.value === 'right' ? width() : 0, bottom: placed.value === 'bottom' ? height() : 0 })
watch(state, () => { reserve(); save() }, { deep: true })

const resized = ref(0)
const onResize = () => { narrow.value = window.matchMedia(NARROW).matches; resized.value++; reserve() }
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), Math.max(lo, hi))
const style = computed(() => {
  const s = state.value, top = navHeight()
  void resized.value
  if (placed.value === 'full') return { top: `${top}px`, left: '0', right: '0', bottom: '0' }
  if (s.placement === 'right') return { top: `${top}px`, right: '0', bottom: '0', width: `${width()}px` }
  if (s.placement === 'bottom') return { left: '0', right: '0', bottom: '0', height: `${height()}px` }
  return { left: `${s.float.x}px`, top: `${s.float.y}px`, width: `${s.float.w}px`, height: `${s.float.h}px` }
})

// Dragging: the docked edge, the floating panel's header, or its corner.
function drag(e: PointerEvent, what: 'edge' | 'move' | 'corner') {
  if ((e.target as HTMLElement).closest('button, select, input, a') && what === 'move') return
  e.preventDefault()
  // Held by this element until the drag ends, however far the finger or mouse strays.
  const el = e.currentTarget as HTMLElement
  try { el.setPointerCapture(e.pointerId) } catch { /* a pointer the browser does not track */ }
  const start = { x: e.clientX, y: e.clientY, s: JSON.parse(JSON.stringify(state.value)) as State }
  const W = window.innerWidth, H = window.innerHeight, top = navHeight()
  function onMove(ev: PointerEvent) {
    const dx = ev.clientX - start.x, dy = ev.clientY - start.y, s = state.value
    if (what === 'edge' && s.placement === 'right') s.width = clamp(start.s.width - dx, 320, W - 200)
    else if (what === 'edge' && s.placement === 'bottom') s.height = clamp(start.s.height - dy, 160, H - top - 120)
    else if (what === 'move') s.float = { ...s.float, x: clamp(start.s.float.x + dx, 0, W - s.float.w), y: clamp(start.s.float.y + dy, top, H - 60) }
    else if (what === 'corner') s.float = { ...s.float, w: clamp(start.s.float.w + dx, 320, W - s.float.x), h: clamp(start.s.float.h + dy, 200, H - s.float.y) }
  }
  function onUp() {
    window.removeEventListener('pointermove', onMove); window.removeEventListener('pointerup', onUp); window.removeEventListener('pointercancel', onUp)
    document.body.style.userSelect = ''
  }
  document.body.style.userSelect = 'none'
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onUp)
}
const place = (p: Placement) => (state.value.placement = p)
// Escape closes it, unless pressed in a field, or a dialog opened over it is there to close first.
let stopEscape = () => {}
onMounted(() => { load(); narrow.value = window.matchMedia(NARROW).matches; reserve(); stopEscape = closeOnEscape(() => emit('close'), { fields: false }); window.addEventListener('resize', onResize) })
onBeforeUnmount(() => {
  stopEscape()
  window.removeEventListener('resize', onResize)
  emit('space', { right: 0, bottom: 0 })
})
</script>

<template>
  <aside class="kbd" :class="placed" :style="style">
    <div class="kbd-head" @pointerdown="placed === 'float' && drag($event, 'move')">
      <button v-if="narrow" class="kbd-place kbd-back" title="Back (Esc)" aria-label="Back" @click="emit('close')">
        <svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </button>
      <span class="kbd-slot"><slot name="head" /></span>
      <span v-if="!narrow" class="kbd-places">
        <button v-for="p in (['right', 'bottom', 'float'] as const)" :key="p" class="kbd-place" :class="{ on: state.placement === p }"
                :title="p === 'float' ? 'Float' : `Dock ${p === 'right' ? 'on the right' : 'at the bottom'}`" @click="place(p)">
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
            <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" fill="none" stroke="currentColor" />
            <rect v-if="p === 'right'" x="9" y="3" width="5" height="10" fill="currentColor" />
            <rect v-else-if="p === 'bottom'" x="2" y="9" width="12" height="4" fill="currentColor" />
            <rect v-else x="5" y="5" width="7" height="5" fill="currentColor" />
          </svg>
        </button>
      </span>
      <button v-if="!narrow" class="kbd-place" title="Close (Esc)" aria-label="Close" @click="emit('close')">✕</button>
    </div>
    <div class="kbd-body"><slot /></div>
    <div v-if="placed === 'right' || placed === 'bottom'" class="kbd-edge" @pointerdown="drag($event, 'edge')"></div>
    <div v-else-if="placed === 'float'" class="kbd-corner" @pointerdown="drag($event, 'corner')"></div>
  </aside>
</template>

<style scoped>
/* Under the site's top bar, whose menus open over it, and over the bar of the page's headings. */
.kbd { position: fixed; z-index: calc(var(--vp-z-index-nav, 30) - 1); display: flex; flex-direction: column; background: var(--vp-c-bg); box-shadow: var(--vp-shadow-3); }
.kbd.right { border-left: 1px solid var(--vp-c-divider); }
.kbd.bottom { border-top: 1px solid var(--vp-c-divider); }
.kbd.float { border: 1px solid var(--vp-c-divider); border-radius: 10px; box-shadow: var(--vp-shadow-4); }
.kbd-head { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 0.9rem; border-bottom: 1px solid var(--vp-c-divider); }
.kbd.float .kbd-head { cursor: move; }
.kbd-slot { flex: 1; display: flex; gap: 0.6rem; align-items: center; min-width: 0; }
.kbd-places { display: inline-flex; gap: 0.15rem; }
.kbd-place { display: inline-flex; align-items: center; justify-content: center; width: 26px; height: 26px; border: none; border-radius: 6px;
  background: none; color: var(--vp-c-text-3); cursor: pointer; font: inherit; }
.kbd-place:hover { background: var(--vp-c-default-soft); color: var(--vp-c-text-1); }
.kbd-place.on { color: var(--vp-c-brand-1); }
@media (pointer: coarse) { .kbd-place { width: 40px; height: 40px; } }
.kbd-body { flex: 1; overflow-y: auto; overscroll-behavior: contain; padding: 0.4rem 1.2rem 2rem; }
.kbd.full .kbd-head { padding: 0.4rem 0.6rem 0.4rem 0.3rem; flex-wrap: wrap; row-gap: 0.3rem; }
.kbd.full .kbd-slot { flex-wrap: wrap; row-gap: 0.3rem; }
.kbd.full .kbd-body { padding: 0.4rem 0.9rem 2rem; }
.kbd-back { width: 36px; height: 36px; color: var(--vp-c-text-2); }
/* A touch on these drags the panel, not the page. */
.kbd-edge, .kbd-corner, .kbd.float .kbd-head { touch-action: none; }
.kbd-edge { position: absolute; z-index: 1; }
.kbd.right .kbd-edge { left: -3px; top: 0; bottom: 0; width: 6px; cursor: ew-resize; }
.kbd.bottom .kbd-edge { top: -3px; left: 0; right: 0; height: 6px; cursor: ns-resize; }
.kbd-edge:hover { background: var(--vp-c-brand-soft); }
/* A finger's target: wider, with a grip to show it is there, as a touch screen has no hover. */
@media (pointer: coarse) {
  .kbd.right .kbd-edge { left: -14px; width: 28px; }
  .kbd.bottom .kbd-edge { top: -14px; height: 28px; }
  .kbd-edge::after { content: ''; position: absolute; border-radius: 3px; background: var(--vp-c-text-3); opacity: 0.6; }
  .kbd.right .kbd-edge::after { left: 11px; top: calc(50% - 24px); width: 6px; height: 48px; }
  .kbd.bottom .kbd-edge::after { top: 11px; left: calc(50% - 24px); height: 6px; width: 48px; }
  .kbd-corner { width: 28px; height: 28px; }
}
.kbd-corner { position: absolute; right: 0; bottom: 0; width: 14px; height: 14px; cursor: nwse-resize;
  background: linear-gradient(135deg, transparent 50%, var(--vp-c-divider) 50%); border-bottom-right-radius: 10px; }
</style>
