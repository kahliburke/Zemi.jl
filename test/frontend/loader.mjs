// Lets Node run the site's components outside VitePress, for tests: `vitepress` is a stand-in,
// stylesheets are nothing, and imports written without an extension find their `.ts` file.

// The site's base is '' unless a test sets `globalThis.__KB_BASE__` (as `/docs`, say); the page's
// route is `globalThis.__KB_ROUTE__`.
const VITEPRESS = "export const withBase = s => s.startsWith('/') ? (globalThis.__KB_BASE__ ?? '') + s : s; export const useData = () => ({}); export const useRoute = () => globalThis.__KB_ROUTE__ ?? ({})"

export async function resolve(specifier, context, next) {
  if (specifier === 'vitepress') return { url: `data:text/javascript,${encodeURIComponent(VITEPRESS)}`, shortCircuit: true }
  if (specifier.endsWith('.css')) return { url: 'data:text/javascript,export default {}', shortCircuit: true }
  if (specifier.startsWith('.') && !/\.[cm]?[jt]s$/.test(specifier)) {
    try { return await next(specifier + '.ts', context) } catch { /* not a .ts file */ }
  }
  return next(specifier, context)
}

// The components are ES modules in TypeScript: said so, rather than guessed at.
export async function load(url, context, next) {
  return url.endsWith('.ts') ? next(url, { ...context, format: 'module-typescript' }) : next(url, context)
}
