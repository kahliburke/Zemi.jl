"""
    Evidence

Where one ranking placed a paper or passage: the `ranking` (`"keyword"` or a layer name), the
`rank` of the unit it matched (for a paper, its best unit in that ranking), that unit's key, the
share it added to the fused score (`contribution`), and a readable `label` for the unit.
"""
struct Evidence
    ranking::String
    rank::Int
    unit::String
    contribution::Float64
    label::String
end
Evidence(ranking, rank, unit, contribution) = Evidence(ranking, rank, unit, contribution, "")

"""
    Passage

A chunk that matched a search, with each ranking that found it (see [`Evidence`](@ref)).
"""
struct Passage
    ord::Int
    section::String
    page_start::Int
    page_end::Int
    text::String
    score::Float64
    evidence::Vector{Evidence}
end

"""
    PaperHit

A paper that matched a search, with its best passages. `score` is its fused score and `max_score`
the score of a paper first in every ranking of this search, so `score / max_score` says how
strong the match is on a scale that holds across queries. `evidence` has one entry per ranking
that found the paper, strongest first.
"""
struct PaperHit
    doc_id::String
    title::String
    authors::Vector{String}
    published::String
    category::String
    score::Float64
    max_score::Float64
    passages::Vector{Passage}
    evidence::Vector{Evidence}
end

"The rankings that found a paper or passage."
via(x::Union{PaperHit,Passage}) = [e.ranking for e in x.evidence]

# Reciprocal rank fusion constant; 60 is the usual choice and keeps any single ranking from
# dominating.
const RRF_K = 60

"""
    keyword_query(q) -> String

Turn free text into an FTS5 query that matches any of its words, so BM25 ranks by how many and
how rare the matching words are (FTS5's default is to require all of them).
"""
function keyword_query(q::AbstractString)
    words = unique(lowercase(m.match) for m in eachmatch(r"[\p{L}\p{N}]{2,}", q))
    return join(("\"$w\"" for w in words), " OR ")
end

function keyword_ranking(kb::KB, q::AbstractString; limit::Integer = 50)
    fts = keyword_query(q)
    isempty(fts) && return String[]
    rows = query(kb, """
        SELECT p.doc_id, c.ord FROM chunks_fts f
        JOIN chunks c ON c.id = f.rowid JOIN papers p ON p.id = c.paper_id
        WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?""", (fts, limit))
    return ["c:$(r.doc_id):$(r.ord)" for r in rows]
end

# Queries' vectors by endpoint, model and text, for searches asked again: emptied when it holds
# `QUERY_CACHE_MAX`, a few megabytes. Embedding is done outside the lock, so searches (and a
# search's layers) embed at once.
const _QUERY_CACHE = Dict{Tuple{String,String,String},Vector{Float32}}()
const _QUERY_CACHE_LOCK = ReentrantLock()
const QUERY_CACHE_MAX = 2000

function query_vector(c::Config, l::Layer, q::AbstractString)
    key = (l.url, l.model, l.query_prefix * q)
    v = lock(() -> get(_QUERY_CACHE, key, nothing), _QUERY_CACHE_LOCK)
    v === nothing || return v
    v = only(embed(c, l, [key[3]]; query = true))
    lock(_QUERY_CACHE_LOCK) do
        length(_QUERY_CACHE) >= QUERY_CACHE_MAX && empty!(_QUERY_CACHE)
        _QUERY_CACHE[key] = v
    end
    return v
end

embedded_layers(kb::KB) = Set(r.name for r in query(kb, "SELECT name FROM layers"))

"""
    rankings(kb, q; layers = nothing, keyword = true, since = nothing, depth = 60)
        -> Vector{Pair{String,Vector{String}}}

The separate rankings a search fuses: `"keyword" => unit keys` from BM25 over chunks, and one
`layer name => unit keys` per embedded layer (paper layers return up to half of `depth`). Unit keys
are `p:<id>`, `s:<id>:<section>` or `c:<id>:<chunk>`. Vector searches run concurrently.
"""
function rankings(kb::KB, q::AbstractString; layers = nothing, keyword::Bool = true,
                  since = nothing, depth::Integer = 60)
    available = embedded_layers(kb)
    use = [l for l in kb.config.layers if l.name in available && (layers === nothing || l.name in layers)]
    qfilter = qdrant_filter(nothing, since)
    out = Pair{String,Vector{String}}[]
    keyword && push!(out, "keyword" => keyword_ranking(kb, q; limit = depth))
    tasks = [Threads.@spawn begin
                 hits = vector_search(collection_name(kb.config, l), query_vector(kb.config, l, q);
                     limit = l.unit == :paper ? depth ÷ 2 : depth, filter = qfilter)
                 l.name => [h.key for h in hits]
             end for l in use]
    append!(out, fetch.(tasks))
    return out
end

"""
    Fused

The result of [`fuse`](@ref): scores and the rankings that contributed, for papers and for chunks.
"""
struct Fused
    paper_score::Dict{String,Float64}
    paper_evidence::Dict{String,Vector{Evidence}}
    chunk_score::Dict{String,Float64}
    chunk_evidence::Dict{String,Vector{Evidence}}
    paper_chunks::Dict{String,Vector{String}}
    max_score::Float64
end

"The paper a unit key (`p:<id>`, `s:<id>:<section>`, `c:<id>:<chunk>`) is of."
unit_paper(key::AbstractString) = split(key, ':'; limit = 3)[2]

"""
    fuse(ranked; weights = nothing, k = RRF_K) -> Fused

Weighted reciprocal rank fusion over the output of [`rankings`](@ref). A paper scores
`w / (k + rank)` from each ranking, at the rank of its best unit there; a chunk scores the same
from each ranking it appears in. `weights` maps ranking names (`"keyword"`, layer names) to their
weight: a missing name weighs 1 and a weight of 0 leaves that ranking out. Larger `k` flattens the
difference between the top ranks.
"""
function fuse(ranked; weights = nothing, k::Real = RRF_K)
    paper_score, paper_evidence = Dict{String,Float64}(), Dict{String,Vector{Evidence}}()
    chunk_score, chunk_evidence = Dict{String,Float64}(), Dict{String,Vector{Evidence}}()
    paper_chunks = Dict{String,Vector{String}}()
    max_score = 0.0
    for (name, keys) in ranked
        w = weights === nothing ? 1.0 : Float64(get(weights, name, 1.0))
        w > 0 || continue
        max_score += w / (k + 1)
        seen = Set{String}()
        for (rank, key) in enumerate(keys)
            c = w / (k + rank)
            paper = unit_paper(key)
            if !(paper in seen)
                push!(seen, paper)
                paper_score[paper] = get(paper_score, paper, 0.0) + c
                push!(get!(Vector{Evidence}, paper_evidence, paper), Evidence(name, rank, key, c))
            end
            if startswith(key, "c:")
                haskey(chunk_score, key) || push!(get!(Vector{String}, paper_chunks, paper), key)
                chunk_score[key] = get(chunk_score, key, 0.0) + c
                push!(get!(Vector{Evidence}, chunk_evidence, key), Evidence(name, rank, key, c))
            end
        end
    end
    return Fused(paper_score, paper_evidence, chunk_score, chunk_evidence, paper_chunks, max_score)
end

# An arXiv id anywhere in a query: new style (2401.00001, with or without its version) or old
# (hep-th/9901001), not inside a longer number or word.
const ARXIV_IN_QUERY = Regex("(?<![\\w./-])(?:arxiv:\\s*)?$ARXIV_ID(?:v\\d+)?(?![\\w./])", "i")

"""
    named_papers(kb, q) -> (ids, rest)

The papers query `q` names by arXiv id that the knowledge base has, in the order named, and what the
query says besides its ids.
"""
function named_papers(kb::KB, q::AbstractString)
    ids = unique(String(m[1]) for m in eachmatch(ARXIV_IN_QUERY, q))
    return (filter(id -> !ismissing(paper_id(kb, id)), ids), String(strip(replace(q, ARXIV_IN_QUERY => " "))))
end

"Papers in descending fused score."
ranked_papers(f::Fused) = [p for (p, _) in sort!(collect(f.paper_score); by = last, rev = true)]

"""
    search(kb, q; limit = 10, layers = config's, keyword = config's, category = nothing, since = nothing,
           passages = 3, weights = config's, k = config's, only = nothing, except = (), kinds = nothing) -> Vector{PaperHit}

Hybrid search. Each enabled ranking (keyword BM25 over chunks, plus one vector search per layer)
produces an ordered list of units, and [`fuse`](@ref) combines them: papers by weighted reciprocal
rank fusion, and within a paper its chunks the same way. Papers the query names by arXiv id come
first, as strong as a match can be (see [`named_papers`](@ref)); a query of ids alone is not ranked
otherwise, so nothing is embedded for it. `only`, a set of paper ids, searches among those alone
(a project's library, see [`library_papers`](@ref)); those in `except` are left out (the documents
the caller may not see, see [`hidden_documents`](@ref)). `kinds` names the kinds of document found
(see [`DocumentKind`](@ref): `["paper", "record"]`), `nothing` for any.

`layers` names the vector layers to use (`nothing` for every layer that has vectors) and `keyword`
whether to use the keyword index; both default to the config's `search_layers` and
`search_keyword`.
`category` matches the primary arXiv category by prefix (`"q-bio"`), and `since` is a
year. `weights` and `k` default to the config's `rank_weights` and `rrf_k`.
"""
function search(kb::KB, q::AbstractString; limit::Integer = 10, layers = kb.config.search_layers,
                keyword::Bool = kb.config.search_keyword, category = nothing, since = nothing, passages::Integer = 3,
                weights = kb.config.rank_weights, k::Real = kb.config.rrf_k, only = nothing, except = (), kinds = nothing)
    named, rest = named_papers(kb, q)
    only === nothing || filter!(in(only), named)
    filter!(!in(except), named)
    wanted(id) = kinds === nothing || (kind = document_kind(id); kind !== nothing && kind.name in kinds)
    filter!(wanted, named)
    # Within a set of papers, the rankings reach further down, since most of what they find is left out.
    f = fuse(isempty(rest) && !isempty(named) ? Pair{String,Vector{String}}[] :
             rankings(kb, q; layers, keyword, since, depth = only === nothing ? 60 : 400); weights, k)
    top = f.max_score > 0 ? f.max_score : 1.0
    hits = PaperHit[]
    for paper in [named; [p for p in ranked_papers(f) if !(p in named) && (only === nothing || p in only) && !(p in except) && wanted(p)]]
        length(hits) >= limit && break
        rows = query(kb, "SELECT * FROM papers WHERE doc_id = ?", (paper,))
        isempty(rows) && continue
        p = first(rows)
        by_id = paper in named
        by_id || matches_filter(p, category, since) || continue
        ckeys = sort(get(f.paper_chunks, paper, String[]); by = c -> -f.chunk_score[c])
        label = unit_labeler(kb, p)
        strongest(es) = sort!([Evidence(e.ranking, e.rank, e.unit, e.contribution, label(e.unit)) for e in es];
                              by = e -> -e.contribution)
        ps = [load_passage(kb, p, c, f.chunk_score[c], strongest(f.chunk_evidence[c])) for c in first(ckeys, passages)]
        found = strongest(get(f.paper_evidence, paper, Evidence[]))
        by_id && pushfirst!(found, Evidence("id", 1, "p:$paper", top, "its arXiv id"))
        push!(hits, PaperHit(paper, coalesce(p.title, paper), json_list(p.authors),
            coalesce(p.published, ""), coalesce(p.primary_category, ""), by_id ? top : f.paper_score[paper], top,
            filter(!isnothing, ps), found))
    end
    return hits
end

"""
    unit_labeler(kb, paper) -> (unit key -> String)

Labels for one paper's units, for showing what matched: "title and abstract" (or "paper summary"),
a section's title, or a passage's number and section.
"""
function unit_labeler(kb::KB, p)
    titles = Dict(r.ord => r.title for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ?", (p.id,)))
    chunk_section = Dict(r.ord => r.section for r in query(kb, "SELECT ord, section FROM chunks WHERE paper_id = ?", (p.id,)))
    section_title(ord) = ord == 0 ? "Abstract" : get(titles, ord, "section $ord")
    return function (key)
        parts = split(key, ':')
        parts[1] == "p" && return "the paper"
        n = parse(Int, parts[3])
        parts[1] == "s" && return section_title(n)
        return "passage $(n % CHUNK_STRIDE), " * section_title(get(chunk_section, n, 0))           # a codebase's numbered within its file
    end
end

# What each embedding model is, for people choosing between them.
const MODEL_INFO = Dict(
    "qwen3-embedding:4b" => (; name = "Qwen3 Embedding 4B", note = "the strongest of the local models, and the slowest"),
    "qwen3-embedding:0.6b" => (; name = "Qwen3 Embedding 0.6B", note = "the same family, smaller and several times faster"),
    "nomic-embed-text" => (; name = "nomic-embed-text", note = "the fastest, and the weakest at telling these papers apart"),
    "text-embedding-3-large" => (; name = "OpenAI text-embedding-3-large", note = "a hosted model, on trial"))

model_name(model::AbstractString) = haskey(MODEL_INFO, model) ? MODEL_INFO[model].name : model

"""
    ranking_description(config, name) -> String

A sentence on what a ranking searches: the keyword index, or what a layer embeds and with which
model.
"""
function ranking_description(c::Config, name::AbstractString)
    name == "keyword" && return "BM25 over the text of every passage: finds exact words, names and acronyms, " *
                                "without knowing what they mean."
    i = findfirst(l -> l.name == name, c.layers)
    i === nothing && return ""
    l = c.layers[i]
    what = if !isempty(l.source)
        s = findfirst(x -> x.name == l.source, c.summarizers)
        by = s === nothing ? l.source : c.summarizers[s].model
        l.unit == :paper ? "an LLM's summary of each paper (by $by)" : "an LLM's summary of each section (by $by)"
    else
        Dict(:paper => "each paper's title and abstract", :section => "the text of each section",
             :chunk => "passages of a paragraph or two")[l.unit]
    end
    info = get(MODEL_INFO, l.model, nothing)
    model = info === nothing ? l.model : "$(info.name), $(info.note)"
    return "Embeds $what with $model."
end

"""
    ranking_label(config, name) -> String

A ranking's name for people: `"keyword"`, or a layer as what it embeds and with which model
(`"passages · Qwen3 Embedding 4B"`), and for summaries, whose (`"section summaries by opus · Qwen3
Embedding 4B"`): the summarizer's model, or its name.
"""
function ranking_label(c::Config, name::AbstractString)
    name == "keyword" && return "keyword"
    name == "id" && return "arXiv id"
    i = findfirst(l -> l.name == name, c.layers)
    i === nothing && return String(name)
    l = c.layers[i]
    what = Dict(:paper => "papers", :section => "sections", :chunk => "passages")[l.unit]
    if !isempty(l.source)
        j = findfirst(s -> s.name == l.source, c.summarizers)
        what = replace(what, r"s$" => "") * " summaries by " * (j === nothing ? l.source : c.summarizers[j].model)
    end
    return what * " · " * model_name(l.model)
end

json_list(s) = ismissing(s) ? String[] : String.(JSON.parse(s))

function qdrant_filter(category, since)
    must = Dict[]
    since === nothing || push!(must, Dict("key" => "year", "range" => Dict("gte" => since)))
    isempty(must) ? nothing : Dict("must" => must)
end

function matches_filter(p, category, since)
    category === nothing || startswith(coalesce(p.primary_category, ""), category) || return false
    since === nothing || something(tryparse(Int, first(coalesce(p.published, "0000"), 4)), 0) >= since || return false
    return true
end

function load_passage(kb::KB, p, key, score, evidence)
    ord = parse(Int, split(key, ':')[3])
    rows = query(kb, """
        SELECT c.ord, c.section, c.page_start, c.page_end, c.text, s.path FROM chunks c
        LEFT JOIN sections s ON s.paper_id = c.paper_id AND s.ord = c.section
        WHERE c.paper_id = ? AND c.ord = ?""", (p.id, ord))
    isempty(rows) && return nothing
    r = first(rows)
    section = r.section == 0 ? "Abstract" : coalesce(r.path, "")
    return Passage(r.ord, section, r.page_start, r.page_end, r.text, score, evidence)
end

"""
    similar_papers(kb, doc_id; layer = first paper layer, limit = 10, except = ()) -> Vector{@NamedTuple}

Papers nearest to this one in a paper-level layer, but those in `except`.
"""
function similar_papers(kb::KB, doc_id::AbstractString; layer = nothing, limit::Integer = 10, except = ())
    l = layer === nothing ? kb.config.layers[findfirst(l -> l.unit == :paper, kb.config.layers)] :
        Zemi.layer(kb.config, layer)
    u = only(units(kb, l, doc_id))
    v = query_vector(kb.config, Layer(; name = l.name, model = l.model, unit = l.unit), u.text)
    hits = vector_search(collection_name(kb.config, l), v; limit = limit + 1 + length(except))
    out = []
    for h in hits
        id = split(h.key, ':')[2]
        (id == doc_id || id in except) && continue
        p = paper_row(kb, id)
        push!(out, (doc_id = id, title = coalesce(p.title, id), score = h.score))
    end
    return first(out, limit)
end

"""
    compare_rankings(kb, q; top = 5, layers = nothing) -> Vector{NamedTuple}

The top units of each ranking side by side, for seeing how the keyword index and each layer
differ on the same query. One row per (ranking, rank), with a readable label for the unit.
"""
function compare_rankings(kb::KB, q::AbstractString; top::Integer = 5, layers = nothing, keyword::Bool = true)
    rows = []
    for (name, keys) in rankings(kb, q; layers, keyword, depth = top)
        for (rank, key) in enumerate(first(keys, top))
            push!(rows, (; ranking = name, rank, unit = describe_unit(kb, key)))
        end
    end
    return rows
end

"A short label for a unit key: paper id, section and the start of the text."
function describe_unit(kb::KB, key::AbstractString)
    parts = split(key, ':')
    kind, id = parts[1], parts[2]
    kind == "p" && return "[$id] (whole paper)"
    pid = paper_id(kb, id)
    section_label(ord) = ord == 0 ? "Abstract" :
        coalesce(scalar(kb, "SELECT title FROM sections WHERE paper_id = ? AND ord = ?", (pid, ord)), "?")
    n = parse(Int, parts[3])
    kind == "s" && return "[$id] §$(section_label(n))"
    r = query(kb, "SELECT section, text FROM chunks WHERE paper_id = ? AND ord = ?", (pid, n))
    isempty(r) && return "[$id] chunk $n"
    text = replace(first(r).text, r"\s+" => " ")
    return "[$id] §$(section_label(first(r).section)): $(first(text, 90))…"
end
