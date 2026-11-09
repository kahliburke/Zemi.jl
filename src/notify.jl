# Notifications of what newly waits on people: what their Waiting on you shows (see `waiting`),
# pushed to the devices they turned notifications on for (see webpush.jl). Each round compares what
# waits on each person with what it saw last, and what is new is held a few seconds, so a burst of
# changes makes one notification. Nothing is pushed of what the person did themselves, or while they
# are looking at a board, where Waiting on you shows it.

"The parts of Waiting on you that are pushed, as the board names them. Findings to accept are not."
const NOTIFY_SECTIONS = ["proposed" => "to approve", "questions" => "to answer", "answered" => "answered",
                         "review" => "to review", "mine" => "yours"]

"How long the first of a burst of changes waits for the rest, in seconds."
const NOTIFY_HOLD = Ref(15.0)

"How often what waits on people is looked at, in seconds."
const NOTIFY_EVERY = 10

"""
How long after a board in view last asked for changes its person still counts as looking at it, in
seconds: longer than a board's request for changes waits (see `wait_tasks_changed`), so a board that
stopped asking (its page closed) stops counting soon after.
"""
const BOARD_SEEN_SECONDS = 40

"A device is dropped after this many sends in a row failed."
const PUSH_FAILURES = 20

const BOARD_SEEN = Dict{Int,Float64}()
const BOARD_SEEN_LOCK = ReentrantLock()

"Record that `caller` is looking at a board (its page is visible and focused, asking for changes)."
board_seen!(caller::Caller; at::Float64 = time()) =
    caller.user_id === nothing || lock(() -> (BOARD_SEEN[caller.user_id] = at), BOARD_SEEN_LOCK)

"Record that `caller` stopped looking at the board: its page lost the focus, or was hidden or closed."
board_left!(caller::Caller) =
    caller.user_id === nothing || lock(() -> delete!(BOARD_SEEN, caller.user_id), BOARD_SEEN_LOCK)

"Whether person `uid` has had a board in view within `BOARD_SEEN_SECONDS`."
board_in_view(uid::Integer; at::Float64 = time()) =
    lock(() -> at - get(BOARD_SEEN, uid, -Inf) <= BOARD_SEEN_SECONDS, BOARD_SEEN_LOCK)

clip_line(s::AbstractString, n::Integer = 160) =
    (t = strip(replace(s, r"\s+" => " ")); length(t) > n ? first(t, n - 1) * "…" : t)

"Whether person `me` made the latest change to task `task_id` themselves."
changed_by(kb::KB, task_id::Integer, me::AbstractString) = !isempty(query(kb, """
    SELECT 1 FROM task_events e WHERE e.id = (SELECT max(id) FROM task_events WHERE task_id = ?) AND e.by_agent = 0 AND e.by_person = ?""",
    (task_id, me)))

"""
    waiting_items(kb, caller) -> Vector{NamedTuple}

What waits on `caller` that may be pushed, each `(; key, section, ref, title, text, theirs)`: plans
to approve and tasks to review that concern them (see [`concerns`](@ref); the board shows them all),
questions asked of them by name, answers to theirs, and their open tasks, in the projects they see.
`theirs` is whether they made the change that put it there.
"""
function waiting_items(kb::KB, caller::Caller)
    me = person_id(caller)
    isempty(me) && return NamedTuple[]
    seen = Dict{String,Bool}()
    sees(ref) = get!(() -> (k = ref_project(ref); k !== nothing && project_access(kb, caller, k) >= VIEW), seen, ref)
    w = waiting(kb; me)
    out = NamedTuple[]
    item(section, key, t, text; theirs = false) = push!(out, (; key, section, ref = String(t.ref), title = String(t.title), text, theirs))
    for t in w.proposed
        sees(t.ref) && t.concerns && item("proposed", "proposed:$(t.ref)", t, t.title; theirs = changed_by(kb, task_ref(kb, t.ref), me))
    end
    for t in w.review
        sees(t.ref) && t.concerns && item("review", "review:$(t.ref)", t, t.title; theirs = changed_by(kb, task_ref(kb, t.ref), me))
    end
    for t in w.mine
        sees(t.ref) && item("mine", "mine:$(t.ref)", t, t.title; theirs = changed_by(kb, task_ref(kb, t.ref), me))
    end
    # Questions asked of them by name; one asked of anyone waits on the board.
    named = Set(q.note for q in waiting_questions(kb) if q.to_whom == "person" && q.to_person == me)
    for t in w.questions
        t.note in named && sees(t.ref) && item("questions", "questions:$(t.note)", t, "$(t.asker): $(t.question)")
    end
    for t in w.answered
        sees(t.ref) && item("answered", "answered:$(t.note)", t, "$(t.answerer): $(t.answer)")
    end
    return out
end

"The site's page `path` (`projects#PU-2`), from its root, as a notification opens it: on whatever address the browser has the site at."
page_path(path::AbstractString) = (i = findfirst('#', path); i === nothing ? "/$path.html" : "/$(path[1:i-1]).html$(path[i:end])")

"""
    notification(c, items) -> Dict

What a push says of `items` (see [`waiting_items`](@ref)): a `title`, a `body`, the `url` to open
(the task, for one). Each has no tag of its own, so none replaces another: a replaced one does not
show on a Mac's screen, only in its Notification Center.
"""
function notification(c::Config, items)
    heads = Dict("proposed" => "To approve", "questions" => "Question for you", "answered" => "Your question answered",
                 "review" => "To review", "mine" => "Assigned to you")
    if length(items) == 1
        i = only(items)
        return Dict("title" => "$(heads[i["section"]]) · $(i["ref"])", "body" => clip_line(i["text"], 240),
                    "url" => page_path("projects#" * i["ref"]))
    end
    lines = ["$(i["ref"]) $(lowercase(heads[i["section"]])): $(clip_line(i["text"], 90))" for i in items]
    more = length(lines) > 4 ? "\n… and $(length(lines) - 4) more" : ""
    key = first(split(items[1]["ref"], '-'))
    return Dict("title" => "$(length(items)) things wait on you", "body" => join(first(lines, 4), "\n") * more,
                "url" => page_path("projects#" * key))
end

"Person `uid`'s notification state: the sections they want, what was seen last (`nothing` before the first look), what is held."
function notify_state(kb::KB, uid::Integer)
    r = query(kb, "SELECT * FROM notify_people WHERE user_id = ?", (uid,))
    isempty(r) && return (; sections = first.(NOTIFY_SECTIONS), seen = nothing, pending = Dict{String,Any}[], since = nothing)
    s = first(r)
    return (; sections = ismissing(s.sections) || s.sections === nothing ? first.(NOTIFY_SECTIONS) : String.(JSON.parse(s.sections)),
              seen = ismissing(s.seen) || s.seen === nothing ? nothing : Set{String}(JSON.parse(s.seen)),
              pending = Dict{String,Any}[Dict{String,Any}(p) for p in JSON.parse(s.pending)],
              since = ismissing(s.pending_since) ? nothing : s.pending_since)
end

function save_notify_state!(kb::KB, uid::Integer; seen, pending, since)
    execute!(kb, """INSERT INTO notify_people (user_id, seen, pending, pending_since) VALUES (?, ?, ?, ?)
                    ON CONFLICT (user_id) DO UPDATE SET seen = excluded.seen, pending = excluded.pending, pending_since = excluded.pending_since""",
             (uid, JSON.json(sort!(collect(seen))), JSON.json(pending), since === nothing ? missing : since))
end

"""
    set_notify_sections!(kb, uid, sections)

Push to person `uid` only what is new in `sections` of their Waiting on you (see `NOTIFY_SECTIONS`).
"""
function set_notify_sections!(kb::KB, uid::Integer, sections)
    known = first.(NOTIFY_SECTIONS)
    bad = setdiff(String.(sections), known)
    isempty(bad) || error("No such part of Waiting on you: $(join(bad, ", ")) (known: $(join(known, ", ")))")
    execute!(kb, """INSERT INTO notify_people (user_id, sections) VALUES (?, ?)
                    ON CONFLICT (user_id) DO UPDATE SET sections = excluded.sections""", (uid, JSON.json(unique(String.(sections)))))
end

"""
    push_to_person!(kb, uid, message; send = web_push, endpoint = "") -> Int

Send `message` (see [`notification`](@ref)) to every device of person `uid`, or only the one at
`endpoint`, returning how many took it. A device its push service says is gone is dropped, as is one that failed `PUSH_FAILURES` times in a row.
"""
function push_to_person!(kb::KB, uid::Integer, message::AbstractDict; send = web_push, endpoint::AbstractString = "")
    payload = JSON.json(message)
    sent = 0
    devices = isempty(endpoint) ? query(kb, "SELECT * FROM push_devices WHERE user_id = ?", (uid,)) :
              query(kb, "SELECT * FROM push_devices WHERE user_id = ? AND endpoint = ?", (uid, endpoint))
    for d in devices
        status = try
            send(kb.config, d, payload)
        catch e
            @warn "Push to a device of user $uid failed" exception = e maxlog = 3
            0
        end
        if status in (200, 201, 202)
            sent += 1
            execute!(kb, "UPDATE push_devices SET last_sent = ?, failures = 0 WHERE id = ?", (now_iso(), d.id))
        elseif status in (404, 410) || d.failures + 1 >= PUSH_FAILURES
            execute!(kb, "DELETE FROM push_devices WHERE id = ?", (d.id,))
        else
            execute!(kb, "UPDATE push_devices SET failures = failures + 1 WHERE id = ?", (d.id,))
        end
    end
    return sent
end

"""
    notify_person!(kb, uid; at = time(), send = web_push)

One round for person `uid`: what newly waits on them, in the sections they want and not of their
own doing, joins what is held; what stopped waiting leaves it. Once the first of it has waited
`NOTIFY_HOLD` seconds it is sent as one notification. While they have a board in view, nothing is
held or sent. The first look only notes what already waits.
"""
function notify_person!(kb::KB, uid::Integer; at::Float64 = time(), send = web_push)
    caller = account_caller(kb, uid, :session)
    caller.user_id === nothing && return
    st = notify_state(kb, uid)
    items = waiting_items(kb, caller)
    keys = Set(i.key for i in items)
    if st.seen === nothing
        save_notify_state!(kb, uid; seen = keys, pending = Dict{String,Any}[], since = nothing)
        return
    end
    pending = filter(p -> p["key"] in keys, st.pending)
    held = Set(p["key"] for p in pending)
    for i in items
        (i.key in st.seen || i.key in held || i.theirs || !(i.section in st.sections)) && continue
        push!(pending, Dict{String,Any}("key" => i.key, "section" => i.section, "ref" => i.ref, "text" => i.text))
    end
    board_in_view(uid; at) && empty!(pending)
    since = isempty(pending) ? nothing : something(st.since, string(at))
    if !isempty(pending) && at - parse(Float64, since) >= NOTIFY_HOLD[]
        push_to_person!(kb, uid, notification(kb.config, pending); send)
        empty!(pending)
        since = nothing
    end
    save_notify_state!(kb, uid; seen = keys, pending, since)
end

"""
    notify_round!(kb; at = time(), send = web_push)

A round of [`notify_person!`](@ref) for everyone with a device to push to.
"""
function notify_round!(kb::KB; at::Float64 = time(), send = web_push)
    for r in query(kb, "SELECT DISTINCT d.user_id FROM push_devices d JOIN users u ON u.id = d.user_id WHERE u.disabled = 0")
        try
            notify_person!(kb, Int(r.user_id); at, send)
        catch e
            @warn "Notifying user $(r.user_id) failed" exception = (e, catch_backtrace()) maxlog = 3
        end
    end
end

"Push what newly waits on people, every `NOTIFY_EVERY` seconds, in the shared service."
follow_notifications(kb::KB) = every!(() -> notify_round!(kb), "Pushing notifications"; seconds = NOTIFY_EVERY)

# ── The API ───────────────────────────────────────────────────────────────────────────────────────

"Person `uid`'s devices, for their settings: each with when it was added and last sent to."
push_devices(kb::KB, uid::Integer) =
    [(; id = Int(d.id), d.label, d.created_at, last_sent = coalesce(d.last_sent, ""), d.endpoint)
     for d in query(kb, "SELECT * FROM push_devices WHERE user_id = ? ORDER BY id", (uid,))]

"""
    add_push_device!(kb, uid; endpoint, p256dh, auth, label = "")

Push to the browser whose subscription is `endpoint`, `p256dh` and `auth` for person `uid`. A
browser subscribed before, by someone else signed in on it then, now notifies `uid`.
"""
function add_push_device!(kb::KB, uid::Integer; endpoint::AbstractString, p256dh::AbstractString, auth::AbstractString,
                          label::AbstractString = "")
    why = push_endpoint_problem(endpoint)
    why === nothing || error("Not a push service's address: $why")
    length(unb64url(p256dh)) == 65 && length(unb64url(auth)) == 16 || error("Not a browser's push keys")
    execute!(kb, """INSERT INTO push_devices (user_id, endpoint, p256dh, auth, label, created_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (endpoint) DO UPDATE SET user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
                                                         label = excluded.label, failures = 0""",
             (uid, endpoint, p256dh, auth, first(strip(label), 80), now_iso()))
end

remove_push_device!(kb::KB, uid::Integer, endpoint::AbstractString) =
    execute!(kb, "DELETE FROM push_devices WHERE user_id = ? AND endpoint = ?", (uid, endpoint))

push_uid(c) = (c.caller.user_id === nothing && error("Notifications are for people signed in to the shared service"); c.caller.user_id)

route!("GET", "/api/push") do c
    uid = push_uid(c)
    st = notify_state(c.kb, uid)
    Dict("key" => push_public_key(c.kb.config), "sections" => st.sections,
         "all_sections" => [Dict("id" => k, "label" => l) for (k, l) in NOTIFY_SECTIONS],
         "devices" => [Dict(pairs(d)) for d in push_devices(c.kb, uid)])
end
route!("POST", "/api/push/devices") do c
    d = json_body(c)
    keys = get(d, "keys", Dict())
    add_push_device!(c.kb, push_uid(c); endpoint = string(get(d, "endpoint", "")), p256dh = string(get(keys, "p256dh", "")),
                     auth = string(get(keys, "auth", "")), label = string(get(d, "label", "")))
    Dict("ok" => true)
end
route!("POST", "/api/push/devices/remove") do c
    remove_push_device!(c.kb, push_uid(c), string(get(json_body(c), "endpoint", "")))
    Dict("ok" => true)
end
route!("POST", "/api/push/sections") do c
    set_notify_sections!(c.kb, push_uid(c), get(json_body(c), "sections", String[]))
    Dict("ok" => true)
end
route!("POST", "/api/push/test") do c
    uid = push_uid(c)
    # To the device just turned on, when it is named.
    n = push_to_person!(c.kb, uid, Dict("title" => "Notifications are on",
                                        "body" => "Questions for you, answers to yours, plans and work to review, and tasks assigned to you will show here.",
                                        "url" => page_path("projects")); endpoint = string(get(json_body(c), "endpoint", "")))
    Dict("sent" => n)
end
