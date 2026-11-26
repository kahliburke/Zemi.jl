// A real canvas drag. A single yellow finding between two blue papers lets us identify its
// position from the rendered pixels, including after the viewport has fitted the documents.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, closeBrowser } from './browser.mjs'

after(closeBrowser)

const nodes = [-0.6, 0, 0.6].map((x, i) => ({
  id: String(i), title: ['Paper A', 'Finding B', 'Paper C'][i], kind: i === 1 ? 'finding' : 'paper',
  page: '/findings', links: 0, x: [x, 0], p: [x, 0, 0],
}))
const fixture = { nodes, links: [], similar: [], clusters: [], job: null, abstracts: false, abstract_only: 0 }
const prepare = page => page.route(url => url.pathname.endsWith('/api/graph'), r => r.fulfill({ json: fixture }))

// Runs in the page. Coordinates are CSS viewport pixels, like Playwright's mouse.
function nodeCenter(rgb = [246, 213, 92]) {
  const canvas = document.querySelector('.kbx-canvas canvas')
  if (!canvas) return null
  const { width, height } = canvas
  const { data } = canvas.getContext('2d').getImageData(0, 0, width, height)
  let x = 0, y = 0, count = 0
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] !== rgb[0] || data[i + 1] !== rgb[1] || data[i + 2] !== rgb[2]) continue
    x += (i / 4) % width
    y += Math.floor(i / 4 / width)
    count++
  }
  if (!count) return null
  const rect = canvas.getBoundingClientRect()
  return { x: rect.left + (x / count + 0.5) * rect.width / width, y: rect.top + (y / count + 0.5) * rect.height / height }
}

test('Explore pins a dragged finding, releases it, restores the semantic map and remembers its forces', async () => {
  const { page, errors, close } = await open('/kb/explore', '.kbx', { prepare })
  try {
    await page.getByRole('tab', { name: 'Forces' }).click()
    const semantic = page.getByRole('button', { name: 'Semantic map', exact: true })
    const free = page.getByRole('button', { name: 'Free physics' })
    assert.equal(await semantic.getAttribute('aria-pressed'), 'true')
    const onDrop = page.getByRole('combobox', { name: 'On drop' })
    await onDrop.selectOption('pin')
    const home = await (await page.waitForFunction(nodeCenter)).jsonValue()
    await free.click()
    assert.equal(await free.getAttribute('aria-pressed'), 'true')
    assert.equal(await page.getByRole('slider').count(), 5)
    const distance = page.getByRole('slider', { name: 'Link distance' })
    await distance.fill('120')
    const release = page.getByRole('button', { name: 'Unpin node' })
    const drag = async (dx, dy) => {
      const start = await page.evaluate(nodeCenter)
      await page.mouse.move(start.x, start.y)
      await page.locator('.kbx-tip').waitFor()
      await page.mouse.down()
      await page.mouse.move(start.x + dx, start.y + dy, { steps: 12 })
      await page.mouse.up()
      await release.waitFor()
    }
    await drag(-95, 75)
    assert.match(await page.locator('.kbx-card h3').innerText(), /Finding B/)
    await release.click()
    assert.equal(await release.count(), 0)
    await drag(60, 45)
    const dropped = await page.evaluate(nodeCenter)
    assert.ok(Math.hypot(dropped.x - home.x, dropped.y - home.y) > 40)
    await page.getByRole('button', { name: 'Return to semantic map' }).click()
    assert.equal(await semantic.getAttribute('aria-pressed'), 'true')
    await page.locator('.kbx-card').getByRole('button', { name: 'Close', exact: true }).click()
    await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))))
    const restored = await page.evaluate(nodeCenter)
    assert.ok(Math.hypot(restored.x - home.x, restored.y - home.y) < 2, JSON.stringify({ home, restored }))
    await free.click()
    assert.equal(await release.count(), 0)
    await page.reload()
    assert.equal(await onDrop.inputValue(), 'pin')
    assert.equal(await semantic.getAttribute('aria-pressed'), 'true')
    await free.click()
    assert.equal(await distance.inputValue(), '120')
    assert.deepEqual(errors, [])
  } finally { await close() }
})

test('a subset and centered document remain navigable when positions follow the links', async () => {
  const set = { spec: 'cluster:1', kind: 'cluster', name: 'Methods', count: 3, least: 3, few: false, trail: [] }
  const { page, errors, close } = await open('/kb/explore?set=cluster:1&center=1', '.kbx', {
    prepare: async page => {
      await page.route(url => url.pathname.endsWith('/api/graph'), r => r.fulfill({ json: {
        ...fixture, nodes: nodes.map(n => ({ ...n, cluster: 1 })), set,
        clusters: [{ id: 1, name: 'Methods', size: 3 }], links: [[0, 1, 'evidence']],
      } }))
      await page.route(url => url.pathname.endsWith('/api/search'), r => r.fulfill({ json: { hits: [{ id: '1', score: 1 }] } }))
    },
  })
  try {
    await page.locator('.kbx-card h3', { hasText: 'Finding B' }).waitFor()
    assert.equal(await page.locator('.kbx-crumb').innerText(), 'Methods')
    await page.getByRole('tab', { name: 'Forces' }).click()
    await page.getByRole('button', { name: 'Free physics' }).click()
    await page.getByRole('tab', { name: 'Legend' }).click()
    await page.getByTitle('Go to Methods').click()
    assert.equal(await page.locator('.kbx-card').count(), 0)
    const search = page.getByPlaceholder(/Search the map/)
    await search.fill('finding')
    await page.getByRole('button', { name: 'Map these' }).waitFor()
    await search.press('Enter')
    await page.locator('.kbx-card h3', { hasText: 'Finding B' }).waitFor()
    assert.equal(new URL(page.url()).searchParams.get('set'), 'cluster:1')
    assert.deepEqual(errors, [])
  } finally { await close() }
})

test('dragging from the semantic map highlights one hop and pulls the neighbour before drop', async () => {
  // A chain at its rest lengths, with no global forces: movement of the record comes from its links.
  const chain = [
    { ...nodes[1], x: [-0.2, 0] },
    { ...nodes[0], kind: 'record', x: [0, 0] },
    { ...nodes[2], x: [0, 0.2] },
  ]
  const { page, errors, close } = await open('/kb/explore', '.kbx', {
    prepare: async page => {
      await page.addInitScript(() => localStorage.setItem('kb-explore-forces',
        JSON.stringify({ centering: 0, repulsion: 0, distance: 140 })))
      await page.route(url => url.pathname.endsWith('/api/graph'), r => r.fulfill({ json: {
        ...fixture, nodes: chain, links: [[0, 1, 'cites'], [1, 2, 'cites']],
      } }))
    },
  })
  try {
    await page.waitForFunction(nodeCenter)
    // Wait for the initial camera fit before measuring movement in screen coordinates.
    await page.waitForTimeout(1100)
    const start = await page.evaluate(nodeCenter)
    const green = [61, 214, 140]
    const before = await page.evaluate(nodeCenter, green)
    await page.mouse.move(start.x, start.y)
    await page.locator('.kbx-tip').waitFor()
    await page.mouse.down()
    await page.mouse.move(start.x - 100, start.y + 45, { steps: 12 })
    await page.locator('.kbx-card h3', { hasText: 'Finding B' }).waitFor()
    const restore = page.getByRole('button', { name: 'Return to semantic map' })
    await restore.waitFor()
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

    const finding = await page.evaluate(nodeCenter)
    const record = await page.evaluate(nodeCenter, green)
    assert.ok(record.x < before.x - 5, JSON.stringify({ before, record }))
    // The second-hop paper fades, while the directly linked record retains its full colour.
    assert.equal(await page.evaluate(nodeCenter, [91, 141, 239]), null)
    const paper = await page.evaluate(nodeCenter, [41, 57, 91])
    assert.ok(paper, 'the second-hop paper is visible in its dimmed colour')
    // Both links are citations. Compare their rendered contrast at their respective midpoints.
    const contrast = await page.evaluate(([finding, record, paper]) => {
      const canvas = document.querySelector('.kbx-canvas canvas')
      const ctx = canvas.getContext('2d'), rect = canvas.getBoundingClientRect()
      function blueAt(a, b) {
        const x = ((a.x + b.x) / 2 - rect.left) * canvas.width / rect.width
        const y = ((a.y + b.y) / 2 - rect.top) * canvas.height / rect.height
        const rgba = ctx.getImageData(Math.round(x) - 4, Math.round(y) - 4, 9, 9).data
        let peak = 0
        for (let i = 0; i < rgba.length; i += 4) peak = Math.max(peak, rgba[i + 2] * rgba[i + 3] / 255)
        return peak
      }
      return [blueAt(finding, record), blueAt(record, paper)]
    }, [finding, record, paper])
    assert.ok(contrast[0] > contrast[1] + 70, JSON.stringify(contrast))
    await page.mouse.up()
    await restore.waitFor({ state: 'hidden' })
    assert.equal(await page.getByRole('button', { name: 'Unpin node' }).count(), 0)
    await page.locator('.kbx-card').getByRole('button', { name: 'Close', exact: true }).click()
    const home = await page.evaluate(nodeCenter, green)
    assert.ok(Math.hypot(home.x - before.x, home.y - before.y) < 2)
    assert.deepEqual(errors, [])
  } finally { await close() }
})

test('return on drop restores the dragged document, its neighbour and the previous layout mode', async () => {
  const { page, errors, close } = await open('/kb/explore', '.kbx', {
    prepare: async page => {
      await page.addInitScript(() => localStorage.setItem('kb-explore-forces',
        JSON.stringify({ repulsion: 0, centering: 0, distance: 140 })))
      await page.route(url => url.pathname.endsWith('/api/graph'), r => r.fulfill({ json: {
        ...fixture, nodes: [nodes[1], { ...nodes[0], kind: 'record', x: [0.2, 0] }, nodes[2], { ...nodes[0], id: '3' }],
        links: [[0, 1, 'cites']],
      } }))
    },
  })
  try {
    await page.getByRole('tab', { name: 'Forces' }).click()
    const onDrop = page.getByRole('combobox', { name: 'On drop' })
    const semantic = page.getByRole('button', { name: 'Semantic map', exact: true })
    const unpin = page.getByRole('button', { name: 'Unpin node' })
    assert.equal(await onDrop.inputValue(), 'return')
    await page.waitForFunction(nodeCenter)
    await page.waitForTimeout(1100) // the initial camera fit
    const green = [61, 214, 140]
    const start = await page.evaluate(nodeCenter)
    const neighbour = await page.evaluate(nodeCenter, green)
    const pull = async (dx, dy) => {
      const at = await page.evaluate(nodeCenter)
      await page.mouse.move(at.x, at.y)
      await page.locator('.kbx-tip').waitFor()
      await page.mouse.down()
      await page.mouse.move(at.x + dx, at.y + dy, { steps: 12 })
    }
    const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y)
    await pull(-85, 55)
    assert.ok(distance(await page.evaluate(nodeCenter, green), neighbour) > 4)
    await page.mouse.up()
    await page.getByRole('button', { name: 'Semantic map', exact: true, pressed: true }).waitFor()
    assert.ok(distance(await page.evaluate(nodeCenter), start) < 2)
    assert.ok(distance(await page.evaluate(nodeCenter, green), neighbour) < 2)
    assert.equal(await unpin.count(), 0)

    await onDrop.selectOption('pin')
    await pull(-65, -45)
    await page.mouse.up()
    await unpin.waitFor()
    const pinned = await page.evaluate(nodeCenter)
    assert.ok(distance(pinned, start) > 40)
    // A temporary drag on an existing pin returns to that pin, even with reduced motion.
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await onDrop.selectOption('return')
    await pull(50, 75)
    await page.mouse.up()
    await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))))
    assert.ok(distance(await page.evaluate(nodeCenter), pinned) < 2)
    assert.equal(await semantic.getAttribute('aria-pressed'), 'false')
    assert.ok(await unpin.isVisible())
    assert.deepEqual(errors, [])
  } finally { await close() }
})
