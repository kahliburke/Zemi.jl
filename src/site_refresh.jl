# Keeping the site served current: what jobs change in the knowledge base written into it as they
# change it, without a build, and a build when what the site is built from changes.

"Whether a refresh of the site served runs (see [`request_refresh!`](@ref)), and whether another was asked for meanwhile."
mutable struct RefreshState
    running::Bool
    again::Bool
end
const REFRESH = RefreshState(false, false)
const REFRESH_LOCK = ReentrantLock()
const REFRESH_WRITING = ReentrantLock()
"When the site served was last refreshed whole (see [`refresh_site!`](@ref)), and how often at least, in seconds."
const LAST_WHOLE_REFRESH = Ref(0.0)
const WHOLE_REFRESH_EVERY = 3600

"""
    refresh_site!(c) -> Union{Int,Nothing}

Bring the site served up to date with the knowledge base without building it: its data files and
the pages made from templates are written into it (see [`write_site`](@ref), [`stamp_templates!`](@ref)),
so a paper added shows at once. Only the documents jobs noted as changed are written, with what
names them (see [`write_site_changes!`](@ref), [`note_changes!`](@ref)), unless a change named none
or the last whole refresh is an hour old. The pages `write_site` writes for the build go to a folder of their
own. Returns how many templated pages were written, or `nothing` with no site served or one without
templates.
"""
function refresh_site!(c::Config)
    served = current_site(c)
    # A site with no templated pages has none to refresh (one built before them, or a test's).
    (served === nothing || !any(t -> isfile(joinpath(served, last(t).template * ".html")), TEMPLATED)) && return nothing
    t = time()
    digest() = (f = joinpath(served, BUILT_PAGES_FILE); isfile(f) ? read(f, String) : "")
    n, compiled, whole = lock(REFRESH_WRITING) do       # one at a time, however it was asked for
        was = digest()
        pages = mkpath(joinpath(builds_dir(c), "refresh-pages"))
        # The documents changed, written alone; the whole site when a change named none, when what
        # the refresh pages hold may be behind it, or now and then for what follows from every paper
        # (related papers, the works they cite and lack).
        changed = take_changes!()
        whole = changed === nothing || isempty(changed) || time() - LAST_WHOLE_REFRESH[] > WHOLE_REFRESH_EVERY ||
                write_site_changes!(kb(), pages, served, changed) === nothing
        whole && (write_site(kb(), pages, served); LAST_WHOLE_REFRESH[] = time())
        stamp_templates!(served), !isempty(was) && digest() != was, whole    # a site from before the digest: none to compare
    end
    @info "[site] Refreshed the site served in $(round(time() - t; digits = 1)) s ($(whole ? "all" : "the documents changed"), $n pages written)" *
          (compiled ? "; pages the build compiles changed, so it builds" : "")
    # The list of codebases or a notebook's page changed: those are built, not made from templates.
    compiled && request_build!(c)
    return n
end

"""
    request_refresh!(c; settle = 0)

Refresh the site served in the background (see [`refresh_site!`](@ref)). A request while one runs is
remembered and refreshed once that one ends; with `settle`, it first waits that many seconds.
"""
function request_refresh!(c::Config; settle::Real = 0)
    start = lock(REFRESH_LOCK) do
        REFRESH.running && (REFRESH.again = true; return false)
        REFRESH.running = REFRESH.again = true
        true
    end
    start || return
    Threads.@spawn while true
        while IMPORTS[] > 0                         # not from a knowledge base half imported
            sleep(2)
        end
        settle > 0 && sleep(settle)
        lock(() -> REFRESH.again = false, REFRESH_LOCK)
        try
            Base.invokelatest(refresh_site!, c)
        catch e
            @error "The site served was not refreshed" exception = (e, catch_backtrace())
        end
        done = lock(REFRESH_LOCK) do
            REFRESH.again && return false
            REFRESH.running = false
            true
        end
        done && break
    end
    return
end

"Seconds a refresh waits after a change before it starts, so a run of changes makes one refresh."
const REFRESH_SETTLE = Ref(5.0)

"The timer that rebuilds the site when the knowledge base, or (run for one person) its source, changes."
const WATCHER = Ref{Union{Timer,Nothing}}(nothing)

"""
What the site is built from (see [`site_source_files`](@ref)), to rebuild when it changes: the newest
time a file of it was written, and how many there are. Not what a build writes into `docs/` (the
generated pages, the notebooks' bundles), which would rebuild it forever.
"""
function source_signature(c::Config)
    files = last.(site_source_files(c))
    return (maximum(mtime, files; init = 0.0), length(files))
end

"Seconds a build waits after a change before it starts, so a run of changes makes one build."
const BUILD_SETTLE = Ref(30.0)

"""
    watch_site!(c; build, sources = false) -> Timer

Refresh the site served when a job changes the knowledge base (it touches the changes stamp; see
[`refresh_site!`](@ref)), build it when the build stamp is touched (see [`rebuild_site!`](@ref)) and,
with `sources`, when what it is built from changes (see [`source_signature`](@ref)).
"""
function watch_site!(c::Config; build = default_site_build, sources::Bool = false)
    stamp, rebuild = changes_stamp(c), build_stamp(c)
    mkpath(dirname(stamp)); isfile(stamp) || touch(stamp)
    signature() = (mtime(stamp), mtime(rebuild), sources ? source_signature(c) : (0.0, 0))
    seen = Ref(signature())
    WATCHER[] === nothing || close(WATCHER[])
    WATCHER[] = Timer(2; interval = 2) do _
        # (A Timer whose callback throws stops for good: one failed look, at a folder being replaced
        # say, must not end the site's refreshes.)
        try
            now_ = signature()
            now_ == seen[] && return
            # A change to the knowledge base is written into the site served (which builds only when a
            # page it compiles changed, see `refresh_site!`); a change to the site's sources builds it.
            now_[1] != seen[][1] && request_refresh!(c; settle = REFRESH_SETTLE[])
            (now_[2] != seen[][2] || now_[3] != seen[][3]) && request_build!(c; build, settle = BUILD_SETTLE[])
            seen[] = now_
        catch e
            @error "[site] Watching for changes failed; trying again" exception = e
        end
    end
end
