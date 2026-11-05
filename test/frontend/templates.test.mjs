// Pages made from a template (docs/src/components/kbTemplates.ts): a page's slug from its address,
// and the build's table of page scripts answering for pages added since the build.
import { test } from 'node:test'
import assert from 'node:assert/strict'

// The page's table, set by the build's script before the module runs.
globalThis.window = { __VP_HASH_MAP__: { 'generated_kb_templates_paper.md': 'Bx1', 'generated_kb_templates_code-file.md': 'Cy2',
                                         'generated_kb_templates_codebase.md': 'Ew4',
                                         'generated_kb_papers_2401-00001.md': 'Built', 'index.md': 'Home' } }
const { slugOf, dataPath, useTemplatedPage } = await import('../../docs/src/components/kbTemplates.ts')
// The components' Vue, as they resolve it.
const { reactive, effectScope, nextTick } = await import('../../docs/node_modules/vue/index.mjs')

test('a page\'s slug, flat or in a folder of its own', () => {
  assert.equal(slugOf('papers', '/generated/kb/papers/2401-00001.html'), '2401-00001')
  assert.equal(slugOf('papers', '/base/generated/kb/papers/2401-00001'), '2401-00001')
  assert.equal(slugOf('papers', '/generated/kb/papers/2401-00001/notebook.html'), '')     // a page beneath one
  assert.equal(slugOf('code', '/generated/kb/code/code-kb/files/src_tasks_jl.html'), 'code-kb/src_tasks_jl')
  assert.equal(slugOf('codebase', '/generated/kb/code/code-kb/'), 'code-kb/index')
  assert.equal(slugOf('codebase', '/generated/kb/code/code-kb/files/src_tasks_jl.html'), '')
  assert.equal(slugOf('daily', '/generated/kb/daily/2026-10-02/'), '2026-10-02/index')
  assert.equal(slugOf('daily', '/generated/kb/daily/2026-10-02/index.html'), '2026-10-02/index')
  assert.equal(slugOf('papers', '/generated/kb/topics/physics-plasm-ph.html'), '')
  assert.equal(slugOf('nothing', '/generated/kb/papers/2401-00001.html'), '')
  assert.equal(dataPath('code', 'code-kb/src_tasks_jl'), '/kb-data/code/code-kb/src_tasks_jl.json')
})

test('a page added since the build is answered with its template\'s script', () => {
  const table = window.__VP_HASH_MAP__
  assert.equal(table['generated_kb_papers_2401-00001.md'], 'Built')                  // built pages keep their own
  assert.equal(table['generated_kb_papers_2402-00002.md'], 'Bx1.c1')
  assert.equal(table['generated_kb_code_code-kb_files_src_tasks_jl.md'], 'Cy2.c1')
  assert.equal(table['generated_kb_code_code-kb_index.md'], 'Ew4.c1')                // a codebase's own page
  assert.equal(table['generated_kb_papers_2401-00001_notebook.md'], undefined)      // not a page of the kind
  assert.equal(table['generated_kb_daily_2026-10-02_index.md'], undefined)          // no template in the table
  // A table set later, as the build's script may, is answered the same way.
  window.__VP_HASH_MAP__ = { 'generated_kb_templates_paper.md': 'Dz3' }
  assert.equal(window.__VP_HASH_MAP__['generated_kb_papers_9999-00001.md'], 'Dz3.c1')
})

test('a page shows the answer for the last address only, its data or its error', async () => {
  globalThis.location = { hash: '' }
  globalThis.document = { getElementById: () => null }
  const route = globalThis.__KB_ROUTE__ = reactive({ path: '/generated/kb/papers/2401-00001.html', data: { title: '', frontmatter: {} } })
  // Each data file's status, and how long it takes to answer.
  const files = { '/kb-data/papers/2401-00001.json': [404, 40], '/kb-data/papers/2402-00002.json': [200, 5],
                  '/kb-data/papers/2403-00003.json': [200, 40], '/kb-data/papers/2404-00004.json': [404, 5] }
  globalThis.fetch = url => new Promise(done => setTimeout(() => {
    const [status] = files[url]
    done(new Response(JSON.stringify(status === 200 ? { title: url } : {}), { status }))
  }, files[url][1]))
  const wait = ms => new Promise(done => setTimeout(done, ms))
  const scope = effectScope()
  const page = scope.run(() => useTemplatedPage('papers', 'No such paper.', { title: p => `T ${p.title}`, markdown: false }))
  route.path = '/generated/kb/papers/2402-00002.html'                // gone on before the first answers
  await nextTick(); await wait(60)
  assert.equal(page.data.value.title, '/kb-data/papers/2402-00002.json')
  assert.equal(page.error.value, '')                                    // the first one's failure, late, is dropped
  assert.equal(route.data.title, 'T /kb-data/papers/2402-00002.json')
  route.path = '/generated/kb/papers/2403-00003.html'
  await nextTick()
  route.path = '/generated/kb/papers/2404-00004.html'
  await nextTick(); await wait(60)
  assert.equal(page.data.value, null)                                   // nor is a success for an address left
  assert.equal(page.error.value, 'No such paper.')
  scope.stop()
})
