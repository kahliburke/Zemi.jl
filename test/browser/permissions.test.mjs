// What a person is shown follows what they may do (kbApi's `can`). The test service runs for one
// person, who may do everything; here its /api/status answers for someone signed in with a role.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

const READER = ['read', 'tasks.view']
const CURATOR = ['read', 'tasks.view', 'tutor', 'notebook.create', 'notebook.upload', 'daily', 'paper.add', 'config.view']

// The status as for Bea, signed in with `permissions`.
const signedIn = permissions => async page => page.route(u => new URL(u).pathname === '/api/status', async route => {
  const r = await route.fetch()
  const s = await r.json()
  s.me = { ...s.me, name: 'Bea', email: 'bea@example.org', via: 'session', permissions }
  await route.fulfill({ response: r, json: s })
})

async function paperPage(prepare) {
  const id = (await api('/api/daily')).find(d => d.day === '2026-10-01').id
  return open(`/generated/kb/papers/${id.replace(/[./]/g, '-')}`, 'button.kbfig-mention', { prepare })
}

test('a reader is offered no tutor and no notebooks on a paper, which the person running it is', async () => {
  const mine = await paperPage()
  await mine.page.waitForSelector('.kbc-open')
  assert.ok(await mine.page.locator('.kbn-button:has-text("Attach notebook")').count() === 1)
  await mine.close()
  const { page, errors, close } = await paperPage(signedIn(READER))
  await page.waitForTimeout(1000)                                 // as long as the controls take to show
  assert.equal(await page.locator('.kbc-open').count(), 0)
  assert.equal(await page.locator('.kbn-button').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('signed in, a notebook is attached without asking a name', async () => {
  const { page, errors, close } = await paperPage(signedIn(CURATOR))
  await page.locator('.kbn-button:has-text("Attach notebook")').click()
  await page.waitForSelector('.kbn-button:has-text("Attach")')
  assert.equal(await page.locator('input[placeholder="Your name"]').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('a reader is offered no adding of documents', async () => {
  const mine = await open('/generated/kb/status', '.kbu-drop')
  await mine.close()
  const { page, errors, close } = await open('/generated/kb/status', '.kbu', { prepare: signedIn(READER) })
  await page.waitForSelector('.kbu-dim:has-text("paper.add")')
  assert.equal(await page.locator('.kbu-drop').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('a reader is offered no picking of the paper of the day', async () => {
  const mine = await open('/generated/kb/daily', '.kbd')
  const offered = await mine.page.locator('.kbd-button').count()
  await mine.close()
  const { page, errors, close } = await open('/generated/kb/daily', 'button.kbfig-mention', { prepare: signedIn(READER) })
  await page.waitForTimeout(1000)
  assert.ok(offered > 0)
  assert.equal(await page.locator('.kbd-button').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('the front page asks only whether setup is needed, and then leads to it', async () => {
  const asked = []
  const { page, errors, close } = await open('/', 'body', {
    prepare: page => page.route(u => new URL(u).pathname === '/api/config/setup', route => {
      asked.push(route.request().url())
      return route.fulfill({ json: { needed: true } })
    })
  })
  await page.waitForSelector('.kbsu-prompt a[href*="setup"]')
  assert.ok(asked.length > 0 && asked.every(u => new URL(u).searchParams.has('needed')))
  assert.deepEqual(errors, [])
  await close()
})

test("the models a dataset sets are shown, not offered, on the Configuration page", async () => {
  const { page, errors, close } = await open('/service/configuration', '.kbcf-brand', {
    prepare: page => page.route(u => new URL(u).pathname === '/api/config', async route => {
      const r = await route.fetch()
      const c = await r.json()
      for (const s of c.settings) if (s.key === 'summarizer') s.follows = true
      await route.fulfill({ response: r, json: c })
    })
  })
  assert.ok(await page.locator('select#summarizer').isDisabled())
  assert.ok(!(await page.locator('select#judge').isDisabled()))
  assert.match(await page.locator('.kbcf-row:has(select#summarizer)').innerText(), /Set by the dataset/)
  assert.deepEqual(errors, [])
  await close()
})

test('a refused invitation keeps what was entered', async () => {
  const { page, close } = await open('/service/administration', '.kbad-form', { prepare: signedIn(['read', 'users.manage']) })
  await page.locator('.kbad-form input[type=email]').fill('ada@reef')     // the browser's check passes, the service's does not
  await page.locator('.kbad-form button:text-is("Invite")').click()
  await page.waitForSelector('.kbad-error:has-text("Not an email address")')
  assert.equal(await page.locator('.kbad-form input[type=email]').inputValue(), 'ada@reef')
  await close()
})

test('the site has no link to the package\'s repository', async () => {
  const { page, errors, close } = await open('/', '.VPNavBar')
  assert.equal(await page.locator('.VPNavBar a[href*="github.com"]').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})
