# The shared service, `zemi --shared`: one port serving the site, the API, signing in and (through
# the embedded Kaimon) MCP, to people signed in through the providers in `[shared]`. The site is
# rebuilt in a process of its own into a new folder and switched to in one step, so it never goes
# down while it builds; pages opened before a switch still find the old build's assets.

"Whether this process serves the shared service, whose site has the accounts' pages too."
const SHARED_MODE = Ref(false)

# ── Metrics ───────────────────────────────────────────────────────────────────────────────────────

"How many of a route's first requests after a start are left out of its times: they compile what they run."
const METRIC_WARMUP = 2
"How many of a route's latest times are kept, for its percentile."
const METRIC_RECENT = 1000

"""
A route's requests since the service started: how many, how many failed, and the times of those after
the warm-up ([`METRIC_WARMUP`](@ref)), the latest kept for a percentile. A route that `waits` (a long poll)
spends its time waiting for a change.
"""
mutable struct RouteTimes
    count::Int
    errors::Int
    timed::Int
    total::Float64
    slowest::Float64
    recent::Vector{Float64}
    next::Int
    waits::Bool
end
RouteTimes(waits::Bool) = RouteTimes(0, 0, 0, 0.0, 0.0, Float64[], 1, waits)

const METRICS = Dict{String,RouteTimes}()
const METRICS_LOCK = ReentrantLock()
const STARTED = Ref(now())

function record!(route::AbstractString, status::Integer, seconds::Real; waits::Bool = false)
    lock(METRICS_LOCK) do
        m = get!(() -> RouteTimes(waits), METRICS, route)
        m.count += 1
        m.errors += status >= 500
        m.count > METRIC_WARMUP || return
        m.timed += 1
        m.total += seconds
        m.slowest = max(m.slowest, seconds)
        if length(m.recent) < METRIC_RECENT
            push!(m.recent, seconds)
        else
            m.recent[m.next] = seconds
            m.next = mod1(m.next + 1, METRIC_RECENT)
        end
    end
end

"The time `p` of a route's latest requests took no longer than (0.95 for the 95th percentile)."
percentile(m::RouteTimes, p::Real) = isempty(m.recent) ? nothing : sort(m.recent)[clamp(ceil(Int, p * length(m.recent)), 1, length(m.recent))]

"""
    metric_route(req, parts) -> (route, waits)

The route a request counts under, and whether it waits: an API request under the pattern it matched
(`GET /api/tasks/:task`), signing in, MCP and an unknown API path under their first parts, and the
site's pages as one.
"""
function metric_route(req::HTTP.Request, parts)
    (isempty(parts) || !(parts[1] in ("api", "auth", "mcp"))) && return ("site", false)
    found = parts[1] == "api" ? find_route(req.method, parts) : nothing
    found === nothing || return (req.method * " " * first(found).pattern, first(found).waits)
    return (req.method * " /" * join(first(parts, 2), '/'), false)
end

"""
    respond_service(kb, req; shared) -> HTTP.Response

Answer a request to the knowledge base's one port: the API under `/api/`, and the site from its
current build. In the shared service (`shared`), for whoever signed in, with signing in under
`/auth/`; run for one person, for whoever runs it, with changes only from this machine's pages.
"""
function respond_service(kb::KB, req::HTTP.Request; shared::Bool)
    sh = kb.config.shared
    uri = HTTP.URI(req.target)
    params = HTTP.queryparams(uri)
    parts = filter(!isempty, split(HTTP.unescapeuri(uri.path), '/'))
    t0 = time()
    r = try
        if length(parts) == 4 && parts[1:3] == ["api", "media", "upload"]
            # A file sent to an upload link: the link is its sender's credential (see media_upload).
            upload_response(kb, req, parts[4])
        elseif !shared && !haskey(ICON_PATHS, uri.path) && (locked = local_key_response(kb, req, uri, params)) !== nothing
            locked
        elseif shared && !isempty(parts) && parts[1] == "auth"
            auth_response(kb, sh, req, parts, params)
        elseif shared && !isempty(parts) && parts[1] == "mcp"
            mcp_response(kb, req)
        elseif shared && !isempty(parts) && (parts[1] == "oauth" || (parts[1] == ".well-known" && length(parts) > 1 &&
                                                                     startswith(parts[2], "oauth-")))
            oauth_response(kb, sh, req, parts, params)
        elseif !isempty(parts) && parts[1] == "api"
            if !shared
                local_host(req) ? respond_local(kb, req) : json_response(Dict("error" => "Not this machine's address"); status = 403)
            elseif req.method == "POST" && !shared_write_allowed(sh, req)
                json_response(Dict("error" => "Only from this site's pages, or with a token."); status = 403)
            else
                handle(kb, req, shared_caller(kb, req))
            end
        elseif req.method != "GET"
            HTTP.Response(405)
        elseif uri.path == "/zemi-sw.js"
            # The service worker that shows pushed notifications (see notify.jl), at the root so it
            # covers the whole site, and looked at again on every visit.
            r = file_response(SERVICE_WORKER; req)
            HTTP.setheader(r, "Cache-Control" => "no-cache")
            r
        elseif uri.path == "/manifest.webmanifest"
            # What a phone installs the site as, which on an iPhone notifications need. To anyone,
            # like the icons it names: browsers ask for it without signing in.
            HTTP.Response(200, ["Content-Type" => "application/manifest+json"], JSON.json(web_manifest(kb.config)))
        elseif !isempty(DEV_URL[])
            # Under `zemi dev` the pages come from the development server.
            redirect(DEV_URL[] * req.target)
        elseif haskey(ICON_PATHS, uri.path) && isfile(site_icon(kb.config, ICON_PATHS[uri.path]))
            # The site's icon, to anyone, and to be shown on other sites: browsers and MCP clients
            # (claude.ai's connectors) look for it before signing in.
            r = file_response(site_icon(kb.config, ICON_PATHS[uri.path]); req)
            HTTP.setheader(r, "Access-Control-Allow-Origin" => "*")
            HTTP.setheader(r, "Cross-Origin-Resource-Policy" => "cross-origin")
            r
        elseif shared && uri.path == "/privacy"
            # To anyone: sign-in providers link to it before anyone has signed in.
            HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], privacy_page(kb.config))
        elseif shared && (caller = shared_caller(kb, req)).via == :anonymous
            redirect("/auth/sign-in?return_to=" * HTTP.escapeuri(req.target))
        elseif shared && !can(caller, "read")
            # A token made without `read` is for what else it was given (tasks, say), not the pages.
            HTTP.Response(403, ["Content-Type" => "text/plain; charset=utf-8"], "Not permitted (read).")
        else
            # A codebase the site is built without, any record and any private paper are answered here, to those who may see them.
            caller, path = shared ? caller : local_caller(), HTTP.unescapeuri(uri.path)
            live = codebase_site_response(kb, caller, path; req)
            live === nothing && (live = record_site_response(kb, caller, path; req))
            live === nothing && (live = private_paper_response(kb, caller, path; req))
            f = live === nothing ? site_file(kb.config, uri.path) : nothing
            live !== nothing ? live :
            f !== nothing ? file_response(f; req) :
            current_site(kb.config) === nothing ? HTTP.Response(503, ["Retry-After" => "30"], "Site building. Try again shortly.") :
            not_found_page(kb.config)
        end
    catch e
        @error "Request failed" target = req.target exception = (e, catch_backtrace())
        HTTP.Response(500)
    end
    route, waits = metric_route(req, parts)
    record!(route, r.status, time() - t0; waits)
    return r
end

"The site's 404 page, as the answer to a request for what it has not got."
function not_found_page(c::Config)
    root = current_site(c)
    page = root === nothing ? "" : joinpath(root, "404.html")
    return isfile(page) ? file_response(page; status = 404) : HTTP.Response(404)
end

"Answer a request to the shared service (see [`respond_service`](@ref))."
respond_shared(kb::KB, req::HTTP.Request) = respond_service(kb, req; shared = true)

"""
    serve_shared(; kb = kb(), build = default_site_build) -> HTTP.Server

Run the shared service on `[shared] port`: the site (built now if it has never been or was built from other sources, and again when a
job changes the knowledge base), the API and signing in. The default roles are created if missing.
"""
function serve_shared(; kb::KB = kb(), build = default_site_build, host::AbstractString = kb.config.shared.host,
                      site::Bool = true)
    c = kb.config
    isempty(c.shared.base_url) && error("[shared] base_url is not set: where do people reach this service? " *
                                        "To try the service on this machine, run it with --local-sign-in (or ZEMI_LOCAL_SIGN_IN=1)")
    isempty(c.shared.providers) && !LOCAL_SIGN_IN[] && @warn "No sign-in provider is configured ([[shared.providers]]): nobody can sign in"
    for p in c.shared.providers
        try
            resolve_key(p.client_secret, "provider $(p.name)")
        catch e
            @warn "Signing in with $(p.name) will fail until its client secret is readable" exception = e
        end
    end
    ensure_roles!(kb)
    SHARED_MODE[] = true
    STARTED[] = now()
    if site
        reap_stale_build!(c)
        site_outdated(c) && request_build!(c; build)
        watch_site!(c; build)
    end
    @info "Shared knowledge base at $(c.shared.base_url) (listening on $host:$(c.shared.port))"
    server = HTTP.serve!(host, c.shared.port) do req
        revise_code()
        on_workers(() -> Base.invokelatest(respond_shared, kb, req))
    end
    Threads.@spawn warm_up(kb; shared = true)
    return server
end

"""
    warm_up(kb; shared = false) -> Int

Make the requests the board, the findings and the sign-in page start with, once, read-only, as the
service starts: Julia compiles each the first time it runs, which otherwise keeps the first person to
open a page waiting seconds per request. Returns how many were made.
"""
function warm_up(kb::KB; shared::Bool = false)
    t0 = time()
    targets = ["/api/status", "/api/me", "/api/projects", "/api/tasks/codebases", "/api/tasks/people", "/api/tasks/waiting",
               "/api/tasks/changes?since=-1"]
    for r in query(kb, "SELECT key FROM projects ORDER BY key LIMIT 1")
        k = String(r.key)
        append!(targets, ["/api/projects/$k", "/api/projects/$k/declined", "/api/findings?project=$k"])
        for t in query(kb, "SELECT number FROM tasks WHERE project_id = (SELECT id FROM projects WHERE key = ?) LIMIT 1", (k,))
            push!(targets, "/api/tasks/$k-$(t.number)")
        end
    end
    for t in targets
        try handle(kb, HTTP.Request("GET", t), local_caller()) catch end
    end
    try
        shared && sign_in_page(kb.config.shared)
        page = site_file(kb.config, "/")
        page === nothing || file_response(page; req = HTTP.Request("GET", "/"))
    catch
    end
    @info "Ready: $(length(targets)) of the first requests answered once, in $(round(time() - t0; digits = 1)) s"
    return length(targets)
end

"Whether something answers on `port` on this machine."
port_taken(port::Integer) = try close(connect(ip"127.0.0.1", port)); true catch; false end

"Where this process serves the knowledge base for one person (see [`serve_local`](@ref)), empty if it does not."
const SERVED_AT = Ref("")

"""
    serve_local(; kb = kb(), port = 8000, sources = true, build = default_site_build) -> HTTP.Server

Serve the knowledge base for whoever runs it, on `http://localhost:<port>`: the site from its current
build (built now if it has none or, with `sources`, was built from other sources, and again when the
knowledge base or, with `sources`, what the site is built from changes) and the API, on the one port, with no signing in.
"""
function serve_local(; kb::KB = kb(), port::Integer = parse(Int, get(ENV, "ZEMI_PORT", "8000")),
                     sources::Bool = true, build = default_site_build, site::Bool = true)
    c = kb.config
    port_taken(port) && error("Port $port is in use, perhaps by another zemi: stop that, or serve on another port " *
                              "([service] port in the config, or ZEMI_PORT)")
    STARTED[] = now()
    if site
        reap_stale_build!(c)
        (sources ? site_outdated(c) : current_site(c) === nothing) && request_build!(c; build)
        watch_site!(c; build, sources)
    end
    SERVED_AT[] = "http://localhost:$port"
    LOCAL_PORT[] = port
    if stderr isa Base.TTY
        say(:ok, "The knowledge base is at http://localhost:$port", ("A browser new to it", local_link(c, port), "or zemi open"),
            "Ctrl-C stops it.")
    else
        @info "Knowledge base at http://localhost:$port" * (sources ? "" : " (rebuilt when a job changes it)") *
              "; a browser new to it opens $(local_link(c, port)), or run zemi open"
    end
    SETUP_ANNOUNCED[] = (kb, local_link(c, port, "/service/setup.html"))
    if site && setup_needed(kb)
        current_site(c) === nothing ? @info("Not set up yet: Setup opens in the browser once the site is built, in a few minutes") :
                                      announce_setup()
    end
    return HTTP.serve!("127.0.0.1", port) do req
        revise_code()
        on_workers(() -> Base.invokelatest(respond_service, kb, req; shared = false))
    end
end

"""
    on_workers(f)

Run `f` on the default thread pool and wait for it. HTTP.jl answers each connection on the
interactive pool, which has one thread: a request's work done there holds up every other request.
Done on the default pool, requests are answered side by side, the interactive thread only waiting.
"""
on_workers(f) = fetch(Threads.@spawn f())

"The knowledge base served for one person and the address of its setup page, for `announce_setup`."
const SETUP_ANNOUNCED = Ref{Any}(nothing)

"""
    announce_setup(io = stderr)

On a knowledge base served for one person that is still to be set up (see [`setup_needed`](@ref)),
say in the terminal, in a box that stands out from the log, where to set it up: when it is served
with a site built, and when the first build finishes.
"""
function announce_setup(io::IO = stderr)
    SETUP_ANNOUNCED[] === nothing && return
    kb, url = SETUP_ANNOUNCED[]
    (isopen(kb) && setup_needed(kb)) || return               # not one served before and since closed
    lines = ["This knowledge base is not set up yet.", "Open $url to set it up."]
    width = maximum(length, lines) + 4
    printstyled(io, "\n  ╭", "─"^width, "╮\n"; color = :green, bold = true)
    for (i, l) in enumerate(lines)
        printstyled(io, "  │  "; color = :green, bold = true)
        printstyled(io, rpad(l, width - 2); color = i == 1 ? :green : :cyan, bold = true)
        printstyled(io, "│\n"; color = :green, bold = true)
    end
    printstyled(io, "  ╰", "─"^width, "╯\n\n"; color = :green, bold = true)
end

# ── Running ───────────────────────────────────────────────────────────────────────────────────────

"""
A knowledge base this process serves: how (`mode`: `:local`, `:dev` or `:shared`), where people open
it (`url`) and where its API is (`api`), its server, the loops started with it (`tasks`, waited for as
it stops), what else stops with it (`stops`), and whether Kaimon runs the process as its extension
(`hosted`, see hosted.jl). See [`stop!`](@ref).
"""
mutable struct Running
    mode::Symbol
    url::String
    api::String
    server::Any
    tasks::Vector{Any}
    stops::Vector{Function}
    hosted::Bool
end

"The port the knowledge base is served on for one person: `ZEMI_PORT`, else `[service] port`."
local_port(c::Config) = parse(Int, get(ENV, "ZEMI_PORT", string(c.service.port)))

"""
    start_local(; port, dev = false, dev_port, hosted = false, build = default_site_build) -> Running

Serve the knowledge base for whoever runs it (see [`serve_local`](@ref)), with Kaimon's agents, the
arXiv watch, and the plugins and record sources (see [`load_plugins!`](@ref) and
[`follow_sources`](@ref)). With `dev`, for developing it: the site from VitePress's development server
on `dev_port` (see dev.jl), without the dataset, the arXiv watch and backups. With `hosted`, Kaimon
runs this process as its extension and serves the tools itself. `build` builds the site (see
[`build_site!`](@ref)).
"""
function start_local(; port::Integer = local_port(kb().config), dev::Bool = false,
                     dev_port::Integer = dev_server_port(kb().config), hosted::Bool = false, build = default_site_build)
    STOPPING[] = false
    db = kb()
    # The knowledge base's tools reach the Claude sessions and notebooks on this machine through its Kaimon.
    hosted ? ensure_qdrant(db.config; patience = 30) || @warn("Qdrant is not answering at $(Qdrant.url()): searching by meaning and embedding will fail") :
             agent_session(; tools = true)
    if !dev && db.config.dataset.role != :none
        # The site is first built once this import is done (see `IMPORTS`), not from a knowledge base
        # half imported; the build is asked for as soon as the site is served.
        Threads.atomic_add!(IMPORTS, 1)
        job = start_import(db)
        Threads.@spawn (wait(job); Threads.atomic_sub!(IMPORTS, 1))
    end
    dev && (DEV_URL[] = "http://localhost:$dev_port")
    server = serve_local(; kb = db, port, site = !dev, build)
    api = "http://localhost:$port"
    r = Running(dev ? :dev : :local, dev ? DEV_URL[] : api, api, server, Any[], Function[], hosted)
    dev || push!(r.tasks, follow_dataset!(db), start_watch!(db), follow_backups(db))
    push!(r.tasks, follow_task_vectors(db), follow_commits(db), follow_media(db))
    load_plugins!(db.config)
    push!(r.tasks, follow_sources(db))
    dev || upgrade_landscape(db)
    start_figure_sweep(db)
    hosted && push!(r.tasks, start_autosync!(db))
    if dev
        push!(r.stops, start_dev!(db; api = "http://127.0.0.1:$port", dev_port))
        SETUP_ANNOUNCED[] = (db, local_link(db.config, port, "/service/setup.html"))
        announce_setup()
    end
    return r
end

"""
    run_local()

`zemi`: serve the knowledge base for whoever runs it (see [`start_local`](@ref)) until the process
is stopped.
"""
run_local() = run_until_stopped(start_local())

"`zemi dev`: serve the knowledge base for developing it, run for one person (see [`start_local`](@ref))."
run_dev(; port::Integer = local_port(kb().config)) = run_until_stopped(start_local(; port, dev = true))

"""
    start_shared(; kaimon_mode = nothing, dev = false, local_sign_in = false, hosted = false) -> Running

Run the knowledge base as a service for the people signed in to it, with the arXiv watch, the
plugins and record sources, and the dataset followed by a consumer. With `local_sign_in`
(`--local-sign-in`, or `ZEMI_LOCAL_SIGN_IN=1`), people sign in on this machine without a provider
(see [`local_sign_in`](@ref)). `kaimon_mode` (`:embedded` or `:external`, from `--kaimon`) overrides
`[shared] kaimon`; with `hosted`, Kaimon runs this process as its extension, serves the tools and
hosts the agents. With `dev`, the site comes from VitePress's development server, as under
[`start_local`](@ref).
"""
function start_shared(; kaimon_mode::Union{Symbol,Nothing} = nothing, dev::Bool = false, hosted::Bool = false,
                      local_sign_in::Bool = get(ENV, "ZEMI_LOCAL_SIGN_IN", "") == "1")
    STOPPING[] = false
    db = kb()
    if local_sign_in
        # Tried on this machine, the service needs no [shared] table: it is at localhost on its port
        # (see `shared_config`), the config read again with the local sign-in on.
        LOCAL_SIGN_IN[] = true
        db.config = load_config()
        why = local_sign_in_problem(db.config.shared)
        isempty(why) || (LOCAL_SIGN_IN[] = false; error("The local sign-in is for trying the service on this machine, and $why"))
        printstyled(stderr, "\n  Local sign-in is on at $(db.config.shared.base_url): anyone on this machine can sign in as anyone\n",
                    "  invited, or an admin", isempty(db.config.shared.admins) ? " (with none named, the first to sign in is one)" : "", ".\n\n";
                    color = :yellow, bold = true)
    end
    which = hosted ? :hosted : something(kaimon_mode, db.config.shared.kaimon)
    dev_port = dev_server_port(db.config)
    dev && (DEV_URL[] = "http://localhost:$dev_port")
    # Pages are served before Qdrant and Kaimon are up, and say they are starting until then.
    STARTING[] = true
    ready = nothing
    server = serve_shared(; kb = db, site = !dev)
    r = Running(:shared, dev ? DEV_URL[] : db.config.shared.base_url, "http://127.0.0.1:$(db.config.shared.port)", server,
                Any[], Function[], hosted)
    ensure_qdrant(db.config; patience = 30) || @warn "Qdrant is not answering at $(Qdrant.url()): searching by meaning and embedding will fail"
    push!(r.tasks, follow_task_vectors(db), follow_commits(db), follow_media(db))
    load_plugins!(db.config)
    start_figure_sweep(db)
    if which != :hosted
        try
            Gate = KaimonGate
            embedded = which == :embedded && db.config.shared.kaimon_port > 0
            if embedded && !kaimon_embeddable()
                @warn "This Kaimon cannot run as the service's own: /mcp is off, and agents use the Kaimon of whoever runs the service"
                embedded = false
            end
            if embedded
                # The service's own Kaimon, which serves the tools at /mcp and hosts the agents.
                ready = watch_embedded(start_embedded!(db.config))
                Gate.serve(; tools = create_tools(Gate.GateTool), namespace = MCP_NAMESPACE, force = true,
                           allow_mirror = false, allow_restart = false)
            elseif which == :external
                # The Kaimon already running on this machine serves the tools to its sessions, unrestricted,
                # and hosts the agents; /mcp is off.
                Gate.serve(; tools = create_tools(Gate.GateTool), namespace = MCP_NAMESPACE, force = true,
                           allow_mirror = false, allow_restart = false)
            else
                Gate.serve(; force = true, discoverable = false)
            end
        catch e
            @warn "No Kaimon session: agents (summaries, the tutor, notebooks) cannot run" exception = e
        end
    end
    # The sources start once the service's Kaimon is up, since what they bring in is read by its agents.
    begin_sources() = (STARTING[] = false; push!(r.tasks, follow_sources(db)); upgrade_landscape(db))
    ready === nothing ? begin_sources() : @async (try wait(ready) catch end; begin_sources())
    db.config.dataset.role == :none || start_import(db)
    push!(r.tasks, follow_dataset!(db), start_watch!(db), follow_backups(db), follow_notifications(db))
    hosted && push!(r.tasks, start_autosync!(db))
    dev && push!(r.stops, start_dev!(db; api = "http://127.0.0.1:$(db.config.shared.port)", dev_port))
    return r
end

"`zemi --shared`: run the knowledge base for the people signed in to it (see [`start_shared`](@ref)) until the process is stopped."
run_shared(; kw...) = run_until_stopped(start_shared(; kw...))

"""
Wait on the knowledge base `r` serves until the process is stopped. Ctrl-C or a service manager's
SIGTERM ends the process, and `r` is stopped on the way out (see [`stop!`](@ref)).
"""
function run_until_stopped(r::Running)
    # Catching the interrupt instead does not work: it is thrown into whichever task is running at the
    # time, often one of the HTTP server's, which swallows it.
    atexit(() -> (stop!(r); shutdown()))
    Base.exit_on_sigint(true)
    wait(r.server)
end

"""
    stop!(r; seconds = 15)

Stop the knowledge base `r` serves: no more requests, no more rebuilds (one running is stopped, and
the build served is left as it is), the development server and the service's own Kaimon stopped,
and its loops waited for, up to `seconds`. The knowledge base stays open; a process Kaimon does not
host closes its Kaimon session.
"""
function stop!(r::Running; seconds::Real = 15)
    @info "Stopping the knowledge base"
    STOPPING[] = true
    tasks_changed!()                                   # wakes the loop waiting for tasks to change
    try close(r.server) catch end
    WATCHER[] === nothing || (close(WATCHER[]); WATCHER[] = nothing)
    p = BUILD_PROCESS[]
    p === nothing || process_exited(p) || terminate(getpid(p); group = true, what = "The site build", seconds = 10)
    for stop in r.stops
        try stop() catch e; @warn "Stopping part of the knowledge base failed" exception = e end
    end
    r.hosted || try KaimonGate.stop() catch end
    stop_embedded!()
    deadline = time() + seconds
    for t in r.tasks
        t isa Task || continue
        while !istaskdone(t) && time() < deadline
            sleep(0.1)
        end
    end
    SERVED_AT[] = DEV_URL[] = ""
    SHARED_MODE[] = LOCAL_SIGN_IN[] = STARTING[] = false
    return r
end
