// The guide's screenshots, each in the light and the dark theme, taken from the demo served as a
// group's shared service, signed in as one of its people: `node demo/screenshots.mjs [site] [out]`.
// Without `site`, it serves the demo itself (`serve.jl --shared`) and stops it after. The Docs
// workflow runs it before building the guide. playwright-core is the docs' package.
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import { mkdirSync, existsSync, rmSync } from 'node:fs'
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

// The demo, served here when no site is given, until its site is built: serve.jl leaves a file
// saying so. The shots are taken as Rowan, who signs in on this machine (ZEMI_EMAIL for another).
let server = null
const EMAIL = process.env.ZEMI_EMAIL ?? 'rowan@example.org'
const READY = join(process.env.XDG_CACHE_HOME ?? join(homedir(), '.cache'), 'zemi', 'demo', 'serve', 'ready')
if (!process.argv[2]) {
  rmSync(READY, { force: true })
  server = spawn('julia', ['--project=app', 'demo/serve.jl', '--shared'], { cwd: REPO, stdio: ['ignore', 'inherit', 'inherit'],
                                                                          env: { ...process.env, ZEMI_PORT: String(PORT) } })
  server.on('exit', code => { console.error(`The demo stopped (${code})`); process.exit(1) })
  const deadline = Date.now() + 30 * 60_000
  while (!existsSync(READY)) {
    if (Date.now() > deadline) { server.kill(); throw new Error('The demo did not build its site in 30 minutes') }
    console.log("waiting for the demo's site")
    await sleep(5000)
  }
}

// Drawing with the pen: a loop around what is at `sel`, in the time a hand takes, the shot taken
// before it fades.
async function circle(page, sel) {
  const b = await page.locator(sel).first().boundingBox()
  const cx = b.x + b.width / 2, cy = b.y + b.height / 2, rx = b.width / 2 + 14, ry = b.height / 2 + 12
  await page.mouse.move(cx + rx, cy)
  await page.mouse.down()
  for (let i = 1; i <= 24; i++) {
    const a = i / 24 * 2.15 * Math.PI
    await page.mouse.move(cx + rx * Math.cos(a), cy + ry * Math.sin(a))
    await page.waitForTimeout(12)
  }
  await page.mouse.up()
}

// The page scrolled so what is at `sel` is at the top, below the top bar.
async function scrollTo(page, sel) {
  const b = await page.locator(sel).first().boundingBox()
  await page.evaluate(y => window.scrollBy(0, y), b.y - 90)
}

// Setup at its step `n` (from 0), moved on with Next as a person would, as a new knowledge base shows
// it: without the line saying the demo's is set up already.
async function setupStep(page, n) {
  await page.waitForSelector('.kbsu-steps', { timeout: 30_000 })
  await page.addStyleTag({ content: 'p.kb-dim:has(+ .kbsu-steps) { display: none }' })
  for (let i = 0; i < n; i++) await page.click('.kbsu-button:has-text("Next")', { timeout: 10_000 })
  await page.mouse.move(0, 0)
}

// name, page, what to wait for before taking it, anything to do on the page first, the part of the
// page to take (all of what is in view when none; a selector takes that element whole; a function
// gives the part), and how long to let it settle (1.5 s when not given).
const SHOTS = [
  ['front', '/', '.VPHero'],
  ['paper', '/kb/papers/2203-05645', '.kb-paper-head'],
  ['daily', '/kb/daily', '.vp-doc h2'],
  ['landscape', '/kb/landscape', 'svg'],
  ['search', '/kb/', '.kb-hit', async page => {
    await page.fill('.vp-doc input', 'how do larvae settle on ridged surfaces')
    await page.press('.vp-doc input', 'Enter')
  }],
  ['board', '/projects#RB', '.kbp-face'],
  ['task', '/projects#RB-6', '.kbd-body'],
  ['proposal', '/projects#RB-15', 'text=Waiting for approval'],
  ['library', '/projects#RB', '.kbl-box', async page => { await page.click('.kbp-view:has-text("Library")'); await page.mouse.move(0, 0) }],
  // Following Ada, who is planning with a task open and writing on it, and pointing something out with the pen.
  ['planning', '/projects#RB', '.kbp-session', async page => {
    await page.click('.kbp-people-button')
    await page.click('.kbp-person:has-text("Ada") button:has-text("Follow")')
    await page.waitForSelector('.kbp-session', { timeout: 15_000 })
    await page.waitForTimeout(2500)                       // her task opened and scrolled to
    await page.keyboard.press('p')
    await circle(page, '.kbd [data-control="status"]')
  }, undefined, 0],
  ['review', '/projects#RB', '.kbr-charts', async page => { await page.click('.kbp-view:has-text("Review")'); await page.mouse.move(0, 0) }],
  ['finding', '/findings#LS-F1', 'text=Millimetre-scale ridges'],
  ['admin', '/service/administration', '.kbad-chip'],
  ['menu', '/', '.kba-menu', async page => { await page.click('.kba-button') }, { x: 1440 - 480, y: 0, width: 480, height: 300 }],
  // What a group's first admin goes through: signing in (the providers' buttons, without the form for
  // signing in on this machine), Setup's four steps, and inviting the others.
  ['sign-in', '/auth/sign-in', 'h1', page => page.addStyleTag({ content: 'form.l { display: none }' }), 'main'],
  ['setup', '/service/setup', '.kbsu-steps', page => setupStep(page, 0)],
  ['setup-arxiv', '/service/setup', '.kbsu-steps', page => setupStep(page, 1)],
  ['setup-model', '/service/setup', '.kbsu-steps', page => setupStep(page, 2)],
  ['setup-sharing', '/service/setup', '.kbsu-steps', page => setupStep(page, 3)],
  ['invite', '/service/administration', '.kbad-chip', async page => {
    const form = page.locator('h3:text-is("Invite someone") + form')
    await form.locator('input[type=email]').fill('una@example.org')
    await form.locator('.kbad-chip:has-text("Curator")').click()
    await scrollTo(page, 'h3:text-is("Invite someone")')
    await page.mouse.move(0, 0)
  }, async page => {
    const h = await page.locator('h3:text-is("Invite someone")').boundingBox()
    const f = await page.locator('h3:text-is("Invite someone") + form').boundingBox()
    return { x: f.x - 16, y: h.y - 12, width: f.width + 32, height: f.y + f.height - h.y + 28 }
  }],
  // The service's own pages, where a group sets itself up.
  ['configuration', '/service/configuration', '.kbcf h2'],
  ['configuration-group', '/service/configuration', '.kbcf h2', page => scrollTo(page, '.kbcf h2:text-is("The group")')],
  ['models', '/service/configuration', '#model input', page => scrollTo(page, '#model h2')],
  ['operations', '/service/operations', 'text=Jobs', undefined, 'h2:text-is("Jobs") + table'],
  // A project's library with its Zotero group; Rowan's library on its page and on the Documents page.
  ['zotero', '/projects#RB', '.kbz', async page => { await page.click('.kbp-view:has-text("Library")'); await page.mouse.move(0, 0) },
   async page => { const b = await page.locator('.kbl-box').boundingBox(); return { ...b, height: 420 } }],
  ['library-account', '/service/library', '.kbl-table',
   page => page.locator('.kbl-missing').first().evaluate(d => { d.open = true }), 'section.kbl'],
  ['documents-sharing', '/kb/manage?state=mine', '.kbm-intro', async page => {
    await page.waitForSelector('.kbm input[type=checkbox]', { timeout: 30_000 })
    await page.locator('.kbm tbody tr:has-text("Scoring turf") input[type=checkbox]').check()
    await page.addStyleTag({ content: '.kbj { display: none }' })        // the service's jobs, not the library's
    await scrollTo(page, 'h2:has-text("Find and manage")')
    await page.mouse.move(0, 0)
  }],
  // The palette, finding the knowledge base's things as one types.
  ['palette', '/projects#RB', '.kbpal-item', async page => {
    await page.waitForSelector('.kbp-card')
    await page.keyboard.press('ControlOrMeta+k')
    await page.locator('.kbpal-input').fill('recover')
    await page.waitForSelector('.kbpal-group:has-text("In the knowledge base")')
  }],
]
// ZEMI_SHOTS=setup,palette takes those alone.
const ONLY = process.env.ZEMI_SHOTS ? new Set(process.env.ZEMI_SHOTS.split(',')) : null

// What a page saw, for a shot that went wrong: its top bar, who the service says is asking, and the
// browser's errors.
async function explain(page, errors) {
  console.warn(`  the top bar: ${(await page.locator('.VPNavBar').innerText().catch(() => '')).replace(/\s+/g, ' ')}`)
  console.warn(`  /api/status: ${await page.evaluate(async () => { try { const r = await fetch('/api/status'); return `${r.status} ${(await r.text()).slice(0, 300)}` } catch (e) { return String(e) } })}`)
  errors.forEach(x => console.warn(`  browser: ${x}`))
}

const browser = await chromium.launch().catch(() => chromium.launch({ channel: 'chrome' }))
for (const theme of ['light', 'dark']) {
  // At twice the pixels, so they stay sharp on high-density screens.
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, colorScheme: theme })
  // Signed in, as the browser stays after the sign-in page.
  const p = await context.newPage()
  await p.goto(`${SITE}/auth/sign-in?return_to=/`)
  await p.fill('form.l input[name=email]', EMAIL)
  await p.click('form.l button')
  await p.waitForLoadState('load')
  await p.close()
  // VitePress keeps the reader's choice in localStorage, over the system's.
  await context.addInitScript(t => localStorage.setItem('vitepress-theme-appearance', t), theme)
  for (const [name, path, ready, act, clip, settle = 1500] of SHOTS) {
    if (ONLY && !ONLY.has(name)) continue
    const page = await context.newPage()
    const errors = []
    page.on('console', m => { if (m.type() === 'error') errors.push(m.text()) })
    page.on('pageerror', e => errors.push(String(e)))
    // Not 'networkidle': the projects page keeps a connection open for live updates.
    await page.goto(SITE + path, { waitUntil: 'load', timeout: 120_000 })
    // A shot whose step fails is left out, with what the page showed, rather than ending the run.
    if (act) {
      await page.waitForTimeout(1000)
      try { await act(page) } catch (e) {
        console.warn(`${name}-${theme}: left out (${e.message.split('\n')[0]})`)
        await explain(page, errors)
        await page.close()
        continue
      }
    }
    await page.waitForSelector(ready, { timeout: 30_000 }).catch(async () => { console.warn(`${name}: no ${ready}`); await explain(page, errors) })
    await page.waitForTimeout(settle)           // charts and fonts settle
    const path_ = `${OUT}/${name}-${theme}.png`
    await (typeof clip === 'string' ? page.locator(clip).first().screenshot({ path: path_ })
           : page.screenshot({ path: path_, clip: typeof clip === 'function' ? await clip(page) : clip }))
    await page.close()
    console.log(`${name}-${theme}.png`)
  }
  await context.close()
}
await browser.close()
if (server) { server.removeAllListeners('exit'); server.kill() }
process.exit(0)
