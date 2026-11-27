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

# ── Semantic Scholar ─────────────────────────────────────────────────────────────────────────────

"""
    s2_references(ids; key = "", post = s2_post) -> Dict{String,Union{Vector{FetchedReference},Nothing}}

The reference lists Semantic Scholar keeps for the works `ids` (its ids: `ARXIV:2401.00001`,
`DOI:10.…`), asked a hundred at a time, a second apart; `nothing` for a work it does not know. `key`
is a Semantic Scholar API key; without one, requests share its public allowance and are slower to be
answered when it is busy.
"""
function s2_references(ids::AbstractVector{<:AbstractString}; key::AbstractString = "", post = s2_post,
                       progress = msg -> nothing, cancelled = () -> false)
    out = Dict{String,Union{Vector{FetchedReference},Nothing}}()
    batches = collect(Iterators.partition(ids, S2_BATCH_SIZE))
    for (n, batch) in enumerate(batches)
        cancelled() && break
        n > 1 && sleep(1.1)
        length(batches) > 1 && progress("Semantic Scholar: $(n) of $(length(batches)) requests")
        for (id, p) in zip(batch, post(collect(batch); key))
            out[id] = p === nothing ? nothing : FetchedReference[s2_reference(r) for r in something(get(p, "references", nothing), [])]
        end
    end
    return out
end

"One request of [`s2_references`](@ref): Semantic Scholar's records of `ids`, in order, `nothing` for those it lacks."
function s2_post(ids::AbstractVector{<:AbstractString}; key::AbstractString = "")
    headers = ["Content-Type" => "application/json"]
    isempty(key) || push!(headers, "x-api-key" => key)
    r = with_retry("Semantic Scholar"; tries = 3, patience = 180, pause = 2.0) do
        HTTP.post(S2_BATCH, headers, JSON.json(Dict("ids" => ids)); query = ["fields" => S2_FIELDS], retry = false,
                  connect_timeout = 20, readtimeout = 120)
    end
    return JSON.parse(body_text(r.body))
end

# An entry of Semantic Scholar's list. An arXiv DOI names no more than the arXiv id does, and is left out.
function s2_reference(r::AbstractDict)
    ext = something(get(r, "externalIds", nothing), Dict())
    arxiv, doi = get(ext, "ArXiv", nothing), get(ext, "DOI", nothing)
    doi = doi === nothing || startswith(lowercase(doi), "10.48550/") ? nothing : normalize_doi(doi)
    year = get(r, "year", nothing)
    return FetchedReference((arxiv === nothing ? nothing : String(arxiv), doi, String(something(get(r, "title", nothing), "")),
                             String[a["name"] for a in something(get(r, "authors", nothing), []) if get(a, "name", nothing) !== nothing],
                             year isa Integer ? Int(year) : nothing))
end

# ── OpenAlex ─────────────────────────────────────────────────────────────────────────────────────

"""
    openalex_references(dois; contact = "") -> Dict{String,Union{Vector{FetchedReference},Nothing}}

The reference lists OpenAlex keeps for the works with DOIs `dois`, fifty works at a time; `nothing`
for a work it does not know. OpenAlex names the works cited by its own ids, which are looked up for
their DOIs, titles, authors and years, and their arXiv ids where they are posted there.
"""
function openalex_references(dois::AbstractVector{<:AbstractString}; contact::AbstractString = "", get_works = openalex_get)
    cited = Dict{String,Vector{String}}()
    for batch in Iterators.partition(unique(normalize_doi.(dois)), 50)
        for w in get_works(["filter" => "doi:" * join(batch, '|'), "per-page" => "50", "select" => "doi,referenced_works"]; contact)
            w["doi"] === nothing && continue
            cited[normalize_doi(w["doi"])] = [last(split(String(u), '/')) for u in something(w["referenced_works"], [])]
        end
    end
    known = Dict{String,FetchedReference}()
    for batch in Iterators.partition(unique(reduce(vcat, values(cited); init = String[])), 50)
        for w in get_works(["filter" => "openalex_id:" * join(batch, '|'), "per-page" => "50",
                            "select" => "id,doi,title,publication_year,authorships,locations"]; contact)
            known[last(split(String(w["id"]), '/'))] = openalex_reference(w)
        end
    end
    return Dict{String,Union{Vector{FetchedReference},Nothing}}(
        normalize_doi(d) => (haskey(cited, normalize_doi(d)) ? FetchedReference[known[i] for i in cited[normalize_doi(d)] if haskey(known, i)] : nothing)
        for d in dois)
end

function openalex_reference(w::AbstractDict)
    doi = w["doi"] === nothing ? nothing : normalize_doi(w["doi"])
    arxiv = nothing
    if doi !== nothing && startswith(doi, "10.48550/arxiv.")
        arxiv, doi = doi[length("10.48550/arxiv.")+1:end], nothing
    end
    for l in something(get(w, "locations", nothing), [])
        arxiv === nothing || break
        id = parse_arxiv_id(something(get(l, "landing_page_url", nothing), ""))
        id === nothing || (arxiv = id.id)
    end
    authors = String[a["author"]["display_name"] for a in something(get(w, "authorships", nothing), [])
                     if get(something(get(a, "author", nothing), Dict()), "display_name", nothing) !== nothing]
    year = get(w, "publication_year", nothing)
    return FetchedReference((arxiv, doi, String(something(get(w, "title", nothing), "")), authors, year isa Integer ? Int(year) : nothing))
end

# ── Keeping them ─────────────────────────────────────────────────────────────────────────────────

"""
    fetch_references!(kb, ids; force = false, s2 = s2_references, openalex = openalex_references,
                      progress, cancelled) -> Int

Fetch the reference lists of the papers `ids` and keep them (see [`fetched_references`](@ref)),
returning how many papers a list was found for. Each is asked of Semantic Scholar by its arXiv id or
DOI; a paper it does not know, or knows no references of, is asked of OpenAlex by its DOI (an arXiv
paper's being its arXiv DOI). A paper whose list was found before is skipped unless `force`, and one
with none found is asked again after [`REFETCH_EMPTY`](@ref). Nothing is summarized or embedded.
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
    isempty(asked) && return 0
    progress("Fetching the reference lists of $(length(asked)) paper(s) from Semantic Scholar")
    found = s2(collect(values(asked)); key = resolve_key(kb.config.semantic_scholar_key, "semantic_scholar_key"), progress, cancelled)
    lists = Dict{String,Tuple{String,Vector{FetchedReference}}}()
    for (id, work) in asked
        refs = get(found, work, nothing)
        refs === nothing || isempty(refs) || (lists[id] = ("semanticscholar", refs))
    end
    rest = Dict(id => (startswith(work, "DOI:") ? work[5:end] : "10.48550/arxiv." * lowercase(id))
                for (id, work) in asked if !haskey(lists, id))
    if !isempty(rest) && !cancelled()
        progress("Asking OpenAlex for $(length(rest)) paper(s) Semantic Scholar has no list for")
        more = try
            openalex(collect(values(rest)); contact = kb.config.contact)
        catch e
            e isa InterruptException && rethrow()
            @warn "OpenAlex could not be asked for reference lists" exception = e
            Dict{String,Any}()
        end
        for (id, doi) in rest
            refs = get(more, normalize_doi(doi), nothing)
            refs === nothing || isempty(refs) || (lists[id] = ("openalex", refs))
        end
    end
    at = now_iso()
    transaction(kb) do
        for id in keys(asked)
            pid = paper_id(kb, id)
            source, refs = get(lists, id, ("", FetchedReference[]))
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
    return length(lists)
end

"The ids of the knowledge base's papers and uploads, those a reference list can be fetched for."
literature_ids(kb::KB) = String[r.id for r in query(kb, "SELECT doc_id AS id FROM papers WHERE $(literature_sql()) ORDER BY doc_id")]

"""
    fetched_references(kb, doc_id) -> Vector{Reference}

The reference list fetched for a paper (see [`fetch_references!`](@ref)), each entry as a reference
list's entry reads: its authors, year and title, and its arXiv id or DOI.
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
    parts = filter(!isempty, [who * (ismissing(r.year) ? "" : " ($(r.year))"), strip(r.title),
                              ismissing(r.arxiv) ? "" : "arXiv:" * r.arxiv, ismissing(r.doi) ? "" : "doi:" * r.doi])
    return join(parts, ". ")
end
