import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'
after(closeBrowser)

// Fictional bylines; example ORCID iDs from the ORCID format documentation.
const uri = 'https://orcid.org/0000-0002-1694-233X'
const sign = (name, key, orcid = null) => ({ name, key, orcid })
const focal = sign('Avery Lane', 'lane|a', uri), alias = sign('A. Lane', 'lane|a', uri)
const noId = sign('Avery Lane', 'lane|a'), fern = sign('River Fern', 'fern|r')
const papers = [
  ['2601.00001', 'Mapping tidal channels', [focal, fern]],
  ['2601.00002', 'A catalogue of estuary surveys', [alias, fern, sign('Rae West', 'west|r')]],
  ['2601.00003', 'Coastal field methods', [focal, sign('Lin Moss', 'moss|l')]],
  ['2601.00004', 'Notes on salinity', [noId, fern]],
].map(([id, title, names]) => ({ id, title, published: '2024', authors: names.map((a, i) => ({ ...a, position: i + 1 })) }))

test('a legacy author link distinguishes namesakes; an edge opens its evidence and a name recentres the graph', async () => {
  const { page, errors, close } = await open('/kb/authors?a=lane%7Ca', '.kba', {
    prepare: p => p.route(u => u.pathname.endsWith('/api/author-publications'), r => r.fulfill({ json: papers })),
  })
  try {
    await page.getByRole('heading', { name: 'Select an author byline' }).waitFor()
    await page.getByRole('link', { name: 'Avery Lane · ' + uri }).click()
    await page.getByRole('link', { name: 'Explore co-publications' }).click()
    await page.getByRole('button', { name: '2 shared publications with River Fern' }).click()
    const evidence = page.locator('.kba-papers a')
    assert.deepEqual(await evidence.allTextContents(), ['Mapping tidal channels', 'A catalogue of estuary surveys'])
    assert.match(await evidence.first().getAttribute('href'), /kb\/papers\/2601-00001/)
    if (process.env.ZEMI_SHOT) await page.locator('.kba-profile').screenshot({ path: process.env.ZEMI_SHOT })
    await page.locator('.kba-neighbours').getByRole('link', { name: 'River Fern' }).click()
    await page.getByRole('heading', { name: 'River Fern', exact: true }).waitFor()
    await page.goBack()
    await page.getByRole('heading', { name: 'Avery Lane', exact: true }).waitFor()
    assert.match(page.url(), /view=coauthors/)
    await page.getByRole('button', { name: 'All authors' }).click()
    await page.getByRole('searchbox').fill('0000-0002-1694-233X')
    assert.equal(await page.locator('.kba-list li').count(), 1)
    assert.deepEqual(errors, [])
  } finally { await close() }
})

test('a curator can correct a single existing byline and follow its new ORCID profile', async () => {
  let submission
  const { page, errors, close } = await open('/kb/authors?a=name%3AAvery%20Lane', '.kba', {
    prepare: async p => {
      await p.route(u => u.pathname.endsWith('/api/status'), r => r.fulfill({ json: { me: {
        name: 'Curator', via: 'session', permissions: ['read', 'paper.manage'], quotas: {},
      }, layers: [], cannot: {}, keyword: { default: true } } }))
      await p.route(u => u.pathname.endsWith('/api/author-publications'), r => r.fulfill({ json: papers }))
      await p.route(u => u.pathname.endsWith('/api/author-orcid'), r => {
        submission = r.request().postDataJSON()
        return r.fulfill({ json: { orcid: uri } })
      })
    },
  })
  try {
    await page.getByRole('button', { name: 'Edit ORCID' }).click()
    await page.getByRole('textbox', { name: /ORCID for Avery Lane/ }).fill(uri)
    await page.getByRole('button', { name: 'Save', exact: true }).click()
    await page.locator('.kba-profile').getByRole('link', { name: uri }).waitFor()
    assert.equal(await page.locator('.kba-papers li').count(), 4)
    assert.deepEqual(submission, { paper: '2601.00004', position: 1, name: 'Avery Lane', previous: null, orcid: uri })
    assert.deepEqual(errors, [])
  } finally { await close() }
})
