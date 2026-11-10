// The site on a phone and a tablet: a touch screen, laid out as a mobile browser lays it out.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const PHONE = { width: 390, height: 844, touch: true }
const TABLET = { width: 820, height: 1180, touch: true }
// Whether the page scrolls sideways: wider than its window.
const sideways = page => page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth)

test('on a phone the board fits the screen, and a task opens over the whole of it', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card', PHONE)
  assert.equal(await sideways(page), false)
  // The project's About folds to its line; the filters behind a button.
  assert.equal(await page.locator('.kbp-context.folded').count(), 1)
  assert.equal(await page.getByLabel('Sort each column').isVisible(), false)
  await page.locator('.kbp-card:has(.kbp-ref:text-is("BR-1"))').tap()
  const dock = page.locator('.kbd.full')
  await dock.waitFor()
  const box = await dock.boundingBox()
  assert.equal(Math.round(box.x), 0)
  assert.equal(Math.round(box.width), 390)
  assert.equal(await page.locator('.kbd-edge').count(), 0)
  assert.equal(await sideways(page), false)
  await page.getByRole('button', { name: 'Back' }).tap()
  await dock.waitFor({ state: 'detached' })
  assert.deepEqual(errors, [])
  await close()
})

test('on a phone the documents table scrolls in place', async () => {
  const { page, errors, close } = await open('/generated/kb/manage', '.kbm-table', PHONE)
  assert.equal(await sideways(page), false)
  assert.deepEqual(errors, [])
  await close()
})

test('on a tablet the docked task panel is resized by dragging its edge with a finger', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card', TABLET)
  await page.locator('.kbp-card:has(.kbp-ref:text-is("BR-1"))').tap()
  const dock = page.locator('.kbd.right')
  await dock.waitFor()
  const before = (await dock.boundingBox()).width
  const edge = await page.locator('.kbd-edge').boundingBox()
  assert.ok(edge.width >= 24, `the edge is a finger's width (${edge.width} px)`)
  // A real touch, through the browser's input: it must drag the edge, not scroll the page.
  const cdp = await page.context().newCDPSession(page)
  const x = edge.x + edge.width / 2, y = edge.y + edge.height / 2
  const touch = (type, x) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] })
  await touch('touchStart', x)
  for (let i = 1; i <= 10; i++) await touch('touchMove', x - 12 * i)
  await touch('touchEnd', x - 120)
  const after = (await dock.boundingBox()).width
  assert.ok(Math.abs(after - before - 120) <= 4, `${before} px to ${after} px`)
  assert.deepEqual(errors, [])
  await close()
})
