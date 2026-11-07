# ── Projects and tasks ───────────────────────────────────────────────────────────────────────────
# Work planned and tracked in the knowledge base, by people and by agents: projects (a research
# topic, or a codebase the knowledge base has read), their milestones, and tasks on a board. A task's
# body is its plan, its activity log is how agents report progress and people answer, and its links
# tie it to papers, notebooks, code and conversations. An agent's plan waits in Proposed until a
# person moves it on.

"The board's columns, in order. An agent's plan starts in `proposed` and a person moves it on."
const TASK_STATUSES = ("proposed", "backlog", "ready", "in_progress", "review", "done")
const STATUS_LABELS = Dict("proposed" => "Proposed", "backlog" => "Backlog", "ready" => "Ready",
                           "in_progress" => "In progress", "review" => "Review", "done" => "Done")
# ASAP (0) comes before everything, in the order tasks were marked so.
const PRIORITIES = Dict(0 => "ASAP", 1 => "high", 2 => "normal", 3 => "low")

"What a task can link to: a paper, a notebook, a codebase's file, a tutor conversation, a URL, a task, or a task it blocks."
const LINK_KINDS = ("paper", "notebook", "code", "chat", "url", "task", "blocks", "author", "person", "finding", "record")

"""
    Actor(name, agent)

Who makes a change: a person, by name, or an agent (`agent = true`), named for whom it works.
"""
struct Actor
    name::String
    agent::Bool
end

person(name::AbstractString) = Actor(String(name), false)
agent(name::AbstractString) = Actor(isempty(name) ? "agent" : String(name), true)

"""
How long after a person makes a task or project the same request from them is taken as a repeat
of it (a form sent twice, a client trying again after a timeout), answered with the one made.
"""
const REPEAT_SECONDS = 30
repeat_since() = iso_ago(Second(REPEAT_SECONDS))

# ── Tasks ────────────────────────────────────────────────────────────────────────────────────────

"""
    task_ref(kb, ref) -> Int

The id of the task referred to as `KEY-number` (`KB-12`, any case).
"""
function task_ref(kb::KB, ref::AbstractString)
    parts = task_parts(ref)
    parts === nothing && error("A task is referred to as KEY-number, like KB-12: $ref")
    r = query(kb, "SELECT t.id FROM tasks t JOIN projects p ON p.id = t.project_id WHERE p.key = ? AND t.number = ?", parts)
    isempty(r) && not_found("No task $ref")
    return Int(first(r).id)
end

function check_status(s::AbstractString)
    s in TASK_STATUSES || error("A task's status is one of $(join(TASK_STATUSES, ", ")): $s")
    return String(s)
end

check_priority(p::Integer) = (haskey(PRIORITIES, p) || error("A task's priority is 0 (ASAP), 1 (high), 2 (normal) or 3 (low): $p"); Int(p))

"A priority given by name or number (\"asap\", \"high\", \"normal\", \"low\", or 0–3), or `nothing` for `\"\"`."
function parse_priority(s::AbstractString)
    w = lowercase(strip(s))
    isempty(w) && return nothing
    i = findfirst(==(w), Dict(k => lowercase(v) for (k, v) in PRIORITIES))
    i !== nothing && return i
    n = tryparse(Int, w)
    n === nothing && error("A task's priority is asap, high, normal or low: $s")
    return check_priority(n)
end

"The position after every task in a column, so a task moved or made there goes to its end."
column_end(kb::KB, pid::Integer, status::AbstractString) =
    coalesce(scalar(kb, "SELECT max(position) FROM tasks WHERE project_id = ? AND status = ?", (pid, status)), 0.0) + 1.0

"Record an event in task `task`'s activity; returns its id."
function record!(kb::KB, task::Integer, by::Actor, kind::AbstractString; text::AbstractString = "", detail = Dict{String,Any}())
    id = insert_row!(kb, "INSERT INTO task_events (task_id, at, who, by_agent, kind, text, detail) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     (task, now_iso(), by.name, by.agent ? 1 : 0, kind, text, JSON.json(detail)))
    # Kept searchable (see task_search.jl): what is said on the task, and its title and plan as they change.
    if kind in SEARCHED_NOTES && !isempty(text)
        index_note!(kb, task, id, text)
    elseif kind == "created" || kind == "edit" && get(detail, "field", "") in ("title", "body")
        index_task_text!(kb, task)
    end
    tasks_changed!()
    return id
end

# ── Changes, for pages that follow them ──────────────────────────────────────────────────────────
# A count of changes to projects and tasks made by this process, and a condition that wakes those
# waiting for the next one (see `wait_tasks_changed`).

const TASKS_CHANGED = Threads.Condition()
const TASKS_VERSION = Ref(0)

"Note a change to projects or tasks, waking those waiting for one."
tasks_changed!() = lock(() -> (TASKS_VERSION[] += 1; notify(TASKS_CHANGED)), TASKS_CHANGED)

"The latest event of any task's activity, by id: what an agent waiting for people starts from."
last_event_id(kb::KB) = Int(coalesce(scalar(kb, "SELECT max(id) FROM task_events"), 0))

"""
    people_events(kb, key, since) -> Vector{NamedTuple}

What people (not agents) did on project `key`'s tasks after event `since`, oldest first:
`(; id, ref, title, who, kind, text, detail)`, as in a task's activity.
"""
function people_events(kb::KB, key::AbstractString, since::Integer)
    rows = query(kb, """SELECT e.id, e.who, e.kind, e.text, e.detail, p.key || '-' || t.number AS ref, t.title
                        FROM task_events e JOIN tasks t ON t.id = e.task_id JOIN projects p ON p.id = t.project_id
                        WHERE p.key = ? AND e.id > ? AND e.by_agent = 0 ORDER BY e.id""", (uppercase(strip(key)), since))
    return [(; id = Int(r.id), ref = String(r.ref), title = String(r.title), who = String(r.who), kind = String(r.kind),
               text = coalesce(r.text, ""), detail = JSON.parse(coalesce(r.detail, "{}"))) for r in rows]
end

"""
    wait_tasks_changed(since; timeout = 25) -> Int

The count of changes (see `TASKS_VERSION`) once it differs from `since`, or after `timeout` seconds
without a change.
"""
function wait_tasks_changed(since::Integer; timeout::Real = 25)
    lock(TASKS_CHANGED) do
        TASKS_VERSION[] == since || return TASKS_VERSION[]
        t = Timer(_ -> lock(() -> notify(TASKS_CHANGED), TASKS_CHANGED), timeout)
        try
            while TASKS_VERSION[] == since && isopen(t)
                wait(TASKS_CHANGED)
            end
        finally
            close(t)
        end
        return TASKS_VERSION[]
    end
end

"""
    create_task!(kb, key, title; body, parent, milestone, priority, assignee, status, subtasks, by) -> String

A task in project `key`, at the end of its column, and its `subtasks` (each a title, or a `Dict`
with `"title"` and optionally `"body"`) under it. Without a `milestone`, a task goes into the
project's active milestone, and a subtask into its parent's. An agent's tasks are proposed, whatever `status`
asks, until a person moves them on; a person's start in `status` (`backlog` by default). A subtask
is in its parent's project. Returns the new task's reference; the same task (title, body and
parent) asked for again by the same person moments later is the one made (see [`REPEAT_SECONDS`](@ref)).
"""
function create_task!(kb::KB, key::AbstractString, title::AbstractString; body::AbstractString = "",
                      parent::AbstractString = "", milestone::AbstractString = "", priority::Integer = 2,
                      assignee::AbstractString = "", status::AbstractString = "backlog", subtasks = [], by::Actor)
    isempty(strip(title)) && error("A task needs a title")
    pid = project_id(kb, key)
    use_media!(kb, key, title, body)
    assignee = assignee_id(kb, assignee; project = key)
    parent_id = isempty(parent) ? missing : task_ref(kb, parent)
    !ismissing(parent_id) && scalar(kb, "SELECT project_id FROM tasks WHERE id = ?", (parent_id,)) != pid &&
        error("$parent is in another project")
    status = by.agent ? "proposed" : check_status(status)
    priority = check_priority(priority)
    # Unless given one, a subtask is in its parent's milestone, and a task in the project's active one.
    mid = !isempty(milestone) ? milestone_id(kb, pid, milestone) :
          !ismissing(parent_id) ? scalar(kb, "SELECT milestone_id FROM tasks WHERE id = ?", (parent_id,)) :
          active_milestone_id(kb, pid)
    ref, made = transaction(kb) do
        # The same task from the same person moments ago is that one (see REPEAT_SECONDS).
        repeat = scalar(kb, """SELECT number FROM tasks WHERE project_id = ? AND parent_id IS ? AND title = ? AND body = ?
                               AND created_by = ? AND created_at >= ? ORDER BY id DESC LIMIT 1""",
                        (pid, parent_id, strip(title), body, by.name, repeat_since()))
        ismissing(repeat) || return ("$(uppercase(strip(key)))-$repeat", false)
        n = Int(scalar(kb, "SELECT next_number FROM projects WHERE id = ?", (pid,)))
        execute!(kb, "UPDATE projects SET next_number = next_number + 1 WHERE id = ?", (pid,))
        now = now_iso()
        id = insert_row!(kb, """INSERT INTO tasks (project_id, number, parent_id, milestone_id, title, body, status, priority,
                                assignee, position, created_by, by_agent, created_at, updated_at, asap_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                         (pid, n, parent_id, mid, strip(title), body, status, priority, assignee,
                          column_end(kb, pid, status), by.name, by.agent ? 1 : 0, now, now, priority == 0 ? now : missing))
        record!(kb, id, by, "created"; detail = Dict("status" => status))
        ("$(uppercase(strip(key)))-$n", true)
    end
    made || return ref
    link_at_references!(kb, ref, title * "\n" * body; by)
    # More to do under a task in Review or Done sends it back to work (a proposal does not, until approved).
    if !ismissing(parent_id) && !(status in ("done", "proposed")) &&
       scalar(kb, "SELECT status FROM tasks WHERE id = ?", (parent_id,)) in ("review", "done")
        update_task!(kb, parent; status = "in_progress", by)
    end
    for s in subtasks
        t, b = s isa AbstractDict ? (string(get(s, "title", "")), string(get(s, "body", ""))) : (string(s), "")
        create_task!(kb, key, t; body = b, parent = ref, milestone, status, by)
    end
    return ref
end

"""
    update_task!(kb, ref; title, body, status, milestone, priority, assignee, blocked, before, with_subtasks, by)

Change task `ref`, recording each change in its activity. A task is done only when every task under
it is: marking it done otherwise is refused, unless `with_subtasks`, which marks them done with it.
Only a person moves a task out of Proposed; when a person does, the proposed tasks under it, at any
depth, go with it to Ready or the backlog (to the backlog when it goes further), and each of them
without an assignee is given to whoever planned it (see [`approval_assignee`](@ref)). `blocked` is why
the task is blocked, or `""` to unblock it. `before`, another task's reference, puts it just above that
task in its column. `parent` puts it under another task of its project (not one of its own), or at
the top level with `""`. Fields left `nothing` are unchanged.
"""
function update_task!(kb::KB, ref::AbstractString; title = nothing, body = nothing, status = nothing,
                      milestone = nothing, priority = nothing, assignee = nothing, blocked = nothing,
                      before = nothing, parent = nothing, with_subtasks::Bool = false, by::Actor)
    id = task_ref(kb, ref)
    use_media!(kb, something(ref_project(ref)), title, body)
    t = first(query(kb, "SELECT * FROM tasks WHERE id = ?", (id,)))
    unfinished = Int[]
    if status !== nothing && status != t.status
        check_status(status)
        t.status == "proposed" && by.agent && error("$ref waits for a person's approval: it stays proposed until one moves it on")
        status == "proposed" && by.agent && t.status != "proposed" && error("Only a person puts a task back to proposed")
        # Done only when everything under it is: those not done are done with it when asked.
        if status == "done"
            open_below = query(kb, """WITH RECURSIVE below(id) AS (SELECT id FROM tasks WHERE parent_id = ?
                                       UNION SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
                                     SELECT t.id, p.key || '-' || t.number AS ref FROM tasks t JOIN below b ON b.id = t.id
                                     JOIN projects p ON p.id = t.project_id WHERE t.status != 'done' ORDER BY t.number""", (id,))
            isempty(open_below) || with_subtasks ||
                error("$ref has subtasks not done ($(join((r.ref for r in open_below), ", "))): finish them first, or mark it done with them")
            unfinished = [Int(r.id) for r in open_below]
        end
    end
    transaction(kb) do
        set(col, val) = execute!(kb, "UPDATE tasks SET $col = ?, updated_at = ? WHERE id = ?", (val, now_iso(), id))
        if title !== nothing && strip(title) != t.title
            isempty(strip(title)) && error("A task needs a title")
            set("title", strip(title)); record!(kb, id, by, "edit"; detail = Dict("field" => "title", "from" => t.title))
        end
        if body !== nothing && body != t.body
            set("body", body); record!(kb, id, by, "edit"; detail = Dict("field" => "body"))
        end
        if milestone !== nothing
            mid = milestone_id(kb, t.project_id, milestone)
            isequal(mid, t.milestone_id) || (set("milestone_id", mid); record!(kb, id, by, "edit"; detail = Dict("field" => "milestone", "to" => milestone)))
        end
        if priority !== nothing && priority != t.priority
            set("priority", check_priority(priority)); record!(kb, id, by, "edit"; detail = Dict("field" => "priority", "to" => priority))
            set("asap_at", priority == 0 ? now_iso() : missing)
        end
        assignee === nothing || (assignee = assignee_id(kb, assignee; project = something(ref_project(ref), "")))
        if assignee !== nothing && assignee != t.assignee
            set("assignee", assignee); record!(kb, id, by, "edit"; detail = Dict("field" => "assignee", "to" => assignee))
        end
        if parent !== nothing
            pid = isempty(parent) ? missing : task_ref(kb, parent)
            if !isequal(pid, t.parent_id)
                if !ismissing(pid)
                    scalar(kb, "SELECT project_id FROM tasks WHERE id = ?", (pid,)) == t.project_id || error("$parent is in another project")
                    # Nor under itself, at any depth.
                    below = Set(r.id for r in query(kb, """WITH RECURSIVE below(id) AS (SELECT ? UNION
                        SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id) SELECT id FROM below""", (id,)))
                    pid in below && error("$ref can't go under $parent, which is part of it")
                    # Under a done task only what is done, at every level, as a done task's subtasks are.
                    if scalar(kb, "SELECT status FROM tasks WHERE id = ?", (pid,)) == "done"
                        open_here = [r.ref for r in query(kb, """SELECT t.id, p.key || '-' || t.number AS ref FROM tasks t
                                     JOIN projects p ON p.id = t.project_id WHERE t.id IN ($(join(below, ','))) AND t.status != 'done'
                                     ORDER BY t.number""") if !(r.id == id && status == "done")]
                        isempty(open_here) || error("$parent is done, and $(join(open_here, ", ")) $(length(open_here) == 1 ? "is" : "are") not: " *
                                                    "only what is done goes under a done task")
                    end
                end
                set("parent_id", pid)
                record!(kb, id, by, "edit"; detail = Dict("field" => "parent", "to" => isempty(parent) ? "" : uppercase(strip(parent))))
            end
        end
        if blocked !== nothing && blocked != t.blocked
            set("blocked", blocked)
            record!(kb, id, by, isempty(blocked) ? "unblocked" : "blocked"; text = blocked)
        end
        to = something(status, t.status)
        if status !== nothing && status != t.status
            set("status", status)
            set("position", column_end(kb, t.project_id, status))
            record!(kb, id, by, "status"; detail = Dict("from" => t.status, "to" => status))
            if t.status == "done"
                for a in query(kb, """WITH RECURSIVE above(id) AS (SELECT parent_id FROM tasks WHERE id = ?
                                       UNION SELECT t.parent_id FROM tasks t JOIN above a ON t.id = a.id WHERE t.parent_id IS NOT NULL)
                                     SELECT t.id FROM tasks t JOIN above a ON a.id = t.id WHERE t.status = 'done'""", (id,))
                    execute!(kb, "UPDATE tasks SET status = 'in_progress', position = ?, updated_at = ? WHERE id = ?",
                             (column_end(kb, t.project_id, "in_progress"), now_iso(), a.id))
                    record!(kb, a.id, by, "status"; detail = Dict("from" => "done", "to" => "in_progress"))
                end
            end
            for s in unfinished
                from = scalar(kb, "SELECT status FROM tasks WHERE id = ?", (s,))
                execute!(kb, "UPDATE tasks SET status = 'done', position = ?, updated_at = ? WHERE id = ?",
                         (column_end(kb, t.project_id, "done"), now_iso(), s))
                record!(kb, s, by, "status"; detail = Dict("from" => from, "to" => "done"))
            end
            # Approving a plan approves its subtasks, and theirs, at every depth, into the column the
            # plan went to (the backlog, when it went further along).
            if t.status == "proposed"
                into = status in ("backlog", "ready") ? status : "backlog"
                approved = [id]
                for s in query(kb, """WITH RECURSIVE below(id) AS (SELECT id FROM tasks WHERE parent_id = ?
                                       UNION SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
                                     SELECT t.id FROM tasks t JOIN below b ON b.id = t.id WHERE t.status = 'proposed'""", (id,))
                    execute!(kb, "UPDATE tasks SET status = ?, position = ?, updated_at = ? WHERE id = ?",
                             (into, column_end(kb, t.project_id, into), now_iso(), s.id))
                    record!(kb, s.id, by, "status"; detail = Dict("from" => "proposed", "to" => into))
                    push!(approved, Int(s.id))
                end
                # Each approved without an assignee goes to whoever planned it.
                key = String(scalar(kb, "SELECT key FROM projects WHERE id = ?", (t.project_id,)))
                for a in query(kb, "SELECT id, created_by, by_agent FROM tasks WHERE id IN ($(join(approved, ','))) AND assignee = ''")
                    who = approval_assignee(kb, String(a.created_by), a.by_agent == 1, key)
                    isempty(who) && continue
                    execute!(kb, "UPDATE tasks SET assignee = ? WHERE id = ?", (who, a.id))
                    record!(kb, a.id, by, "edit"; detail = Dict("field" => "assignee", "to" => who))
                end
            end
        end
        if before !== nothing
            other = first(query(kb, "SELECT id, project_id, status, position FROM tasks WHERE id = ?", (task_ref(kb, before),)))
            (other.project_id == t.project_id && other.status == to) || error("$before is not in $ref's column")
            above = coalesce(scalar(kb, "SELECT max(position) FROM tasks WHERE project_id = ? AND status = ? AND position < ?",
                                    (t.project_id, to, other.position)), other.position - 1.0)
            set("position", (above + other.position) / 2)
        end
    end
    (title === nothing && body === nothing) || link_at_references!(kb, ref, something(title, t.title) * "\n" * something(body, t.body); by)
    # Completed in, or moved into, a milestone marked done: archived with the milestone's others.
    (status == "done" || milestone !== nothing) &&
        archive_finished!(kb, scalar(kb, "SELECT key FROM projects WHERE id = ?", (t.project_id,)))
    tasks_changed!()                                   # a move within a column records no activity
    return ref
end

"""
Add a note to task `ref`'s activity: a `comment`, an agent's `progress` report, or a `question`. An
agent's question waits on people (see [`waiting`](@ref)) and a person's on the agents (see
[`asked_of_agents`](@ref)), until someone from the other side writes after it. Returns the note's
number, which [`edit_note!`](@ref) takes.
"""
function note_task!(kb::KB, ref::AbstractString, text::AbstractString; kind::AbstractString = "comment", by::Actor)
    kind in SEARCHED_NOTES || error("A note is a comment, progress or a question: $kind")
    isempty(strip(text)) && error("A note needs text")
    id = task_ref(kb, ref)
    use_media!(kb, something(ref_project(ref)), text)
    note = record!(kb, id, by, kind; text = strip(text))
    execute!(kb, "UPDATE tasks SET updated_at = ? WHERE id = ?", (now_iso(), id))
    link_at_references!(kb, ref, text; by)
    return note
end

"""
    edit_note!(kb, ref, note, text; by)

Give note `note` (its number in task `ref`'s activity: a comment, progress report or question) the
new `text`, keeping the text it replaces (see [`note_history`](@ref)). People edit their own notes
and those agents wrote; an agent edits only its own. The note keeps its place, kind and state (a
question stays open or answered); its references are linked, and search follows the new text.
"""
function edit_note!(kb::KB, ref::AbstractString, note::Integer, text::AbstractString; by::Actor)
    id = task_ref(kb, ref)
    use_media!(kb, something(ref_project(ref)), text)
    rows = query(kb, "SELECT who, by_agent, kind, text FROM task_events WHERE id = ? AND task_id = ?", (note, id))
    isempty(rows) && not_found("No note $note on $(uppercase(strip(ref)))")
    e = first(rows)
    e.kind in SEARCHED_NOTES || error("Only comments, progress notes and questions are edited")
    mine = e.who == by.name && (e.by_agent == 1) == by.agent
    mine || (!by.agent && e.by_agent == 1) ||
        error(by.agent ? "An agent edits only its own notes" : "A person edits their own notes and agents' notes")
    text = strip(text)
    isempty(text) && error("A note needs text")
    text == e.text && return note
    now = now_iso()
    transaction(kb) do
        execute!(kb, "INSERT INTO task_note_edits (event_id, at, who, by_agent, text) VALUES (?, ?, ?, ?, ?)",
                 (note, now, by.name, by.agent ? 1 : 0, e.text))
        execute!(kb, "UPDATE task_events SET text = ?, edited_at = ? WHERE id = ?", (text, now, note))
        execute!(kb, "DELETE FROM task_search WHERE event_id = ?", (note,))
        index_note!(kb, id, note, text)
        execute!(kb, "UPDATE tasks SET updated_at = ? WHERE id = ?", (now, id))
    end
    link_at_references!(kb, ref, text; by)
    tasks_changed!()
    return note
end

"""
    note_history(kb, note) -> Vector{NamedTuple}

Note `note`'s earlier texts, oldest first: `(; at, who, by_agent, text)`, each the text an edit at
`at` by `who` replaced.
"""
note_history(kb::KB, note::Integer) =
    [(; at = String(r.at), who = String(r.who), by_agent = r.by_agent == 1, text = String(r.text))
     for r in query(kb, "SELECT at, who, by_agent, text FROM task_note_edits WHERE event_id = ? ORDER BY id", (note,))]

"""
    delete_task!(kb, ref; by) -> Int

Delete task `ref` with its subtasks at every depth, their links and activity, and other tasks' links
to them. Their numbers are not used again. A subtask's deletion is recorded in its parent's
activity. Returns how many tasks were deleted.
"""
function delete_task!(kb::KB, ref::AbstractString; by::Actor)
    id = task_ref(kb, ref)
    t = first(query(kb, "SELECT parent_id FROM tasks WHERE id = ?", (id,)))
    gone = [(Int(r.id), String(r.ref)) for r in query(kb, """
        WITH RECURSIVE below(id) AS (SELECT ? UNION SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
        SELECT t.id, p.key || '-' || t.number AS ref FROM tasks t JOIN below b ON b.id = t.id JOIN projects p ON p.id = t.project_id""", (id,))]
    transaction(kb) do
        for (_, r) in gone
            execute!(kb, "DELETE FROM task_links WHERE kind IN ('task', 'blocks') AND target = ?", (r,))
        end
        execute!(kb, "DELETE FROM tasks WHERE id = ?", (id,))           # its subtasks, links and activity go with it
        ismissing(t.parent_id) || record!(kb, Int(t.parent_id), by, "deleted"; text = uppercase(strip(ref)),
                                          detail = Dict("subtasks" => length(gone) - 1))
    end
    tasks_changed!()
    prune_task_search!(kb)
    return length(gone)
end

"""
Link task `ref` to `target`, of `kind` (see [`LINK_KINDS`](@ref)); `remove` takes the link away. The
link is noted in the task's activity unless `quiet` (a reference in a note already shows it).
"""
function link_task!(kb::KB, ref::AbstractString, kind::AbstractString, target::AbstractString;
                    label::AbstractString = "", remove::Bool = false, quiet::Bool = false, by::Actor)
    kind in LINK_KINDS || error("A link is one of $(join(LINK_KINDS, ", ")): $kind")
    isempty(strip(target)) && error("A link needs a target")
    id = task_ref(kb, ref)
    target = String(strip(target))
    kind in ("task", "blocks") && (target = uppercase(target); task_ref(kb, target))
    if remove
        execute!(kb, "DELETE FROM task_links WHERE task_id = ? AND kind = ? AND target = ?", (id, kind, target))
    else
        execute!(kb, "INSERT OR REPLACE INTO task_links (task_id, kind, target, label) VALUES (?, ?, ?, ?)", (id, kind, target, label))
    end
    quiet ? tasks_changed!() : record!(kb, id, by, remove ? "unlink" : "link"; text = target, detail = Dict("kind" => kind))
    return ref
end

function task_row(r)
    (; ref = "$(r.key)-$(r.number)", title = r.title, status = r.status, blocked = r.blocked,
       priority = Int(r.priority), assignee = r.assignee, milestone = coalesce(r.milestone, ""),
       parent = ismissing(r.parent_number) ? "" : "$(r.key)-$(r.parent_number)",
       subtasks = Int(r.subtasks), subtasks_done = Int(r.subtasks_done),
       created_by = r.created_by, by_agent = r.by_agent == 1, created_at = r.created_at, updated_at = r.updated_at,
       archived_at = coalesce(r.archived_at, ""), declined_at = coalesce(r.declined_at, ""), sent_back = coalesce(r.sent_back, 0) == 1,
       asap_at = coalesce(r.asap_at, ""))
end

# A task's progress counts its subtasks at every level below it.
const BELOW = """WITH RECURSIVE below(id, status) AS (SELECT id, status FROM tasks WHERE parent_id = t.id
                 UNION ALL SELECT x.id, x.status FROM tasks x JOIN below b ON x.parent_id = b.id)"""
# Sent back: its last move into or out of Review or Done took it back to work, until it is in review again.
const SENT_BACK = """(t.status NOT IN ('review', 'done') AND coalesce((SELECT json_extract(e.detail, '\$.from') IN ('review', 'done')
    FROM task_events e WHERE e.task_id = t.id AND e.kind = 'status'
      AND (json_extract(e.detail, '\$.from') IN ('review', 'done') OR json_extract(e.detail, '\$.to') IN ('review', 'done'))
    ORDER BY e.id DESC LIMIT 1), 0))"""
const TASK_SELECT = """
    SELECT t.*, p.key, m.name AS milestone, pt.number AS parent_number,
           ($BELOW SELECT count(*) FROM below) AS subtasks,
           ($BELOW SELECT count(*) FROM below WHERE status = 'done') AS subtasks_done,
           $SENT_BACK AS sent_back
    FROM tasks t JOIN projects p ON p.id = t.project_id
    LEFT JOIN milestones m ON m.id = t.milestone_id LEFT JOIN tasks pt ON pt.id = t.parent_id"""

"""
    tasks(kb; project, status, milestone, assignee, parent, q, top = false, limit = 200) -> Vector{NamedTuple}

Tasks, in board order (by column, then position), filtered by any of: project key, status,
milestone, assignee, parent task, and text `q` in the title or body. `top` keeps only tasks without
a parent. Archived and declined tasks are left out; `archived = true` gives only the archived ones,
`declined = true` only the declined (see [`decline_task!`](@ref)), the latest first.
"""
function tasks(kb::KB; project::AbstractString = "", status::AbstractString = "", milestone::AbstractString = "",
               assignee::AbstractString = "", parent::AbstractString = "", q::AbstractString = "", top::Bool = false,
               archived::Bool = false, declined::Bool = false, limit::Integer = 200)
    where, args = String[declined ? "t.declined_at IS NOT NULL" : archived ? "t.archived_at IS NOT NULL AND t.declined_at IS NULL" :
                         "t.archived_at IS NULL"], Any[]
    isempty(project) || (push!(where, "p.key = ?"); push!(args, uppercase(strip(project))))
    isempty(status) || (push!(where, "t.status = ?"); push!(args, check_status(status)))
    isempty(milestone) || (push!(where, "m.name = ?"); push!(args, strip(milestone)))
    isempty(assignee) || (push!(where, "t.assignee = ?"); push!(args, assignee))
    isempty(parent) || (push!(where, "t.parent_id = ?"); push!(args, task_ref(kb, parent)))
    isempty(q) || (push!(where, "(t.title LIKE ? OR t.body LIKE ?)"); push!(args, "%$q%", "%$q%"))
    top && push!(where, "t.parent_id IS NULL")
    order = declined ? "t.declined_at DESC" : archived ? "t.archived_at DESC" :
            "CASE t.status " * join(("WHEN '$s' THEN $i" for (i, s) in enumerate(TASK_STATUSES)), " ") * " END, t.position"
    sql = TASK_SELECT * " WHERE " * join(where, " AND ") * " ORDER BY $order LIMIT ?"
    return NamedTuple[task_row(r) for r in query(kb, sql, (args..., limit))]
end

"""
    task(kb, ref) -> NamedTuple

Task `ref` in full: what [`tasks`](@ref) gives, with its `body`, `project`, `links`, `subtasks` (as
tasks), the tasks that block it (`blocked_by`), and its `activity`, oldest first.
"""
function task(kb::KB, ref::AbstractString)
    id = task_ref(kb, ref)
    r = first(query(kb, TASK_SELECT * " WHERE t.id = ?", (id,)))
    links = [(; kind = l.kind, target = l.target, label = l.label) for l in query(kb, "SELECT * FROM task_links WHERE task_id = ? ORDER BY kind, target", (id,))]
    blocked_by = [String(b.ref) for b in query(kb, """
        SELECT p.key || '-' || t.number AS ref FROM task_links l JOIN tasks t ON t.id = l.task_id JOIN projects p ON p.id = t.project_id
        WHERE l.kind = 'blocks' AND l.target = ?""", (task_row(r).ref,))]
    activity = [(; id = Int(e.id), at = e.at, who = e.who, by_agent = e.by_agent == 1, kind = e.kind, text = e.text, detail = JSON.parse(e.detail),
                   resolved_at = coalesce(e.resolved_at, ""), edited_at = coalesce(e.edited_at, ""))
                for e in query(kb, "SELECT * FROM task_events WHERE task_id = ? ORDER BY id", (id,))]
    commits = [Base.structdiff(c, (; root = "")) for c in task_commits(kb, id)]
    mentions = task_mentions(kb, id)
    found = findings_citing(kb, "task", task_row(r).ref)            # what the task's work concluded
    return merge(task_row(r), (; body = r.body, project = r.key, links, blocked_by, activity, commits, mentions, findings = found,
                               subtasks_list = [task_row(s) for s in query(kb, TASK_SELECT * " WHERE t.parent_id = ? ORDER BY t.number", (id,))]))
end

"How an agent is named as a task's assignee: `agent:` and its name. A person is their email (in the shared service) or name."
const AGENT_ASSIGNEE = "agent:Claude"
is_agent_assignee(a::AbstractString) = startswith(a, "agent:")

"The agents work can be assigned to."
const AGENTS = [AGENT_ASSIGNEE]

"""
    assignee_id(kb, who) -> String

Whom work is assigned to, as a task keeps it: `""` for nobody, or one of [`people`](@ref) (of
`project`, when given; an agent also given as its name, `Claude`), found by id or name in any case
and kept as their id. Anyone else
is refused, so a slip of the keyboard does not become someone to assign work to.
"""
function assignee_id(kb::KB, who::AbstractString; project::AbstractString = "")
    w = String(strip(who))
    isempty(w) && return ""
    l = lowercase(w)
    them = people(kb; project)
    for p in them
        (l == lowercase(p.id) || l == lowercase(p.label) || p.agent && l == lowercase(p.id[7:end])) && return p.id
    end
    error("No one called $w here; work goes to " * join((p.label for p in them), ", "))
end

"""
    people(kb) -> Vector{NamedTuple}

Who a task can be assigned to, `(; id, label, agent)`: the service's people (in the shared service,
those with accounts, by email, and with `project` those who reach it; run for one person, whoever
runs it), and the agents, `agent:Claude`
(see `AGENTS`).
"""
function people(kb::KB; project::AbstractString = "")
    list = [(; id = String(r.email), label = isempty(r.name) ? String(r.email) : String(r.name), agent = false)
            for r in query(kb, "SELECT id, email, name FROM users WHERE disabled = 0 ORDER BY name, email")
            if isempty(project) || in_project(kb, Int(r.id), project)]
    if isempty(list)
        me = something(local_user(), "")
        isempty(me) || push!(list, (; id = me, label = me, agent = false))
    end
    return [list; [(; id = a, label = a[7:end] * " (agent)", agent = true) for a in AGENTS]]
end

"""
    approval_assignee(kb, created_by, by_agent, key) -> String

Whom a task approved without an assignee is given to: the agents, for an agent's plan; else the
person who made it, as [`people`](@ref) of project `key` names them; `""` when there is no one.
"""
function approval_assignee(kb::KB, created_by::AbstractString, by_agent::Bool, key::AbstractString)
    by_agent && return AGENT_ASSIGNEE
    i = findfirst(p -> !p.agent && (p.label == created_by || p.id == created_by), people(kb; project = key))
    return i === nothing ? "" : people(kb; project = key)[i].id
end

"""
    next_task(kb, key) -> Union{String,Nothing}

The task for an agent to work on next in project `key`, among those assigned to an agent or to
nobody (a person's own task is theirs, though its subtasks may be an agent's), not blocked and with
nothing open blocking it: ASAP work waiting (`ready`) first, in the order it was marked so; then work
sent back from review; then the approved tasks waiting, the highest priority first, then the first
in its column. `nothing` when there is none.
"""
function next_task(kb::KB, key::AbstractString)
    takeable(t) = isempty(t.blocked) && (isempty(t.assignee) || is_agent_assignee(t.assignee)) &&
                  all(b -> task(kb, b).status == "done", task(kb, t.ref).blocked_by)
    for t in sort(filter(t -> t.priority == 0, tasks(kb; project = key, status = "ready")); by = t -> t.asap_at)
        takeable(t) && return t.ref
    end
    for t in sort(filter(t -> t.sent_back && t.status in ("ready", "in_progress"), tasks(kb; project = key, limit = 5000));
                  by = t -> t.priority, alg = MergeSort)
        takeable(t) && return t.ref
    end
    for t in sort(tasks(kb; project = key, status = "ready"); by = t -> t.priority, alg = MergeSort)
        isempty(t.blocked) || continue
        isempty(t.assignee) || is_agent_assignee(t.assignee) || continue
        open = [b for b in task(kb, t.ref).blocked_by if task(kb, b).status != "done"]
        isempty(open) && return t.ref
    end
    return nothing
end

"""
    waiting(kb; me = "") -> NamedTuple

What waits on a person, across projects: `proposed`, plans waiting for approval (a whole plan once,
and a subtask proposed under a task already approved); `questions`, tasks where an agent asked a
question no person has written after, each with the `question`; `review`, tasks in Review; and
`mine`, the open tasks assigned to `me` (an email in the shared service, a name run for one person);
`findings`, the findings agents drafted, to accept, and those whose evidence changed, to look at again
(see [`check_findings!`](@ref)); and `answered`, the questions `asker` (as their activity names them) put to agents where an agent
has had the last word (see [`answered_questions`](@ref)). A question on a task that is done no
longer waits.
"""
function waiting(kb::KB; me::AbstractString = "", asker::AbstractString = "")
    find(where, args = ()) = NamedTuple[task_row(r) for r in query(kb, TASK_SELECT * " WHERE t.archived_at IS NULL AND (" * where * ") ORDER BY p.key, t.priority, t.position", args)]
    asked = Dict(Int(r.task_id) => String(r.text) for r in open_questions(kb; agents = true))
    questions = isempty(asked) ? NamedTuple[] :
        [merge(t, (; question = asked[task_ref(kb, t.ref)])) for t in find("t.id IN ($(join(keys(asked), ','))) AND t.status != 'done'")]
    return (; proposed = find("t.status = 'proposed' AND (t.parent_id IS NULL OR pt.status != 'proposed')"),
              questions,
              review = find("t.status = 'review'"),
              mine = isempty(me) ? NamedTuple[] : find("t.assignee = ? AND t.status != 'done'", (me,)),
              findings = filter(f -> (f.by_agent && f.status == "draft") || !isempty(f.recheck), findings(kb)),
              answered = isempty(asker) ? NamedTuple[] : answered_questions(kb, asker))
end

"""
    answered_questions(kb, asker) -> Vector{NamedTuple}

Questions `asker` put to the agents where an agent has had the last word: an agent replied to their
latest question on the task, and neither have they written since nor marked it resolved (see
[`resolve_question!`](@ref)). Writing again (asking again sends it back to the agents) takes it off
until the next reply. Each task once, as [`tasks`](@ref) gives it, with the `question` and the
first reply after it (`answer`), the latest first.
"""
function answered_questions(kb::KB, asker::AbstractString)
    out = NamedTuple[]
    for q in query(kb, """
            WITH latest AS (SELECT task_id, max(id) AS id FROM task_events
                            WHERE kind = 'question' AND by_agent = 0 AND who = ? GROUP BY task_id)
            SELECT e.task_id, e.text, a.id AS answer_id, a.text AS answer
            FROM latest l JOIN task_events e ON e.id = l.id JOIN tasks t ON t.id = e.task_id
            JOIN task_events a ON a.id = (SELECT min(r.id) FROM task_events r WHERE r.task_id = e.task_id AND r.id > e.id
                                          AND r.kind = 'comment' AND r.by_agent = 1)
            WHERE e.resolved_at IS NULL AND t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM task_events w WHERE w.task_id = e.task_id AND w.id > a.id AND w.by_agent = 0
                              AND w.who = ? AND w.kind IN ('comment', 'question'))
            ORDER BY a.id DESC""", (asker, asker))
        r = query(kb, TASK_SELECT * " WHERE t.id = ?", (q.task_id,))
        isempty(r) || push!(out, merge(task_row(first(r)), (; question = String(q.text), answer = String(q.answer))))
    end
    return out
end

"""
    resolve_question!(kb, ref; asker)
    resolve_question!(kb, ref; agents = true)

Mark questions on task `ref` resolved, so they leave what waits: `asker`'s own, answered to their
satisfaction; or, with `agents`, the agents' questions still open there, answered some other way
(in conversation, say) or no longer needing an answer.
"""
function resolve_question!(kb::KB, ref::AbstractString; asker::AbstractString = "", agents::Bool = false)
    agents == isempty(asker) || error("Resolve either a person's questions (asker) or the agents' (agents = true)")
    id = task_ref(kb, ref)
    if agents
        execute!(kb, "UPDATE task_events SET resolved_at = ? WHERE task_id = ? AND kind = 'question' AND by_agent = 1 AND resolved_at IS NULL",
                 (now_iso(), id))
    else
        execute!(kb, "UPDATE task_events SET resolved_at = ? WHERE task_id = ? AND kind = 'question' AND by_agent = 0 AND who = ? AND resolved_at IS NULL",
                 (now_iso(), id, asker))
    end
    tasks_changed!()
    return ref
end

"Questions asked by agents (`agents`) or by people, not resolved, that nobody from the other side has written after (a comment or a question of their own)."
open_questions(kb::KB; agents::Bool) = collect(query(kb, """
    SELECT e.task_id, e.text, e.who FROM task_events e
    WHERE e.kind = 'question' AND e.by_agent = ? AND e.resolved_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM task_events r WHERE r.task_id = e.task_id AND r.id > e.id AND r.kind IN ('comment', 'question')
                      AND r.by_agent != e.by_agent)
    ORDER BY e.id""", (agents ? 1 : 0,)))

"""
    asked_of_agents(kb, key) -> Vector

The questions people asked on project `key`'s tasks, archived ones aside, that no agent has answered
yet: each task (as [`tasks`](@ref) gives it) with the `question` and who asked it (`asker`).
"""
function asked_of_agents(kb::KB, key::AbstractString)
    pid = project_id(kb, key)
    out = NamedTuple[]
    for q in open_questions(kb; agents = false)
        r = query(kb, TASK_SELECT * " WHERE t.id = ? AND t.project_id = ? AND t.archived_at IS NULL", (q.task_id, pid))
        isempty(r) || push!(out, merge(task_row(first(r)), (; question = String(q.text), asker = String(q.who))))
    end
    return out
end

"""
    archive_task!(kb, ref; undo = false, by)

Archive task `ref`, which is done, with its subtasks at every depth: off the board, the agents' task
lists and what waits on people, still readable in the project's archive. `undo` brings it back.
"""
function archive_task!(kb::KB, ref::AbstractString; undo::Bool = false, by::Actor)
    id = task_ref(kb, ref)
    t = first(query(kb, "SELECT status, archived_at FROM tasks WHERE id = ?", (id,)))
    undo || t.status == "done" || error("Only a done task is archived; $ref is $(STATUS_LABELS[t.status])")
    transaction(kb) do
        execute!(kb, """WITH RECURSIVE below(id) AS (SELECT ? UNION SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
                        UPDATE tasks SET archived_at = ? WHERE id IN (SELECT id FROM below)""", (id, undo ? missing : now_iso()))
        record!(kb, id, by, undo ? "unarchived" : "archived")
    end
    return ref
end

"""
    decline_task!(kb, ref; reason = "", undo = false, by)

Decline proposed plan `ref`: it leaves the board with its subtasks, as an archived task does, and is
kept among the project's declined plans with `reason`. `undo` brings it back to Proposed. Only a
person declines a plan.
"""
function decline_task!(kb::KB, ref::AbstractString; reason::AbstractString = "", undo::Bool = false, by::Actor)
    by.agent && error("Only a person declines a plan")
    id = task_ref(kb, ref)
    t = first(query(kb, "SELECT status, declined_at FROM tasks WHERE id = ?", (id,)))
    undo ? (ismissing(t.declined_at) && error("$ref is not declined")) :
           (t.status == "proposed" || error("Only a proposed plan is declined; $ref is $(STATUS_LABELS[t.status])"))
    at = undo ? missing : now_iso()
    transaction(kb) do
        execute!(kb, """WITH RECURSIVE below(id) AS (SELECT ? UNION SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
                        UPDATE tasks SET archived_at = ?, declined_at = ? WHERE id IN (SELECT id FROM below)""", (id, at, at))
        record!(kb, id, by, undo ? "undeclined" : "declined"; text = strip(reason))
    end
    return ref
end

"""
    send_back!(kb, ref; request, subtasks = String[], by)

Send task `ref`, in Review or Done, back to work: to In progress, assigned to the agent that did it,
with `request` (what is needed) as the reviewer's comment and `subtasks` added for that agent, ready.
Agents take work sent back before anything new (see [`next_task`](@ref)). Only a person sends work back.
"""
function send_back!(kb::KB, ref::AbstractString; request::AbstractString, subtasks = String[], by::Actor)
    by.agent && error("Only a person sends work back")
    isempty(strip(request)) && error("Say what is needed")
    t = task(kb, ref)
    t.status in ("review", "done") || error("$ref is $(STATUS_LABELS[t.status]), not in review")
    agent = is_agent_assignee(t.assignee) ? t.assignee : AGENT_ASSIGNEE
    update_task!(kb, ref; status = "in_progress", assignee = agent, by)
    note_task!(kb, ref, request; kind = "comment", by)
    for s in subtasks
        isempty(strip(s)) || create_task!(kb, t.project, strip(s); parent = ref, status = "ready", assignee = agent, by)
    end
    return ref
end

"Why task `ref` was last declined, as the person declining it said, or `\"\"`."
declined_reason(kb::KB, ref::AbstractString) = String(coalesce(scalar(kb,
    "SELECT text FROM task_events WHERE task_id = ? AND kind = 'declined' ORDER BY id DESC LIMIT 1", (task_ref(kb, ref),)), ""))

"Archive project `key`'s done tasks (those at the top level, with their subtasks). Returns how many."
function archive_done!(kb::KB, key::AbstractString; by::Actor)
    refs = [t.ref for t in tasks(kb; project = key, status = "done", top = true, limit = 100_000)]
    foreach(r -> archive_task!(kb, r; by), refs)
    return length(refs)
end

