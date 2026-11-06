# The knowledge base as pages of the docs site: one page per paper, index pages by topic and by
# date posted, and a JSON file of every paper for searching in the browser when no search service is
# running. The docs build (`docs/make.jl`) calls `write_site`.

"""
    page_slug(id) -> String

A page name for a paper or topic: the id with dots and slashes as dashes (`2401.12345` →
`2401-12345`, `cond-mat/9703229` → `cond-mat-9703229`, `q-bio.PE` → `q-bio-PE`). A
dot would read as a file extension, and a static server asked for the clean URL `…/2401.12345`
would not look for `2401.12345.html`.
"""
page_slug(id::AbstractString) = replace(id, r"[./]" => "-")

"Where the site is served, for links to its pages: the shared service's address, else this process's own; empty when it serves none."
function site_base(c::Config)
    at = filter(!isempty, [c.shared.base_url, DEV_URL[], SERVED_AT[]])
    return isempty(at) ? "" : String(rstrip(first(at), '/'))
end

"""
    site_link(c, path) -> String

The address of the site's page `path` for an agent to hand people (`findings#KB-F3`,
`generated/kb/papers/2401-00001`, a directory's page ending in `/`), on [`site_base`](@ref); empty
where the site is not served. With `.html`, as the site links its own pages (see `pageLink` in
kbLinks.ts).
"""
function site_link(c::Config, path::AbstractString)
    base = site_base(c)
    isempty(base) && return ""
    i = findfirst('#', path)
    page, fragment = i === nothing ? (path, "") : (path[1:prevind(path, i)], path[i:end])
    page = lstrip(page, '/')
    return string(base, "/", page, isempty(page) || endswith(page, "/") ? "" : ".html", fragment)
end

"The address of document `id`'s page (see [`site_link`](@ref))."
document_link(c::Config, id::AbstractString) = site_link(c, "generated/kb/" * document_page(id))
"The address of task or finding `ref`'s place on the site: the board, or the findings page."
ref_link(c::Config, ref::AbstractString) = (r = uppercase(strip(ref)); site_link(c, (is_finding_ref(r) ? "findings#" : "projects#") * r))

"What the site's pages know of the group: its name and field, and the tutoring profile's questions."
group_json(c::Config) = Dict("name" => site_title(c), "field" => c.group.field,
                             "questions" => [Dict("id" => q.id, "text" => q.text, "options" => q.options, "many" => q.many)
                                             for q in profile_questions(c.group)])

"The site's title: the group's name, else the package's."
site_title(c::Config) = isempty(c.group.name) ? "Zemi" : c.group.name

"""
    hero_image(config) -> String

The front page's image, as the YAML of its `image:` entry: one for each of the site's themes, or the
logo alone (see [`hero_files`](@ref)).
"""
function hero_image(c::Config)
    heroes = hero_files(c)
    length(heroes) == 1 && return "    src: /$(first(only(heroes)))\n    alt: \"\""
    return "    light: /$(first(heroes[1]))\n    dark: /$(first(heroes[2]))\n    alt: $(yaml_string(site_title(c)))"
end

"The front page's panels, as its `features:` YAML (none: no entry)."
function panels_yaml(panels)
    isempty(panels) && return ""
    items = ["  - title: $(yaml_string(p.title))\n    details: $(yaml_string(p.text))" *
             (isempty(p.link) ? "" : "\n    link: $(yaml_string(p.link))") for p in panels]
    return "features:\n" * join(items, "\n")
end

"""
    front_page(config) -> String

The site's front page for a knowledge base whose content has none of its own (`pages/index.md`, see
[`content_path`](@ref)): the group's name, its field and what it works on, and the ways in.
"""
function front_page(c::Config)
    g = c.group
    text = isempty(g.field) ? "A research group's knowledge base" : "Research in $(g.field)"
    tagline = isempty(g.description) ?
        "The papers the group reads, read in full and searchable by meaning, with what it has found and the work it has planned." :
        g.description
    """
    ```@raw html
    ---
    layout: home

    hero:
      name: $(yaml_string(site_title(c)))
      text: $(yaml_string(text))
      tagline: $(yaml_string(tagline))
      actions:
        - theme: brand
          text: Search the knowledge base
          link: /generated/kb/
        - theme: alt
          text: Findings
          link: /findings
        - theme: alt
          text: Projects
          link: /projects
      image:
    $(hero_image(c))

    $(panels_yaml(g.panels))
    ---

    <KBSetup prompt />
    ```
    """
end

"""
    SitePaper

What the site shows for one paper, gathered from the knowledge base.
"""
Base.@kwdef struct SitePaper
    doc_id::String
    title::String
    authors::Vector{String}
    published::String
    category::String
    abstract::String
    journal_ref::Union{String,Nothing}
    doi::Union{String,Nothing}
    posts::Vector{Any}
    summary::String
    topics::Vector{String}
    sections::Vector{Any}
    related::Vector{Any}
    processed::Bool
    classification::Union{Dict,Nothing} = nothing
    version::String = ""
    blocks::Dict{Int,Vector{Symbol}} = Dict{Int,Vector{Symbol}}()   # each section's kinds of block, in order (its text is sent on demand)
    references::Vector{Reference} = Reference[]
    daily::String = ""      # the latest day it was the paper of the day, if it was
    figures::Int = 0        # how many figures and tables were cut from it (see `cut_paper_figures!`)
    tables::Int = 0
end

"Split an LLM paper summary into its paragraph and its `Topics:` list."
function split_topics(text::AbstractString)
    m = match(r"\n\s*Topics:\s*(.+)\s*$"s, text)
    m === nothing && return (String(strip(text)), String[])
    return (String(strip(text[1:m.offset-1])), String.(strip.(split(m[1], ','))))
end

"""
    related_papers(kb, doc_id; layer = first paper layer, limit = 6, except = ()) -> Vector{NamedTuple}

The papers nearest this one by its stored paper-level vector, but those in `except`, without
embedding anything. Empty when the paper has no vector in that layer.
"""
function related_papers(kb::KB, doc_id::AbstractString; layer = nothing, limit::Integer = 6, except = ())
    ls = [l for l in kb.config.layers if l.unit == :paper && isempty(l.source)]
    isempty(ls) && return []
    l = layer === nothing ? first(ls) : Zemi.layer(kb.config, layer)
    coll = collection_name(kb.config, l)
    # A document not yet embedded in this layer has no vector to look up; asking Qdrant would log a 404.
    ismissing(scalar(kb, "SELECT 1 FROM embeddings WHERE layer = ? AND unit_key = ?", (l.name, "p:$doc_id"))) && return []
    hits = try
        Qdrant.collection_exists(coll) || return []
        v = get(Qdrant.get_point(coll, point_id(l.name, "p:$doc_id")), "vector", nothing)
        v isa AbstractVector || return []
        vector_search(coll, Float64.(v); limit = limit + 1 + length(except))
    catch e
        # A site build without Qdrant still builds, without related papers.
        @warn "No related papers for $doc_id" exception = e maxlog = 1
        return []
    end
    out = []
    for h in hits
        id = split(h.key, ':')[2]
        (id == doc_id || id in except) && continue
        r = query(kb, "SELECT title FROM papers WHERE doc_id = ?", (id,))
        isempty(r) && continue
        push!(out, (; doc_id = String(id), title = coalesce(first(r).title, id), score = h.score))
    end
    return first(out, limit)
end

"""
    SiteData

What the pages of a set of papers show, read for all of them at once (see [`site_data`](@ref)): a
few queries in all, rather than several for each paper.
"""
struct SiteData
    rows::Dict{String,Any}                       # arxiv id => its row in papers
    summaries::Dict{Int,Vector{Any}}             # paper id => its summaries
    sections::Dict{Int,Vector{Any}}              # paper id => its sections, in order
    parsed::Set{Int}
    classifications::Dict{Int,Dict}
    mentions::Dict{Int,Vector{Any}}
    blocks::Dict{Int,Dict{Int,Vector{Symbol}}}   # paper id => section => its kinds of block
    daily::Dict{String,String}                   # arxiv id => the latest day it was the paper of the day
    figures::Dict{Int,Dict{String,Int}}          # paper id => how many figures and tables were cut from it
    related::Dict{String,Vector{Any}}            # arxiv id => the papers nearest it (see `cached_related`)
end

"""
    site_data(kb, ids; related = true) -> SiteData

Read what the pages of papers `ids` show, for all of them at once; with `related`, their related
papers from the table that keeps them (see [`cached_related`](@ref)).
"""
function site_data(kb::KB, ids::AbstractVector; related::Bool = true)
    ids = String[String(id) for id in ids if !ismissing(id)]
    rows = Dict{String,Any}()
    for chunk in Iterators.partition(unique(ids), 500)
        foreach(r -> rows[String(r.doc_id)] = r, query(kb, "SELECT * FROM papers WHERE doc_id IN ($(in_marks(length(chunk))))", Tuple(chunk)))
    end
    pids = [Int(r.id) for r in values(rows)]
    within = isempty(pids) ? "paper_id IN (NULL)" : "paper_id IN ($(join(pids, ',')))"
    grouped(sql) = (out = Dict{Int,Vector{Any}}(); foreach(r -> push!(get!(Vector{Any}, out, Int(r.paper_id)), r), query(kb, sql)); out)
    summaries = grouped("SELECT paper_id, unit_key, summarizer, text, created_at FROM summaries WHERE $within")
    sections = grouped("SELECT paper_id, ord, title, level, page_start, page_end FROM sections WHERE $within ORDER BY paper_id, $(section_order())")
    parsed = Set(Int(r.paper_id) for r in query(kb, "SELECT paper_id FROM parses WHERE $within"))
    classifications = Dict(Int(r.paper_id) => JSON.parse(r.data) for r in query(kb, "SELECT paper_id, data FROM classifications WHERE $within"))
    mentions = grouped("SELECT paper_id, source, channel, posted_at, author, url, message FROM mentions WHERE $within ORDER BY posted_at")
    blocks = Dict{Int,Dict{Int,Vector{Symbol}}}()
    for r in query(kb, "SELECT paper_id, section, kind FROM blocks WHERE $within AND kind != 'heading' ORDER BY paper_id, ord")
        push!(get!(Vector{Symbol}, get!(Dict{Int,Vector{Symbol}}, blocks, Int(r.paper_id)), Int(r.section)), Symbol(r.kind))
    end
    daily = Dict(String(r.doc_id) => String(r.day) for r in query(kb, "SELECT doc_id, max(day) AS day FROM daily WHERE status = 'done' GROUP BY doc_id"))
    figures = Dict{Int,Dict{String,Int}}()
    for r in query(kb, "SELECT paper_id, kind, count(*) AS n FROM figures WHERE $within GROUP BY paper_id, kind")
        get!(Dict{String,Int}, figures, Int(r.paper_id))[String(r.kind)] = Int(r.n)
    end
    near = related ? cached_related(kb, [id for id in keys(rows) if Int(rows[id].id) in parsed]) : Dict{String,Vector{Any}}()
    return SiteData(rows, summaries, sections, parsed, classifications, mentions, blocks, daily, figures, near)
end

"""
    site_paper(kb, doc_id; summarizer = nothing, related = true, references = nothing, data = nothing) -> SitePaper

What a paper's page shows, from `data` (see [`site_data`](@ref)), read for this paper alone when none
is given. Its references are matched against the knowledge base through `references`, a
[`ReferenceIndex`](@ref) (one is built when none is given). The summaries shown are `summarizer`'s,
else those of [`shown_summarizer`](@ref).
"""
function site_paper(kb::KB, doc_id::AbstractString; summarizer = nothing, related::Bool = true,
                    references::Union{ReferenceIndex,Nothing} = nothing, data::Union{SiteData,Nothing} = nothing)
    d = something(data, site_data(kb, [doc_id]; related))
    haskey(d.rows, doc_id) || not_found("No paper $doc_id in the knowledge base")
    p = d.rows[doc_id]
    pid = Int(p.id)
    sums = get(d.summaries, pid, Any[])
    # The summarizer whose summaries are shown: the configured one where it wrote the paper's, else the latest to.
    want = kind_summarizer(kb.config, doc_id)
    wrote = sort([r for r in sums if startswith(r.unit_key, "p:")]; by = r -> r.created_at, rev = true)
    sname = something(summarizer, any(r -> r.summarizer == want, wrote) ? want : isempty(wrote) ? "" : String(first(wrote).summarizer))
    shown = [r for r in sums if r.summarizer == sname]
    paper_summary = [String(r.text) for r in shown if startswith(r.unit_key, "p:")]
    summary, topics = isempty(paper_summary) ? ("", String[]) : split_topics(first(paper_summary))
    section_summary = Dict(String(r.unit_key) => String(r.text) for r in shown if startswith(r.unit_key, "s:"))
    sections = [(; s.ord, s.title, s.level, s.page_start, s.page_end, summary = get(section_summary, "s:$doc_id:$(s.ord)", nothing))
                for s in get(d.sections, pid, Any[])]
    processed = pid in d.parsed
    posts = [(; r.source, r.channel, posted = unix2datetime(r.posted_at), r.author, r.url, r.message) for r in get(d.mentions, pid, Any[])]
    return SitePaper(; doc_id = String(doc_id), title = coalesce(p.title, doc_id), authors = json_list(p.authors),
        published = coalesce(p.published, ""), category = coalesce(p.primary_category, ""),
        abstract = coalesce(p.abstract, ""), journal_ref = coalesce(p.journal_ref, nothing), doi = coalesce(p.doi, nothing),
        posts, summary, topics, sections,
        related = related && processed ? get(d.related, doc_id, []) : [], processed,
        classification = get(d.classifications, pid, nothing), version = coalesce(p.version, ""),
        blocks = get(d.blocks, pid, Dict{Int,Vector{Symbol}}()),
        references = processed ? paper_references(kb, doc_id; index = references === nothing ? ReferenceIndex(kb) : references) : Reference[],
        daily = get(d.daily, doc_id, ""), figures = get(get(d.figures, pid, Dict()), "figure", 0),
        tables = get(get(d.figures, pid, Dict()), "table", 0))
end

"How long a paper's related papers are kept before they are looked for again: the library grows."
const RELATED_DAYS = 1

"""
    cached_related(kb, ids; limit = 6) -> Dict{String,Vector{Any}}

The related papers of each of `ids` (see [`related_papers`](@ref)), as `(; doc_id, title, score)`:
from the table that keeps them, looked for again (several at a time) for those not found in the last
[`RELATED_DAYS`](@ref) days. A paper's titles are read now, so a renamed paper shows its new one.
"""
function cached_related(kb::KB, ids::AbstractVector{<:AbstractString}; limit::Integer = 6)
    isempty(ids) && return Dict{String,Vector{Any}}()
    since = iso_ago(Day(RELATED_DAYS))
    kept = Dict(String(r.doc_id) => JSON.parse(r.related) for r in query(kb, """
        SELECT p.doc_id, c.related FROM related_papers c JOIN papers p ON p.id = c.paper_id WHERE c.at >= ?""", (since,)))
    stale = [id for id in ids if !haskey(kept, id)]
    found = asyncmap(id -> (id, related_papers(kb, id; limit)), stale; ntasks = 8)
    transaction(kb) do
        for (id, rs) in found
            pid = paper_id(kb, id)
            ismissing(pid) && continue
            kept[id] = [Dict("doc_id" => r.doc_id, "score" => r.score) for r in rs]
            execute!(kb, "INSERT OR REPLACE INTO related_papers VALUES (?, ?, ?)", (pid, JSON.json(kept[id]), now_iso()))
        end
    end
    # Only documents the site has: not one open only to its projects' members, which it is built without.
    titles = Dict(String(r.doc_id) => coalesce(r.title, r.doc_id)
                  for r in query(kb, "SELECT doc_id, title FROM papers WHERE $(open_sql())"))
    return Dict(id => Any[(; doc_id = String(r["doc_id"]), title = String(titles[r["doc_id"]]), score = Float64(r["score"]))
                          for r in get(kept, id, []) if haskey(titles, r["doc_id"])] for id in ids)
end

const RELEVANCE_BADGE = ("unrelated", "peripheral", "related", "central")

"""
    section_text_json(kb, id, section) -> Vector{Dict}

Section `section`'s text of paper `id`, for its page to show when it is opened (KBSectionText.vue):
its blocks in order, each `kind` (paragraph, equation, caption, reference…) and `text`.
"""
section_text_json(kb::KB, id::AbstractString, section::Integer) =
    [Dict("kind" => String(r.kind), "text" => String(r.text))
     for r in query(kb, "SELECT kind, text FROM blocks WHERE paper_id = ? AND section = ? AND kind != 'heading' ORDER BY ord",
                    (paper_id(kb, id), section))]

"The digest of the pages a build compiles from the knowledge base, in the site (see [`write_site`](@ref))."
const BUILT_PAGES_FILE = "built-pages.sha256"

"""
The mark in the name of each templated page's copy of its template's script, after the template's
hash (see `stamp_templates!`; kbTemplates.ts adds the same). A script is cached for good under its
name, so it changes whenever what a copy holds does, for browsers to fetch the new one.
"""
const TEMPLATE_COPY = "c1"

"""
Pages made from a template, by kind: the kind's folder of the site, where each of its pages is a
copy of the kind's built template, filled in the browser from the page's data file,
`kb-data/<kind>/<slug>.json` at the site's root; and the template's page, built once (see
docs/src/components/kbTemplates.ts, which docs/make.jl gives this table). The folder also holds a stub page
per page of the kind, the template's Markdown, which the documentation build resolves links against
and the development server builds; VitePress's build leaves them out (`srcExclude`).
"""
const TEMPLATED = ("papers" => (; folder = "generated/kb/papers", template = "generated/kb/templates/paper", component = "KBPaperPage"),
                   "topics" => (; folder = "generated/kb/topics", template = "generated/kb/templates/topic", component = "KBTopicPage"),
                   # A folder with `*` holds a folder of pages for each name in its place (a codebase's
                   # files); the page's slug is then `<name>/<page>`.
                   "code" => (; folder = "generated/kb/code/*/files", template = "generated/kb/templates/code-file", component = "KBCodeFilePage"),
                   # After `code`: an address is taken for the first kind it fits, and a codebase's
                   # files are beneath its page's folder.
                   "codebase" => (; folder = "generated/kb/code/*", template = "generated/kb/templates/codebase", component = "KBCodebasePage"),
                   "daily" => (; folder = "generated/kb/daily/*", template = "generated/kb/templates/day", component = "KBDayPage"),
                   "resources" => (; folder = "generated/kb/resources", template = "generated/kb/templates/resource", component = "KBResourcePage"),
                   # Served by the service alone (see site_records.jl): no page of it is built.
                   "records" => (; folder = "generated/kb/records", template = "generated/kb/templates/record", component = "KBRecordPage"))

"The Markdown of a templated kind's page: its component, which reads the page from its address."
template_markdown(kind::AbstractString) = "```@raw html\n<$(Dict(TEMPLATED)[kind].component) />\n```\n"

"""
    paper_json(sp; cited_by = [], notebooks = []) -> Dict

A paper's data file: everything its page shows (KBPaperPage.vue lays it out), with what needs the
knowledge base worked out here: badges, how it arrived, its sections with where their text and the
reference list go, and the papers it links to by slug. Texts are as stored (Markdown with `\$…\$`
mathematics); `cited_by` lists the papers that cite it as `(; doc_id, title)`, and `notebooks` its
notebooks.
"""
function paper_json(sp::SitePaper; cited_by = [], notebooks = [])
    c = something(sp.classification, Dict{String,Any}())
    r = get(c, "relevance", nothing)
    link(id, title) = Dict("id" => id, "slug" => page_slug(id), "title" => title, "page" => document_page(id))
    ours = [x for x in sp.references if x.cites !== nothing]
    listed = Ref(false)
    sections = map(sp.sections) do s
        blocks = get(sp.blocks, s.ord, Symbol[])
        d = Dict{String,Any}("ord" => s.ord, "level" => s.level, "title" => s.title, "summary" => something(s.summary, ""))
        if !listed[] && !isempty(sp.references) && any(==(:reference), blocks)
            listed[] = true                          # the reference list, as entries, once
            d["references"] = true
        elseif !isempty(blocks)
            # The text itself is sent by the service when it is opened (KBSectionText.vue).
            pages = s.page_start == s.page_end ? "p. $(s.page_start)" : "pp. $(s.page_start)–$(s.page_end)"
            d["text"] = occursin(REFERENCES, s.title) ? "$(length(blocks)) references" : "Full text, $pages"
            d["page"] = coalesce(s.page_start, nothing)      # the page its PDF button opens at
        end
        d
    end
    posts = map(sp.posts) do m
        d = Dict{String,Any}("source" => m.source, "author" => coalesce(m.author, nothing),
                             "where" => !ismissing(m.channel) ? "Posted in #" * m.channel :
                                                                uppercasefirst(get(ARRIVALS, m.source, m.source)),
                             "on" => Dates.format(m.posted, "d U yyyy"))
        # One the arXiv watch took in says how it was rated, the judge's sentence with it.
        if m.source == "watch" && !ismissing(m.message) && occursin(':', m.message)
            rating, reason = strip.(split(m.message, ':'; limit = 2))
            d["rating"], d["reason"] = rating, reason
        end
        # A paper of the day links to its day, dated as the day is.
        m.source == "daily" && !isempty(sp.daily) && (d["day"] = sp.daily; d["on"] = Dates.format(Date(sp.daily), "d U yyyy"))
        d
    end
    return Dict{String,Any}(
        "id" => sp.doc_id, "slug" => page_slug(sp.doc_id), "title" => sp.title, "local" => !is_arxiv_id(sp.doc_id),
        "version" => sp.version, "authors" => [Dict("name" => a, "key" => author_key(a)) for a in sp.authors],
        "category" => isempty(sp.category) ? nothing :
                      Dict("id" => sp.category, "title" => category_title(sp.category), "slug" => page_slug(sp.category)),
        "published" => sp.published, "venue" => something(get(c, "venue", nothing), sp.journal_ref, Some(nothing)),
        "document_type" => get(c, "document_type", nothing),
        "relevance" => r isa Integer && 0 <= r <= 3 ?
                       Dict("level" => r, "label" => RELEVANCE_BADGE[r+1], "note" => string(something(get(c, "relevance_note", nothing), ""))) : nothing,
        "one_line" => get(c, "one_line", nothing), "doi" => sp.doi, "daily" => sp.daily, "posts" => posts,
        "summary" => sp.summary, "topics" => sp.topics, "abstract" => sp.abstract, "processed" => sp.processed,
        "notebooks" => [Dict("title" => nb.title, "page" => notebook_page_name(nb), "summary" => first(nb.summary, 240),
                             "by" => nb.kind == "agent" ? "made by an agent" : !isempty(nb.added_by) ? "added by " * nb.added_by : "added")
                        for nb in notebooks],
        "figures" => sp.figures, "tables" => sp.tables, "sections" => sections,
        "references" => [Dict("label" => x.label, "text" => x.text, "doi" => x.doi, "arxiv" => x.arxiv,
                              "cites" => x.cites === nothing ? nothing : link(x.cites, x.cites_title)) for x in sp.references],
        "here" => [merge(link(x.cites, x.cites_title), Dict("label" => x.label)) for x in ours],
        "cited_by" => [link(x.doc_id, x.title) for x in cited_by],
        "classification" => sp.classification === nothing ? [] : [Dict("label" => l, "value" => v) for (l, v) in classification_rows(sp.classification)],
        "related" => [link(x.doc_id, x.title) for x in sp.related])
end

"""
    stamp_templates!(site) -> Int

In the built site `site`, make each templated page whose data file is there a copy of its kind's
built template: its HTML at the page's address, and the template's scripts under the page's name in
`assets/`, where VitePress's router looks for a page's script by the page's name, each naming the
page as its own (VitePress shows that page's address once it loads it). Copies whose data
file is gone are removed. Every page then is files, as a static host needs. Returns how many pages
were written.
"""
function stamp_templates!(site::AbstractString)
    n = 0
    assets = joinpath(site, "assets")
    same(file, bytes) = isfile(file) && read(file) == bytes
    for (kind, (; folder, template)) in TEMPLATED
        isfile(joinpath(site, template * ".html")) || continue
        html = read(joinpath(site, template * ".html"))
        scripts = template_scripts(site, template)
        own(bytes, page) = own_script(bytes, template, page)
        # Each page's slug, from its data file's path: `<page>`, or `<name>/<page>` in a folder with `*`.
        data = joinpath(site, "kb-data", kind)
        slugs = Set{String}(isdir(data) ? [relpath(joinpath(r, f[1:end-5]), data) for (r, _, fs) in walkdir(data) for f in fs if endswith(f, ".json")] :
                                          String[])
        nested = occursin('*', folder)
        # The folders of the kind's pages, each with the slug its pages' names are prefixed with.
        folders = if nested
            before, after = rstrip(first(split(folder, '*')), '/'), lstrip(last(split(folder, '*')), '/')
            named(d) = isempty(after) ? joinpath(before, d) : joinpath(before, d, after)
            names = isdir(joinpath(site, before)) ? readdir(joinpath(site, before)) : String[]
            union([named(d) => d * "/" for d in names if isdir(joinpath(site, named(d)))],
                  [named(dirname(s)) => dirname(s) * "/" for s in slugs])
        else
            [folder => ""]
        end
        for (dir, prefix) in folders
            mine = [s[ncodeunits(prefix)+1:end] for s in slugs if startswith(s, prefix) && !occursin('/', s[ncodeunits(prefix)+1:end])]
            names = replace(dir, "/" => "_") * "_"
            for page in mine
                files = [joinpath(site, dir, page * ".html") => html;
                         [joinpath(assets, names * page * ".md" * copy_tail(tail)) => own(bytes, joinpath(dir, page)) for (tail, bytes) in scripts]]
                all(((f, b),) -> same(f, b), files) && continue
                mkpath(joinpath(site, dir))
                foreach(((f, b),) -> same(f, b) || write_atomic(f, b), files)
                n += 1
            end
            # Copies whose data file is gone (a page built for itself, or one beneath a page, is not a copy).
            keep = Set(mine)
            for f in (isdir(joinpath(site, dir)) ? readdir(joinpath(site, dir)) : String[])
                page = endswith(f, ".html") ? f[1:end-5] : ""
                !isempty(page) && !(page in keep) && same(joinpath(site, dir, f), html) && rm(joinpath(site, dir, f))
            end
            for f in (isdir(assets) ? readdir(assets) : String[])
                m = startswith(f, names) ? match(nested ? r"^(.+)\.md(\..+\.js)$" : r"^([^_]+)\.md(\..+\.js)$", f[ncodeunits(names)+1:end]) : nothing
                if m !== nothing && !(m[1] in keep) && any(((t, b),) -> copy_tail(t) == m[2] && same(joinpath(assets, f), own(b, joinpath(dir, m[1]))), scripts)
                    rm(joinpath(assets, f))
                end
            end
        end
    end
    return n
end

"""
    template_scripts(site, template) -> Vector{Pair{String,Vector{UInt8}}}

The scripts of `template`'s page in the built site `site`, `assets/<key>.<hash>.js` and
`<key>.<hash>.lean.js` (its key its path with `_` for `/`), each as what its name has after the
key, and its bytes.
"""
function template_scripts(site::AbstractString, template::AbstractString)
    assets = joinpath(site, "assets")
    key = replace(template, "/" => "_") * ".md"
    isdir(assets) || return Pair{String,Vector{UInt8}}[]
    return [f[ncodeunits(key)+1:end] => read(joinpath(assets, f)) for f in readdir(assets) if startswith(f, key * ".") && endswith(f, ".js")]
end

"""
Template `template`'s script `bytes` as page `page`'s (its path, without `.md`). A page's script
names the page it is, and VitePress sets the address bar to that page's address once it loads it:
a copy names its own page, not the template.
"""
own_script(bytes, template::AbstractString, page::AbstractString) =
    Vector{UInt8}(replace(String(copy(bytes)), template * ".md" => page * ".md"))

"The end of a copy's script's name, from its template's: `.<hash>.js` as `.<hash>.c1.js` (see `TEMPLATE_COPY`)."
copy_tail(tail::AbstractString) = replace(tail, r"^(\.[^.]+)" => SubstitutionString("\\1.$TEMPLATE_COPY"))

"A document's classification as `label => text` rows: its type, categories, areas, methods… and relevance."
function classification_rows(c::AbstractDict)
    list(k) = (v = get(c, k, nothing); v isa AbstractVector ? String.(string.(v)) : v === nothing ? String[] : [string(v)])
    rows = Pair{String,String}[]
    kind = join(filter(!isempty, [list("document_type"); list("venue"); list("year")]), " · ")
    isempty(kind) || push!(rows, "Type" => kind)
    cats = [list("category"); list("secondary_categories")]
    isempty(cats) || push!(rows, "Categories" => join(("$(category_title(x)) ($x)" for x in unique(cats)), ", "))
    for (label, k) in (("Research areas", "research_areas"), ("Methods", "methods"), ("Applications", "applications"),
                       ("Keywords", "keywords"), ("Affiliations", "affiliations"))
        v = list(k)
        isempty(v) || push!(rows, label => join(v, " · "))
    end
    r = get(c, "relevance", nothing)
    if r isa Integer && 0 <= r <= 3
        push!(rows, "Relevance" => "$r of 3, $(RELEVANCE[r+1])" * (n = get(c, "relevance_note", nothing); n === nothing ? "" : ". " * string(n)))
    end
    return rows
end

"How a mention says a paper came: posted in a channel by someone, uploaded, added from the arXiv watch…, and when."
function arrival_text(m)
    who = ismissing(m.author) ? "" : " by " * m.author
    when = " " * Dates.format(m.posted, "yyyy-mm-dd")
    return !ismissing(m.channel) ? "posted in #$(m.channel)$who$when" : get(ARRIVALS, m.source, m.source) * who * when
end

"""
    site_papers(kb; related = true) -> Vector{SitePaper}

Every paper with metadata (every document of the literature, see [`DocumentKind`](@ref)), most
recently posted first. Codebases have pages of their own (see [`write_code_site`](@ref)).
"""
function site_papers(kb::KB; related::Bool = true)
    ids = [String(r.doc_id) for r in query(kb, """
        SELECT p.doc_id, (SELECT max(posted_at) FROM mentions m WHERE m.paper_id = p.id) AS posted
        FROM papers p WHERE p.metadata_at IS NOT NULL AND $(literature_sql(on = "p"))
        ORDER BY coalesce(posted, 0) DESC, p.published DESC""")]
    references = ReferenceIndex(kb)
    data = site_data(kb, ids; related)
    return [site_paper(kb, id; related, references, data) for id in ids]
end

"""
    paper_record(sp) -> Dict

A paper's entry in papers.json: what the lists of papers (KBPaperList.vue), the topics and the
search box without a service read; and `sort`, its place in the list: its latest arrival, then
when it was published, as [`site_papers`](@ref) orders them.
"""
function paper_record(sp::SitePaper)
    latest = isempty(sp.posts) ? 0 : round(Int, datetime2unix(maximum(m.posted for m in sp.posts)))
    return Dict{String,Any}("id" => sp.doc_id, "slug" => page_slug(sp.doc_id), "title" => sp.title,
        "authors" => first(sp.authors, 6), "published" => sp.published, "category" => sp.category,
        "summary" => isempty(sp.summary) ? first(sp.abstract, 600) : sp.summary, "topics" => sp.topics,
        "posted_by" => unique([m.author for m in sp.posts if !ismissing(m.author)]),
        "posted" => isempty(sp.posts) ? "" : Dates.format(last(sp.posts).posted, "yyyy-mm-dd"),
        # For the lists of papers: how and when it came, each time.
        "arrivals" => [Dict("text" => arrival_text(m), "month" => Dates.format(m.posted, "yyyy-mm")) for m in sp.posts],
        "authors_total" => length(sp.authors), "category_title" => isempty(sp.category) ? "" : category_title(sp.category),
        "processed" => sp.processed, "sort" => Any[latest, sp.published])
end

"The topics of the papers `records` (see [`paper_record`](@ref)), most papers first."
function site_categories(records)
    counts = Dict{String,Int}()
    for r in records
        isempty(r["category"]) || (counts[r["category"]] = get(counts, r["category"], 0) + 1)
    end
    return sort!(collect(keys(counts)); by = c -> (-counts[c], c))
end

"""
    write_site_lists!(kb, dir, public, records; write)

The site's lists, from the papers' `records` (see [`paper_record`](@ref)) and the knowledge base:
papers.json, each topic's data file and stub page, status.json, the documents' digest, the
authors and the arXiv watch.
"""
function write_site_lists!(kb::KB, dir::AbstractString, public::AbstractString, records; write = write_if_changed)
    for c in site_categories(records)
        slug = page_slug(c)
        write(joinpath(public, "kb-data", "topics", slug * ".json"), JSON.json(Dict("id" => c, "title" => category_title(c), "slug" => slug)))
        write(joinpath(dir, "topics", slug * ".md"), template_markdown("topics"))
    end
    write(joinpath(public, "papers.json"), JSON.json(records))
    write(joinpath(public, "status.json"), JSON.json(contents_json(kb, records)))
    write(joinpath(public, "group.json"), JSON.json(group_json(kb.config)))
    # The front page's image (see `hero_image`), and the content's images, at the site's root where
    # its pages name them (`/picture.webp`).
    own = content_path(kb.config, "assets")
    for (name, path) in [hero_files(kb.config); [f => joinpath(own, f) for f in (isdir(own) ? readdir(own) : String[])
                                                 if !startswith(f, ".") && isfile(joinpath(own, f))]]
        cp(path, joinpath(public, name); force = true)
    end
    # Which documents the pages were written from, so a publish pairs the site with them (see site_publish.jl).
    write(joinpath(public, DOCUMENTS_FILE), documents_digest(kb))
    write(joinpath(public, "authors.json"), JSON.json(authors_json(kb)))
    write(joinpath(public, "watch.json"), JSON.json(Dict("checked" => coalesce(scalar(kb, "SELECT value FROM kv WHERE key = 'watch_checked_at'"), nothing),
        "categories" => kb.config.watch_categories, "days" => kb.config.watch_days, "papers" => watch_json(kb), "taken" => watch_taken_json(kb))))
    return
end

"A paper's notebooks: each one's page, under the paper's, and the notebook to download, at the site's root under its path in the content."
function write_notebook_pages(write, c::Config, dir::AbstractString, public::AbstractString, id::AbstractString, title::AbstractString, nbs)
    for nb in nbs
        write(joinpath(dir, "papers", page_slug(id), notebook_page_name(nb) * ".md"), notebook_page(nb, id, title))
        write(joinpath(public, nb.path), read(content_path(c, nb.path), String))
    end
end

"""
    built_pages_digest(dir) -> String

A digest of the pages the build compiles from the knowledge base, those under `dir` that are not the
stubs of templated pages (see `TEMPLATED`): a refresh that changes it needs a build (see `refresh_site!`).
"""
function built_pages_digest(dir::AbstractString)
    stubs = Set(template_markdown(k) for (k, _) in TEMPLATED)
    pages = isdir(dir) ? sort!([joinpath(r, f) for (r, _, fs) in walkdir(dir) for f in fs if endswith(f, ".md")]) : String[]
    texts = ((relpath(f, dir), read(f, String)) for f in pages)
    return bytes2hex(sha256(join((p * "\n" * t for (p, t) in texts if !(t in stubs)), "\0")))
end

"""
    write_site_changes!(kb, dir, public, ids) -> Union{Int,Nothing}

What [`write_site`](@ref) writes, for the documents `ids` changed and the site written from the
knowledge base before them: each changed paper's data file, stub and notebooks' pages, those of the
papers whose pages name it (those it cites, and those citing it), and the lists (see
[`write_site_lists!`](@ref)), papers.json patched rather than gathered; a paper gone has its files
removed. A document of a kind the site is built without (a record) changes only the page listing
them. Returns how many papers were written, or `nothing` when it cannot stand in for the whole:
another document than a paper changed (a codebase: the list of them is built), or the site has no
papers.json of this kind.
"""
function write_site_changes!(kb::KB, dir::AbstractString, public::AbstractString, ids)
    unbuilt = filter(id -> is_kind(k -> !k.site, id), collect(ids))
    if !isempty(unbuilt)
        write_records_page(kb, dir)
        ids = setdiff(ids, unbuilt)
        isempty(ids) && (write_if_changed(joinpath(public, BUILT_PAGES_FILE), built_pages_digest(dir)); return 0)
    end
    all(is_literature, ids) || return nothing
    listed = joinpath(public, "papers.json")
    isfile(listed) || return nothing
    old = JSON.parsefile(listed)
    all(r -> haskey(r, "sort"), old) || return nothing
    write = write_if_changed
    papers = Set(String(r.doc_id) for r in query(kb, "SELECT doc_id FROM papers WHERE metadata_at IS NOT NULL AND $(literature_sql())"))
    here, gone = filter(in(papers), collect(ids)), filter(!in(papers), collect(ids))
    index = ReferenceIndex(kb)
    # The changed papers, and those whose pages name them: those citing them, and those they cite.
    citing = Dict(id => citing_papers(kb, id; index) for id in here)
    touched = union(Set(here), (c.doc_id for cs in values(citing) for c in cs))
    data = site_data(kb, collect(touched))
    sps = Dict(id => site_paper(kb, id; references = index, data) for id in touched)
    for sp in collect(values(sps)), r in sp.references
        r.cites === nothing || haskey(sps, r.cites) || !(r.cites in papers) || (sps[r.cites] = site_paper(kb, r.cites; references = index))
    end
    template = template_markdown("papers")
    for (id, sp) in sps
        slug = page_slug(id)
        cited_by = [(; c.doc_id, c.title) for c in get(() -> citing_papers(kb, id; index), citing, id)]
        nbs = paper_notebooks(kb, id)
        write(joinpath(public, "kb-data", "papers", slug * ".json"), JSON.json(paper_json(sp; cited_by, notebooks = nbs)))
        write(joinpath(dir, "papers", slug * ".md"), template)
        write_notebook_pages(write, kb.config, dir, public, id, sp.title, nbs)
    end
    for id in gone
        slug = page_slug(id)
        rm(joinpath(public, "kb-data", "papers", slug * ".json"); force = true)
        rm(joinpath(dir, "papers", slug * ".md"); force = true)
        rm(joinpath(dir, "papers", slug); recursive = true, force = true)
    end
    records = [r for r in old if !haskey(sps, r["id"]) && !(r["id"] in gone)]
    append!(records, paper_record(sp) for sp in values(sps))
    sort!(records; by = r -> (r["sort"][1], r["sort"][2]), rev = true)
    write_site_lists!(kb, dir, public, records; write)
    # A topic no paper has now is let go.
    topics = Set(page_slug(c) for c in site_categories(records))
    for folder in (joinpath(public, "kb-data", "topics"), joinpath(dir, "topics")), f in (isdir(folder) ? readdir(folder) : String[])
        splitext(f)[1] in topics || rm(joinpath(folder, f))
    end
    write(joinpath(public, BUILT_PAGES_FILE), built_pages_digest(dir))
    return length(sps)
end

"""
    write_site(kb, dir, public; related = true, write = write_if_changed) -> NamedTuple

Write the knowledge base's pages under `dir` (a folder of the docs source), and their data under
`public` (copied to the site's root). The pages are mostly shells whose components draw the data, so
the site shows the knowledge base's changes without a build:
- a page per paper, topic, codebase, codebase file and day, each a stub of its kind's template (see
  `TEMPLATED`), its data in `public/kb-data/<kind>/`, the day's picked figures in
  `public/kb-data/figures/`;
- `index.md`, `timeline.md` and `topics.md`, drawn from `papers.json`; `status.md`, from
  `status.json`; `authors.md`, `landscape.md`, `missing.md`, `watch.md` and `daily.md`, from
  their JSON (see [`landscape!`](@ref), [`cited_works`](@ref), [`watch!`](@ref),
  [`feature_daily!`](@ref)); and `manage.md`, the Documents page;
- the pages the build still compiles: the lists of codebases (see [`write_code_site`](@ref)) and of
  records (see [`write_records_page`](@ref)), and each notebook's, whose digest is `BUILT_PAGES_FILE`.

Files are only rewritten when their contents change. Returns the pages for the site's navigation,
paths relative to `dir`: `(; code, code_index, index, timeline, overview, status, manage, landscape,
missing, watch, daily, authors, topics, papers, records)`, where `code` pairs each open codebase's name with its
page, with `topics` as `title => path` pairs, `papers` the number of papers, and `records` the page
listing the records, `nothing` while there are none.
"""
function write_site(kb::KB, dir::AbstractString, public::AbstractString; related::Bool = true, write = write_if_changed)
    # Every file written is noted, so pages left from documents since removed can be deleted.
    written = Set{String}()
    save = write
    write = (file, text) -> (push!(written, abspath(file)); save(file, text))
    # How long each part takes, in the build's log (see `step_time` in docs/make.jl).
    t = Ref(time())
    step(what) = (@info "SiteStep: $what in $(round(time() - t[]; digits = 1)) s"; t[] = time())
    papers = site_papers(kb; related)
    step("gathered $(length(papers)) papers")
    # The figures the papers of the day's analyses discuss, with their copies for the other theme.
    shown = site_figures!(kb, joinpath(public, "kb-data", "figures"), written)
    cited_by = Dict{String,Vector{Any}}()
    for sp in papers, id in unique(r.cites for r in sp.references if r.cites !== nothing)
        push!(get!(Vector{Any}, cited_by, id), (; sp.doc_id, sp.title))
    end
    notebooks = Dict(sp.doc_id => nbs for sp in papers for nbs in (paper_notebooks(kb, sp.doc_id),) if !isempty(nbs))
    # Each paper's data file and stub page (see `TEMPLATED`), and the papers' template.
    template = template_markdown("papers")
    write(joinpath(dir, "templates", "paper.md"), template)
    for sp in papers
        slug = page_slug(sp.doc_id)
        write(joinpath(public, "kb-data", "papers", slug * ".json"),
              JSON.json(paper_json(sp; cited_by = get(cited_by, sp.doc_id, []), notebooks = get(notebooks, sp.doc_id, []))))
        write(joinpath(dir, "papers", slug * ".md"), template)
    end
    titles = Dict(sp.doc_id => sp.title for sp in papers)
    foreach(((id, nbs),) -> write_notebook_pages(write, kb.config, dir, public, id, titles[id], nbs), notebooks)
    step("wrote the papers' pages")
    # The lists of papers (by topic, by month, the latest) are drawn from papers.json, so a paper
    # added shows in them without a build; each topic's page is made from a template, as a paper's is.
    write(joinpath(dir, "templates", "topic.md"), template_markdown("topics"))
    write(joinpath(dir, "templates", "code-file.md"), template_markdown("code"))
    write(joinpath(dir, "templates", "codebase.md"), template_markdown("codebase"))
    write(joinpath(dir, "templates", "record.md"), template_markdown("records"))
    # Each resource's data file and stub, and the page listing them, once there are any.
    write(joinpath(dir, "templates", "resource.md"), template_markdown("resources"))
    resources = resources_json(kb)
    for r in resources
        write(joinpath(public, "kb-data", "resources", r["slug"] * ".json"), JSON.json(resource_json(kb, r["id"])))
        write(joinpath(dir, "resources", r["slug"] * ".md"), template_markdown("resources"))
    end
    # One read in full since: its address leads to the paper it became.
    for m in moved_resources(kb)
        write(joinpath(public, "kb-data", "resources", m.slug * ".json"), JSON.json(Dict("moved" => m.page)))
        write(joinpath(dir, "resources", m.slug * ".md"), template_markdown("resources"))
    end
    write(joinpath(public, "resources.json"), JSON.json(resources))
    isempty(resources) || write(joinpath(dir, "resources.md"), """
        # Resources

        ```@raw html
        <KBResources />
        ```
        """)
    topics = [category_title(c) => "topics/$(page_slug(c)).md" for c in site_categories([paper_record(sp) for sp in papers])]
    write(joinpath(dir, "topics.md"), """
        # Topics

        ```@raw html
        <KBTopics />
        ```
        """)
    write(joinpath(dir, "timeline.md"), """
        # Timeline

        ```@raw html
        <KBPaperList by="month" />
        ```
        """)
    write(joinpath(dir, "index.md"), """
        # Knowledge base

        ```@raw html
        <KBSearch />
        ```

        ```@raw html
        <p class="kb-bib"><KBBibliography /></p>
        ```

        ## Recently posted

        ```@raw html
        <KBPaperList :recent="15" />
        ```
        """)
    write(joinpath(dir, "status.md"), status_markdown())
    write(joinpath(dir, "manage.md"), documents_markdown())

    write_site_lists!(kb, dir, public, [paper_record(sp) for sp in papers]; write)
    write(joinpath(dir, "authors.md"), """
        # Authors

        ```@raw html
        <KBAuthors />
        ```
        """)
    write(joinpath(dir, "landscape.md"), """
        # Landscape

        ```@raw html
        <KBLandscape />
        ```
        """)
    CITED_WORKS[] = cited_works(sp.doc_id => sp.references for sp in papers)    # (the API serves them too)
    write(joinpath(public, "missing.json"), JSON.json(works_json(kb, on_arxiv(kb, CITED_WORKS[]))))
    write(joinpath(dir, "missing.md"), """
        # Missing papers

        ```@raw html
        <KBMissing />
        ```
        """)
    step("wrote the topics, timeline, search data, authors and status")
    days = dailies(kb)
    for d in days, f in d.figures
        haskey(f, "file") || continue
        info = get(get(shown, d.id, Dict()), f["file"], nothing)
        info === nothing ? (f["missing"] = true) : merge!(f, info)
    end
    write(joinpath(dir, "templates", "day.md"), template_markdown("daily"))
    day_pages = daily_pages(kb, days)
    foreach(((path, text),) -> write(joinpath(dir, path), text), day_pages.pages)
    foreach(((slug, d),) -> write(joinpath(public, "kb-data", "daily", slug * ".json"), JSON.json(d)), day_pages.data)
    write(joinpath(public, "daily.json"), JSON.json(daily_json(days)))
    write(joinpath(dir, "watch.md"), """
        # New on arXiv

        ```@raw html
        <KBWatch />
        ```
        """)
    # The landscape as last built, without the codebases the site is built without (one may have
    # been closed since).
    landscape, closed = read_landscape(kb.config), closed_documents(kb)
    landscape === nothing || filter!(p -> !(p["id"] in closed), landscape["papers"])
    landscape === nothing ? rm(joinpath(public, "landscape.json"); force = true) :
                            write(joinpath(public, "landscape.json"), JSON.json(landscape))
    step("wrote the papers of the day and the watch")
    code = write_code_site(kb, joinpath(dir, "code"), joinpath(public, "code"); write)
    records = write_records_page(kb, dir; write)
    step("wrote the codebases' pages")
    for folder in (joinpath(dir, "papers"), joinpath(dir, "topics"), joinpath(dir, "resources"), joinpath(dir, "code"), joinpath(public, "code"), joinpath(dir, "daily"),
                   joinpath(dir, "figures"), joinpath(public, "notebooks"), joinpath(public, "kb-data"),
                   joinpath(dir, "templates"))
        isdir(folder) || continue
        for (root, _, files) in walkdir(folder), f in files
            file = abspath(joinpath(root, f))
            file in written || rm(file)
        end
    end
    save(joinpath(public, BUILT_PAGES_FILE), built_pages_digest(dir))
    return (; code = [c.title => joinpath("code", c.page) for c in code], code_index = "code/index.md", index = "index.md", timeline = "timeline.md", overview = "topics.md", status = "status.md",
              manage = "manage.md", landscape = "landscape.md", missing = "missing.md", watch = "watch.md", daily = "daily.md", authors = "authors.md", topics,
              papers = length(papers), records = records ? "records.md" : nothing,
              resources = isempty(resources) ? nothing : "resources.md")
end

"What [`write_site`](@ref) returns, as JSON, for a build process to read back (see [`site_from_json`](@ref))."
site_json(site) = JSON.json(Dict(String(k) => (v isa AbstractVector{<:Pair} ? [[first(x), last(x)] for x in v] : v) for (k, v) in pairs(site)))

"What [`write_site`](@ref) returned, from [`site_json`](@ref)."
function site_from_json(text::AbstractString)
    d = JSON.parse(text)
    pairs_of(k) = [String(x[1]) => String(x[2]) for x in d[k]]
    return (; code = pairs_of("code"), code_index = d["code_index"], index = d["index"], timeline = d["timeline"],
              overview = d["overview"], status = d["status"], manage = d["manage"], landscape = d["landscape"],
              missing = d["missing"], watch = d["watch"], daily = d["daily"], authors = d["authors"],
              topics = pairs_of("topics"), papers = Int(d["papers"]), records = get(d, "records", nothing),
              resources = get(d, "resources", nothing))
end

"""
    site_figures!(kb, dir, written) -> Dict

Copy the figures the papers of the day's analyses picked into `dir/<paper>/`, each with its
copy recolored for the other theme (see [`theme_figures`](@ref)), noting each file in `written`.
Returns, by paper and file, what a day's page needs to show it (see [`day_json`](@ref)): `"width"`, and `"light"` and `"dark"`
for a figure shown in each theme.
"""
function site_figures!(kb::KB, dir::AbstractString, written::Set{String})
    shown = Dict{String,Dict{String,Dict{String,Any}}}()
    picks = [(id = String(r.doc_id), file = String(f["file"])) for r in query(kb, "SELECT doc_id, figures FROM daily WHERE figures IS NOT NULL")
             for f in JSON.parse(r.figures) if haskey(f, "file")]
    for (id, file) in unique(picks)
        from = joinpath(figures_dir(kb.config, id), file)
        isfile(from) || continue
        info = Dict{String,Any}("width" => image_size(from)[1] ÷ 2)
        themed = try_theme(from, "$file of $id")
        themed === nothing || (info["light"] = basename(themed.light); info["dark"] = basename(themed.dark))
        for src in (themed === nothing ? [from] : [themed.light, themed.dark])
            to = abspath(joinpath(dir, page_slug(id), basename(src)))
            push!(written, to)
            isfile(to) && filesize(to) == filesize(src) || (mkpath(dirname(to)); cp(src, to; force = true))
        end
        get!(Dict{String,Dict{String,Any}}, shown, id)[file] = info
    end
    return shown
end

"""
    documents_markdown() -> String

The page where documents are acted on (its address is still `manage.md`): adding them, finding each
and running its steps again (KBManager.vue), bringing all of them up to date, and the sources that
bring them in (KBSources.vue).
"""
documents_markdown() = """
    # Documents

    ## Add documents

    arXiv ids, PDFs and Git repositories.

    ```@raw html
    <KBUpload />
    ```

    ## Find and manage

    ```@raw html
    <KBManager />
    ```

    ## Sync

    ```@raw html
    <KBSync />
    ```

    ## Sources

    ```@raw html
    <KBSources />
    ```
    """

"""
    status_markdown() -> String

The site's status page: what the knowledge base holds, its tables drawn from status.json (see
[`contents_json`](@ref), KBStatusTables.vue), which a refresh rewrites. What is done to documents is
on the Documents page (see [`documents_markdown`](@ref)).
"""
status_markdown() = """
    # Status

    What the knowledge base holds. Documents are added, read again and removed on [Documents](./manage.md).

    ## Services

    ```@raw html
    <KBServices />
    ```

    ## Contents

    ```@raw html
    <KBStatusTables />
    ```
    """

"""
    contents_json(kb, records) -> Dict

What the knowledge base holds, for the status page: papers and how far they have been processed,
passages, each layer's vectors, the summaries and what they cost in tokens, and who shared the
papers when.
"""
function contents_json(kb::KB, records)
    n(sql) = Int(scalar(kb, sql))
    counts = Dict(r.layer => (; r.n, r.papers) for r in query(kb,
        "SELECT layer, count(*) AS n, count(DISTINCT paper_id) AS papers FROM embeddings GROUP BY layer"))
    years = Dict{String,Int}()
    for r in records
        isempty(r["arrivals"]) && continue
        y = first(first(r["arrivals"])["month"], 4)
        years[y] = get(years, y, 0) + 1
    end
    return Dict(
        "at" => Dates.format(now(), "d U yyyy, HH:MM"),
        "papers" => Dict("recorded" => length(records), "full" => count(r -> r["processed"], records),
                         "uploaded" => count(r -> !is_arxiv_id(r["id"]), records),
                         "sections" => n("SELECT count(*) FROM sections"), "passages" => n("SELECT count(*) FROM chunks")),
        "layers" => [(c = get(counts, l.name, (; n = 0, papers = 0));
                      Dict("name" => l.name, "embeds" => ranking_label(kb.config, l.name), "model" => l.model,
                           "papers" => c.papers, "vectors" => c.n)) for l in kb.config.layers],
        "summaries" => [Dict("summarizer" => r.summarizer, "model" => r.model, "papers" => r.papers, "summaries" => r.n,
                             "input" => coalesce(r.tin, 0), "output" => coalesce(r.tout, 0))
                        for r in query(kb, """SELECT summarizer, model, count(*) AS n, count(DISTINCT paper_id) AS papers,
                                              sum(input_tokens) AS tin, sum(output_tokens) AS tout FROM summaries GROUP BY summarizer""")],
        "shared_by" => [Dict("who" => r.who, "papers" => r.n)
                        for r in query(kb, """SELECT author AS who, count(DISTINCT paper_id) AS n FROM mentions
                                              WHERE author IS NOT NULL GROUP BY who ORDER BY n DESC""")],
        "years" => [Dict("year" => y, "papers" => years[y]) for y in sort!(collect(keys(years)))])
end

"Write `text` to `file` unless it already holds exactly that, so file watchers only see real changes."
function write_if_changed(file::AbstractString, text::AbstractString)
    mkpath(dirname(file))
    (isfile(file) && read(file, String) == text) || write_atomic(file, text)
    return file
end

"Write `data` to `file` in one step, through a file beside it, so one reading it while a served site is refreshed sees the old or the new."
function write_atomic(file::AbstractString, data)
    tmp = "$file.$(Random.randstring(8)).part"         # its own, should another write the same file
    Base.write(tmp, data)
    mv(tmp, file; force = true)
    return file
end
