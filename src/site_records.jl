# Records on the site: a record's page, made from its kind's template (see `TEMPLATED`) and drawn
# from its data, and the page listing them. No record is built into the site, open or not: the
# service answers at the addresses a built page would have, to those who may see it (see
# `record_site_response`), in the shared service and run for one person alike.

"""
    record_page_json(kb, p) -> Dict

The data of record `p`'s page (KBRecordPage.vue lays it out): what it is and where it came from (its
date, people, label, source and address), its projects and access, its summary and topics, its text
with its figures in place and captioned, its transcript, and how it is cited (see [`cite_json`](@ref)).
"""
function record_page_json(kb::KB, p)
    id, slug = String(p.doc_id), page_slug(p.doc_id)
    r = record_row(kb, id)
    doc = record_document(kb, id)
    summary, topics = split_topics(coalesce(scalar(kb,
        "SELECT text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%' AND summarizer = ?",
        (p.id, something(shown_summarizer(kb, id), ""))), ""))
    src(f) = "/api/figures/$slug/$(f["file"])"
    figures = Dict(String(f["name"]) => f for f in doc["figures"])
    placed = Set{String}()
    # A figure's image, as the text names it, becomes the figure with its caption beneath it.
    function shown(text)
        replace(text, FIGURE_IMAGE => function (m)
            name = String(match(FIGURE_IMAGE, m)[1])
            haskey(figures, name) || return m
            push!(placed, name)
            f = figures[name]
            caption = md_escape(String(f["caption"]))
            return "\n\n![$caption]($(src(f)))\n\n" * (isempty(caption) ? "" : "*$caption*\n\n")
        end)
    end
    sections = [Dict("heading" => String(s["heading"]), "text" => shown(String(s["text"]))) for s in doc["sections"]]
    titles = Dict(String(x.key) => String(x.name) for x in query(kb, "SELECT key, name FROM projects"))
    return Dict{String,Any}(
        "id" => id, "slug" => slug, "title" => String(p.title), "date" => r.happened, "day" => record_day(r.happened), "cite" => cite_json(kb, id),
        "people" => json_list(p.authors), "label" => r.label, "source" => r.source, "url" => r.url, "access" => p.access,
        "note" => record_note(kb, id), "updated" => r.updated_at,
        "projects" => [Dict("key" => k, "name" => get(titles, k, k)) for k in document_projects(kb, id)],
        "summary" => summary, "topics" => topics, "read" => !ismissing(scalar(kb, "SELECT 1 FROM parses WHERE paper_id = ?", (p.id,))),
        "sections" => sections,
        "figures" => [Dict("name" => n, "caption" => f["caption"], "src" => src(f), "placed" => n in placed)
                      for (n, f) in ((String(f["name"]), f) for f in doc["figures"])],
        "transcript" => [Dict("speaker" => t["speaker"], "start" => t["start"], "end" => t["end"], "text" => t["text"])
                         for t in doc["transcript"]])
end

"""
The addresses of a record's page, its script (a copy of its kind's template's, see
[`stamp_templates!`](@ref)) and its data on the site, each with the record's slug (its id, which
[`page_slug`](@ref) leaves as it is).
"""
const RECORD_ADDRESSES = [
    r"^generated/kb/records/(?<slug>rec-[a-z0-9-]+)(?:\.html)?$" => :page,
    r"^assets/generated_kb_records_(?<slug>rec-[a-z0-9-]+)\.md(?<tail>\..+\.js)$" => :page_script,
    r"^kb-data/records/(?<slug>rec-[a-z0-9-]+)\.json$" => :page_data]

"""
    record_site_response(kb, caller, path; req = nothing) -> Union{HTTP.Response,Nothing}

The answer to a request for the site's `path` when it names a record's page, script or data (see
`RECORD_ADDRESSES`): to a caller who may see the record (see [`document_visible`](@ref)), what a
built page would have there, its page a copy of the records' built template and its data from the
knowledge base; for a record not here, or to anyone else, the site's 404 page. `nothing` for any
other path, and for a page whose template the site served lacks.
"""
function record_site_response(kb::KB, caller::Caller, path::AbstractString; req::Union{HTTP.Request,Nothing} = nothing)
    rel = lstrip(path, '/')
    i = findfirst(((re, _),) -> occursin(re, rel), RECORD_ADDRESSES)
    i === nothing && return nothing
    re, what = RECORD_ADDRESSES[i]
    m = match(re, rel)
    rows = query(kb, "SELECT * FROM papers WHERE doc_id = ? AND $(kind_in(RECORD))", (m[:slug],))
    (isempty(rows) || !document_visible(kb, caller, first(rows).doc_id)) && return not_found_page(kb.config)
    p = first(rows)
    if what == :page_data
        r = json_response(record_page_json(kb, p))
        HTTP.setheader(r, "Cache-Control" => "no-store")
        return r
    end
    root = current_site(kb.config)
    root === nothing && return nothing
    template = Dict(TEMPLATED)["records"].template
    if what == :page
        f = joinpath(root, template * ".html")
        return isfile(f) ? file_response(f; req) : nothing
    end
    scripts = template_scripts(root, template)
    j = findfirst(((tail, _),) -> copy_tail(tail) == m[:tail], scripts)
    j === nothing && return nothing
    return HTTP.Response(200, ["Content-Type" => CONTENT_TYPES[".js"], "Cache-Control" => "no-cache"],
                         own_script(last(scripts[j]), template, "generated/kb/records/$(p.doc_id)"))
end

"""
    write_records_page(kb, dir; write) -> Bool

The page listing the records (`records.md` under `dir`), which the reader's are drawn into as it is
read (KBRecords.vue); it says when there are none at all. Returns whether there are any, for the
site's sidebar to link to it.
"""
function write_records_page(kb::KB, dir::AbstractString; write = write_if_changed)
    any = !ismissing(scalar(kb, "SELECT 1 FROM papers WHERE $(kind_in(RECORD)) LIMIT 1"))
    write(joinpath(dir, "records.md"), """
        # Records

        ```@raw html
        <KBRecords$(any ? "" : " none") />
        ```
        """)
    return any
end

# The records the caller may see, newest first: `?project=KEY` for a project's, `?source=…` for one
# source's.
route!("GET", "/api/records") do c
    Any[merge(Dict(pairs(r)), Dict(:slug => page_slug(r.id), :page => document_page(r.id), :day => record_day(r.date)))
        for r in visible_records(c.kb, c.caller; project = get(c.params, "project", ""), source = get(c.params, "source", ""))]
end

# Link a document of a kind with access to a project, or undo it: `{"project": KEY, "remove": true}`.
route!("POST", "/api/documents/:id/projects"; need = "paper.manage") do c
    b, id = json_body(c), c[:id]
    is_kind(k -> k.access, id) || error("Only a document whose access is set is linked to projects")
    key = String(get(b, "project", ""))
    get(b, "remove", false) === true ? unlink_document!(c.kb, id, key) : link_document!(c.kb, id, key)
    Dict("id" => id, "projects" => document_projects(c.kb, id))
end
