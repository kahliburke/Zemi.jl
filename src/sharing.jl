# What a person holds (see document_access.jl), shared and contributed. Sharing lets others see it:
# the members of projects, or every reader. It stays the person's and live: what they change of it,
# others see, they may make it private again, and it goes with them when they leave. Contributing
# hands a version of it to the group: a paper (one document whoever brings it in) becomes the group's,
# and a note is copied into a record the group owns, which contributing again brings up to date (its
# id, links and the findings citing it kept). While the person's own note is as they contributed it,
# what they find shows the contribution alone.

migration!(18, ["""CREATE TABLE contributions (
                       paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
                       contributed TEXT NOT NULL,
                       content_sha TEXT NOT NULL,
                       user_id INTEGER NOT NULL,
                       at TEXT NOT NULL)"""])

# The source of the records people contribute from their libraries.
record_source!("contributions"; label = "Contributed from a person's library", summarized = false,
               about = "a note a person contributed to the group from their library", api = PLUGIN_API)

"Document `id`, refused as none unless `caller` holds it."
held_document(kb::KB, caller::Caller, id::AbstractString) =
    (holds(kb, caller, id) || not_found("No document $id in your library"); String(id))

# The projects something is shared with or contributed to: each one the caller changes work in.
function sharing_projects(kb::KB, caller::Caller, access::AbstractString, projects)
    access == "projects" || return String[]
    keys = unique([need_project!(kb, caller, String(k), CONTRIBUTE) for k in projects])
    isempty(keys) && error("Name the projects to share it with")
    return keys
end

# Link `id` to exactly `keys`.
function link_exactly!(kb::KB, id::AbstractString, keys)
    for k in document_projects(kb, id)
        k in keys || unlink_document!(kb, id, k)
    end
    foreach(k -> link_document!(kb, id, k), keys)
end

"""
    share_document!(kb, caller, id, access; projects = []) -> String

One of the holders of document `id` (`caller`) sets who sees it: its holders alone (`"private"`),
the members of `projects` (`"projects"`, each one they change work in), or every reader (`"open"`).
It stays theirs (see sharing.jl).
"""
function share_document!(kb::KB, caller::Caller, id::AbstractString, access::AbstractString; projects = String[])
    held_document(kb, caller, id)
    access = lowercase(strip(access))
    access in DOCUMENT_ACCESS || error("Share a document as \"private\", \"projects\" or \"open\", not \"$access\"")
    keys = sharing_projects(kb, caller, access, projects)
    access == "projects" && link_exactly!(kb, id, keys)
    return set_document_access!(kb, id, access)
end

"""
    contribute_document!(kb, caller, id; access = "open", projects = []) -> String

One of the holders of document `id` (`caller`) hands a version of it to the group, open to every
reader or to the members of `projects`, returning the group's document. A paper becomes the group's,
held for no one. A record (a note) is copied into a record of the `contributions` source, by the
person; contributed again, that record is brought up to date.
"""
function contribute_document!(kb::KB, caller::Caller, id::AbstractString; access::AbstractString = "open", projects = String[])
    held_document(kb, caller, id)
    access = lowercase(strip(access))
    access in ("open", "projects") || error("A contribution is open to every reader or to projects, not \"$access\"")
    keys = sharing_projects(kb, caller, access, projects)
    if !is_record(id)
        execute!(kb, "DELETE FROM document_holders WHERE paper_id = ?", (paper_id(kb, id),))
        access == "projects" && link_exactly!(kb, id, keys)
        set_document_access!(kb, id, access)
        return String(id)
    end
    doc, row, p = record_document(kb, id), record_row(kb, id), paper_row(kb, id)
    dir = figures_dir(kb.config, id)
    figures = [(; name = String(f["name"]), caption = String(f["caption"]), image = read(joinpath(dir, f["file"])))
               for f in doc["figures"] if isfile(joinpath(dir, f["file"]))]
    r = (; key = id, title = String(p.title), date = String(row.happened), people = json_list(p.authors),
           sections = [(; heading = String(s["heading"]), text = String(s["text"])) for s in doc["sections"]], figures,
           transcript = [(; speaker = String(t["speaker"]), start = t["start"], stop = t["end"], text = String(t["text"])) for t in doc["transcript"]],
           url = String(row.url), projects = keys, access)
    who = caller_name(caller)
    cid, _ = put_record!(kb, "contributions", r; label = "Contributed by $who from their library", by = who)
    set_document_access!(kb, cid, access)                 # a contribution again may open it wider, or narrower
    access == "projects" && link_exactly!(kb, cid, keys)
    execute!(kb, "INSERT OR REPLACE INTO contributions (paper_id, contributed, content_sha, user_id, at) VALUES (?, ?, ?, ?, ?)",
             (paper_id(kb, id), cid, row.content_sha, caller.user_id, now_iso()))
    return cid
end

"""
    superseded_documents(kb, caller) -> Set{String}

The notes `caller` holds that are as they contributed them (see [`contribute_document!`](@ref)): what
they find shows their contributions in their place.
"""
function superseded_documents(kb::KB, caller::Caller)
    caller.user_id === nothing && return Set{String}()
    return Set{String}(String(r.doc_id) for r in query(kb, """
        SELECT p.doc_id FROM contributions c JOIN papers p ON p.id = c.paper_id JOIN records x ON x.paper_id = p.id
        JOIN document_holders h ON h.paper_id = p.id WHERE h.user_id = ? AND x.content_sha = c.content_sha""", (caller.user_id,)))
end

"What `caller` is not to find: what they may not see (see [`hidden_documents`](@ref)), and their notes their contributions stand for."
unfound_documents(kb::KB, caller::Caller) = union(hidden_documents(kb, caller), superseded_documents(kb, caller))

"""
    remove_library!(kb, uid) -> NamedTuple

Person `uid` leaves: their library goes, its files and every document held for them alone, shared
or not, with everything made from it. What they contributed stays the group's, and a document held
for others too stays theirs. Returns how many files and documents went.
"""
function remove_library!(kb::KB, uid::Integer)
    space = "people/$uid"
    files = library_files(kb, space)
    foreach(f -> delete_library_file!(kb, space, f.path), files)
    execute!(kb, "DELETE FROM kv WHERE key = ? OR key LIKE ?", (library_state_key(space), source_state_key("obsidian") * ":" * space * ":%"))
    held = [String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM document_holders h JOIN papers p ON p.id = h.paper_id
                                                    WHERE h.user_id = ?""", (uid,))]
    gone = 0
    for id in held
        execute!(kb, "DELETE FROM document_holders WHERE user_id = ? AND paper_id = ?", (uid, paper_id(kb, id)))
        isempty(document_holders(kb, id)) || continue
        remove_paper!(kb, id)
        gone += 1
    end
    return (; files = length(files), documents = gone)
end

# ── The API ───────────────────────────────────────────────────────────────────────────────────────

sharing_body(c) = (b = json_body(c); (String(get(b, "access", "")), String.(get(b, "projects", String[]))))

# Who sees a document one holds: `{"access": "private" | "projects" | "open", "projects": [KEY, …]}`.
route!("POST", "/api/documents/:id/share"; need = "library") do c
    access, projects = sharing_body(c)
    Dict("id" => c[:id], "access" => share_document!(c.kb, c.caller, c[:id], access; projects))
end

# A version of a document one holds, given to the group: `{"access": "open" | "projects", "projects": […]}`.
route!("POST", "/api/documents/:id/contribute"; need = "library") do c
    access, projects = sharing_body(c)
    Dict("id" => contribute_document!(c.kb, c.caller, c[:id]; access = isempty(access) ? "open" : access, projects))
end

# Leaving: one's library removed, what one contributed kept (`{"confirm": true}`).
route!("POST", "/api/library/remove"; need = "library") do c
    get(json_body(c), "confirm", false) === true || error("Removing your library cannot be undone: confirm it")
    c.caller.user_id === nothing && error("A library run for one person is removed with its data folder")
    r = remove_library!(c.kb, c.caller.user_id)
    Dict("files" => r.files, "documents" => r.documents)
end
