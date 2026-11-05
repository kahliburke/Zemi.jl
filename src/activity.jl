# Who is using the service now, so whoever looks after it can restart it at a quiet moment: each
# person's latest requests, from the site or an agent over /mcp, and the work running for them (jobs,
# the tutor answering, the site building). Kept in memory, so after a restart it starts empty.

"How recent a request must be for its person to count as active: a restart within it may interrupt them."
const ACTIVE_MINUTES = 10

"How recent a page's own polling must be for it to count as open."
const OPEN_MINUTES = 2

mutable struct Presence
    name::String
    email::String
    last::Union{DateTime,Nothing}       # their latest request that did something
    what::String                        # what it was
    via::String                         # "site" or "MCP"
    open::Union{DateTime,Nothing}       # the latest polling from one of their open pages
    times::Vector{DateTime}             # their requests within ACTIVE_MINUTES of the latest
end

const PRESENCE = Dict{Int,Presence}()
const PRESENCE_LOCK = ReentrantLock()

# What an open page asks for by itself, on a timer: the service's status, its jobs, the board's and
# findings' changes, a refreshing operations page. These say a page is open, not that anyone acted.
const POLLS = (["api", "status"], ["api", "jobs"], ["api", "tasks", "changes"], ["api", "ops"], ["api", "ops", "agents"])

function presence!(caller::Caller)
    p = get!(() -> Presence("", "", nothing, "", "", nothing, DateTime[]), PRESENCE, caller.user_id)
    p.name, p.email = caller.name, caller.email
    return p
end

"""
    seen!(caller, what, via; at = now(UTC))

Record that `caller` did `what` through `via` ("site" or "MCP"). Nothing for this machine's own
requests or anyone not signed in.
"""
function seen!(caller::Caller, what::AbstractString, via::AbstractString; at::DateTime = now(UTC))
    caller.user_id === nothing && return
    lock(PRESENCE_LOCK) do
        p = presence!(caller)
        p.last, p.what, p.via = at, String(what), String(via)
        filter!(t -> at - t < Minute(ACTIVE_MINUTES), p.times)
        push!(p.times, at)
    end
    return
end

"Record that a page of `caller`'s is open, asking for something by itself (see `POLLS`)."
function page_open!(caller::Caller; at::DateTime = now(UTC))
    caller.user_id === nothing && return
    lock(() -> (presence!(caller).open = at), PRESENCE_LOCK)
    return
end

"Record a request to the API: a page polling, or something its person did."
function request_seen!(caller::Caller, method::AbstractString, parts)
    caller.user_id === nothing && return
    # A board's presence reports and ink, sent on timers and as a pen moves, say a page is open too.
    (method == "GET" && any(==(parts), POLLS)) || parts in (["api", "presence"], ["api", "ink"]) ? page_open!(caller) :
        seen!(caller, "$method /" * join(parts, '/'), "site")
end

"""
    activity(; at = now(UTC)) -> NamedTuple

Who is using the service and what is running, as of `at`: `people` (each signed-in person seen since
the service started, the latest first, with whether they are `active` or have a page `open`),
`running` (what a restart would stop: jobs, the tutor answering, the site building), and `quiet`,
whether a restart now would interrupt no one.
"""
function activity(; at::DateTime = now(UTC))
    people = lock(PRESENCE_LOCK) do
        [(; name = p.name, email = p.email, last = p.last === nothing ? "" : iso(p.last), what = p.what, via = p.via,
            active = p.last !== nothing && at - p.last < Minute(ACTIVE_MINUTES),
            open = p.open !== nothing && at - p.open < Minute(OPEN_MINUTES),
            requests = count(t -> at - t < Minute(ACTIVE_MINUTES), p.times))
         for p in values(PRESENCE)]
    end
    sort!(people; by = p -> (p.active, p.open, p.last), rev = true)
    running = String[]
    for j in list_jobs()
        j.status == :running && push!(running, "job $(j.id) $(j.name): $(j.message)")
    end
    for (chat, doing) in lock(() -> collect(CHAT_DOING), CHAT_LOCK)
        push!(running, "the tutor answering in conversation $chat" * (isempty(doing) ? "" : ": $doing"))
    end
    lock(() -> SITE.building, SITE_LOCK) && push!(running, "the site building")
    quiet = isempty(running) && !any(p -> p.active || p.open, people)
    return (; people, running, quiet, active_minutes = ACTIVE_MINUTES)
end

"""
    format_activity(a = activity()) -> String

[`activity`](@ref) as text, for an agent deciding whether to restart the service.
"""
function format_activity(a = activity())
    io = IOBuffer()
    println(io, a.quiet ? "Quiet: a restart now interrupts no one." : "In use: a restart now would interrupt this.")
    for p in a.people
        (p.active || p.open) || continue
        who = isempty(p.name) ? p.email : p.name
        println(io, "- ", who, p.active ? ": $(p.what) through the $(p.via == "MCP" ? "MCP" : "site"), at $(p.last) ($(p.requests) requests in $(a.active_minutes) min)" : "",
                p.open ? (p.active ? "; a page open" : ": a page open") : "")
    end
    foreach(r -> println(io, "- ", r), a.running)
    return String(take!(io))
end
