import test from 'node:test'
import assert from 'node:assert/strict'
import { forceSettings, linkStrength } from '../../docs/src/components/kbExplorePhysics.ts'

test('force preferences survive a storage round trip, with defaults for absent or invalid fields', () => {
  const settings = { repulsion: 130, strength: 0.7, distance: 90, centering: 0.9, similarity: 2 }
  assert.deepEqual(forceSettings(JSON.parse(JSON.stringify(settings))), settings)
  assert.deepEqual(forceSettings({ strength: 'invalid', similarity: -1, distance: 300 }), {
    ...forceSettings(null), similarity: 0, distance: 250,
  })
})

test('similarity weight scales scored links independently of explicit relations', () => {
  const settings = forceSettings({ strength: 0.5, similarity: 2 })
  for (const kind of ['cites', 'refers', 'evidence', 'related', 'task']) {
    assert.equal(linkStrength(settings, { kind }), 0.5)
  }
  assert.equal(linkStrength(settings, { kind: 'similar', similarity: 0.75 }), 0.75)
  assert.equal(linkStrength({ ...settings, similarity: 0 }, { kind: 'similar', similarity: 1 }), 0)
})
