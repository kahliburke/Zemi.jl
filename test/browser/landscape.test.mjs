// The landscape (docs/src/components/KBLandscape.vue), drawn from a landscape.json served here.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const paper = (i, more) => ({ id: `2609.0000${i}`, title: `Paper ${i}`, kind: 'paper', category: 'q-bio', page: `papers/p${i}`,
  x: i / 10, y: i / 10, cluster: 1, scores: [0.5], relevance: 0.3 + i / 20, area: 1, llm_relevance: null, one_line: null, ...more })
const landscape = papers => ({ built_at: '2026-11-08T00:00:00Z', layer: 'l', named_by: 's', focus_areas: [{ name: 'Area', description: '' }],
  clusters: [{ id: 1, name: 'One', description: '', named: true, size: papers.length, x: 0.5, y: 0.5, scores: [0.5], relevance: 0.5 }], papers })
const serving = data => page => page.route(u => new URL(u).pathname.endsWith('/landscape.json'), r => r.fulfill({ json: data }))
const ticks = page => page.locator('.kbl-svg .kbl-tick:not(.start)').allTextContents()

test('over time, papers are placed by when they were published, or by when the group had them', async () => {
  // Published over years, all had in one week, one with no publication date.
  const papers = [paper(1, { published: '2015', added: '2026-11-02' }), paper(2, { published: '2021-03', added: '2026-11-03' }),
                  paper(3, { published: '2025-06-01', added: '2026-11-04' }), paper(4, { published: '2026-10-29', added: '2026-11-05' }),
                  paper(5, { published: '', added: '2026-11-06' })]
  const { page, errors, close } = await open('/generated/kb/landscape', '.kbl', { prepare: serving(landscape(papers)) })
  await page.locator('.kbl-tab', { hasText: 'Over time' }).click({ timeout: 30000 })
  assert.equal(await page.locator('.kbl-svg circle').count(), 4)
  assert.match(await page.locator('.kbl-controls').innerText(), /1 without a date/)
  const years = await ticks(page)
  assert.ok(years.includes('2021'), String(years))
  await page.locator('.kbl-controls select').nth(1).selectOption('added')
  assert.equal(await page.locator('.kbl-svg circle').count(), 5)
  if (process.env.ZEMI_SHOT) await page.locator('.kbl').screenshot({ path: process.env.ZEMI_SHOT })
  assert.deepEqual((await ticks(page)).filter(t => /^Nov/.test(t)).slice(0, 2), ['Nov 2', 'Nov 3'])            // by the day
  assert.deepEqual(errors, [])
  await close()
})

test('a landscape built before papers had both dates is placed by its one date', async () => {
  const papers = [1, 2, 3, 4, 5].map(i => paper(i, { date: `202${i}-01-01` }))
  const { page, errors, close } = await open('/generated/kb/landscape', '.kbl', { prepare: serving(landscape(papers)) })
  await page.locator('.kbl-tab', { hasText: 'Over time' }).click({ timeout: 30000 })
  assert.equal(await page.locator('.kbl-svg circle').count(), 5)
  assert.deepEqual(errors, [])
  await close()
})
