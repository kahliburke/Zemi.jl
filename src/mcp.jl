# ── The MCP endpoint ─────────────────────────────────────────────────────────────────────────────
# In shared mode people's MCP clients (Claude) reach the knowledge base's tools at `/mcp`. A Kaimon
# of the service's own, run headless beside it on `[shared] kaimon_port`, serves them: this process
# serves its tools on a gate that Kaimon finds, and passes each request on with the tools the
# caller's token allows. That Kaimon is restricted (`KAIMON_RESTRICTED`), so a request that reaches
# it without a list of tools gets none, and it hosts the service's own agents too.

"The namespace the knowledge base's tools are served under: `zemi.search`, and so on."
const MCP_NAMESPACE = "zemi"

"The tools `caller` may use over `/mcp`, by their full names."
mcp_tools(caller::Caller) =
    sort!(["$MCP_NAMESPACE.$(t.name)" for t in TOOLS[] if t.need !== nothing && can(caller, t.need)])

"The JSON-RPC methods passed on: starting a session, and listing and calling tools."
const MCP_METHODS = ("initialize", "notifications/initialized", "notifications/cancelled", "tools/list", "tools/call")

"The client headers passed on; every other one (`Origin`, `Authorization`, `X-Kaimon-*`) is not."
const MCP_CLIENT_HEADERS = ("Accept", "Mcp-Session-Id", "MCP-Protocol-Version", "Last-Event-ID")

"""
The service's Kaimon: its process, port and API key, and its own config and cache directories, set
apart from a Kaimon the same person runs.
"""
Base.@kwdef mutable struct EmbeddedKaimon
    port::Int
    key::String
    config_dir::String
    cache_dir::String
    process::Union{Base.Process,Nothing} = nothing
end

const EMBEDDED = Ref{Union{EmbeddedKaimon,Nothing}}(nothing)

# A gate's longest socket path is `<cache>/sock/<session id>-stream.sock`: the cache directory
# and 54 bytes, which must fit the platform's `sun_path` (104 bytes on macOS and the BSDs, 108 on
# Linux, each with its terminating NUL).
const SOCKET_PATH_MAX = Sys.isbsd() ? 103 : 107
socket_dir_fits(dir::AbstractString) = ncodeunits(dir) + 54 <= SOCKET_PATH_MAX

"""
    embedded_dirs(c) -> (config, cache)

Where the service's Kaimon keeps its configuration (under the data directory) and its cache: there
too when the path is short enough for its sockets, otherwise in a directory of `/tmp` named for
the data directory.
"""
function embedded_dirs(c::Config)
    config = joinpath(c.data_dir, "kaimon")
    cache = joinpath(config, "cache")
    socket_dir_fits(cache) || (cache = "/tmp/kbk-" * bytes2hex(sha256(c.data_dir))[1:10])
    return config, cache
end

"""
    prepare_embedded(c) -> EmbeddedKaimon

Make the service's Kaimon's directories, private to whoever runs the service, and its
configuration: strict, loopback only, on `[shared] kaimon_port`, with an API key kept from one run
to the next.
"""
function prepare_embedded(c::Config)
    config, cache = embedded_dirs(c)
    for d in (config, cache)
        mkpath(d)
        chmod(d, 0o700)
    end
    file = joinpath(config, "config.json")
    old = isfile(file) ? JSON.parsefile(file) : Dict{String,Any}()
    keys = get(old, "api_keys", [])
    key = isempty(keys) ? "kaimon_" * bytes2hex(rand(SECRET_RNG, UInt8, 24)) : String(first(keys))
    settings = merge(old, Dict("mode" => "strict", "api_keys" => [key], "allowed_ips" => ["127.0.0.1", "::1"],
                               "port" => c.shared.kaimon_port))
    haskey(settings, "created_at") || (settings["created_at"] = round(Int, time()))
    write_private(file, JSON.json(settings, 2))
    return EmbeddedKaimon(; port = c.shared.kaimon_port, key, config_dir = config, cache_dir = cache)
end

"The environment the service's Kaimon runs in: this process's own, with its directories, restricted, and indexing no code."
function embedded_env(e::EmbeddedKaimon)
    env = build_env()
    env["KAIMON_CONFIG_DIR"] = e.config_dir
    env["KAIMON_CACHE_DIR"] = e.cache_dir
    env["KAIMON_RESTRICTED"] = "1"
    env["KAIMON_CODE_INDEX"] = "0"
    return env
end

"""
Whether the loaded Kaimon can run as the service's own. One that cannot would ignore its own
directories and run on those of the Kaimon the same person uses: their extensions, sockets and
agents.
"""
kaimon_embeddable() = KAIMON[] !== nothing && isdefined(kaimon(), :code_indexing)

"The Julia project this process loaded Kaimon from, for the service's Kaimon to run in."
kaimon_project() = something(Base.active_project(), first(filter(isfile, Base.load_path())))

"How long the service's Kaimon is given to stop (closing its agents) before it is killed."
const EMBEDDED_STOP_SECONDS = 30

"The file holding the process id of the service's Kaimon, to stop one a previous run left behind."
embedded_pid_file(e::EmbeddedKaimon) = joinpath(e.config_dir, "kaimon.pid")

# Whether process `pid` is the service's Kaimon on `port`, from its command line: a pid file outlives
# its process, and the number may since have gone to another.
function is_embedded_kaimon(pid::Integer, port::Integer)
    cmd = process_command(pid)
    return occursin("-m Kaimon", cmd) && occursin("--port $port", cmd)
end

"Stop the service's Kaimon a previous run left behind, which would hold the port."
reap_stale_embedded!(e::EmbeddedKaimon) =
    reap_pid_file!(embedded_pid_file(e); matches = pid -> is_embedded_kaimon(pid, e.port), what = "[mcp] the service's Kaimon",
                   seconds = EMBEDDED_STOP_SECONDS)

"""
    start_embedded!(c) -> EmbeddedKaimon

Start the service's Kaimon, headless, logging to `kaimon.log` in its configuration directory, and
point this process's gate at it (`KAIMON_CACHE_DIR`), so the tools this process serves and the
agents it starts are that Kaimon's. One left running by an earlier run is stopped first. Returns
once it is started; [`embedded_ready`](@ref) says when it answers.
"""
function start_embedded!(c::Config)
    e = prepare_embedded(c)
    reap_stale_embedded!(e)
    log = joinpath(e.config_dir, "kaimon.log")
    cmd = setenv(`$(Base.julia_cmd()) --startup-file=no --threads=auto --project=$(kaimon_project()) -m Kaimon --headless --port $(e.port)`,
                 merge(embedded_env(e), confinement_env(c, e)))
    e.process = run(pipeline(cmd; stdin = devnull, stdout = log, stderr = log, append = true); wait = false)
    write(embedded_pid_file(e), string(getpid(e.process)))
    ENV["KAIMON_CACHE_DIR"] = e.cache_dir
    EMBEDDED[] = e
    @info "[mcp] Starting the service's Kaimon on port $(e.port) (log: $log)"
    return e
end

"Whether the service's Kaimon answers."
function embedded_ready(e::EmbeddedKaimon = EMBEDDED[])
    e === nothing && return false
    try
        close(Sockets.connect(ip"127.0.0.1", e.port))
        return true
    catch
        return false
    end
end

"""
Whether the service's Kaimon serves this process's tools: its port answers, and a session opened
with it lists the knowledge base's tools (its gate has connected and registered them).
"""
function serves_tools(e::EmbeddedKaimon)
    embedded_ready(e) || return false
    url = "http://127.0.0.1:$(e.port)/mcp"
    # Kaimon lists only the tools a request names as allowed, as the proxy names a token's.
    h = ["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream", "Authorization" => "Bearer $(e.key)",
         "X-Kaimon-Allowed-Tools" => "$MCP_NAMESPACE.status"]
    rpc(id, method, params) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    try
        r = HTTP.post(url, h, rpc(1, "initialize", Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(),
                                                        "clientInfo" => Dict("name" => "$MCP_NAMESPACE-ready", "version" => "1")));
                      status_exception = false, retry = false, connect_timeout = 2, request_timeout = 10)
        sid = HTTP.header(r, "Mcp-Session-Id", "")
        (r.status == 200 && !isempty(sid)) || return false
        listed = HTTP.post(url, [h; "Mcp-Session-Id" => sid], rpc(2, "tools/list", Dict());
                           status_exception = false, retry = false, request_timeout = 10)
        try HTTP.request("DELETE", url, [h; "Mcp-Session-Id" => sid]; status_exception = false, retry = false, request_timeout = 5) catch end
        return occursin(Regex("\"$(MCP_NAMESPACE)[._]status\""), String(copy(listed.body)))
    catch
        return false
    end
end

"Whether the service's Kaimon serves this process's tools, as last seen by [`watch_embedded`](@ref)."
const MCP_SERVING = Ref(false)

"How long, in seconds, a request to /mcp waits for the service's Kaimon while the service starts."
const MCP_START_WAIT = 180

"""
The service's Kaimon once it serves the tools, waiting while the service starts (up to
`MCP_START_WAIT` seconds), so a client calling right after a restart is answered rather than
refused; `nothing` when there is none, or it does not come up.
"""
function serving_upstream(; wait::Real = MCP_START_WAIT)
    t0 = time()
    while true
        e = EMBEDDED[]
        e !== nothing && MCP_SERVING[] && return e
        STARTING[] || return nothing                                       # not starting: nothing to wait for
        e !== nothing && e.process !== nothing && process_exited(e.process) && return nothing
        time() - t0 > wait && return nothing
        sleep(0.25)
    end
end

"Say when the service's Kaimon serves the tools, or that it stopped before it did, with the end of its log."
function watch_embedded(e::EmbeddedKaimon; timeout::Real = 300)
    @async begin
        t0 = time()
        MCP_SERVING[] = false
        while time() - t0 < timeout && !STOPPING[]
            serves_tools(e) && (MCP_SERVING[] = true; return @info "[mcp] Serving MCP at /mcp ($(duration(time() - t0)) to start)")
            if e.process !== nothing && process_exited(e.process)
                log = joinpath(e.config_dir, "kaimon.log")
                tail = isfile(log) ? join(last(readlines(log), 15), "\n") : ""
                return @error "[mcp] The service's Kaimon stopped; the end of its log:\n$tail"
            end
            sleep(1)
        end
    end
end

"""
Stop the service's Kaimon and wait for it: on SIGTERM it closes its agents and gates' connections,
and one still running after [`EMBEDDED_STOP_SECONDS`](@ref) is killed.
"""
function stop_embedded!()
    e = EMBEDDED[]
    e === nothing && return
    p = e.process
    p === nothing || process_exited(p) || terminate(getpid(p); what = "The service's Kaimon", seconds = EMBEDDED_STOP_SECONDS)
    rm(embedded_pid_file(e); force = true)
    MCP_SERVING[] = false
    EMBEDDED[] = nothing
end

"What a client is told the tools are for, in place of the Kaimon's own instructions."
const MCP_INSTRUCTIONS = """
    A research group's knowledge base: papers, with their sections, passages and summaries. Search it
    by meaning and keywords, then read the papers and sections the results point to. Cite papers by
    their arXiv ids. The paper picked for the group each day, with its analysis, comes from `daily`.

    Work is planned here as tasks in projects (with the task tools, where the token allows them).
    Plan work of more than a step or two with `plan` rather than in a file; a person approves it on
    the board. To work on approved tasks, take one with `next_task`, mark its subtasks done as you go,
    report with `task_note`, and move it to review when it is finished. `next_task` also lists the
    questions asked of the agents: answer each with `task_note(kind="comment", reply_to=<its note>)`.
    When work concludes something worth keeping, record it with `finding_draft`, citing what it rests
    on; a person accepts it."""

"""
    rewrite_messages(f, body, content_type) -> Vector{UInt8}

Apply `f` to each JSON-RPC message in a response body: the body itself, or each `data:` event of
an event stream.
"""
function rewrite_messages(f, body::AbstractVector{UInt8}, content_type::AbstractString)
    text = String(copy(body))
    if occursin("text/event-stream", content_type)
        lines = map(split(text, '\n')) do l
            startswith(l, "data: ") || return l
            m = try JSON.parse(l[7:end]) catch; return l end
            return "data: " * JSON.json(f(m))
        end
        return Vector{UInt8}(join(lines, '\n'))
    end
    m = try JSON.parse(text) catch; return Vector{UInt8}(body) end
    return Vector{UInt8}(JSON.json(f(m)))
end

"""
    with_instructions(m; site = "", icon = "") -> Dict

The answer to `initialize`, with the knowledge base's instructions, and with `site`, the service's
address, its icon (the file `icon`) and web page in the server's details, which clients show the connection with.
"""
function with_instructions(m; site::AbstractString = "", icon::AbstractString = "")
    m isa AbstractDict && get(m, "result", nothing) isa AbstractDict && haskey(m["result"], "capabilities") || return m
    m["result"]["instructions"] = MCP_INSTRUCTIONS
    if !isempty(site)
        info = get!(Dict{String,Any}, m["result"], "serverInfo")
        # The small one inlined, so a client shows it without fetching anything; the full one by address.
        info["icons"] = [(isfile(icon) ? [Dict("src" => "data:image/png;base64," * base64encode(read(icon)), "mimeType" => "image/png",
                                                "sizes" => ["64x64"])] : [])...,
                         Dict("src" => "$site/apple-touch-icon.png", "mimeType" => "image/png", "sizes" => ["256x256"])]
        info["websiteUrl"] = site
    end
    return m
end

# What a tool's answer may not tell a caller about the machine serving it: its paths (a database, a
# PDF, a stack trace's files) and the addresses of the services the knowledge base uses.
const SERVER_PATH = r"(?<![\w.~])/(?:Users|home|private|tmp|var|opt|srv|mnt|Volumes)/[^\s\"'`)\]]*[^\s\"'`)\],.;:]"
const LOCAL_URL = r"https?://(?:localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)(?::\d+)?(?:[^\s\"'`)\]]*[^\s\"'`)\],.;:])?"

"`text` with the serving machine's paths and service addresses replaced by what they are."
function redact(text::AbstractString, c::Config)
    text = replace(text, rstrip(c.ollama_url, '/') => "[embedding service]", Qdrant.url() => "[vector store]")
    return replace(replace(text, LOCAL_URL => "[local service]"), SERVER_PATH => "[path]")
end

"Every string in a JSON-RPC message redacted (see [`redact`](@ref))."
redact_message(m::AbstractDict, c::Config) = (for (k, v) in m; m[k] = redact_message(v, c); end; m)
redact_message(m::AbstractVector, c::Config) = map!(v -> redact_message(v, c), m, m)
redact_message(m::AbstractString, c::Config) = redact(m, c)
redact_message(m, ::Config) = m

mcp_error(id, code, message; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json"],
                  JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => code, "message" => message))))

# Whose each MCP session is: the person whose token opened it, by the session's id, with when it was
# last used. The tools find who they work for here (see `mcp_caller`), so an agent cannot name
# someone else or reach projects its person cannot. A session unused for `MCP_SESSION_IDLE` is
# forgotten, and its client opens another when told it is unknown.
const MCP_CALLERS = Dict{String,Tuple{Caller,DateTime}}()
const MCP_CALLERS_LOCK = ReentrantLock()
const MCP_SESSION_IDLE = Day(7)

"The person who opened MCP session `sid`, or `nothing`."
session_owner(sid::AbstractString) = (s = lock(() -> get(MCP_CALLERS, sid, nothing), MCP_CALLERS_LOCK); s === nothing ? nothing : first(s))

"The person an agent's tool call is for, as a caller, when it came through `/mcp`: whose token opened its session."
function mcp_caller()
    sid = KaimonGate.current_caller()
    sid === nothing && return nothing
    return session_owner(sid)
end

# Whom each agent the service opens for a person works for, by the agent's id (a tutor's
# conversation, say): its tool calls act with that person's access and no more (see `agent_caller`).
const AGENT_CALLERS = Dict{String,Caller}()
const AGENT_CALLERS_LOCK = ReentrantLock()

"Agent `id`, which the service opened, works for `caller` until [`stop_acting!`](@ref)."
act_for!(id::AbstractString, caller::Caller) = lock(() -> (AGENT_CALLERS[String(id)] = caller; nothing), AGENT_CALLERS_LOCK)
stop_acting!(id::AbstractString) = lock(() -> (delete!(AGENT_CALLERS, String(id)); nothing), AGENT_CALLERS_LOCK)

"""
The person the agent making the current tool call works for, when the service opened it for someone
(see [`act_for!`](@ref)); `nothing` otherwise. Kaimon names the agent from a header only the
configs it writes for its own agents carry, which the `/mcp` proxy never passes on.
"""
function agent_caller()
    id = KaimonGate.current_agent_id()
    return id === nothing ? nothing : lock(() -> get(AGENT_CALLERS, id, nothing), AGENT_CALLERS_LOCK)
end

"Whether `a` and `b` are one token's holder: an MCP session is used only with the token that opened it."
same_holder(a::Caller, b::Caller) = a.user_id == b.user_id && a.token_id == b.token_id

"The name of the person an agent's tool call is for (see [`mcp_caller`](@ref)), or `nothing`."
mcp_person() = (c = mcp_caller(); c === nothing ? nothing : isempty(c.name) ? c.email : c.name)

caller_label(caller::Caller) = isempty(caller.name) ? caller.email : "$(caller.name) <$(caller.email)>"

"""
    event_stream_body(stream, f) -> HTTP.CallbackBody

An event stream from the service's Kaimon, passed on as it arrives, each event's JSON-RPC message
rewritten by `f` (see [`rewrite_messages`](@ref)): a tool's progress reaches the client while the
tool runs, so a long call is not taken for a stalled one.
"""
function event_stream_body(stream, f)
    raw, out = UInt8[], UInt8[]
    done = false
    # Where the first complete event ends: after its blank line.
    function event_end(b)
        a, c = findfirst(UInt8[0x0a, 0x0a], b), findfirst(UInt8[0x0d, 0x0a, 0x0d, 0x0a], b)
        ends = [last(x) for x in (a, c) if x !== nothing]
        return isempty(ends) ? nothing : minimum(ends)
    end
    function more!()
        while isempty(out) && !done
            if eof(stream)
                done = true
                isempty(raw) || append!(out, rewrite_messages(f, raw, "text/event-stream"))
                empty!(raw)
            else
                append!(raw, readavailable(stream))
                while (i = event_end(raw)) !== nothing
                    append!(out, rewrite_messages(f, raw[1:i], "text/event-stream"))
                    deleteat!(raw, 1:i)
                end
            end
        end
    end
    read_some(dst) = (more!(); n = min(length(dst), length(out)); copyto!(dst, 1, out, 1, n); deleteat!(out, 1:n); n)
    return HTTP.CallbackBody(read_some, () -> (try HTTP.closeread(stream) catch end; nothing))
end

"""
    mcp_response(kb, req; upstream) -> HTTP.Response

Answer a request to `/mcp`: from a token's holder only, for the methods in [`MCP_METHODS`](@ref)
(and `ping`, answered here), passed on to the service's Kaimon with the tools the token allows
and none of the client's own credentials or Kaimon headers. A tool call is written to the audit
log, and its answer comes back without the serving machine's paths and addresses (see
[`redact`](@ref)). A session belongs to the token holder who opened it (see [`MCP_CALLERS`](@ref)):
another's token cannot use it. An event stream comes back as it arrives (see
[`event_stream_body`](@ref)). By default the service's own Kaimon answers, waited for while the
service starts (see [`serving_upstream`](@ref)).
"""
function mcp_response(kb::KB, req::HTTP.Request; upstream::Union{EmbeddedKaimon,Nothing,Symbol} = :service)
    auth = HTTP.header(req, "Authorization", "")
    caller = startswith(auth, "Bearer ") ? token_caller(kb, strip(auth[8:end]); mcp = true) : ANONYMOUS
    caller.via == :anonymous &&
        return HTTP.Response(401, ["WWW-Authenticate" => "Bearer resource_metadata=\"$(resource_metadata_url(oauth_base(kb.config.shared, req)))\"",
                                   "Content-Type" => "text/plain"], "A token is needed.")
    upstream === :service && (upstream = serving_upstream())
    upstream === nothing && return HTTP.Response(503, ["Content-Type" => "text/plain", "Retry-After" => "30"], "MCP is not running.")
    # No stream of the server's own messages: clients then use only responses to their requests.
    req.method in ("POST", "DELETE") || return HTTP.Response(405, ["Allow" => "POST, DELETE"])
    tools = mcp_tools(caller)
    asked_sid = HTTP.header(req, "Mcp-Session-Id", "")
    method = ""
    if req.method == "POST"
        msg = try json_body(req) catch; nothing end
        msg isa AbstractDict && haskey(msg, "method") || return mcp_error(nothing, -32600, "Invalid request"; status = 400)
        id, method = get(msg, "id", nothing), String(msg["method"])
        method == "ping" && return HTTP.Response(200, ["Content-Type" => "application/json"],
                                                 JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict())))
        method in MCP_METHODS || return id === nothing ? HTTP.Response(202) : mcp_error(id, -32601, "Method not found")
    end
    # Every request but the one opening a session names a session this token's holder opened. One
    # unknown here (made up, ended, or opened before the service restarted) is refused: tools find
    # whom they act for from this map, and the client opens a new session on a 404.
    if method != "initialize"
        owner = isempty(asked_sid) ? nothing : session_owner(asked_sid)
        (owner !== nothing && same_holder(owner, caller)) ||
            return HTTP.Response(isempty(asked_sid) ? 400 : 404, ["Content-Type" => "text/plain"],
                                 isempty(asked_sid) ? "Open a session with initialize first." : "No such session.")
    end
    if req.method == "POST"
        if method == "tools/call"
            name = string(get(get(msg, "params", Dict()), "name", ""))
            allowed = replace(name, '.' => '_') in (replace(t, '.' => '_') for t in tools)
            audit!(kb, caller, "mcp.tool"; target = name, detail = Dict("allowed" => allowed))
            seen!(caller, name, "MCP")
            allowed || return mcp_error(id, -32602, "$name is not among your tools.")
        end
    end
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(upstream.key)",
               "X-Kaimon-Allowed-Tools" => join(tools, ",")]
    for h in MCP_CLIENT_HEADERS
        v = HTTP.header(req, h, "")
        isempty(v) || push!(headers, h => v)
    end
    any(h -> first(h) == "Accept", headers) || push!(headers, "Accept" => "application/json, text/event-stream")
    sent = body_bytes(req)
    push!(headers, "Content-Length" => string(length(sent)))
    stream = HTTP.open(req.method, "http://127.0.0.1:$(upstream.port)/mcp", headers; retry = false, connect_timeout = 5)
    write(stream, sent)
    HTTP.closewrite(stream)
    r = HTTP.startread(stream)
    out = ["Content-Type" => HTTP.header(r, "Content-Type", "application/json")]
    sid = HTTP.header(r, "Mcp-Session-Id", "")
    isempty(sid) || push!(out, "Mcp-Session-Id" => sid)
    ok = 200 <= r.status < 300
    lock(MCP_CALLERS_LOCK) do
        if method == "initialize"
            filter!(s -> now() - last(last(s)) <= MCP_SESSION_IDLE, MCP_CALLERS)
            ok && !isempty(sid) && (MCP_CALLERS[sid] = (caller, now()))
        elseif (req.method == "DELETE" && ok) || r.status == 404
            delete!(MCP_CALLERS, asked_sid)                  # ended here, or no longer known to Kaimon
        else
            MCP_CALLERS[asked_sid] = (caller, now())         # the holder's access as it is now
        end
    end
    f = method == "initialize" ? (m -> with_instructions(m; site = kb.config.shared.base_url, icon = site_icon(kb.config))) :
        method == "tools/call" ? (m -> redact_message(m, kb.config)) : identity
    occursin("text/event-stream", first(out)[2]) && return HTTP.Response(r.status, out, event_stream_body(stream, f))
    raw = read(stream)
    HTTP.closeread(stream)
    return HTTP.Response(r.status, out, f === identity ? raw : rewrite_messages(f, raw, first(out)[2]))
end
