// Bundles the plugin into main.js, as Obsidian loads it: Obsidian's own modules and Node's are left
// for Obsidian to provide.
import esbuild from 'esbuild'
import builtins from 'builtin-modules'

const watch = process.argv.includes('--watch')
const ctx = await esbuild.context({
  entryPoints: ['src/main.ts'],
  bundle: true,
  external: ['obsidian', 'electron', '@codemirror/*', '@lezer/*', ...builtins],
  format: 'cjs',
  target: 'es2020',
  sourcemap: watch ? 'inline' : false,
  outfile: 'main.js',
  logLevel: 'info',
})
if (watch) await ctx.watch()
else { await ctx.rebuild(); await ctx.dispose() }
