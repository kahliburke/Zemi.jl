// The jobs the pages start (kbApi.ts): followed until each ends, which the pages hear of, the polling
// then stopping; and what a machine cannot run.
import { test } from 'node:test'
import assert from 'node:assert/strict'

const { followJobs, jobs, finishedJobs, blockers, status } = await import('../../docs/src/components/kbApi.ts')

const job = (id, s) => ({ id, name: id, status: s, message: '', elapsed: '1 s', ids: [], result: null, error: null })
const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(done => setImmediate(done)) }

test('a job followed is heard of when it ends, and the polling then stops', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] })
  let state = 'running', asked = 0
  globalThis.fetch = async () => { asked++; return new Response(JSON.stringify([job('j1', state), job('j0', 'done')]), { status: 200 }) }
  const before = finishedJobs.value
  await followJobs('j1')
  assert.deepEqual(jobs.value.map(j => j.status), ['running', 'done'])
  assert.equal(finishedJobs.value, before)
  state = 'done'
  t.mock.timers.tick(1500); await settle()
  assert.equal(finishedJobs.value, before + 1)
  const then = asked
  t.mock.timers.tick(6000); await settle()
  assert.equal(asked, then)                                               // nothing running, nothing followed
})

test('one who may not see every job follows their own', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] })
  const asked = []
  globalThis.fetch = async url => {
    asked.push(url)
    return url.endsWith('/api/jobs') ? new Response(JSON.stringify({ error: 'Not permitted (jobs.view).' }), { status: 403 })
                                     : new Response(JSON.stringify(job('j2', 'failed')), { status: 200 })
  }
  const before = finishedJobs.value
  await followJobs('j2')
  assert.deepEqual(asked, ['/api/jobs', '/api/jobs/j2'])
  assert.equal(jobs.value[0].id, 'j2')
  assert.equal(finishedJobs.value, before + 1)
})

test('what a machine cannot run, for papers and for code', () => {
  status.value = { cannot: { ingest: { paper: ['No PDF reader'], code: ['No git', 'No PDF reader'] } } }
  assert.deepEqual(blockers('ingest', ['2401.00001', '2402.00002']), ['No PDF reader'])
  assert.deepEqual(blockers('ingest', ['2401.00001', 'code-kb']), ['No PDF reader', 'No git'])
  assert.deepEqual(blockers('reindex', ['2401.00001']), [])
  assert.deepEqual(blockers('ingest', ['rec-reef-survey']), [])               // a kind the status does not name
  status.value = null
})
