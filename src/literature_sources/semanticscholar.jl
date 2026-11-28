const S2_BATCH = "https://api.semanticscholar.org/graph/v1/paper/batch"
const S2_FIELDS = "externalIds,references.externalIds,references.title,references.year,references.authors"
# Papers asked about in one request: Semantic Scholar takes up to 500, but a request's answer is
# limited in size, and a hundred papers' lists stay well within it.
const S2_BATCH_SIZE = 100

"""
    s2_references(ids; key = "", post = s2_post, progress, cancelled) -> (; found, error)

The reference lists Semantic Scholar keeps for the works `ids` (its ids: `ARXIV:2401.00001`,
`DOI:10.…`), asked a hundred at a time, a second apart, as [`Answers`](@ref). A request that fails,
or is answered in an unexpected form, stops the asking: `error` says why, the works not yet answered
are left out, and Semantic Scholar is left alone for [`REST`](@ref). `key` is a Semantic Scholar API
key; without one, requests share its public allowance and are slower to be answered when it is busy.
"""
function s2_references(ids::AbstractVector{<:AbstractString}; key::AbstractString = "", post = s2_post,
                       progress = msg -> nothing, cancelled = () -> false)
    found = Answers()
    resting("Semantic Scholar") && return (; found, error = "Semantic Scholar failed lately and is not asked for a few minutes")
    batches = collect(Iterators.partition(ids, S2_BATCH_SIZE))
    for (n, batch) in enumerate(batches)
        cancelled() && break
        n > 1 && sleep(1.1)
        length(batches) > 1 && progress("Semantic Scholar: $(n) of $(length(batches)) requests")
        got = try
            s2_answer(post(collect(batch); key), length(batch))
        catch e
            e isa InterruptException && rethrow()
            rest!("Semantic Scholar")
            return (; found, error = "Semantic Scholar: " * failure_message(e))
        end
        merge!(found, Dict(zip(batch, got)))
    end
    return (; found, error = "")
end

"One request of [`s2_references`](@ref): Semantic Scholar's answer for `ids`, as it came."
function s2_post(ids::AbstractVector{<:AbstractString}; key::AbstractString = "")
    headers = ["Content-Type" => "application/json"]
    isempty(key) || push!(headers, "x-api-key" => key)
    r = with_retry("Semantic Scholar"; tries = 2, patience = 60, pause = 2.0) do
        HTTP.post(S2_BATCH, headers, JSON.json(Dict("ids" => ids)); query = ["fields" => S2_FIELDS], retry = false,
                  connect_timeout = 20, read_idle_timeout = 60)
    end
    return JSON.parse(body_text(r.body))
end

# Semantic Scholar's answer for `n` works: a list of `n`, each a record or null. Any other form is an
# error; a record without a list of references has none.
function s2_answer(answer, n::Integer)
    answer isa AbstractVector && length(answer) == n || error("an answer of an unexpected form")
    return map(answer) do p
        p isa AbstractDict || return nothing
        refs = get(p, "references", nothing)
        refs isa AbstractVector ? FetchedReference[s2_reference(r) for r in refs if r isa AbstractDict] : FetchedReference[]
    end
end

# An entry of Semantic Scholar's list. An arXiv DOI names no more than the arXiv id does, and is left out.
function s2_reference(r::AbstractDict)
    ext = get(r, "externalIds", nothing)
    ext isa AbstractDict || (ext = Dict())
    arxiv, doi = answer_text(get(ext, "ArXiv", nothing)), answer_text(get(ext, "DOI", nothing))
    doi = doi === nothing || startswith(lowercase(doi), "10.48550/") ? nothing : normalize_doi(doi)
    authors = get(r, "authors", nothing)
    names = String[n for a in (authors isa AbstractVector ? authors : []) if a isa AbstractDict
                   for n in (answer_text(get(a, "name", nothing)),) if n !== nothing]
    return FetchedReference((arxiv, doi, something(answer_text(get(r, "title", nothing)), ""), names, answer_year(get(r, "year", nothing))))
end

const RECOMMENDATION_ORIGIN = "Semantic Scholar recommendations"

# Only the bibliographic identifiers an administrator selects leave the instance.
function recommendation_seed(value)
    value = strip(value)
    occursin(r"^[a-fA-F0-9]{40}$", value) && return lowercase(value)
    m = match(r"^CorpusId:(\d+)$"i, value)
    m === nothing || return "CorpusId:" * m[1]
    arxiv = parse_arxiv_id(value)
    arxiv === nothing || return "ARXIV:" * arxiv.id
    doi = parse_doi(value)
    doi === nothing || return "DOI:" * doi
    error("[watch] a recommendation seed must be a DOI, arXiv ID, CorpusId or Semantic Scholar paper ID")
end

recommendation_seeds(c) = (; positive = unique(recommendation_seed.(c.watch_recommend_like)),
                             negative = unique(recommendation_seed.(c.watch_recommend_avoid)))

function s2_recommendations(seeds; key, limit)
    endpoint = "https://api.semanticscholar.org/recommendations/v1/papers/"
    fields = "title,abstract,publicationDate,year,venue,authors,externalIds,url"
    headers = ["Content-Type" => "application/json"]
    isempty(key) || push!(headers, "x-api-key" => key)
    body = JSON.json((; positivePaperIds = seeds.positive, negativePaperIds = seeds.negative))
    response = with_retry("Semantic Scholar recommendations"; tries = 2, patience = 30, pause = 2.0) do
        HTTP.post(endpoint, headers, body; query = ["fields" => fields, "limit" => string(limit)], retry = false,
                  connect_timeout = 10, response_header_timeout = 30, read_idle_timeout = 30)
    end
    return JSON.parse(body_text(response.body))
end

function recommended_watch(kb; cancelled = () -> false, progress = msg -> nothing, post = s2_recommendations)
    c = kb.config
    (isempty(c.watch_recommend_like) || cancelled()) && return []
    seeds = recommendation_seeds(c)
    found = []
    try
        key = resolve_key(c.semantic_scholar_key, "semantic_scholar_key")
        result = post(seeds; key, limit = c.watch_recommend_limit)
        papers = result["recommendedPapers"]
        papers isa AbstractVector || error("unexpected recommendations response")
        for paper in Iterators.take(papers, c.watch_recommend_limit)
            cancelled() && break
            paper isa AbstractDict || continue
            id = answer_text(get(paper, "paperId", nothing))
            (id === nothing || !occursin(r"^[a-fA-F0-9]{40}$", id)) && continue
            ref = s2_reference(paper)
            isempty(strip(ref.title)) && continue
            url = something(watch_url(get(paper, "url", nothing)), "https://www.semanticscholar.org/paper/$id")
            arxiv = parse_arxiv_id(something(ref.arxiv, ""))
            doi = parse_doi(something(ref.doi, ""))
            published = something(answer_text(get(paper, "publicationDate", nothing)),
                                  ref.year === nothing ? "" : string(ref.year))
            push!(found, linked_candidate(; url, key = "s2:" * lowercase(id), ref.title, ref.authors,
                abstract = something(answer_text(get(paper, "abstract", nothing)), ""), published,
                category = something(answer_text(get(paper, "venue", nothing)), ""), origin = RECOMMENDATION_ORIGIN,
                doi, arxiv = arxiv === nothing ? nothing : arxiv.id))
        end
    catch e
        e isa InterruptException && rethrow()
        progress("Skipped Semantic Scholar recommendations: $(failure_message(e))")
    end
    return found
end
