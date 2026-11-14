using Documenter, DocumenterSlate, DocumenterVitepress
import KaimonSlate
import Zemi as KBase

# How long each step of a build takes, in its log (the service shows these lines as the build runs):
# from the moment the service started this process (ZEMI_BUILD_T0), then each step's own time.
step_time(what, t0) = @info "SiteStep: $what in $(round(time() - t0; digits = 1)) s"
haskey(ENV, "ZEMI_BUILD_T0") && step_time("started and loaded the packages", parse(Float64, ENV["ZEMI_BUILD_T0"]))

# Code blocks are written back as Markdown with a fence no run of backticks in them can close, however
# it is indented (see KBase.plain_code): pages quote files, equations and text that could otherwise
# end a block early and put what follows on the page as HTML.
Documenter.Markdown.plain(io::IO, code::Documenter.Markdown.Code) = KBase.plain_code(io, code.language, code.code)
# Under zemi, pick up changes to the package since the last build.
isdefined(Main, :Revise) && Main.Revise.revise()

# A service builds each version of the site from sources of its own, so builds of other knowledge
# bases from this checkout do not write over its pages: ZEMI_SITE_DOCS names a folder laid out
# like this one (see `default_site_build`). Otherwise the pages are written here.
const DOCS = get(ENV, "ZEMI_SITE_DOCS", @__DIR__)
const SRC = joinpath(DOCS, "src")
const NOTEBOOKS = joinpath(DOCS, "notebooks")      # the content's, linked into the sources
const GENERATED = joinpath(SRC, "generated")
const KB_PAGES = joinpath(GENERATED, "kb")
const KB_PUBLIC = joinpath(DOCS, "kb_public")   # build output: copied to the site's root
# `zemi dev` writes the pages without bundling them, for VitePress's development server to serve,
# forwarding the API to the knowledge base at ZEMI_DEV_API (see `run_dev`).
const DEV = get(ENV, "ZEMI_SITE_DEV", "") == "1"
# When the knowledge base changes, it writes again only the pages that changed, from a folder holding
# just them: ZEMI_SITE_PAGES names a file listing them, a line each, under src (see
# `write_dev_pages!`). Their links to other pages are left for VitePress to follow.
const ONLY = let f = DEV ? get(ENV, "ZEMI_SITE_PAGES", "") : ""
    isempty(f) ? String[] : filter(!isempty, readlines(f))
end

# A notebook's title: its first Markdown heading, or its file's name.
function notebook_title(path)
    rep = KaimonSlate.ReportEngine.parse_report(read(path, String); id = basename(path))
    for c in rep.cells
        m = match(r"^#\s+(.+)$"m, c.source)
        c.kind == KaimonSlate.ReportEngine.MARKDOWN && m !== nothing && return String(strip(m.captures[1]))
    end
    return splitext(basename(path))[1]
end

# Rewrite a generated page only when it changes, so the preview's file watcher stays quiet.
function write_page(file, text)
    mkpath(dirname(file))
    (isfile(file) && read(file, String) == text) || write(file, text)
    return relpath(file, SRC)
end

# A notebook's page: the notebook, as Slate renders it.
placement(nb) = "```@slate ../../../notebooks/$nb\n```\n"

# The knowledge base API this site's components talk to: by default the one serving the site, on the
# same origin (`zemi` and `zemi --shared` serve both from one port); ZEMI_API names another.
kb_api = get(ENV, "ZEMI_API", "")

# Every page, unless only some are written again.
if isempty(ONLY)
    # ZEMI_SITE_NOTEBOOKS=0 leaves them out: a site of a knowledge base without the papers they cite,
    # or built where no Slate hub can render them (a paper's notebooks then go unrendered too).
    nbs = get(ENV, "ZEMI_SITE_NOTEBOOKS", "1") == "0" || !isdir(NOTEBOOKS) ? String[] : sort!(filter(endswith(".jl"), readdir(NOTEBOOKS)))
    t = time()
    notebook_pages = [notebook_title(joinpath(NOTEBOOKS, nb)) => write_page(joinpath(GENERATED, "notebooks", replace(nb, ".jl" => ".md")), placement(nb))
                      for nb in nbs]
    step_time("wrote the notebooks' pages", t)
    rm(joinpath(GENERATED, "dates"); recursive = true, force = true)       # pages of cells by date, no longer made

    # The knowledge base's pages. The search component on its index page uses the knowledge base API
    # when `zemi` is serving it and papers.json otherwise.
    # A service writes them itself before starting this build, its code already compiled (see
    # `default_site_build`), and names what it wrote in ZEMI_SITE_WRITTEN.
    t = time()
    site = haskey(ENV, "ZEMI_SITE_WRITTEN") ? KBase.site_from_json(read(ENV["ZEMI_SITE_WRITTEN"], String)) :
                                                  KBase.write_site(KBase.kb(), KB_PAGES, KB_PUBLIC)
    haskey(ENV, "ZEMI_SITE_WRITTEN") || step_time("wrote the knowledge base's pages", t)
    # Every page loads the version list from the site root. deploydocs writes the real one, so a local
    # preview gets an empty stand-in.
    write_page(joinpath(KB_PUBLIC, "versions.js"), "// The version list is written by deploydocs.\n")
    # So is the current version, by DocumenterVitepress after it bundles the site, which `zemi dev` does not.
    DEV && write_page(joinpath(KB_PUBLIC, "siteinfo.js"), "var DOCUMENTER_CURRENT_VERSION = \"dev\";\n")
    kb_page(path) = relpath(joinpath(KB_PAGES, path), SRC)
    # The records, once there are any (see `KBase.write_records_page`).
    records = site.records === nothing ? [] : ["Records" => kb_page(site.records)]
    resources = site.resources === nothing ? [] : ["Resources" => kb_page(site.resources)]
    kb_pages = ["Knowledge base" => ["Search" => kb_page(site.index), records..., "Paper of the Day" => kb_page(site.daily),
                                     "Landscape" => kb_page(site.landscape),
                                     "Topics" => kb_page(site.overview), resources..., "Authors" => kb_page(site.authors), "Missing papers" => kb_page(site.missing),
                                     "New on arXiv" => kb_page(site.watch),
                                     "Timeline" => kb_page(site.timeline), "Status" => kb_page(site.status),
                                     "Documents" => kb_page(site.manage)],
                "Code" => ["Codebases" => kb_page(site.code_index); [t => kb_page(p) for (t, p) in site.code]]]
end

# Whether the site's addresses leave out `.html` (see the config's `cleanUrls` below).
const CLEAN_URLS = false

# Registers with VitePress the knowledge base's components that its pages name (those that only other
# components use are imported by them), and ships the site's data files.
struct KnowledgeBaseSite <: Documenter.Plugin end
DocumenterVitepress.vitepress_components(::KnowledgeBaseSite) =
    [(name = n, import_path = "@/$n.vue") for n in ("KBSearch", "KBSettings", "KBUpload", "KBManager", "KBCodeTree", "KBSync", "KBLandscape",
                                                      "KBDownload", "KBBibliography", "KBMissing", "KBWatch", "KBDaily", "KBInLibraries", "KBAuthors", "KBAccount",
                                                      "KBSources", "KBServices",
                                                      "KBAccountPage", "KBOperations", "KBConfiguration", "KBLayers", "KBAdmin", "KBUpdate", "KBPalette",
                                                      "KBProjects", "KBFindings", "KBPaperPage", "KBPaperList", "KBTopics", "KBTopicPage",
                                                      "KBStatusTables", "KBCodeFilePage", "KBCodebasePage", "KBCodebases", "KBDayPage",
                                                      "KBRecordPage", "KBRecords", "KBResourcePage", "KBResources",
                                                      "KBSetup", "KBOpenSource")]
DocumenterVitepress.vitepress_assets(::KnowledgeBaseSite) = isdir(KB_PUBLIC) ? [KB_PUBLIC] : String[]
function DocumenterVitepress.vitepress_config_transform(::KnowledgeBaseSite, config::String)
    # ZEMI_SITE_BASE serves the site under a path (the demo's, `/Zemi.jl/demo/`); otherwise it is at the
    # root, as a service serves it. Set either way: on a CI service DocumenterVitepress takes the base
    # from the repository's name, for GitHub Pages. The config names the base twice.
    config = replace(config, r"base: '[^']*'" => "base: '$(get(ENV, "ZEMI_SITE_BASE", "/"))'")
    # ZEMI_SITE_NOTICE, HTML, is shown in a bar above every page: what a static copy cannot do, say.
    # It sits outside the app, so it stays as pages change, in the room VitePress keeps above its nav.
    # vp-raw keeps the router from opening its links as the site's own pages: they lead elsewhere.
    if !isempty(get(ENV, "ZEMI_SITE_NOTICE", ""))
        style = ".kb-notice{position:fixed;top:0;left:0;right:0;z-index:100;padding:6px 16px;text-align:center;" *
                "font-size:13px;line-height:1.5;background:var(--vp-c-warning-soft);color:var(--vp-c-text-1)}" *
                ".kb-notice a{color:var(--vp-c-brand-1);text-decoration:underline}"
        script = "document.addEventListener('DOMContentLoaded',()=>{const d=document.createElement('div');" *
                 "d.className='kb-notice vp-raw';d.innerHTML=$(KBase.JSON.json(ENV["ZEMI_SITE_NOTICE"]));document.body.prepend(d);" *
                 "const h=()=>document.documentElement.style.setProperty('--vp-layout-top-height',d.offsetHeight+'px');" *
                 "h();addEventListener('resize',h)})"
        config = replace(config, "head: [" => "head: [\n    ['style', {}, $(KBase.JSON.json(style))],\n    ['script', {}, $(KBase.JSON.json(script))],"; count = 1)
    end
    # Page links end in .html: LiveServer (behind zemi) and plain static hosts do not map a clean
    # URL like /generated/kb/timeline to timeline.html, so a clean URL only loads through the router.
    config = replace(config, "cleanUrls: true," => "cleanUrls: $CLEAN_URLS,")
    # The site's search box finds papers by title only, the timeline and topic lists (lists of those
    # titles) by their headings, and code pages without their collapsed source: the knowledge base's
    # own search covers the text, and indexing it here would grow the index by megabytes.
    search = "detailedView: true"
    occursin(search, config) || @warn "No `$search` in the VitePress config; paper text stays in the site search index"
    config = replace(config, search => search * raw""",
        _render(src, env, md) {
          const path = env.relativePath
          const headings = (re) => (src.match(re) ?? []).join('\n\n')
          if (path.startsWith('generated/kb/papers/'))
            src = headings(/^# .*$/m)
          else if (path.startsWith('generated/kb/topics') || path.startsWith('generated/kb/timeline'))
            src = headings(/^#{1,3} .*$/gm)
          else if (path.startsWith('generated/kb/'))
            src = src.replace(/^::: details[^\n]*\n[\s\S]*?^:::[ \t]*$/gm, '')
          return md.render(src, env)
        }"""; count = 1)
    # A paper page's bundle carries the paper's whole text, so a long paper passes Vite's 500 kB
    # warning, which is meant for application code; the limit is raised to leave room for them.
    # Every page but the home page is generated (from the knowledge base or the notebooks), so an
    # "Edit this page" link would lead to a file that the next build overwrites.
    config = replace(config, r"^\s*editLink: \{[^\n]*\},?\n"m => "")
    # The template's GitHub link would lead every knowledge base's site to the package's repository.
    config = replace(config, r"^\s*socialLinks: \[[^\]]*\],?\n"m => "")
    vite = "vite: {"
    occursin(vite, config) || @warn "No `$vite` in the VitePress config; Vite keeps its chunk size warning at 500 kB"
    config = replace(config, vite => vite * "\n    build: { chunkSizeWarningLimit: 2000 },"; count = 1)
    if DEV
        target = repr(get(ENV, "ZEMI_DEV_API", "http://127.0.0.1:8000"))
        # Folders, with their slash, so a page's own files (authors.json) stay the development server's.
        config = replace(config, vite => vite * "\n    server: { proxy: { '/api/': $target, '/auth/': $target, '^/mcp(\\\\?|\$)': $target } },"; count = 1)
    end
    # The components read the knowledge base API's address from `__KB_API__`, link to the site's pages
    # as the config has them (kbLinks.ts), and know the pages made from a template (kbTemplates.ts)
    # from `KBase.TEMPLATED`.
    define = "define: {"
    occursin(define, config) || error("No `$define` in the VitePress config to give the components the knowledge base API's address")
    templates = [Dict("name" => k, "folder" => t.folder, "template" => t.template) for (k, t) in KBase.TEMPLATED]
    config = replace(config, define => define * "\n      __KB_API__: JSON.stringify($(repr(kb_api)))," *
                                                 "\n      __KB_CLEAN_URLS__: $CLEAN_URLS," *
                                                 "\n      __KB_TEMPLATES__: JSON.stringify($(KBase.JSON.json(templates)))," *
                                                 "\n      __KB_TEMPLATE_COPY__: JSON.stringify($(repr(KBase.TEMPLATE_COPY))),"; count = 1)
    # A heading's anchor keeps the heading's characters, and a paper's section title may hold a "%"
    # ("5% β"), which VitePress decodes as a URL escape and fails the build on. A "%" that is not an
    # escape is written as one ("%25") before VitePress reads the link; browsers decode it back.
    hook = "config(md) {"
    occursin(hook, config) || error("No `$hook` in the VitePress config to make heading links safe in")
    config = replace(config, hook => hook * "\n      " * raw"""
          const link = md.renderer.rules.link_open
          md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
            const href = tokens[idx].attrGet('href')
            if (href) tokens[idx].attrSet('href', href.replace(/%(?![0-9A-Fa-f]{2})/g, '%25'))
            return link ? link(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options)
          }
          // Inline code is shown as it is, never compiled as part of the page's Vue template (VitePress
          // does this for code blocks only), so text quoted in it cannot run as an expression.
          const inline = md.renderer.rules.code_inline
          md.renderer.rules.code_inline = (tokens, idx, options, env, self) =>
            inline(tokens, idx, options, env, self).replace(/^<code/, '<code v-pre')"""; count = 1)
    # A formula in a paper's text cannot link to a script, or lay itself over the page: MathJax here
    # loads `\href` and `\style` as formulas ask for them, so its output is filtered as the knowledge
    # base's own renderer filters it (kbMarkdown.ts).
    mathjax = "mathjax.markdownConfig(md);"
    occursin(mathjax, config) || error("No `$mathjax` in the VitePress config to make formulas safe after")
    config = replace(config, mathjax => mathjax * raw"""
          for (const rule of ['math_inline', 'math_block']) {
            const made = md.renderer.rules[rule]
            if (made) md.renderer.rules[rule] = (tokens, idx, options, env, self) =>
              made(tokens, idx, options, env, self)
                .replace(/\s(?:xlink:)?href\s*=\s*"(?!https?:|mailto:|#)[^"]*"/gi, '')
                .replace(/style="([^"]*)"/gi, (_, css) =>
                  `style="${css.split(';').filter(d => !/^\s*(position\s*:\s*(fixed|absolute)|z-index\s*:)/i.test(d)).join(';')}"`)
          }"""; count = 1)
    # Code pages show files as they are, and a file may name a local server's address
    # (http://localhost:8000), which VitePress would otherwise count as a dead link.
    start = "defineConfig({"
    occursin(start, config) || error("No `$start` in the VitePress config to allow links to localhost in")
    # Pages made from a template (see `KBase.TEMPLATED`) are files the build writes after VitePress
    # runs, so links to them are not dead; their stub pages are only for Documenter to resolve links
    # against, and the development server to build.
    templated = join(("'$(last(t).folder)/*.md'" for t in KBase.TEMPLATED), ", ")
    links = join(("/(^|\\/)$(basename(last(t).folder))\\/[^\\/]+\$/" for t in KBase.TEMPLATED), ", ")
    config = replace(config, start => start * "\n  ignoreDeadLinks: [url => /^(?:[a-z]+:)?\\/\\/localhost/i.test(url), $links]," *
                                              (DEV ? "" : "\n  srcExclude: [$templated],"); count = 1)
    # The map of every page's script, and the site's data, in one script the browser caches, rather
    # than written into every page: with a page per paper it is a quarter of the site.
    config = replace(config, start => start * "\n  metaChunk: true,"; count = 1)
    # No version picker: the site is built from one version, the knowledge base as it is now.
    picker = r"\{\s*component:\s*'VersionPicker'\s*\},?"
    occursin(picker, config) || @warn "No VersionPicker in the VitePress config's nav"
    config = replace(config, picker => ""; count = 1)
    # No previous and next page links: the sidebar's order is not a reading order. A page that has one
    # sets `prev` and `next` in its front matter.
    # The footer names what the site is built with, and leads to the open source it runs on.
    base = something(match(r"base: '([^']*)'", config), (; captures = ["/"])).captures[1]
    footer = r"footer: \{\s*message: '[^']*',"
    occursin(footer, config) || @warn "No footer message in the VitePress config to replace"
    config = replace(config, footer => "docFooter: { prev: false, next: false },\n    footer: {\n      message: 'Built with " *
        "<a href=\"https://github.com/kahliburke/Zemi.jl\">Zemi</a> and <a href=\"https://github.com/kahliburke/KaimonSlate.jl\">Kaimon Slate</a>" *
        " · <a href=\"$(rstrip(base, '/'))/open-source$(CLEAN_URLS ? "" : ".html")\">Open source</a>',"; count = 1)
    # Open source ends the sidebar, not the top bar: the top bar is for the knowledge base's parts.
    opensource = r"\{\s*text:\s*'Open source',\s*link:\s*'[^']*'\s*\},?\s*"
    occursin(opensource, config) || @warn "No Open source entry in the VitePress config's nav"
    config = replace(config, opensource => ""; count = 1)
    marker = "...navTemp.nav,"
    occursin(marker, config) || (@warn "No `$marker` in the VitePress config; the search settings button is left out"; return config)
    # The palette (Cmd-K) is in the top bar so that it is on every page; it shows nothing until opened.
    return replace(config, marker => marker * "\n  { component: 'KBSettings' },\n  { component: 'KBAccount' },\n  { component: 'KBUpdate' },\n  { component: 'KBPalette' },"; count = 1)
end

# The service's own pages (service/*.md) are built but not listed: the top bar's menu (KBAccount.vue)
# leads to those the person's roles open.
pages = !isempty(ONLY) ? ONLY :
    ["Home" => "index.md", kb_pages..., "Projects" => "projects.md", "Findings" => "findings.md",
     (isempty(notebook_pages) ? [] : ["Notebooks" => notebook_pages])..., "Open source" => "open-source.md"]

# The site's packages, beside the build folder (the development server's are written as it starts).
const BUILD = get(ENV, "ZEMI_SITE_BUILD", "build")
DEV || KBase.site_packages!(dirname(isabspath(BUILD) ? BUILD : joinpath(DOCS, BUILD)))

# Notebook bundles are build output (git-ignored, under docs/slate/): each build renders a notebook
# whose bundle is missing or older than the notebook, through the Slate hub on this machine.
t_docs = time()
makedocs(;
    root = DOCS,
    # The development server keeps serving the folder while the pages are written again.
    clean = !DEV,
    sitename = get(ENV, "ZEMI_SITE_TITLE", "Zemi"),
    # The shared service builds each version of the site into a folder of its own (see `build_site!`).
    build = BUILD,
    # Outside CI there is nothing to deploy: saying so directly spares the warning Documenter gives
    # when it cannot find a CI system to ask.
    format = MarkdownVitepress(; repo = "github.com/kahliburke/Zemi.jl", devbranch = "main",
                               devurl = "dev", build_vitepress = !DEV,
                               deploy_decision = haskey(ENV, "CI") ? nothing : Documenter.DeployDecision(; all_ok = false)),
    # `never`: the notebooks' bundles as the dataset brought them (see src/site_publish.jl).
    plugins = [SlateDocs(; render = Symbol(get(ENV, "ZEMI_SLATE_RENDER", "auto"))), KnowledgeBaseSite()],
    remotes = nothing,
    pages,
    pagesonly = !isempty(ONLY),
    warnonly = !isempty(ONLY),
)
step_time("ran Documenter and VitePress", t_docs)
# Each templated page, a copy of its kind's built template.
if !DEV
    site_dir = joinpath(isabspath(BUILD) ? BUILD : joinpath(DOCS, BUILD), "1")
    t = time()
    n = KBase.stamp_templates!(site_dir)
    step_time("copied the templates to $n pages", t)
end
