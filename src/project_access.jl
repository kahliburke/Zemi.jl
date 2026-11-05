# Who may reach a project: its members, each with a role there (viewer, contributor, maintainer:
# looking, changing its work, and managing the project itself: its context, codebase and
# milestones), and those whose roles reach every project (`projects.all`). Who belongs to a project
# is up to its owner, who made it, and to those who look after people (`users.manage`). The global permissions say what kind
# of work someone may do at all (`tasks.view`, `tasks.edit`); membership says where. Run for one
# person (`:local`), every project is theirs. A project someone may not reach is, to them, no
# project: it is answered as one that does not exist.

"What each role in a project allows, as a level: seeing, then contributing, then managing it."
const PROJECT_ROLES = ("viewer", "contributor", "maintainer")
const NO_ACCESS, VIEW, CONTRIBUTE, MAINTAIN = 0, 1, 2, 3
"Each level's name, as the board shows it (`\"\"` for none)."
access_name(level::Integer) = ("", PROJECT_ROLES...)[level + 1]

"""
    project_membership(kb, caller, key) -> Int

`caller`'s level in project `key` by membership alone: their role there, `MAINTAIN` with
`projects.all` or run for one person, `NO_ACCESS` for a project a token was not made for. What
documents linked to the project they see (see [`document_visible`](@ref)); its board takes the
permissions too (see [`project_access`](@ref)).
"""
function project_membership(kb::KB, caller::Caller, key::AbstractString)
    caller.via == :local && return MAINTAIN
    k = uppercase(strip(key))
    caller.projects === nothing || k in caller.projects || return NO_ACCESS     # a token made for other projects
    pid = scalar(kb, "SELECT id FROM projects WHERE key = ?", (k,))
    ismissing(pid) && return NO_ACCESS
    can(caller, "projects.all") && return MAINTAIN
    caller.user_id === nothing && return NO_ACCESS
    role = coalesce(scalar(kb, "SELECT role FROM project_members WHERE project_id = ? AND user_id = ?", (pid, caller.user_id)), "")
    return something(findfirst(==(role), PROJECT_ROLES), NO_ACCESS)
end

"""
    project_access(kb, caller, key) -> Int

How far `caller` may reach project `key` and its work: `NO_ACCESS`, `VIEW`, `CONTRIBUTE` or
`MAINTAIN`. Their [`project_membership`](@ref), within what their permissions allow: seeing needs
`tasks.view`, more needs `tasks.edit`.
"""
function project_access(kb::KB, caller::Caller, key::AbstractString)
    caller.via == :local && return MAINTAIN
    can(caller, "tasks.view") || return NO_ACCESS
    level = project_membership(kb, caller, key)
    return can(caller, "tasks.edit") ? level : min(level, VIEW)
end

"""
    need_project!(kb, caller, key, level)

Refuse unless `caller` reaches project `key` at `level` (see [`project_access`](@ref)): one they
cannot reach at all is "No project", as if it did not exist.
"""
function need_project!(kb::KB, caller::Caller, key::AbstractString, level::Integer)
    have = project_access(kb, caller, key)
    k = uppercase(strip(key))
    have == NO_ACCESS && not_found("No project $k")
    have < level && not_permitted("Not permitted: in $k you may " * (have == VIEW ? "look but not change" : "change work but not manage the project"))
    return k
end

"The keys of the projects `caller` may see."
visible_projects(kb::KB, caller::Caller) =
    Set(String(r.key) for r in query(kb, "SELECT key FROM projects") if project_access(kb, caller, r.key) >= VIEW)

"""
    manages_members(kb, caller, key) -> Bool

Whether `caller` decides who belongs to project `key`, and may delete it: its owner, those who look
after people (`users.manage`), and whoever runs the knowledge base for one person.
"""
function manages_members(kb::KB, caller::Caller, key::AbstractString)
    caller.via == :local && return true
    project_access(kb, caller, key) == NO_ACCESS && return false
    can(caller, "users.manage") && return true
    owner = scalar(kb, "SELECT owner_id FROM projects WHERE key = ?", (uppercase(strip(key)),))
    return caller.user_id !== nothing && !ismissing(owner) && owner == caller.user_id
end

"Whether `caller` may see the task (or anything else) under reference `ref`."
sees_ref(kb::KB, caller::Caller, ref::AbstractString, visible = visible_projects(kb, caller)) =
    (k = ref_project(ref); k !== nothing && k in visible)

"""
    members(kb, key) -> Vector{NamedTuple}

Project `key`'s members: `(; user_id, email, name, role, added_at, added_by)`, maintainers first.
"""
members(kb::KB, key::AbstractString) =
    [(; user_id = Int(r.user_id), email = String(r.email), name = String(r.name), role = String(r.role),
        added_at = String(r.added_at), added_by = String(r.added_by))
     for r in query(kb, """SELECT m.user_id, u.email, u.name, m.role, m.added_at, m.added_by FROM project_members m
                           JOIN users u ON u.id = m.user_id WHERE m.project_id = ?
                           ORDER BY CASE m.role WHEN 'maintainer' THEN 0 WHEN 'contributor' THEN 1 ELSE 2 END, u.name, u.email""",
                    (project_id(kb, key),))]

"""
    set_member!(kb, key, who, role; by)

Make person `who` (an email, or an account's id) a member of project `key` with `role` (one of
`PROJECT_ROLES`), or change their role there; `role` "" takes them off. The last maintainer stays.
"""
function set_member!(kb::KB, key::AbstractString, who, role::AbstractString; by::AbstractString = "")
    pid = project_id(kb, key)
    uid = who isa Integer ? who : scalar(kb, "SELECT id FROM users WHERE email = ? COLLATE NOCASE", (strip(who),))
    ismissing(uid) && not_found("No one with the email $who has an account here")
    role = lowercase(strip(role))
    isempty(role) || role in PROJECT_ROLES || error("A member is a $(join(PROJECT_ROLES, ", ", " or ")): $role")
    owner = scalar(kb, "SELECT owner_id FROM projects WHERE id = ?", (pid,))
    !ismissing(owner) && owner == uid && role != "maintainer" && error("$(uppercase(strip(key)))'s owner stays a maintainer")
    transaction(kb) do
        if isempty(role)
            execute!(kb, "DELETE FROM project_members WHERE project_id = ? AND user_id = ?", (pid, uid))
        else
            execute!(kb, """INSERT INTO project_members (project_id, user_id, role, added_at, added_by) VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT (project_id, user_id) DO UPDATE SET role = excluded.role""", (pid, uid, role, now_iso(), by))
        end
        had = scalar(kb, "SELECT count(*) FROM project_members WHERE project_id = ?", (pid,)) > 0
        had && scalar(kb, "SELECT count(*) FROM project_members WHERE project_id = ? AND role = 'maintainer'", (pid,)) == 0 &&
            error("$(uppercase(strip(key))) needs a maintainer: make another one first")
    end
    tasks_changed!()
    return nothing
end

"Whether account `uid` reaches project `key`: a member of it, or one whose roles reach every project."
in_project(kb::KB, uid::Integer, key::AbstractString) =
    "projects.all" in user_permissions(kb, uid) ||
    !ismissing(scalar(kb, "SELECT 1 FROM project_members m JOIN projects p ON p.id = m.project_id WHERE p.key = ? AND m.user_id = ?",
                      (uppercase(strip(key)), uid)))
