// Links to the site's pages (kbLinks.ts) and @-references (kbRefs.ts): where each kind leads, how the
// picker writes one, and the forms text writes them in.
import { test } from 'node:test'
import assert from 'node:assert/strict'

const links = await import('../../docs/src/components/kbLinks.ts')
const { href, sourceHref, refFor, refText, refsToMarkdown, setCodebase, onTaskRef, findReferences } =
  await import('../../docs/src/components/kbRefs.ts')

test('the kind of a document, from its id', async () => {
  const { documentKind, isArxivId, isCodebase, isRecord, hasAccess, citedAs, splitCodeTarget, kindNoun } = await import('../../docs/src/components/kbKinds.ts')
  assert.equal(documentKind('2401.00001'), 'paper')
  assert.equal(documentKind('hep-th/9901001'), 'paper')
  assert.equal(documentKind('doc-5f13926ae1'), 'paper')
  assert.equal(documentKind('code-kb'), 'code')
  assert.equal(documentKind('rec-notes-survey'), 'record')
  assert.equal(documentKind('zzz-reef-survey'), undefined)                    // of no kind: neither a paper nor on arXiv
  assert.ok(isArxivId('2401.00001') && !isArxivId('doc-5f13926ae1') && !isArxivId('zzz-reef-survey'))
  assert.ok(isCodebase('code-kb') && !isCodebase('doc-5f13926ae1') && isRecord('rec-notes-survey') && !isRecord('code-kb'))
  assert.ok(hasAccess('code-kb') && hasAccess('rec-notes-survey') && !hasAccess('2401.00001') && !hasAccess('zzz-reef-survey'))
  assert.equal(kindNoun('code'), 'codebase')
  assert.equal(citedAs('2401.00001'), 'arXiv:2401.00001')
  assert.equal(citedAs('doc-5f13926ae1'), 'doc-5f13926ae1')
  assert.deepEqual(splitCodeTarget('code-kb:src/tasks.jl#f'), ['code-kb', 'src/tasks.jl#f'])
  assert.deepEqual(splitCodeTarget('src/tasks.jl#f'), ['', 'src/tasks.jl#f'])
})

test('pages, each kind built one way', () => {
  assert.equal(links.pageLink('/projects'), '/projects.html')
  assert.equal(links.pageLink('/generated/kb/daily/2026-10-02/'), '/generated/kb/daily/2026-10-02/')
  assert.equal(links.paperHref('2401.00001'), '/generated/kb/papers/2401-00001.html')
  assert.equal(links.paperHref('2401-00001'), '/generated/kb/papers/2401-00001.html')        // its page name works as well
  assert.equal(links.paperHref('hep-th/9901001'), '/generated/kb/papers/hep-th-9901001.html')
  assert.equal(links.codeHref('code-kb', 'src/tasks.jl', 'update_project!'), '/generated/kb/code/code-kb/files/src_tasks_jl.html#update_project!')
  assert.equal(links.topicHref('physics.plasm-ph'), '/generated/kb/topics/physics-plasm-ph.html')
  assert.equal(links.authorHref('hale|r'), '/generated/kb/authors.html?a=hale%7Cr')
  assert.equal(links.manageHref('2401.00001'), '/generated/kb/manage.html?id=2401.00001')
  assert.equal(links.taskHref('KB-12'), '/projects.html#KB-12')
  assert.equal(links.findingHref('new/KB-12'), '/findings.html#new/KB-12')
})

test('where a reference leads', () => {
  setCodebase('')
  assert.equal(href('code', 'src/tasks.jl#update_project!'), '')                                 // no codebase open
  assert.equal(href('code', 'code-kb:src/tasks.jl#update_project!'), '/generated/kb/code/code-kb/files/src_tasks_jl.html#update_project!')
  setCodebase('code-kb')
  assert.equal(href('code', 'src/'), '/generated/kb/code/code-kb/files/src.html')
  assert.equal(href('notebook', 'notebooks/papers/2409-00785/scaling.jl'), '/generated/kb/papers/2409-00785/scaling.html')
  assert.equal(href('notebook', 'elsewhere.jl'), '')
  assert.equal(href('codebase', 'code-kb'), '/generated/kb/code/code-kb/')
  assert.equal(href('author', 'lovelace|a'), '/generated/kb/authors.html?a=lovelace%7Ca')
  assert.equal(href('finding', 'kb-f3'), '/findings.html#KB-F3')
  assert.equal(href('record', 'rec-notes-2026-10-02'), '/generated/kb/records/rec-notes-2026-10-02.html')
  assert.equal(href('person', 'rowan@example.org'), '')
  setCodebase('')
})

test('a link or source: a paper not held on arXiv, a web page as itself, a result where it is served', () => {
  assert.equal(sourceHref('paper', '2401.00001'), 'https://arxiv.org/abs/2401.00001')
  assert.equal(sourceHref('paper', '2401.00001', 'A Study of Reefs'), '/generated/kb/papers/2401-00001.html')
  assert.equal(sourceHref('paper', 'doc-5f13926ae1'), '/generated/kb/papers/doc-5f13926ae1.html')
  assert.equal(sourceHref('url', 'https://example.org/a'), 'https://example.org/a')
  assert.equal(sourceHref('url', 'javascript:alert(1)'), '')
  assert.equal(sourceHref('result', `media/${'a'.repeat(64)}/plot.png`), `/api/media/${'a'.repeat(64)}/plot.png`)
  assert.equal(sourceHref('task', 'KB-12'), '/projects.html#KB-12')
})

test('a reference as the picker writes it', () => {
  assert.equal(refFor('task', 'KB-12'), '@KB-12')
  assert.equal(refFor('finding', 'KB-F3'), '@KB-F3')
  assert.equal(refFor('paper', '2401.00001'), '@arXiv:2401.00001')
  assert.equal(refFor('paper', 'doc-5f13926ae1'), '@doc-5f13926ae1')
  assert.equal(refFor('record', 'rec-notes-2026-10-02'), '@rec-notes-2026-10-02')
  assert.equal(refFor('code', 'code-kb:src/tasks.jl#update_project!'), '@code:src/tasks.jl#update_project!')
  assert.equal(refFor('notebook', 'notebooks/papers/2409-00785/scaling.jl', 'Error scaling'),
               '@[Error scaling](notebook:notebooks/papers/2409-00785/scaling.jl)')
  assert.equal(refText({ kind: 'person', target: 'bea@example.org', label: 'Bea Moss', detail: '' }), '@[Bea Moss](person:bea@example.org)')
})

test('references in text, outside code', () => {
  const md = refsToMarkdown('See @code:src/tasks.jl#update_project! and @doc-5f13926ae1, @arXiv:hep-th/9901001, ' +
                            '@[Ada [1](author:lovelace|a), not `@KB-12`.')
  assert.match(md, /\[update_project!\]\(kbref:code:src%2Ftasks\.jl%23update_project!\)/)
  assert.match(md, /\[doc-5f13926ae1\]\(kbref:paper:doc-5f13926ae1\)/)
  assert.match(md, /\[arXiv:hep-th\/9901001\]\(kbref:paper:hep-th%2F9901001\)/)
  assert.match(md, /\[Ada \\\[1\]\(kbref:author:lovelace%7Ca\)/)                // a bracket in a label kept as text
  assert.match(md, /`@KB-12`/)
  assert.doesNotMatch(md, /kbref:task/)
  assert.equal(refsToMarkdown('mail ada@KB-12 x'), 'mail ada@KB-12 x')                                    // not after a word
  assert.equal(refsToMarkdown('As @rec-notes-2026-10-02.'), 'As [rec-notes-2026-10-02](kbref:record:rec-notes-2026-10-02).')
})

test('a click or Enter on a task reference opens it', () => {
  const opened = []
  const handler = onTaskRef(r => opened.push(r))
  const at = ref => ({ closest: s => s === '[data-task]' && ref ? { dataset: { task: ref } } : null })
  let prevented = 0
  const event = (type, target, key) => ({ type, target, key, preventDefault: () => prevented++ })
  handler(event('click', at('KB-12')))
  handler(event('keydown', at('KB-13'), 'Tab'))
  handler(event('keydown', at('KB-14'), 'Enter'))
  handler(event('click', at(null)))
  assert.deepEqual(opened, ['KB-12', 'KB-14'])
  assert.equal(prevented, 2)
})

test('what the picker offers is asked of the project', async () => {
  const asked = []
  globalThis.fetch = async url => { asked.push(url); return new Response('[]', { status: 200 }) }
  await findReferences('ada lo', 'K&B')
  await findReferences('x')
  assert.deepEqual(asked, ['/api/tasks/references?q=ada%20lo&project=K%26B', '/api/tasks/references?q=x'])
})
