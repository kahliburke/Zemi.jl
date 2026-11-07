# Who else is on the boards, and what people did there lately, for the boards to show beside their
# agents (see agent_activity.jl). Each open board reports its person's presence (`/api/presence`),
# kept in memory only, at one of three levels:
#
# - `hidden`: not shown at all, and forgotten;
# - `present` (the default): shown on the board they have open, and whom they follow, nothing more;
# - `planning`: also the task they have open, what they are writing on it, and what
#   is in view (the board's view, the card in the middle and the one pointed at, how far down the open
#   task), so others can follow them through a planning session instead of sharing a screen.
#
# What people did is the tasks' activity, which every level leaves as it is.

"How long after a board last reported its person still counts as there, in seconds: a board reports
at least every 20 seconds."
const PRESENT_SECONDS = 60

"How many of people's latest actions a board shows."
const RECENT_ACTIONS = 15
"How far back a board shows people's actions, in days."
const RECENT_DAYS = 7

"What one person's open board reports: the project, and in planning mode, the task, a draft and whom they follow."
Base.@kwdef struct BoardPresence
    name::String
    project::String
    planning::Bool = false
    open::String = ""
    draft_ref::String = ""
    draft::String = ""
    following::Int = 0
    view::String = ""
    at::Float64 = time()
end

const PRESENCE_BOARDS = Dict{Int,BoardPresence}()       # user => their presence
const PRESENCE_CHANGED = Threads.Condition()
const PRESENCE_VERSION = Ref(0)

presence_changed!() = lock(() -> (PRESENCE_VERSION[] += 1; notify(PRESENCE_CHANGED)), PRESENCE_CHANGED)

"""
    report_presence!(caller, mode; project, open = "", draft_ref = "", draft = "", following = 0, view = "", at = time())

Record what `caller`'s board reports: `mode` `"hidden"` (forget them), `"present"` or `"planning"`, on
`project`, and `following` (the id of the person they follow, if any). In planning mode `open`, the
draft written on `draft_ref` and `view` (what is in view, as the board describes it in JSON) are kept
too; otherwise not. The boards are told when what they would show changes, not on every report.
"""
function report_presence!(caller::Caller, mode::AbstractString; project::AbstractString = "", open::AbstractString = "",
                          draft_ref::AbstractString = "", draft::AbstractString = "", following::Integer = 0,
                          view::AbstractString = "", at::Float64 = time())
    caller.user_id === nothing && return
    mode in ("hidden", "present", "planning") || error("A presence is hidden, present or planning: $mode")
    planning = mode == "planning"
    p = BoardPresence(; name = caller.name, project = uppercase(strip(project)), planning,
                 open = planning ? uppercase(strip(open)) : "", draft_ref = planning ? uppercase(strip(draft_ref)) : "",
                 draft = planning ? first(String(draft), 4000) : "", following = Int(following),
                 view = planning ? first(String(view), 2000) : "", at)
    changed = lock(PRESENCE_CHANGED) do
        before = get(PRESENCE_BOARDS, caller.user_id, nothing)
        mode == "hidden" || isempty(p.project) ? delete!(PRESENCE_BOARDS, caller.user_id) : (PRESENCE_BOARDS[caller.user_id] = p)
        gone = [u for (u, q) in PRESENCE_BOARDS if at - q.at > PRESENT_SECONDS]
        foreach(u -> delete!(PRESENCE_BOARDS, u), gone)
        shown(q) = q === nothing ? nothing : (q.project, q.planning, q.open, q.draft_ref, q.draft, q.following, q.view)
        shown(before) != shown(get(PRESENCE_BOARDS, caller.user_id, nothing)) || !isempty(gone)
    end
    changed && presence_changed!()
    return
end

"""
    presence(kb, caller; at = time()) -> Vector{NamedTuple}

The other people with a board open, in the projects `caller` reaches: each `(; id, name, project,
planning, open, draft_ref, draft, following, view, at)`, the planning fields empty for one who is not
planning. Never `caller` themselves.
"""
function presence(kb::KB, caller::Caller; at::Float64 = time())
    entries = lock(() -> [(u, p) for (u, p) in PRESENCE_BOARDS if u != caller.user_id && at - p.at <= PRESENT_SECONDS], PRESENCE_CHANGED)
    seen = Dict{String,Bool}()
    sees(k) = get!(() -> project_access(kb, caller, k) >= VIEW, seen, k)
    out = [(; id = u, p.name, p.project, p.planning, p.open, p.draft_ref, p.draft, p.following, p.view, at = iso(p.at))
           for (u, p) in entries if sees(p.project)]
    return sort!(out; by = x -> x.name)
end

"""
    wait_presence(since; timeout = 25) -> Int

Wait until the presences change after version `since`, or `timeout` seconds pass; the version then.
"""
function wait_presence(since::Integer; timeout::Real = 25)
    lock(PRESENCE_CHANGED) do
        PRESENCE_VERSION[] == since || return PRESENCE_VERSION[]
        t = Timer(_ -> lock(() -> notify(PRESENCE_CHANGED), PRESENCE_CHANGED), timeout)
        try
            while PRESENCE_VERSION[] == since && isopen(t)
                wait(PRESENCE_CHANGED)
            end
        finally
            close(t)
        end
        return PRESENCE_VERSION[]
    end
end

"""
    people_did(kb, key, caller; at = time()) -> Vector{NamedTuple}

The latest of people's actions on project `key`'s tasks, the newest first: each `(; who, kind, ref,
title, text, detail, at)`. Not `caller`'s, nor agents'.
"""
people_did(kb::KB, key::AbstractString, caller::Caller; at::Float64 = time()) =
    [(; who = String(r.who), kind = String(r.kind), ref = String(r.ref), title = String(r.title),
        text = first(String(r.text), 200), detail = JSON.parse(String(r.detail)), at = String(r.at))
     for r in query(kb, """SELECT e.who, e.kind, e.text, e.detail, e.at, p.key || '-' || t.number AS ref, t.title
                           FROM task_events e JOIN tasks t ON t.id = e.task_id JOIN projects p ON p.id = t.project_id
                           WHERE p.key = ? AND e.by_agent = 0 AND e.who != ? AND e.at >= ?
                           ORDER BY e.at DESC, e.id DESC LIMIT ?""",
                    (uppercase(strip(key)), caller.name, iso(at - RECENT_DAYS * 86400), RECENT_ACTIONS))]

# What the caller's board reports, and the others' presences, waiting with `since` for a change.
route!("POST", "/api/presence"; need = "tasks.view") do c
    d = json_body(c)
    project = String(get(d, "project", ""))
    isempty(project) || project_access(c.kb, c.caller, project) >= VIEW || not_found("No project $project")
    report_presence!(c.caller, String(get(d, "mode", "present")); project, open = String(get(d, "open", "")),
                     draft_ref = String(get(d, "draft_ref", "")), draft = String(get(d, "draft", "")),
                     following = Int(get(d, "following", 0)), view = String(get(d, "view", "")))
    ok_json()
end
route!("GET", "/api/presence"; need = "tasks.view", waits = true) do c
    v = wait_presence(int_param(c.params, "since", -1))
    Dict("version" => v, "me" => something(c.caller.user_id, 0), "people" => Any[Dict(pairs(p)) for p in presence(c.kb, c.caller)])
end

# ── Ink ───────────────────────────────────────────────────────────────────────────────────────────
# A pen for planning sessions: where someone points with it, and what they draw, shown on
# the others' boards, fading in a moment. Each point is anchored to what is under it (a card, a
# control, a place in the open task), so screens laid out differently show it over the same things.
# Only those in a session on the board use or see it: whoever is planning there, and those following
# them. Points are kept in memory, a few seconds.

"How long strokes are kept for a board to collect, in seconds."
const INK_SECONDS = 10

const INK = NamedTuple[]                        # (seq, user, name, project, stroke, points, at), oldest first
const INK_CHANGED = Threads.Condition()
const INK_SEQ = Ref(0)

"Whether `caller` is in a session on project `key`'s board: planning there, or following someone who is."
function in_session(caller::Caller, key::AbstractString)
    k = uppercase(strip(key))
    lock(PRESENCE_CHANGED) do
        p = get(PRESENCE_BOARDS, something(caller.user_id, 0), nothing)
        (p === nothing || p.project != k) && return false
        p.planning && return true
        l = get(PRESENCE_BOARDS, p.following, nothing)
        return l !== nothing && l.planning && l.project == k
    end
end

"""
    add_ink!(caller, key, stroke, points; at = time())

Pass on where `caller` points, or part of what they draw, on project `key`'s board: `points`, as the
board encodes them (JSON), continuing stroke `stroke`. Refused unless they are in a session there.
"""
function add_ink!(caller::Caller, key::AbstractString, stroke::AbstractString, points::AbstractString; at::Float64 = time())
    in_session(caller, key) || error("Only someone in a session on the board, planning or following, points or draws on it")
    lock(INK_CHANGED) do
        INK_SEQ[] += 1
        push!(INK, (; seq = INK_SEQ[], user = something(caller.user_id, 0), name = caller.name, project = uppercase(strip(key)),
                      stroke = first(String(stroke), 40), points = first(String(points), 20_000), at))
        filter!(s -> at - s.at <= INK_SECONDS, INK)
        notify(INK_CHANGED)
    end
    return
end

"""
    ink_since(caller, key, since; timeout = 25) -> NamedTuple

The points and strokes on project `key`'s board after `since`, by others, waiting up to `timeout`
seconds for one: `(; seq, strokes)`, none for someone not in a session there (see `in_session`).
"""
function ink_since(caller::Caller, key::AbstractString, since::Integer; timeout::Real = 25)
    k = uppercase(strip(key))
    lock(INK_CHANGED) do
        if INK_SEQ[] == since
            t = Timer(_ -> lock(() -> notify(INK_CHANGED), INK_CHANGED), timeout)
            try
                while INK_SEQ[] == since && isopen(t)
                    wait(INK_CHANGED)
                end
            finally
                close(t)
            end
        end
        in_session(caller, k) || return (; seq = INK_SEQ[], strokes = NamedTuple[])
        return (; seq = INK_SEQ[], strokes = [(; s.seq, id = s.user, s.name, s.stroke, s.points) for s in INK
                                             if s.seq > since && s.project == k && s.user != caller.user_id])
    end
end

route!("POST", "/api/ink"; need = "tasks.view") do c
    d = json_body(c)
    add_ink!(c.caller, String(get(d, "project", "")), String(get(d, "stroke", "")), String(get(d, "points", "[]")))
    ok_json()
end
route!("GET", "/api/ink"; need = "tasks.view") do c
    r = ink_since(c.caller, get(c.params, "project", ""), int_param(c.params, "since", -1))
    Dict("seq" => r.seq, "strokes" => Any[Dict(pairs(s)) for s in r.strokes])
end
