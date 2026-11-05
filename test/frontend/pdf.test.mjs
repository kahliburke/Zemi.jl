// Where a paper's PDF opens at a page: the service's copy, or arXiv's on a copy of the site without one.
import { test } from 'node:test'
import assert from 'node:assert/strict'
const { servicePdf, arxivPdf } = await import('../../docs/src/components/kbPdf.ts')

test("the service's PDF, at the page", () => {
  assert.equal(servicePdf('', '2609.00002', 4), '/api/pdf/2609.00002#page=4')
  assert.equal(servicePdf('http://127.0.0.1:8701', 'doc-0123456789'), 'http://127.0.0.1:8701/api/pdf/doc-0123456789')
  assert.equal(servicePdf('', 'q-bio/0501001', 1), '/api/pdf/q-bio%2F0501001')         // the first page needs no fragment
})

test("arXiv's PDF of the version read, at the page", () => {
  assert.equal(arxivPdf('2609.00002', 'v2', 7), 'https://arxiv.org/pdf/2609.00002v2#page=7')
  assert.equal(arxivPdf('2609.00002', '', null), 'https://arxiv.org/pdf/2609.00002')
  assert.equal(arxivPdf('q-bio/0501001', 'v1', 2), 'https://arxiv.org/pdf/q-bio/0501001v1#page=2')
})
