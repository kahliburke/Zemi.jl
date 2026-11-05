# A project's review: what its work has done over time, for the board's review dashboard. Read off
# the tasks' activity: when each was created, and every move between columns.

"""
    project_review(kb, key; now = now(UTC)) -> Dict

The figures for project `key`'s review, its declined plans left out:

- `stats`: tasks `done` (and `done_week`, the last seven days), `open`, `in_review`, `cycle_hours` (the
  median from starting a task to its being done), `rework` (the share of tasks that reached review
  and were sent back at least once), `by_agents` (the share of done tasks an agent was assigned),
  `questions` and `questions_open`, and `commits` (recorded against its tasks, see task_commits.jl).
- `buckets`: the span from the first task to `now` in equal steps (`step` is "hour", "day" or
  "week", whichever gives a readable count), each with `start`, `created`, `done`, `sent_back`, `commits` and
  `columns`: how many tasks stood in each column at its end.
- `milestones`: each with `name`, `created_at`, `closed`, `closed_at` (`""` while open), `due`, `total` and `done`.
"""
function project_review(kb::KB, key::AbstractString; now::DateTime = Dates.now(UTC))
    pid = project_id(kb, key)
    ts = query(kb, "SELECT id, status, assignee, created_at FROM tasks WHERE project_id = ? AND declined_at IS NULL", (pid,))
    ids = Set(Int(t.id) for t in ts)
    events = [e for e in query(kb, """SELECT e.task_id, e.at, e.kind, e.detail, e.by_agent FROM task_events e
                                       JOIN tasks t ON t.id = e.task_id WHERE t.project_id = ? AND e.kind IN ('created', 'status', 'question')
                                       ORDER BY e.id""", (pid,)) if Int(e.task_id) in ids]
    # Each task's columns over time: (when, column), from its creation on.
    moves = Dict{Int,Vector{Tuple{DateTime,String}}}()
    created = Dict(Int(t.id) => parse_iso(t.created_at) for t in ts)
    sent_back = Tuple{Int,DateTime}[]
    for e in events
        e.kind == "question" && continue
        id, at, d = Int(e.task_id), parse_iso(e.at), JSON.parse(coalesce(e.detail, "{}"))
        if e.kind == "created"
            moves[id] = [(at, get(d, "status", "backlog"))]
        else
            push!(get!(() -> [(created[id], d["from"])], moves, id), (at, d["to"]))
            d["from"] == "review" && !(d["to"] in ("review", "done")) && e.by_agent == 0 && push!(sent_back, (id, at))
        end
    end
    for t in ts                                            # tasks from before activity was kept
        haskey(moves, Int(t.id)) || (moves[Int(t.id)] = [(created[Int(t.id)], String(t.status))])
    end
    commit_times = [parse_iso(String(r.at)) for r in query(kb, """SELECT DISTINCT c.id, c.at FROM commits c
                       JOIN task_commits tc ON tc.commit_id = c.id AND tc.relation != 'mentions' JOIN tasks t ON t.id = tc.task_id
                       WHERE t.project_id = ? AND t.declined_at IS NULL""", (pid,))]
    column_at(id, at) = (i = findlast(m -> m[1] <= at, moves[id]); i === nothing ? nothing : moves[id][i][2])

    first_at = isempty(created) ? now : minimum(values(created))
    span = now - first_at
    step, width = span <= Day(2) ? ("hour", Hour(1)) : span <= Day(90) ? ("day", Day(1)) : ("week", Week(1))
    start = floor(first_at, width)
    buckets = Dict{String,Any}[]
    for s in start:width:now
        e = s + width
        done_here = count(id -> any(m -> s <= m[1] < e && m[2] == "done", moves[id][2:end]), keys(moves))
        columns = Dict(c => 0 for c in TASK_STATUSES)
        for id in keys(moves)
            c = column_at(id, min(e, now))
            c === nothing || (columns[c] += 1)
        end
        push!(buckets, Dict("start" => iso(s),
                            "created" => count(at -> s <= at < e, values(created)), "done" => done_here,
                            "sent_back" => count(x -> s <= x[2] < e, sent_back), "commits" => count(at -> s <= at < e, commit_times),
                            "columns" => columns))
    end

    done_ids = [Int(t.id) for t in ts if t.status == "done"]
    cycle = Float64[]
    for id in done_ids
        ms = moves[id]
        started = findfirst(m -> m[2] == "in_progress", ms)
        finished = findlast(m -> m[2] == "done", ms)
        finished === nothing && continue
        from = started === nothing ? ms[1][1] : ms[started][1]
        push!(cycle, Dates.value(ms[finished][1] - from) / 3_600_000)
    end
    reached_review = count(id -> any(m -> m[2] == "review", moves[id]), keys(moves))
    reworked = length(unique(first.(sent_back)))
    questions = count(e -> e.kind == "question", events)
    open_q = length([q for q in [open_questions(kb; agents = true); open_questions(kb; agents = false)] if Int(q.task_id) in ids])
    stats = Dict(
        "done" => length(done_ids),
        "done_week" => count(id -> any(m -> m[2] == "done" && m[1] >= now - Day(7), moves[id]), done_ids),
        "open" => count(t -> t.status != "done", ts),
        "in_review" => count(t -> t.status == "review", ts),
        "cycle_hours" => isempty(cycle) ? nothing : round(sort(cycle)[cld(length(cycle), 2)]; digits = 1),
        "rework" => reached_review == 0 ? nothing : round(reworked / reached_review; digits = 2),
        "by_agents" => isempty(done_ids) ? nothing :
                       round(count(t -> t.status == "done" && startswith(t.assignee, "agent:"), ts) / length(done_ids); digits = 2),
        "questions" => questions, "questions_open" => open_q, "commits" => length(commit_times))
    # One done before completion times were kept is dated by when its work was finished: its last
    # task put away or moved to Done (work still open does not date it), or, with none, when it was made.
    closed_at(m) = m.closed == 0 ? "" : String(coalesce(m.closed_at,
        scalar(kb, "SELECT max(archived_at) FROM tasks WHERE milestone_id = ?", (m.id,)),
        scalar(kb, """SELECT max(e.at) FROM task_events e JOIN tasks t ON t.id = e.task_id
                      WHERE t.milestone_id = ? AND e.kind = 'status' AND json_extract(e.detail, '\$.to') = 'done'""", (m.id,)),
        m.created_at))
    milestones = [Dict("name" => String(m.name), "created_at" => String(m.created_at), "closed" => m.closed == 1, "closed_at" => closed_at(m),
                       "due" => String(coalesce(m.due, "")),
                       "total" => Int(scalar(kb, "SELECT count(*) FROM tasks WHERE milestone_id = ? AND parent_id IS NULL AND declined_at IS NULL", (m.id,))),
                       "done" => Int(scalar(kb, "SELECT count(*) FROM tasks WHERE milestone_id = ? AND parent_id IS NULL AND status = 'done'", (m.id,))))
                  for m in query(kb, "SELECT * FROM milestones WHERE project_id = ? ORDER BY created_at", (pid,))]
    return Dict("stats" => stats, "step" => step, "buckets" => buckets, "milestones" => milestones,
                "now" => iso(now))
end
