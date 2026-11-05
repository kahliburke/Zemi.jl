// The Configuration page's Look section (KBConfiguration.vue): a logo uploaded or pasted, drawn as a
// PNG in the browser, and Zemi's put back.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10"><rect width="20" height="10" fill="#c33"/></svg>'

test('a logo uploaded as an SVG becomes the logo, and Zemi\'s can be put back', async () => {
  const { page, errors, close } = await open('/service/configuration', '.kbcf-brand')
  const row = page.locator('.kbcf-row:has(img.logo)')
  await row.locator('input[type=file]').setInputFiles({ name: 'logo.svg', mimeType: 'image/svg+xml', buffer: Buffer.from(svg) })
  await page.waitForSelector('.kbcf-saved:has-text("Saved")')
  assert.equal((await api('/api/config/brand')).logo.own, true)
  assert.match(await row.innerText(), /this knowledge base's/)
  await row.locator('button:text-is("use Zemi\'s")').click()
  await page.waitForSelector('.kbcf-saved:has-text("Put back")')
  assert.equal((await api('/api/config/brand')).logo.own, false)
  assert.deepEqual(errors, [])
  await close()
})

test('an image pasted on the front page image takes its place', async () => {
  const { page, errors, close } = await open('/service/configuration', '.kbcf-brand')
  await page.locator('img.hero-dark').evaluate(async (img, text) => {
    const data = new DataTransfer()
    data.items.add(new File([text], 'pasted.svg', { type: 'image/svg+xml' }))
    img.focus()
    img.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))
  }, svg)
  await page.waitForSelector('.kbcf-saved:has-text("Saved")')
  assert.equal((await api('/api/config/brand'))['hero-dark'].own, true)
  await api('/api/config/brand/hero-dark?reset=1', {})                       // as it was
  assert.deepEqual(errors, [])
  await close()
})
