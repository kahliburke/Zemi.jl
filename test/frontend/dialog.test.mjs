// Dialogs and panels over the page (docs/src/components/kbDialog.ts): Escape closes the one opened
// last, and the focus goes in as one opens and back as it closes.
import { test } from 'node:test'
import assert from 'node:assert/strict'

let listener = null
globalThis.window = { addEventListener: (_, f) => { listener = f }, removeEventListener: (_, f) => { if (listener === f) listener = null } }
const { closeOnEscape, holdFocus } = await import('../../docs/src/components/kbDialog.ts')

const escape = (inField = false) => {
  const e = { key: 'Escape', defaultPrevented: false, target: { closest: () => (inField ? {} : null) }, preventDefault() { this.defaultPrevented = true } }
  listener?.(e)
  return e
}

test('Escape closes the dialog opened last, then the one under it', () => {
  const closed = []
  const panel = closeOnEscape(() => closed.push('panel'), { fields: false })
  const dialog = closeOnEscape(() => closed.push('dialog'))
  assert.ok(escape(true).defaultPrevented)                              // in a dialog's field, the dialog
  dialog()
  assert.ok(!escape(true).defaultPrevented)                             // in a field beside the page, the field's
  escape()
  assert.deepEqual(closed, ['dialog', 'panel'])
  panel()
  assert.equal(listener, null)                                          // none open, none listening
})

test('Escape a field has used is left alone', () => {
  let closed = 0
  const stop = closeOnEscape(() => closed++)
  listener({ key: 'Escape', defaultPrevented: true, target: null, preventDefault() {} })
  listener({ key: 'Enter', defaultPrevented: false, target: null, preventDefault() {} })
  assert.equal(closed, 0)
  stop()
})

test('the focus goes into a dialog and back', () => {
  const focused = []
  const el = name => ({ name, isConnected: true, focus() { focused.push(name) } })
  const trigger = el('trigger')
  globalThis.document = { activeElement: trigger }
  const box = { ...el('box'), querySelector: () => null }
  const release = holdFocus(box)
  const field = el('field')
  holdFocus({ ...el('form'), querySelector: () => field })
  release()
  assert.deepEqual(focused, ['box', 'field', 'trigger'])
})
