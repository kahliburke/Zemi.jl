// The palette (docs/src/components/KBPalette.vue) on the seeded test service: Cmd-K opens it instead of
// VitePress's search, it finds the knowledge base's things and pages, and its commands run.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const openPalette = async page => {
  await page.keyboard.press('ControlOrMeta+k')
  await page.waitForSelector('.kbpal-input')
}

test('Cmd-K opens the palette, not the site search, and a task found opens on its board', async () => {
  const { page, errors, close } = await open('/findings#BR-F1', '.kbf-claim')
  await openPalette(page)
  assert.equal(await page.locator('.VPLocalSearchBox').count(), 0)
  await page.locator('.kbpal-input').fill('reef pap')
  await page.locator('.kbpal-item:has-text("Read the reef papers")').waitFor()
  assert.match(await page.locator('.kbpal-item.on').innerText(), /Read the reef papers[\s\S]*Task · BR-1/)
  await page.keyboard.press('Enter')
  await page.waitForSelector('.kbp-panel')
  assert.match(page.url(), /projects\.html#BR-1$/)
  assert.deepEqual(errors, [])
  await close()
})

test('it goes to pages and projects, searches the knowledge base, and switches the theme', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await openPalette(page)
  await page.locator('.kbpal-input').fill('findi')
  assert.ok(await page.locator('.kbpal-item:has-text("Findings")').count() >= 1)
  await page.locator('.kbpal-input').fill('OT')
  await page.locator('.kbpal-item:has-text("OT Other")').waitFor()
  await page.locator('.kbpal-input').fill('coral spawning')
  await page.locator('.kbpal-item:has-text("Search the knowledge base for")').click()
  await page.waitForSelector('.kb-search input')
  assert.equal(await page.locator('.kb-search input').inputValue(), 'coral spawning')
  const dark = await page.evaluate(() => document.documentElement.classList.contains('dark'))
  await openPalette(page)
  await page.locator('.kbpal-input').fill(dark ? 'light theme' : 'dark theme')
  await page.keyboard.press('Enter')
  assert.equal(await page.evaluate(() => document.documentElement.classList.contains('dark')), !dark)
  await openPalette(page)
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.kbpal-input').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})
