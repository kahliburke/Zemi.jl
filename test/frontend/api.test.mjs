// The knowledge base API from the pages: connecting (a service still starting is asked again; a site
// without the API is told so at once), the failures requests give, and requests of which only the
// latest counts.
import { test } from 'node:test'
import assert from 'node:assert/strict'

const { connect, mode, status, RECONNECT, getJSON, post, latest, isStale, every, liveOrSite } =
  await import('../../docs/src/components/kbApi.ts')
// What connecting touches of a browser, set after Vue has loaded (it looks for a full document).
globalThis.document = { documentElement: { classList: { toggle() {} } } }
RECONNECT.every = 5

const answers = list => {
  const asked = []
  globalThis.fetch = async url => {
    asked.push(url)
    const a = list.shift()
    if (a === 'down') throw new TypeError('fetch failed')
    return new Response(a.status === 204 ? null : JSON.stringify(a.body ?? {}), { status: a.status })
  }
  return asked
}

test('a service still starting is asked again until it answers', async () => {
  const asked = answers(['down', { status: 503 }, { status: 504 }, { status: 200, body: { papers: 3 } }])
  await connect(true)
  assert.equal(mode.value, 'live')
  assert.equal(status.value.papers, 3)
  assert.equal(asked.length, 4)
})

test('a site without the API is static at once', async () => {
  const asked = answers([{ status: 404 }])
  await connect(true)
  assert.equal(mode.value, 'static')
  assert.equal(asked.length, 1)
})

test('it gives up when the service stays down', async () => {
  RECONNECT.within = 30
  answers(Array(100).fill('down'))
  await connect(true)
  assert.equal(mode.value, 'static')
  RECONNECT.within = 120_000
})

test('a refused request fails with the reason the API gave', async () => {
  answers([{ status: 403, body: { error: 'Not permitted (tasks.edit).' } }, { status: 500, body: {} }, { status: 204 }])
  await assert.rejects(getJSON('/api/tasks/KB-1'), { message: 'Not permitted (tasks.edit).' })
  await assert.rejects(getJSON('/api/tasks/KB-1'), /HTTP 500/)
  assert.equal(await post('/auth/sign-out'), null)
})

test('a static site is read from its own files, tried again while they are briefly away', async () => {
  mode.value = 'static'
  const asked = answers([{ status: 404 }, { status: 200, body: [1, 2] }])
  const realTimeout = globalThis.setTimeout
  globalThis.setTimeout = (f) => realTimeout(f, 0)
  try { assert.deepEqual(await liveOrSite('/api/watch', '/watch.json'), [1, 2]) } finally { globalThis.setTimeout = realTimeout }
  assert.deepEqual(asked, ['/watch.json', '/watch.json'])
})

test('only the latest of a kind of request counts', async () => {
  const opening = latest()
  const later = (v, ms) => signal => new Promise((done, fail) => {
    const t = setTimeout(() => done(v), ms)
    signal.addEventListener('abort', () => { clearTimeout(t); fail(new DOMException('aborted', 'AbortError')) })
  })
  const first = opening(later('first', 30)), second = opening(later('second', 5))
  await assert.rejects(first, e => isStale(e))
  assert.equal(await second, 'second')
  // Closing what it was for drops the one on its way.
  const third = opening(later('third', 5))
  opening.cancel()
  await assert.rejects(third, e => isStale(e))
  // A request that ignores its signal is dropped all the same when a later one is asked.
  const deaf = opening(() => new Promise(done => setTimeout(() => done('deaf'), 10)))
  const heard = opening(later('heard', 1))
  await assert.rejects(deaf, e => isStale(e))
  assert.equal(await heard, 'heard')
})

test('a repeated step never overlaps itself, and stops', async () => {
  let running = 0, most = 0, runs = 0
  const stop = every(1, async () => {
    running++; most = Math.max(most, running); runs++
    await new Promise(done => setTimeout(done, 5))
    running--
  })
  await new Promise(done => setTimeout(done, 40))
  stop()
  const seen = runs
  await new Promise(done => setTimeout(done, 20))
  assert.equal(most, 1)
  assert.ok(seen >= 2)
  assert.ok(runs <= seen + 1)
})
