# Tools served by the `zemi` Kaimon extension, for agents and for notebook `@tool` cells
# (`@tool zemi.search(query = …)`). Each is a thin wrapper over the package API that formats its
# result as text.

"Whether creating the tools starts a dataset publisher's autosync timer (tests turn it off)."
const AUTOSYNC = Ref(true)

"""
A tool the knowledge base serves: its name, the function answering it, the permission it needs over
`/mcp` (`nothing` for one never offered there, which reads paths on the service's own disk), and
how long it may go silent (see KaimonGate's `GateTool`).
"""
struct ZemiTool
    name::String
    f::Function
    need::Union{String,Nothing}
    timeout_ms::Union{Int,Nothing}
end

"The tools, in the order they are declared. Declaring one again (as Revise does) replaces it."
const TOOLS = Ref(ZemiTool[])
const TOOLS_LOCK = ReentrantLock()

"""
    tool!(name, f; need, timeout_ms = nothing)

Serve `f` as tool `name` (`zemi.<name>`), its schema and description taken from its signature and
docstring, and over `/mcp` to callers with permission `need`.
"""
function tool!(name::AbstractString, f::Function; need::Union{AbstractString,Nothing}, timeout_ms::Union{Integer,Nothing} = nothing)
    t = ZemiTool(name, f, need, timeout_ms)
    lock(TOOLS_LOCK) do
        i = findfirst(x -> x.name == name, TOOLS[])
        TOOLS[] = i === nothing ? [TOOLS[]; t] : [TOOLS[][1:i-1]; t; TOOLS[][i+1:end]]
    end
    return t
end

"The KaimonGate serving the tools, which passes on their progress."
const GATE = Ref{Union{Module,Nothing}}(nothing)

"Tell a tool's caller how its work is going, when a gate serves it."
tool_progress(msg) = (g = GATE[]; g !== nothing && isdefined(g, :progress) ? g.progress(msg) : nothing)

const AUTOSYNC_STARTED = Threads.Atomic{Bool}(false)

"""
    create_tools(GateTool) -> Vector

The knowledge base's tools (see [`tool!`](@ref)), built with the `GateTool` type of whichever
KaimonGate is serving them. Where Kaimon runs the process as Zemi's extension, the knowledge base
starts serving too (see [`host!`](@ref)); elsewhere a dataset publisher's timer is started, once in
a process (see [`start_autosync!`](@ref)), unless `AUTOSYNC[]` is false.
"""
function create_tools(GateTool::Type)
    GATE[] = parentmodule(GateTool)
    if hosted()
        host!()
    elseif AUTOSYNC[] && !Threads.atomic_xchg!(AUTOSYNC_STARTED, true)
        Threads.@spawn try
            start_autosync!(kb())
        catch e
            @warn "The dataset autosync did not start" exception = e
        end
    end
    return [GateTool(t.name, t.f; t.timeout_ms) for t in TOOLS[]]
end

"""
    search(query::String; limit::Int=8, category::String="", since::Int=0, keyword::Bool=true, layers::String="", project::String="",
           kind::String="") -> String

Search the knowledge base for papers relevant to `query`, a question or topic in plain
language. Combines keyword (BM25) search over passages with vector search in the configured search
layers, fused by reciprocal rank. Returns papers with their best-matching passages, each
tagged with the section and pages it came from, after the projects' findings that match: what
the group's work has concluded. Codebases and the group's records (notes of its meetings and
other work, each saying how it was made) are found too.

- `limit`: number of papers to return.
- `category`: primary arXiv category prefix, e.g. "q-bio.PE" or "math".
- `since`: earliest publication year (0 for no limit).
- `keyword`: include keyword search (false for meaning-only search).
- `layers`: comma-separated layer names to use, or "all" (default: the layers built on the
  strongest model; see `status`).
- `project`: a project's key, to search only the papers in its library, and its findings.
- `kind`: "paper", "code" or "record" for only those (a comma list for several).
"""
function search_tool(query::String; limit::Int = 8, category::String = "", since::Int = 0,
                     keyword::Bool = true, layers::String = "", project::String = "", kind::String = "")::String
    isempty(project) || tool_needs(project, VIEW)
    only = isempty(project) ? nothing : library_papers(kb(), project)
    only !== nothing && isempty(only) && return "$(uppercase(strip(project)))'s library has no papers yet: see `library`."
    caller = tool_caller()
    hits = search(kb(), query; limit, keyword, only, except = unfound_documents(kb(), caller),
        kinds = isempty(kind) ? nothing : split_list(kind),
        category = isempty(category) ? nothing : category,
        since = since == 0 ? nothing : since,
        layers = isempty(layers) ? kb().config.search_layers : layers == "all" ? nothing : split_list(layers))
    seen = isempty(project) ? visible_projects(kb(), caller) : (uppercase(strip(project)),)
    found = can(caller, "tasks.view") ? search_findings(kb(), query; projects = seen, limit = 5) : NamedTuple[]
    isempty(hits) && isempty(found) && return "No matches for \"$query\"."
    out = isempty(found) ? "" : "## Findings (read one with `finding`)\n\n" *
        join(("- $(f.ref) [$(f.status)] $(f.claim)" for f in found), "\n") * "\n\n## Papers\n\n"
    return out * (isempty(hits) ? "No papers match." : format_hits(hits))
end
tool!("search", search_tool; need = "read")

"""
    paper(doc_id::String) -> String

Everything known about one paper: metadata, abstract, how it arrived and from whom, its
section outline, and how far it has been processed (downloaded, parsed, embedded
in which layers).
"""
function paper_tool(doc_id::String)::String
    return format_paper(kb(), tool_document(doc_id))
end
tool!("paper", paper_tool; need = "read")

"""
    read(doc_id::String; section::String="", pages::String="", summaries::Bool=false, max_chars::Int=20000) -> String

Read a paper's parsed text. `section` selects a section and its subsections, by number
("2.1") or by words from its title ("realizability"); `pages` selects a page range ("3-5").
With neither, returns the whole paper up to `max_chars`. Equations appear as extracted from
the PDF (Unicode symbols, not LaTeX).

`summaries=true` returns the LLM-written summary of each selected section instead of its
text: a quick way to see what a paper covers, section by section, before reading any of it.
"""
function read_tool(doc_id::String; section::String = "", pages::String = "",
                   summaries::Bool = false, max_chars::Int = 20000)::String
    return read_paper(kb(), tool_document(doc_id); section, pages, summaries, max_chars)
end
tool!("read", read_tool; need = "read")

"""
    figures(doc_id::String) -> String

A paper's figures and tables, as cut from its PDF: each one's label, page and full caption, and
where the text mentions it (the section and the sentence). See one with `figure`.
"""
function figures_tool(doc_id::String)::String
    id = tool_document(doc_id)
    figs = paper_figures_cut(kb(), id)
    isempty(figs) && return figures_missing(kb(), id)
    said = figure_mentions_in(kb(), id)
    io = IOBuffer()
    println(io, "$(count(f -> f.kind == "figure", figs)) figure(s) and $(count(f -> f.kind == "table", figs)) table(s) cut from $id. ",
            "See one with `figure(\"$id\", \"$(first(figs).label)\")`.")
    for f in figs
        println(io, "\n## ", f.label, "\n\n", f.caption)
        for m in get(said, (f.kind, f.number), NamedTuple[])
            println(io, "- mentioned in ", isempty(m.section) ? "p. $(m.page)" : "$(m.section) (p. $(m.page))", ": ", m.sentence)
        end
    end
    return String(take!(io))
end
tool!("figures", figures_tool; need = "read")

"""
    figure(doc_id::String, which::String; theme::String="light") -> String

One or more of a paper's figures or tables as images, each with its caption. `which` is a comma
list: "3", "Fig. 3", "Figure 3b" or "Table II" (a bare number is a figure); at most four at
once. `theme` "dark" gives the versions drawn for a dark background.
"""
function figure_tool(doc_id::String, which::String; theme::String = "light")::String
    id = tool_document(doc_id)
    figs = paper_figures_cut(kb(), id)
    isempty(figs) && return figures_missing(kb(), id)
    picked = pick_figures(figs, which)
    length(picked) > 4 && error("At most four figures at once: ask for the rest in another call")
    images = NamedTuple[]
    for f in picked
        file = figure_file(kb(), page_slug(id), f.file; theme = theme == "dark" ? "dark" : "light")
        isempty(file) || push!(images, (; bytes = read(file), type = image_type(file)))
    end
    text = join(("$(f.label) of $id: $(f.caption)" for f in picked), "\n\n")
    return with_images(text, images)
end
tool!("figure", figure_tool; need = "read")

"""
    page(doc_id::String, page::Int) -> String

A page of a paper's PDF as an image: for equations, layouts, or a figure `figure` cut short.
"""
function page_tool(doc_id::String, page::Int)::String
    id = tool_document(doc_id)
    return with_images("Page $page of $id.", [(; bytes = page_image(kb(), id, page), type = "image/png")])
end
tool!("page", page_tool; need = "read")

"""
    references(doc_id::String) -> String

A paper's reference list, each marked with the paper of the knowledge base it is (when it is
one), and the knowledge base's papers that cite it.
"""
function references_tool(doc_id::String)::String
    id = tool_document(doc_id)
    index = ReferenceIndex(kb())
    refs = paper_references(kb(), id; index)
    citing = citing_papers(kb(), id; index)
    io = IOBuffer()
    inkb = count(r -> r.cites !== nothing, refs)
    println(io, isempty(refs) ? "No references read from $id." : "$(length(refs)) references in $id, $inkb of them in the knowledge base.")
    for r in refs
        println(io, "- ", isempty(r.label) ? "" : "[$(r.label)] ", replace(r.text, '\n' => ' '),
                r.cites === nothing ? "" : "  → in the knowledge base: [$(r.cites)] $(r.cites_title)")
    end
    println(io, isempty(citing) ? "\nNo paper in the knowledge base cites it." : "\nCited by $(length(citing)) paper(s) in the knowledge base:")
    for c in citing
        println(io, "- [", c.doc_id, "] ", c.title, isempty(c.label) ? "" : " (as [$(c.label)])")
    end
    return String(take!(io))
end
tool!("references", references_tool; need = "read")

"""
    similar(doc_id::String; limit::Int=8) -> String

Papers in the knowledge base closest to this one, by the embedding of title and abstract.
"""
function similar_tool(doc_id::String; limit::Int = 8)::String
    hits = similar_papers(kb(), tool_document(doc_id); limit, except = unfound_documents(kb(), tool_caller()))
    isempty(hits) && return "No similar papers found."
    return join(("$(i). [$(h.doc_id)] $(h.title)  (similarity $(round(h.score; digits = 3)))"
                 for (i, h) in enumerate(hits)), "\n")
end
tool!("similar", similar_tool; need = "read")

"""
    ingest(papers::String; wait::Bool=false) -> String

Add papers to the knowledge base and process them: arXiv metadata, PDF download, parsing,
chunking and embedding in every layer. `papers` is a comma- or space-separated list of arXiv
ids or URLs. Steps already done are skipped, so re-running is cheap. arXiv allows one request
every 3 seconds, so each new paper takes several seconds.

A codebase id (`code-…`) is read again from the service's copy of its repository (current
within 30 s), and only the files that changed are summarized and embedded. Linked codebases
are also ingested each night when their files changed, so this is needed only to have a push
read sooner.

By default runs as a background job and returns its id; poll it with `job_status`. With
`wait=true`, runs in the call and returns the result (use for a few papers only).
"""
function ingest_tool(papers::String; wait::Bool = false)::String
    ids = split_list(papers)
    isempty(ids) && return "⛔ No papers given."
    if wait
        results = ingest!(kb(), ids; progress = tool_progress)
        return format_ingest(results)
    end
    job = start_job("ingest $(length(ids)) paper(s)"; ids = normalize_id.(ids), changes = changes_stamp(kb().config)) do job
        ingest!(kb(), ids; progress = msg -> report!(job, msg), cancelled = () -> cancelled(job))
    end
    return "Started job $(job.id) to ingest $(length(ids)) paper(s). Poll `job_status(job_id=\"$(job.id)\")`."
end
tool!("ingest", ingest_tool; need = "paper.add", timeout_ms = 1_800_000)

"""
    add_pdf(path::String; title::String="", authors::String="", added_by::String="", ingest::Bool=true) -> String

Add a paper that is not on arXiv from a PDF file on this machine, and (unless `ingest=false`)
process it like any other: parse, summarize, embed. Returns its id (`doc-…`, from the file's
contents, so the same file is never added twice). `title` and the abstract default to what
the PDF shows; `authors` is comma-separated; `added_by` records who added it.
"""
function add_pdf_tool(path::String; title::String = "", authors::String = "", added_by::String = "",
                      ingest::Bool = true)::String
    k = kb()
    id = add_pdf!(k, expanduser(path); title = isempty(title) ? nothing : title,
        authors = String.(filter(!isempty, strip.(split(authors, ',')))),
        added_by = isempty(added_by) ? nothing : added_by)
    ingest || return "Added $id. Process it with `ingest(papers=\"$id\")`."
    return "Added $id.\n" * format_ingest(ingest!(k, [id]; progress = tool_progress))
end
tool!("add_pdf", add_pdf_tool; need = nothing, timeout_ms = 1_800_000)

"""
    ingest_code(path::String; name::String="", wait::Bool=false) -> String

Add a codebase from a directory on this machine and read it: each tracked source,
documentation and configuration file becomes a section, cut at its definitions, with an LLM
summary of every file and of the project, all embedded for search. Running it again after the
code changes redoes only the files that changed. `name` defaults to the directory's name.
Runs as a background job unless `wait=true`.
"""
function ingest_code_tool(path::String; name::String = "", wait::Bool = false)::String
    root = expanduser(path)
    id = add_codebase!(kb(), root; name = isempty(name) ? basename(rstrip(abspath(root), '/')) : name)
    wait && return format_ingest(ingest!(kb(), [id]; progress = tool_progress))
    job = start_job("ingest $id"; ids = [id], changes = changes_stamp(kb().config)) do job
        ingest!(kb(), [id]; progress = msg -> report!(job, msg), cancelled = () -> cancelled(job))
    end
    return "Reading $id as job $(job.id). Poll `job_status(job_id=\"$(job.id)\")`."
end
tool!("ingest_code", ingest_code_tool; need = nothing, timeout_ms = 1_800_000)

"""
    papers(; filter::String="", author::String="", state::String="", limit::Int=30) -> String

List papers in the knowledge base, and its codebases, most recently posted first (the group's
records are listed by `records`). `filter` matches words in the
title or authors; `author` keeps the papers by an author, matching the beginnings of the words of
their name in any form it is written ("lovelace", "A. Love"); `state` is "new" (recorded only),
"parsed" or "embedded".
"""
function papers_tool(; filter::String = "", author::String = "", state::String = "", limit::Int = 30)::String
    return format_paper_list(kb(), filter, state, limit; author, except = hidden_documents(kb(), tool_caller()))
end
tool!("papers", papers_tool; need = "read")

"""
    records(; project::String="", source::String="", limit::Int=30) -> String

The group's records you may see, newest first: notes of its meetings and other work, each with
its date, people, label (how it was made) and projects. `project` keeps a
project's, `source` those from one source. Read one with `read`, its summary with `paper`; weigh
what it says as what people said, not as established.
"""
function records_tool(; project::String = "", source::String = "", limit::Int = 30)::String
    isempty(project) || tool_needs(project, VIEW)
    rs = visible_records(kb(), tool_caller(); project, source)
    isempty(rs) && return "No records."
    io = IOBuffer()
    println(io, "$(length(rs)) record(s)", length(rs) > limit ? ", showing $limit" : "", ":")
    for r in first(rs, limit)
        println(io, "- [$(r.id)] $(r.title): $(record_day(r.date))", isempty(r.people) ? "" : ", with $(prose_list(r.people))",
                "; $(r.label); ", isempty(r.projects) ? "no project" : join(r.projects, ", "), r.read ? "" : " (not read yet)")
    end
    return String(take!(io))
end
tool!("records", records_tool; need = "read")

"""
    status() -> String

Knowledge base overview: how many papers are recorded, downloaded, parsed and embedded; each
embedding layer with its model, unit and vector count; whether Ollama and Qdrant are
reachable; and running jobs. To those who look after the service, also who is using it now
and whether a restart would interrupt them: check this before restarting it.
"""
function status_tool()::String
    s = format_status(kb())
    c = try tool_caller() catch; nothing end
    SHARED_MODE[] && c !== nothing && can(c, "server.view") || return s
    return s * "\n" * format_activity()
end
tool!("status", status_tool; need = "read")

"""
    daily(; day::String="") -> String

The paper of the day: the paper picked for the group on `day` (`YYYY-MM-DD`; the latest when
empty), new on arXiv or from the library, with why it was picked, its analysis, the figures it
singles out (their images too), and the notebooks made from it; then the other days with a
paper, to ask for one.
"""
daily_tool(; day::String = "")::String = with_images(format_daily(kb(), day), daily_figures(kb(), day))
tool!("daily", daily_tool; need = "read")

"""
    sync(; dry_run::Bool=false, unread::Bool=false, wait::Bool=false) -> String

Bring the knowledge base up to date: read documents whose reading is unfinished or stale (a
codebase whose files changed, a paper parsed by an older reader, missing or outdated summaries
or embeddings), fetch missing arXiv records, classify unclassified documents, and read again any
paper with a newer version on arXiv. `dry_run=true` lists what would be done, and why, without
doing it. `unread=true` also reads every paper only recorded (costly: each is downloaded,
summarized and embedded). Runs as a background job unless `wait=true`.
"""
function sync_tool(; dry_run::Bool = false, unread::Bool = false, wait::Bool = false)::String
    dry_run && return format_sync_plan(sync_plan(kb(); unread))
    wait && return format_sync(sync!(kb(); unread, progress = tool_progress))
    job = start_sync(kb(); unread)
    return "Syncing as job $(job.id) ($(job.name)). Poll `job_status(job_id=\"$(job.id)\")`."
end
tool!("sync", sync_tool; need = "sync", timeout_ms = 1_800_000)

"""
    publish(; wait::Bool=false) -> String

Publish this knowledge base's stream of the dataset, which the other members import instead of
reading the papers themselves: the arXiv papers, uploads and codebases marked shared that were read
here, with their text, summaries, classification and vectors. Uploads only what changed since the
last publication. Needs `[dataset] role = "publish"` in the config. Runs as a background job unless
`wait=true`.
"""
function publish_tool(; wait::Bool = false)::String
    db = kb()
    db.config.dataset.role == :publish ||
        return "⛔ This knowledge base is not a dataset publisher: set [dataset] role = \"publish\" in ~/.config/zemi/config.toml."
    wait && return format_publish(publish!(db; progress = tool_progress))
    job = start_publish(db)
    return "Publishing as job $(job.id). Poll `job_status(job_id=\"$(job.id)\")`."
end
tool!("publish", publish_tool; need = "sync", timeout_ms = 1_800_000)

"""
    job_status(; job_id::String="", cancel::Bool=false) -> String

Progress of a background job, or all jobs when `job_id` is empty. `cancel=true` asks the job
to stop after its current paper.
"""
function job_status_tool(; job_id::String = "", cancel::Bool = false)::String
    if isempty(job_id)
        jobs = list_jobs()
        isempty(jobs) && return "No jobs."
        return join((format_job(j) for j in jobs), "\n")
    end
    job = get_job(job_id)
    job === nothing && return "⛔ No job $job_id."
    cancel && !can(tool_caller(), "jobs.control") && return "⛔ Not permitted: cancelling a job needs jobs.control"
    cancel && cancel!(job)
    return format_job(job; detail = true)
end
tool!("job_status", job_status_tool; need = "jobs.view")


split_list(s::AbstractString) = String.(filter(!isempty, split(s, r"[,\s]+")))

"Document `doc_id` a tool is asked about, refused as none when its caller may not see it."
tool_document(doc_id::AbstractString) = seen_document(kb(), tool_caller(), normalize_id(doc_id))

function normalize_id(s::AbstractString)
    local_kind(strip(s)) === nothing || return String(strip(s))
    id = parse_arxiv_id(s)
    id === nothing && error("Not an arXiv id: $s")
    return id.id
end

# ── Formatting ──────────────────────────────────────────────────────────────

short_authors(a) = isempty(a) ? "" : length(a) <= 3 ? join(a, ", ") : "$(a[1]) et al."

function snippet(text::AbstractString, n::Int = 360)
    t = replace(text, r"\s+" => " ")
    length(t) <= n ? t : first(t, n) * "…"
end

page_range(a, b) = a == b ? "p.$a" : "pp.$(a)–$(b)"

function format_hits(hits::Vector{PaperHit}; config::Config = kb().config)
    io = IOBuffer()
    for (i, h) in enumerate(hits)
        println(io, "$i. [$(h.doc_id)] $(h.title)")
        note = document_note(kb(), h.doc_id)
        isempty(note) || println(io, "   ", note)
        pages(p) = is_kind(k -> k.pdf, h.doc_id) ? " ($(page_range(p.page_start, p.page_end)))" : ""
        println(io, "   $(short_authors(h.authors)) · $(h.published) · $(h.category) · score $(round(h.score; digits = 4)) ",
            "($(round(Int, 100 * h.score / h.max_score))% of a first place in every ranking)")
        println(io, "   ranked: ", join(("$(ranking_label(config, e.ranking)) #$(e.rank)" *
                                         (startswith(e.unit, "p:") ? "" : " ($(snippet(e.label, 50)))") for e in h.evidence), "; "))
        for p in h.passages
            ranks = join(("$(ranking_label(config, e.ranking)) #$(e.rank)" for e in p.evidence), ", ")
            println(io, "   › $(p.section)$(pages(p)) [$ranks]: $(snippet(p.text))")
        end
    end
    return String(take!(io))
end

function processing_state(kb::KB, pid)
    fetched = !ismissing(scalar(kb, "SELECT 1 FROM files WHERE paper_id = ?", (pid,)))
    parsed = !ismissing(scalar(kb, "SELECT 1 FROM parses WHERE paper_id = ?", (pid,)))
    layers = [r.layer => r.n for r in query(kb,
        "SELECT layer, count(*) AS n FROM embeddings WHERE paper_id = ? GROUP BY layer ORDER BY layer", (pid,))]
    return (; fetched, parsed, layers)
end

"""
Paper `id`'s figures and tables, cut from its PDF first if they have not been (see
[`cut_paper_figures!`](@ref)); a document not read from a PDF has those it came with (a record's).
"""
function paper_figures_cut(kb::KB, id::AbstractString)
    is_kind(k -> k.pdf, id) && !figures_cut(kb, id) && lock(() -> cut_paper_figures!(kb, id), paper_lock(id))
    return paper_figures(kb, id)
end

"Why paper `id` has no figures or tables to show."
function figures_missing(kb::KB, id::AbstractString)
    is_kind(k -> k.pdf, id) || return "$id has no figures."
    pid = paper_id(kb, id)
    files = query(kb, "SELECT path FROM files WHERE paper_id = ?", (pid,))
    (isempty(files) || !isfile(first(files).path)) && return "No figures for $id: its PDF is not on this machine."
    return "No figures or tables were found in $id: none of its captions names one."
end

function format_paper(kb::KB, doc_id::AbstractString)
    p = paper_row(kb, doc_id)
    io = IOBuffer()
    println(io, "[$(p.doc_id)$(coalesce(p.version, ""))] $(coalesce(p.title, "(no metadata yet)"))")
    page = document_link(kb.config, p.doc_id)
    isempty(page) || println(io, "Page: ", page)
    note = document_note(kb, doc_id)
    isempty(note) || println(io, note)
    r = record_row(kb, doc_id)
    r === nothing || println(io, "From $(r.source)", isempty(r.url) ? "" : ": $(r.url)", "; linked to ",
                             (l = document_projects(kb, doc_id); isempty(l) ? "no project" : join(l, ", ")))
    authors = json_list(p.authors)
    isempty(authors) || println(io, "Authors: ", join(authors, ", "))
    # Uploaded documents and codebases have only some of arXiv's metadata.
    if !ismissing(p.published)
        line = "Published $(p.published)"
        ismissing(p.updated) || p.updated == p.published || (line *= ", updated $(p.updated)")
        cats = json_list(p.categories)
        ismissing(p.primary_category) || (line *= " · $(p.primary_category)" * (isempty(cats) ? "" : " ($(join(cats, ", ")))"))
        println(io, line)
    end
    ismissing(p.journal_ref) || println(io, "Journal: $(p.journal_ref)")
    ismissing(p.doi) || println(io, "DOI: $(p.doi)")
    is_arxiv_id(p.doc_id) ? println(io, "https://arxiv.org/abs/$(p.doc_id)") :
        (ismissing(p.source_path) || println(io, "Source: $(p.source_path)"))
    ismissing(p.abstract) || println(io, "\nAbstract: ", p.abstract)
    for sm in summaries(kb, doc_id)
        startswith(sm.unit, "p:") && println(io, "\nSummary ($(sm.summarizer), $(sm.model)): ", sm.text)
    end
    c = classification(kb, doc_id)
    c === nothing || println(io, "\nClassification:\n", format_classification(c))
    ms = mentions(kb, doc_id)
    if !isempty(ms)
        println(io, "\nPosted:")
        for m in ms
            println(io, "  $(Dates.format(m.posted, "yyyy-mm-dd HH:MM")) by $(coalesce(m.author, "?"))", ismissing(m.channel) ? "" : " in #$(m.channel)")
        end
    end
    st = processing_state(kb, p.id)
    println(io, "\nState: ", st.fetched ? "downloaded" : "not downloaded", ", ", st.parsed ? "parsed" : "not parsed",
        isempty(st.layers) ? ", not embedded" : ", embedded in " * join(("$(k) ($v)" for (k, v) in st.layers), ", "))
    figs = paper_figures(kb, doc_id)
    pdf = is_kind(k -> k.pdf, doc_id)
    isempty(figs) || println(io, "\nFigures and tables: $(count(f -> f.kind == "figure", figs)) figure(s), $(count(f -> f.kind == "table", figs)) table(s); ",
                             "list them with `figures`, see one with `figure`", pdf ? ", a page with `page`. References and what cites it: `references`." : ".")
    sections = query(kb, "SELECT number, title, level, page_start, page_end FROM sections WHERE paper_id = ? ORDER BY $(section_order())", (p.id,))
    if !isempty(sections)
        println(io, "\nOutline:")
        for s in sections
            println(io, "  ", "  "^(s.level - 1), s.title, "  (", page_range(s.page_start, s.page_end), ")")
        end
    end
    return String(take!(io))
end

"""
    read_paper(kb, doc_id; section = "", pages = "", max_chars = 20000) -> String
"""
function read_paper(kb::KB, doc_id::AbstractString; section::AbstractString = "",
                    pages::AbstractString = "", summaries::Bool = false, max_chars::Integer = 20000)
    p = paper_row(kb, doc_id)
    blocks = query(kb, "SELECT section, kind, page, text FROM blocks WHERE paper_id = ? ORDER BY ord", (p.id,))
    isempty(blocks) && return "⛔ $doc_id has not been parsed yet; ingest it first."
    note = document_note(kb, doc_id)
    if !isempty(section)
        secs = query(kb, "SELECT ord, number, title, path FROM sections WHERE paper_id = ? ORDER BY $(section_order())", (p.id,))
        i = findfirst(s -> coalesce(s.number, "") == section, secs)
        i === nothing && (i = findfirst(s -> occursin(lowercase(section), lowercase(s.title)), secs))
        i === nothing && return "⛔ No section matching \"$section\". Sections: " * join((s.title for s in secs), "; ")
        root = secs[i].path
        keep = Set(s.ord for s in secs if s.path == root || startswith(s.path, root * " › "))
        blocks = filter(b -> b.section in keep, blocks)
    end
    if !isempty(pages)
        m = match(r"^(\d+)(?:\s*[-–]\s*(\d+))?$", strip(pages))
        m === nothing && return "⛔ pages should look like \"3\" or \"3-5\"."
        a = parse(Int, m[1]); b = m[2] === nothing ? a : parse(Int, m[2])
        blocks = filter(x -> a <= x.page <= b, blocks)
    end
    summaries && return (isempty(note) ? "" : note * "\n\n") * section_summaries_text(kb, doc_id, Set(b.section for b in blocks), max_chars)
    io = IOBuffer()
    isempty(note) || println(io, note)
    page = 0
    for b in blocks
        b.kind in ("footnote",) && continue
        if b.page != page
            page = b.page
            println(io, "\n[page $page]")
        end
        b.kind == "heading" ? println(io, "\n## ", b.text) :
        b.kind == "equation" ? println(io, "    ", replace(b.text, "\n" => "\n    ")) :
        println(io, b.text)
        position(io) > max_chars && (println(io, "\n… (truncated at $max_chars characters)"); break)
    end
    return String(take!(io))
end

function section_summaries_text(kb::KB, doc_id, sections, max_chars)
    rows = [s for s in Zemi.summaries(kb, doc_id; summarizer = shown_summarizer(kb, doc_id)) if startswith(s.unit, "p:") ||
            parse(Int, split(s.unit, ':')[3]) in sections]
    isempty(rows) && return "⛔ No summaries for $doc_id yet; they are written during ingest."
    io = IOBuffer()
    for s in rows
        println(io, startswith(s.unit, "p:") ? "## Paper" : "## $(s.section)")
        println(io, s.text, "\n")
        position(io) > max_chars && (println(io, "… (truncated at $max_chars characters)"); break)
    end
    println(io, "(summaries by $(first(rows).summarizer), $(first(rows).model))")
    return String(take!(io))
end

function format_ingest(results)
    io = IOBuffer()
    for r in results
        if r.ok
            emb = join(("$(k) $v" for (k, v) in r.embedded if v > 0), ", ")
            println(io, "✓ $(r.id): ", r.parsed ? "parsed" : "parse up to date", ", ",
                r.summarized > 0 ? "$(r.summarized) summaries written, " : "",
                isempty(emb) ? "embeddings up to date" : "embedded $emb", get(r, :classified, false) ? ", classified" : "",
                " ($(round(r.seconds; digits = 1))s)")
            r.error === nothing || println(io, "  ⚠ ", r.error)
        else
            println(io, "✗ $(r.id): $(r.error)")
        end
    end
    return String(take!(io))
end

function format_paper_list(kb::KB, filter::AbstractString, state::AbstractString, limit::Integer; author::AbstractString = "",
                           except = ())
    rows = query(kb, """
        SELECT p.id, p.doc_id, p.title, p.authors, p.published,
               (SELECT max(posted_at) FROM mentions m WHERE m.paper_id = p.id) AS posted,
               EXISTS (SELECT 1 FROM parses x WHERE x.paper_id = p.id) AS parsed,
               EXISTS (SELECT 1 FROM embeddings e WHERE e.paper_id = p.id) AS embedded
        FROM papers p
        WHERE $(kind_in(k -> k.site; on = "p")) AND (? = '' OR p.title LIKE '%' || ? || '%' OR p.authors LIKE '%' || ? || '%')
        ORDER BY coalesce(posted, 0) DESC, p.published DESC""", (filter, filter, filter))
    rows = Base.filter(r -> !(r.doc_id in except), rows)
    isempty(author) || (rows = Base.filter(r -> any(a -> author_matches(a, author), json_list(r.authors)), rows))
    state == "new" && (rows = Base.filter(r -> r.parsed == 0, rows))
    state == "parsed" && (rows = Base.filter(r -> r.parsed == 1, rows))
    state == "embedded" && (rows = Base.filter(r -> r.embedded == 1, rows))
    isempty(rows) && return "No papers."
    io = IOBuffer()
    println(io, "$(length(rows)) paper(s)", length(rows) > limit ? ", showing $limit" : "", ":")
    for r in first(rows, limit)
        mark = r.embedded == 1 ? "●" : r.parsed == 1 ? "◐" : "○"
        posted = ismissing(r.posted) ? "" : " posted $(Dates.format(unix2datetime(r.posted), "yyyy-mm-dd"))"
        println(io, "$mark [$(r.doc_id)] $(coalesce(r.title, "(no metadata yet)"))$posted")
    end
    println(io, "● embedded  ◐ parsed  ○ recorded only")
    return String(take!(io))
end

# A service that is not running refuses the connection at once; one that is busy (Qdrant while a
# site build queries it) can take seconds to answer, and still counts as running.
function service_up(url)
    try
        HTTP.get(url; connect_timeout = 2, request_timeout = 20, retry = false).status == 200
    catch
        false
    end
end

function format_status(kb::KB)
    c = kb.config
    n(sql) = scalar(kb, sql)
    io = IOBuffer()
    # The shared service tells callers what it holds, not where (see `redact`).
    SHARED_MODE[] ? println(io, "Knowledge base") : println(io, "Knowledge base at $(db_path(c))")
    println(io, "Papers: $(n("SELECT count(*) FROM papers")) recorded, ",
        "$(n("SELECT count(*) FROM papers WHERE metadata_at IS NOT NULL")) with metadata, ",
        "$(n("SELECT count(*) FROM files")) downloaded, $(n("SELECT count(*) FROM parses")) parsed ",
        "($(n("SELECT count(*) FROM chunks")) passages)")
    for r in query(kb, """SELECT summarizer, model, count(*) AS n, count(DISTINCT paper_id) AS papers,
                          sum(input_tokens) AS tin, sum(output_tokens) AS tout FROM summaries GROUP BY summarizer""")
        println(io, "Summaries by $(r.summarizer) ($(r.model)): $(r.n) for $(r.papers) paper(s), ",
            "$(coalesce(r.tin, 0)) input / $(coalesce(r.tout, 0)) output tokens")
    end
    println(io, "\nLayers:")
    counts = Dict(r.layer => r.n for r in query(kb, "SELECT layer, count(*) AS n FROM embeddings GROUP BY layer"))
    for l in c.layers
        from = isempty(l.source) ? "" : " (summaries by $(l.source))"
        println(io, "  $(rpad(l.name, 26)) $(rpad(l.unit, 8)) $(rpad(l.model, 22)) $(lpad(get(counts, l.name, 0), 6)) vectors$from")
    end
    at(url) = SHARED_MODE[] ? "" : " " * url
    println(io, "\nOllama$(at(c.ollama_url)): ", service_up("$(c.ollama_url)/api/tags") ? "up" : "DOWN")
    println(io, "Qdrant$(at(Qdrant.url())): ", Qdrant.ping() ? "up" : "DOWN")
    running = Base.filter(j -> j.status == :running, list_jobs())
    isempty(running) || println(io, "\nRunning jobs:\n", join((format_job(j) for j in running), "\n"))
    return String(take!(io))
end

function format_job(j::Job; detail::Bool = false)
    s = "$(j.id) $(j.name): $(j.status) after $(elapsed(j)) — $(j.message)"
    detail || return s
    # An ingest returns its per-paper results; other jobs (a sync, a Manage action) their own report.
    if j.status == :done && j.result !== nothing
        s *= "\n" * (j.result isa AbstractVector && all(r -> r isa NamedTuple && haskey(r, :ok), j.result) ?
                      format_ingest(j.result) : string(j.result))
    end
    j.status == :failed && (s *= "\n" * first(something(j.error, ""), 2000))
    return s
end
