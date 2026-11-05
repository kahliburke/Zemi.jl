# The API behind the Projects page: projects and their boards, tasks, milestones, notes and links
# (see tasks.jl). Seeing needs `tasks.view`, changing `tasks.edit`, and either only in the projects
# the caller reaches (see project_access.jl); a change is the person's, so they may move an agent's
# plan out of Proposed.

task_json(t) = Dict(pairs(t))

"A project's codebase as the board shows it: its id, title, revision, web page and repository's, or `nothing`."
function codebase_json(kb::KB, id::AbstractString)
    isempty(id) && return nothing
    r = first(query(kb, "SELECT title FROM papers WHERE doc_id = ?", (id,)))
    root = codebase_dir(kb, id)
    return Dict("id" => id, "title" => coalesce(r.title, id), "rev" => isdir(root) ? git_rev(root) : "",
                "remote" => remote_url(root), "page" => "/generated/kb/code/$(page_slug(id))/index.html")
end

"""
A finding as its page shows it (see [`finding`](@ref)), with its `sources` (see
[`finding_sources`](@ref)). Tasks and findings in projects the caller does not see (`sees`) are left
out, and so are the documents in `unseen` (see [`hidden_documents`](@ref)).
"""
function finding_json(kb::KB, ref::AbstractString, sees = _ -> true; unseen = Set{String}())
    f = finding(kb, ref)
    hidden(kind, target) = kind in ("task", "finding") ? !sees(target) : kind in ("paper", "record") && target in unseen
    return merge(Dict(pairs(f)), Dict(:activity => Any[Dict(pairs(a)) for a in finding_activity(kb, ref)],
                                      :evidence => Any[Dict(pairs(e)) for e in f.evidence if !hidden(e.kind, e.target)],
                                      :sources => Any[Dict(pairs(s)) for s in finding_sources(kb, ref) if !hidden(s.kind, s.target)],
                                      :used_by => Any[Dict(pairs(u)) for u in f.used_by if sees(u.ref)]))
end

"The board's columns, as the page shows them."
const STATUS_JSON = [Dict("id" => s, "label" => STATUS_LABELS[s]) for s in TASK_STATUSES]

"Whether the caller may see the task, finding or anything else under reference `ref`."
sees(c::APICall, ref) = (k = ref_project(ref); k !== nothing && project_access(c.kb, c.caller, k) >= VIEW)
sees(c::APICall) = ref -> sees(c, ref)

"The project a list is asked for (`?project=KEY`), which the caller must see, or `\"\"`."
function named_project(c::APICall)
    named = get(c.params, "project", "")
    isempty(named) || need_project!(c.kb, c.caller, named, VIEW)
    return named
end

"""
The people the caller may find: of the project named, else of the projects they see, not every
account, unless they look after accounts.
"""
function known_people(c::APICall, named = named_project(c))
    kb, caller = c.kb, c.caller
    !isempty(named) || caller.via == :local || can(caller, "users.manage") ? people(kb; project = named) :
        unique(p -> p.id, [p for k in sort!(collect(visible_projects(kb, caller))) for p in people(kb; project = k)])
end

"The caller as tasks name whom they are assigned to."
my_name(c::APICall) = c.caller.via == :local ? caller_name(c.caller) : c.caller.email

finding_reply(c::APICall, ref) = finding_json(c.kb, ref, sees(c); unseen = hidden_documents(c.kb, c.caller))
task_reply(c::APICall, ref) = task_json(task(c.kb, ref))
library_reply(c::APICall) = Any[Dict(pairs(x)) for x in library(c.kb, c[:key]; c.caller)]

# ── Projects ──────────────────────────────────────────────────────────────────────────────────────
# Seeing a project needs seeing it, changing its work contributing to it, and changing the project
# itself (its context, codebase and milestones) maintaining it. Its members and deleting it are for
# whoever `manages_members` names, checked by those routes.

# The projects the caller sees, with the board's columns. With `?kind=…&target=…`, each project's
# item for that source in its library, or nothing.
route!("GET", "/api/projects"; need = "tasks.view") do c
    kb, params = c.kb, c.params
    holding = haskey(params, "target") ? library_holding(kb, get(params, "kind", "paper"), params["target"]) : nothing
    item(p) = holding === nothing ? Dict() : Dict(:library => (x = get(holding, p.key, nothing); x === nothing ? nothing : Dict(pairs(x))))
    Dict("projects" => Any[merge(Dict(pairs(p)), Dict(:access => access_name(project_access(kb, c.caller, p.key))), item(p))
                           for p in projects(kb) if project_access(kb, c.caller, p.key) >= VIEW],
         "statuses" => STATUS_JSON)
end

route!("POST", "/api/projects"; need = "tasks.edit") do c
    can(c.caller, "projects.create") || not_permitted("Not permitted: creating projects needs projects.create")
    d = json_body(c)
    Dict("key" => create_project!(c.kb, get(d, "name", ""); key = get(d, "key", ""), description = get(d, "description", ""),
                                  codebase = get(d, "codebase", ""), owner = c.caller.user_id,
                                  add_codebase = can(c.caller, "paper.add"), by = person_of(c), c.caller))
end

# A project's board: its tasks, milestones, codebase, the records linked to it that the caller sees,
# agents at work and how far the caller reaches it.
route!("GET", "/api/projects/:key"; need = "tasks.view", project = VIEW) do c
    kb, key = c.kb, uppercase(c[:key])
    i = findfirst(x -> x.key == key, projects(kb))
    i === nothing && not_found("No project $key")
    p = projects(kb)[i]
    Dict("project" => Dict(pairs(p)), "statuses" => STATUS_JSON, "codebase" => codebase_json(kb, p.codebase),
         "access" => access_name(project_access(kb, c.caller, key)), "manages_members" => manages_members(kb, c.caller, key),
         "agents" => Dict(pairs(agents_at_work(kb, key))),
         "findings" => Int(scalar(kb, "SELECT count(*) FROM findings WHERE project_id = ? AND archived_at IS NULL", (project_id(kb, key),))),
         "records" => [Dict("id" => r.id, "title" => r.title, "day" => record_day(r.date)) for r in visible_records(kb, c.caller; project = key)],
         "milestones" => [Dict(pairs(m)) for m in milestones(kb, key)],
         "tasks" => Any[task_json(t) for t in tasks(kb; project = key, limit = 5000)])
end

route!("POST", "/api/projects/:key"; need = "tasks.edit", project = MAINTAIN) do c
    d = json_body(c)
    update_project!(c.kb, c[:key]; name = opt(d, "name"), description = opt(d, "description"), codebase = opt(d, "codebase"),
                    add_codebase = can(c.caller, "paper.add"), by = person_of(c), c.caller)
    Dict("project" => Dict(pairs(only(p for p in projects(c.kb) if p.key == uppercase(c[:key])))))
end

route!("POST", "/api/projects/:key/delete"; need = "tasks.edit", project = VIEW) do c
    key = uppercase(c[:key])
    manages_members(c.kb, c.caller, key) || not_permitted("Not permitted: a project is deleted by its owner or an admin")
    Dict("deleted" => key, "tasks" => delete_project!(c.kb, key))
end

route!(c -> Any[Dict(pairs(m)) for m in members(c.kb, uppercase(c[:key]))], "GET", "/api/projects/:key/members";
       need = "tasks.view", project = VIEW)
route!("POST", "/api/projects/:key/members"; need = "tasks.edit", project = VIEW) do c
    key = uppercase(c[:key])
    manages_members(c.kb, c.caller, key) || not_permitted("Not permitted: members are managed by the project's owner or an admin")
    d = json_body(c)
    set_member!(c.kb, key, get(d, "who", ""), get(d, "role", ""); by = caller_name(c.caller))
    Any[Dict(pairs(m)) for m in members(c.kb, key)]
end

route!(c -> code_activity(c.kb, c[:key]; days = tryparse(Int, get(c.params, "days", ""))), "GET", "/api/projects/:key/code";
       need = "tasks.view", project = VIEW)
route!(c -> project_review(c.kb, c[:key]), "GET", "/api/projects/:key/review"; need = "tasks.view", project = VIEW)
route!(c -> project_map(c.kb, c[:key]), "GET", "/api/projects/:key/map"; need = "tasks.view", project = VIEW)

route!("GET", "/api/projects/:key/history"; need = "tasks.view", project = VIEW) do c
    h = project_history(c.kb, c[:key])
    Dict("milestones" => Any[merge(Dict(pairs(m)), Dict(:tasks => Any[task_json(t) for t in m.tasks])) for m in h.milestones],
         "archived" => Any[Dict(:day => a.day, :tasks => Any[task_json(t) for t in a.tasks]) for a in h.archived])
end

route!("GET", "/api/projects/:key/declined"; need = "tasks.view", project = VIEW) do c
    Any[merge(task_json(t), Dict(:reason => declined_reason(c.kb, t.ref)))
        for t in tasks(c.kb; project = c[:key], declined = true, top = true, limit = 1000)]
end

route!(c -> Dict("archived" => archive_done!(c.kb, c[:key]; by = person_of(c))), "POST", "/api/projects/:key/archive-done";
       need = "tasks.edit", project = CONTRIBUTE)

# Milestones.
route!("POST", "/api/projects/:key/milestones"; need = "tasks.edit", project = MAINTAIN) do c
    d = json_body(c)
    Dict("name" => create_milestone!(c.kb, c[:key], get(d, "name", ""); due = get(d, "due", ""), start = get(d, "start", ""),
                                     description = get(d, "description", "")))
end

route!("POST", "/api/projects/:key/milestone-update"; need = "tasks.edit", project = MAINTAIN) do c
    d = json_body(c)
    name = update_milestone!(c.kb, c[:key], get(d, "name", ""); start = opt(d, "start"), due = opt(d, "due"),
                             description = opt(d, "description"), rename = opt(d, "rename"))
    Dict("milestone" => only(filter(m -> m.name == name, milestones(c.kb, c[:key]))))
end

route!(c -> Dict("active_milestone" => set_active_milestone!(c.kb, c[:key], get(json_body(c), "name", ""))),
       "POST", "/api/projects/:key/active-milestone"; need = "tasks.edit", project = MAINTAIN)

route!("POST", "/api/projects/:key/milestone-done"; need = "tasks.edit", project = MAINTAIN) do c
    d = json_body(c)
    decisions = [(; ref = String(x["ref"]), action = String(x["action"]), milestone = String(get(x, "milestone", "")))
                 for x in get(d, "decisions", Any[])]
    Dict("milestone" => finish_milestone!(c.kb, c[:key], get(d, "name", ""); reopen = get(d, "reopen", false) === true,
                                          decisions, by = person_of(c)))
end

# What the project works from: a source named as it is mentioned anywhere, and why it matters.
route!(library_reply, "GET", "/api/projects/:key/library"; need = "tasks.view", project = VIEW)
route!("POST", "/api/projects/:key/library"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    library_add!(c.kb, c[:key], get(d, "source", ""); why = get(d, "why", ""), by = person_of(c), c.caller)
    library_reply(c)
end
route!("POST", "/api/projects/:key/library/:item/keep"; need = "tasks.edit", project = CONTRIBUTE) do c
    library_keep!(c.kb, c[:key], something(tryparse(Int, c[:item]), 0); by = person_of(c))
    library_reply(c)
end
route!("POST", "/api/projects/:key/library/:item/delete"; need = "tasks.edit", project = CONTRIBUTE) do c
    library_remove!(c.kb, c[:key], something(tryparse(Int, c[:item]), 0); by = person_of(c))
    library_reply(c)
end

# ── Tasks ─────────────────────────────────────────────────────────────────────────────────────────

route!("POST", "/api/tasks"; need = "tasks.edit") do c
    d = json_body(c)
    need_project!(c.kb, c.caller, get(d, "project", ""), CONTRIBUTE)
    ref = create_task!(c.kb, get(d, "project", ""), get(d, "title", ""); body = get(d, "body", ""), parent = get(d, "parent", ""),
                       milestone = get(d, "milestone", ""), priority = Int(get(d, "priority", 2)), assignee = get(d, "assignee", ""),
                       status = get(d, "status", "backlog"), by = person_of(c))
    task_reply(c, ref)
end

route!(c -> Any[Dict(pairs(p)) for p in known_people(c)], "GET", "/api/tasks/people"; need = "tasks.view")

route!("GET", "/api/tasks/search"; need = "tasks.view") do c
    hits = search_tasks(c.kb, get(c.params, "q", ""); project = named_project(c), me = my_name(c), projects = visible_projects(c.kb, c.caller),
                        limit = int_param(c.params, "limit", 30))
    Any[merge(task_json(t), Dict(:matches => [Dict(pairs(m)) for m in t.matches])) for t in hits if sees(c, t.ref)]
end

# The tasks that changed a codebase's file.
route!("GET", "/api/tasks/file-work"; need = "tasks.view") do c
    codebase = seen_document(c.kb, c.caller, get(c.params, "codebase", ""))
    Any[Dict(pairs(w)) for w in file_work(c.kb, codebase, get(c.params, "path", "")) if sees(c, w.ref)]
end

# What a project can be linked to: the codebases the caller sees.
route!("GET", "/api/tasks/codebases"; need = "tasks.view") do c
    Any[Dict("id" => String(p.doc_id), "title" => coalesce(p.title, p.doc_id)) for p in visible_codebases(c.kb, c.caller)]
end

# What `@` finds as it is typed: tasks and findings the caller sees, and people they may find.
route!("GET", "/api/tasks/references"; need = "tasks.view") do c
    named = named_project(c)
    found = at_reference_matches(c.kb, get(c.params, "q", ""); project = named, c.caller)
    findable = any(r -> r.kind == "person", found) ? Set(p.id for p in known_people(c, named)) : Set{String}()
    Any[Dict(pairs(r)) for r in found if r.kind in ("task", "finding") ? sees(c, r.target) : r.kind != "person" || r.target in findable]
end

# Long polling: answered when projects or tasks change, or after a while without.
route!(c -> Dict("version" => wait_tasks_changed(int_param(c.params, "since", -1))), "GET", "/api/tasks/changes"; need = "tasks.view")

# What waits on the caller. Findings wait on those who may accept them.
route!("GET", "/api/tasks/waiting"; need = "tasks.view") do c
    w = waiting(c.kb; me = my_name(c), asker = caller_name(c.caller))
    accepts(ref) = project_access(c.kb, c.caller, ref_project(ref)) >= CONTRIBUTE
    Dict(k => k == :findings ? Any[Dict(pairs(f)) for f in v if accepts(f.ref)] : Any[task_json(t) for t in v if sees(c, t.ref)]
         for (k, v) in pairs(w))
end

route!(c -> task_reply(c, c[:task]), "GET", "/api/tasks/:task"; need = "tasks.view", project = VIEW)
route!("POST", "/api/tasks/:task"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    update_task!(c.kb, c[:task]; title = opt(d, "title"), body = opt(d, "body"), status = opt(d, "status"),
                 milestone = opt(d, "milestone"), priority = opt(d, "priority"), assignee = opt(d, "assignee"),
                 blocked = opt(d, "blocked"), before = opt(d, "before"), parent = opt(d, "parent"),
                 with_subtasks = get(d, "with_subtasks", false) === true, by = person_of(c))
    task_reply(c, c[:task])
end

route!(c -> Dict("diff" => task_diff(c.kb, c[:task])), "GET", "/api/tasks/:task/diff"; need = "tasks.view", project = VIEW)

route!("GET", "/api/tasks/:task/notes/:note/history"; need = "tasks.view", project = VIEW) do c
    note = something(tryparse(Int, c[:note]), 0)
    any(e -> e.id == note, task(c.kb, c[:task]).activity) || not_found("No note $(c[:note]) on $(uppercase(c[:task]))")
    Any[Dict(pairs(h)) for h in note_history(c.kb, note)]
end

route!("POST", "/api/tasks/:task/resolve"; need = "tasks.edit", project = CONTRIBUTE) do c
    get(json_body(c), "agents", false) === true ? resolve_question!(c.kb, c[:task]; agents = true) :
                                             resolve_question!(c.kb, c[:task]; asker = caller_name(c.caller))
    task_reply(c, c[:task])
end

route!("POST", "/api/tasks/:task/send-back"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    send_back!(c.kb, c[:task]; request = get(d, "request", ""), subtasks = String[string(x) for x in get(d, "subtasks", Any[])],
               by = person_of(c))
    task_reply(c, c[:task])
end

route!("POST", "/api/tasks/:task/decline"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    decline_task!(c.kb, c[:task]; reason = get(d, "reason", ""), undo = get(d, "undo", false) === true, by = person_of(c))
    task_reply(c, c[:task])
end

route!("POST", "/api/tasks/:task/archive"; need = "tasks.edit", project = CONTRIBUTE) do c
    archive_task!(c.kb, c[:task]; undo = get(json_body(c), "undo", false) === true, by = person_of(c))
    task_reply(c, c[:task])
end

route!(c -> Dict("deleted" => delete_task!(c.kb, c[:task]; by = person_of(c))), "POST", "/api/tasks/:task/delete";
       need = "tasks.edit", project = CONTRIBUTE)

# A person's note is a comment or a question.
route!("POST", "/api/tasks/:task/notes"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    kind = get(d, "kind", "comment")
    kind in ("comment", "question") || error("A person's note is a comment or a question: $kind")
    note_task!(c.kb, c[:task], get(d, "text", ""); kind, by = person_of(c))
    task_reply(c, c[:task])
end

route!("POST", "/api/tasks/:task/notes/:note"; need = "tasks.edit", project = CONTRIBUTE) do c
    edit_note!(c.kb, c[:task], something(tryparse(Int, c[:note]), 0), get(json_body(c), "text", ""); by = person_of(c))
    task_reply(c, c[:task])
end

# A task linked to is one the caller may see: a link shows it on the task.
route!("POST", "/api/tasks/:task/links"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    get(d, "kind", "") in ("task", "blocks") && need_project!(c.kb, c.caller, something(ref_project(String(get(d, "target", ""))), ""), VIEW)
    link_task!(c.kb, c[:task], get(d, "kind", ""), get(d, "target", ""); label = get(d, "label", ""),
               remove = get(d, "remove", false) === true, by = person_of(c))
    task_reply(c, c[:task])
end

# ── Findings ──────────────────────────────────────────────────────────────────────────────────────

# The findings resting on a paper (`?paper=`), in the projects the caller sees, for its page; or a
# project's (`?project=`), found by `?q=` or all of them.
route!("GET", "/api/findings"; need = "tasks.view") do c
    kb, params = c.kb, c.params
    if haskey(params, "paper")
        seen = Set(p.key for p in projects(kb) if project_access(kb, c.caller, p.key) >= VIEW)
        return Any[Dict(pairs(f)) for f in paper_findings(kb, normalize_id(params["paper"]); projects = seen)]
    end
    named = named_project(c)
    isempty(named) && error("Name a project: ?project=KEY")
    q = strip(get(params, "q", ""))
    found = isempty(q) ? findings(kb; project = named, status = get(params, "status", ""), archived = get(params, "archived", "") == "1") :
                         search_findings(kb, q; projects = (named,), status = get(params, "status", ""), limit = 50)
    Any[Dict(pairs(f)) for f in found]
end

route!("POST", "/api/findings"; need = "tasks.edit") do c
    d = json_body(c)
    need_project!(c.kb, c.caller, get(d, "project", ""), CONTRIBUTE)
    from = get(d, "task", "")
    isempty(from) || sees(c, from) || not_found("No task $from")
    finding_reply(c, create_finding!(c.kb, get(d, "project", ""), get(d, "claim", ""); body = get(d, "body", ""), task = from,
                                     by = person_of(c)))
end

route!(c -> finding_reply(c, c[:finding]), "GET", "/api/findings/:finding"; need = "tasks.view", project = VIEW)
route!("POST", "/api/findings/:finding"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    update_finding!(c.kb, c[:finding]; claim = opt(d, "claim"), body = opt(d, "body"), status = opt(d, "status"),
                    reason = opt(d, "reason"), by = person_of(c))
    finding_reply(c, c[:finding])
end

route!(c -> Any[Dict(pairs(v)) for v in finding_versions(c.kb, c[:finding])], "GET", "/api/findings/:finding/versions";
       need = "tasks.view", project = VIEW)

route!("POST", "/api/findings/:finding/delete"; need = "tasks.edit", project = CONTRIBUTE) do c
    delete_finding!(c.kb, c[:finding]; by = person_of(c))
    Dict("deleted" => uppercase(c[:finding]))
end

route!("POST", "/api/findings/:finding/archive"; need = "tasks.edit", project = CONTRIBUTE) do c
    archive_finding!(c.kb, c[:finding]; restore = get(json_body(c), "restore", false) == true, by = person_of(c))
    finding_reply(c, c[:finding])
end

# A finding whose evidence changed: it still holds (`{"keep": true}`), or an agent is asked to re-check it.
route!("POST", "/api/findings/:finding/recheck"; need = "tasks.edit", project = CONTRIBUTE) do c
    ref = c[:finding]
    get(json_body(c), "keep", false) === true && (keep_finding!(c.kb, ref; by = person_of(c)); return finding_reply(c, ref))
    asked = recheck_task!(c.kb, ref; by = person_of(c))
    merge(finding_reply(c, ref), Dict(:task => asked))
end

route!("POST", "/api/findings/:finding/evidence"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    src = isempty(strip(get(d, "source", ""))) ? (; kind = get(d, "kind", ""), target = get(d, "target", ""), page = Int(get(d, "page", 0))) :
          evidence_source(d["source"])
    src.kind in ("task", "finding") && !sees(c, src.target) && not_found("No $(src.kind) $(src.target)")
    add_evidence!(c.kb, c[:finding]; src.kind, src.target, src.page, relation = get(d, "relation", "supports"),
                  excerpt = get(d, "excerpt", ""), note = get(d, "note", ""), detail = get(d, "detail", Dict{String,Any}()), by = person_of(c))
    finding_reply(c, c[:finding])
end

route!("POST", "/api/findings/:finding/evidence/:item/delete"; need = "tasks.edit", project = CONTRIBUTE) do c
    remove_evidence!(c.kb, c[:finding], something(tryparse(Int, c[:item]), 0); by = person_of(c))
    finding_reply(c, c[:finding])
end

route!("POST", "/api/findings/:finding/comments"; need = "tasks.edit", project = CONTRIBUTE) do c
    comment_finding!(c.kb, c[:finding], get(json_body(c), "text", ""); by = person_of(c))
    finding_reply(c, c[:finding])
end

route!("POST", "/api/findings/:finding/comments/:comment"; need = "tasks.edit", project = CONTRIBUTE) do c
    edit_finding_comment!(c.kb, c[:finding], something(tryparse(Int, c[:comment]), 0), get(json_body(c), "text", ""); by = person_of(c))
    finding_reply(c, c[:finding])
end
