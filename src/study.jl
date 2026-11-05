# Studies: a question asked of the knowledge base, in themes. A study lives in a folder of its own
# in the content (`studies/<name>/`, see `content_path`): `study.toml` says what it asks and how each theme is searched for, and
# the drafts of its sections sit beside it as Markdown, written by the summarizer from the papers
# found and then revised by people. A notebook shows the evidence and the drafts.

"""
    Theme

One theme of a study: its `name`, a `description` of what it covers (given to the drafting model),
the `queries` that find its papers in the knowledge base, and the `arxiv` search queries (arXiv API
syntax) that find papers to add.
"""
Base.@kwdef struct Theme
    name::String
    description::String = ""
    queries::Vector{String} = String[]
    arxiv::Vector{String} = String[]
end

"""
    Synthesis

A section of a study drafted from its theme sections rather than from papers (an overview, say, or
the opportunities they point to): its `name`, the `slug` naming its file, and the `instructions`
for writing it.
"""
Base.@kwdef struct Synthesis
    name::String
    slug::String
    instructions::String
end

"""
    Study

A study read from its folder: `title`, the `question` it asks, its `audience` (who the drafts are
written for) and `context` (what the group brings, for drafts that weigh where to contribute), its
`themes`, its `syntheses` (drafted in order, each from the theme sections and the syntheses before
it), and the folder (`dir`) holding `study.toml` and the drafts.
"""
Base.@kwdef struct Study
    dir::String
    title::String
    question::String
    audience::String = ""
    context::String = ""
    themes::Vector{Theme}
    syntheses::Vector{Synthesis} = Synthesis[]
end

"""
    load_study(dir) -> Study
    load_study(config, name) -> Study

Read a study from its folder's `study.toml`: the folder `dir`, or the content's study `name`.
"""
load_study(c::Config, name::AbstractString) = load_study(content_path(c, "studies", name))
function load_study(dir::AbstractString)
    t = TOML.parsefile(joinpath(dir, "study.toml"))
    themes = [Theme(; name = th["name"], description = get(th, "description", ""),
                     queries = String.(get(th, "queries", String[])), arxiv = String.(get(th, "arxiv", String[])))
              for th in t["themes"]]
    syntheses = [Synthesis(; name = s["name"], slug = s["slug"], instructions = s["instructions"]) for s in get(t, "syntheses", [])]
    return Study(; dir = abspath(dir), title = t["title"], question = t["question"], audience = get(t, "audience", ""),
                 context = get(t, "context", ""), themes, syntheses)
end

# ── Evidence: the papers of the knowledge base each theme finds ──────────────────────────────────

"""
    EvidencePaper

A paper a theme found: `strength` sums, over the theme's queries, how strongly each search ranked
it (its fused score against a first place in every ranking), `queries` counts the queries that
found it, and `passages` holds its best-matching passages.
"""
Base.@kwdef struct EvidencePaper
    id::String
    title::String
    authors::Vector{String}
    year::String
    strength::Float64
    queries::Int
    passages::Vector{Passage}
end

"""
    study_evidence(kb, study; per_query = 15, each = 6, limit = 40) -> Vector{Pair{Theme,Vector{EvidencePaper}}}

For each theme, the papers its queries find (`per_query` from each search), strongest first, at
most `limit`: each query's own `each` strongest papers, so a paper only one query finds is not
crowded out by those every query finds, then the rest by strength. Each query is searched twice: with every ranking, and by the papers' titles and
abstracts alone. A paper read in full is found by many rankings and one only recorded by one, so
the second search lets a recorded paper count for its relevance; a paper counts by the stronger of
the two.
"""
function study_evidence(kb::KB, study::Study; per_query::Integer = 15, each::Integer = 6, limit::Integer = 40)
    by_record = [l.name for l in record_layers(kb.config) if l.name in embedded_layers(kb)]
    function hits(q)
        best = Dict{String,Tuple{Float64,PaperHit,Vector{Passage}}}()
        searches = [search(kb, q; limit = per_query, passages = 3)]
        isempty(by_record) || push!(searches, search(kb, q; limit = per_query, passages = 3, layers = by_record, keyword = false))
        for hs in searches, h in hs
            strength = h.max_score > 0 ? h.score / h.max_score : 0.0
            was = get(best, h.doc_id, (-1.0, h, Passage[]))
            best[h.doc_id] = (max(strength, was[1]), strength > was[1] ? h : was[2], [was[3]; h.passages])
        end
        return values(best)
    end
    return map(study.themes) do theme
        found = Dict{String,EvidencePaper}()
        kept = String[]                                 # each query's strongest, in order
        for q in theme.queries
            qs = sort!(collect(hits(q)); by = x -> -x[1])
            append!(kept, [x[2].doc_id for x in first(qs, each)])
            for (strength, h, passages) in qs
            was = get(found, h.doc_id, nothing)
            found[h.doc_id] = was === nothing ?
                EvidencePaper(; id = h.doc_id, h.title, h.authors, year = first(h.published, 4), strength, queries = 1,
                              passages = first(sort!(unique(p -> p.ord, passages); by = p -> -p.score), 3)) :
                EvidencePaper(; was.id, was.title, was.authors, was.year, strength = was.strength + strength,
                              queries = was.queries + 1,
                              passages = first(sort!(unique(p -> p.ord, [was.passages; passages]); by = p -> -p.score), 3))
            end
        end
        rest = sort!(collect(values(found)); by = p -> -p.strength)
        chosen = unique([[found[id] for id in kept]; rest])
        theme => sort!(first(chosen, max(limit, length(unique(kept)))); by = p -> -p.strength)
    end
end

"""
    theme_overlaps(evidence) -> Matrix{Int}

How many papers each pair of themes share (the diagonal: each theme's own count).
"""
function theme_overlaps(evidence)
    sets = [Set(p.id for p in ps) for (_, ps) in evidence]
    return [length(intersect(a, b)) for a in sets, b in sets]
end

"""
    crossings(evidence, theme_name) -> Vector{NamedTuple}

The papers of the named theme that other themes found too, with those themes: where, say, field
surveys meet modelling or machine learning.
"""
function crossings(evidence, name::AbstractString)
    i = findfirst(e -> e.first.name == name, evidence)
    i === nothing && not_found("No theme named $name")
    others = [(e.first.name, Set(p.id for p in e.second)) for (j, e) in enumerate(evidence) if j != i]
    out = [(; paper = p, themes = [n for (n, ids) in others if p.id in ids]) for p in evidence[i].second]
    return filter(x -> !isempty(x.themes), out)
end

"Each theme's papers counted by year: `theme name => [(year, count)]`, oldest first."
theme_timeline(evidence) = [t.name => sort!([(y, count(p -> p.year == y, ps)) for y in unique(p.year for p in ps if !isempty(p.year))])
                            for (t, ps) in evidence]

# ── Candidates: papers on arXiv the study should add ─────────────────────────────────────────────

"""
    Candidate

A paper on arXiv a study's searches found that the knowledge base lacks: its record, the themes
whose searches found it, and `similarity`, its title and abstract's closeness to the nearest of
those themes' queries (`NaN` when no embedding model is at hand).
"""
Base.@kwdef struct Candidate
    meta::PaperMeta
    themes::Vector{String}
    similarity::Float64
end

"How long each of a study's arXiv searches waits out arXiv being too busy to answer, in seconds."
const STUDY_SEARCH_PATIENCE = 300

"""
    find_candidates(kb, study; max_results = 40, search = search_arxiv, progress) -> Vector{Candidate}

Run each theme's arXiv searches and return the papers not in the knowledge base, closest to their
themes first (or in the order arXiv ranked them, without an embedding model). A search waits out
arXiv being busy for a while (see [`STUDY_SEARCH_PATIENCE`](@ref)); one that still fails is warned
about and skipped.
"""
function find_candidates(kb::KB, study::Study; max_results::Integer = 40,
                         search = (q, c; max_results) -> search_arxiv(q, c; max_results, patience = STUDY_SEARCH_PATIENCE),
                         progress = msg -> nothing)
    have = Set(r.doc_id for r in query(kb, "SELECT doc_id FROM papers"))
    found = Dict{String,PaperMeta}()
    themes = Dict{String,Vector{String}}()
    order = String[]
    for theme in study.themes, q in theme.arxiv
        progress("Searching arXiv: $q")
        # One search failing (arXiv answering 429 in a busy spell, say) costs only its own results.
        metas = try
            search(q, kb.config; max_results)
        catch e
            e isa InterruptException && rethrow()
            @warn "An arXiv search failed; its papers are left out" query = q exception = e
            PaperMeta[]
        end
        for m in metas
            m.doc_id in have && continue
            haskey(found, m.doc_id) || (found[m.doc_id] = m; push!(order, m.doc_id))
            union!(get!(Vector{String}, themes, m.doc_id), [theme.name])
        end
    end
    isempty(order) && return Candidate[]
    progress("Ranking $(length(order)) papers by closeness to their themes")
    similarity = try
        l = landscape_layer(kb.config)
        unit(v) = v ./ max(norm(v), eps())
        docs = embed(kb.config, l, [first(l.doc_prefix * found[id].title * "\n\n" * found[id].abstract, l.max_chars) for id in order])
        asked = Dict(q => unit(Float64.(query_vector(kb.config, l, q))) for t in study.themes for q in t.queries)
        map(zip(order, docs)) do (id, v)
            u = unit(Float64.(v))
            maximum(dot(u, asked[q]) for t in study.themes if t.name in themes[id] for q in t.queries; init = 0.0)
        end
    catch e
        e isa InterruptException && rethrow()
        @warn "No embedding model to rank the candidates by; they keep arXiv's order" exception = e
        fill(NaN, length(order))
    end
    out = [Candidate(; meta = found[id], themes = themes[id], similarity = s) for (id, s) in zip(order, similarity)]
    return all(isnan, similarity) ? out : sort!(out; by = c -> -c.similarity)
end

"""
    add_candidates!(kb, ids; progress) -> Vector{String}

Add papers found for a study: record them with their arXiv metadata and embed their titles and
abstracts, so studies and the landscape see them at once. Reading them in full is a sync's work.
"""
function add_candidates!(kb::KB, ids::AbstractVector{<:AbstractString}; progress = msg -> nothing)
    ids = add_papers!(kb, ids; source = "study")
    progress("Fetching the arXiv records of $(length(ids)) paper(s)")
    refresh_metadata!(kb, ids)
    embed_records!(kb, ids; progress)
    return ids
end

# ── Drafts: a section per theme, and an overview ─────────────────────────────────────────────────

study_system(c::Config) = "You write sections of a literature study for a research group$(in_field(c)). Reply with Markdown only."

draft_path(study::Study, slug::AbstractString) = joinpath(study.dir, "$slug.md")

# A draft file begins with a comment saying what it was written from, and the hash of the text as
# written, so a draft someone has since edited is recognised and left alone.
const DRAFT_HEADER = r"\A<!-- study draft: (\{.*?\}) -->\n"s

function read_draft(path::AbstractString)
    isfile(path) || return nothing
    text = read(path, String)
    m = match(DRAFT_HEADER, text)
    m === nothing && return (; meta = Dict{String,Any}(), body = text, edited = true)
    meta = JSON.parse(m.captures[1])
    body = text[ncodeunits(m.match)+1:end]
    return (; meta, body, edited = get(meta, "text_sha", "") != bytes2hex(sha256(body)))
end

function write_draft(path::AbstractString, body::AbstractString, meta::AbstractDict)
    meta = merge(Dict{String,Any}(meta), Dict("text_sha" => bytes2hex(sha256(body)), "written_at" => now_iso()))
    write(path, "<!-- study draft: $(JSON.json(meta)) -->\n" * body)
end

"The material a theme's draft is written from: each paper's summary or abstract, and its passages the searches found."
function theme_material(kb::KB, papers::AbstractVector{EvidencePaper}; passage_chars::Integer = 500, summary_chars::Integer = 1500)
    io = IOBuffer()
    for p in papers
        c = classification(kb, p.id)
        line = c === nothing ? nothing : get(c, "one_line", nothing)
        s = summaries(kb, p.id; summarizer = something(shown_summarizer(kb, p.id), ""))
        summary = [x.text for x in s if startswith(x.unit, "p:")]
        about = isempty(summary) ? coalesce(paper_row(kb, p.id).abstract, "") : first(split_topics(only(summary))[1], summary_chars)
        who = isempty(p.authors) ? "" : first(p.authors) * (length(p.authors) > 1 ? " et al." : "")
        println(io, "## [arXiv:$(p.id)] $(p.title)")
        println(io, "$who, $(p.year)", line === nothing ? "" : ". $line")
        println(io, "\n", about, "\n")
        for x in p.passages
            println(io, "Passage (", x.section, "): ", first(replace(x.text, r"\s+" => " "), passage_chars))
        end
        println(io)
    end
    return String(take!(io))
end

function theme_prompt(kb::KB, study::Study, theme::Theme)
    """
    $(group_brief(kb.config))The study: $(study.title). Its question: $(study.question)

    Its readers: $(study.audience)

    Write the study's section on the theme "$(theme.name)": $(theme.description)

    The papers on this theme in the group's knowledge base are in the attached material, each with
    its summary and the passages the searches found. Write the section from that material:
    - Open with a paragraph saying what the material shows about the theme as it bears on the
      study's question.
    - Then cover what has been done, by whom and with which methods, how approaches changed over
      time, and how the work bears on the study's question; use ### subsections.
    - Cite each claim with the ids given, in the form [arXiv:2401.00001]. Cite only the papers in
      the material, and say so where the material is thin rather than filling in from memory.
    - Explain each technical term and code the first time it appears, briefly, for these readers.
    - Add a "### Where to start reading" list of the three to five papers that best introduce the
      theme, each with a sentence on what it teaches.
    - End with a "### Gaps and open questions" list: what this literature leaves open, and what
      the material is missing for this study.
    Between 900 and 1500 words.
    """
end

"""
    draft_theme!(kb, study, theme, papers; summarizer = kb.config.summarizer, force = false) -> NamedTuple

Have the summarizer write the study's section on `theme` from the papers found for it, saved as
`<theme>.md` in the study's folder. A draft is written again only when the papers it would be
written from changed (or with `force`), and never over one someone has edited.
Returns `(; path, written, reason)`.
"""
function draft_theme!(kb::KB, study::Study, theme::Theme, papers::AbstractVector{EvidencePaper};
                      summarizer::AbstractString = kb.config.summarizer, force::Bool = false)
    path = draft_path(study, slugify(theme.name))
    material = theme_material(kb, papers)
    s = Zemi.summarizer(kb.config, summarizer)
    prompt = theme_prompt(kb, study, theme)
    inputs = bytes2hex(sha256(JSON.json(Dict("material" => material, "prompt" => prompt, "model" => s.model))))
    was = read_draft(path)
    was !== nothing && was.edited && return (; path, written = false, reason = "edited since it was drafted")
    !force && was !== nothing && get(was.meta, "inputs_sha", "") == inputs && return (; path, written = false, reason = "up to date")
    body = strip(ask(s, study_system(kb.config), prompt; preamble = material)) * "\n"
    write_draft(path, body, Dict("theme" => theme.name, "summarizer" => s.name, "model" => s.model,
                                 "papers" => [p.id for p in papers], "inputs_sha" => inputs))
    return (; path, written = true, reason = "drafted from $(length(papers)) papers")
end

"""
    draft_synthesis!(kb, study, synthesis; summarizer = kb.config.summarizer, force = false) -> NamedTuple

Write one of the study's syntheses, `<slug>.md`, from its theme sections and the syntheses listed
before it, as they now stand (revised or not), following its instructions. Like a theme's draft it
is written again only when what it is written from changed, and never over an edited one.
"""
function draft_synthesis!(kb::KB, study::Study, syn::Synthesis; summarizer::AbstractString = kb.config.summarizer,
                          force::Bool = false)
    path = draft_path(study, syn.slug)
    before = study.syntheses[1:something(findfirst(x -> x.slug == syn.slug, study.syntheses), 1)-1]
    sources = [[(t.name, slugify(t.name)) for t in study.themes]; [(x.name, x.slug) for x in before]]
    sections = [(n, read_draft(draft_path(study, slug))) for (n, slug) in sources]
    material = join(("# $(n)\n\n$(d.body)" for (n, d) in sections if d !== nothing), "\n\n")
    isempty(material) && error("No theme has a draft yet; draft the themes first")
    s = Zemi.summarizer(kb.config, summarizer)
    prompt = """
        $(group_brief(kb.config))The study: $(study.title). Its question: $(study.question)

        Its readers: $(study.audience)

        What the readers bring: $(study.context)

        The study's sections so far are in the attached material. Write its section "$(syn.name)":
        $(syn.instructions)

        Keep the citations in the same [arXiv:id] form, and cite only papers the sections cite.
        Use ### subsections.
        """
    inputs = bytes2hex(sha256(JSON.json(Dict("material" => material, "prompt" => prompt, "model" => s.model))))
    was = read_draft(path)
    was !== nothing && was.edited && return (; path, written = false, reason = "edited since it was drafted")
    !force && was !== nothing && get(was.meta, "inputs_sha", "") == inputs && return (; path, written = false, reason = "up to date")
    body = strip(ask(s, study_system(kb.config), prompt; preamble = material)) * "\n"
    write_draft(path, body, Dict("theme" => syn.name, "summarizer" => s.name, "model" => s.model, "inputs_sha" => inputs))
    return (; path, written = true, reason = "drafted from $(count(x -> x[2] !== nothing, sections)) sections")
end

"""
    draft_study!(kb, study, evidence; ntasks = 4, force = false, progress) -> Vector{NamedTuple}

Draft every theme's section (`ntasks` at a time, since an agent takes minutes a section), then each
synthesis in order. Each result is `(; path, written, reason)`. A synthesis is drafted again whenever
what it is written from changed, which includes a theme section drafted again.
"""
function draft_study!(kb::KB, study::Study, evidence; ntasks::Integer = 4, force::Bool = false,
                      progress = msg -> nothing)
    results = asyncmap(evidence; ntasks) do (theme, papers)
        progress("Drafting “$(theme.name)” from $(length(papers)) papers")
        r = draft_theme!(kb, study, theme, papers; force)
        progress("“$(theme.name)”: $(r.reason)")
        r
    end
    for syn in study.syntheses
        progress("Drafting “$(syn.name)”")
        r = draft_synthesis!(kb, study, syn; force)
        progress("“$(syn.name)”: $(r.reason)")
        push!(results, r)
    end
    return results
end

const DRAFT_CITATION = r"\[(arXiv:[^\]]+)\]"
cited_ids(text::AbstractString) =
    unique(String(x.captures[1]) for m in eachmatch(DRAFT_CITATION, text) for x in eachmatch(r"arXiv:\s*([^\s;,\]]+)", m.match))

"""
    draft_markdown(kb, study, slug) -> String

A draft as it is shown: without the heading it opens with (the notebook gives each section its own),
and with its `[arXiv:id]` citations (one or several to a bracket) as Slate citations, `[@key]`
against the study's bibliography (see [`write_study_bib`](@ref)). A cited id the knowledge base
does not have is left as text.
"""
function draft_markdown(kb::KB, study::Study, slug::AbstractString)
    d = read_draft(draft_path(study, slug))
    d === nothing && return ""
    body = replace(d.body, r"\A\s*#{1,3} [^\n]*\n" => "")
    have(id) = !ismissing(paper_id(kb, id))
    return replace(body, DRAFT_CITATION => function (m)
        ids = cited_ids(m)
        known = filter(have, ids)
        cites = isempty(known) ? "" : "[" * join(("@" * cite_key(id) for id in known), "; ") * "]"
        rest = join(("arXiv:" * id for id in ids if !have(id)), "; ")
        isempty(rest) ? cites : isempty(cites) ? "($rest)" : "$cites ($rest)"
    end)
end

"""
    write_study_bib(kb, study; pages = "generated/kb/") -> String

Write the study's bibliography, `references.bib` in its folder: an entry for every paper of the
knowledge base its drafts cite. The file is only rewritten when it changes. Returns its path.
"""
function write_study_bib(kb::KB, study::Study; pages::AbstractString = "generated/kb/")
    slugs = [[slugify(t.name) for t in study.themes]; [s.slug for s in study.syntheses]]
    ids = unique(id for slug in slugs for d in (read_draft(draft_path(study, slug)),) if d !== nothing
                 for id in cited_ids(d.body) if !ismissing(paper_id(kb, id)))
    text = "% The papers this study's drafts cite, written by `write_study_bib` from the knowledge base.\n\n" *
           join((bib_entry(kb, id; pages) for id in sort(ids)), "\n")
    path = joinpath(study.dir, "references.bib")
    (isfile(path) && read(path, String) == text) || write(path, text)
    return path
end

# ── Showing a study ──────────────────────────────────────────────────────────────────────────────
# As Markdown, which a notebook splices into its prose (`{{ … }}`), so the text and tables typeset as
# the notebook's own in every view: live, the docs site and a PDF.

"""
    StudyMarkdown

Markdown text for a notebook to show: a draft or a table. It shows as `text/markdown`, which Slate
renders as prose, and as plain text in full, so a splice never shortens it.
"""
struct StudyMarkdown
    text::String
end
Base.show(io::IO, ::MIME"text/markdown", m::StudyMarkdown) = print(io, m.text)
Base.show(io::IO, ::MIME"text/plain", m::StudyMarkdown) = print(io, m.text)
Base.show(io::IO, m::StudyMarkdown) = print(io, m.text)

# A docs-source path the docs build makes relative to the page holding it (DocumenterSlate), so a
# link works on whichever page the notebook is placed.
page_href(id; pages = "generated/kb/") = "slate-docpage:$(pages)papers/$(page_slug(id)).md"
first_author(p) = isempty(p.authors) ? "" : last(split(first(p.authors))) * (length(p.authors) > 1 ? " et al." : "")
cell_text(s) = replace(md_escape(s), "|" => "\\|")
paper_cell(id, title, who; pages) = "[$(cell_text(title))]($(page_href(id; pages)))" * (isempty(who) ? "" : " · " * cell_text(who))

"""
    study_text(kb, study, slug) -> StudyMarkdown

One of the study's sections (a theme's or a synthesis's draft), citing the study's bibliography, or
a note that it has not been drafted yet.
"""
function study_text(kb::KB, study::Study, slug::AbstractString)
    text = draft_markdown(kb, study, slug)
    return StudyMarkdown(isempty(text) ? "*Not drafted yet: `draft_study!` writes it.*" : text)
end

"""
    papers_table(kb, papers; shown = 12, pages = "generated/kb/") -> StudyMarkdown

A theme's papers as a table, strongest first: strength, year, the paper linked to its page with its
first author, and whether it has been read in full or only its abstract is known.
"""
function papers_table(kb::KB, papers::AbstractVector{EvidencePaper}; shown::Integer = 12, pages::AbstractString = "generated/kb/")
    read_in_full = Set(r.id for r in query(kb, "SELECT p.doc_id AS id FROM papers p JOIN parses x ON x.paper_id = p.id"))
    rows = ["| Strength | Year | Paper | Read |", "|---:|:--|:--|:--|"]
    for p in first(papers, shown)
        push!(rows, "| $(round(p.strength; digits = 2)) | $(p.year) | $(paper_cell(p.id, p.title, first_author(p); pages)) | " *
                    (p.id in read_in_full ? "in full" : "abstract") * " |")
    end
    more = length(papers) > shown ? "\n\n*…and $(length(papers) - shown) more.*" : ""
    return StudyMarkdown(join(rows, "\n") * more)
end

"""
    overlaps_table(evidence) -> StudyMarkdown

How many papers each pair of themes shares, as a table (the diagonal: each theme's own count).
"""
function overlaps_table(evidence)
    names = [t.name for (t, _) in evidence]
    m = theme_overlaps(evidence)
    rows = ["| | " * join(cell_text.(names), " | ") * " |", "|:--|" * repeat("--:|", length(names))]
    append!(rows, ["| **$(cell_text(names[i]))** | " * join((i == j ? "*$(m[i, j])*" : string(m[i, j]) for j in eachindex(names)), " | ") * " |"
                   for i in eachindex(names)])
    return StudyMarkdown(join(rows, "\n"))
end

"""
    crossings_table(evidence, theme_name; pages = "generated/kb/") -> StudyMarkdown

The papers of one theme that other themes found too, as a table: where the work meets.
"""
function crossings_table(evidence, name::AbstractString; pages::AbstractString = "generated/kb/")
    found = crossings(evidence, name)
    isempty(found) && return StudyMarkdown("*No paper of “$(name)” is found by another theme.*")
    rows = ["| Paper | Year | Also found by |", "|:--|:--|:--|"]
    append!(rows, ["| $(paper_cell(r.paper.id, r.paper.title, first_author(r.paper); pages)) | $(r.paper.year) | " *
                   join(cell_text.(r.themes), ", ") * " |" for r in found])
    return StudyMarkdown(join(rows, "\n"))
end
