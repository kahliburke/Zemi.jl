// The Documents page (KBManager.vue): dropping a document with a reason, and restoring it from the dropped view.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('a document dropped with a reason is listed as dropped, and restored from there', async () => {
  const { page, errors, close } = await open('/service/manage', '.kbm-table')
  await page.locator('.kbm-input').fill('2609.00099')
  const row = page.locator('.kbm-table tbody tr', { hasText: 'Tide gauges along a reef flat' })
  await row.waitFor()
  await row.locator('select.kbm-select').selectOption('drop')
  const dialog = page.locator('.kb-dialog')
  await dialog.waitFor()
  assert.match(await dialog.locator('h3').innerText(), /Drop 2609\.00099\?/)
  await dialog.locator('textarea').fill('Not about reefs after all')
  await dialog.locator('button', { hasText: 'Drop' }).click()
  await row.waitFor({ state: 'detached' })
  await page.locator('.kbm-filters select').selectOption('dropped')
  const dropped = page.locator('.kbm-table tbody tr', { hasText: 'Tide gauges along a reef flat' })
  await dropped.waitFor()
  assert.match(await dropped.innerText(), /Not about reefs after all/)
  await dropped.locator('button', { hasText: 'Restore' }).click()
  await page.locator('text=Nothing is dropped.').waitFor()
  assert.deepEqual(errors, [])
  await close()
})
