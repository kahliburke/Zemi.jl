import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

test('share the reviewed text or just the deep link from a user gesture', async () => {
  const { page, close } = await open('/open-source#licenses', '.VPNavBar', {
    prepare: page => page.addInitScript(() => {
      Object.defineProperty(navigator, 'canShare', { value: () => true })
      Object.defineProperty(navigator, 'share', { value: async data => {
        window.delivered = { data, activated: navigator.userActivation.isActive }
        if (window.cancelShare) throw new DOMException('Cancelled', 'AbortError')
      } })
    }),
  })
  try {
    const trigger = page.getByRole('button', { name: 'Share this page' })
    const excerpt = await page.locator('.VPContent h1').first().evaluate(el => {
      const range = document.createRange()
      range.selectNodeContents(el)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      return selection.toString().trim()
    })
    await trigger.click()
    const dialog = page.getByRole('dialog', { name: 'Share this page' })
    assert.equal(await dialog.getByLabel('Text to share').inputValue(), excerpt)
    await dialog.getByLabel('Text to share').fill('A reviewed passage.')
    await dialog.getByRole('button', { name: 'Share…' }).click()
    const { data, activated } = await page.evaluate(() => window.delivered)
    assert.equal(activated, true)
    assert.equal(data.text, 'A reviewed passage.')
    assert.equal(data.url, page.url())
    assert.ok(data.title)
    await trigger.click()
    await dialog.getByRole('button', { name: 'Link only' }).click()
    await page.evaluate(() => { window.cancelShare = true })
    await dialog.getByRole('button', { name: 'Share…' }).click()
    assert.deepEqual(await page.evaluate(() => window.delivered.data), { url: page.url() })
    assert.ok(await dialog.isVisible())
    assert.equal(await dialog.getByRole('status').count(), 0)
  } finally { await close() }
})
