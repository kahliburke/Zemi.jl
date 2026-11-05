// The Markdown editor (KBEditor.vue), attachments and rendering, on the seeded test service.
import { test, after } from 'node:test'
import assert from 'node:assert/strict'
import { open, api, closeBrowser } from './browser.mjs'

after(closeBrowser)

// The comment editor of task `ref`'s panel, focused.
async function commentEditor(ref) {
  const opened = await open(`/projects#${ref}`, '.kbp-comment .cm-content')
  await opened.page.locator('.kbp-comment .cm-content').click()
  return opened
}

test('references are offered after @, and written as references', async () => {
  const { page, errors, close } = await commentEditor('BR-2')
  await page.keyboard.type('See @patches')
  // The tasks are offered first and the papers after them, and the list is drawn again then;
  // CodeMirror takes no Enter for a moment after it is drawn, so one meant for it is not misread.
  await page.waitForSelector('.cm-tooltip-autocomplete li:has-text("PAPER")')
  await page.waitForTimeout(250)
  assert.match(await page.locator('.cm-tooltip-autocomplete li').first().innerText(), /Plot the reef patches/)
  await page.keyboard.press('Enter')
  assert.match(await page.locator('.kbp-comment .cm-content').innerText(), /See @BR-6 /)
  assert.deepEqual(errors, [])
  await close()
})

test('Escape closes the completions, not the panel', async () => {
  const { page, errors, close } = await commentEditor('BR-2')
  await page.keyboard.type('@Scan')
  await page.waitForSelector('.cm-tooltip-autocomplete')
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.cm-tooltip-autocomplete').count(), 0)
  assert.equal(await page.locator('.kbp-panel').count(), 1)
  assert.deepEqual(errors, [])
  await close()
})

test('the split view shows the text rendered, mathematics included', async () => {
  const { page, errors, close } = await commentEditor('BR-2')
  await page.keyboard.type('Energy $E = mc^2$ and **bold**')
  await page.locator('.kbp-comment .kbe-views button:text-is("split")').click()
  await page.waitForSelector('.kbp-comment .kbe-preview mjx-container')
  assert.equal(await page.locator('.kbp-comment .kbe-preview strong').innerText(), 'bold')
  await page.locator('.kbp-comment .kbe-views button:text-is("write")').click()          // as it was
  assert.deepEqual(errors, [])
  await close()
})

test('the buttons sit under the editor', async () => {
  const { page, errors, close } = await commentEditor('BR-2')
  const editor = await page.locator('.kbp-comment .kbe').boundingBox()
  const actions = await page.locator('.kbp-comment .kbp-comment-actions').boundingBox()
  assert.ok(actions.y - (editor.y + editor.height) < 30, `a gap of ${actions.y - (editor.y + editor.height)} px`)
  assert.deepEqual(errors, [])
  await close()
})

test('a pasted image is attached, and ⌘-Enter sends the comment with it', async () => {
  const { page, errors, close } = await commentEditor('BR-2')
  await page.keyboard.type('The plot: ')
  // A one-pixel PNG, pasted as a screenshot is.
  await page.evaluate(() => {
    const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='), c => c.charCodeAt(0))
    const data = new DataTransfer()
    data.items.add(new File([png], 'image.png', { type: 'image/png' }))
    document.querySelector('.kbp-comment .cm-content').dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))
  })
  await page.waitForFunction(() => /!\[screenshot-[^\]]+\]\(media\//.test(document.querySelector('.kbp-comment .cm-content').textContent))
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+Enter' : 'Control+Enter')
  await page.waitForSelector('.kbp-panel .kbp-note img')
  const notes = (await api('/api/tasks/BR-2')).activity.filter(e => e.kind === 'comment')
  assert.match(notes.at(-1).text, /The plot: \n?!\[screenshot-.*\]\(media\/[0-9a-f]{64}\/screenshot-.*\.png\)/)
  assert.deepEqual(errors, [])
  await close()
})

test('a draft comes back after a reload, and goes once cleared', async () => {
  const { page, errors, close } = await commentEditor('BR-1')
  await page.keyboard.type('Half a thought')
  await page.reload({ waitUntil: 'load' })
  await page.waitForSelector('.kbp-comment .cm-content')
  await page.waitForFunction(() => document.querySelector('.kbp-comment .cm-content').textContent.includes('Half a thought'))
  await page.locator('.kbp-comment .cm-content').click()
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+a' : 'Control+a')
  await page.keyboard.press('Backspace')
  assert.deepEqual(await page.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('kb-draft:'))), [])
  assert.deepEqual(errors, [])
  await close()
})
