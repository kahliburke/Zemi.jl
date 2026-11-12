# Projects: a research topic, or a codebase the knowledge base has read, whose work is planned and
# tracked as tasks (see tasks.jl), each with a key its tasks are referred to by (`KB-12`).

"""
    create_project!(kb, name; key, description = "", codebase = "", owner = nothing, add_codebase = true, by,
                    caller = local_caller()) -> String

A project, with `key`, the short prefix of its tasks' references (`KB` for `KB-12`): letters and
digits, made uppercase. `codebase` is a codebase the knowledge base has read (its id, `code-…`), for
agents working in that codebase's directory to find it, or a repository's address (see
[`codebase_id`](@ref), for `caller`, and `add_codebase`). `owner`, an account's id, owns the project:
its first maintainer, who decides with the admins who belongs to it (see project_access.jl). Returns
the key; the same project asked for again by the same person moments later is the one made (see
[`REPEAT_SECONDS`](@ref)).
"""
function create_project!(kb::KB, name::AbstractString; key::AbstractString, description::AbstractString = "",
                         codebase::AbstractString = "", owner::Union{Integer,Nothing} = nothing, add_codebase::Bool = true,
                         by::Actor, caller::Caller = local_caller())
    key = uppercase(strip(key))
    occursin(r"^[A-Z][A-Z0-9]{0,9}$", key) || error("A project key is a letter and up to nine letters or digits: $key")
    isempty(strip(name)) && error("A project needs a name")
    isempty(query(kb, "SELECT 1 FROM projects WHERE key = ? AND name = ? AND created_by = ? AND created_at >= ?",
                  (key, strip(name), by.name, repeat_since()))) || return key
    cid = codebase_id(kb, codebase; add = add_codebase, caller)
    isempty(query(kb, "SELECT 1 FROM projects WHERE key = ?", (key,))) || error("A project's key is already $key")
    use_media!(kb, key, description; record = false)
    execute!(kb, "INSERT INTO projects (key, name, description, codebase_id, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?)",
             (key, strip(name), description, cid, by.name, now_iso()))
    use_media!(kb, key, description)
    if owner !== nothing
        execute!(kb, "UPDATE projects SET owner_id = ? WHERE key = ?", (owner, key))
        set_member!(kb, key, owner, "maintainer"; by = by.name)
    end
    tasks_changed!()
    return key
end

"""
    codebase_id(kb, codebase; add = true, caller = local_caller())

The id of codebase `codebase` (`code-…`, a repository's address, or a folder on this machine, whose
codebase is recorded if new); `missing` when it is empty or `none`, and an error for anything else. A
repository or folder the knowledge base does not have is added only with `add`: the service reads it
with its own credentials and shows it to its readers, so adding one takes what adding a paper does
(`paper.add`), and a folder, in a shared service, what changing its configuration does (see
[`add_codebase_from!`](@ref)). Linking a project to a
codebase shows it to the project's members, so one `caller` may not see is none to them, unless
they decide who sees codebases (`paper.manage`).
"""
function codebase_id(kb::KB, codebase::AbstractString; add::Bool = true, caller::Caller = local_caller())
    codebase = strip(codebase)
    (isempty(codebase) || lowercase(codebase) == "none") && return missing
    linkable(doc_id) = can(caller, "paper.manage") ? doc_id : seen_document(kb, caller, doc_id)
    if is_repository(codebase)
        known = query(kb, "SELECT id, doc_id FROM papers WHERE $(kind_in(CODEBASE)) AND remote = ?", (clone_url(codebase),))
        isempty(known) || (linkable(first(known).doc_id); return Int(first(known).id))
        add || not_permitted("Not permitted: a repository the knowledge base does not have yet is added by someone with paper.add")
        return paper_id(kb, link_repository!(kb, codebase))
    end
    if is_folder(codebase)
        root = (r = abspath(expanduser(codebase)); r == "/" ? r : String(rstrip(r, '/')))
        known = query(kb, "SELECT id, doc_id FROM papers WHERE $(kind_in(CODEBASE)) AND source_path = ?", (root,))
        isempty(known) || (linkable(first(known).doc_id); return Int(first(known).id))
        add || not_permitted("Not permitted: a folder the knowledge base does not have yet is added by someone with paper.add")
        return paper_id(kb, add_codebase_from!(kb, root; caller))
    end
    id = is_codebase(codebase) ? paper_id(kb, codebase) : missing
    ismissing(id) && not_found("No codebase $codebase in the knowledge base (a codebase's id begins code-; give a repository's address or a folder's path for a new one)")
    linkable(codebase)
    return id
end

"""
    update_project!(kb, key; name = nothing, description = nothing, codebase = nothing, add_codebase = true, by,
                    caller = local_caller())

Rename project `key`, give it a new `description` (what it is about and how to work in it, which
agents read before they take its work, see `next_task`), or link it to a `codebase` (its id,
`code-…`, or its repository's address, added with `add_codebase` as [`codebase_id`](@ref) says, for
`caller`; `"none"` unlinks it), for agents working in that codebase's directory to find it. Only a
person changes the name and description; an agent may link a codebase.
"""
function update_project!(kb::KB, key::AbstractString; name = nothing, description = nothing, codebase = nothing,
                         add_codebase::Bool = true, by::Actor, caller::Caller = local_caller())
    by.agent && (name !== nothing || description !== nothing) && error("Only a person changes a project's name or description")
    pid = project_id(kb, key)
    use_media!(kb, key, description)
    codebase === nothing ||
        execute!(kb, "UPDATE projects SET codebase_id = ? WHERE id = ?",
                 (codebase_id(kb, codebase; add = add_codebase, caller), pid))
    name === nothing || (isempty(strip(name)) ? error("A project needs a name") :
                         execute!(kb, "UPDATE projects SET name = ? WHERE id = ?", (strip(name), pid)))
    description === nothing || execute!(kb, "UPDATE projects SET description = ? WHERE id = ?", (strip(description), pid))
    tasks_changed!()
    return uppercase(strip(key))
end

"""
    delete_project!(kb, key) -> Int

Delete project `key` with everything in it: its tasks and their activity, milestones, findings and
members, and the links to its tasks and findings from other projects, which a project given its key
later would otherwise inherit. Returns how many tasks went with it.
"""
function delete_project!(kb::KB, key::AbstractString)
    pid = project_id(kb, key)
    k = uppercase(strip(key))
    n = Int(scalar(kb, "SELECT count(*) FROM tasks WHERE project_id = ?", (pid,)))
    transaction(kb) do
        ref = "(upper(target) GLOB ? OR upper(target) GLOB ?)"
        refs = ("$k-[0-9]*", "$k-F[0-9]*")
        execute!(kb, "DELETE FROM task_links WHERE kind IN ('task', 'blocks', 'finding') AND $ref", refs)
        execute!(kb, "DELETE FROM finding_evidence WHERE kind IN ('task', 'finding') AND $ref", refs)
        execute!(kb, "DELETE FROM projects WHERE id = ?", (pid,))
        prune_task_search!(kb)
    end
    tasks_changed!()
    return n
end

"""
    projects(kb; path = "", archived = false) -> Vector{NamedTuple}

The projects, each `(; key, name, description, codebase, root, tasks, open, active_milestone)`: its codebase's id and
directory, if it has one, and how many tasks it has and how many are not done, subtasks not counted. With `path`, only
those whose codebase holds that directory (an agent's working directory), the innermost first.
"""
function projects(kb::KB; path::AbstractString = "", archived::Bool = false)
    rows = query(kb, """
        SELECT p.key, p.name, p.description, d.doc_id AS codebase, d.source_path AS root, am.name AS active_milestone,
               (SELECT count(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.archived_at IS NULL) AS tasks,
               (SELECT count(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.status != 'done') AS open
        FROM projects p LEFT JOIN papers d ON d.id = p.codebase_id LEFT JOIN milestones am ON am.id = p.active_milestone_id
        WHERE p.archived = ? ORDER BY p.name""", (archived ? 1 : 0,))
    list = [(; key = r.key, name = r.name, description = r.description, codebase = coalesce(r.codebase, ""),
               root = coalesce(r.root, ""), tasks = Int(r.tasks), open = Int(r.open),
               active_milestone = coalesce(r.active_milestone, "")) for r in rows]
    isempty(path) && return list
    dir = rstrip(abspath(expanduser(path)), '/')
    holds(root) = !isempty(root) && (dir == rstrip(root, '/') || startswith(dir, rstrip(root, '/') * "/"))
    return sort!(filter(p -> holds(p.root), list); by = p -> -length(p.root))
end

function project_id(kb::KB, key::AbstractString)
    r = query(kb, "SELECT id FROM projects WHERE key = ?", (uppercase(strip(key)),))
    isempty(r) && not_found("No project $key")
    return Int(first(r).id)
end
