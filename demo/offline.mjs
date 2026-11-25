// Inject only the public demo's reading material. Run after stamp_templates! so direct navigations
// and VitePress links have both the full and lean page chunks, including the per-paper copies.
import { createHash } from 'node:crypto'
import { readFile, writeFile, unlink } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'

const [site, packages] = process.argv.slice(2)
const { injectManifest } = createRequire(resolve(packages, 'package.json'))('workbox-build')
const dest = join(site, 'zemi-sw.js')
// Vite also produces hundreds of lazy editor modes and highlighting grammars. Keep the
// reader's configured grammars and their static imports (Julia's grammar embeds several others).
const graphPath = join(site, '.vite', 'manifest.json')
const graph = JSON.parse(await readFile(graphPath, 'utf8'))
const highlight = JSON.parse(await readFile(new URL('../docs/src/components/kbHighlight.json', import.meta.url)))
const chunks = new Set()
function include(key) {
  const chunk = graph[key]
  if (chunks.has(chunk.file)) return
  chunks.add(chunk.file)
  for (const dependency of chunk.imports || []) include(dependency)
}
for (const [key, chunk] of Object.entries(graph)) {
  if (key.includes('/@codemirror/')) continue
  if (key.includes('/@shikijs/langs/') && !highlight.languages.includes(chunk.name)) continue
  if (key.includes('/@shikijs/themes/') && !highlight.themes.includes(chunk.name)) continue
  include(key)
}
const { count, size, warnings } = await injectManifest({
  swSrc: fileURLToPath(new URL('../docs/src/assets/zemi-sw.js', import.meta.url)),
  swDest: dest,
  globDirectory: site,
  globPatterns: [
    'index.html', 'generated/kb/index.html', 'generated/kb/papers/*.html',
    'papers.json', 'daily.json', 'kb-data/papers/*.json',
    'assets/{app.*,style.*,*.woff2,index.md.*,generated_kb_index.md.*,generated_kb_papers_*.js}',
    'assets/chunks/metadata.*.js', ...[...chunks].filter(file => file.startsWith('assets/chunks/')),
    'vp-icons.css', 'siteinfo.js', 'manifest.webmanifest',
    '{favicon.ico,logo.png,hero-light.*,hero-dark.*,zemi-icon-*.png}',
  ],
  maximumFileSizeToCacheInBytes: 10 * 1024 * 1024,
})
if (warnings.length) throw new Error(warnings.join('\n'))
const worker = await readFile(dest, 'utf8')
const revision = createHash('sha256').update(worker).digest('hex').slice(0, 20)
await writeFile(dest, worker.replace('__ZEMI_BUILD__', revision))
await unlink(graphPath)
console.log(`Offline demo: ${count} files, ${(size / 1024 / 1024).toFixed(1)} MiB`)
