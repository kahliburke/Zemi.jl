# ── zemi dev ───────────────────────────────────────────────────────────────────────────────────────
# The knowledge base for developing it: the API from this process, with Revise applying changes to
# the code, and the site from VitePress's development server, which compiles a page when it is
# opened and puts an edited component into the open page at once. The pages are written without
# bundling, and when the knowledge base changes, the pages that change are written again. Full
# builds are for `zemi` and `zemi --shared`.

"Where `zemi dev` writes its pages, and the development server's packages."
dev_dir(c::Config) = joinpath(site_root(c), "dev")

"The development server's address, which the API server sends requests for pages to."
const DEV_URL = Ref("")
const DEV_SERVER = Ref{Union{Base.Process,Nothing}}(nothing)
# The process writing changed pages (docs/dev_writer.jl), started when first needed.
const PAGE_WRITER = Ref{Union{Base.Process,Nothing}}(nothing)

"""
    write_dev_pages!(kb; api, all = true)

Write the site's pages for the development server into [`dev_dir`](@ref), without bundling them, with
the development server forwarding the API to `api`.
The components and the theme's styles are links to the checkout's, so the development server puts
their edits into the open page; the knowledge base's data folders are links to where it writes them
(see [`link_public!`](@ref)), and pages whose sources are gone are removed (see [`prune_pages!`](@ref)). Unless `all`, only what the knowledge base changed is written again
(see [`write_changed_pages!`](@ref)).
"""
function write_dev_pages!(kb::KB; api::AbstractString, all::Bool = true)
    docs = joinpath(pkgdir(@__MODULE__), "docs")
    install_docs_env(kb.config)
    dir = dev_dir(kb.config)
    md = joinpath(dir, "build", ".documenter")
    all || !isdir(md) || return write_changed_pages!(kb, docs, dir, md; api)
    sources = site_sources(kb.config, joinpath(dir, "docs"))
    t0 = time()
    run_make(kb.config, dir, Dict("ZEMI_SITE_BUILD" => joinpath(dir, "build"), "ZEMI_SITE_DOCS" => sources); api)
    link_sources!(docs, md)
    link_public!(joinpath(sources, "kb_public"), joinpath(md, "public"))
    pruned = prune_pages!(joinpath(sources, "src"), md)
    pruned > 0 && @info "[dev] Removed $pruned page(s) whose sources are gone"
    @info "[dev] Pages written in $(duration(time() - t0))"
end

"""
    write_changed_pages!(kb, docs, dir, md; api)

Write again into the pages `md` the development server serves only what the knowledge base changed:
its pages are written here, by a process that has them compiled already, into the sources the last
full writing left in `dir`, noting the files that change; the page writer (docs/dev_writer.jl) then
puts just those pages through Documenter, from a folder holding only them, and they are copied into
`md` for the development server to put into the open page.
"""
function write_changed_pages!(kb::KB, docs::AbstractString, dir::AbstractString, md::AbstractString;
                              api::AbstractString)
    t0 = time()
    src = joinpath(dir, "docs", "src")
    public = joinpath(dir, "docs", "kb_public")
    written, removed = diff_site_pages!(kb, src, public)
    foreach(rel -> rm(joinpath(md, rel); force = true), removed)
    pages = filter(endswith(".md"), written)
    for rel in setdiff(written, pages)
        mkpath(dirname(joinpath(md, rel)))
        cp(joinpath(src, rel), joinpath(md, rel); force = true)
    end
    if !isempty(pages)
        only = joinpath(dir, "changed")
        rm(only; recursive = true, force = true)
        for rel in pages
            mkpath(dirname(joinpath(only, "src", rel)))
            cp(joinpath(src, rel), joinpath(only, "src", rel))
        end
        # The paths the pages reach the notebooks by, as in the full sources.
        link_dir(content_path(kb.config, "notebooks"), joinpath(only, "notebooks"))
        link_dir(slate_dir(kb.config), joinpath(only, "slate"))
        list = joinpath(only, "pages.txt")
        write(list, join(pages, "\n"))
        write_pages(kb.config, dir, Dict("ZEMI_SITE_BUILD" => joinpath(only, "build"), "ZEMI_SITE_DOCS" => only,
                                    "ZEMI_SITE_PAGES" => list); api)
        for rel in pages
            mkpath(dirname(joinpath(md, rel)))
            cp(joinpath(only, "build", ".documenter", rel), joinpath(md, rel); force = true)
        end
        rm(only; recursive = true, force = true)
    end
    n = length(written) + length(removed) + link_public!(public, joinpath(md, "public"))
    @info "[dev] $n changed file(s) written in $(duration(time() - t0))"
    return n
end

make_env(c::Config, env::Dict; api) = merge(slate_env(c), Dict("ZEMI_SITE_DEV" => "1", "ZEMI_DEV_API" => api, "ZEMI_API" => "",
                                                 "ZEMI_SITE_TITLE" => site_title(c)), env)

"The package's `docs/` folder, where the site's build scripts are."
package_docs() = joinpath(pkgdir(@__MODULE__), "docs")

"Run docs/make.jl for `zemi dev` in a process of its own, with `env` added to the environment, its output in `dir`/pages.log."
function run_make(c::Config, dir::AbstractString, env::Dict; api::AbstractString)
    open(joinpath(dir, "pages.log"), "w") do io
        run_logged(setenv(`$(Base.julia_cmd()) --project=$(site_env(c)) $(joinpath(package_docs(), "make.jl"))`,
                          build_env(make_env(c, env; api))), io) ||
            error("Writing the pages failed; see $(joinpath(dir, "pages.log"))")
    end
end

"The page writer, started if it is not running, its output in `dir`/writer.log."
function page_writer(c::Config, dir::AbstractString)
    p = PAGE_WRITER[]
    p === nothing || process_exited(p) || return p
    cmd = Cmd(`$(Base.julia_cmd()) --project=$(site_env(c)) $(joinpath(package_docs(), "dev_writer.jl"))`; detach = true)
    # The writer has a handle of its own on its log; this one is closed once it has started.
    return PAGE_WRITER[] = open(log -> open(pipeline(setenv(cmd, build_env()); stderr = log), "r+"), joinpath(dir, "writer.log"), "a")
end

"Run docs/make.jl for `zemi dev` in the [`page_writer`](@ref)."
function write_pages(c::Config, dir::AbstractString, env::Dict; api::AbstractString)
    p = page_writer(c, dir)
    println(p, join(("$k=$v" for (k, v) in make_env(c, env; api)), '\t'))
    answer = readline(p)
    answer == "ok" || error("Writing the pages failed ($(isempty(answer) ? "the page writer stopped" : answer)); see $(joinpath(dir, "writer.log"))")
end

"""
    diff_site_pages!(kb, src, public) -> (written, removed)

Write the knowledge base's pages into the docs source folder `src` (and its public files into
`public`), as the site's build does, and say which files under `src` changed: those `written` and
those `removed`, as paths relative to it.
"""
function diff_site_pages!(kb::KB, src::AbstractString, public::AbstractString)
    pages_dir = joinpath(src, "kb")
    # A file is only written when it changes, so its time says whether it did.
    files() = isdir(pages_dir) ? Dict(joinpath(root, f) => mtime(joinpath(root, f)) for (root, _, fs) in walkdir(pages_dir) for f in fs) :
                                 Dict{String,Float64}()
    before = files()
    write_site(kb, pages_dir, public)
    after = files()
    return (sort!([relpath(f, src) for (f, t) in after if get(before, f, nothing) != t]),
            sort!([relpath(f, src) for f in keys(before) if !haskey(after, f)]))
end

"""
    link_public!(public, to) -> Int

The knowledge base's files at the site's root (`public`, docs/make.jl's `KB_PUBLIC`) in the
development server's `public` folder `to`: each folder linked rather than copied (a paper's or a
codebase file's data, thousands of them), each file copied where it differs. Returns how many
were copied or linked.
"""
function link_public!(public::AbstractString, to::AbstractString)
    n = 0
    mkpath(to)
    for entry in readdir(public)
        from, at = joinpath(public, entry), joinpath(to, entry)
        if isdir(from)
            islink(at) && link_target(at) == abspath(from) && continue
            rm(at; recursive = true, force = true)
            link_dir(from, at)
        else
            isfile(at) && !islink(at) && filesize(from) == filesize(at) && read(from) == read(at) && continue
            cp(from, at; force = true)
        end
        n += 1
    end
    return n
end

"""
Remove from the development server's pages `md` the knowledge base's pages (`kb/`, and the older
`generated/`) whose sources under `src` are gone: the documentation build adds and replaces pages,
and leaves those of a paper since removed, or of a path no longer written.
"""
function prune_pages!(src::AbstractString, md::AbstractString)
    n = 0
    for dir in ("kb", "generated")
        isdir(joinpath(md, dir)) || continue
        for (root, _, files) in walkdir(joinpath(md, dir); topdown = false)
            for f in files
                rel = relpath(joinpath(root, f), md)
                isfile(joinpath(src, rel)) || (rm(joinpath(md, rel)); n += 1)
            end
            isempty(readdir(root)) && rm(root)
        end
    end
    return n
end

"""
Replace the copies of the checkout's components and theme styles in the pages folder `md` with links
to them, and link ones added since. Links already in place are left alone. The service worker is
linked into the public files, as the service serves it at the site's root and a page registers one
only from its own origin, which here is the development server's.
"""
function link_sources!(docs::AbstractString, md::AbstractString)
    pairs = [[joinpath(docs, "src", "components", f) => joinpath(md, "components", f) for f in readdir(joinpath(docs, "src", "components"))];
             [joinpath(docs, "src", ".vitepress", "theme", f) => joinpath(md, ".vitepress", "theme", f)
              for f in readdir(joinpath(docs, "src", ".vitepress", "theme"))];
             SERVICE_WORKER => joinpath(md, "public", basename(SERVICE_WORKER))]
    for (from, to) in pairs
        isfile(from) || continue
        islink(to) && link_target(to) == from && continue
        mkpath(dirname(to))
        rm(to; force = true)
        link_file(from, to)
    end
end

"""
Julia code that ends its process's group once process `ARGS[end]` is no longer its parent, checking
every two seconds (not on Windows, where a group ends with the console).
"""
const ENDS_WITH_PARENT = """
    Sys.iswindows() || let parent = parse(Int, ARGS[end])
        @async while true
            sleep(2)
            ccall(:getppid, Cint, ()) == parent || (ccall(:kill, Cint, (Cint, Cint), 0, 15); exit(0))
        end
    end
    """

"""
What runs the development server (see [`start_dev_server!`](@ref)), given the pages, the port, and
the process that starts it: once that process is gone, its group ends (see [`ENDS_WITH_PARENT`](@ref)),
VitePress with it, so a service killed outright leaves no server behind, watching the pages.
"""
const DEV_SERVER_SCRIPT = ENDS_WITH_PARENT * """
    import DocumenterVitepress, Zemi
    Zemi.vitepress(DocumenterVitepress.node, ARGS[1], "dev", "--port", ARGS[2], "--strictPort"; install = false)
    """

"""
Start VitePress's development server on the pages, at `port`, in a process group of its own, the
site's packages installed beside them first when they are not (see [`site_packages!`](@ref)):
DocumenterVitepress installs none when it finds a `package.json`. The group ends itself once this
process is gone, stopped without stopping it (see [`DEV_SERVER_SCRIPT`](@ref)).
"""
function start_dev_server!(c::Config; port::Integer)
    # Taken, the server would stop at once (it is held to its port) while the pages led to whatever has it.
    in_use = try close(Sockets.connect(ip"127.0.0.1", port)); true catch; false end
    in_use && error("Port $port is in use, and the development server needs it: free it, or choose another with ZEMI_DEV_PORT")
    build = joinpath(dev_dir(c), "build")
    site_packages!(dev_dir(c))
    cmd = setenv(`$(Base.julia_cmd()) --project=$(site_env(c)) -e $DEV_SERVER_SCRIPT $build $port $(getpid())`, build_env())
    log = joinpath(dev_dir(c), "server.log")
    p = DEV_SERVER[] = run(pipeline(Cmd(cmd; detach = true); stdout = log, stderr = log); wait = false)
    DEV_URL[] = "http://localhost:$port"
    # Stopping by itself, it says why at the end of its log.
    Threads.@spawn (wait(p); p === DEV_SERVER[] && !success(p) &&
                    @error "[dev] The development server stopped; the end of its log:\n" * join(last(readlines(log), 15), "\n"))
    return p
end

"The newest time any file under `paths` (a file, or a folder) was changed, for `keep`'s files."
function newest(paths; keep = _ -> true)
    files(p) = isdir(p) ? (joinpath(r, f) for (r, _, fs) in walkdir(p) for f in fs) : (p,)
    return maximum((mtime(f) for p in paths for f in files(p) if keep(f) && isfile(f)); init = 0.0)
end

"""
What the pages are written by besides the knowledge base: docs/make.jl and the checkout's own pages
(`site`), and the package's code (`code`).
"""
dev_sources(docs::AbstractString) =
    (site = () -> newest([joinpath(docs, "make.jl"), joinpath(docs, "src")];
                         keep = f -> endswith(f, ".md") && first(splitpath(relpath(f, joinpath(docs, "src")))) ∉ ("generated", "kb")),
     code = () -> newest([joinpath(dirname(docs), "src")]; keep = endswith(".jl")))

"The port VitePress's development server takes for `zemi dev`: `ZEMI_DEV_PORT`, else `[service] dev_port`."
dev_server_port(c::Config) = parse(Int, get(ENV, "ZEMI_DEV_PORT", string(c.service.dev_port)))

"""
    start_dev!(kb; api, dev_port = dev_server_port(kb.config)) -> stop

For a server already answering the API at `api`: write the pages, start the development server on
`dev_port`, and write again the pages the knowledge base changes when it does, or every page when
the settings change the site's look or docs/make.jl or the checkout's own pages change. When the
package's code changes, the pages it changes are written again, with the code as Revise applies it
here and a page writer started afresh. Returns a function that stops the development server.
"""
function start_dev!(kb::KB; api::AbstractString, dev_port::Integer = dev_server_port(kb.config))
    c = kb.config
    DEV_URL[] = "http://localhost:$dev_port"
    @info "[dev] Writing the pages, without bundling"
    write_dev_pages!(kb; api)
    start_dev_server!(c; port = dev_port)
    @info "Knowledge base for development at $(DEV_URL[]) (the API at $api; the server's log: $(joinpath(dev_dir(c), "server.log")))"
    # One writing at a time, the development server serving throughout: the changed pages when the
    # knowledge base changes, every page when what the whole site is written from changes.
    again = Channel{Nothing}(1)
    full, recode = Ref(false), Ref(false)
    ask(every = false; code = false) = (full[] |= every; recode[] |= code; isready(again) || put!(again, nothing))
    # Every page is written again when the build stamp moves too: the settings changed the site's
    # title, front page or images (see `rebuild_site!`).
    stamp, rebuild = changes_stamp(c), build_stamp(c)
    seen, rebuilt = Ref(mtime(stamp)), Ref(mtime(rebuild))
    docs, md = joinpath(pkgdir(@__MODULE__), "docs"), joinpath(dev_dir(c), "build", ".documenter")
    sources = dev_sources(docs)
    site_at, code_at = Ref(sources.site()), Ref(sources.code())
    WATCHER[] = Timer(2; interval = 2) do _
        try link_sources!(docs, md) catch e; @error "[dev] Linking the components failed" exception = e end
        mtime(rebuild) != rebuilt[] && (rebuilt[] = mtime(rebuild); ask(true))
        mtime(stamp) != seen[] && (seen[] = mtime(stamp); ask())
        (t = sources.site()) != site_at[] && (site_at[] = t; ask(true))
        (t = sources.code()) != code_at[] && (code_at[] = t; ask(; code = true))
    end
    @async for _ in again
        every, code = full[], recode[]
        full[] = recode[] = false
        if code
            revise_code()
            w = PAGE_WRITER[]
            w === nothing || process_exited(w) || terminate(getpid(w); group = true, what = "The page writer", seconds = 5)
        end
        try Base.invokelatest(write_dev_pages!, kb; api, all = every) catch e; @error "[dev] Writing the pages failed" exception = e end
    end
    # Writing the changed pages once now has it compiled, here and in the page writer, before the
    # knowledge base first changes.
    page_writer(c, dev_dir(c))
    ask()
    return function ()
        p = DEV_SERVER[]
        p === nothing || process_exited(p) || terminate(getpid(p); group = true, what = "The development server", seconds = 5)
        w = PAGE_WRITER[]
        w === nothing || process_exited(w) || terminate(getpid(w); group = true, what = "The page writer", seconds = 5)
    end
end
