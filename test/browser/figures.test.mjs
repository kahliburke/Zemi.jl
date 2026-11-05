// A paper's figures and tables (KBFigures.vue) on the seeded test service: the paper of the day's
// analysis and a paper's summary link their mentions to the figures, and a picked figure sits
// beside the paragraph discussing it.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('a picked figure sits after the paragraph that first mentions it', async () => {
  const { page, errors, close } = await open('/generated/kb/daily', 'button.kbfig-mention')
  // The analysis is drawn in pieces (KBDayPage.vue): the paragraph ends its piece, and the figure follows.
  const after = await page.locator('div:has(> p:last-child:has-text("The blue box in Fig. 1")) + p.kb-figure').count()
  assert.equal(after, 1)
  assert.deepEqual(errors, [])
  await close()
})

test('a mention previews its figure on hover and opens it on a click', async () => {
  // A short window, so the mentions are down the page.
  const { page, errors, close } = await open('/generated/kb/daily', 'button.kbfig-mention', { height: 420 })
  const mentions = await page.locator('button.kbfig-mention').allInnerTexts()
  // The inline figure's own label, under it, opens it large too.
  assert.deepEqual(mentions.slice(0, 5), ['Fig. 1', 'Figure 1', 'Table 1', 'Figs. 1', '2'])
  await page.locator('button.kbfig-mention', { hasText: 'Table 1' }).hover()
  await page.waitForSelector('.kbfig-preview img')
  assert.match(await page.locator('.kbfig-preview img').getAttribute('src'), /\/api\/figures\/.+\/table-1\.webp\?theme=dark/)
  assert.match(await page.locator('.kbfig-preview p').innerText(), /^Table 1\./)
  // The page stays where it was read: no jump to the top.
  await page.locator('button.kbfig-mention', { hasText: 'Table 1' }).scrollIntoViewIfNeeded()
  const y = await page.evaluate(() => window.scrollY)
  assert.ok(y > 0)
  await page.locator('button.kbfig-mention', { hasText: 'Table 1' }).click()
  await page.waitForSelector('.kbfig-overlay')
  assert.equal(await page.evaluate(() => window.scrollY), y)
  assert.match(await page.locator('.kbfig-nav span').innerText(), /3 of 3/)
  await page.keyboard.press('ArrowLeft')
  assert.match(await page.locator('.kbfig-caption').innerText(), /^Figure 2: A red box/)
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.kbfig-overlay').count(), 0)
  assert.equal(await page.evaluate(() => window.scrollY), y)
  assert.deepEqual(errors, [])
  await close()
})

test("a paper's summary links its mentions too, and the gallery opens from the page's contents", async () => {
  const days = await api('/api/daily')
  const id = days.find(d => d.day === '2026-10-01').id
  const slug = id.replace(/[./]/g, '-')
  const { page, errors, close } = await open(`/generated/kb/papers/${slug}`, 'button.kbfig-mention')
  assert.equal(await page.locator('.tip button.kbfig-mention').innerText(), 'Fig. 2')
  await page.locator('.VPDocAsideOutline a', { hasText: 'Figures and tables' }).click()
  await page.waitForSelector('.kbfig-grid .kbfig-item')
  assert.equal(await page.locator('.kbfig-item').count(), 3)
  assert.deepEqual(errors, [])
  await close()
})
