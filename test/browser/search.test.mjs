// The search box (docs/src/components/KBSearch.vue), its answers held back here to see it wait.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const hit = title => ({ id: '2609.00001', slug: 'p1', kind: 'paper', title, authors: ['Ada Lovelace'], published: '2026-01-01',
  category: 'q-bio', score: 1, max_score: 1, evidence: [], passages: [] })

test('a search shows that it is running, and dims what an earlier query found', async () => {
  const held = []
  const prepare = page => page.route(u => new URL(u).pathname.endsWith('/api/search'), r => { held.push(r) })
  const answer = title => Promise.all(held.splice(0).map(r => r.fulfill({ json: { hits: [hit(title)], findings: [], seconds: 0.1 } })))
  const { page, errors, close } = await open('/generated/kb/', '.kb-search .kb-mode.live', { prepare })
  const spinner = page.locator('.kb-search .kb-spinner')

  await page.locator('.kb-search input').fill('coral')
  await spinner.waitFor({ timeout: 300 })                                  // at once, before the pause in typing ends
  await page.waitForTimeout(500)
  assert.ok(held.length > 0)
  assert.ok(await spinner.isVisible())
  await answer('Coral polyps')
  await page.locator('.kb-hit', { hasText: 'Coral polyps' }).waitFor()
  await spinner.waitFor({ state: 'detached' })
  assert.equal(await page.locator('.kb-results.stale').count(), 0)

  // A new query: the last one's results are dimmed until its own come.
  await page.locator('.kb-search input').fill('coral reef')
  await page.locator('.kb-results.stale').waitFor({ timeout: 300 })
  await page.waitForTimeout(500)
  if (process.env.ZEMI_SHOT) await page.locator('.kb-search').screenshot({ path: process.env.ZEMI_SHOT })
  await answer('Coral reefs')
  await page.locator('.kb-hit', { hasText: 'Coral reefs' }).waitFor()
  assert.equal(await page.locator('.kb-results.stale').count(), 0)
  assert.equal(await spinner.count(), 0)

  // Cleared, nothing runs.
  await page.locator('.kb-search input').fill('')
  assert.equal(await spinner.count(), 0)
  assert.deepEqual(errors, [])
  await close()
})
