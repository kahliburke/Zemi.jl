// What this browser keeps: the rankings a search uses (kbSearchPrefs.ts), of which the last cannot be
// turned off, and the tutoring profile (kbProfile.ts), as the tutor reads it.
import { test } from 'node:test'
import assert from 'node:assert/strict'

const kept = new Map()
globalThis.localStorage = { getItem: k => kept.get(k) ?? null, setItem: (k, v) => kept.set(k, String(v)), removeItem: k => kept.delete(k) }
kept.set('zemi.search.rankings', '{not json')                              // a choice the browser mangled
kept.set('kb-tutoring-profile', '{"version": 1, "answers": ')
globalThis.fetch = async () => new Response(JSON.stringify({ questions: [
  { id: 'background', text: 'Your background?', options: ['Biology', 'Physics'] },
  { id: 'depth', text: 'How deep?', options: ['Overview', 'Details'] }] }), { status: 200 })

const { status } = await import('../../docs/src/components/kbApi.ts')
const { current, customised, toggleLayer, toggleKeyword, reset, vectorless } = await import('../../docs/src/components/kbSearchPrefs.ts')
const { profile, optedOut, loadProfile, loadQuestions, saveProfile, optOut, clearProfile, profileText } =
  await import('../../docs/src/components/kbProfile.ts')

const layer = (name, vectors, d = false) => ({ name, label: name, description: '', model: '', unit: '', source: '', dim: 8, vectors, papers: 1, default: d })

test('the rankings: the defaults, a choice kept, and the last one left on', () => {
  assert.equal(customised.value, false)                                    // a mangled choice is no choice
  status.value = { keyword: { default: true, description: '' }, layers: [layer('chunks', 10, true), layer('sections', 5), layer('empty', 0, true)] }
  assert.deepEqual(current.value, { keyword: true, layers: ['chunks'] })   // a layer without vectors is left out
  toggleKeyword()
  toggleLayer('chunks')                                                     // the last ranking stays
  assert.deepEqual(current.value, { keyword: false, layers: ['chunks'] })
  toggleLayer('sections'); toggleLayer('chunks')
  assert.deepEqual(current.value, { keyword: false, layers: ['sections'] })
  assert.deepEqual(JSON.parse(kept.get('zemi.search.rankings')), { keyword: false, layers: ['sections'] })
  status.value = { ...status.value, layers: [layer('sections', 0)] }       // its vectors gone: keyword search
  assert.equal(vectorless.value, true)
  assert.deepEqual(current.value, { keyword: true, layers: [] })
  reset()
  assert.equal(customised.value, false)
  assert.equal(kept.has('zemi.search.rankings'), false)
})

test('the profile: a mangled one is none, and it reads as the learner wrote it', async () => {
  loadProfile()
  assert.equal(profile.value, null)
  assert.equal(optedOut.value, false)
  await loadQuestions()
  assert.equal(profileText(), '')
  saveProfile({ version: 1, answers: { background: ['Biology', 'Physics'], depth: [] }, notes: { depth: ' Mostly the methods. ' }, updated: '' })
  assert.equal(profileText(), '- Your background? Biology; Physics\n- How deep? (no choice) (their note: Mostly the methods.)')
  optOut()
  loadProfile()
  assert.equal(optedOut.value, true)
  assert.equal(profileText(), '')
  clearProfile()
  loadProfile()
  assert.equal(optedOut.value, false)
})
