// The findings page (KBFindings.vue) on the seeded test service.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('a finding reads as a write-up, with its sources beside it', async () => {
  const { page, errors, close } = await open('/findings#BR-F1', '.kbf-claim')
  assert.equal(await page.locator('.kbf-claim').innerText(), 'The crest is sharp')
  assert.equal(await page.locator('.kbf-body mjx-container').count(), 1)
  assert.match(await page.locator('.kbf-sources').innerText(), /FROM[\s\S]*Read the reef papers/i)
  assert.deepEqual(errors, [])
  await close()
})

test('started from a task on the board, it begins with that task as its source', async () => {
  const { page, errors, close } = await open('/projects#BR-1', '.kbp-panel')
  await page.locator('.kbp-panel a:has-text("Finding")').click()
  await page.waitForSelector('.kbf-editing')
  assert.match(await page.locator('.kbf-chip').innerText(), /from BR-1/)
  await page.locator('.kbf-claim-field').fill('Started from a task')
  await page.locator('.kbf-editing .kbf-button').click()
  await page.waitForSelector('.kbf-claim')
  const made = (await api('/api/findings?project=BR')).find(f => f.claim === 'Started from a task')
  assert.deepEqual((await api(`/api/findings/${made.ref}`)).sources.map(s => [s.kind, s.target]), [['task', 'BR-1']])
  await api(`/api/findings/${made.ref}/delete`, {})                         // as it was
  assert.deepEqual(errors, [])
  await close()
})

test('contesting asks why, and shows it', async () => {
  await api('/api/findings/BR-F1', { status: 'accepted' })
  const { page, errors, close } = await open('/findings#BR-F1', '.kbf-claim')
  await page.locator('button:text-is("Contest")').click()
  await page.locator('.kbf-asking input').fill('Only one surface measured')
  await page.locator('.kbf-asking .kbf-button').click()
  await page.waitForSelector('.kbf-reason')
  assert.match(await page.locator('.kbf-reason').innerText(), /contested by[\s\S]*Only one surface measured/i)
  await api('/api/findings/BR-F1', { status: 'draft' })                     // as it was
  assert.deepEqual(errors, [])
  await close()
})
