# Who may see a document of a kind with access (see `DocumentKind`; a codebase, a record): every
# member of the site (`open`), or only those who reach a project linked to it (`projects`), as for a
# private repository's. A document is linked to projects in `document_projects`, and a codebase to the
# projects it is the codebase of as well. Run for one person, every document is theirs. A document
# someone may not see is, to them, none: it is answered as one that does not exist and left out of
# lists. The site every reader is served is built without it (see site_code.jl), and the dataset does
# not carry it.

"A document's access: open to every reader, or only to the members of the projects linked to it."
const DOCUMENT_ACCESS = ("open", "projects")

migration!(2, ["ALTER TABLE papers ADD COLUMN access TEXT NOT NULL DEFAULT 'open' CHECK (access IN ('open', 'projects'))"])

# The projects a document belongs to, beside a codebase's own (`projects.codebase_id`).
migration!(3, ["""CREATE TABLE document_projects (
                      paper_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                      project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                      PRIMARY KEY (paper_id, project_id))""",
               "CREATE INDEX document_projects_project ON document_projects (project_id)"])

"""
    document_projects(kb, id) -> Vector{String}

The keys of the projects document `id` is linked to, in order: those it is linked to (see
[`link_document!`](@ref)), and those it is the codebase of.
"""
document_projects(kb::KB, id::AbstractString) = [String(r.key) for r in query(kb, """
    SELECT p.key FROM projects p JOIN papers d ON d.id = p.codebase_id WHERE d.doc_id = ?
    UNION SELECT p.key FROM document_projects l JOIN projects p ON p.id = l.project_id
          JOIN papers d ON d.id = l.paper_id WHERE d.doc_id = ?
    ORDER BY 1""", (id, id))]

"[`document_projects`](@ref) for every document linked to a project, by its id."
function documents_projects(kb::KB)
    out = Dict{String,Vector{String}}()
    for r in query(kb, """
            SELECT d.doc_id, p.key FROM projects p JOIN papers d ON d.id = p.codebase_id
            UNION SELECT d.doc_id, p.key FROM document_projects l JOIN projects p ON p.id = l.project_id
                  JOIN papers d ON d.id = l.paper_id
            ORDER BY 1, 2""")
        push!(get!(Vector{String}, out, String(r.doc_id)), String(r.key))
    end
    return out
end

"""
    link_document!(kb, id, key)
    unlink_document!(kb, id, key)

Link document `id` to project `key`, or undo the link. A codebase stays linked to the projects it is
the codebase of.
"""
link_document!(kb::KB, id::AbstractString, key::AbstractString) =
    (execute!(kb, "INSERT OR IGNORE INTO document_projects VALUES (?, ?)", document_project(kb, id, key)); nothing)
unlink_document!(kb::KB, id::AbstractString, key::AbstractString) =
    (execute!(kb, "DELETE FROM document_projects WHERE paper_id = ? AND project_id = ?", document_project(kb, id, key)); nothing)

function document_project(kb::KB, id::AbstractString, key::AbstractString)
    pid = paper_id(kb, id)
    ismissing(pid) && not_found("No document $id in the knowledge base")
    return (pid, project_id(kb, key))
end

"""
    document_visible(kb, caller, id) -> Bool

Whether `caller` may see document `id`: an open one, and one with `projects` access when they are
a member of a project linked to it (see [`project_membership`](@ref); `projects.all` reaches every
project), whatever they may do with its tasks. One linked to no project only those with its kind's `unassigned` permission see (a
record, before anyone assigns it). A document of a kind without access is every reader's.
"""
function document_visible(kb::KB, caller::Caller, id::AbstractString)
    caller.via == :local && return true
    kind = document_kind(id)
    kind !== nothing && kind.access || return true
    coalesce(scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,)), "open") == "open" && return true
    return closed_visible(caller, kind, document_projects(kb, id), k -> project_membership(kb, caller, k) >= VIEW)
end

"Whether `caller` sees a closed document of `kind` linked to projects `linked`, `sees(key)` saying whether they see a project."
closed_visible(caller::Caller, kind::DocumentKind, linked, sees) =
    isempty(linked) ? kind.unassigned !== nothing && can(caller, kind.unassigned) : any(sees, linked)

"The documents (their ids) open only to the members of their projects."
closed_documents(kb::KB) =
    Set{String}(String(r.doc_id) for r in query(kb, "SELECT doc_id FROM papers WHERE NOT ($(open_sql()))"))

"The documents `caller` may not see (see [`document_visible`](@ref)), to leave out of what they are answered."
function hidden_documents(kb::KB, caller::Caller)
    caller.via == :local && return Set{String}()
    linked, member = documents_projects(kb), Dict{String,Bool}()
    sees(k) = get!(() -> project_membership(kb, caller, k) >= VIEW, member, k)
    hidden = Set{String}()
    for id in closed_documents(kb)
        kind = document_kind(id)
        kind !== nothing && kind.access && !closed_visible(caller, kind, get(linked, id, String[]), sees) && push!(hidden, id)
    end
    return hidden
end

"Document `id`, refused as none when `caller` may not see it."
seen_document(kb::KB, caller::Caller, id::AbstractString) =
    (document_visible(kb, caller, id) || not_found("No $(something(document_kind(id), PAPER).noun) $id in the knowledge base"); id)

"""
    default_codebase_access(c, remote) -> String

The access a codebase newly linked to repository `remote` starts with: `projects` for one read as
the GitHub App (see [`repository_access`](@ref)), a private repository, else `open`. One whose App
installation cannot be asked about now starts closed.
"""
function default_codebase_access(c::Config, remote::AbstractString)
    try
        return isempty(repository_access(c, remote).env) ? "open" : "projects"
    catch e
        @warn "Could not ask GitHub whether the App reads $remote; the codebase is open only to its projects" exception = e
        return "projects"
    end
end

"""
    set_document_access!(kb, id, access) -> String

Make document `id`, of a kind with access, open to every reader (`"open"`) or only to the members of
the projects linked to it (`"projects"`). Its pages join or leave the site as it is next refreshed.
"""
function set_document_access!(kb::KB, id::AbstractString, access::AbstractString)
    access = lowercase(strip(access))
    access in DOCUMENT_ACCESS || error("A document's access is \"open\" or \"projects\", not \"$access\"")
    kind = document_kind(id)
    (kind === nothing || ismissing(paper_id(kb, id))) && not_found("No document $id in the knowledge base")
    kind.access || error("Every $(kind.noun) is open to every reader: its access is not set")
    execute!(kb, "UPDATE papers SET access = ? WHERE doc_id = ?", (access, id))
    note_changes!([id])
    mkpath(kb.config.data_dir)
    touch(changes_stamp(kb.config))
    return access
end

"The codebases `caller` may see, as their rows of `papers`, by title."
visible_codebases(kb::KB, caller::Caller) =
    (hidden = hidden_documents(kb, caller);
     [p for p in query(kb, "SELECT * FROM papers WHERE $(kind_in(CODEBASE)) ORDER BY title") if !(p.doc_id in hidden)])

# The codebases the caller may see, as the Codebases page lists them: it lists those the site is
# built without as it is read.
route!("GET", "/api/codebases") do c
    Any[Dict(k => d[k] for k in ("id", "slug", "title", "one_line", "files", "commit", "access"))
        for d in (codebase_page_json(c.kb, p) for p in visible_codebases(c.kb, c.caller))]
end

# A document's access: `{"access": "open" | "projects"}`.
route!("POST", "/api/documents/:id/access"; need = "paper.manage") do c
    Dict("id" => c[:id], "access" => set_document_access!(c.kb, c[:id], String(get(json_body(c), "access", ""))))
end
