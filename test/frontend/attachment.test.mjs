import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readAttachment } from '../../docs/src/components/kbFrontmatter.ts'
import { isMarkdownMedia } from '../../docs/src/components/kbApi.ts'

test('only a Markdown media address is accepted by the reader', () => {
  const h = 'a'.repeat(64)
  assert.equal(isMarkdownMedia(`media/${h}/note.MD`), true)
  for (const address of [`media/${h}/../note.md`, `media/${h}/plot.svg`, 'https://example.org/note.md', 'media/nohash/note.md'])
    assert.equal(isMarkdownMedia(address), false)
})

test('frontmatter metadata, original body and malformed input', () => {
  const file = readAttachment('\uFEFF---\r\ntitle: Reef\r\ndate: 2026-11-26\r\nhuman_reviewed: false\r\nlabels: [a, b]\r\n---\r\n# Details\r\n', 'reef.md')
  assert.deepEqual(file, { title: 'Reef', date: '2026-11-26', metadata: [['human_reviewed', 'false'], ['labels', '["a","b"]']],
                           body: '# Details\r\n', unparsed: '' })
  for (const bad of ['---\ntitle: [\n---\nBody', '---\nTitle\n---\nBody', '---\ntitle: [\nBody', '---\n\nA horizontal rule']) {
    const result = readAttachment(bad, 'reef.md')
    assert.equal(result.title, 'reef.md')
    assert.equal(result.unparsed + result.body, bad)
  }
})
