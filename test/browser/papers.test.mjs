// A paper's page, made from its data file by the paper template (KBPaperPage.vue, kbTemplates.ts).
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

test("a paper's page, from a link in the site: its title, header, outline and tab", async () => {
  const { page, errors, close } = await open('/generated/kb/timeline', '.vp-doc a[href*="papers/"]')
  await page.locator('.vp-doc a', { hasText: 'Figures to look at' }).first().click()
  await page.waitForSelector('h1#paper-title')
  assert.equal((await page.locator('h1#paper-title').innerText()).trim(), 'Figures to look at')
  assert.match(page.url(), /\/generated\/kb\/papers\/doc-[0-9a-f]+(\.html)?$/)
  assert.match(await page.locator('.kb-paper-head').innerText(), /Uploaded PDF/)
  await page.waitForFunction(() => document.title.startsWith('Figures to look at'))
  await page.waitForSelector('.VPDocAsideOutline a:has-text("Figures and tables")')
  assert.deepEqual(errors, [])
  await close()
})
