// The board (docs/src/components/KBProjects.vue) on the seeded test service (see serve.jl).
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

// The references on the cards of a column, by its status.
const cards = (page, status) => page.locator(`.kbp-col.${status} .kbp-card .kbp-ref`).allInnerTexts()

test('the columns, with their cards, and nothing failing', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  assert.deepEqual(await cards(page, 'ready'), ['BR-1'])
  assert.deepEqual(await cards(page, 'in_progress'), ['BR-2'])
  assert.deepEqual(await cards(page, 'review'), ['BR-5'])
  assert.ok((await cards(page, 'proposed')).includes('BR-6'))
  assert.deepEqual(errors, [])
  await close()
})

test('a card opens in the panel, its plan rendered', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await page.locator('.kbp-card:has(.kbp-ref:text-is("BR-1"))').click()
  await page.waitForSelector('.kbp-panel .kbp-body')
  assert.equal(await page.locator('.kbp-panel .kbp-body mjx-container').count(), 2)            // inline and displayed math
  assert.equal(await page.locator('.kbp-panel .kbp-body li').count(), 2)
  assert.match(page.url(), /#BR-1$/)
  assert.deepEqual(errors, [])
  await close()
})

test('the address opens a task, and switching projects follows', async () => {
  const { page, errors, close } = await open('/projects#BR-2', '.kbp-panel')
  assert.match(await page.locator('.kbp-panel').innerText(), /Scan the reef crest/)
  await page.getByLabel('Project', { exact: true }).selectOption('OT')
  await page.waitForSelector('.kbp-card:has(.kbp-ref:text-is("OT-1"))')
  assert.match(page.url(), /#OT$/)
  assert.equal(await page.locator('.kbp-card:has(.kbp-ref:text-is("BR-1"))').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('dragging a card to another column moves it', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  // Onto the column below its cards: onto a card would make it that card's subtask.
  const column = page.locator('.kbp-col.in_progress')
  const box = await column.boundingBox()
  await page.locator('.kbp-card:has(.kbp-ref:text-is("BR-1"))').dragTo(column, { targetPosition: { x: box.width / 2, y: box.height - 6 } })
  await page.waitForFunction(() => document.querySelector('.kbp-col.in_progress')?.textContent.includes('BR-1'))
  const moved = await api('/api/tasks/BR-1')
  await api('/api/tasks/BR-1', { status: 'ready', parent: '' })                     // as it was
  assert.equal(moved.status, 'in_progress')
  assert.equal(moved.parent, '')
  assert.deepEqual(errors, [])
  await close()
})

test('dragging a card onto a milestone puts it there, and onto "No milestone" takes it out', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  const card = page.locator('.kbp-card:has(.kbp-ref:text-is("BR-5"))')
  await card.dragTo(page.locator('.kbp-milestones .kbp-ms:has-text("First")'))
  await page.waitForFunction(() => [...document.querySelectorAll('.kbp-card')].some(c => c.textContent.includes('BR-5') && c.textContent.includes('First')))
  const put = await api('/api/tasks/BR-5')
  // "No milestone" shows once the drag has begun, so the drag is made by hand.
  await card.hover()
  await page.mouse.down()
  await page.mouse.move(10, 10, { steps: 5 })
  const none = page.locator('.kbp-ms-none')
  await none.waitFor()
  await none.hover()
  await page.mouse.up()
  await page.waitForFunction(() => ![...document.querySelectorAll('.kbp-card')].some(c => c.textContent.includes('BR-5') && c.textContent.includes('First')))
  const out = await api('/api/tasks/BR-5')
  await api('/api/tasks/BR-5', { milestone: '' })                                  // as it was
  assert.equal(put.milestone, 'First')
  assert.equal(put.status, 'review')
  assert.equal(out.milestone, '')
  assert.deepEqual(errors, [])
  await close()
})

test('what waits on you: plans to approve, work to review, questions to answer', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-waiting')
  const chips = await page.locator('.kbp-waiting .kbp-ms').allInnerTexts()
  for (const w of ['to approve', 'to review', 'to answer']) assert.ok(chips.some(c => c.includes(w)), w)
  await page.locator('.kbp-waiting .kbp-ms:has-text("to answer")').click()
  assert.match(await page.locator('.kbp-waiting-list').innerText(), /Which transect first\?/)
  assert.deepEqual(errors, [])
  await close()
})

test('a milestone narrows the board to its tasks', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await page.locator('.kbp-ms:has-text("First")').first().click()
  await page.waitForFunction(() => !document.body.textContent.includes('Scan the reef crest'))
  assert.deepEqual(await cards(page, 'ready'), ['BR-1'])
  assert.deepEqual(errors, [])
  await close()
})

test('a milestone\'s dates are changed from the board', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await page.locator('.kbp-ms:has-text("First")').first().click()
  await page.getByRole('button', { name: 'Edit', exact: true }).click()
  await page.getByLabel('Starts').fill('2026-11-20')
  await page.getByLabel('Due').fill('2026-12-15')
  await page.getByRole('button', { name: 'Save' }).click()
  await page.waitForFunction(() => document.querySelector('.kbp-ms.on')?.textContent.includes('2026-11-20 – 2026-12-15'))
  assert.equal(await page.locator('.kbp-ms-edit').count(), 0)
  assert.deepEqual(errors, [])
  await close()
})

test('searching finds a task and opens it', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await page.locator('input[placeholder^="Search tasks"]').fill('patches')
  await page.locator('.kbts-panel li[role="option"]').first().click()
  await page.waitForSelector('.kbp-panel')
  assert.match(await page.locator('.kbp-panel').innerText(), /Plot the reef patches/)
  assert.deepEqual(errors, [])
  await close()
})

test('the review dashboard opens', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-card')
  await page.locator('nav[aria-label="The project\'s views"]').getByRole('button', { name: 'Review' }).click()
  await page.waitForSelector('text=start to done')
  assert.deepEqual(errors, [])
  await close()
})

test("a click to the right of a record's title, or of the Records heading, does nothing", async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-records')
  const records = page.locator('details.kbp-records')
  if (!(await records.evaluate(d => d.open))) await page.locator('.kbp-records-head .kbp-waiting-label').click()
  const link = page.locator('.kbp-records-list a', { hasText: 'Reef crest review' })
  await link.waitFor()
  const at = await link.boundingBox(), list = await page.locator('.kbp-records-list').boundingBox()
  assert.ok(at.x + at.width < list.x + list.width - 40, 'the link is as wide as its title')
  const before = page.url()
  await page.mouse.click(list.x + list.width - 10, at.y + at.height / 2)
  const head = await page.locator('.kbp-records-head').boundingBox()
  await page.mouse.click(list.x + list.width - 10, head.y + head.height / 2)
  await page.waitForTimeout(300)
  assert.equal(page.url(), before)
  assert.equal(await records.evaluate(d => d.open), true)
  assert.deepEqual(errors, [])
  await close()
})

test('a question waiting on you opens ready for your reply, and the answer goes under it', async () => {
  const { page, errors, close } = await open('/projects#BR', '.kbp-waiting')
  await page.locator('.kbp-waiting .kbp-ms:has-text("to answer")').click()
  await page.locator('.kbp-waiting-list li:has-text("Which transect first?") .kbp-reflink').click()
  await page.waitForSelector('.kbp-replying')
  assert.match(await page.locator('.kbp-replying').innerText(), /Replying to Claude for Rowan's question/)
  await page.locator('.kbp-comment .cm-content').click()
  await page.keyboard.type('Start at the crest.')
  await page.getByRole('button', { name: 'Answer', exact: true }).click()
  const answer = page.locator('.kbp-activity li.reply.comment', { hasText: 'Start at the crest.' })
  await answer.waitFor()
  assert.match(await answer.innerText(), /answer/)
  assert.match(await page.locator('.kbp-activity li.question', { hasText: 'Which transect first?' }).innerText(), /answered/)
  // A question asked of the agents waits for them, and a comment that is not a reply answers nothing.
  await page.locator('.kbp-comment .cm-content').click()
  await page.keyboard.type('Which tide table?')
  await page.locator('.kbp-ask-to').selectOption('agents')
  await page.getByRole('button', { name: 'Ask', exact: true }).click()
  const asked = page.locator('.kbp-activity li.question', { hasText: 'Which tide table?' })
  await asked.waitFor()
  assert.match(await asked.innerText(), /asked the agents[\s\S]*for the agents/)
  const t = await api('/api/tasks/BR-1')
  const q = t.activity.find(e => e.text === 'Which tide table?')
  assert.deepEqual([q.to_whom, q.state], ['agents', 'open'])
  assert.deepEqual(errors, [])
  await close()
})
