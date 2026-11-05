// What the components share for showing things (kbFormat.ts, kbUtils.ts) and the site's lists they
// read (kbData.ts).
import { test } from 'node:test'
import assert from 'node:assert/strict'

const { day, shortDay, when, todayUtc, bytes, plural, byline } = await import('../../docs/src/components/kbFormat.ts')
const { escapeHtml, markedSnippet, plainLine, anchorOf, anchors, fenced, plainCopy } = await import('../../docs/src/components/kbUtils.ts')
const { loadPapers, loadDays, FRESH } = await import('../../docs/src/components/kbData.ts')

test('days, a day as written being that day anywhere', () => {
  process.env.TZ = 'Pacific/Honolulu'
  assert.equal(day('2026-10-08'), new Date(Date.UTC(2026, 9, 8)).toLocaleDateString(undefined, { dateStyle: 'medium', timeZone: 'UTC' }))
  assert.match(day('2026-10-08'), /8/)
  assert.match(shortDay('2026-10-08'), /8/)
  assert.equal(day(''), '')
  assert.equal(day(null, '—'), '—')
  assert.equal(when(undefined, 'never'), 'never')
  assert.match(when('2026-10-08T10:30:00Z'), /2026/)
  assert.equal(todayUtc(new Date(Date.UTC(2026, 0, 1, 23, 30))), '2026-01-01')
})

test('sizes, counts and authors', () => {
  assert.equal(bytes(512), '512 B')
  assert.equal(bytes(2048), '2 KB')
  assert.equal(bytes(5.5 * 2 ** 20), '5.5 MB')
  assert.equal(bytes(3 * 2 ** 30), '3.0 GB')
  assert.equal(plural(1, 'paper'), '1 paper')
  assert.equal(plural(0, 'paper'), '0 papers')
  assert.equal(plural(2, 'summary', 'summaries'), '2 summaries')
  assert.equal(byline(['Ada', 'Rowan', 'Bea']), 'Ada et al.')
  assert.equal(byline(['Ada', 'Rowan', 'Bea'], 3), 'Ada, Rowan, Bea')
  assert.equal(byline(['Ada'], 1, 9), 'Ada et al.')                                  // the list cut short already
  assert.equal(byline([]), '')
})

test('text as HTML, and search snippets', () => {
  assert.equal(escapeHtml('<a href="x">&</a>'), '&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;')
  assert.equal(markedSnippet('a \x01<b>\x02 c'), 'a <mark>&lt;b&gt;</mark> c')
  assert.equal(plainLine('**Done**: the `fit`\n- one\n- two'), 'Done: the fit · one · two')
})

test('anchors of headings, kept apart', () => {
  assert.equal(anchorOf('Cited by'), 'cited-by')
  assert.equal(anchorOf('<em>Énergie</em> & β-decay'), 'énergie-β-decay')
  assert.equal(anchorOf('+ / ·'), '')
  const unique = anchors(['notes'])
  assert.deepEqual(['notes', 'fit', 'fit', 'fit'].map(unique), ['notes-2', 'fit', 'fit-2', 'fit-3'])
})

test('code fenced past its own backticks', () => {
  assert.equal(fenced('x = 1', 'julia'), '```julia\nx = 1\n```')
  assert.equal(fenced('a ```` b `c`'), '`````\na ```` b `c`\n`````')
})

test('a plain copy is apart from what it copies', () => {
  const v = { a: [1, { b: 2 }] }
  const c = plainCopy(v)
  c.a[1].b = 3
  assert.equal(v.a[1].b, 2)
})

test('the site\'s lists are read once, again once stale, and again after a failure', async () => {
  let asked = 0
  const answers = [{ status: 500 }, { status: 200, body: [{ id: '2401.00001' }] }, { status: 200, body: [{ id: '2402.00002' }] }]
  globalThis.fetch = async () => { asked++; const a = answers.shift(); return new Response(JSON.stringify(a.body ?? {}), { status: a.status }) }
  await assert.rejects(loadPapers())
  const [a, b] = await Promise.all([loadPapers(), loadPapers()])
  assert.equal(a, b)
  assert.equal(asked, 2)
  FRESH.ms = -1
  assert.equal((await loadPapers())[0].id, '2402.00002')
  FRESH.ms = 60_000
  globalThis.fetch = async url => new Response(JSON.stringify([{ day: '2026-10-08', from: url }]), { status: 200 })
  assert.equal((await loadDays())[0].from, '/daily.json')
})
