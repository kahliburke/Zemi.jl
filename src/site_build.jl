# The site's builds: in a process of its own, into a new folder each, switched to in one step, so the
# site served never goes down while it builds; pages opened before a switch still find the old
# build's assets.

"""
Where the shared service keeps its builds of the site, and the `current` link to the one it serves:
by its real path (see [`real_path`](@ref)), since VitePress takes each page's address relative to
the folder it builds in after resolving the page's file through links.
"""
site_root(c::Config) = real_path(joinpath(c.data_dir, "site"))

"`path` with its links resolved, as far as it exists."
real_path(path::AbstractString) = ispath(path) ? realpath(path) :
    (d = dirname(path); d == path ? path : joinpath(real_path(d), basename(path)))
builds_dir(c::Config) = joinpath(site_root(c), "builds")
current_link(c::Config) = joinpath(site_root(c), "current")

"The build being served, as a folder, or `nothing` before the first."
current_site(c::Config) = (l = current_link(c); islink(l) ? readlink(l) : nothing)

"How the site's builds stand: one running, one asked for meanwhile, the last error, the build served."
Base.@kwdef mutable struct SiteState
    building::Bool = false
    again::Bool = false
    started::Union{DateTime,Nothing} = nothing
    finished::Union{DateTime,Nothing} = nothing
    error::Union{String,Nothing} = nothing
    id::String = ""
end
const SITE = SiteState()
const SITE_LOCK = ReentrantLock()

"""
    build_site!(c; build = default_site_build) -> String

Build the site into a new folder under [`builds_dir`](@ref) and, when it builds, serve it: the
`current` link is replaced in one step, so a request is answered from the old build or the new,
never from one half written. Returns the build's id. `build(out, log)` builds the site into `out`;
by default, `docs/make.jl` in a Julia process of its own.
"""
function build_site!(c::Config; build = default_site_build)
    # Named by the second it starts, after any build of the same second: what it leaves is its own.
    builds = mkpath(builds_dir(c))
    id, out = "", ""
    while true
        id = Dates.format(now(UTC), dateformat"yyyymmddTHHMMSS")
        out = joinpath(builds, id)
        ispath(out) || ispath(out * ".log") || break
        sleep(0.2)
    end
    log = out * ".log"
    t0 = time()
    @info "[site] Building $id (log: $log)"
    # What it is built from, for publishing it (see site_publish.jl).
    record = Dict("build" => id, "sources" => site_source_digest(c), "shared" => SHARED_MODE[])
    try
        build(out, log)
        site = joinpath(out, "1")
        isfile(joinpath(site, "index.html")) || error("The site build made no index.html")
    catch
        tail = isfile(log) ? join(last(readlines(log), 15), "\n") : ""
        isempty(tail) || @error "[site] Build $id failed; the end of its log:\n$tail"
        rm(out; recursive = true, force = true)                    # its log stays, to read why
        rethrow()
    end
    write(out * ".json", JSON.json(record))
    switch_site!(c, joinpath(out, "1"))
    lock(() -> SITE.id = id, SITE_LOCK)
    # What changed while it was built shows in it too.
    request_refresh!(c)
    prune_builds!(c)
    @info "[site] Built in $(duration(time() - t0)); serving $id"
    return id
end

"A span of seconds as people read it: `3 min 20 s`."
duration(s::Real) = s < 60 ? "$(round(Int, s)) s" : "$(floor(Int, s / 60)) min $(round(Int, s % 60)) s"

# The lines of a build's output worth showing as it runs: Documenter's and DocumenterSlate's steps,
# VitePress's, and anything that went wrong. The rest goes to the build's log only.
const BUILD_STAGE = r"^\[ Info: (SiteStep|SetupBuildDirectory|Doctest|ExpandTemplates|CrossReferences|CheckDocument|Populate|RenderDocument|DocumenterVitepress|render_doc_bundle|SlateDocs)|vitepress v|building client|rendering pages|build complete|^(┌ )?(Warning|Error)|ERROR"

"Run `cmd`, its output to `io` and its stage lines (see `BUILD_STAGE`) to the log as it goes."
function run_logged(cmd::Cmd, io::IO; pid_file = nothing)
    out = Pipe()
    # In a process group of its own, so stopping it stops what it starts (the Node process that
    # bundles the site), and a Ctrl-C in the terminal is left to the service to pass on.
    p = run(pipeline(Cmd(cmd; detach = true); stdout = out, stderr = out); wait = false)
    close(out.in)
    BUILD_PROCESS[] = p
    pid_file === nothing || write(pid_file, string(getpid(p)))
    reader = @async for line in eachline(out)
        println(io, line); flush(io)
        clean = replace(line, r"\e\[[0-9;]*m" => "")
        occursin(BUILD_STAGE, clean) && @info "[site] " * strip(replace(clean, r"^\[ Info: " => ""))
    end
    try
        wait(p); wait(reader)
    finally
        BUILD_PROCESS[] = nothing
        pid_file === nothing || rm(pid_file; force = true)
    end
    return success(p)
end

"Point the `current` link at `site`, replacing it in one step (a rename)."
function switch_site!(c::Config, site::AbstractString)
    tmp = current_link(c) * ".new"
    ispath(tmp) && rm(tmp)
    symlink(site, tmp)
    Base.Filesystem.rename(tmp, current_link(c))
end

"The site build running, so stopping the service can stop it too."
const BUILD_PROCESS = Ref{Union{Base.Process,Nothing}}(nothing)

"""
The environment for the Julia processes that build the site: this process's, less what pins it to an
environment of its own (an installed app's launcher sets `JULIA_LOAD_PATH` to just the app's), so a
build finds the docs environment and the standard library.
"""
function build_env(extra = Dict{String,String}())
    env = Dict{String,String}(k => v for (k, v) in ENV if !(k in ("JULIA_LOAD_PATH", "JULIA_PROJECT")))
    return merge(env, extra)
end

"The file holding the process id of the site build running in `builds`, to stop one a previous run left behind."
build_pid_file(builds::AbstractString) = joinpath(builds, "building.pid")

"""
    reap_stale_build!(c)

Stop the site build a previous run of the service left running (one killed outright leaves its
build going), and what it started.
"""
reap_stale_build!(c::Config) =
    reap_pid_file!(build_pid_file(builds_dir(c)); matches = pid -> occursin("make.jl", process_command(pid)),
                   what = "[site] the site build", group = true, seconds = 10)

"The docs environments this process has installed, the site is built in."
const DOCS_READY = Set{String}()

"The heap, in MB, of the Node process that bundles the site."
const SITE_NODE_HEAP_MB = 12288

"""
    site_env(config) -> String

The Julia environment the site is built in, in the knowledge base's site folder: the package's
`docs/Project.toml`, with this copy of the package in it by path. The package's own folder is never
written to, so an installed package (read-only) builds its site as a checkout does.
"""
site_env(c::Config) = joinpath(site_root(c), "env")

"""
    install_docs_env(config) -> String

Install the site's environment (see [`site_env`](@ref)), once in a process, and return its folder.
Resolved first: dependencies the package has gained since its manifest was written are installed only
by resolving. Where the manifest holds a version the project's compat no longer allows, it is updated.
"""
function install_docs_env(c::Config)
    env = site_env(c)
    env in DOCS_READY && return env
    @info "[site] Installing the docs environment"
    mkpath(env)
    project = TOML.parsefile(joinpath(pkgdir(@__MODULE__), "docs", "Project.toml"))
    project["sources"]["Zemi"] = Dict("path" => pkgdir(@__MODULE__))
    text = sprint(io -> TOML.print(io, project))
    file = joinpath(env, "Project.toml")
    (isfile(file) && read(file, String) == text) || write(file, text)
    run(setenv(`$(Base.julia_cmd()) --project=$env -e "using Pkg; try Pkg.resolve() catch; Pkg.update() end; Pkg.instantiate()"`, build_env()))
    push!(DOCS_READY, env)
    return env
end

"""
    slate_env(c) -> Dict

What a site build is told of the Slate hub its notebooks render through: the port `[notebooks]
slate_port` names, else `KAIMONSLATE_PORT` in this process's environment; neither, KaimonSlate's own.
"""
function slate_env(c::Config)
    port = c.slate_port > 0 ? string(c.slate_port) : get(ENV, "KAIMONSLATE_PORT", "")
    return isempty(port) ? Dict{String,String}() : Dict("KAIMONSLATE_PORT" => port)
end

"Builds the site in a Julia process of its own, the API on the same origin as the pages."
function default_site_build(out::AbstractString, log::AbstractString)
    docs = joinpath(pkgdir(@__MODULE__), "docs")
    c = kb().config
    env_dir = install_docs_env(c)
    # Notebooks render through the same Slate hub as under zemi.
    # VitePress bundles every page in one Node process, past Node's default heap for a large
    # knowledge base; options set in the environment are kept.
    node = strip(get(ENV, "NODE_OPTIONS", "") * " --max-old-space-size=$SITE_NODE_HEAP_MB")
    env = build_env(merge(slate_env(c), Dict("ZEMI_SITE_BUILD" => out, "ZEMI_API" => "",
                               "ZEMI_BUILD_T0" => string(time()),
                               "NODE_OPTIONS" => node,
                               # The notebooks as published, rather than run, when each is the one rendered.
                               "ZEMI_SITE_TITLE" => site_title(c),
                               "ZEMI_SLATE_RENDER" => published_renders_current(c) ? "never" : "auto")))
    sources = out * ".docs"
    try
        site_sources(c, sources)
        env["ZEMI_SITE_DOCS"] = sources
        # The knowledge base's pages are written here, where their code is compiled already: a build
        # process of its own would compile it first, which takes longer than writing them.
        t = time()
        site = write_site(kb(), joinpath(sources, "src", "generated", "kb"), joinpath(sources, "kb_public"))
        @info "[site] SiteStep: wrote the knowledge base's pages in $(round(time() - t; digits = 1)) s"
        env["ZEMI_SITE_WRITTEN"] = joinpath(sources, "site.json")
        write(env["ZEMI_SITE_WRITTEN"], site_json(site))
        cmd = setenv(`$(Base.julia_cmd()) --project=$env_dir $(joinpath(docs, "make.jl"))`, env)
        open(log, "w") do io
            run_logged(cmd, io; pid_file = build_pid_file(dirname(out))) || error("The site build failed; see $log")
        end
    finally
        rm(sources; recursive = true, force = true)
    end
end

"""
    site_sources(config, dir) -> dir

A folder laid out like the package's `docs` for one build to write its pages into: a copy of the
package's `docs/src` without pages written by earlier builds, with the content's own pages and images
over it (see [`content_path`](@ref)), and a front page from the group (see [`front_page`](@ref))
where the content has none; `notebooks`, the content's, which the pages reach by relative paths; and
`slate`, the notebooks' rendered bundles that builds share (see [`slate_dir`](@ref)).
"""
function site_sources(c::Config, dir::AbstractString)
    docs = joinpath(pkgdir(@__MODULE__), "docs")
    rm(dir; recursive = true, force = true)
    mkpath(joinpath(dir, "src"))
    for entry in readdir(joinpath(docs, "src"))
        entry == "generated" || cp(joinpath(docs, "src", entry), joinpath(dir, "src", entry))
    end
    # The package's files are read-only where it is installed, and the copies would be too.
    chmod(joinpath(dir, "src"), 0o755; recursive = true)
    overlay!(content_path(c, "pages"), joinpath(dir, "src"))
    overlay!(content_path(c, "assets"), joinpath(dir, "src", "assets"))
    isfile(content_path(c, "pages", "index.md")) || write(joinpath(dir, "src", "index.md"), front_page(c))
    mkpath(content_path(c, "notebooks"))
    symlink(content_path(c, "notebooks"), joinpath(dir, "notebooks"))
    mkpath(slate_dir(c))
    symlink(slate_dir(c), joinpath(dir, "slate"))
    return dir
end

"Copy the files under `from`, if it is there, into `to` at the same paths, over what is there."
function overlay!(from::AbstractString, to::AbstractString)
    isdir(from) || return
    for f in tree_files(from)
        dest = joinpath(to, relpath(f, from))
        mkpath(dirname(dest))
        cp(f, dest; force = true)
    end
end

"""
Remove the builds of the site but the one served and the newest `keep` that built (with a record),
which pages already open in a browser may still load assets from, and what builds no longer running
left: a failed build's folder, its log once newer builds have theirs, a build's sources. Only builds'
files (named by their time) are touched, not what the builds share there.
"""
function prune_builds!(c::Config; keep::Integer = 2)
    served = something(current_site(c), "")
    names = readdir(builds_dir(c))
    builds = sort!(unique(m[1] for m in (match(r"^(\d{8}T\d{6})(\..*)?$", n) for n in names) if m !== nothing); rev = true)
    built = filter(b -> isfile(joinpath(builds_dir(c), b * ".json")), builds)
    isempty(built) && return
    for b in builds
        dir = joinpath(builds_dir(c), b)
        # One newer than the newest that built is running still, or its log says why it failed.
        (b in first(built, keep) || b > first(built) || startswith(served, dir)) && continue
        rm(dir; recursive = true, force = true)
        foreach(ext -> rm(dir * ext; recursive = true, force = true), (".log", ".json", ".docs"))
    end
end

"""
    request_build!(c; build = default_site_build, settle = 0)

Build the site in the background. A request while a build runs is remembered and built once that
one ends, however many come. With `settle`, a build first waits that many seconds, and what is asked
for meanwhile is built by it.
"""
function request_build!(c::Config; build = default_site_build, settle::Real = 0)
    start = lock(SITE_LOCK) do
        SITE.building && (SITE.again = true; return false)
        SITE.building = true; SITE.again = false; SITE.started = now()
        true
    end
    start || return
    Threads.@spawn while true
        # Not from a knowledge base half imported (see `IMPORTS`); the import's end asks for a build again.
        IMPORTS[] > 0 && @info "[site] Waiting for the import to finish"
        while IMPORTS[] > 0
            sleep(2)
        end
        # A job's changes come in runs (a sync ingests one document after another): what is asked for
        # while settling is built by this build, not one more.
        if settle > 0
            sleep(settle)
            lock(() -> SITE.again = false, SITE_LOCK)
        end
        # Built by the code as it is now: a change to it is often what asked for the build.
        revise_code()
        # Nothing to build when the site served is the publisher's and nothing here differs from it.
        err = try
            Base.invokelatest(published_site_current, c) ? @info("[site] The published site is current; not building it here") :
                                                            Base.invokelatest(build_site!, c; build)
            nothing
        catch e
            @error "The site did not build; the last build is still served" exception = (e, catch_backtrace())
            failure_message(e)
        end
        try
            err === nothing && Base.invokelatest(announce_setup)
        catch e
            @warn "Could not say where to set the knowledge base up" exception = e
        end
        more = lock(SITE_LOCK) do
            SITE.error = err; SITE.finished = now()
            SITE.again || (SITE.building = false; return false)
            SITE.again = false; SITE.started = now()
            true
        end
        more || break
    end
    return
end
