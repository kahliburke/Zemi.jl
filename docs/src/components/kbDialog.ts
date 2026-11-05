// What dialogs and panels over the page share (see KBDialog.vue): Escape closing the one opened
// last, and the focus moved in as one opens and back as it closes.

type Entry = { close: () => void; fields: boolean }
const open: Entry[] = []

// One listener answers for every dialog open, after the page's own: a field that uses Escape (a list
// of completions closing) keeps it.
function onKey(e: KeyboardEvent) {
  if (e.key !== 'Escape' || e.defaultPrevented || !open.length) return
  const top = open[open.length - 1]
  if (!top.fields && (e.target as HTMLElement | null)?.closest?.('input, textarea, select, .cm-editor')) return
  e.preventDefault()
  top.close()
}

/**
 * Let Escape call `close` while this is the last opened of those open; the returned function takes it
 * off. With `fields: false`, Escape pressed in a field is left to the field (a panel beside the page,
 * rather than a dialog over it).
 */
export function closeOnEscape(close: () => void, { fields = true } = {}): () => void {
  const entry = { close, fields }
  if (!open.length) window.addEventListener('keydown', onKey)
  open.push(entry)
  return () => {
    const i = open.indexOf(entry)
    if (i >= 0) open.splice(i, 1)
    if (!open.length) window.removeEventListener('keydown', onKey)
  }
}

/**
 * Move the focus into `box`, which is opening: to what in it has `autofocus`, else its first field,
 * else the box itself. The returned function puts it back where it was.
 */
export function holdFocus(box: HTMLElement): () => void {
  const before = document.activeElement as HTMLElement | null
  ;(box.querySelector<HTMLElement>('[autofocus], input:not([type=hidden]), select, textarea') ?? box).focus()
  return () => { if (before?.isConnected) before.focus() }
}

let made = 0
/** An id for an element a dialog is named by. */
export const dialogId = () => `kb-dialog-${++made}`
