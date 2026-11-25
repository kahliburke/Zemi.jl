// The plugin reads citations as Zemi does (see obsidian.jl and the vault's tests in test/suite.jl).
import { strict as assert } from 'node:assert'
import { citationGroups, citations } from '../src/cite_rule'

const keys = (text: string) => citations(text).map(c => c.key)
const marked = (text: string) => citations(text).map(c => text.slice(c.from, c.to))

const daily = 'Read about tides [see @arXiv:2401.00001, p. 2; @nobody], not [a link @x](https://example.org).'
assert.deepEqual(keys(daily), ['arXiv:2401.00001', 'nobody'])                 // a link's text is no citation
assert.deepEqual(marked(daily), ['@arXiv:2401.00001', '@nobody'])             // from its `@` to the key's end
assert.deepEqual(keys('[@hale2024tides; -@lovelace2024engines]'), ['hale2024tides', 'lovelace2024engines'])
assert.deepEqual(marked('[-@lovelace2024engines, p. 3]'), ['@lovelace2024engines'])
assert.deepEqual(keys('Write to [ada@x.org] or ada@x.org.'), [])               // an address names no document
assert.deepEqual(keys('[@heron-migration.] and [@Água2026]'), ['heron-migration', 'Água2026'])
assert.deepEqual(keys('[@a]\n[@b]'), ['a', 'b'])
// A citation's parts keep the words around their keys, as it is shown by its documents' titles.
const g = citationGroups(daily)
assert.equal(g.length, 1)
assert.equal(daily.slice(g[0].from, g[0].to), '[see @arXiv:2401.00001, p. 2; @nobody]')
assert.deepEqual(g[0].items.map(i => [i.before, i.key, i.after]), [['see ', 'arXiv:2401.00001', ', p. 2'], ['', 'nobody', '']])
assert.deepEqual(citationGroups('[no key here] and [x @y]').map(g => g.items.map(i => i.key)), [['y']])
console.log('cite_rule: ok')
