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

test("a paper's Cite panel: its reference, citation, BibTeX, address and link, each to copy", async () => {
  const { page, errors, close } = await open('/generated/kb/timeline', '.vp-doc a[href*="papers/"]')
  await page.locator('.vp-doc a', { hasText: 'Figures to look at' }).first().click()
  await page.waitForSelector('h1#paper-title')
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write'])
  const id = page.url().match(/papers\/(doc-[0-9a-f]+)/)[1]
  // The icon copies the reference at once.
  await page.locator('.kbct-icon').click()
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), `@${id}`)
  await page.locator('.kb-paper-head button', { hasText: 'Cite' }).click()
  const dialog = page.locator('.kb-dialog')
  await dialog.waitFor()
  assert.deepEqual(await dialog.locator('.kbct-label').allInnerTexts(),
                   ['Reference · in a task, note or finding here', 'Citation · APA', 'BibTeX', 'Link', 'Markdown'])
  const texts = await dialog.locator('.kbct-text').allInnerTexts()
  assert.equal(texts[0], `@${id}`)
  assert.match(texts[1], /Figures to look at/)
  assert.match(texts[2], new RegExp(`^@misc\\{${id},`))
  assert.equal(texts[3], page.url().replace(/[?#].*$/, ''))
  assert.equal(texts[4], `[Figures to look at](${texts[3]})`)
  await dialog.locator('.kbct-copy').nth(2).click()
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), texts[2])
  await page.keyboard.press('Escape')
  await dialog.waitFor({ state: 'detached' })
  assert.deepEqual(errors, [])
  await close()
})
