// The editor's reading of Markdown and its text helpers (docs/src/components/kbEditorSyntax.ts).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { markdownParser, referenceQuery, toggleMark } from '../../docs/src/components/kbEditorSyntax.ts'

// The spans of `text` the parser reads as mathematics.
function math(text) {
  const out = []
  markdownParser.parse(text).iterate({ enter: n => { if (n.name === 'Math') out.push(text.slice(n.from, n.to)) } })
  return out
}

test('mathematics, inline and displayed, as the renderer reads it', () => {
  assert.deepEqual(math('Energy $E = mc^2$ and $$\\int_0^1 x\\,dx$$.'), ['$E = mc^2$', '$$\\int_0^1 x\\,dx$$'])
  assert.deepEqual(math('$$\na + b\n$$'), ['$$\na + b\n$$'])
  assert.deepEqual(math('It costs $5 and $6.'), [])                   // no space just inside a single dollar
  assert.deepEqual(math('Escaped \\$x$ and `$y$` in code'), [])
})

test('a reference being typed', () => {
  assert.deepEqual(referenceQuery('See @KB-1'), { at: 4, q: 'KB-1' })
  assert.deepEqual(referenceQuery('@'), { at: 0, q: '' })
  assert.equal(referenceQuery('mail me@example.org'), null)
})

test('marks around a selection, put on and taken off', () => {
  assert.deepEqual(toggleMark('a word here', 2, 6, '**'), { text: 'a **word** here', from: 4, to: 8 })
  assert.deepEqual(toggleMark('a **word** here', 4, 8, '**'), { text: 'a word here', from: 2, to: 6 })
})
