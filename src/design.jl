# The knowledge base as a design problem: what each layer costs to build and to query, measured on
# this machine, and what a choice of layers and fusion weights buys in retrieval quality at what
# cost for a whole corpus. `design_point` is the model a design campaign evaluates.

"""
    LayerCost

What one layer costs, measured: embedding time per paper, query time (embedding the question and
searching the collection), and vectors and bytes stored per paper.
"""
Base.@kwdef struct LayerCost
    layer::String
    unit::Symbol
    model::String
    source::String
    seconds_per_paper::Float64
    query_ms::Float64
    vectors_per_paper::Float64
    bytes_per_paper::Float64
    context_chars::Int
end

"""
    SummaryCost

What one summarizer costs per paper, from the token counts recorded with its summaries and its
prices, and roughly how long a paper takes (from when its first and last summaries were written).
"""
Base.@kwdef struct SummaryCost
    summarizer::String
    dollars_per_paper::Float64
    seconds_per_paper::Float64
end

"""
    DesignData

Everything a design point is computed from: the probe questions' rankings (for quality) and the
measured costs.
"""
Base.@kwdef struct DesignData
    probes::Vector{ProbeRankings}
    layers::Dict{String,LayerCost}
    summaries::Dict{String,SummaryCost}
    keyword_ms::Float64
    fetch_seconds_per_paper::Float64
    parse_seconds_per_paper::Float64
end

# Context windows of the embedding models, in tokens; about four characters a token.
const MODEL_CONTEXT_TOKENS = Dict("qwen3-embedding:4b" => 32768, "qwen3-embedding:0.6b" => 32768,
                                  "nomic-embed-text" => 2048, "text-embedding-3-large" => 8191)

median_of(xs) = (s = sort(collect(xs)); isempty(s) ? 0.0 : s[(length(s) + 1) ÷ 2])

"""
    measure_design_data(kb, probes; ids = a few ingested papers, progress = msg -> nothing) -> DesignData

Measure what the knowledge base costs on this machine. Each layer's model re-embeds the units of
`ids` (nothing is stored) for its time per paper, and embeds and searches a few questions for its
query time. Vector and byte counts come from what is stored across the whole knowledge base; LLM
cost from the recorded tokens and the summarizers' prices. Fetching a paper is counted at the
arXiv request interval, which is what limits it.
"""
function measure_design_data(kb::KB, probes::Vector{ProbeRankings};
                             ids = nothing, progress = msg -> nothing)
    parsed = [r.doc_id for r in query(kb, "SELECT p.doc_id FROM parses x JOIN papers p ON p.id = x.paper_id ORDER BY p.doc_id")]
    ids = something(ids, first(parsed, 5))
    stored = Dict(r.layer => (; r.n, r.papers) for r in query(kb,
        "SELECT layer, count(*) AS n, count(DISTINCT paper_id) AS papers FROM embeddings GROUP BY layer"))
    dims = Dict(r.name => r.dim for r in query(kb, "SELECT name, dim FROM layers"))
    questions = ["How does the method's error scale with the size of the problem?",
                 "Which measurements were used to validate the model?",
                 "What limits how far the results can be generalized?"]
    layers = Dict{String,LayerCost}()
    for l in kb.config.layers
        haskey(stored, l.name) && haskey(dims, l.name) || continue
        progress("timing $(l.name)")
        texts = [u.text for id in ids for u in units(kb, l, id)]
        isempty(texts) && continue
        embed(kb.config, l, texts[1:1])                    # load the model before timing
        t = @elapsed embed(kb.config, l, texts)
        coll = collection_name(kb.config, l)
        qt = map(questions) do q
            1000 * @elapsed vector_search(coll, only(embed(kb.config, l, [l.query_prefix * q * " $(rand(UInt16))"])); limit = 60)
        end
        n, papers = stored[l.name]
        layers[l.name] = LayerCost(; layer = l.name, unit = l.unit, model = l.model, source = l.source,
            seconds_per_paper = t / length(ids), query_ms = median_of(qt),
            vectors_per_paper = n / papers, bytes_per_paper = n / papers * dims[l.name] * 4,
            context_chars = 4 * get(MODEL_CONTEXT_TOKENS, l.model, 2048))
    end
    progress("timing keyword search and parsing")
    keyword_ms = median_of(1000 * @elapsed(keyword_ranking(kb, q)) for q in questions)
    files = [first(r).path for id in ids for r in (query(kb, "SELECT path FROM files f JOIN papers p ON p.id = f.paper_id WHERE p.doc_id = ?", (id,)),) if !isempty(r)]
    parse_s = isempty(files) ? 0.0 : sum(f -> @elapsed(parse_pdf(f, kb.config)), files) / length(files)

    summaries = Dict{String,SummaryCost}()
    for s in kb.config.summarizers
        rows = query(kb, """SELECT paper_id, sum(input_tokens) AS tin, sum(output_tokens) AS tout,
                            min(created_at) AS t0, max(created_at) AS t1
                            FROM summaries WHERE summarizer = ? GROUP BY paper_id""", (s.name,))
        isempty(rows) && continue
        dollars = sum(r -> (coalesce(r.tin, 0) * s.price_in + coalesce(r.tout, 0) * s.price_out) / 1e6, rows) / length(rows)
        seconds = median_of(Dates.value(parse_iso(r.t1) - parse_iso(r.t0)) / 1000 for r in rows)
        summaries[s.name] = SummaryCost(; summarizer = s.name, dollars_per_paper = dollars, seconds_per_paper = seconds)
    end
    return DesignData(; probes, layers, summaries, keyword_ms,
        fetch_seconds_per_paper = ARXIV_INTERVAL, parse_seconds_per_paper = parse_s)
end

"""
    design_point(d; weights, k = RRF_K, corpus = 492, threshold = 0.05) -> NamedTuple

Retrieval quality and whole-corpus cost of one knowledge base design: how each ranking (keyword
and each layer) is weighted in search. A weight below `threshold` drops the ranking, and with it
the layer's embedding time, storage and query time; summary layers bring their summarizer's LLM
cost, paid once however many layers read its summaries.

Grouped by subsystem (`ingest`, `summarize`, `embed`, `store`, `search`), with the totals a
requirement reads at the top level: `mrr_broad`, `mrr_specific`, `hit5_specific`, `ingest_hours`,
`llm_dollars`, `storage_gb`, `query_ms`, `rankings_used`. Query time assumes the rankings run one
after another, an upper bound (search runs them concurrently).
"""
function design_point(d::DesignData; weights, k::Real = RRF_K, corpus::Integer = 492, threshold::Real = 0.05)
    w = Dict{String,Float64}(String(n) => (x >= threshold ? Float64(x) : 0.0) for (n, x) in pairs(weights))
    used = sort!([n for (n, x) in w if x > 0])
    q = score_ranking(d.probes; weights = w, k)
    layers = [d.layers[n] for n in used if haskey(d.layers, n)]
    sources = unique(c.source for c in layers if !isempty(c.source))
    per_paper(f, xs) = sum(f, xs; init = 0.0)
    embed_s = per_paper(c -> c.seconds_per_paper, layers)
    llm_s = per_paper(s -> d.summaries[s].seconds_per_paper, filter(in(keys(d.summaries)), sources))
    dollars = per_paper(s -> d.summaries[s].dollars_per_paper, filter(in(keys(d.summaries)), sources))
    fetch_parse_s = d.fetch_seconds_per_paper + d.parse_seconds_per_paper
    hours(s) = corpus * s / 3600
    query_ms = per_paper(c -> c.query_ms, layers) + (get(w, "keyword", 0.0) > 0 ? d.keyword_ms : 0.0)
    storage_gb = corpus * per_paper(c -> c.bytes_per_paper, layers) / 1e9
    ingest_hours = hours(fetch_parse_s + llm_s + embed_s)
    return (;
        ingest = (; hours = hours(fetch_parse_s), max_passage_chars = CHUNK_MAX),
        summarize = (; hours = hours(llm_s), dollars = corpus * dollars, summarizers = length(sources)),
        embed = (; hours = hours(embed_s), layers = length(layers),
                   min_context_chars = minimum((c.context_chars for c in layers); init = typemax(Int))),
        store = (; gb = storage_gb),
        search = (; q.mrr_broad, q.hit1_broad, q.hit5_broad, q.mrr_specific, q.hit1_specific, q.hit5_specific, query_ms),
        q.mrr_broad, q.mrr_specific, q.hit5_specific, q.mrr,
        ingest_hours, llm_dollars = corpus * dollars, storage_gb, query_ms, rankings_used = length(used))
end
