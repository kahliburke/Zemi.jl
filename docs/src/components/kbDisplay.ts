// How this browser shows the papers' figures: each theme its own copy (the default), or always the
// figure as the paper drew it. Kept in this browser, and applied as a class on the page's root.
import { ref } from 'vue'

const KEY = 'kb-original-figures'
export const originalFigures = ref(false)

function apply() { document.documentElement.classList.toggle('kb-original-figures', originalFigures.value) }

export function loadDisplay() {
  originalFigures.value = localStorage.getItem(KEY) === '1'
  apply()
}

export function setOriginalFigures(on: boolean) {
  originalFigures.value = on
  on ? localStorage.setItem(KEY, '1') : localStorage.removeItem(KEY)
  apply()
}
