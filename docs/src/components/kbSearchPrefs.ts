// The rankings this browser has chosen to search with (see KBSettings), kept in its storage, and
// what a search uses of them: each layer with vectors to search, and keyword search when no layer is left.
import { ref, computed } from 'vue'
import { status } from './kbApi'

export type Choice = { keyword: boolean; layers: string[] }

const PREFS = 'zemi.search.rankings'
const chosen = ref<Choice | null>(null)
// Read once in the browser (not while the site is built).
if (typeof localStorage !== 'undefined') {
  try { chosen.value = JSON.parse(localStorage.getItem(PREFS) ?? 'null') } catch { chosen.value = null }
}

const defaults = (): Choice => ({ keyword: status.value?.keyword.default ?? true,
                                  layers: (status.value?.layers ?? []).filter(l => l.default).map(l => l.name) })
// Layers without vectors (a knowledge base imported without Qdrant, say) have nothing to search, so
// a choice keeps only those with vectors, and searches by keyword when none is left.
const searchable = computed(() => new Set((status.value?.layers ?? []).filter(l => l.vectors > 0).map(l => l.name)))
export const vectorless = computed(() => status.value !== null && searchable.value.size === 0)
export const current = computed<Choice>(() => {
  const c = chosen.value ?? defaults()
  const layers = c.layers.filter(n => searchable.value.has(n))
  return { keyword: c.keyword || !layers.length, layers }
})
export const customised = computed(() => chosen.value !== null)

function save(next: Choice) {
  chosen.value = next
  localStorage.setItem(PREFS, JSON.stringify(next))
}
// A search needs something to search with, so the last ranking cannot be turned off.
export function toggleLayer(name: string) {
  const c = current.value
  const layers = c.layers.includes(name) ? c.layers.filter(n => n !== name) : [...c.layers, name]
  if (layers.length || c.keyword) save({ ...c, layers })
}
export function toggleKeyword() {
  const c = current.value
  if (c.layers.length || !c.keyword) save({ ...c, keyword: !c.keyword })
}
export function reset() {
  chosen.value = null
  localStorage.removeItem(PREFS)
}
