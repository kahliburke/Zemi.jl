// The setup page (KBSetup.vue) on the seeded test service: through its steps to a knowledge base set
// up for a group. Run last: it changes the group the others see.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('setup walks through the group, arXiv, the model and sharing', async () => {
  const { page, errors, close } = await open('/service/setup', '.kbsu-steps')
  const next = page.locator('.kbsu-button')
  assert.ok(await next.isDisabled())                                        // a group needs a name
  await page.locator('.kbsu-field:has-text("Name") input').first().fill('Reef Ecology Lab')
  await page.locator('.kbsu-field:has-text("Field") input').first().fill('coral reef ecology')
  await page.locator('.kbsu-area input').first().fill('Recovery')
  await next.click()
  await page.locator('input[placeholder^="Find a category"]').fill('populations')
  await page.locator('.kbsu-found li:has-text("q-bio.PE")').click()
  assert.match(await page.locator('.kbsu-chips').innerText(), /q-bio\.PE/)
  // From the keyboard: Enter takes the first found.
  await page.locator('input[placeholder^="Find a category"]').fill('q-bio.QM')
  await page.locator('input[placeholder^="Find a category"]').press('Enter')
  assert.match(await page.locator('.kbsu-chips').innerText(), /q-bio\.QM/)
  await next.click()
  assert.ok(await page.locator('.kbsu-choice input[type=radio]:checked').count() === 1)   // the summarizer configured
  await next.click()
  await page.locator('.kbsu-choice:has-text("Alone") input').check()
  await page.locator('.kbsu-button:text-is("Set up")').click()
  await page.waitForSelector('.kbsu-done')
  // Adding papers is on the Documents page.
  assert.match(await page.locator('.kbsu-done a', { hasText: 'Add papers' }).getAttribute('href'), /\/manage(\.html)?#add-documents$/)
  const conf = await api('/api/config')
  const value = key => conf.settings.find(s => s.key === key).value
  assert.equal(value('group.name'), 'Reef Ecology Lab')
  assert.deepEqual(value('group.focus_areas'), [{ name: 'Recovery', description: '' }])
  assert.ok(value('watch.categories').includes('q-bio.PE'))
  assert.deepEqual(errors, [])
  await close()
})
