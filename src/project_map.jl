# A map of a project's work: where each line of it stands, drawn from the board. The service gathers
# a project's tasks (archived ones too), milestones, activity, commits, findings and links in one
# document (`project_map`, served at /api/projects/<KEY>/map); a notebook reads it from there
# (`remote_project_map`) or from a local knowledge base, and groups the tasks into threads.

"""
    project_map(kb, key) -> Dict

Everything a map of project `key` is drawn from, as JSON: the `project`, its `milestones`, every task
not declined (archived ones included), the tasks' `links`, their `activity` (notes and moves), the
`commits` recorded against them, the project's `findings` with the tasks they rest on, the
`questions` still open (`by_agent`: an agent's, waiting on people), and its codebase as the
knowledge base has read it (see [`code_map`](@ref)). Read it with [`read_project_map`](@ref).
"""
function project_map(kb::KB, key::AbstractString)
    key = uppercase(strip(key))
    pid = project_id(kb, key)
    p = first(query(kb, "SELECT key, name, description, created_at FROM projects WHERE id = ?", (pid,)))
    str(x) = ismissing(x) ? "" : String(x)
    ref = "p.key || '-' || t.number"
    tasks = [Dict("ref" => String(r.ref), "title" => String(r.title), "status" => String(r.status), "priority" => Int(r.priority),
                  "milestone" => str(r.milestone), "parent" => ismissing(r.parent) ? "" : "$key-$(r.parent)",
                  "assignee" => str(r.assignee), "created_at" => String(r.created_at), "updated_at" => String(r.updated_at),
                  "archived_at" => str(r.archived_at))
             for r in query(kb, """SELECT $ref AS ref, t.title, t.status, t.priority, m.name AS milestone, pt.number AS parent,
                                          t.assignee, t.created_at, t.updated_at, t.archived_at
                                   FROM tasks t JOIN projects p ON p.id = t.project_id LEFT JOIN milestones m ON m.id = t.milestone_id
                                   LEFT JOIN tasks pt ON pt.id = t.parent_id
                                   WHERE t.project_id = ? AND t.declined_at IS NULL ORDER BY t.number""", (pid,))]
    within = "FROM tasks t JOIN projects p ON p.id = t.project_id"
    links = [Dict("task" => String(r.ref), "kind" => String(r.kind), "target" => String(r.target), "label" => str(r.label))
             for r in query(kb, "SELECT $ref AS ref, l.kind, l.target, l.label $within JOIN task_links l ON l.task_id = t.id WHERE t.project_id = ?", (pid,))]
    activity = [Dict("task" => String(r.ref), "at" => String(r.at), "kind" => String(r.kind), "by_agent" => r.by_agent == 1, "to" => str(r.to))
                for r in query(kb, """SELECT $ref AS ref, e.at, e.kind, e.by_agent, CASE e.kind WHEN 'status' THEN json_extract(e.detail, '\$.to') END AS "to"
                                      $within JOIN task_events e ON e.task_id = t.id WHERE t.project_id = ? ORDER BY e.id""", (pid,))]
    commits = [Dict("task" => String(r.ref), "at" => String(r.at), "subject" => String(r.subject))
               for r in query(kb, """SELECT $ref AS ref, c.at, c.subject $within JOIN task_commits tc ON tc.task_id = t.id AND tc.relation != 'mentions'
                                     JOIN commits c ON c.id = tc.commit_id WHERE t.project_id = ? ORDER BY c.at""", (pid,))]
    # A finding rests on the tasks its evidence names, and on those that link to it.
    rests = Dict{String,Vector{String}}()
    for r in query(kb, """SELECT p.key || '-F' || f.number AS finding, e.target AS task FROM findings f JOIN projects p ON p.id = f.project_id
                          JOIN finding_evidence e ON e.finding_id = f.id AND e.kind = 'task' WHERE f.project_id = ?
                          UNION SELECT l.target, $ref $within JOIN task_links l ON l.task_id = t.id AND l.kind = 'finding' WHERE t.project_id = ?""", (pid, pid))
        push!(get!(rests, String(r.finding), String[]), uppercase(String(r.task)))
    end
    findings = [Dict("ref" => String(r.ref), "claim" => String(r.claim), "status" => String(r.status), "created_at" => String(r.created_at),
                     "tasks" => sort!(unique(get(rests, String(r.ref), String[]))))
                for r in query(kb, """SELECT p.key || '-F' || f.number AS ref, f.claim, f.status, f.created_at FROM findings f
                                      JOIN projects p ON p.id = f.project_id WHERE f.project_id = ? AND f.archived_at IS NULL ORDER BY f.number""", (pid,))]
    refs = Dict(Int(r.id) => String(r.ref) for r in query(kb, "SELECT t.id, $ref AS ref $within WHERE t.project_id = ?", (pid,)))
    questions = [Dict("task" => refs[Int(q.task_id)], "text" => String(q.text), "by_agent" => agents)
                 for agents in (true, false) for q in open_questions(kb; agents) if haskey(refs, Int(q.task_id))]
    return Dict("project" => Dict("key" => key, "name" => String(p.name), "description" => str(p.description), "created_at" => String(p.created_at)),
                "generated_at" => now_iso(),
                "milestones" => [Dict(String(k) => v for (k, v) in pairs(m) if k in (:name, :description, :start, :due, :closed, :closed_at, :created_at))
                                 for m in milestones(kb, key)],
                "tasks" => tasks, "links" => links, "activity" => activity, "commits" => commits,
                "findings" => findings, "questions" => questions, "code" => code_map(kb, key))
end

"""
    code_map(kb, key) -> Union{Dict,Nothing}

Project `key`'s codebase as the knowledge base has read it, or `nothing` without one: its `id`, its
`summary`, its `files`, each with its `path`, `lines`, `definitions`, its `summary`, `work` (the lines
that each of the project's tasks changed in it, through the commits recorded against them) and
`used_by` (the notebooks that call what it defines), and its `notebooks` (files under `notebooks/`),
each with its `path`, `lines`, `summary`, `uses` (the files whose definitions it calls) and the
project's `tasks` that link to it.
"""
function code_map(kb::KB, key::AbstractString)
    i = findfirst(p -> p.key == uppercase(strip(key)), projects(kb))
    i === nothing && return nothing
    id = projects(kb)[i].codebase
    isempty(id) && return nothing
    files = Dict{String,Any}[]
    walk(n) = n["kind"] == "file" ? push!(files, n) : foreach(walk, n["children"])
    walk(code_tree(kb, id))
    work = Dict{String,Dict{String,Int}}()
    for r in query(kb, """SELECT p.key || '-' || t.number AS ref, c.files FROM commits c
                          JOIN task_commits tc ON tc.commit_id = c.id AND tc.relation != 'mentions'
                          JOIN tasks t ON t.id = tc.task_id JOIN projects p ON p.id = t.project_id
                          WHERE p.key = ? AND c.codebase_id = ?""", (uppercase(strip(key)), paper_id(kb, id)))
        for f in JSON.parse(r.files)
            w = get!(work, String(f["path"]), Dict{String,Int}())
            w[String(r.ref)] = get(w, String(r.ref), 0) + Int(f["added"]) + Int(f["removed"])
        end
    end
    p = paper_row(kb, id)
    notebook(f) = startswith(f["path"], "notebooks/") && endswith(f["path"], ".jl")
    uses = notebook_uses(kb, id, [f["path"] for f in files if notebook(f)], [f["path"] for f in files if !notebook(f) && endswith(f["path"], ".jl")])
    attached = Dict{String,Vector{String}}()
    for r in query(kb, """SELECT p.key || '-' || t.number AS ref, l.target FROM task_links l JOIN tasks t ON t.id = l.task_id
                          JOIN projects p ON p.id = t.project_id WHERE p.key = ? AND l.kind = 'notebook'""", (uppercase(strip(key)),))
        push!(get!(attached, String(r.target), String[]), String(r.ref))
    end
    entry(f) = Dict("path" => f["path"], "lines" => something(f["lines"], 0), "summary" => something(f["summary"], ""))
    return Dict("id" => id, "summary" => coalesce(p.abstract, ""),
                "files" => [merge(entry(f), Dict("definitions" => something(f["definitions"], 0), "work" => get(work, f["path"], Dict{String,Int}()),
                                                 "used_by" => sort([n for (n, u) in uses if f["path"] in u])))
                            for f in files if !notebook(f)],
                "notebooks" => [merge(entry(f), Dict("uses" => get(uses, f["path"], String[]), "tasks" => get(attached, f["path"], String[])))
                                for f in files if notebook(f)])
end

"""
    notebook_uses(kb, id, notebooks, sources) -> Dict{String,Vector{String}}

For each of codebase `id`'s `notebooks`, the `sources` (file paths) whose definitions it calls: a
function by `name(`, a type or constant by its name.
"""
function notebook_uses(kb::KB, id::AbstractString, notebooks, sources)
    names = Dict(path => unique(d.name for d in file_definitions(kb, id, path) if occursin(r"^[A-Za-z_][A-Za-z0-9_!]*$", d.name))
                 for path in sources)
    pattern(n) = isuppercase(first(n)) ? Regex("\\b\\Q$(n)\\E\\b") : Regex("\\b\\Q$(n)\\E\\(")
    pats = Dict(path => [pattern(n) for n in ns] for (path, ns) in names)
    pid = paper_id(kb, id)
    out = Dict{String,Vector{String}}()
    for nb in notebooks
        ord = scalar(kb, "SELECT ord FROM sections WHERE paper_id = ? AND title = ?", (pid, nb))
        ismissing(ord) && continue
        text = join((b.text for b in query(kb, "SELECT text FROM blocks WHERE paper_id = ? AND section = ?", (pid, ord))), "\n")
        out[nb] = sort([path for path in sources if any(r -> occursin(r, text), pats[path])])
    end
    return out
end

"The token the notebooks read the shared service with: `kb_token` beside the config file, made on the site's Account page."
remote_token() = (f = joinpath(dirname(config_path()), "kb_token"); isfile(f) ? strip(read(f, String)) :
                  error("No token at $f: make one on the knowledge base's Account page (seeing tasks), and save it there"))

"""
    remote_project_map(key; url, token = remote_token()) -> ProjectMap

Project `key`'s map (see [`project_map`](@ref)) as the shared service at `url` has it.
"""
function remote_project_map(key::AbstractString; url::AbstractString, token::AbstractString = remote_token())
    r = HTTP.get("$(rstrip(url, '/'))/api/projects/$(uppercase(key))/map", ["Authorization" => "Bearer $token"]; status_exception = false)
    r.status == 200 || error("The knowledge base at $url answered $(r.status): $(String(r.body))")
    return read_project_map(JSON.parse(String(r.body)))
end

"A task on the map. `archived` is when it was put away, if it was."
struct MapTask
    ref::String
    title::String
    status::String
    priority::Int
    milestone::String
    parent::String
    assignee::String
    created::DateTime
    updated::DateTime
    archived::Union{DateTime,Nothing}
end

"A finding on the map, with the tasks it rests on."
struct MapFinding
    ref::String
    claim::String
    status::String
    created::DateTime
    tasks::Vector{String}
end

"""
A project's map (see [`project_map`](@ref)): its tasks by ref, in board number order (`order`),
milestones, links, dated activity (notes and moves, and commits; a move's column `to`), findings,
open questions, and its codebase's files (`code`, with how many lines each task changed in each) and
summary (`code_summary`).
"""
struct ProjectMap
    key::String
    name::String
    description::String
    created::DateTime
    generated::DateTime
    milestones::Vector{NamedTuple{(:name, :description, :start, :due, :closed),Tuple{String,String,Date,Union{Date,Nothing},Bool}}}
    tasks::Dict{String,MapTask}
    order::Vector{String}
    links::Vector{NamedTuple{(:task, :kind, :target),Tuple{String,String,String}}}
    activity::Vector{NamedTuple{(:task, :at, :kind, :to),Tuple{String,DateTime,String,String}}}
    findings::Vector{MapFinding}
    questions::Vector{NamedTuple{(:task, :text, :by_agent),Tuple{String,String,Bool}}}
    code::Vector{NamedTuple{(:path, :lines, :definitions, :summary, :work, :used_by),Tuple{String,Int,Int,String,Dict{String,Int},Vector{String}}}}
    code_summary::String
    notebooks::Vector{NamedTuple{(:path, :lines, :summary, :uses, :tasks),Tuple{String,Int,String,Vector{String},Vector{String}}}}
end

"A [`ProjectMap`](@ref) from [`project_map`](@ref)'s document (as written, or parsed from JSON)."
function read_project_map(d::AbstractDict)
    p = d["project"]
    s(x) = x === nothing ? "" : String(x)
    code = get(d, "code", nothing)
    tasks = [MapTask(t["ref"], t["title"], t["status"], Int(t["priority"]), s(t["milestone"]), s(t["parent"]), s(t["assignee"]),
                     parse_iso(t["created_at"]), parse_iso(t["updated_at"]), isempty(s(t["archived_at"])) ? nothing : parse_iso(t["archived_at"]))
             for t in d["tasks"]]
    moves = [(; task = String(a["task"]), at = parse_iso(a["at"]), kind = String(a["kind"]), to = s(get(a, "to", ""))) for a in d["activity"]]
    worked = [(; task = String(c["task"]), at = parse_iso(c["at"]), kind = "commit", to = "") for c in d["commits"]]
    return ProjectMap(p["key"], p["name"], s(p["description"]), parse_iso(p["created_at"]), parse_iso(d["generated_at"]),
                      [(; name = String(m["name"]), description = s(m["description"]),
                          start = Date(isempty(s(get(m, "start", ""))) ? first(s(get(m, "created_at", d["generated_at"])), 10) : m["start"]),
                          due = isempty(s(m["due"])) ? nothing : Date(m["due"]), closed = Bool(m["closed"])) for m in d["milestones"]],
                      Dict(t.ref => t for t in tasks), [t.ref for t in tasks],
                      [(; task = String(l["task"]), kind = String(l["kind"]), target = String(l["target"])) for l in d["links"]],
                      sort!([moves; worked]; by = a -> a.at),
                      [MapFinding(f["ref"], f["claim"], f["status"], parse_iso(f["created_at"]), String.(f["tasks"])) for f in d["findings"]],
                      [(; task = String(q["task"]), text = String(q["text"]), by_agent = Bool(q["by_agent"])) for q in d["questions"]],
                      code === nothing ? NamedTuple{(:path, :lines, :definitions, :summary, :work, :used_by),Tuple{String,Int,Int,String,Dict{String,Int},Vector{String}}}[] :
                          [(; path = String(f["path"]), lines = Int(f["lines"]), definitions = Int(f["definitions"]), summary = s(f["summary"]),
                              work = Dict{String,Int}(String(k) => Int(v) for (k, v) in f["work"]), used_by = String.(get(f, "used_by", String[])))
                           for f in code["files"]],
                      code === nothing ? "" : s(code["summary"]),
                      code === nothing ? NamedTuple{(:path, :lines, :summary, :uses, :tasks),Tuple{String,Int,String,Vector{String},Vector{String}}}[] :
                          [(; path = String(n["path"]), lines = Int(n["lines"]), summary = s(n["summary"]), uses = String.(n["uses"]),
                              tasks = String.(n["tasks"])) for n in get(code, "notebooks", Any[])])
end
read_project_map(kb::KB, key::AbstractString) = read_project_map(project_map(kb, key))

"""
A line of a project's work: tasks (`roots`, by ref) with everything under them that no other thread
claims (`tasks`, in board number order), drawn as one row of the roadmap and one group of the thread map.
"""
struct Thread
    name::String
    roots::Vector{String}
    tasks::Vector{String}
end

"""
    threads(m; groups = nothing) -> Vector{Thread}

Project map `m`'s work as threads. By default each milestone is a thread of its tasks: a task belongs
to its milestone's thread, with what is under it, even when the task above it is in another; the
top-level tasks in no milestone are one more, "No milestone". `groups` (name => task refs) names threads by
hand: a thread holds the tasks it lists, any task among them a subtask too, and what is under them,
each task going to the nearest listed task above it; the top-level tasks left over are gathered
under "Other".
"""
function threads(m::ProjectMap; groups = nothing)
    tops = [r for r in m.order if isempty(m.tasks[r].parent)]
    named = groups === nothing ?
        [[ms.name => [r for r in m.order if m.tasks[r].milestone == ms.name && !in_milestone(m, m.tasks[r].parent, ms.name)]
          for ms in m.milestones];
         ["No milestone" => [r for r in tops if isempty(m.tasks[r].milestone)]]] :
        [String(name) => [uppercase(String(r)) for r in refs if haskey(m.tasks, uppercase(String(r)))] for (name, refs) in groups]
    owner = Dict(r => i for (i, (_, refs)) in enumerate(named) for r in refs)
    function owned(r)
        while true
            haskey(owner, r) && return owner[r]
            p = m.tasks[r].parent
            (isempty(p) || !haskey(m.tasks, p)) && return 0
            r = p
        end
    end
    of = Dict(r => owned(r) for r in m.order)
    out = [Thread(String(name), refs, [r for r in m.order if of[r] == i]) for (i, (name, refs)) in enumerate(named)]
    left = [r for r in m.order if of[r] == 0]
    isempty(left) || push!(out, Thread("Other", [r for r in left if isempty(m.tasks[r].parent) || !(m.tasks[r].parent in left)], left))
    return filter(t -> !isempty(t.tasks), out)
end

in_milestone(m::ProjectMap, ref::AbstractString, name::AbstractString) = haskey(m.tasks, ref) && m.tasks[ref].milestone == name

"Every task in thread `t`, in board number order."
thread_tasks(m::ProjectMap, t::Thread) = [m.tasks[r] for r in t.tasks]

"""
    thread_state(m, t; now) -> NamedTuple

Where thread `t` stands: `state` ("finished", "active" if it moved in the last 3 days, "quiet" in the
last 14, else "dormant"), `done` and `total` tasks, `last` (when it last moved), `next` (its tasks in
progress, then ready), `review` (tasks in Review) and `asked` (agents' questions waiting on people).
"""
function thread_state(m::ProjectMap, t::Thread; now::DateTime = m.generated)
    ts = thread_tasks(m, t)
    refs = Set(x.ref for x in ts)
    moved = [a.at for a in m.activity if a.task in refs && is_work(a)]
    last = isempty(moved) ? minimum(x.created for x in ts) : maximum(moved)
    done = count(x -> x.status == "done", ts)
    idle = now - last
    state = done == length(ts) ? "finished" : idle < Day(3) ? "active" : idle < Day(14) ? "quiet" : "dormant"
    next = [x for s in ("in_progress", "ready") for x in ts if x.status == s]
    return (; state, done, total = length(ts), last, next, review = [x for x in ts if x.status == "review"],
              asked = [q for q in m.questions if q.by_agent && q.task in refs])
end

"""
Whether activity `a` is work on a task: making it, a note or question, a commit, or a move into
progress, review or done. Edits and moves between the planning columns are not.
"""
is_work(a) = a.kind in ("created", "comment", "progress", "question", "commit") ||
             (a.kind == "status" && a.to in ("in_progress", "review", "done"))

"""
    activity_by_day(m, t) -> Dict{Date,Int}

How much work thread `t` saw each day (see [`is_work`](@ref)).
"""
function activity_by_day(m::ProjectMap, t::Thread)
    refs = Set(x.ref for x in thread_tasks(m, t))
    out = Dict{Date,Int}()
    for a in m.activity
        a.task in refs && is_work(a) || continue
        out[Date(a.at)] = get(out, Date(a.at), 0) + 1
    end
    return out
end

"""
    glance_markdown(m, ts) -> String

A table of threads `ts` of project map `m`, a line each: its state, tasks done, when it last moved,
what is next and what waits on a person (Review, and agents' questions).
"""
function glance_markdown(m::ProjectMap, ts::Vector{Thread})
    io = IOBuffer()
    cell(s) = replace(s, "|" => "\\|", "\n" => " ")
    named(xs) = join(("$(x.ref) $(cell(first(x.title, 50)))" for x in first(xs, 2)), "; ") * (length(xs) > 2 ? " (+$(length(xs) - 2))" : "")
    println(io, "| Thread | State | Done | Last moved | Next | Waiting on a person |")
    println(io, "|---|---|---|---|---|---|")
    for t in ts
        s = thread_state(m, t)
        waits = String[]
        isempty(s.review) || push!(waits, "$(length(s.review)) in Review")
        isempty(s.asked) || push!(waits, "$(length(s.asked)) question$(length(s.asked) == 1 ? "" : "s")")
        println(io, "| ", cell(t.name), " | ", s.state, " | ", s.done, "/", s.total, " | ", Dates.format(s.last, "d u"), " | ",
                isempty(s.next) ? "–" : named(s.next), " | ", isempty(waits) ? "–" : join(waits, ", "), " |")
    end
    return String(take!(io))
end

"""
    summary_markdown(m, ts; days = 7) -> String

A few lines on project map `m` over the last `days`: which threads moved most, the findings drafted,
what waits on people, and the milestones due next.
"""
function summary_markdown(m::ProjectMap, ts::Vector{Thread}; days::Integer = 7)
    since = Date(m.generated) - Day(days - 1)
    moved = sort!([(t, sum((n for (d, n) in activity_by_day(m, t) if d >= since); init = 0)) for t in ts]; by = last, rev = true)
    busy = [t.name for (t, n) in moved if n > 0]
    states = [thread_state(m, t) for t in ts]
    open = count(s -> s.state != "finished", states)
    lines = String["**$(m.name)**: $(length(ts)) threads, $open still open, as the board stood on $(Dates.format(m.generated, "d U yyyy, HH:MM")) UTC."]
    push!(lines, isempty(busy) ? "Nothing moved in the last $days days." :
                 "Moving most in the last $days days: " * join(first(busy, 3), ", ") * (length(busy) > 3 ? ", and $(length(busy) - 3) more." : "."))
    found = [f for f in m.findings if Date(f.created) >= since]
    isempty(found) || push!(lines, "$(length(found)) finding$(length(found) == 1 ? "" : "s") drafted: " * join((f.ref for f in found), ", ") * ".")
    review = sum(length(s.review) for s in states; init = 0)
    asked = sum(length(s.asked) for s in states; init = 0)
    review + asked > 0 && push!(lines, "Waiting on a person: $review in Review, $asked question$(asked == 1 ? "" : "s") from agents.")
    due = sort!([ms for ms in m.milestones if !ms.closed && ms.due !== nothing]; by = ms -> ms.due)
    isempty(due) || push!(lines, "Due next: " * join(("$(ms.name) ($(Dates.format(ms.due, "d u")))" for ms in first(due, 3)), ", ") * ".")
    return join(lines, "\n\n")
end

"When task `ref` of project map `m` was last moved into Done, or `nothing` if it is not done."
function done_at(m::ProjectMap, ref::AbstractString)
    t = m.tasks[ref]
    t.status == "done" || return nothing
    at = nothing
    for a in m.activity
        a.task == ref && a.kind == "status" && a.to == "done" && (at = a.at)
    end
    return something(at, t.archived, t.updated)
end

"""
    finished(m) -> Vector{NamedTuple}

What project map `m` has finished: each done task whose parent is not done (a piece of work delivered
whole), latest first, as `(; ref, title, milestone, at, subtasks, commits)`: when it was done, how
many done tasks are under it, and the commits recorded against it and them.
"""
function finished(m::ProjectMap)
    under = Dict{String,Vector{String}}()
    for r in m.order
        p = m.tasks[r].parent
        isempty(p) || push!(get!(under, p, String[]), r)
    end
    below(r) = [c for x in get(under, r, String[]) for c in [x; below(x)]]
    commits = Dict{String,Int}()
    for a in m.activity
        a.kind == "commit" && (commits[a.task] = get(commits, a.task, 0) + 1)
    end
    top = [r for r in m.order if m.tasks[r].status == "done" &&
           (isempty(m.tasks[r].parent) || !haskey(m.tasks, m.tasks[r].parent) || m.tasks[m.tasks[r].parent].status != "done")]
    out = [(; ref = r, title = m.tasks[r].title, milestone = m.tasks[r].milestone, at = done_at(m, r),
              subtasks = count(c -> m.tasks[c].status == "done", below(r)),
              commits = sum((get(commits, c, 0) for c in [r; below(r)]); init = 0)) for r in top]
    return sort!(out; by = x -> x.at, rev = true)
end

"""
    finished_markdown(m) -> String

What project map `m` has finished (see [`finished`](@ref)), milestone by milestone, latest first, then
the findings drafted, each with its claim.
"""
function finished_markdown(m::ProjectMap)
    io = IOBuffer()
    done = finished(m)
    names = unique(x.milestone for x in done)
    for name in names
        println(io, "**", isempty(name) ? "No milestone" : name, "**\n")
        for x in done
            x.milestone == name || continue
            extra = join(filter(!isempty, [x.subtasks > 0 ? "$(x.subtasks) subtask$(x.subtasks == 1 ? "" : "s")" : "",
                                            x.commits > 0 ? "$(x.commits) commit$(x.commits == 1 ? "" : "s")" : ""]), ", ")
            println(io, "- **", x.ref, "** ", x.title, " · done ", Dates.format(x.at, "d u"), isempty(extra) ? "" : " · $extra")
        end
        println(io)
    end
    isempty(m.findings) || println(io, "**Findings**\n")
    for f in sort(m.findings; by = f -> f.created)
        println(io, "- **", f.ref, "** (", f.status, ", ", Dates.format(f.created, "d u"), ") ", f.claim)
    end
    return String(take!(io))
end
