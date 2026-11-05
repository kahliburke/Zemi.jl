# Works the knowledge base's papers cite that it does not hold, from their reference lists, ranked by
# how many papers cite them: the papers a reader of this library is most likely to be missing.

"""
    CitedWork

A work papers of the knowledge base cite and it does not hold. `key` is what its citations were
grouped by: its arXiv id, else its DOI, else its year with the first two other numbers of the
reference (a journal's volume and page); citations by journal and page alone join those of the same
work by identifier. `arxiv` and `doi` are as cited, `text` is one reference to
it as printed, and `cited_by` the ids of the papers citing it.
"""
Base.@kwdef struct CitedWork
    key::String
    arxiv::Union{String,Nothing} = nothing
    doi::Union{String,Nothing} = nothing
    text::String
    cited_by::Vector{String} = String[]
end

"""
    work_key(ref) -> Union{String,Nothing}

What citations of one work have in common: `arxiv:<id>`, else `doi:<doi>`, else `ref:<year>:<n>:<m>`
for a reference with one year and two other numbers, one of them a page (100 or more). Nothing for
a reference with too little to tell it apart.
"""
function work_key(r::Reference)
    r.arxiv !== nothing && return "arxiv:" * lowercase(r.arxiv)
    r.doi !== nothing && return "doi:" * normalize_doi(r.doi)
    return journal_key(r.text)
end

"A reference's year with the first two other numbers in it, one a page: `ref:<year>:<n>:<m>`."
function journal_key(text::AbstractString)
    # Whole numbers: not parts of a decimal or a DOI's prefix ("10.1088"), though a full stop may end one.
    numbers = [parse(Int, m.match) for m in eachmatch(r"(?<![\d.])\d{1,7}(?!\d|\.\d)", text)]
    years = unique(filter(n -> 1900 <= n <= 2100, numbers))
    rest = filter(n -> !(1900 <= n <= 2100), numbers)
    (length(years) == 1 && length(rest) >= 2 && maximum(rest[1:2]) >= 100) || return nothing
    return "ref:$(only(years)):$(rest[1]):$(rest[2])"
end

"""
    cited_works(references; min_cited = 2) -> Vector{CitedWork}

The works cited in `references` (citing paper id => its [`Reference`](@ref)s) that are not in the
knowledge base, cited by at least `min_cited` papers, most cited first. A reference matched to a
paper of the knowledge base, or with too little to group by (see [`work_key`](@ref)), is left out.
"""
function cited_works(references; min_cited::Integer = 2)
    works = Dict{String,CitedWork}()
    # A work some papers cite by its arXiv id or DOI and others only by journal and page: the journal
    # numbers of a reference with an identifier say which identifier they stand for.
    stands_for = Dict{String,String}()
    for (citing, refs) in references, r in refs
        r.cites === nothing || continue
        key = work_key(r)
        key === nothing && continue
        startswith(key, "ref:") || (j = journal_key(r.text)) === nothing || get!(stands_for, j, key)
        w = get!(works, key) do
            CitedWork(; key, r.arxiv, r.doi, r.text)
        end
        citing in w.cited_by || push!(w.cited_by, String(citing))
        # The fullest reference stands for the work, up to a length worth reading.
        if length(r.text) > length(w.text) && length(r.text) <= 400
            works[key] = CitedWork(; key, arxiv = something(w.arxiv, r.arxiv, Some(nothing)),
                                   doi = something(w.doi, r.doi, Some(nothing)), r.text, w.cited_by)
        end
    end
    for (j, key) in stands_for
        (haskey(works, j) && haskey(works, key)) || continue
        union!(works[key].cited_by, pop!(works, j).cited_by)
    end
    picked = [w for w in values(works) if length(w.cited_by) >= min_cited]
    return sort!(picked; by = w -> (-length(w.cited_by), w.key))
end

"The works the knowledge base's papers cite and it does not hold (see [`cited_works`](@ref))."
function cited_works(kb::KB; min_cited::Integer = 2)
    index = ReferenceIndex(kb)
    ids = [r.id for r in query(kb, "SELECT p.doc_id AS id FROM papers p JOIN parses x ON x.paper_id = p.id WHERE $(literature_sql(on = "p"))")]
    return cited_works((id => paper_references(kb, id; index) for id in ids); min_cited)
end

# ── Missing works on arXiv ───────────────────────────────────────────────────────────────────────
# A work cited only by DOI can still be on arXiv. OpenAlex knows where works are posted; what it says
# of each DOI is kept (doi_arxiv), so a site build never asks.

"""
    find_on_arxiv!(kb, dois; recheck = Day(60), lookup = openalex_arxiv, progress) -> Int

Ask OpenAlex what `dois` are on arXiv, fifty at a time, and keep the answers; a DOI asked about within
`recheck` is not asked again. Returns how many of those asked are on arXiv.
"""
function find_on_arxiv!(kb::KB, dois; recheck::Period = Day(60), lookup = openalex_arxiv, progress = msg -> nothing)
    since = iso_ago(recheck)
    checked = Set(r.doi for r in query(kb, "SELECT doi FROM doi_arxiv WHERE checked_at >= ?", (since,)))
    todo = [d for d in unique(normalize_doi.(dois)) if !(d in checked)]
    found = 0
    for (i, batch) in enumerate(Iterators.partition(todo, 50))
        progress("[$(min(50i, length(todo)))/$(length(todo))] asking OpenAlex which DOIs are on arXiv")
        answers = lookup(collect(batch), kb.config.contact)
        transaction(kb) do
            for d in batch
                id = get(answers, d, nothing)
                found += id !== nothing
                execute!(kb, "INSERT OR REPLACE INTO doi_arxiv VALUES (?, ?, ?)", (d, something(id, missing), now_iso()))
            end
        end
    end
    return found
end

"""
    on_arxiv(kb, works) -> Vector{CitedWork}

`works` with the arXiv id found for each one cited only by DOI (see [`find_on_arxiv!`](@ref)), and
without those whose arXiv id the knowledge base already holds.
"""
function on_arxiv(kb::KB, works::AbstractVector{CitedWork})
    known = Dict(r.doi => r.doc_id for r in query(kb, "SELECT doi, doc_id FROM doi_arxiv WHERE doc_id IS NOT NULL"))
    held = Set(r.id for r in query(kb, "SELECT doc_id AS id FROM papers"))
    out = CitedWork[]
    for w in works
        id = something(w.arxiv, w.doi === nothing ? nothing : get(known, normalize_doi(w.doi), nothing), Some(nothing))
        id !== nothing && id in held && continue
        push!(out, id === w.arxiv ? w : CitedWork(; w.key, arxiv = id, w.doi, w.text, w.cited_by))
    end
    return out
end

# ── Serving the list ─────────────────────────────────────────────────────────────────────────────
# Gathering the cited works means reading every reference list. The site build does it anyway and
# keeps what it found here, so the API serving the same process answers from it: with what is on
# arXiv applied as of the request, a lookup needs no rebuild of the site.
const CITED_WORKS = Ref{Union{Vector{CitedWork},Nothing}}(nothing)

"""
    missing_works(kb) -> Vector{CitedWork}

The works the knowledge base's papers cite and it lacks, with what is known of them on arXiv (see
[`on_arxiv`](@ref)): from the site build's gathering where there was one, else gathered now.
"""
function missing_works(kb::KB)
    CITED_WORKS[] === nothing && (CITED_WORKS[] = cited_works(kb))
    return on_arxiv(kb, CITED_WORKS[])
end

"The missing works as the site's list shows them, each citing paper with its page and title."
function works_json(kb::KB, works::AbstractVector{CitedWork})
    ids = unique(id for w in works for id in w.cited_by)
    titles = isempty(ids) ? Dict{String,String}() : Dict(r.id => coalesce(r.title, r.id) for r in query(kb,
        "SELECT doc_id AS id, title FROM papers WHERE doc_id IN ($(in_marks(length(ids))))", Tuple(ids)))
    return [Dict("key" => w.key, "arxiv" => w.arxiv, "doi" => w.doi, "text" => w.text,
                 "cited_by" => [Dict("id" => id, "slug" => page_slug(id), "title" => get(titles, id, id)) for id in w.cited_by])
            for w in works]
end
