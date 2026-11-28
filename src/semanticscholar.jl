# Reference lists fetched for papers: a paper read here has its own, from its text (see
# `paper_references`); one known only by its abstract has the list Semantic Scholar keeps for it, or
# OpenAlex for a work Semantic Scholar does not know. Fetched lists are kept per paper and stand in
# for a list from the text until the paper is read.

const S2_BATCH = "https://api.semanticscholar.org/graph/v1/paper/batch"
const S2_FIELDS = "externalIds,references.externalIds,references.title,references.year,references.authors"
# Papers asked about in one request: Semantic Scholar takes up to 500, but a request's answer is
# limited in size, and a hundred papers' lists stay well within it.
const S2_BATCH_SIZE = 100

migration!(33, [
    """CREATE TABLE fetched_references (
        paper_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        ord INTEGER NOT NULL,
        arxiv TEXT,
        doi TEXT,
        title TEXT NOT NULL DEFAULT '',
        authors TEXT NOT NULL DEFAULT '[]',
        year INTEGER,
        PRIMARY KEY (paper_id, ord))""",
    "CREATE INDEX fetched_references_arxiv ON fetched_references (arxiv)",
    "CREATE INDEX fetched_references_doi ON fetched_references (doi)",
    # Each paper whose list was asked for: where from, when, and how many entries were found (0 for
    # none, which is asked again after `REFETCH_EMPTY`).
    """CREATE TABLE references_fetched (
        paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
        source TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        count INTEGER NOT NULL)"""])

"One entry of a fetched reference list."
const FetchedReference = @NamedTuple{arxiv::Union{String,Nothing}, doi::Union{String,Nothing}, title::String,
                                     authors::Vector{String}, year::Union{Int,Nothing}}

"How long a paper with no list found waits before it is asked about again: lists are added as papers are indexed."
const REFETCH_EMPTY = Day(30)

# A service that fails is left alone for a while, so that recording papers, or a long fetch, does not
# wait on it again for each request; the papers it was not asked about are asked the next time.
const RESTING = Dict{String,DateTime}()
const RESTING_LOCK = ReentrantLock()
"How long a service that failed is left alone."
const REST = Minute(10)
resting(service::AbstractString) = lock(() -> get(RESTING, service, DateTime(0)) > now(UTC), RESTING_LOCK)
rest!(service::AbstractString) = lock(() -> (RESTING[service] = now(UTC) + REST), RESTING_LOCK)

# Text from a service's answer, `nothing` for anything else.
answer_text(x) = x isa AbstractString && !isempty(x) ? String(x) : nothing
answer_year(x) = x isa Integer ? Int(x) : nothing

# What a service answered for each work asked about: its list (empty for none), or `nothing` for a work
# it does not know. A work it was not asked about, or did not answer for, is not there at all.
const Answers = Dict{String,Union{Vector{FetchedReference},Nothing}}

# ── Semantic Scholar ─────────────────────────────────────────────────────────────────────────────

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

# ── OpenAlex ─────────────────────────────────────────────────────────────────────────────────────

"""
    openalex_references(dois; contact = "", get_works = openalex_get) -> (; found, error)

The reference lists OpenAlex keeps for the works with DOIs `dois`, fifty works at a time, as
[`Answers`](@ref) keyed by normalized DOI. OpenAlex names the works cited by its own ids, which are
looked up for their DOIs, titles, authors and years, and their arXiv ids where they are posted there.
A request that fails stops the asking, as for Semantic Scholar ([`s2_references`](@ref)): only the
works whose whole list was looked up are answered.
"""
function openalex_references(dois::AbstractVector{<:AbstractString}; contact::AbstractString = "", get_works = openalex_get)
    found = Answers()
    resting("OpenAlex") && return (; found, error = "OpenAlex failed lately and is not asked for a few minutes")
    asked = unique(normalize_doi.(dois))
    cited = Dict{String,Vector{String}}()
    known = Dict{String,FetchedReference}()
    try
        for batch in Iterators.partition(asked, 50)
            works = get_works(["filter" => "doi:" * join(batch, '|'), "per-page" => "50", "select" => "doi,referenced_works"]; contact)
            works isa AbstractVector || error("an answer of an unexpected form")
            for w in works
                doi = w isa AbstractDict ? answer_text(get(w, "doi", nothing)) : nothing
                doi === nothing && continue
                ids = get(w, "referenced_works", nothing)
                cited[normalize_doi(doi)] = [last(split(u, '/')) for u in (ids isa AbstractVector ? ids : []) if u isa AbstractString]
            end
        end
        for batch in Iterators.partition(unique(reduce(vcat, values(cited); init = String[])), 50)
            works = get_works(["filter" => "openalex_id:" * join(batch, '|'), "per-page" => "50",
                               "select" => "id,doi,title,publication_year,authorships,locations"]; contact)
            works isa AbstractVector || error("an answer of an unexpected form")
            for w in works
                id = w isa AbstractDict ? answer_text(get(w, "id", nothing)) : nothing
                id === nothing || (known[last(split(id, '/'))] = openalex_reference(w))
            end
        end
    catch e
        e isa InterruptException && rethrow()
        rest!("OpenAlex")
        return (; found, error = "OpenAlex: " * failure_message(e))
    end
    for d in asked
        found[d] = haskey(cited, d) ? FetchedReference[known[i] for i in cited[d] if haskey(known, i)] : nothing
    end
    return (; found, error = "")
end

function openalex_reference(w::AbstractDict)
    doi = answer_text(get(w, "doi", nothing))
    doi = doi === nothing ? nothing : normalize_doi(doi)
    arxiv = nothing
    if doi !== nothing && startswith(doi, "10.48550/arxiv.")
        arxiv, doi = doi[length("10.48550/arxiv.")+1:end], nothing
    end
    locations = get(w, "locations", nothing)
    for l in (locations isa AbstractVector ? locations : [])
        arxiv === nothing && l isa AbstractDict || break
        id = parse_arxiv_id(something(answer_text(get(l, "landing_page_url", nothing)), ""))
        id === nothing || (arxiv = id.id)
    end
    authorships = get(w, "authorships", nothing)
    authors = String[n for a in (authorships isa AbstractVector ? authorships : []) if a isa AbstractDict
                     for who in (get(a, "author", nothing),) if who isa AbstractDict
                     for n in (answer_text(get(who, "display_name", nothing)),) if n !== nothing]
    return FetchedReference((arxiv, doi, something(answer_text(get(w, "title", nothing)), ""), authors,
                             answer_year(get(w, "publication_year", nothing))))
end

# ── Keeping them ─────────────────────────────────────────────────────────────────────────────────

"""
    fetch_references!(kb, ids; force = false, s2 = s2_references, openalex = openalex_references,
                      progress, cancelled) -> (; found, unanswered, error)

Fetch the reference lists of the papers `ids` and keep them (see [`fetched_references`](@ref)):
`found` is how many papers a list was found for. Each is asked of Semantic Scholar by its arXiv id or
DOI; a paper it does not know, knows no references of, or did not answer for, is asked of OpenAlex by
its DOI (an arXiv paper's being its arXiv DOI). A paper whose list was found before is skipped unless
`force`, and one both services answered with none for is asked again after [`REFETCH_EMPTY`](@ref).

A service that is down or answers wrongly costs nothing kept: the papers it did not answer for keep
what they had and are asked again next time (`unanswered` of them, `error` saying why). Nothing is
summarized or embedded.
"""
function fetch_references!(kb::KB, ids::AbstractVector{<:AbstractString}; force::Bool = false, s2 = s2_references,
                           openalex = openalex_references, progress = msg -> nothing, cancelled = () -> false)
    since = iso_ago(REFETCH_EMPTY)
    done = Set(String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM references_fetched f JOIN papers p ON p.id = f.paper_id
                                                    WHERE f.count > 0 OR f.fetched_at >= ?""", (since,)))
    asked = Dict{String,String}()                    # each paper by what it is asked under
    for id in unique(ids)
        (force || !(id in done)) || continue
        rows = query(kb, "SELECT doi FROM papers WHERE doc_id = ?", (id,))
        isempty(rows) && continue
        p = first(rows)
        work = is_arxiv_id(id) ? "ARXIV:" * id : ismissing(p.doi) || isempty(p.doi) ? nothing : "DOI:" * normalize_doi(p.doi)
        work === nothing || (asked[id] = work)
    end
    isempty(asked) && return (; found = 0, unanswered = 0, error = "")
    errors = String[]
    key = try
        resolve_key(kb.config.semantic_scholar_key, "semantic_scholar_key")
    catch e                                          # asked without it, as with none
        push!(errors, failure_message(e))
        ""
    end
    progress("Fetching the reference lists of $(length(asked)) paper(s) from Semantic Scholar")
    s = s2(collect(values(asked)); key, progress, cancelled)
    isempty(s.error) || push!(errors, s.error)
    lists = Dict{String,Tuple{String,Vector{FetchedReference}}}()
    none = Set{String}()                             # those Semantic Scholar answered for with no list
    for (id, work) in asked
        haskey(s.found, work) || continue
        refs = s.found[work]
        refs === nothing || isempty(refs) ? push!(none, id) : (lists[id] = ("semanticscholar", refs))
    end
    rest = Dict(id => normalize_doi(startswith(work, "DOI:") ? work[5:end] : "10.48550/arxiv." * id)
                for (id, work) in asked if !haskey(lists, id))
    answered = Set{String}()                         # those OpenAlex answered for
    if !isempty(rest) && !cancelled()
        progress("Asking OpenAlex for $(length(rest)) paper(s) Semantic Scholar has no list for")
        o = openalex(collect(values(rest)); contact = kb.config.contact)
        isempty(o.error) || push!(errors, o.error)
        for (id, doi) in rest
            haskey(o.found, doi) || continue
            push!(answered, id)
            refs = o.found[doi]
            refs === nothing || isempty(refs) || (lists[id] = ("openalex", refs))
        end
    end
    at = now_iso()
    # Kept: the lists found, and "none" for those both services answered for without one.
    kept = [[(id, src, refs) for (id, (src, refs)) in lists]; [(id, "", FetchedReference[]) for id in none if id in answered && !haskey(lists, id)]]
    transaction(kb) do
        for (id, source, refs) in kept
            pid = paper_id(kb, id)
            execute!(kb, "DELETE FROM fetched_references WHERE paper_id = ?", (pid,))
            for (i, r) in enumerate(refs)
                execute!(kb, """INSERT INTO fetched_references (paper_id, ord, arxiv, doi, title, authors, year)
                                VALUES (?, ?, ?, ?, ?, ?, ?)""", (pid, i, r.arxiv, r.doi, r.title, JSON.json(r.authors), r.year))
            end
            execute!(kb, """INSERT INTO references_fetched (paper_id, source, fetched_at, count) VALUES (?, ?, ?, ?)
                            ON CONFLICT (paper_id) DO UPDATE SET source = excluded.source, fetched_at = excluded.fetched_at,
                            count = excluded.count""", (pid, source, at, length(refs)))
        end
    end
    unanswered = length(asked) - length(kept)
    unanswered > 0 && !isempty(errors) && @warn "Reference lists not fetched for $unanswered paper(s): $(join(errors, "; "))"
    return (; found = length(lists), unanswered, error = join(errors, "; "))
end

"""
    references_report(r) -> String

What a [`fetch_references!`](@ref) did, said for a job or the terminal.
"""
references_report(r) = "Reference lists found for $(r.found) paper(s)." *
    (r.unanswered > 0 && !isempty(r.error) ? " $(r.unanswered) not answered, to be asked again next time ($(r.error))." : "")

"The ids of the knowledge base's papers and uploads, those a reference list can be fetched for."
literature_ids(kb::KB) = String[r.id for r in query(kb, "SELECT doc_id AS id FROM papers WHERE $(literature_sql()) ORDER BY doc_id")]

"""
    fetched_references(kb, doc_id) -> Vector{Reference}

The reference list fetched for a paper (see [`fetch_references!`](@ref)), each entry as a reference
list's entry reads, its authors, year and title, with its arXiv id and DOI beside it.
"""
function fetched_references(kb::KB, doc_id::AbstractString)
    rows = query(kb, """SELECT f.ord, f.arxiv, f.doi, f.title, f.authors, f.year FROM fetched_references f
                        JOIN papers p ON p.id = f.paper_id WHERE p.doc_id = ? ORDER BY f.ord""", (doc_id,))
    return [Reference(; label = string(r.ord), text = fetched_text(r), arxiv = coalesce(r.arxiv, nothing), doi = coalesce(r.doi, nothing))
            for r in rows]
end

function fetched_text(r)
    names = json_list(r.authors)
    who = isempty(names) ? "" : length(names) > 3 ? join(names[1:3], ", ") * " et al." : join(names, ", ")
    return join(filter(!isempty, [who * (ismissing(r.year) ? "" : " ($(r.year))"), strip(r.title)]), ". ")
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
