// The guide's screenshots, each in the light and the dark theme, taken from the demo as `zemi` serves
// it: `node demo/screenshots.mjs [site] [out]`. Without `site`, it serves the demo itself (serve.jl)
// and stops it after. The Docs workflow runs it before building the guide. playwright-core is the
// docs' package.
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import { mkdirSync, existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
const require = createRequire(new URL('../docs/package.json', import.meta.url))
const { chromium } = require('playwright-core')

const REPO = new URL('..', import.meta.url).pathname
const PORT = Number(process.env.ZEMI_PORT || 8020)
const SITE = process.argv[2] ?? `http://127.0.0.1:${PORT}`         // (Node tries IPv6 first for localhost)
const OUT = process.argv[3] ?? new URL('../guide/src/assets/screenshots/', import.meta.url).pathname
mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))

// The demo, served here when no site is given, until its site is built: the service answers 503
// while it builds. Its key is the file the demo keeps in its data (ZEMI_KEY for a site served
// elsewhere).
let server = null
let KEY = process.env.ZEMI_KEY ?? ''
const KEY_FILE = join(process.env.XDG_CACHE_HOME ?? join(homedir(), '.cache'), 'zemi', 'demo', 'serve', 'data', 'local_key')
if (!process.argv[2]) {
  server = spawn('julia', ['--project=app', 'demo/serve.jl'], { cwd: REPO, stdio: ['ignore', 'inherit', 'inherit'],
                                                               env: { ...process.env, ZEMI_PORT: String(PORT) } })
  server.on('exit', code => { if (code) { console.error(`The demo stopped (${code})`); process.exit(1) } })
  const deadline = Date.now() + 30 * 60_000
  for (;;) {
    // Each check with a limit: a request made while the service starts can hang.
    if (!KEY && existsSync(KEY_FILE)) KEY = readFileSync(KEY_FILE, 'utf8').trim()
    let seen = KEY ? '' : 'no key yet'
    try {
      if (KEY) {
        const r = await fetch(SITE + '/', { headers: { Authorization: `Bearer ${KEY}` }, signal: AbortSignal.timeout(15_000) })
        if (r.status === 200) break
        seen = `HTTP ${r.status}`
      }
    } catch (e) { seen = e.cause?.code ?? e.name }
    console.log(`waiting for the demo's site: ${seen}`)
    if (Date.now() > deadline) { server.kill(); throw new Error('The demo did not build its site in 30 minutes') }
    await sleep(5000)
  }
}

// name, page, what to wait for before taking it, anything to do on the page first, and the part of
// the page to take (all of what is in view when none).
const SHOTS = [
  ['front', '/', '.VPHero'],
  ['paper', '/generated/kb/papers/2203-05645', '.kb-paper-head'],
  ['daily', '/generated/kb/daily', '.vp-doc h2'],
  ['landscape', '/generated/kb/landscape', 'svg'],
  ['search', '/generated/kb/', '.kb-hit', async page => {
    await page.fill('.vp-doc input', 'how do larvae settle on ridged surfaces')
    await page.press('.vp-doc input', 'Enter')
  }],
  ['board', '/projects#RB', '.kbp-card'],
  ['finding', '/findings#LS-F1', 'text=Millimetre-scale ridges'],
  ['menu', '/', '.kba-menu', async page => { await page.click('.kba-button') }, { x: 1440 - 480, y: 0, width: 480, height: 300 }],
]

const browser = await chromium.launch().catch(() => chromium.launch({ channel: 'chrome' }))
for (const theme of ['light', 'dark']) {
  // At twice the pixels, so they stay sharp on high-density screens.
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, colorScheme: theme })
  // The key, kept as the browser keeps it after following the address with it.
  if (KEY) { const p = await context.newPage(); await p.goto(`${SITE}/?key=${KEY}`); await p.close() }
  // VitePress keeps the reader's choice in localStorage, over the system's.
  await context.addInitScript(t => localStorage.setItem('vitepress-theme-appearance', t), theme)
  for (const [name, path, ready, act, clip] of SHOTS) {
    const page = await context.newPage()
    // Not 'networkidle': the projects page keeps a connection open for live updates.
    await page.goto(SITE + path, { waitUntil: 'load', timeout: 120_000 })
    if (act) { await page.waitForTimeout(1000); await act(page) }
    await page.waitForSelector(ready, { timeout: 30_000 }).catch(() => console.warn(`${name}: no ${ready}`))
    await page.waitForTimeout(1500)             // charts and fonts settle
    await page.screenshot({ path: `${OUT}/${name}-${theme}.png`, clip })
    await page.close()
    console.log(`${name}-${theme}.png`)
  }
  await context.close()
}
await browser.close()
if (server) { server.removeAllListeners('exit'); server.kill() }
