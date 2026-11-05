# A project's library: what it works from, gathered (papers, notebooks and codebases), each with a
# line on why it matters to the project. A person's items are kept; an agent's are proposed until a
# person keeps them. The project's own codebase is always in it.

"""
    library_source(kb, source; caller = local_caller()) -> (; kind, target)

What a library item names, written as it is mentioned anywhere: a paper (`@arXiv:2401.00001`, `@doc-…`,
or an arXiv id alone), a notebook (`@[label](notebook:path)`), or a codebase (its id, `code-…`, or its
repository's address, which records it if it is new) that `caller` may see.
"""
function library_source(kb::KB, source::AbstractString; caller::Caller = local_caller())
    s = String(strip(source))
    if is_codebase(lstrip(s, '@')) && occursin(r"^@?[A-Za-z0-9-]+$", s)
        id = lowercase(lstrip(s, '@'))
        ismissing(paper_id(kb, id)) && not_found("No codebase $id in the knowledge base")
        return (; kind = "codebase", target = seen_document(kb, caller, id))
    end
    is_repository(s) && return (; kind = "codebase", target = seen_document(kb, caller, link_repository!(kb, s)))
    e = evidence_source(s)
    e.kind in ("paper", "notebook") || error("A library holds papers, notebooks and codebases, not a $(e.kind): $s")
    e.kind == "paper" && ismissing(paper_id(kb, e.target)) && not_found("No paper $(e.target) in the knowledge base")
    return (; kind = e.kind, target = e.target)
end

"""
    library_add!(kb, key, source; why = "", by, caller = local_caller()) -> Int

Put `source` (see [`library_source`](@ref), for `caller`) in project `key`'s library, with `why` it
matters to the project, returning the item's id. An agent's item is proposed until a person keeps
it; adding an item already there gives it the new `why`, and a person adding an agent's proposal
keeps it.
"""
function library_add!(kb::KB, key::AbstractString, source::AbstractString; why::AbstractString = "", by::Actor,
                      caller::Caller = local_caller())
    pid = project_id(kb, key)
    src = library_source(kb, source; caller)
    rows = query(kb, "SELECT id FROM library WHERE project_id = ? AND kind = ? AND target = ?", (pid, src.kind, src.target))
    if isempty(rows)
        execute!(kb, """INSERT INTO library (project_id, kind, target, why, status, added_by, by_agent, added_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                 (pid, src.kind, src.target, strip(why), by.agent ? "proposed" : "kept", by.name, by.agent ? 1 : 0, now_iso()))
        id = Int(scalar(kb, "SELECT last_insert_rowid()"))
    else
        id = Int(first(rows).id)
        isempty(strip(why)) || execute!(kb, "UPDATE library SET why = ? WHERE id = ?", (strip(why), id))
        by.agent || execute!(kb, "UPDATE library SET status = 'kept' WHERE id = ?", (id,))
    end
    tasks_changed!()
    return id
end

"The id of item `id` in project `key`'s library, or an error naming it."
function library_item(kb::KB, key::AbstractString, id::Integer)
    row = query(kb, "SELECT status, by_agent FROM library WHERE id = ? AND project_id = ?", (id, project_id(kb, key)))
    isempty(row) && not_found("No item $id in $(uppercase(strip(key)))'s library")
    return first(row)
end

"Keep item `id` an agent proposed for project `key`'s library: only a person does."
function library_keep!(kb::KB, key::AbstractString, id::Integer; by::Actor)
    by.agent && error("Only a person keeps an item in a project's library")
    library_item(kb, key, id)
    execute!(kb, "UPDATE library SET status = 'kept' WHERE id = ?", (id,))
    tasks_changed!()
end

"Take item `id` out of project `key`'s library. An agent takes out only what an agent proposed."
function library_remove!(kb::KB, key::AbstractString, id::Integer; by::Actor)
    item = library_item(kb, key, id)
    by.agent && !(item.status == "proposed" && item.by_agent == 1) && error("An agent takes out only what an agent proposed")
    execute!(kb, "DELETE FROM library WHERE id = ?", (id,))
    tasks_changed!()
end

"""
    library(kb, key; caller = local_caller()) -> Vector{NamedTuple}

Project `key`'s library: its codebase first, then its items, kept before proposed, papers, notebooks
and codebases, each `(; id, kind, target, label, why, status, added_by, by_agent, added_at, tasks,
findings)`, `tasks` and `findings` the references of the project's tasks that link to it and of its
findings that rest on it. The codebase linked to the project has id 0. A document `caller` may not
see (see [`document_visible`](@ref)) is left out.
"""
function library(kb::KB, key::AbstractString; caller::Caller = local_caller())
    pid = project_id(kb, key)
    cited(kind, target) = (
        tasks = [String(r.ref) for r in query(kb, """SELECT DISTINCT p.key || '-' || t.number AS ref FROM task_links l
                    JOIN tasks t ON t.id = l.task_id JOIN projects p ON p.id = t.project_id
                    WHERE l.kind = ? AND l.target = ? AND t.project_id = ? AND t.archived_at IS NULL ORDER BY t.number""", (kind, target, pid))],
        findings = [String(r.ref) for r in query(kb, """SELECT DISTINCT p.key || '-F' || f.number AS ref FROM finding_evidence e
                    JOIN findings f ON f.id = e.finding_id JOIN projects p ON p.id = f.project_id
                    WHERE e.kind = ? AND e.target = ? AND f.project_id = ? AND f.archived_at IS NULL ORDER BY f.number""", (kind, target, pid))])
    label(kind, target) = kind == "codebase" ? String(coalesce(scalar(kb, "SELECT title FROM papers WHERE doc_id = ?", (target,)), target)) :
                          source_label(kb, kind, target)
    out = NamedTuple[]
    code = project_codebase(kb, key)
    isempty(code) || push!(out, (; id = 0, kind = "codebase", target = code, label = label("codebase", code), why = "The project's codebase",
                                  status = "kept", added_by = "", by_agent = false, added_at = "", tasks = String[], findings = String[]))
    for r in query(kb, """SELECT * FROM library WHERE project_id = ?
                          ORDER BY status = 'proposed', CASE kind WHEN 'paper' THEN 0 WHEN 'notebook' THEN 1 ELSE 2 END, added_at""", (pid,))
        r.kind == "codebase" && r.target == code && continue
        r.kind in ("paper", "codebase") && !document_visible(kb, caller, r.target) && continue
        c = cited(r.kind, r.target)
        push!(out, (; id = Int(r.id), kind = String(r.kind), target = String(r.target), label = label(r.kind, r.target),
                      why = String(r.why), status = String(r.status), added_by = String(r.added_by), by_agent = r.by_agent == 1,
                      added_at = String(r.added_at), c.tasks, c.findings))
    end
    return out
end

"""
    library_holding(kb, kind, target) -> Dict{String,NamedTuple}

The libraries holding `kind` `target`, by project key, each its item `(; id, status, why)`. A
project holds its own codebase as item 0.
"""
function library_holding(kb::KB, kind::AbstractString, target::AbstractString)
    out = Dict{String,NamedTuple}()
    kind == "codebase" && for r in query(kb, "SELECT p.key FROM projects p JOIN papers c ON c.id = p.codebase_id WHERE c.doc_id = ?", (target,))
        out[String(r.key)] = (; id = 0, status = "kept", why = "The project's codebase")
    end
    for r in query(kb, """SELECT p.key, l.id, l.status, l.why FROM library l JOIN projects p ON p.id = l.project_id
                          WHERE l.kind = ? AND l.target = ?""", (kind, target))
        get!(out, String(r.key), (; id = Int(r.id), status = String(r.status), why = String(r.why)))
    end
    return out
end

"The papers project `key`'s library keeps, by their ids, to search within (see [`search`](@ref))."
library_papers(kb::KB, key::AbstractString) =
    Set(String(r.target) for r in query(kb, "SELECT target FROM library WHERE project_id = ? AND kind = 'paper' AND status = 'kept'",
                                        (project_id(kb, key),)))

"""
    format_library(kb, key; caller = local_caller()) -> String

Project `key`'s library as text for an agent working for `caller` (see [`library`](@ref)): each item
with why it matters to the project and what cites it, those an agent proposed marked so.
"""
function format_library(kb::KB, key::AbstractString; caller::Caller = local_caller())
    items = library(kb, key; caller)
    k = uppercase(strip(key))
    isempty(items) && return "$k's library is empty. Propose what the project works from with `library_add`."
    io = IOBuffer()
    for x in items
        name = x.kind == "paper" ? cited_as(x.target) : x.target
        print(io, "- ", x.kind, " ", name, x.label == x.target || isempty(x.label) ? "" : " ($(x.label))")
        x.status == "proposed" && print(io, " [proposed by $(x.added_by)]")
        isempty(x.why) || print(io, ": ", x.why)
        cites = [x.tasks; x.findings]
        isempty(cites) || print(io, " · cited by ", join(cites, ", "))
        x.id > 0 && print(io, " · item $(x.id)")
        println(io)
    end
    return String(take!(io))
end
