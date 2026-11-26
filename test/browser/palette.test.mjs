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
  assert.match(page.url(), /\/projects#BR-1$/)
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

test('the command menu and editor shortcuts filter actions and pages without searching documents', async () => {
  const { page, close } = await open('/projects#BR', '.kbp-card')
  try {
    const lookups = []
    page.on('request', r => { if (r.url().includes('/api/tasks/references')) lookups.push(r.url()) })
    const trigger = page.getByRole('button', { name: 'Commands', exact: true })
    await trigger.click()
    const input = page.getByRole('combobox', { name: 'Filter commands' })
    await input.fill('reefs')
    await page.getByText('No matching commands or pages.').waitFor()
    await page.keyboard.press('Escape')
    assert.ok(await trigger.evaluate(el => el === document.activeElement))
    await page.keyboard.press('ControlOrMeta+Shift+p')
    await input.fill('explore')
    const option = page.getByRole('dialog', { name: 'Command palette' }).getByRole('option', { selected: true })
    assert.match(await option.innerText(), /Explore/)
    assert.equal(await option.getAttribute('id'), await input.getAttribute('aria-activedescendant'))
    await page.keyboard.press('Enter')
    await page.waitForURL(/\/kb\/explore(?:\.html)?$/)
    await page.keyboard.press('F1')
    await input.waitFor()
    await page.keyboard.press('ArrowDown')
    assert.equal(await input.getAttribute('aria-activedescendant'), 'kbpal-item-1')
    await page.keyboard.press('ControlOrMeta+k')
    await page.getByRole('combobox', { name: 'Go to or do' }).waitFor()
    assert.deepEqual(lookups, [])
  } finally { await close() }
})

test('the mobile navigation opens one command palette by touch', async () => {
  const { page, close } = await open('/projects#BR', '.kbp-card', { width: 390, height: 844, touch: true })
  try {
    await page.locator('.VPNavBarHamburger').tap()
    await page.getByRole('button', { name: 'Commands', exact: true }).tap()
    await page.getByRole('combobox', { name: 'Filter commands' }).fill('theme')
    assert.equal(await page.getByRole('dialog', { name: 'Command palette' }).count(), 1)
    await page.getByRole('option', { name: /theme/i }).tap()
    await page.getByRole('dialog', { name: 'Command palette' }).waitFor({ state: 'hidden' })
  } finally { await close() }
})

test('a static copy leaves the site search shortcut available', async () => {
  const { page, close } = await open('/', '.VPNavBar', {
    prepare: page => page.route('**/api/status', r => r.fulfill({ status: 404 }))
  })
  try {
    await page.locator('.VPNavBarSearch button').waitFor()
    await page.keyboard.press('ControlOrMeta+k')
    await page.locator('.VPLocalSearchBox').waitFor()
    assert.equal(await page.getByRole('button', { name: 'Commands', exact: true }).count(), 0)
    assert.equal(await page.locator('.kbpal-input').count(), 0)
  } finally { await close() }
})
