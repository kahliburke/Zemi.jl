# Resources: what the group uses or cites without reading it in full: a data set, a data portal, a
# news report, a law, a book or report with no copy to read, a paper behind a paywall. Each has a
# title, its authors, a date, its type, a link and a note. A resource is the knowledge base's as a
# paper is: kept in project libraries, cited with `@res-…`, and found by search, which reads the one
# section made of what it says about itself. Sources hand them in through `put_resource!` (a
# reference manager's library, say), and each records where it came from.

# What a resource carries beyond its row of `papers`: the source that made it and its key there (one
# resource a key), its type as the source names it, its address, its note, and the hash of all of
# it, which its reading is made from.
migration!(7, ["""CREATE TABLE resources (
                      paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
                      source TEXT NOT NULL,
                      key TEXT NOT NULL,
                      type TEXT NOT NULL DEFAULT '',
                      url TEXT NOT NULL DEFAULT '',
                      note TEXT NOT NULL DEFAULT '',
                      content_sha TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      UNIQUE (source, key))"""])

"""
    Resource(; key, title, type = "", authors = [], date = "", url = "", doi = "", note = "", projects = [])

What a source hands in for a resource: its `key` in the source, its `title`, its `type` as the
source calls it ("dataset", "report", "law"), its `authors`, its `date` (as precise as known:
`2021`, `2021-10`, `2021-10-29`), its `url`, its `doi`, a `note` (a license, when it was looked at),
and the `projects` whose libraries keep it.
"""
Base.@kwdef struct Resource
    key::String
    title::String
    type::String = ""
    authors::Vector{String} = String[]
    date::String = ""
    url::String = ""
    doi::String = ""
    note::String = ""
    projects::Vector{String} = String[]
end

"""
    resource_id(source, key) -> String

The id of the resource `source` keeps as `key`: `res-`, the source and the key in lower case
letters, digits and dashes (see [`record_id`](@ref) for how a long or unusual key is made one).
"""
resource_id(source::AbstractString, key::AbstractString) = source_id(RESOURCE.prefix, source, key)

"What a resource is, as what it is read from and the hash that tells when it changed."
resource_content(r::Resource) = (; r.title, r.type, r.authors, r.date, r.url, r.doi, r.note)

"""
    put_resource!(kb, source, r; by = nothing, proposed = false, read = true) -> (id, changed)

Write resource `r` from `source`: a new one, or the one `source` keeps under `r.key`, in place, its
id, links and citations kept. Unchanged, nothing is written. It is kept in each of `r.projects`'
libraries, as `by` (a person's name, or `nothing` for the source itself) put it there, and `proposed`
there for a person to keep rather than kept; its arrival is a mention from `source` with its address. With `read`, it is then read (see [`read_resource!`](@ref))
and embedded.
"""
function put_resource!(kb::KB, source::AbstractString, r::Resource; by::Union{AbstractString,Nothing} = nothing,
                        proposed::Bool = false, read::Bool = true)
    source = record_source(source)
    title = strip(r.title)
    isempty(title) && error("A resource needs a title")
    isempty(strip(r.key)) && error("A resource needs its key in its source")
    foreach(k -> project_id(kb, k), r.projects)       # each named project is there before anything is written
    known = scalar(kb, "SELECT p.doc_id FROM resources x JOIN papers p ON p.id = x.paper_id WHERE x.source = ? AND x.key = ?", (source, r.key))
    id = ismissing(known) ? resource_id(source, r.key) : String(known)
    ismissing(known) && !ismissing(paper_id(kb, id)) && error("The id $id of $source's resource $(repr(r.key)) is another document's")
    sha = bytes2hex(sha256(JSON.json(resource_content(r))))
    isequal(scalar(kb, "SELECT x.content_sha FROM resources x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)), sha) &&
        return (id, false)
    at = now_iso()
    lock(paper_lock(id)) do
        transaction(kb) do
            new = ismissing(paper_id(kb, id))
            execute!(kb, """
                INSERT INTO papers (doc_id, version, title, abstract, authors, published, doi, primary_category, categories, kind,
                                    metadata_at, added_at)
                VALUES (?, '', ?, ?, ?, ?, ?, ?, '[]', ?, ?, ?)
                ON CONFLICT (doc_id) DO UPDATE SET title = excluded.title, abstract = excluded.abstract, authors = excluded.authors,
                    published = excluded.published, doi = excluded.doi, primary_category = excluded.primary_category,
                    metadata_at = excluded.metadata_at""",
                (id, title, r.note, JSON.json(r.authors), r.date, isempty(r.doi) ? missing : lowercase(strip(r.doi)), r.type,
                 RESOURCE.name, at, at))
            pid = paper_id(kb, id)
            execute!(kb, """
                INSERT INTO resources (paper_id, source, key, type, url, note, content_sha, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (paper_id) DO UPDATE SET type = excluded.type, url = excluded.url, note = excluded.note,
                    content_sha = excluded.content_sha, updated_at = excluded.updated_at""",
                (pid, source, r.key, r.type, r.url, r.note, sha, at))
            new && execute!(kb, """INSERT INTO mentions (paper_id, source, channel, posted_at, author, url, message)
                                   VALUES (?, ?, NULL, ?, ?, ?, NULL)""",
                            (pid, source, time(), something(by, missing), isempty(r.url) ? missing : r.url))
        end
    end
    actor = Actor(something(by, source), proposed)
    for k in r.projects
        library_add!(kb, k, id; by = actor)
    end
    read && ingest!(kb, [id]; classify = false)
    return (id, true)
end

"The row of resource `id`, with its source's fields, or `nothing`."
function resource_row(kb::KB, id::AbstractString)
    rows = query(kb, """SELECT p.id AS pid, p.doc_id, p.title, p.authors, p.published, p.doi, x.source, x.key, x.type, x.url,
                               x.note, x.content_sha FROM resources x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?""", (id,))
    return isempty(rows) ? nothing : first(rows)
end

"""
    parse_resource(r) -> ParsedPaper

What resource row `r` is read as: one section, under its title, of what it says about itself: its
type, authors and date, its note, and where it is.
"""
function parse_resource(r)
    authors = json_list(r.authors)
    lines = filter(!isempty, [join(filter(!isempty, [String(r.type), join(authors, ", "), String(coalesce(r.published, ""))]), " · "),
                              String(r.note), String(r.url), ismissing(r.doi) ? "" : "doi:" * r.doi])
    pieces = [Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), String(r.title), 1, 0, "")]
    isempty(lines) || push!(pieces, Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), join(lines, "\n\n"), 1, 0, ""))
    return ParsedPaper(1, pieces, [Section(1, 1, "", String(r.title), String(r.title), 1, 1)])
end

"""
    read_resource!(kb, id; force = false, step) -> Bool

Read resource `id` (see [`parse_resource`](@ref)), unless what it was read from is what it is.
Returns whether it was read.
"""
function read_resource!(kb::KB, id::AbstractString; force::Bool = false, step = msg -> nothing)
    r = resource_row(kb, id)
    r === nothing && not_found("No resource $id in the knowledge base")
    prev = query(kb, "SELECT file_sha, parser_version FROM parses WHERE paper_id = ?", (r.pid,))
    !force && !isempty(prev) && first(prev).file_sha == r.content_sha && first(prev).parser_version == PARSER_VERSION && return false
    step("reading the resource")
    parsed = parse_resource(r)
    store_parse!(kb, id, parsed; file_sha = r.content_sha, chunks = chunk_paper(parsed))
    return true
end

"""
    resource_note(kb, id) -> String

What a reader or an agent is told wherever resource `id` is given them: that it is a resource the
group uses, not read in full, with its type and where it came from.
"""
function resource_note(kb::KB, id::AbstractString)
    r = resource_row(kb, id)
    r === nothing && return ""
    return "Resource$(isempty(r.type) ? "" : " ($(r.type))") from $(r.source): title, authors, date and note only, not read in full."
end

# ── On the site ───────────────────────────────────────────────────────────────────────────────────

"""
    resource_json(kb, id) -> Dict

The data of resource `id`'s page (KBResourcePage.vue lays it out): what it is, who made it and when,
its note, where it is (its address and DOI), and where it came from.
"""
function resource_json(kb::KB, id::AbstractString)
    r = resource_row(kb, id)
    return Dict{String,Any}("id" => r.doc_id, "slug" => page_slug(r.doc_id), "title" => r.title, "type" => r.type,
                            "authors" => json_list(r.authors), "date" => coalesce(r.published, ""), "note" => r.note, "url" => r.url,
                            "doi" => coalesce(r.doi, ""), "source" => r.source)
end

"Each resource that became another document (see [`promote_resource!`](@ref)), by its slug, with where that one's page is."
moved_resources(kb::KB) =
    [(; slug = page_slug(r.from_id), page = document_page(current_document(kb, r.from_id)))
     for r in query(kb, "SELECT from_id FROM moved_documents WHERE from_id LIKE ?", (RESOURCE.prefix * "%",))]

"Every resource, as the page listing them shows each (`resources.json`), by title."
resources_json(kb::KB) =
    [Dict("id" => r.doc_id, "slug" => page_slug(r.doc_id), "page" => document_page(r.doc_id), "title" => r.title, "type" => r.type,
          "authors" => json_list(r.authors), "date" => coalesce(r.published, ""), "source" => r.source)
     for r in query(kb, """SELECT p.doc_id, p.title, p.authors, p.published, x.type, x.source
                           FROM resources x JOIN papers p ON p.id = x.paper_id ORDER BY lower(p.title)""")]

# ── Becoming a paper ──────────────────────────────────────────────────────────────────────────────

# A document that became another (a resource read in full once its PDF was uploaded): `@` mentions
# and sources that name the first are taken to name the second.
migration!(8, ["CREATE TABLE moved_documents (from_id TEXT PRIMARY KEY, to_id TEXT NOT NULL, at TEXT NOT NULL)"])

"The document `id` names now: itself, or the one it became (see [`promote_resource!`](@ref))."
function current_document(kb::KB, id::AbstractString)
    for _ in 1:10                                     # a document moved again follows each move
        to = scalar(kb, "SELECT to_id FROM moved_documents WHERE from_id = ?", (id,))
        ismissing(to) && return String(id)
        id = to
    end
    return String(id)
end

"""
    promote_resource!(kb, id, pdf; by = nothing) -> String

Read resource `id` in full from its PDF, at `pdf`: the PDF becomes a paper (see [`add_pdf!`](@ref)),
with the resource's title, authors, year and DOI where the PDF gives none, and returning the paper's
id. What named the resource names the paper: project libraries, task links and findings' evidence;
the resource is removed, and its id names the paper from then on (see [`current_document`](@ref)).
The paper is not read here (see [`ingest!`](@ref)).
"""
function promote_resource!(kb::KB, id::AbstractString, pdf::AbstractString; by = nothing)
    r = resource_row(kb, id)
    r === nothing && not_found("No resource $id in the knowledge base")
    year = coalesce(r.published, "")
    new = add_pdf!(kb, pdf; title = r.title, authors = json_list(r.authors), published = isempty(year) ? nothing : first(year, 4),
                   added_by = by)
    new == id && return new
    transaction(kb) do
        ismissing(r.doi) || execute!(kb, "UPDATE papers SET doi = ? WHERE doc_id = ? AND doi IS NULL", (r.doi, new))
        # Where the paper is named already, the resource's link goes; elsewhere it names the paper.
        execute!(kb, """DELETE FROM library WHERE kind = 'paper' AND target = ?
                        AND project_id IN (SELECT project_id FROM library WHERE kind = 'paper' AND target = ?)""", (id, new))
        execute!(kb, "UPDATE library SET target = ? WHERE kind = 'paper' AND target = ?", (new, id))
        execute!(kb, """DELETE FROM task_links WHERE kind = 'paper' AND target = ?
                        AND task_id IN (SELECT task_id FROM task_links WHERE kind = 'paper' AND target = ?)""", (id, new))
        execute!(kb, "UPDATE task_links SET target = ? WHERE kind = 'paper' AND target = ?", (new, id))
        execute!(kb, "UPDATE finding_evidence SET target = ? WHERE kind = 'paper' AND target = ?", (new, id))
        execute!(kb, "INSERT OR REPLACE INTO moved_documents VALUES (?, ?, ?)", (id, new, now_iso()))
    end
    remove_paper!(kb, id)
    tasks_changed!()
    return new
end
