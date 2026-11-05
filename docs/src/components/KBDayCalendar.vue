<!--
  The Paper of the Day's calendar, at the top of its pages: a month at a time, the days with a paper
  marked and linking to their page, the paper's title shown as the pointer rests on a day. The days
  come from daily.json, written with the site.
-->
<script setup lang="ts">
import KBTitle from './KBTitle.vue'
import { ref, computed, onMounted } from 'vue'
import { dayHref } from './kbLinks'
import { shiftMonth, monthWeeks, monthName } from './kbCalendar'
import { loadDays, type Day } from './kbData'
import { todayUtc, shortDay as short } from './kbFormat'

// `day` is the page's own day, whose month is shown first.
const props = defineProps<{ day: string }>()

const days = ref<readonly Day[]>([])
onMounted(async () => { try { days.value = await loadDays() } catch { /* no calendar */ } })
const byDay = computed(() => new Map(days.value.map(d => [d.day, d])))

const month = ref(props.day.slice(0, 7))
const earliest = computed(() => days.value.at(-1)?.day.slice(0, 7) ?? month.value)
const latest = computed(() => days.value[0]?.day.slice(0, 7) ?? month.value)
const weeks = computed(() => monthWeeks(month.value))
const today = todayUtc()

// The paper under the pointer (or keyboard focus), else the page's own.
const pointed = ref<Day | null>(null)
const shown = computed(() => pointed.value ?? byDay.value.get(props.day) ?? null)
</script>

<template>
  <nav class="kbcal" aria-label="Papers of the day">
    <div class="kbcal-head">
      <button type="button" class="kbcal-step" :disabled="month <= earliest" aria-label="Previous month" @click="month = shiftMonth(month, -1)">‹</button>
      <span class="kbcal-month">{{ monthName(month) }}</span>
      <button type="button" class="kbcal-step" :disabled="month >= latest" aria-label="Next month" @click="month = shiftMonth(month, 1)">›</button>
    </div>
    <div class="kbcal-grid">
      <span v-for="(w, i) in ['M', 'T', 'W', 'T', 'F', 'S', 'S']" :key="'h' + i" class="kbcal-weekday">{{ w }}</span>
      <template v-for="(week, i) in weeks" :key="i">
        <template v-for="(d, j) in week" :key="`${i}-${j}`">
          <span v-if="!d"></span>
          <a v-else-if="byDay.has(d)" :href="dayHref(d)" class="kbcal-day kbcal-paper" :class="{ current: d === day, today: d === today }"
             :aria-label="`${short(d)}: ${byDay.get(d)!.title}`" :aria-current="d === day ? 'page' : undefined"
             @mouseenter="pointed = byDay.get(d)!" @mouseleave="pointed = null" @focus="pointed = byDay.get(d)!" @blur="pointed = null">{{ Number(d.slice(8)) }}</a>
          <span v-else class="kbcal-day" :class="{ today: d === today }">{{ Number(d.slice(8)) }}</span>
        </template>
      </template>
    </div>
    <p class="kbcal-title"><template v-if="shown"><span class="kbcal-date">{{ short(shown.day) }}</span> <KBTitle :text="shown.title" /></template></p>
  </nav>
</template>

<style scoped>
.kbcal { display: inline-block; margin: 0.25rem 0 1.25rem; padding: 0.6rem 0.75rem 0.5rem; border: 1px solid var(--vp-c-divider);
         border-radius: 10px; background: var(--vp-c-bg-soft); max-width: 100%; }
.kbcal-head { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.35rem; }
.kbcal-month { font-weight: 600; font-size: 0.95rem; }
.kbcal-step { width: 1.8rem; height: 1.8rem; border: none; border-radius: 6px; background: none; color: var(--vp-c-text-2);
              font-size: 1.2rem; line-height: 1; cursor: pointer; }
.kbcal-step:hover:not(:disabled) { background: var(--vp-c-default-soft); color: var(--vp-c-text-1); }
.kbcal-step:disabled { opacity: 0.3; cursor: default; }
.kbcal-grid { display: grid; grid-template-columns: repeat(7, 2.1rem); gap: 0.15rem; justify-content: center; }
.kbcal-weekday { text-align: center; font-size: 0.7rem; color: var(--vp-c-text-3); padding-bottom: 0.15rem; }
.kbcal-day { display: flex; align-items: center; justify-content: center; height: 2.1rem; border-radius: 50%;
             font-size: 0.82rem; color: var(--vp-c-text-3); }
.kbcal-day.today { box-shadow: inset 0 0 0 1px var(--vp-c-divider); }
.vp-doc a.kbcal-paper { color: var(--vp-c-brand-1); background: var(--vp-c-brand-soft); font-weight: 600; text-decoration: none; }
.vp-doc a.kbcal-paper:hover, .vp-doc a.kbcal-paper:focus-visible { background: var(--vp-c-brand-1); color: var(--vp-c-white); }
.vp-doc a.kbcal-paper.current { box-shadow: 0 0 0 2px var(--vp-c-brand-1); }
.kbcal-title { margin: 0.45rem 0 0; min-height: 2.6em; max-width: 15.5rem; font-size: 0.8rem; line-height: 1.3; color: var(--vp-c-text-2); }
.kbcal-date { color: var(--vp-c-text-1); font-weight: 600; margin-right: 0.25rem; }
</style>
