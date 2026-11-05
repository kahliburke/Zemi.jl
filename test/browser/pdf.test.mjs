// A paper's PDF in a dialog over its page (KBPdf.vue), on the seeded test service: from a section,
// at the section's first page, and from the paper's own buttons.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

const paper = async () => {
  const id = (await api('/api/daily')).find(d => d.day === '2026-10-01').id
  return { id, slug: id.replace(/[./]/g, '-') }
}
const focused = page => page.evaluate(() => document.activeElement?.className ?? '')

test("a section's PDF opens at its page, and Escape closes it", async () => {
  const { id, slug } = await paper()
  const { page, errors, close } = await open(`/generated/kb/papers/${slug}`, '.kbst summary button.kbpdf-chip')
  const chip = page.locator('.kbst summary button.kbpdf-chip').first()
  const n = Number((await chip.innerText()).match(/^PDF p\. (\d+)$/)[1])
  const sent = page.waitForResponse(r => r.url().includes(`/api/pdf/${id}`))
  await chip.click()
  const r = await sent
  assert.equal(r.status(), 200)
  assert.equal(r.headers()['content-type'], 'application/pdf')
  await page.waitForSelector('.kbpdf-box iframe')
  assert.equal(await page.locator('details.kbst[open]').count(), 0)            // the section stays as it was
  const src = await page.locator('.kbpdf-box iframe').getAttribute('src')
  assert.ok(src.endsWith(`/api/pdf/${id}${n > 1 ? `#page=${n}` : ''}`), src)
  assert.equal(await focused(page), 'kbpdf-close')
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.kbpdf-overlay').count(), 0)
  assert.equal(await focused(page), 'kbpdf-chip')                              // back where it was opened
  assert.deepEqual(errors, [])
  await close()
})

test("the paper's PDF opens from its buttons, and the backdrop closes it", async () => {
  const { slug } = await paper()
  const { page, errors, close } = await open(`/generated/kb/papers/${slug}`, '.kb-buttons button.kb-button')
  await page.locator('.kb-buttons button', { hasText: 'Uploaded PDF' }).click()
  await page.waitForSelector('.kbpdf-box iframe')
  await page.mouse.click(4, 4)
  assert.equal(await page.locator('.kbpdf-overlay').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('without the service, an upload offers no PDF', async () => {
  const { slug } = await paper()
  const { page, errors, close } = await open(`/generated/kb/papers/${slug}`, '.kbst summary', {
    prepare: p => p.route('**/api/status', route => route.fulfill({ status: 404, body: '' })) })
  await page.waitForFunction(() => !document.documentElement.classList.contains('kb-live') &&
                                   document.querySelector('.kb-buttons .kb-button-plain'))
  assert.equal(await page.locator('.kbpdf-chip').count(), 0)
  assert.deepEqual(errors.filter(e => !/404/.test(e)), [])
  await close()
})
