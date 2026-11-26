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

"The fewest words a query has for the passages holding it word for word to be found first (see [`verbatim_ranking`](@ref))."
const VERBATIM_WORDS = 3

"""
    verbatim_ranking(kb, q; limit = 200) -> Vector{String}

The passages holding query `q`'s words in its order, as a phrase (each word as the keyword index
stems it), best first by BM25. None for a query of fewer than `VERBATIM_WORDS` words, too few to
name a passage.
"""
function verbatim_ranking(kb::KB, q::AbstractString; limit::Integer = 200)
    words = [m.match for m in eachmatch(r"[\p{L}\p{N}\p{M}]+", q)]
    length(words) < VERBATIM_WORDS && return String[]
    rows = query(kb, """
        SELECT p.doc_id, c.ord FROM chunks_fts f
        JOIN chunks c ON c.id = f.rowid JOIN papers p ON p.id = c.paper_id
        WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?""", ("text : \"$(join(words, ' '))\"", limit))
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
    # Layers of one model and instruction share the query's vector, embedded once.
    same(l) = (l.url, l.model, l.query_prefix)
    vectors = Dict(same(l) => Threads.@spawn(query_vector(kb.config, l, q)) for l in unique(same, use))
    tasks = [Threads.@spawn begin
                 hits = vector_search(collection_name(kb.config, l), fetch(vectors[same(l)]);
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
    fuse(ranked; weights = nothing, k = RRF_K, groups = nothing, reach = nothing) -> Fused

Weighted reciprocal rank fusion over the output of [`rankings`](@ref). A paper scores
`w / (k + rank)` from each ranking, at the rank of its best unit there; a chunk scores the same
from each ranking it appears in. `weights` maps ranking names (`"keyword"`, layer names) to their
weight: a missing name weighs 1 and a weight of 0 leaves that ranking out. Larger `k` flattens the
difference between the top ranks.

Rankings `groups` puts together (a ranking's name => its group's, see [`ranking_groups`](@ref))
count as one, with the largest of their weights: a paper or chunk scores once from them, at its
best rank in any. With `reach` (a paper => the groups it can be found in, `nothing` for all, see
[`ranking_reach`](@ref)), a paper's score is scaled from the groups it can be in to all of them,
so a ranking that has no units of it is not counted as one that missed it.
"""
function fuse(ranked; weights = nothing, k::Real = RRF_K, groups = nothing, reach = nothing)
    group(name) = groups === nothing ? String(name) : String(get(groups, name, name))
    # Each group's weight, and each paper's and chunk's best (rank, ranking, unit) in it, kept in
    # the order first found.
    weight = Dict{String,Float64}()
    best_paper, best_chunk = Dict{Tuple{String,String},Tuple{Int,String,String}}(), Dict{Tuple{String,String},Tuple{Int,String,String}}()
    papers_found, chunks_found = Tuple{String,String}[], Tuple{String,String}[]
    function better!(best, found, at, rank, name, key)
        b = get(best, at, nothing)
        b === nothing && push!(found, at)
        (b === nothing || rank < b[1]) && (best[at] = (rank, String(name), String(key)))
    end
    for (name, keys) in ranked
        w = weights === nothing ? 1.0 : Float64(get(weights, name, 1.0))
        w > 0 || continue
        g = group(name)
        weight[g] = max(get(weight, g, 0.0), w)
        for (rank, key) in enumerate(keys)
            better!(best_paper, papers_found, (g, unit_paper(key)), rank, name, key)
            startswith(key, "c:") && better!(best_chunk, chunks_found, (g, key), rank, name, key)
        end
    end
    paper_score, paper_evidence = Dict{String,Float64}(), Dict{String,Vector{Evidence}}()
    chunk_score, chunk_evidence = Dict{String,Float64}(), Dict{String,Vector{Evidence}}()
    paper_chunks = Dict{String,Vector{String}}()
    for at in papers_found
        rank, name, key = best_paper[at]
        c = weight[at[1]] / (k + rank)
        paper_score[at[2]] = get(paper_score, at[2], 0.0) + c
        push!(get!(Vector{Evidence}, paper_evidence, at[2]), Evidence(name, rank, key, c))
    end
    for at in chunks_found
        rank, name, key = best_chunk[at]
        c = weight[at[1]] / (k + rank)
        haskey(chunk_score, key) || push!(get!(Vector{String}, paper_chunks, unit_paper(key)), key)
        chunk_score[key] = get(chunk_score, key, 0.0) + c
        push!(get!(Vector{Evidence}, chunk_evidence, key), Evidence(name, rank, key, c))
    end
    total = sum(values(weight); init = 0.0)
    if reach !== nothing
        for (paper, s) in paper_score
            can = reach(paper)
            can === nothing && continue
            w = sum(x for (g, x) in weight if g in can || haskey(best_paper, (g, paper)); init = 0.0)
            w > 0 && (paper_score[paper] = s * total / w)
        end
    end
    return Fused(paper_score, paper_evidence, chunk_score, chunk_evidence, paper_chunks, total / (k + 1))
end

"""
    ranking_groups(layers) -> Dict{String,String}

The rankings search counts as one (see [`fuse`](@ref)): each summary layer (one with a `source`)
=> the layer of the same unit embedding the text itself, of the same model where there is one. A
summary is another view of the unit its text layer embeds, and documents that are not summarized
(records, codebases) are in the one but not the other. `layers` are [`Layer`](@ref)s, or anything
with their `name`, `unit`, `model` and `source`.
"""
function ranking_groups(layers)
    out = Dict{String,String}()
    for l in layers
        isempty(l.source) && continue
        text = [m for m in layers if isempty(m.source) && m.unit == l.unit]
        isempty(text) && continue
        out[l.name] = text[something(findfirst(m -> m.model == l.model, text), 1)].name
    end
    return out
end

"""
    ranking_reach(kb, ranked, groups) -> (paper -> Union{Set{String},Nothing})

The rankings (their groups, see [`ranking_groups`](@ref)) each paper `ranked` found can be found
in: every ranking that is no layer's (keyword), and the layers it has units embedded in. A layer
not yet run over a document, or of a unit it has none of, does not reach it.
"""
function ranking_reach(kb::KB, ranked, groups)
    byname = Dict(l.name => l for l in kb.config.layers)
    group(name) = String(get(groups, name, name))
    always = Set(group(n) for (n, _) in ranked if !haskey(byname, n))
    papers = unique(unit_paper(key) for (_, keys) in ranked for key in keys)
    reached = Dict(p => copy(always) for p in papers)
    isempty(papers) && return p -> get(reached, p, nothing)
    marks = join(fill("?", length(papers)), ", ")
    for (n, _) in ranked
        l = get(byname, n, nothing)
        l === nothing && continue
        u = Dict(:paper => "p", :section => "s", :chunk => "c")[l.unit]
        has = u == "p" ? "e.unit_key = 'p:' || p.doc_id" :
              "e.unit_key >= '$u:' || p.doc_id || ':' AND e.unit_key < '$u:' || p.doc_id || ';'"
        for r in query(kb, """SELECT p.doc_id FROM papers p WHERE p.doc_id IN ($marks)
                              AND EXISTS (SELECT 1 FROM embeddings e WHERE e.layer = ? AND $has)""", (papers..., l.name))
            push!(reached[String(r.doc_id)], group(n))
        end
    end
    return p -> get(reached, p, nothing)
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
rank fusion, and within a paper its chunks the same way. A summary layer counts with the layer of its
unit's text as one ranking, and a document is scored on the rankings that can find it (see
[`ranking_groups`](@ref), [`ranking_reach`](@ref)).

Papers the query names by arXiv id come first, as strong as a match can be (see
[`named_papers`](@ref)); a query of ids alone is not ranked otherwise, so nothing is embedded for
it. Then, as strong, the documents holding the rest of the query word for word, with the passages
that do (see [`verbatim_ranking`](@ref)), when no more than `limit` documents do: with the keyword
index only. `only`, a set of paper ids, searches among those alone
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
    seen(id) = (only === nothing || id in only) && !(id in except) &&
               (kinds === nothing || (kind = document_kind(id); kind !== nothing && kind.name in kinds))
    row(id) = (r = query(kb, "SELECT * FROM papers WHERE doc_id = ?", (id,)); isempty(r) ? nothing : first(r))
    filter!(seen, named)
    # Within a set of papers, the rankings reach further down, since most of what they find is left out.
    ranked = isempty(rest) && !isempty(named) ? Pair{String,Vector{String}}[] :
             rankings(kb, q; layers, keyword, since, depth = only === nothing ? 60 : 400)
    groups = ranking_groups(kb.config.layers)
    f = fuse(ranked; weights, k, groups, reach = ranking_reach(kb, ranked, groups))
    top = f.max_score > 0 ? f.max_score : 1.0
    # The documents holding the query word for word come next, with those passages first: when no
    # more of them than are asked for do, for then the words pick out what was searched for.
    verbatim = Dict{String,Vector{Tuple{Int,String}}}()
    exact = String[]
    for (rank, key) in enumerate(keyword ? verbatim_ranking(kb, rest) : String[])
        paper = unit_paper(key)
        (paper in named || !seen(paper)) && continue
        haskey(verbatim, paper) || push!(exact, paper)
        push!(get!(Vector{Tuple{Int,String}}, verbatim, paper), (rank, key))
    end
    filter!(id -> (p = row(id); p !== nothing && matches_filter(p, category, since)), exact)
    length(exact) > limit && empty!(exact)
    hits = PaperHit[]
    for paper in [named; exact; [p for p in ranked_papers(f) if !(p in named) && !(p in exact) && seen(p)]]
        length(hits) >= limit && break
        p = row(paper)
        p === nothing && continue
        by_id, word_for_word = paper in named, paper in exact
        by_id || matches_filter(p, category, since) || continue
        label = unit_labeler(kb, p)
        strongest(es) = sort!([Evidence(e.ranking, e.rank, e.unit, e.contribution, label(e.unit)) for e in es];
                              by = e -> -e.contribution)
        holding = word_for_word ? Dict(key => Evidence("verbatim", rank, key, top) for (rank, key) in verbatim[paper]) : Dict{String,Evidence}()
        ckeys = unique([word_for_word ? last.(verbatim[paper]) : String[];
                        sort(get(f.paper_chunks, paper, String[]); by = c -> -f.chunk_score[c])])
        ps = map(first(ckeys, passages)) do c
            e = get(f.chunk_evidence, c, Evidence[])
            v = get(holding, c, nothing)
            load_passage(kb, p, c, get(f.chunk_score, c, 0.0) + (v === nothing ? 0.0 : top), strongest(v === nothing ? e : [v; e]))
        end
        found = strongest(get(f.paper_evidence, paper, Evidence[]))
        word_for_word && pushfirst!(found, Evidence("verbatim", first(verbatim[paper])[1], first(verbatim[paper])[2], top,
                                                     label(first(verbatim[paper])[2])))
        by_id && pushfirst!(found, Evidence("id", 1, "p:$paper", top, "its arXiv id"))
        push!(hits, PaperHit(paper, coalesce(p.title, paper), json_list(p.authors),
            coalesce(p.published, ""), coalesce(p.primary_category, ""), by_id || word_for_word ? top : f.paper_score[paper], top,
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
    name == "verbatim" && return "word for word"
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

Papers nearest to this one in a paper-level layer, but those in `except`; none for a paper with no
title or abstract yet.
"""
function similar_papers(kb::KB, doc_id::AbstractString; layer = nothing, limit::Integer = 10, except = ())
    l = layer === nothing ? kb.config.layers[findfirst(l -> l.unit == :paper, kb.config.layers)] :
        Zemi.layer(kb.config, layer)
    us = units(kb, l, doc_id)
    isempty(us) && return []                     # known by its id alone: nothing to be near
    u = only(us)
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
