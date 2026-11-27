// The explore page (docs/src/components/KBExplore.vue), drawn from a graph served here: the card of the
// selected document, the panel of its legend and settings, a cluster mapped by itself, and switching
// between the map and the space.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const LONG = 'A long summary of the paper. '.repeat(40)
const doc = (i, cluster, more = {}) => {
  const a = (i * 2.399) % (2 * Math.PI), r = 0.2 + (i % 5) / 10 + cluster / 3
  const at = [r * Math.cos(a), r * Math.sin(a)], deep = [...at, ((i % 7) - 3) / 10]
  return { id: `2609.000${String(i).padStart(2, '0')}`, kind: 'paper', title: `Paper ${i} on ${cluster === 1 ? 'reefs' : 'tides'}`,
           year: '2025', page: `/kb/papers/p${i}`, links: i % 3, access: 'open', mine: false, read: true, cluster,
           central: 0.5 + (i % 4) / 10, x: at, p: deep, ux: at, up: deep, px: at, pp: deep, ...more }
}
const nodes = [...Array(24).keys()].map(i => doc(i, i < 12 ? 1 : 2))
nodes.push({ ...doc(24, 1), id: 'rec-reef-notes', kind: 'record', title: 'Reef notes' })
const graph = (set = undefined) => ({
  nodes: set ? nodes.filter(n => n.cluster === 1).map(n => ({ ...n, cluster: n.id < '2609.00006' ? 1 : 2 })) : nodes,
  links: [[0, 1, 'cites']], similar: [[0, 2, 0.9, false, false], [1, 3, 0.8, false, false]],
  clusters: set ? [{ id: 1, name: 'Reef surveys', description: '', size: 6 }, { id: 2, name: 'Reef models', description: '', size: 7 }]
               : [{ id: 1, name: 'Reefs', description: '', size: 13 }, { id: 2, name: 'Tides', description: '', size: 12 }],
  built_at: 'now', job: null, abstracts: false, abstract_only: 0, least: set ? 6 : 13,     // Tides, 12, too few to map
  ...(set ? { set: { spec: set, kind: 'cluster', name: 'Reefs', count: 13, least: 20, few: false, trail: [] } } : {}) })
const detail = id => ({ id, title: id, authors: ['Ada Lovelace'], published: '2025-01-01', venue: '', topics: ['reefs'], read: true,
  abstract: '', page: '', summary: id === 'rec-reef-notes' ? '' : LONG,
  excerpt: id === 'rec-reef-notes' ? 'Counted at low tide.\n\nTwo transects.' : '' })
const serving = page => Promise.all([
  page.route(u => new URL(u).pathname.endsWith('/api/graph'), r => r.fulfill({ json: graph(new URL(r.request().url()).searchParams.get('set') ?? undefined) })),
  page.route(u => new URL(u).pathname.endsWith('/api/graph/node'), r => r.fulfill({ json: detail(new URL(r.request().url()).searchParams.get('id')) })),
])
const card = page => page.locator('.kbx-card')

test('a document is shown on its card, and stays selected from the map to the space and back', async () => {
  const { page, errors, close } = await open('/kb/explore?center=2609.00003', '.kbx-bar', { prepare: serving })
  await card(page).locator('h3').waitFor()
  assert.equal(await card(page).locator('h3').innerText(), 'Paper 3 on reefs')
  // A long summary is cut short and faded, with More to read it all.
  await page.locator('.kbc-box.clipped').waitFor()
  assert.equal(await page.locator('.kbc-more').count(), 1)
  // The card's actions, as icons named for what they do.
  for (const name of ['Open its page', 'Copy its citation', 'Copy a link to this view'])
    assert.equal(await card(page).getByRole('button', { name }).or(card(page).getByRole('link', { name })).count(), 1, name)
  await page.getByRole('button', { name: 'Space', exact: true }).click()
  await page.waitForTimeout(1500)
  assert.equal(await card(page).locator('h3').innerText(), 'Paper 3 on reefs')
  await page.getByRole('button', { name: 'Map', exact: true }).click()
  await page.waitForTimeout(1000)
  assert.equal(await card(page).locator('h3').innerText(), 'Paper 3 on reefs')
  assert.deepEqual(errors, [])
  await close()
})

test("a short note is shown whole, from the note itself", async () => {
  const { page, errors, close } = await open('/kb/explore?center=rec-reef-notes', '.kbx-bar', { prepare: serving })
  await card(page).locator('h3').waitFor()
  await page.locator('.kbc-box').waitFor()
  assert.match(await page.locator('.kbc-head').innerText(), /from the note/i)
  assert.match(await page.locator('.kbc-text').innerText(), /Two transects/)
  assert.equal(await page.locator('.kbc-more').count(), 0)
  assert.equal(await page.locator('.kbc-box.clipped').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('the panel shows the legend or the settings, and a cluster is mapped by itself', async () => {
  const { page, errors, close } = await open('/kb/explore', '.kbx-bar', { prepare: serving })
  const settings = page.getByRole('button', { name: "The map's legend and settings" })
  if (!(await page.locator('.kbx-panel').count())) await settings.click()
  await page.getByRole('tab', { name: 'Legend' }).click()
  assert.match(await page.locator('.kbx-panel').innerText(), /Reefs[\s\S]*Tides/)
  await page.getByRole('tab', { name: 'Settings' }).click()
  assert.match(await page.locator('.kbx-panel').innerText(), /Layout[\s\S]*Links[\s\S]*Documents/)
  await page.getByRole('tab', { name: 'Legend' }).click()
  // A cluster with too few documents for a map of its own: its lens greyed, saying why, and doing nothing.
  const tides = page.getByRole('button', { name: 'Map Tides by itself' })
  assert.equal(await tides.getAttribute('aria-disabled'), 'true')
  assert.match(await tides.getAttribute('data-tip'), /Too few to map by itself: 12 documents.*at least 13/)
  await tides.click({ force: true })
  await page.waitForTimeout(300)
  assert.equal(new URL(page.url()).searchParams.get('set'), null)
  // Mapped by itself: named in the address, with a way back to all documents.
  await page.getByRole('button', { name: 'Map Reefs by itself' }).click()
  await page.locator('.kbx-crumbs', { hasText: '13' }).waitFor()
  assert.match(await page.locator('.kbx-crumbs').innerText(), /All documents[\s\S]*Reefs[\s\S]*13/)
  assert.equal(new URL(page.url()).searchParams.get('set'), 'cluster:1')
  await page.locator('.kbx-panel', { hasText: 'Reef surveys' }).waitFor()
  assert.match(await page.locator('.kbx-panel').innerText(), /Reef models/)
  // A level further in, from the subset's own legend.
  await page.getByRole('button', { name: 'Map Reef surveys by itself' }).click()
  await page.waitForFunction(() => new URL(location.href).searchParams.get('set') === 'cluster:1@cluster:1')
  await page.getByRole('link', { name: 'All documents' }).click()
  await page.waitForFunction(() => !new URL(location.href).searchParams.get('set'))
  assert.equal(await page.locator('.kbx-crumbs').count(), 0)
  // The whole map back in view.
  await page.getByRole('button', { name: 'Show the whole map' }).click()
  assert.deepEqual(errors, [])
  await close()
})

test("a search's best matches are listed until one is picked", async () => {
  const searching = page => Promise.all([serving(page), page.route(u => new URL(u).pathname.endsWith('/api/search'),
    r => r.fulfill({ json: { hits: [5, 2, 9].map((i, k) => ({ id: nodes[i].id, score: 1 - k / 10 })) } }))])
  const { page, errors, close } = await open('/kb/explore', '.kbx-bar', { prepare: searching })
  await page.getByPlaceholder(/Search the map/).fill('reefs')
  const hits = page.getByRole('complementary', { name: 'Search results' })
  await hits.waitFor()
  assert.deepEqual(await hits.locator('li a').allInnerTexts(), ['Paper 5 on reefs', 'Paper 2 on reefs', 'Paper 9 on reefs'])
  await hits.getByRole('link', { name: 'Paper 2 on reefs' }).click()
  await page.locator('.kbx-card h3').filter({ hasText: 'Paper 2 on reefs' }).waitFor()
  assert.equal(await hits.count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('a new search sets down the selected document and shows its matches', async () => {
  const searching = page => Promise.all([serving(page), page.route(u => new URL(u).pathname.endsWith('/api/search'),
    r => r.fulfill({ json: { hits: [14, 15].map((i, k) => ({ id: nodes[i].id, score: 1 - k / 10 })) } }))])
  const { page, errors, close } = await open('/kb/explore?center=2609.00003', '.kbx-bar', { prepare: searching })
  await card(page).locator('h3').waitFor()
  await page.getByPlaceholder(/Search the map/).fill('tides')
  await page.getByRole('complementary', { name: 'Search results' }).waitFor()
  assert.equal(await page.locator('.kbx-card h3').count(), 0)
  // Moves given one after another carry on from each other.
  await page.getByRole('link', { name: 'Paper 14 on tides' }).click()
  await page.getByRole('button', { name: 'Show the whole map' }).click()
  await page.waitForTimeout(1500)
  assert.deepEqual(errors, [])
  await close()
})
