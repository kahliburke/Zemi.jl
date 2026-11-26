import test from 'node:test'
import assert from 'node:assert/strict'
import { shareUrl, shareData, shareText } from '../../docs/src/components/kbShare.ts'

test('a link keeps the current view and note anchor, without login credentials', () => {
  assert.equal(shareUrl('https://user:pass@kb.test/base/projects?q=test&key=secret#KB-4/12'),
    'https://kb.test/base/projects?q=test#KB-4/12')
})

test('link only sends only the URL, including in the clipboard fallback', () => {
  const url = 'https://kb.test/kb/explore?set=cluster%3A3&center=one'
  assert.equal(shareUrl('https://kb.test/kb/manage?state=mine'), 'https://kb.test/kb/manage?state=mine')
  const data = shareData('link', url, 'Title', 'Draft')
  assert.deepEqual(data, { url })
  assert.equal(shareText(data), url)
})

test('text and link uses the reviewed text with its page title and address', () => {
  const url = 'https://kb.test/findings#KB-F1'
  const data = shareData('content', url, 'One finding', 'First paragraph.\n\nSecond paragraph.')
  assert.deepEqual(data, { title: 'One finding', text: 'First paragraph.\n\nSecond paragraph.', url })
  assert.equal(shareText(data), 'One finding\n\nFirst paragraph.\n\nSecond paragraph.\n\n' + url)
})
