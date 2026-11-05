// The mentions of a paper's figures and tables a page links to its gallery.
import { test } from 'node:test'
import assert from 'node:assert/strict'
const { mentionPieces, numeral } = await import('../../docs/src/components/kbFigureMentions.ts')

const has = key => ['figure:2', 'figure:3', 'figure:4', 'table:2'].includes(key)
const links = text => mentionPieces(text, has).filter(p => p.key).map(p => [p.text, p.key])

test('mentions in their forms are linked, each number its own', () => {
  assert.deepEqual(links('As Fig. 3 shows'), [['Fig. 3', 'figure:3']])
  assert.deepEqual(links('Figure 3b and FIG. 2.'), [['Figure 3b', 'figure:3'], ['FIG. 2', 'figure:2']])
  assert.deepEqual(links('Figs. 2 and 4 compare'), [['Figs. 2', 'figure:2'], ['4', 'figure:4']])
  assert.deepEqual(links('Table II lists'), [['Table II', 'table:2']])
  assert.deepEqual(links('as figure 3 shows'), [['figure 3', 'figure:3']])
})

test('what the paper lacks, and words that only look like mentions, stay text', () => {
  assert.deepEqual(links('Fig. 9 and the configuration 3'), [])
  assert.deepEqual(links('Figs. 2 and 9'), [['Figs. 2', 'figure:2']])
  const pieces = mentionPieces('See Fig. 3, then Table 7.', has)
  assert.equal(pieces.map(p => p.text).join(''), 'See Fig. 3, then Table 7.')     // the text is kept whole
  assert.equal(numeral('XIV'), 14)
})
