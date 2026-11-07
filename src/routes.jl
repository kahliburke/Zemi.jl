# The API's routes: each request's method and path, the permission it needs, and what answers it,
# declared with `route!` beside the code it serves (api.jl, admin.jl, task_api.jl, media.jl).

"""
A request a route answers: the knowledge base, the request, who made it, its query, and the parts
of its path the route names (`c[:key]` for a route's `:key`).
"""
struct APICall
    kb::KB
    req::HTTP.Request
    caller::Caller
    params::Dict{String,String}
    path::Dict{Symbol,String}
end
Base.getindex(c::APICall, k::Symbol) = c.path[k]

body_bytes(c::APICall) = body_bytes(c.req)
json_body(c::APICall) = json_body(c.req)

"Field `k` of a request's body, or `nothing` when it is absent or null: what a change leaves as it is."
opt(d, k) = haskey(d, k) && d[k] !== nothing ? d[k] : nothing

"Who made a request, as tasks and findings record them."
person_of(c::APICall) = person(caller_name(c.caller); id = person_id(c.caller))

"""
One route: its method, its path (`/api/tasks/:task/notes`, with `*paper` last for the rest of the
path, a paper id with a slash in it), the permission it needs, and the project access it needs in
the project its path names (`:key`, or that of a `:task` or `:finding`; see `need_project!`).
`viewing_as` routes are open to an admin viewing as someone whatever that person lacks.
"""
struct Route
    method::String
    pattern::String
    parts::Vector{Union{String,Symbol}}
    rest::Union{Symbol,Nothing}
    need::String
    project::Union{Int,Nothing}
    viewing_as::Bool
    waits::Bool
    f::Function
end

# Literal parts before named ones, so `/api/tasks/search` is not taken for a task.
specificity(r::Route) = join((p isa Symbol ? '1' : '0' for p in r.parts)) * (r.rest === nothing ? "" : "2")

"The routes, most specific first. Replaced whole on each change, so a request reads a complete table."
const ROUTES = Ref(Route[])
const ROUTES_LOCK = ReentrantLock()

"""
    route!(f, method, pattern; need = "read", project = nothing, viewing_as = false, waits = false)

Answer `method` requests to `pattern` with `f(c::APICall)`, for callers with permission `need`. What
`f` returns is sent as JSON, unless it is a response. A route that `waits` holds each request until
something changes (a long poll), so its time is waiting, counted apart from the others' (see
[`record!`](@ref)). Declaring a route again (as Revise does when its code changes) replaces it.
"""
function route!(f, method::AbstractString, pattern::AbstractString; need::AbstractString = "read",
                project::Union{Integer,Nothing} = nothing, viewing_as::Bool = false, waits::Bool = false)
    segs = filter(!isempty, split(pattern, '/'))
    rest = !isempty(segs) && startswith(last(segs), '*') ? Symbol(chop(pop!(segs); head = 1, tail = 0)) : nothing
    parts = Union{String,Symbol}[startswith(s, ':') ? Symbol(s[2:end]) : String(s) for s in segs]
    if project !== nothing
        any(in((:key, :task, :finding)), parts) || error("Route $method $pattern names no project (:key, :task or :finding)")
    end
    r = Route(method, pattern, parts, rest, need, project, viewing_as, waits, f)
    lock(ROUTES_LOCK) do
        ROUTES[] = sort!([filter(x -> (x.method, x.pattern) != (method, pattern), ROUTES[]); r]; by = specificity)
    end
    return r
end

"The parts of `parts` route `r` names, or `nothing` when it does not match."
function match_route(r::Route, parts)
    n = length(r.parts)
    (r.rest === nothing ? length(parts) == n : length(parts) > n) || return nothing
    path = Dict{Symbol,String}()
    for (p, x) in zip(r.parts, parts)
        p isa Symbol ? (path[p] = x) : p == x || return nothing
    end
    r.rest === nothing || (path[r.rest] = join(parts[n+1:end], '/'))
    return path
end

"The route answering `method` on the path `parts`, with the parts it names, or `nothing`."
function find_route(method::AbstractString, parts)
    for r in ROUTES[]
        r.method == method || continue
        path = match_route(r, parts)
        path === nothing || return r, path
    end
    return nothing
end

"The project a route's path names: by its key, or by a task's or finding's reference."
function route_project(c::APICall)
    haskey(c.path, :key) && return c[:key]
    for kind in (:task, :finding)
        haskey(c.path, kind) || continue
        k = ref_project(c[kind])
        k === nothing && not_found("No $kind $(c[kind])")
        return k
    end
end

"""
What a person is told of a failure: the reason for a refusal, or only that something went wrong,
its details (paths, queries) staying in the log (see `log_failure`).
"""
client_message(e) = something(reason(e), "Something went wrong on the service; its log has the details")

"""
A request that failed, in the log: one refused with a reason (no such project, a key taken) as a
warning with that reason, anything else as an error with where it happened.
"""
log_failure(req::HTTP.Request, e, bt) =
    reason(e) === nothing ? @error("API request failed", target = req.target, exception = (e, bt)) :
                            @warn("API request refused: $(reason(e))", target = req.target)

"""
    handle(kb, req, caller = local_caller()) -> HTTP.Response

Answer one request from `caller` with its route, if they have the permission it needs. Whether a
change is allowed at all from where it came (this machine's pages, or the shared service's own) is
the server's to decide before it gets here. Failures come back as JSON with a 4xx or 500 status
(see `error_status`), and every change, done or refused, goes in the audit log.
"""
function handle(kb::KB, req::HTTP.Request, caller::Caller = local_caller())
    req.method == "OPTIONS" && return HTTP.Response(204)
    uri = HTTP.URI(req.target)
    params = HTTP.queryparams(uri)
    parts = filter(!isempty, split(HTTP.unescapeuri(uri.path), '/'))
    found = find_route(req.method, parts)
    if found === nothing
        known = any(r -> match_route(r, parts) !== nothing, ROUTES[])
        return json_response(Dict("error" => known ? "Not with $(req.method)." : "No such endpoint."); status = known ? 405 : 404)
    end
    route, path = found
    if !(can(caller, route.need) || route.viewing_as && caller.admin !== nothing)
        signed_in = caller.via != :anonymous
        return json_response(Dict("error" => signed_in ? "Not permitted ($(route.need))." : "Sign in.",
                                  "permission" => route.need); status = signed_in ? 403 : 401)
    end
    request_seen!(caller, req.method, parts)               # who is using the service (see activity.jl)
    c = APICall(kb, req, caller, params, path)
    r = try
        # The jobs a request starts are its caller's to follow (see `JOB_STARTERS`).
        x = task_local_storage(:kb_caller, caller) do
            route.project === nothing || need_project!(kb, caller, route_project(c), route.project)
            route.f(c)
        end
        x isa HTTP.Response ? x : json_response(x)
    catch e
        log_failure(req, e, catch_backtrace())
        # A document dropped here, with its drop, for the page to offer adding it anyway.
        json_response(Dict("error" => client_message(e), (e isa DroppedError ? ["dropped" => drop_json(e.drop)] : [])...);
                      status = error_status(e))
    end
    req.method == "GET" || parts in UNAUDITED || audit_write!(kb, caller, req, parts, params, r)
    return r
end

"""
The writes the audit log leaves out: a board's presence and its pen, sent every few seconds while a
board is open, which report where someone is and change nothing.
"""
const UNAUDITED = (["api", "presence"], ["api", "ink"])

"Record a change in the audit log: its route, what it was done to, and how it went."
function audit_write!(kb::KB, caller::Caller, req::HTTP.Request, parts, params, r::HTTP.Response)
    detail = Dict{String,Any}(k => v for (k, v) in params if k in AUDITED_FIELDS || k in ("name", "title"))
    if occursin("json", lowercase(HTTP.header(req, "Content-Type", "application/json")))
        b = try json_body(req) catch; nothing end
        b isa AbstractDict && merge!(detail, Dict(k => v for (k, v) in b if k in AUDITED_FIELDS))
    end
    detail["status"] = r.status
    audit!(kb, caller, join(parts[2:end], '/'); detail)
end
