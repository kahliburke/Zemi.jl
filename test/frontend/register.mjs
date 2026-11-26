import { register } from 'node:module'
// What the site's build defines for the components (see docs/make.jl): the API's address, links
// with `.html`, and pages made from a template, a kind of each shape.
globalThis.__KB_API__ = ''
globalThis.__KB_PUBLIC_DEMO__ = false
globalThis.__KB_CLEAN_URLS__ = false
globalThis.__KB_TEMPLATES__ = [
  { name: 'papers', folder: 'kb/papers', template: 'kb/templates/paper' },
  { name: 'code', folder: 'kb/code/*/files', template: 'kb/templates/code-file' },
  { name: 'codebase', folder: 'kb/code/*', template: 'kb/templates/codebase' },
  { name: 'daily', folder: 'kb/daily/*', template: 'kb/templates/day' },
]
globalThis.__KB_TEMPLATE_COPY__ = 'c1'
register('./loader.mjs', import.meta.url)
