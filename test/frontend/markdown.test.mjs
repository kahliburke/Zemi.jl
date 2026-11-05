// The renderer the site's pages share (docs/src/components/kbMarkdown.ts): run with
// `node --import ./test/frontend/register.mjs --test test/frontend/`, or from the Julia tests.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadMarkdown } from '../../docs/src/components/kbMarkdown.ts'

const md = await loadMarkdown()

test('mathematics, inline and displayed', () => {
  const html = md('Energy $E = mc^2$ and\n\n$$\\int_0^1 x\\,dx$$')
  assert.equal((html.match(/<mjx-container/g) ?? []).length, 2)
  assert.match(html, /display="true"/)
  const fenced = md('Its field:\n\n```math\n\\mathbf B = \\nabla\\times\\mathbf A\n```\n\n- a list\n\n  ```math\n  x^2\n  ```')
  assert.equal((fenced.match(/<mjx-container[^>]*display="true"/g) ?? []).length, 2)
  assert.doesNotMatch(fenced, /<code/)
})

test('a formula right against a number, as abstracts write it, and money left as money', () => {
  const abstract = 'reef survey sites ($\\sim$23k), positions on the reef, and depth profiles. ' +
                   'Due to its speed ($\\sim$ms), the surrogate enables it.'
  const html = md(abstract)
  assert.equal((html.match(/<mjx-container/g) ?? []).length, 2)
  assert.match(html, /23k\), positions on the reef/)                 // the words between stay words
  assert.equal((md('It cost $5 and $6 later.').match(/<mjx-container/g) ?? []).length, 0)
  assert.match(md('`$\\sim$1`'), /<code>\$\\sim\$1<\/code>/)              // code as written
})

test('code highlighted in both themes, by name or alias', () => {
  for (const lang of ['julia', 'jl', 'python', 'fortran']) {
    const html = md('```' + lang + '\nx = 1\n```')
    assert.match(html, /<pre class="shiki shiki-themes github-light github-dark/, lang)
    assert.match(html, /--shiki-dark:/, lang)
  }
  assert.match(md('```nonsense\nx\n```'), /<pre><code class="language-nonsense">x/)   // shown, not highlighted
})

test('tables, footnotes and links', () => {
  assert.match(md('| a | b |\n|---|---|\n| 1 | 2 |'), /<table>/)
  const notes = md('A claim[^1].\n\n[^1]: Its source.')
  assert.match(notes, /data-note="fn-t\d+-1"/)
  assert.doesNotMatch(notes, /href="#fn/)                                                  // the page's address is the page's
  assert.match(md('See https://arxiv.org'), /<a href="https:\/\/arxiv.org" target="_blank" rel="noopener">/)
})

test('HTML in text is shown as text', () => {
  const html = md('<b>bold</b> <script>alert(1)</script> <img src=x onerror=alert(1)>')
  assert.doesNotMatch(html, /<b>|<script|<img/)
  assert.match(html, /&lt;script&gt;/)
  assert.doesNotMatch(md('[x](javascript:alert(1))'), /href="javascript:/)
})

test('a formula cannot link anywhere or style the page', () => {
  const html = md('$\\href{javascript:alert(1)}{x}$ $\\href{https://arxiv.org}{y}$ ' +
                  '$\\style{position:fixed;top:0;left:0;width:100vw;height:100vh}{z}$ $\\class{evil}{w}$ $\\cssId{evil}{v}$')
  // (The formula's TeX is kept as text, in data-latex; only what can act is checked.) Without the
  // `html` package there is no \href at all; the filter drops any link that still gets through.
  assert.doesNotMatch(html, /<a\s|href="(?!#)/)
  assert.doesNotMatch(html, /style="[^"]*position:\s*fixed|class="evil"|id="evil"/)
})

test('the formula filter keeps only links to web pages, mail and the page', async () => {
  const { safeMath } = await import('../../docs/src/components/kbMarkdown.ts')
  assert.equal(safeMath('<a href="https://arxiv.org"><a href="javascript:x"><a href="JAVA SCRIPT:x"><use xlink:href="#g">'),
               '<a href="https://arxiv.org"><a><a><use xlink:href="#g">')
})

test('references and attached files', () => {
  assert.match(md('See @KB-12.', { refs: true }), /data-task="KB-12"/)
  assert.doesNotMatch(md('See @KB-12.'), /data-task/)                                    // only when asked for
  assert.match(md('From @kb-f3.', { refs: true }), /<a class="kb-ref kb-ref-finding" href="[^"]*findings\.html#KB-F3">KB-F3<\/a>/)
  const h = 'a'.repeat(64)
  assert.match(md(`![plot](media/${h}/plot.png)`), new RegExp(`<img src="/api/media/${h}/plot.png"[^>]*class="kb-image"`))
  assert.match(md(`![run](media/${h}/run.mp4)`), new RegExp(`<video class="kb-video" controls preload="metadata" src="/api/media/${h}/run.mp4"`))
  assert.match(md(`[data](media/${h}/data.csv)`), new RegExp(`href="/api/media/${h}/data.csv" target="_blank"`))
})

test('a line of text, its \\( \\) mathematics as $ $', () => {
  const html = md('A *line* with \\(x^2\\) and `code`', { inline: true })
  assert.doesNotMatch(html, /<p>/)
  assert.match(html, /<em>line<\/em>/)
  assert.equal((html.match(/<mjx-container/g) ?? []).length, 1)
  assert.match(html, /<code>code<\/code>/)
})

test('a link from the site\'s root stays under its base', () => {
  globalThis.__KB_BASE__ = '/docs'
  try {
    assert.match(md('[a paper](/generated/kb/papers/2401-00001.html)'), /href="\/docs\/generated\/kb\/papers\/2401-00001\.html"/)
    assert.match(md('[elsewhere](//example.org/x)'), /href="\/\/example.org\/x"/)
    assert.match(md('[here](#notes)'), /href="#notes"/)
  } finally { delete globalThis.__KB_BASE__ }
})

test('the tutor\'s citations, to the page of a paper held and to arXiv otherwise', () => {
  const titles = new Map([['2401.00001', 'A Study of [Reefs]']])
  const html = md('As shown [arXiv:2401.00001; arXiv:2402.00002], and [arXiv:2401.00001](https://x.org).', { refs: true, titles })
  assert.match(html, /\(<a class="kb-ref kb-ref-paper" href="\/generated\/kb\/papers\/2401-00001\.html">A Study of \[Reefs\]<\/a>; /)
  assert.match(html, /<a href="https:\/\/arxiv.org\/abs\/2402.00002" target="_blank" rel="noopener">arXiv:2402.00002<\/a>\)/)
  assert.match(html, /<a href="https:\/\/x.org"[^>]*>arXiv:2401.00001<\/a>/)                 // a link written as one stays
  assert.match(md('[arXiv:2401.00001]', { refs: true }), /href="https:\/\/arxiv.org\/abs\/2401.00001"/)
})
