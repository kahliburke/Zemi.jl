// The one Markdown renderer for text people and agents write (task plans, notes, descriptions, the
// tutor's answers): markdown-it with `$…$`, `$$…$$` and ```math mathematics (MathJax, as SVG), code
// highlighted in the site's light and dark themes (Shiki), tables, footnotes and linked URLs, and
// optionally @references and `[arXiv:…]` citations (see kbRefs.ts). Links written from the site's
// root (`/generated/kb/…`) are kept under the site's base. Files attached to the text, named `media/<hash>/<name>`,
// are shown from where they are served: images (full size on a click), movies as players, other
// files as links. Raw HTML in text is shown as text: only what Markdown itself makes is produced.
// Loaded once, on first use, and shared.
import { ref } from 'vue'
import { withBase } from 'vitepress'
import { refsToMarkdown, refsHtml } from './kbRefs'
import { mediaUrl } from './kbApi'
import { escapeHtml } from './kbUtils'
import { closeOnEscape, holdFocus } from './kbDialog'
import type { PluginSimple } from 'markdown-it'
import type { TexPackage } from '@mdit/plugin-mathjax'
import './kbMarkdown.css'

// `refs`: @references and citations made links, a cited paper the knowledge base holds (in `titles`,
// by its id) to its page; `inline`: a line of text, with no paragraph around it.
export type Render = (text: string, options?: { refs?: boolean; inline?: boolean; titles?: ReadonlyMap<string, string> }) => string

// Shiki's names for the languages highlighted; another name for one of them is mapped to it.
const LANGS = ['julia', 'python', 'bash', 'shellscript', 'json', 'toml', 'yaml', 'c', 'cpp', 'fortran-free-form', 'matlab', 'latex', 'r',
               'rust', 'javascript', 'typescript', 'vue', 'html', 'css', 'sql', 'diff', 'markdown']
const ALIASES: Record<string, string> = { jl: 'julia', py: 'python', sh: 'bash', zsh: 'bash', shell: 'shellscript', js: 'javascript',
                                          ts: 'typescript', tex: 'latex', md: 'markdown', yml: 'yaml', fortran: 'fortran-free-form',
                                          f90: 'fortran-free-form' }

// A formula written right against a number, as abstracts do ("$\sim$23k"): the mathematics rule
// takes no `$` followed by a digit as a formula's end (so "$5 and $6" stay money), and then pairs the
// wrong dollar signs. A formula that starts with a TeX command is mathematics, so its end is kept
// apart from the digit by an invisible word joiner. Code is left as written.
const JOINER = '\u2060'
export function mathBeforeDigits(text: string): string {
  return text.split(/(```[\s\S]*?```|`[^`\n]*`)/).map((part, i) =>
    i % 2 ? part : part.replace(/(^|[^$\\])(\$\\[A-Za-z]+[^$\n]*\$)(?=\d)/g, `$1$2${JOINER}`)).join('')
}

// Text as text, for before the renderer has loaded.
export const escapeText: Render = s => escapeHtml(s)

let loading: Promise<Render> | null = null

/** The renderer, loaded once: later calls share the first. */
export function loadMarkdown(): Promise<Render> {
  return loading ??= build()
}

// Bring `el` to the middle of the box it scrolls in (a panel, say), leaving the page behind it alone.
function scrollWithin(el: HTMLElement) {
  for (let box = el.parentElement; box; box = box.parentElement) {
    const y = getComputedStyle(box).overflowY
    if ((y === 'auto' || y === 'scroll') && box.scrollHeight > box.clientHeight) {
      const at = el.getBoundingClientRect().top - box.getBoundingClientRect().top
      box.scrollBy({ top: at - box.clientHeight / 2, behavior: 'smooth' })
      return
    }
  }
  el.scrollIntoView({ behavior: 'smooth', block: 'center' })
}

// An attached file's address in text.
const MEDIA = /^media\/[0-9a-f]{64}\/[A-Za-z0-9._-]+$/

// A click on an attached image shows it full size over the page; a click or Escape (see kbDialog.ts)
// closes it. A click (or Enter) on a footnote, or back from one, scrolls to it.
function zoomImages() {
  const toNote = (e: Event) => {
    const note = (e.target as HTMLElement).closest?.('.kb-md [data-note]')
    if (!note) return false
    e.preventDefault()
    const to = document.getElementById(note.getAttribute('data-note')!)
    if (to) scrollWithin(to)
    return true
  }
  document.addEventListener('keydown', e => { if (e.key === 'Enter') toNote(e) })
  document.addEventListener('click', e => {
    if (toNote(e)) return
    const img = (e.target as HTMLElement).closest?.('.kb-md img.kb-image') as HTMLImageElement | null
    if (!img) return
    e.preventDefault()
    const over = document.createElement('div')
    over.className = 'kb-zoom'
    over.tabIndex = -1
    over.setAttribute('role', 'dialog')
    over.setAttribute('aria-modal', 'true')
    over.setAttribute('aria-label', img.alt || 'Image')
    over.innerHTML = `<img src="${escapeHtml(img.src)}" alt="${escapeHtml(img.alt)}">`
    document.body.appendChild(over)
    const release = holdFocus(over)
    const close = () => { stop(); over.remove(); release() }
    const stop = closeOnEscape(close)
    over.addEventListener('click', close)
  })
}

// The TeX packages formulas may use: the plugin's own list but `html` (\href, \style, \class, \cssId,
// which would let a formula link anywhere, or restyle or cover the page) and `texhtml` (HTML inside a
// formula).
const MATH_PACKAGES = ['base', 'action', 'ams', 'amscd', 'bbm', 'bboldx', 'bbox', 'begingroup', 'boldsymbol', 'braket',
  'bussproofs', 'cancel', 'cases', 'centernot', 'color', 'colortbl', 'colorv2', 'configmacros', 'dsfont', 'empheq', 'enclose',
  'extpfeil', 'gensymb', 'mathtools', 'mhchem', 'newcommand', 'noerrors', 'noundefined', 'physics', 'setoptions', 'tagformat',
  'textcomp', 'textmacros', 'unicode', 'units', 'upgreek', 'verb']

// A formula's links kept only to web pages, mail and the page itself, should one get through: a
// `javascript:` one would run on this site. The static site's formulas go through the same filter
// (see docs/make.jl), since its MathJax loads packages as formulas ask for them.
export const UNSAFE_LINK = /\s(?:xlink:)?href\s*=\s*"(?!https?:|mailto:|#)[^"]*"/gi
export const safeMath = (html: string) => html.replace(UNSAFE_LINK, '')

// The mathematics font's glyphs come in pieces, each loaded when a formula first needs one: MathJax asks
// for a piece by its module's name, which the page cannot import as named, so each is listed here for
// the bundler to make a chunk of.
const FONT_PIECES: Record<string, () => Promise<unknown>> = {
  'PUA': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/PUA.js'),
  'accents': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/accents.js'),
  'accents-b-i': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/accents-b-i.js'),
  'arabic': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/arabic.js'),
  'arrows': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/arrows.js'),
  'braille': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/braille.js'),
  'braille-d': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/braille-d.js'),
  'calligraphic': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/calligraphic.js'),
  'cherokee': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/cherokee.js'),
  'cyrillic': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/cyrillic.js'),
  'cyrillic-ss': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/cyrillic-ss.js'),
  'devanagari': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/devanagari.js'),
  'double-struck': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/double-struck.js'),
  'fraktur': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/fraktur.js'),
  'greek': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/greek.js'),
  'greek-ss': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/greek-ss.js'),
  'hebrew': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/hebrew.js'),
  'latin': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/latin.js'),
  'latin-b': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/latin-b.js'),
  'latin-bi': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/latin-bi.js'),
  'latin-i': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/latin-i.js'),
  'marrows': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/marrows.js'),
  'math': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/math.js'),
  'monospace': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/monospace.js'),
  'monospace-ex': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/monospace-ex.js'),
  'monospace-l': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/monospace-l.js'),
  'mshapes': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/mshapes.js'),
  'phonetics': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/phonetics.js'),
  'phonetics-ss': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/phonetics-ss.js'),
  'sans-serif': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif.js'),
  'sans-serif-b': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif-b.js'),
  'sans-serif-bi': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif-bi.js'),
  'sans-serif-ex': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif-ex.js'),
  'sans-serif-i': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif-i.js'),
  'sans-serif-r': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif-r.js'),
  'script': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/script.js'),
  'shapes': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/shapes.js'),
  'symbols': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/symbols.js'),
  'symbols-b-i': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/symbols-b-i.js'),
  'variants': () => import('@mathjax/mathjax-newcm-font/js/svg/dynamic/variants.js'),
}

// Bumped as a font piece arrives: what was rendered while it loaded (its formulas as written) renders
// again, since each rendering reads it.
const glyphs = ref(0)
const loadingPieces = new Set<Promise<unknown>>()
function awaitPiece(retry: Promise<unknown>) {
  if (loadingPieces.has(retry)) return
  loadingPieces.add(retry)
  retry.then(() => glyphs.value++, e => console.warn('A piece of the mathematics font did not load', e))
       .finally(() => loadingPieces.delete(retry))
}

async function build(): Promise<Render> {
  const [{ default: MarkdownIt }, footnote, mj, shiki] = await Promise.all([
    import('markdown-it'), import('markdown-it-footnote'), import('@mdit/plugin-mathjax'), import('shiki')])
  // Only languages the bundle has: asking for another fails the whole highlighter.
  const langs = LANGS.filter(l => l in shiki.bundledLanguages)
  const highlighter = await shiki.createHighlighter({ themes: ['github-light', 'github-dark'], langs }).catch(e => {
    console.warn('Code is shown without highlighting', e)
    return null
  })
  // The renderer, and one without mathematics, for a text whose formulas wait on a font piece.
  const configured = () => {
    const md = MarkdownIt({
      html: false, linkify: true, breaks: false,
      highlight: (code: string, lang: string) => {
        const l = ALIASES[(lang || '').toLowerCase()] ?? (lang || '').toLowerCase()
        // Both themes at once: the site's dark class picks which shows (see kbMarkdown.css).
        return highlighter && langs.includes(l)
          ? highlighter.codeToHtml(code, { lang: l, themes: { light: 'github-light', dark: 'github-dark' }, defaultColor: false }) : ''
      },
    })
    // (The plugin's types are written against an older markdown-it's.)
    md.use((footnote.default ?? footnote) as unknown as PluginSimple)
    // Footnote links name the note they go to rather than linking to `#…`: the site's router, and pages
    // such as the projects board, take the page's address for their own (see zoomImages).
    for (const rule of ['footnote_ref', 'footnote_anchor'] as const) {
      const made = md.renderer.rules[rule]!
      md.renderer.rules[rule] = (tokens, i, options, env, self) =>
        made(tokens, i, options, env, self).replace(/href="#([^"]+)"/, 'data-note="$1" role="link" tabindex="0"')
    }
    // Links in text leave the page; one to an attached file opens it from where it is served, and one
    // from the site's root stays under its base.
    const link = md.renderer.rules.link_open ?? ((tokens, i, options, _env, self) => self.renderToken(tokens, i, options))
    md.renderer.rules.link_open = (tokens, i, options, env, self) => {
      const href = tokens[i].attrGet('href') ?? ''
      if (MEDIA.test(href)) tokens[i].attrSet('href', mediaUrl(href))
      else if (/^\/(?!\/)/.test(href)) tokens[i].attrSet('href', withBase(href))
      if (/^https?:\/\//.test(href) || MEDIA.test(href)) { tokens[i].attrSet('target', '_blank'); tokens[i].attrSet('rel', 'noopener') }
      return link(tokens, i, options, env, self)
    }
    // An attached image from where it is served, a movie as a player.
    const image = md.renderer.rules.image!
    md.renderer.rules.image = (tokens, i, options, env, self) => {
      const t = tokens[i], src = t.attrGet('src') ?? ''
      if (!MEDIA.test(src)) return image(tokens, i, options, env, self)
      const url = mediaUrl(src)
      if (/\.(mp4|webm|mov)$/i.test(src))
        return `<video class="kb-video" controls preload="metadata" src="${md.utils.escapeHtml(url)}" title="${md.utils.escapeHtml(t.content)}"></video>`
      t.attrSet('src', url); t.attrSet('loading', 'lazy'); t.attrSet('class', 'kb-image')
      return image(tokens, i, options, env, self)
    }
    return md
  }
  const md = configured(), plain = configured()
  try {
    // The font's pieces from the bundle, as formulas need them (see FONT_PIECES).
    const { mathjax } = await import('@mathjax/src/js/mathjax.js')
    const imported = mathjax.asyncLoad
    mathjax.asyncLoad = (name: string) => {
      const piece = FONT_PIECES[name.match(/\/dynamic\/([^/]+?)(?:\.js)?$/)?.[1] ?? '']
      return piece ? piece() : imported(name)
    }
    // A fenced block whose language is math is a displayed formula, as Julia's Markdown writes one.
    // (The list of packages replaces the plugin's, `base` included, which its type leaves out.)
    const instance = await mj.createMathjaxInstance({ output: 'svg', tex: { packages: MATH_PACKAGES as TexPackage[] }, transformer: safeMath,
                                                      mathFence: true })
    if (instance) {
      md.use(mj.mathjax, instance)
      if (typeof document !== 'undefined') {             // what the SVG mathematics needs, once, without every piece
        const style = document.createElement('style')
        const out = instance.documentOptions.OutputJax
        style.textContent = instance.adaptor.cssText(out.styleSheet(mathjax.document('', instance.documentOptions)))
        instance.clearStyle()
        document.head.appendChild(style)
      }
    }
  } catch (e) { console.warn('Mathematics is shown as written', e) }
  if (typeof document !== 'undefined') zoomImages()   // in a page (the renderer also runs in tests)
  // Each rendering's footnotes have ids of their own, as several texts share a page.
  let renderings = 0
  // A formula needing a font piece not loaded yet stops MathJax with a retry: the text is shown with
  // its formulas as written until the piece arrives, then again in full.
  const render = (text: string) => {
    void glyphs.value
    const env = { docId: `t${++renderings}` }
    text = mathBeforeDigits(text)
    try { return md.render(text, env) }
    catch (e: any) {
      if (!(e?.retry instanceof Promise)) throw e
      awaitPiece(e.retry)
      return plain.render(text, env)
    }
  }
  // A line of text (a title): its emphasis, code and mathematics, with no paragraph around it.
  const inline = (text: string) => {
    void glyphs.value
    const t = mathBeforeDigits(text.replace(/\\\((.+?)\\\)/g, '$$$1$$'))   // \( … \) as $ … $, as titles write either
    try { return md.renderInline(t) }
    catch (e: any) {
      if (!(e?.retry instanceof Promise)) throw e
      awaitPiece(e.retry)
      return plain.renderInline(t)
    }
  }
  return (text, options = {}) =>
    options.inline ? inline(text) : options.refs ? refsHtml(render(refsToMarkdown(text, options.titles))) : render(text)
}
