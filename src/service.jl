# The shared service, `zemi --shared`: one port serving the site, the API, signing in and (through
# the embedded Kaimon) MCP, to people signed in through the providers in `[shared]`. The site is
# rebuilt in a process of its own into a new folder and switched to in one step, so it never goes
# down while it builds; pages opened before a switch still find the old build's assets.

"Whether this process serves the shared service, whose site has the accounts' pages too."
const SHARED_MODE = Ref(false)

# ── Metrics ───────────────────────────────────────────────────────────────────────────────────────

"Requests answered, by route: how many, how many failed, and their time, since the service started."
const METRICS = Dict{String,Vector{Float64}}()    # route => [count, errors, total seconds, max seconds]
const METRICS_LOCK = ReentrantLock()
const STARTED = Ref(now())

function record!(route::AbstractString, status::Integer, seconds::Real)
    lock(METRICS_LOCK) do
        m = get!(() -> zeros(4), METRICS, route)
        m[1] += 1; m[2] += status >= 500; m[3] += seconds; m[4] = max(m[4], seconds)
    end
end

"The route a request counts under: its method and the API path's first parts, or the site."
metric_route(req::HTTP.Request, parts) =
    !isempty(parts) && parts[1] in ("api", "auth", "mcp") ? req.method * " /" * join(first(parts, 2), '/') : "site"

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
        elseif shared && (caller = shared_caller(kb, req)).via == :anonymous
            redirect("/auth/sign-in?return_to=" * HTTP.escapeuri(req.target))
        elseif shared && !can(caller, "read")
            # A token made without `read` is for what else it was given (tasks, say), not the pages.
            HTTP.Response(403, ["Content-Type" => "text/plain; charset=utf-8"], "Not permitted (read).")
        else
            # A codebase the site is built without, and any record, is answered here, to those who may see it.
            caller, path = shared ? caller : local_caller(), HTTP.unescapeuri(uri.path)
            live = codebase_site_response(kb, caller, path; req)
            live === nothing && (live = record_site_response(kb, caller, path; req))
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
    record!(metric_route(req, parts), r.status, time() - t0)
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
        Base.invokelatest(respond_shared, kb, req)
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
    STARTED[] = now()
    if site
        reap_stale_build!(c)
        (sources ? site_outdated(c) : current_site(c) === nothing) && request_build!(c; build)
        watch_site!(c; build, sources)
    end
    SERVED_AT[] = "http://localhost:$port"
    LOCAL_PORT[] = port
    @info "Knowledge base at http://localhost:$port" * (sources ? "" : " (rebuilt on Enter, or when a job changes it)") *
          "; a browser new to it opens $(local_link(c, port)), or run zemi open"
    SETUP_ANNOUNCED[] = (kb, local_link(c, port, "/service/setup.html"))
    if site && setup_needed(kb)
        current_site(c) === nothing ? @info("Not set up yet: Setup opens in the browser once the site is built, in a few minutes") :
                                      announce_setup()
    end
    return HTTP.serve!("127.0.0.1", port) do req
        revise_code()
        Base.invokelatest(respond_service, kb, req; shared = false)
    end
end

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
    setup_needed(kb) || return
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

"""
    run_local(; manual = false)

`zemi`: serve the knowledge base for whoever runs it (see [`serve_local`](@ref)), with Kaimon's
agents, the arXiv watch, and the plugins and record sources (see [`load_plugins!`](@ref) and
[`follow_sources`](@ref)), until the process is stopped. With `manual`, edits to what the site is
built from wait for Enter in the terminal.
"""
function run_local(; manual::Bool = false)
    db = kb()
    # The knowledge base's tools reach the Claude sessions and notebooks on this machine through its Kaimon.
    agent_session(; tools = true)
    if db.config.dataset.role != :none
        # The site is first built once this import is done (see `IMPORTS`), not from a knowledge base
        # half imported; the build is asked for as soon as the site is served.
        Threads.atomic_add!(IMPORTS, 1)
        job = start_import(db)
        Threads.@spawn (wait(job); Threads.atomic_sub!(IMPORTS, 1))
    end
    follow_dataset!(db)
    server = serve_local(; kb = db, sources = !manual)
    start_watch!(db)
    follow_task_vectors(db)
    follow_commits(db)
    follow_media(db)
    load_plugins!(db.config)
    follow_sources(db)
    start_figure_sweep(db)
    manual && @async while !eof(stdin)
        readline(stdin)
        @info "Rebuilding the site"
        request_build!(db.config)
    end
    atexit(() -> stop_shared(server, db))
    Base.exit_on_sigint(true)
    wait(server)
end

"""
    run_shared(; kaimon_mode = nothing)

`zemi --shared`: run the knowledge base as a service for the people signed in to it, with the arXiv
watch, the plugins and record sources, and the dataset followed by a consumer, until the process is stopped. With `local_sign_in`
(`--local-sign-in`, or `ZEMI_LOCAL_SIGN_IN=1`), people sign in on this machine without a provider
(see [`local_sign_in`](@ref)). `kaimon_mode`
(`:embedded` or `:external`, from `--kaimon`) overrides `[shared] kaimon` for this run. With `dev` (`zemi dev
--shared`), the site comes from VitePress's development server, as under [`run_dev`](@ref).
"""
function run_shared(; kaimon_mode::Union{Symbol,Nothing} = nothing, dev::Bool = false,
                    local_sign_in::Bool = get(ENV, "ZEMI_LOCAL_SIGN_IN", "") == "1")
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
    which = something(kaimon_mode, db.config.shared.kaimon)
    dev && (DEV_URL[] = "http://localhost:$(dev_server_port())")
    # Pages are served before Qdrant and Kaimon are up, and say they are starting until then.
    STARTING[] = true
    ready = nothing
    server = serve_shared(; kb = db, site = !dev)
    ensure_qdrant(db.config; patience = 30) || @warn "Qdrant is not answering at $(Qdrant.url()): searching by meaning and embedding will fail"
    follow_task_vectors(db)
    follow_commits(db)
    follow_media(db)
    load_plugins!(db.config)
    start_figure_sweep(db)
    if KAIMON[] === nothing
        @warn "Kaimon is not loaded: agents (summaries, the tutor, notebooks) cannot run"
    else
        try
            Gate = kaimon().KaimonGate
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
    ready === nothing ? (STARTING[] = false; follow_sources(db)) :
        @async (try wait(ready) catch end; STARTING[] = false; follow_sources(db))
    db.config.dataset.role == :none || start_import(db)
    follow_dataset!(db)
    start_watch!(db)
    # Ctrl-C or a service manager's SIGTERM ends the process, and the cleanup runs on the way out.
    # Catching the interrupt instead does not work: it is thrown into whichever task is running at
    # the time, often one of the HTTP server's, which swallows it.
    stop_dev = dev ? start_dev!(db; api = "http://127.0.0.1:$(db.config.shared.port)") : () -> nothing
    atexit(() -> (stop_dev(); stop_shared(server, db)))
    Base.exit_on_sigint(true)
    wait(server)
end

"""
    stop_shared(server, kb)

Stop the shared service: no more requests, no more rebuilds (one running is stopped, and the build
served is left as it is), the Kaimon session closed, the database closed.
"""
function stop_shared(server, db::KB)
    @info "Stopping the knowledge base"
    STOPPING[] = true
    try close(server) catch end
    WATCHER[] === nothing || close(WATCHER[])
    p = BUILD_PROCESS[]
    p === nothing || process_exited(p) || terminate(getpid(p); group = true, what = "The site build", seconds = 10)
    KAIMON[] === nothing || try kaimon().KaimonGate.stop() catch end
    stop_embedded!()
    try close(db) catch end
end
