import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser, SITE } from './browser.mjs'

after(closeBrowser)

test('publish a Markdown manuscript, revise it and revisit the citation', async () => {
  const { page, close, errors } = await open('/publications/?project=BR', 'button:text-is("New publication")')
  try {
    await page.getByRole('button', { name: 'New publication' }).click()
    await page.getByLabel('Import manuscript').setInputFiles({
      name: 'survey.md', mimeType: 'text/markdown',
      buffer: Buffer.from('---\ntitle: Transect survey\ndate: 2026-04-12\n---\n## Results\nFirst measurement.')
    })
    assert.equal(await page.getByLabel('Title', { exact: true }).inputValue(), 'Transect survey')
    assert.equal(await page.getByLabel('Manuscript date').inputValue(), '2026-04-12')
    await page.getByLabel('Authors and contributions').fill('Rowan and Survey agent')
    await page.getByLabel('Abstract').fill('Three transects surveyed.')
    await page.getByRole('button', { name: 'Save and preview' }).click()
    await page.getByRole('heading', { name: 'Review draft' }).waitFor()
    await page.getByRole('button', { name: 'Publish v1 in BR' }).click()
    await page.waitForURL(/\/publications\/\d+\/v1\/$/)
    const cited = page.url()
    await page.getByRole('button', { name: 'Cite this version' }).click()
    assert.ok((await page.getByRole('status').allTextContents()).some(s => s.includes(cited)))
    await page.getByRole('button', { name: 'Prepare next version' }).click()
    await page.getByLabel('Manuscript (Markdown)').fill('Second measurement.')
    await page.getByLabel('What changed').fill('Added a transect.')
    await page.getByRole('button', { name: 'Save and preview' }).click()
    await page.getByRole('button', { name: 'Publish v2 in BR' }).click()
    await page.waitForURL(/\/v2\/$/)
    await page.getByText('Second measurement.', { exact: true }).waitFor()
    const id = Number(cited.match(/publications\/(\d+)/)[1])
    const results = await api('/api/search?q=transects&kinds=publication')
    assert.ok(results.publications.some(w => w.id === id && w.version === 2))
    await page.goto(SITE + '/kb/?q=transects')
    await page.getByRole('button', { name: 'publications', exact: true }).click()
    await page.locator('.kb-search').getByRole('link', { name: /Transect survey/ }).filter({ visible: true }).first().waitFor()
    await page.goto(SITE + '/publications/' + id + '/')
    await page.getByText('Second measurement.', { exact: true }).waitFor()
    await page.getByRole('link', { name: 'v1', exact: true }).click()
    await page.getByText('First measurement.', { exact: true }).waitFor()
    assert.equal(page.url(), cited)
    await page.reload()
    await page.getByText('First measurement.', { exact: true }).waitFor()
    assert.deepEqual(errors, [])
  } finally { await close() }
})
