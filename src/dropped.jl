# Dropping a document: removing it and keeping it out. The knowledge base keeps a list of what was
# dropped, with what each way in knows it by (its id, its DOI, its title, a source's key for it), who
# dropped it, when and why. Every way in checks the list (see `keep_out!`): a source handing in a
# dropped document skips it, and its run counts it; a person adding one by hand is told who dropped it
# and why, and may add it anyway, which restores it. A restored drop stays on the list, marked
# restored, so a source knows to bring its document back.

migration!(10, ["""CREATE TABLE dropped (
                       doc_id TEXT PRIMARY KEY,
                       title TEXT NOT NULL,
                       kind TEXT NOT NULL,
                       doi TEXT NOT NULL DEFAULT '',
                       title_key TEXT NOT NULL DEFAULT '',
                       source TEXT NOT NULL DEFAULT '',
                       key TEXT NOT NULL DEFAULT '',
                       dropped_by TEXT NOT NULL,
                       dropped_at TEXT NOT NULL,
                       why TEXT NOT NULL DEFAULT '',
                       restored_by TEXT,
                       restored_at TEXT)""",
                "CREATE INDEX dropped_doi ON dropped (doi) WHERE doi != ''",
                "CREATE INDEX dropped_title ON dropped (title_key) WHERE title_key != ''",
                "CREATE INDEX dropped_key ON dropped (source, key) WHERE key != ''"])

const DROP_COLUMNS = """doc_id, title, kind, dropped_by, dropped_at, why, coalesce(restored_by, '') AS restored_by,
                        coalesce(restored_at, '') AS restored_at"""

drop_row(r) = (; id = String(r.doc_id), title = String(r.title), kind = String(r.kind), by = String(r.dropped_by),
                 at = String(r.dropped_at), why = String(r.why), restored_by = String(r.restored_by),
                 restored_at = String(r.restored_at))

drop_json(d) = Dict("id" => d.id, "title" => d.title, "kind" => d.kind, "by" => d.by, "at" => d.at, "why" => d.why)

"""
    DroppedError(drop)

A document a person dropped, met on its way back in. Refused (409) with who dropped it, when and why;
a way in that takes `anyway = true` restores it instead (see [`keep_out!`](@ref)).
"""
struct DroppedError <: Exception
    drop::NamedTuple
end
Base.showerror(io::IO, e::DroppedError) = print(io, dropped_message(e.drop))

dropped_message(d) = "$(d.title) ($(d.id)) was dropped by $(d.by) on $(first(d.at, 10))" *
                     (isempty(d.why) ? "" : ": $(d.why)") * ". Adding it anyway restores it."

"""
    drop!(kb, id; by, why = "")

Remove document `id` (see [`remove_paper!`](@ref)) and keep it out: it goes on the dropped list with
its DOI, its title and the key its source knows it by (a record's or a resource's, a codebase's
repository), `by` who dropped it and `why`. No source brings it back until it is restored (see
[`restore!`](@ref)).
"""
function drop!(kb::KB, id::AbstractString; by::AbstractString, why::AbstractString = "")
    rows = query(kb, "SELECT title, coalesce(kind, 'paper') AS kind, coalesce(doi, '') AS doi, remote FROM papers WHERE doc_id = ?", (id,))
    isempty(rows) && not_found("No document $id")
    p = only(rows)
    title = String(coalesce(p.title, id))
    known = query(kb, """SELECT x.source, x.key FROM records x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?
                         UNION ALL
                         SELECT x.source, x.key FROM resources x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?""", (id, id))
    source, key = !isempty(known) ? (String(first(known).source), String(first(known).key)) :
                  !ismissing(p.remote) ? ("repository", String(p.remote)) : ("", "")
    doi = isempty(p.doi) ? "" : normalize_doi(p.doi)
    transaction(kb) do
        execute!(kb, """INSERT OR REPLACE INTO dropped (doc_id, title, kind, doi, title_key, source, key, dropped_by, dropped_at, why)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                 (id, title, p.kind, doi, normalize_title(title), source, key, by, now_iso(), strip(why)))
        # A dataset's copy, imported again once it is restored.
        execute!(kb, "DELETE FROM dataset_docs WHERE doc_id = ?", (id,))
    end
    remove_paper!(kb, id)
    return nothing
end

"""
    restore!(kb, id; by = nothing)

Take document `id` off the dropped list: a person may add it again, and the source it came from
brings it back. It stays listed as restored, with `by` who restored it.
"""
function restore!(kb::KB, id::AbstractString; by = nothing)
    ismissing(scalar(kb, "SELECT 1 FROM dropped WHERE doc_id = ? AND restored_at IS NULL", (id,))) && not_found("$id is not dropped")
    execute!(kb, "UPDATE dropped SET restored_by = ?, restored_at = ? WHERE doc_id = ?", (something(by, ""), now_iso(), id))
    return nothing
end

"""
    dropped_documents(kb) -> Vector{NamedTuple}

What is dropped and kept out, latest first: each document's id, title and kind, who dropped it, when and why.
"""
dropped_documents(kb::KB) =
    [drop_row(r) for r in query(kb, "SELECT $DROP_COLUMNS FROM dropped WHERE restored_at IS NULL ORDER BY dropped_at DESC, rowid DESC")]

"The documents dropped and restored since, for a source to bring back."
restored_documents(kb::KB) = Set(String(r.doc_id) for r in query(kb, "SELECT doc_id FROM dropped WHERE restored_at IS NOT NULL"))

"""
    dropped_as(kb; id = "", doi = "", title = "", source = "", key = "") -> Union{NamedTuple,Nothing}

The drop keeping out a document known by any of these: its id, its DOI, its title (compared as
[`normalize_title`](@ref) has it; given for a work without a DOI) or the key `source` knows it by.
`nothing` when none does.
"""
function dropped_as(kb::KB; id::AbstractString = "", doi::AbstractString = "", title::AbstractString = "",
                    source::AbstractString = "", key::AbstractString = "")
    conds, args = String[], Any[]
    isempty(id) || (push!(conds, "doc_id = ?"); push!(args, id))
    d = normalize_doi(doi)
    isempty(d) || (push!(conds, "doi = ?"); push!(args, d))
    t = normalize_title(title)
    isempty(t) || (push!(conds, "title_key = ?"); push!(args, t))
    isempty(key) || (push!(conds, "(source = ? AND key = ?)"); append!(args, [source, key]))
    isempty(conds) && return nothing
    rows = query(kb, "SELECT $DROP_COLUMNS FROM dropped WHERE restored_at IS NULL AND ($(join(conds, " OR "))) LIMIT 1", Tuple(args))
    return isempty(rows) ? nothing : drop_row(only(rows))
end

"""
    keep_out!(kb, anyway; by = nothing, known...)

Refuse a document on its way in that a person dropped (see [`dropped_as`](@ref), which `known` is
given to) with a [`DroppedError`](@ref); with `anyway`, restore it instead, `by` the person adding it.
"""
function keep_out!(kb::KB, anyway::Bool; by = nothing, known...)
    d = dropped_as(kb; known...)
    d === nothing && return
    anyway || throw(DroppedError(d))
    restore!(kb, d.id; by)
end
