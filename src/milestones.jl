# A project's milestones: the stages its tasks are grouped in, one of them active, each marked done
# when its work is, and what the project has finished.

"Add milestone `name` to project `key`, with a `due` date (`YYYY-MM-DD`) or none."
function create_milestone!(kb::KB, key::AbstractString, name::AbstractString; description::AbstractString = "",
                           due::AbstractString = "", start::AbstractString = "")
    isempty(strip(name)) && error("A milestone needs a name")
    for d in (start, due)
        isempty(d) || occursin(r"^\d{4}-\d{2}-\d{2}$", d) || error("A milestone's date is YYYY-MM-DD: $d")
    end
    pid = project_id(kb, key)
    use_media!(kb, key, description)
    isempty(query(kb, "SELECT 1 FROM milestones WHERE project_id = ? AND name = ?", (pid, strip(name)))) ||
        error("$key already has a milestone $(strip(name))")
    execute!(kb, "INSERT INTO milestones (project_id, name, description, due, starts, created_at) VALUES (?, ?, ?, ?, ?, ?)",
             (pid, strip(name), description, isempty(due) ? missing : due, isempty(start) ? missing : start, now_iso()))
    tasks_changed!()
    return String(strip(name))
end

"""
    update_milestone!(kb, key, name; start = nothing, due = nothing, description = nothing, rename = nothing) -> String

Change milestone `name` of project `key`: the dates its work `start`s and is `due` (YYYY-MM-DD, or
`""` for none), its `description`, or its name (`rename`, not one the project already has). What is
not given stays as it is. Returns the milestone's name, new or as it was.
"""
function update_milestone!(kb::KB, key::AbstractString, name::AbstractString; start = nothing, due = nothing,
                           description = nothing, rename = nothing)
    pid = project_id(kb, key)
    mid = milestone_id(kb, pid, name)
    ismissing(mid) && error("$key has no milestone $(strip(name))")
    for d in (start, due)
        d === nothing || isempty(d) || occursin(r"^\d{4}-\d{2}-\d{2}$", d) || error("A milestone's date is YYYY-MM-DD: $d")
    end
    new = rename === nothing ? String(strip(name)) : String(strip(rename))
    isempty(new) && error("A milestone needs a name")
    new == strip(name) || isempty(query(kb, "SELECT 1 FROM milestones WHERE project_id = ? AND name = ?", (pid, new))) ||
        error("$key already has a milestone $new")
    description === nothing || use_media!(kb, key, description)
    transaction(kb) do
        due === nothing || execute!(kb, "UPDATE milestones SET due = ? WHERE id = ?", (isempty(due) ? missing : due, mid))
        start === nothing || execute!(kb, "UPDATE milestones SET starts = ? WHERE id = ?", (isempty(start) ? missing : start, mid))
        description === nothing || execute!(kb, "UPDATE milestones SET description = ? WHERE id = ?", (description, mid))
        rename === nothing || execute!(kb, "UPDATE milestones SET name = ? WHERE id = ?", (new, mid))
    end
    tasks_changed!()
    return new
end

"""
    milestones(kb, key) -> Vector{NamedTuple}

Project `key`'s milestones, `(; name, description, start, due, closed, created_at, done, total, active)`: how many of
its top-level tasks are done, of how many, and whether it is the project's active one. Open ones
first, by date.
"""
function milestones(kb::KB, key::AbstractString)
    rows = query(kb, """
        SELECT m.name, m.description, m.starts, m.due, m.closed, m.closed_at, m.created_at, (p.active_milestone_id = m.id) AS active,
               (SELECT count(*) FROM tasks t WHERE t.milestone_id = m.id AND t.parent_id IS NULL) AS total,
               (SELECT count(*) FROM tasks t WHERE t.milestone_id = m.id AND t.parent_id IS NULL AND t.status = 'done') AS done
        FROM milestones m JOIN projects p ON p.id = m.project_id WHERE m.project_id = ?
        ORDER BY m.closed, m.due IS NULL, m.due, m.name""", (project_id(kb, key),))
    return [(; name = r.name, description = r.description, start = coalesce(r.starts, ""), due = coalesce(r.due, ""), closed = r.closed == 1,
               closed_at = coalesce(r.closed_at, ""), created_at = r.created_at,
               done = Int(r.done), total = Int(r.total), active = coalesce(r.active, 0) == 1) for r in rows]
end

"""
    set_active_milestone!(kb, key, name)

Make milestone `name` project `key`'s active one, where its new tasks go unless they are given
another (see [`create_task!`](@ref)); `""` leaves it without one.
"""
function set_active_milestone!(kb::KB, key::AbstractString, name::AbstractString)
    pid = project_id(kb, key)
    execute!(kb, "UPDATE projects SET active_milestone_id = ? WHERE id = ?", (milestone_id(kb, pid, name), pid))
    tasks_changed!()
    return String(name)
end

"""
    finish_milestone!(kb, key, name; reopen = false, decisions = [], by)

Mark milestone `name` of project `key` done, or open again with `reopen`. A done milestone is no
longer the project's active one, and its completed tasks are archived (see [`archive_finished!`](@ref)).
`decisions` settle its unfinished tasks first, each `(; ref, action, milestone)`: `action` "done"
marks the task done with everything under it; "backlog" moves it to the backlog, into `milestone`
(`""` for none). Unfinished tasks without a decision stay as they are.
"""
function finish_milestone!(kb::KB, key::AbstractString, name::AbstractString; reopen::Bool = false, decisions = [],
                           by::Actor)
    pid = project_id(kb, key)
    mid = milestone_id(kb, pid, name)
    ismissing(mid) && error("Which milestone?")
    for d in decisions                                  # all checked before any is applied
        d.action in ("done", "backlog") || error("A task is either marked done or moved to the backlog: $(d.action)")
        # Only this project's tasks, and one of another is refused as one that is not there.
        id = try task_ref(kb, d.ref) catch; nothing end
        (id !== nothing && scalar(kb, "SELECT project_id FROM tasks WHERE id = ?", (id,)) == pid) ||
            not_found("No task $(d.ref) in $key")
    end
    for d in decisions
        d.action == "done" ? update_task!(kb, d.ref; status = "done", with_subtasks = true, by) :
                             update_task!(kb, d.ref; status = "backlog", milestone = d.milestone, by)
    end
    execute!(kb, "UPDATE milestones SET closed = ?, closed_at = ? WHERE id = ?", (reopen ? 0 : 1, reopen ? missing : now_iso(), mid))
    reopen || execute!(kb, "UPDATE projects SET active_milestone_id = NULL WHERE id = ? AND active_milestone_id = ?", (pid, mid))
    reopen || archive_finished!(kb, key)
    tasks_changed!()
    return String(strip(name))
end

"""
    project_history(kb, key) -> NamedTuple

What project `key` has finished, newest first: `milestones`, those marked done, each
`(; name, description, due, closed_at, tasks)` with the tasks finished in it; and `archived`, other
archived tasks by the day they were archived, each `(; day, tasks)`. Tasks are top-level, as
[`tasks`](@ref) gives them.
"""
function project_history(kb::KB, key::AbstractString)
    pid = project_id(kb, key)
    rows(where, args) = NamedTuple[task_row(r) for r in query(kb, TASK_SELECT * " WHERE " * where * " ORDER BY t.archived_at DESC, t.updated_at DESC", args)]
    done = map(query(kb, "SELECT * FROM milestones WHERE project_id = ? AND closed = 1", (pid,))) do m
        finished = rows("t.milestone_id = ? AND t.parent_id IS NULL AND t.status = 'done' AND t.declined_at IS NULL", (m.id,))
        # One done before completion times were kept: when its last work was put away.
        at = coalesce(m.closed_at, maximum((t.archived_at for t in finished); init = ""))
        (; name = String(m.name), description = String(m.description), due = coalesce(m.due, ""), closed_at = at, tasks = finished)
    end
    sort!(done; by = m -> m.closed_at, rev = true)
    loose = rows("""t.project_id = ? AND t.parent_id IS NULL AND t.archived_at IS NOT NULL AND t.declined_at IS NULL
                    AND (t.milestone_id IS NULL OR t.milestone_id NOT IN (SELECT id FROM milestones WHERE closed = 1))""", (pid,))
    days = unique(first(t.archived_at, 10) for t in loose)
    return (; milestones = done, archived = [(; day, tasks = [t for t in loose if startswith(t.archived_at, day)]) for day in days])
end

"""
    archive_finished!(kb, key) -> Int

Archive project `key`'s completed tasks in milestones marked done, with their subtasks; each is
recorded as archived by its milestone. A milestone's date never marks it done. Returns how many.
"""
function archive_finished!(kb::KB, key::AbstractString)
    rows = query(kb, """
        SELECT p.key || '-' || t.number AS ref, m.name AS milestone FROM tasks t
        JOIN milestones m ON m.id = t.milestone_id JOIN projects p ON p.id = t.project_id
        WHERE t.project_id = ? AND t.parent_id IS NULL AND t.status = 'done' AND t.archived_at IS NULL
          AND m.closed = 1""", (project_id(kb, key),))
    for r in rows
        archive_task!(kb, r.ref; by = Actor("Milestone $(r.milestone)", false))
    end
    return length(rows)
end

"The id of project `pid`'s active milestone, or `missing`."
active_milestone_id(kb::KB, pid::Integer) = scalar(kb, "SELECT active_milestone_id FROM projects WHERE id = ?", (pid,))

function milestone_id(kb::KB, pid::Integer, name::AbstractString)
    isempty(name) && return missing
    r = query(kb, "SELECT id FROM milestones WHERE project_id = ? AND name = ?", (pid, strip(name)))
    isempty(r) && not_found("No milestone $name in this project")
    return Int(first(r).id)
end
