# Resources: what the group uses or cites without reading it in full: a data set, a data portal, a
# news report, a law, a book or report with no copy to read, a paper behind a paywall. Each has a
# title, its authors, a date, its type, a link and a note. A resource is the knowledge base's as a
# paper is: kept in project libraries, cited with `@res-…`, and found by search, which reads the one
# section made of what it says about itself. Sources hand them in through `put_resource!` (a
# reference manager's library, say), and each records where it came from.

# What a resource carries beyond its row of `papers`: the source that made it and its key there (one
# resource a key), its type as the source names it, its address, its note, where it appeared, who
# published it, when it was accessed, and the hash of all of it, which its reading is made from.
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
migration!(9, ["ALTER TABLE resources ADD COLUMN container TEXT NOT NULL DEFAULT ''",
               "ALTER TABLE resources ADD COLUMN publisher TEXT NOT NULL DEFAULT ''",
               "ALTER TABLE resources ADD COLUMN accessed TEXT NOT NULL DEFAULT ''",
               "ALTER TABLE resources ADD COLUMN organizations TEXT NOT NULL DEFAULT '[]'"])

"""
    Resource(; key, title, type = "", authors = [], organizations = [], date = "", url = "", doi = "", note = "",
               container = "", publisher = "", accessed = "", projects = [])

What a source hands in for a resource: its `key` in the source, its `title`, its `type` as the
source calls it ("dataset", "report", "law"), its `authors` and which of them are `organizations`
(an agency, a company), its `date` (as precise as known:
`2021`, `2021-10`, `2021-10-29`), its `url`, its `doi`, a `note` (a license, say), the `container` it
appeared in (a journal, newspaper, website, or the book of a chapter), its `publisher` (or the
institution that issued it), the date it was `accessed`, and the `projects` whose libraries keep it.
"""
Base.@kwdef struct Resource
    key::String
    title::String
    type::String = ""
    authors::Vector{String} = String[]
    organizations::Vector{String} = String[]
    date::String = ""
    url::String = ""
    doi::String = ""
    note::String = ""
    container::String = ""
    publisher::String = ""
    accessed::String = ""
    projects::Vector{String} = String[]
end

"""
    resource_id(source, key) -> String

The id of the resource `source` keeps as `key`: `res-`, the source and the key in lower case
letters, digits and dashes (see [`record_id`](@ref) for how a long or unusual key is made one).
"""
resource_id(source::AbstractString, key::AbstractString) = source_id(RESOURCE.prefix, source, key)

"What a resource is, as what it is read from and the hash that tells when it changed."
resource_content(r::Resource) = (; r.title, r.type, r.authors, r.organizations, r.date, r.url, r.doi, r.note, r.container, r.publisher, r.accessed)

"""
    put_resource!(kb, source, r; by = nothing, proposed = false, why = "", read = true, anyway = false) -> (id, changed)

Write resource `r` from `source`: a new one, or the one `source` keeps under `r.key`, in place, its
id, links and citations kept. Unchanged, nothing is written. It is kept in each of `r.projects`'
libraries, as `by` (a person's name, or `nothing` for the source itself) put it there, and `proposed`
there for a person to keep rather than kept, with `why`; its arrival is a mention from `source` with its address. With `read`, it is then read (see [`read_resource!`](@ref))
and embedded. A new one a person dropped (by its key, its DOI, or its title where it has no DOI) is
refused with a [`DroppedError`](@ref), unless `anyway`, which restores it.
"""
function put_resource!(kb::KB, source::AbstractString, r::Resource; by::Union{AbstractString,Nothing} = nothing,
                        proposed::Bool = false, why::AbstractString = "", read::Bool = true, anyway::Bool = false)
    source = record_source(source)
    title = strip(r.title)
    isempty(title) && error("A resource needs a title")
    isempty(strip(r.key)) && error("A resource needs its key in its source")
    foreach(k -> project_id(kb, k), r.projects)       # each named project is there before anything is written
    known = scalar(kb, "SELECT p.doc_id FROM resources x JOIN papers p ON p.id = x.paper_id WHERE x.source = ? AND x.key = ?", (source, r.key))
    id = ismissing(known) ? resource_id(source, r.key) : String(known)
    ismissing(known) && !ismissing(paper_id(kb, id)) && error("The id $id of $source's resource $(repr(r.key)) is another document's")
    ismissing(known) && keep_out!(kb, anyway; by, id, doi = r.doi, title = isempty(strip(r.doi)) ? title : "", source, key = r.key)
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
                INSERT INTO resources (paper_id, source, key, type, url, note, container, publisher, accessed, organizations,
                                       content_sha, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (paper_id) DO UPDATE SET type = excluded.type, url = excluded.url, note = excluded.note,
                    container = excluded.container, publisher = excluded.publisher, accessed = excluded.accessed,
                    organizations = excluded.organizations, content_sha = excluded.content_sha, updated_at = excluded.updated_at""",
                (pid, source, r.key, r.type, r.url, r.note, strip(r.container), strip(r.publisher), strip(r.accessed), JSON.json(r.organizations), sha, at))
            new && execute!(kb, """INSERT INTO mentions (paper_id, source, channel, posted_at, author, url, message)
                                   VALUES (?, ?, NULL, ?, ?, ?, NULL)""",
                            (pid, source, time(), something(by, missing), isempty(r.url) ? missing : r.url))
        end
    end
    actor = Actor(something(by, source), proposed)
    for k in r.projects
        library_add!(kb, k, id; why, by = actor)
    end
    read && ingest!(kb, [id]; classify = false)
    return (id, true)
end

"The row of resource `id`, with its source's fields, or `nothing`."
function resource_row(kb::KB, id::AbstractString)
    rows = query(kb, """SELECT p.id AS pid, p.doc_id, p.title, p.authors, p.published, p.doi, x.source, x.key, x.type, x.url,
                               x.note, x.container, x.publisher, x.accessed, x.organizations, x.content_sha FROM resources x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?""", (id,))
    return isempty(rows) ? nothing : first(rows)
end

"""
    parse_resource(r) -> ParsedPaper

What resource row `r` is read as: one section, under its title, of what it says about itself: its
type, authors and date, where it appeared and who published it, its note, and where it is.
"""
function parse_resource(r)
    authors = json_list(r.authors)
    lines = filter(!isempty, [join(filter(!isempty, [String(r.type), join(authors, ", "), String(coalesce(r.published, ""))]), " · "),
                              join(filter(!isempty, unique([String(r.container), String(r.publisher)])), " · "),
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
its note, where it appeared and who published it, where it is (its address and DOI, and when it
was accessed there), where it came from, and how it is cited (see [`cite_json`](@ref)).
"""
function resource_json(kb::KB, id::AbstractString)
    r = resource_row(kb, id)
    return Dict{String,Any}("id" => r.doc_id, "slug" => page_slug(r.doc_id), "title" => r.title, "type" => r.type,
                            "authors" => json_list(r.authors), "date" => coalesce(r.published, ""), "note" => r.note, "url" => r.url,
                            "doi" => coalesce(r.doi, ""), "container" => r.container, "publisher" => r.publisher,
                            "accessed" => r.accessed, "source" => r.source, "cite" => cite_json(kb, r.doc_id))
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
    new == id || move_document!(kb, id, new)
    return new
end

"""
    move_document!(kb, id, to)

Make document `to` stand for resource `id`, which it is a copy of: what named the resource names `to`
(project libraries, task links, findings' evidence), `to` gets the resource's DOI where it has none,
the resource is removed, and its id names `to` from then on (see [`current_document`](@ref)).
"""
function move_document!(kb::KB, id::AbstractString, to::AbstractString)
    r = resource_row(kb, id)
    r === nothing && not_found("No resource $id in the knowledge base")
    transaction(kb) do
        ismissing(r.doi) || execute!(kb, "UPDATE papers SET doi = ? WHERE doc_id = ? AND doi IS NULL", (r.doi, to))
        # Where the paper is named already, the resource's link goes; elsewhere it names the paper.
        execute!(kb, """DELETE FROM library WHERE kind = 'paper' AND target = ?
                        AND project_id IN (SELECT project_id FROM library WHERE kind = 'paper' AND target = ?)""", (id, to))
        execute!(kb, "UPDATE library SET target = ? WHERE kind = 'paper' AND target = ?", (to, id))
        execute!(kb, """DELETE FROM task_links WHERE kind = 'paper' AND target = ?
                        AND task_id IN (SELECT task_id FROM task_links WHERE kind = 'paper' AND target = ?)""", (id, to))
        execute!(kb, "UPDATE task_links SET target = ? WHERE kind = 'paper' AND target = ?", (to, id))
        execute!(kb, "UPDATE finding_evidence SET target = ? WHERE kind = 'paper' AND target = ?", (to, id))
        execute!(kb, "INSERT OR REPLACE INTO moved_documents VALUES (?, ?, ?)", (id, to, now_iso()))
    end
    remove_paper!(kb, id)
    tasks_changed!()
    return to
end
