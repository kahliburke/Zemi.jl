// The Status page (docs/src/components/KBOperations.vue) on the seeded test service (see serve.jl).
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('backing up from the Status page takes a snapshot, which the list shows', async () => {
  const { page, errors, close } = await open('/service/operations', '.kbo-cards')
  await page.getByRole('button', { name: 'Back up now' }).click()
  await page.waitForFunction(() => /Last snapshot/.test(document.querySelector('.kbo')?.textContent ?? ''), null, { timeout: 30000 })
  await page.getByRole('button', { name: 'The snapshots' }).click()
  const row = page.locator('.kbo-snapshots tbody tr').first()
  await row.waitFor()
  assert.match(await row.innerText(), /^\d{8}T\d{6}Z/)
  const listed = await api('/api/ops/backups')
  assert.ok(listed.backups.length >= 1 && listed.status.error === '')
  assert.deepEqual(errors, [])
  await close()
})
