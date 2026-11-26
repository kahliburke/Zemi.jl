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
  await page.keyboard.press('ArrowDown')
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
  await page.keyboard.press('Enter')
  await page.waitForSelector('.kb-search input')
  assert.equal(await page.locator('.kb-search input').inputValue(), 'coral spawning')
  const dark = await page.evaluate(() => document.documentElement.classList.contains('dark'))
  await openPalette(page)
  await page.locator('.kbpal-input').fill(dark ? '>light theme' : '>dark theme')
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
    page.on('request', r => { if (r.url().includes('/api/search?')) lookups.push(r.url()) })
    const trigger = page.getByRole('button', { name: 'Search Zemi', exact: true })
    await trigger.click()
    await page.getByRole('combobox', { name: 'Search Zemi' }).fill('>')
    const input = page.getByRole('combobox', { name: 'Filter commands' })
    await input.fill('>reefs')
    await page.getByText('No matching commands or pages.').waitFor()
    await page.keyboard.press('Escape')
    assert.ok(await trigger.evaluate(el => el === document.activeElement))
    await page.keyboard.press('ControlOrMeta+Shift+p')
    await input.fill('>explore')
    const option = page.getByRole('dialog', { name: 'Command palette' }).getByRole('option', { selected: true })
    assert.match(await option.innerText(), /Explore/)
    assert.equal(await option.getAttribute('id'), await input.getAttribute('aria-activedescendant'))
    await page.keyboard.press('Enter')
    await page.waitForURL(/\/kb\/explore(?:\.html)?$/)
    await page.locator('.kbx').waitFor()
    await page.keyboard.press('F1')
    await input.waitFor()
    await input.press('ArrowDown')
    assert.equal(await input.getAttribute('aria-activedescendant'), 'kbpal-item-1')
    await page.keyboard.press('ControlOrMeta+k')
    await page.getByRole('combobox', { name: 'Search Zemi' }).waitFor()
    assert.deepEqual(lookups, [])
  } finally { await close() }
})

test('the mobile navigation opens one command palette by touch', async () => {
  const { page, close } = await open('/projects#BR', '.kbp-card', { width: 390, height: 844, touch: true })
  try {
    await page.getByRole('button', { name: 'Search Zemi', exact: true }).tap()
    await page.getByRole('combobox', { name: 'Search Zemi' }).fill('>theme')
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

test('a word found only in a note opens that note and is shareable with project and type filters', async () => {
  const { page, close } = await open('/projects#BR', '.kbp-card')
  try {
    await page.getByRole('button', { name: 'Search Zemi', exact: true }).click()
    const field = page.getByRole('combobox', { name: 'Search Zemi' })
    await field.fill('BR-1')
    await page.getByRole('option', { name: /Read the reef papers/ }).first().waitFor()
    assert.match(await page.getByRole('listbox', { name: 'Results' }).getByRole('option').first().innerText(), /BR-1/)
    await field.fill('transect')
    await page.getByRole('checkbox', { name: 'In project BR' }).check()
    const note = page.getByRole('option', { name: /Which transect first/i })
    await note.waitFor()
    const id = (await note.innerText()).match(/Note (\d+)/)[1]
    await page.keyboard.press('Enter')
    const result = page.locator('.kb-search a', { hasText: 'Which transect first' })
    await result.waitFor()
    await page.getByRole('combobox', { name: 'Result type' }).selectOption('task')
    await page.waitForURL('**/*kind=task*')
    assert.equal(new URL(page.url()).searchParams.get('project'), 'BR')
    await page.reload()
    await result.waitFor()
    assert.equal(await page.getByRole('combobox', { name: 'Project' }).inputValue(), 'BR')
    await result.click()
    await page.waitForURL('**/projects#BR-1/' + id)
    await page.locator('[data-event="' + id + '"]').waitFor()
  } finally { await close() }
})

test('a slow or failed suggestion can be retried without losing the query', async () => {
  const { page, close } = await open('/projects#BR', '.kbp-card')
  try {
    let release
    const held = new Promise(resolve => { release = resolve })
    await page.route('**/api/search?*', async route => {
      await held
      await route.fulfill({ status: 503, json: { error: 'Unavailable' } })
    }, { times: 1 })
    await openPalette(page)
    const field = page.locator('.kbpal-input')
    const asked = page.waitForRequest('**/api/search?*')
    await field.fill('transect')
    await asked
    await page.getByText('Searching…', { exact: true }).waitFor()
    release()
    await page.getByRole('button', { name: 'Retry', exact: true }).click()
    assert.equal(await field.inputValue(), 'transect')
    await page.getByRole('option', { name: /Which transect first/i }).waitFor()
    await field.fill('zznomatchesxyz')
    await page.getByText('No results for “zznomatchesxyz”.').waitFor()
  } finally { await close() }
})

test('the header keeps the query while the first status request is pending', async () => {
  let release
  const held = new Promise(resolve => { release = resolve })
  const { page, close } = await open('/projects#BR', '.VPNavBarSearch button', {
    prepare: page => page.route('**/api/status', async route => {
      await held
      await route.continue()
    })
  })
  try {
    await page.getByRole('button', { name: 'Search Zemi', exact: true }).click()
    const field = page.getByRole('combobox', { name: 'Search Zemi' })
    await field.fill('transect')
    await page.getByText('Connecting to Zemi…').waitFor()
    release()
    await page.getByRole('option', { name: /Which transect first/i }).waitFor()
    assert.equal(await page.locator('.VPLocalSearchBox').count(), 0)
  } finally { release(); await close() }
})
