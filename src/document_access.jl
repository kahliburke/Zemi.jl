# Who may see a document: every member of the site (`open`), only those who reach a project linked to
# it (`projects`), as for a private repository's, or only the people it is held for (`private`, its
# holders in `document_holders`), whatever their role, as their own work in progress is. A document
# held for someone is theirs, shared or not (see sharing.jl); one held for no one is the group's. A
# kind with access (see `DocumentKind`; a codebase, a record) is one whose access those who manage
# documents set. A document is linked to projects in `document_projects`, and a codebase to the
# projects it is the codebase of as well. Run for one person, every document is theirs. A document
# someone may not see is, to them, none: it is answered as one that does not exist and left out of
# lists. The site every reader is served is built without it (see site_code.jl), and the dataset does
# not carry it.

"A document's access: open to every reader, only to the members of the projects linked to it, or only to its holders."
const DOCUMENT_ACCESS = ("open", "projects", "private")

migration!(2, ["ALTER TABLE papers ADD COLUMN access TEXT NOT NULL DEFAULT 'open' CHECK (access IN ('open', 'projects'))"])

# The projects a document belongs to, beside a codebase's own (`projects.codebase_id`).
migration!(3, ["""CREATE TABLE document_projects (
                      paper_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                      project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                      PRIMARY KEY (paper_id, project_id))""",
               "CREATE INDEX document_projects_project ON document_projects (project_id)"])

# Access gains `private` (a column's CHECK cannot change in place, so the column is made again), and
# a private document's holders are kept.
migration!(15, ["ALTER TABLE papers ADD COLUMN access_new TEXT NOT NULL DEFAULT 'open' CHECK (access_new IN ('open', 'projects', 'private'))",
                "UPDATE papers SET access_new = access",
                "ALTER TABLE papers DROP COLUMN access",
                "ALTER TABLE papers RENAME COLUMN access_new TO access",
                """CREATE TABLE document_holders (
                       paper_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                       user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                       PRIMARY KEY (paper_id, user_id))""",
                "CREATE INDEX document_holders_user ON document_holders (user_id)"])

"The people (their user ids) document `id` is held for, in order."
document_holders(kb::KB, id::AbstractString) =
    [Int(r.user_id) for r in query(kb, """SELECT h.user_id FROM document_holders h JOIN papers p ON p.id = h.paper_id
                                         WHERE p.doc_id = ? ORDER BY h.user_id""", (id,))]

"The documents (their ids) held for person `uid`."
held_documents(kb::KB, uid::Integer) =
    Set{String}(String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM document_holders h JOIN papers p ON p.id = h.paper_id
                                                        WHERE h.user_id = ?""", (uid,)))

"Whether `caller` is one of document `id`'s holders."
holds(kb::KB, caller::Caller, id::AbstractString) =
    caller.user_id !== nothing && !ismissing(scalar(kb, """SELECT 1 FROM document_holders h JOIN papers p ON p.id = h.paper_id
                                                          WHERE p.doc_id = ? AND h.user_id = ?""", (id, caller.user_id)))

"Hold document `id` for person `uid`."
hold_document!(kb::KB, id::AbstractString, uid::Integer) =
    (execute!(kb, "INSERT OR IGNORE INTO document_holders SELECT id, ? FROM papers WHERE doc_id = ?", (uid, id)); nothing)

"""
    bring_in!(kb, id, holder; new)

Document `id` has been brought into the knowledge base, `new` to it or not, for one person (`holder`,
their user id) or for the group (`nothing`). Brought for a person, a new document is private to
them, and a private one is held for them as well; one open already stays open. Brought for the
group, a document of a kind without access is the group's from then on, held for no one and open to
every reader: a paper is one document, whoever brings it in.
"""
function bring_in!(kb::KB, id::AbstractString, holder::Union{Integer,Nothing}; new::Bool)
    access = scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,))
    ismissing(access) && return nothing
    if holder === nothing
        something(document_kind(id), PAPER).access && return nothing
        execute!(kb, "DELETE FROM document_holders WHERE paper_id = (SELECT id FROM papers WHERE doc_id = ?)", (id,))
        access == "open" || (execute!(kb, "UPDATE papers SET access = 'open' WHERE doc_id = ?", (id,)); note_changes!([id]))
    elseif new || access == "private"
        new && execute!(kb, "UPDATE papers SET access = 'private' WHERE doc_id = ?", (id,))
        hold_document!(kb, id, holder)
    end
    return nothing
end

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

Whether `caller` may see document `id`: an open one; one held for them, whatever their role; and one
with `projects` access when they are a member of a project linked to it (see
[`project_membership`](@ref); `projects.all` reaches every project), whatever they may do with its
tasks. One linked to no project only those with its kind's `unassigned` permission see (a record,
before anyone assigns it).
"""
function document_visible(kb::KB, caller::Caller, id::AbstractString)
    caller.via == :local && return true
    access = coalesce(scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,)), "open")
    access == "open" && return true
    holds(kb, caller, id) && return true
    access == "private" && return false
    return closed_visible(caller, something(document_kind(id), PAPER), document_projects(kb, id), k -> project_membership(kb, caller, k) >= VIEW)
end

"Whether `caller` sees a closed document of `kind` linked to projects `linked`, `sees(key)` saying whether they see a project."
closed_visible(caller::Caller, kind::DocumentKind, linked, sees) =
    isempty(linked) ? kind.unassigned !== nothing && can(caller, kind.unassigned) : any(sees, linked)

"The documents (their ids) not open to every reader: private, or open only to the members of their projects."
closed_documents(kb::KB) =
    Set{String}(String(r.doc_id) for r in query(kb, "SELECT doc_id FROM papers WHERE NOT ($(open_sql()))"))

"The documents `caller` may not see (see [`document_visible`](@ref)), to leave out of what they are answered."
function hidden_documents(kb::KB, caller::Caller)
    caller.via == :local && return Set{String}()
    linked, member = documents_projects(kb), Dict{String,Bool}()
    sees(k) = get!(() -> project_membership(kb, caller, k) >= VIEW, member, k)
    held = caller.user_id === nothing ? Set{String}() : held_documents(kb, caller.user_id)
    hidden = Set{String}()
    for r in query(kb, "SELECT doc_id, access FROM papers WHERE NOT ($(open_sql()))")
        id = String(r.doc_id)
        id in held && continue
        (r.access == "private" || !closed_visible(caller, something(document_kind(id), PAPER), get(linked, id, String[]), sees)) &&
            push!(hidden, id)
    end
    return hidden
end

"""
The private documents not held for `caller`: none of theirs to manage, whatever their role. Those
who manage documents see every other, those of projects they are not in too.
"""
others_private(kb::KB, caller::Caller) =
    caller.via == :local ? Set{String}() :
    Set{String}(String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM papers p WHERE p.access = 'private'
        AND NOT EXISTS (SELECT 1 FROM document_holders h WHERE h.paper_id = p.id AND h.user_id = ?)""", (something(caller.user_id, 0),)))

"Document `id`, refused as none when it is private and not `caller`'s (see [`others_private`](@ref))."
managed_document(kb::KB, caller::Caller, id::AbstractString) =
    (caller.via == :local || coalesce(scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,)), "open") != "private" ||
     holds(kb, caller, id) || not_found("No document $id in the knowledge base"); String(id))

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
    set_document_access!(kb, id, access; holder = nothing) -> String

Make document `id` open to every reader (`"open"`), open only to the members of the projects linked
to it (`"projects"`), or private to its holders (`"private"`), with `holder` (a user id) one of them;
a private document has at least one. Its pages join or leave the site as it is next refreshed.
"""
function set_document_access!(kb::KB, id::AbstractString, access::AbstractString; holder::Union{Integer,Nothing} = nothing)
    access = lowercase(strip(access))
    access in DOCUMENT_ACCESS || error("A document's access is \"open\", \"projects\" or \"private\", not \"$access\"")
    kind = something(document_kind(id), PAPER)
    ismissing(paper_id(kb, id)) && not_found("No document $id in the knowledge base")
    holder === nothing || hold_document!(kb, id, holder)
    access == "private" && isempty(document_holders(kb, id)) && error("A private document is held for someone: give its holder")
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

# A document's access: `{"access": "open" | "projects"}`. A private document is its holders' to open
# (and, to anyone else, none); making one private is theirs too.
route!("POST", "/api/documents/:id/access"; need = "paper.manage") do c
    managed_document(c.kb, c.caller, c[:id])
    access = String(get(json_body(c), "access", ""))
    lowercase(strip(access)) == "private" && error("A document is made private by one of its holders")
    Dict("id" => c[:id], "access" => set_document_access!(c.kb, c[:id], access))
end
