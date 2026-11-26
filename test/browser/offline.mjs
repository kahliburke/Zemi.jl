// Exercise the published files under their Pages prefix, including a cold navigation with the
// HTTP cache cleared and the server disconnected. Run with node test/browser/offline.mjs _site/demo.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { extname, resolve, sep } from 'node:path'
import { once } from 'node:events'

const { chromium } = createRequire(new URL('../../docs/package.json', import.meta.url))('playwright-core')
const dir = resolve(process.argv[2])
const base = '/Zemi.jl/demo/'
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
  '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' }
let disconnected = false
let forbidden = ''
const server = createServer(async (req, res) => {
  if (disconnected) return req.socket.destroy()
  const path = new URL(req.url, 'http://localhost').pathname
  if (path === forbidden) return res.writeHead(403).end('Access denied')
  const file = resolve(dir, './' + decodeURIComponent(path.slice(base.length)) + (path.endsWith('/') ? 'index.html' : ''))
  if (!path.startsWith(base) || !file.startsWith(dir + sep)) return res.writeHead(404).end()
  try {
    const bytes = await readFile(file)
    res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream' }).end(bytes)
  } catch { res.writeHead(404).end() }
})

server.listen(0, '127.0.0.1')
await once(server, 'listening')
const url = `http://127.0.0.1:${server.address().port}${base}`
let browser
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE })
  const context = await browser.newContext({ locale: 'en-US' })
  await context.addInitScript(() => {
    window.notificationRequests = 0
    Notification.requestPermission = async () => { window.notificationRequests++; return 'denied' }
  })
  let page = await context.newPage()
  await page.goto(url)
  await page.getByRole('button', { name: 'Install Zemi' }).waitFor()
  assert.equal(await page.locator('link[rel=manifest]').evaluate(link => link.href), url + 'manifest.webmanifest')
  const manifest = await (await context.request.get(url + 'manifest.webmanifest')).json()
  assert.equal(new URL(manifest.start_url, url).href, url)
  for (const n of [192, 512]) {
    const icon = manifest.icons.find(icon => icon.sizes === `${n}x${n}`)
    const png = await (await context.request.get(new URL(icon.src, url).href)).body()
    assert.equal(png.readUInt32BE(16), n)
    assert.equal(png.readUInt32BE(20), n)
  }
  await page.waitForFunction(() => navigator.serviceWorker.controller, undefined, { timeout: 60000 })
  assert.equal(await page.evaluate(async () => (await navigator.serviceWorker.ready).scope), url)
  assert.equal(await page.evaluate(() => window.notificationRequests), 0)
  const cdp = await context.newCDPSession(page)
  assert.deepEqual((await cdp.send('Page.getInstallabilityErrors')).installabilityErrors, [])
  const [paper] = await (await context.request.get(url + 'papers.json')).json()
  const article = url + 'generated/kb/papers/' + paper.slug + '.html'
  await page.goto(article)
  await page.locator('#paper-title').waitFor()
  const title = await page.locator('#paper-title').innerText()
  const summary = await page.locator('.kbpp .tip.custom-block > div').first().innerText()
  assert.ok(summary.trim())

  forbidden = new URL(article).pathname
  assert.equal((await page.goto(article)).status(), 403)
  forbidden = ''
  await cdp.send('Network.clearBrowserCache')
  await page.close()
  disconnected = true
  await context.setOffline(true)
  page = await context.newPage()
  await page.goto(url)
  await page.getByRole('link', { name: 'Search the knowledge base', exact: true }).click()
  const search = page.locator('.kb-search input')
  await search.waitFor()
  await page.waitForFunction(() => /\([1-9]\d* papers\)/.test(document.querySelector('.kb-note')?.textContent || ''))
  await search.fill(paper.id)
  await page.locator('.kb-hits a.kb-title').first().click()
  await page.locator('#paper-title').waitFor()
  assert.equal(await page.locator('#paper-title').innerText(), title)
  await page.reload()
  await page.locator('#paper-title').waitFor()
  assert.equal(await page.locator('#paper-title').innerText(), title)
  assert.equal(await page.locator('.kbpp .tip.custom-block > div').first().innerText(), summary)
  assert.equal((await page.goto(url + 'never-published.html')).status(), 503)
  assert.equal(await page.locator('h1').innerText(), 'You’re offline')
  console.log('Offline launch, keyword search, article navigation and reload passed.')
} finally {
  await browser?.close()
  server.close()
}
