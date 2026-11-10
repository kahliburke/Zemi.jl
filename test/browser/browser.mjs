// What the browser tests share: a browser on the test service (see serve.jl), each page's errors
// collected, and the service's API. The site's address comes from ZEMI_TEST_SITE (run.jl sets
// it); playwright-core is the docs' package.
import { createRequire } from 'node:module'
const require = createRequire(new URL('../../docs/package.json', import.meta.url))
const { chromium } = require('playwright-core')

export const SITE = process.env.ZEMI_TEST_SITE ?? 'http://localhost:5181'
export const API = process.env.ZEMI_TEST_API ?? 'http://127.0.0.1:8701'
// The test service's key (see src/local_key.jl), which each browser is given as `zemi open` would.
const KEY = process.env.ZEMI_TEST_KEY ?? ''
const KEY_COOKIE = `zemi_key_${new URL(API).port}`

async function newContext(options = {}) {
  const context = await (await launch()).newContext(options)
  await context.addCookies([{ name: KEY_COOKIE, value: KEY, url: SITE }])
  return context
}

let browser
let warmed                // the development server compiles the site on its first page, which takes minutes
export async function launch() {
  // Playwright's own Chromium, or the installed Chrome where that one isn't downloaded for this version.
  browser ??= await chromium.launch().catch(() => chromium.launch({ channel: 'chrome' }))
  return browser
}
export async function closeBrowser() { await browser?.close(); browser = undefined }

// The site's first page, until `ready` shows: the development server optimizes the site's
// dependencies as it first serves them, and a browser that loaded the page before that keeps the
// modules it cached, so each try is a fresh one.
async function warmUp(path, ready) {
  for (let i = 0; i < 6; i++) {
    const context = await newContext()
    try {
      const page = await context.newPage()
      await page.goto(SITE + path, { waitUntil: 'load', timeout: 300_000 })
      await page.waitForSelector(ready ?? 'body', { timeout: 60_000 })
      return
    } catch { /* not yet */ } finally { await context.close() }
  }
  throw new Error(`The site did not show ${ready} at ${path}`)
}

// A page at `path` on the site, waiting for `ready` (a selector), with the errors it reports:
// uncaught exceptions and console errors. `prepare(page)` runs before it loads (to route requests, say).
// With `touch`, the browser is a phone's or a tablet's: a touch screen, laid out as a mobile one.
export async function open(path, ready, { width = 1500, height = 950, prepare, touch = false } = {}) {
  warmed ??= warmUp(path, ready)
  await warmed
  const context = await newContext({ viewport: { width, height }, colorScheme: 'dark', isMobile: touch, hasTouch: touch })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', e => errors.push(String(e)))
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()) })
  if (prepare) await prepare(page)
  await page.goto(SITE + path, { waitUntil: 'load', timeout: 60_000 })
  if (ready) await page.waitForSelector(ready, { timeout: 60_000 })
  return { page, errors, close: () => context.close() }
}

// The API, as the site's pages call it.
export async function api(path, body) {
  const auth = { Authorization: `Bearer ${KEY}` }
  const r = await fetch(API + path, body === undefined ? { headers: auth } :
    { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'X-Zemi': '1' }, body: JSON.stringify(body) })
  const data = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(`${path}: ${r.status} ${data.error ?? ''}`)
  return data
}
