# OpenAlex, the open catalogue of scholarly works: the published record of an uploaded paper (see
# `lookup_upload`), and where the works the papers cite are posted (see `find_on_arxiv!`).

const OPENALEX_WORKS = "https://api.openalex.org/works"

"""
    openalex_get(query; contact = "", timeout = 30) -> Vector

The works OpenAlex finds for `query` (its parameters), asked as [`with_retry`](@ref) does: a busy
spell waited out for a while, a failure tried once more. `contact`, an email address, identifies the caller. OPENALEX_API_KEY authenticates paginated requests.
"""
function openalex_get(query::AbstractVector; contact::AbstractString = "", timeout::Real = 30)
    return openalex_page(query; contact, timeout)["results"]
end

function openalex_page(query; contact = "", timeout = 30)
    key = get(ENV, "OPENALEX_API_KEY", "")
    headers = isempty(key) ? Pair{String,String}[] : ["Authorization" => "Bearer $key"]
    isempty(contact) || (query = [query; "mailto" => contact])
    r = with_retry("OpenAlex"; tries = 2, patience = 30) do
        HTTP.get(OPENALEX_WORKS, headers; query, retry = false, connect_timeout = 20, response_header_timeout = timeout,
                 read_idle_timeout = timeout)
    end
    return JSON.parse(body_text(r.body))
end

"""
    openalex_work(; doi = nothing, title = nothing, contact = "") -> Union{AbstractDict,Nothing}

OpenAlex's record of a work, by its DOI or by its exact title, or `nothing` when it has none.
`contact`, an email address, identifies the caller.
"""
function openalex_work(; doi = nothing, title = nothing, contact::AbstractString = "")
    query = doi !== nothing ? ["filter" => "doi:" * doi] : ["filter" => "title.search:" * replace(title, r"[,:|]" => " ")]
    push!(query, "per-page" => "5",
          "select" => "doi,title,type,authorships,publication_year,primary_location,biblio,abstract_inverted_index")
    works = openalex_get(query; contact, timeout = 30)
    doi === nothing || return isempty(works) ? nothing : first(works)
    i = findfirst(w -> same_title(something(w["title"], ""), title), works)
    return i === nothing ? nothing : works[i]
end

"OpenAlex's kinds of work that are no paper: a journal's own entry, a dataset, a grant and the like."
const NOT_PAPERS = ("paratext", "dataset", "grant", "standard", "libguides", "supplementary-materials", "peer-review", "erratum")

"""
Whether an OpenAlex work is a paper: not one of [`NOT_PAPERS`](@ref), and not a journal's own record,
which has the journal's name for its title or an ISSN for its DOI.
"""
function is_paper(w::AbstractDict)
    get(w, "type", nothing) in NOT_PAPERS && return false
    occursin("/issn.", lowercase(something(get(w, "doi", nothing), ""))) && return false
    source = something(get(something(get(w, "primary_location", nothing), Dict()), "source", nothing), Dict())
    journal = something(get(source, "display_name", nothing), "")
    return isempty(journal) || !same_title(something(get(w, "title", nothing), ""), journal)
end

"An OpenAlex work as the fields a paper's record keeps."
function work_record(w::AbstractDict)
    authors = String[]
    orcids = Union{String,Nothing}[]
    for entry in something(w["authorships"], [])
        author = get(entry, "author", nothing)
        name = get(something(author, Dict()), "display_name", nothing)
        raw = get(entry, "raw_author_name", nothing)
        name = raw isa String && !isempty(strip(raw)) ? raw : name
        name === nothing && continue
        push!(authors, name)
        # The identifier recorded on this work. An OpenAlex author profile may instead
        # have acquired an identifier by disambiguation across other works.
        push!(orcids, orcid_uri(get(entry, "raw_orcid", nothing)))
    end
    source = something(get(something(w["primary_location"], Dict()), "source", nothing), Dict())
    journal, b, year = get(source, "display_name", nothing), something(w["biblio"], Dict()), w["publication_year"]
    ref = journal === nothing ? nothing :
        journal * (get(b, "volume", nothing) === nothing ? "" : " " * b["volume"]) *
        (get(b, "first_page", nothing) === nothing ? "" : ", " * b["first_page"]) * (year === nothing ? "" : " ($year)")
    words = Pair{Int,String}[]
    for (word, at) in something(w["abstract_inverted_index"], Dict()), i in at
        push!(words, i => word)
    end
    abstract = isempty(words) ? nothing : join(last.(sort!(words; by = first)), " ")
    doi = w["doi"] === nothing ? nothing : normalize_doi(w["doi"])
    return (; title = String(w["title"]), authors, orcids, year = year === nothing ? nothing : string(year), journal, journal_ref = ref, doi, abstract)
end

"""
    doi_copies(doi; contact = "") -> (; arxiv, pdfs)

Where OpenAlex knows a copy of the work with DOI `doi` to read: its arXiv id (`nothing` for none), and
the addresses of the open PDFs of it, its best open copy's first.
"""
function doi_copies(doi::AbstractString; contact::AbstractString = "")
    works = openalex_get(["filter" => "doi:" * doi, "per-page" => "1", "select" => "doi,locations,best_oa_location"]; contact)
    isempty(works) && return (; arxiv = nothing, pdfs = String[])
    w = first(works)
    locations = AbstractDict[l for l in [something(get(w, "best_oa_location", nothing), Dict()); something(w["locations"], [])] if !isempty(l)]
    arxiv = nothing
    for l in locations
        id = parse_arxiv_id(something(get(l, "landing_page_url", nothing), ""))
        id === nothing || (arxiv = id.id; break)
    end
    pdfs = unique!([String(l["pdf_url"]) for l in locations if get(l, "is_oa", false) === true && get(l, "pdf_url", nothing) !== nothing])
    return (; arxiv, pdfs)
end

"Where a DOI's copies are looked up (see [`doi_copies`](@ref)); tests put a stand-in here."
const DOI_COPIES = Ref{Function}(doi_copies)

"OpenAlex's kinds of work as a resource's type names them, for the bibliography's entries (see `RESOURCE_ENTRIES`)."
const OPENALEX_TYPES = Dict("article" => "article", "review" => "article", "letter" => "article", "editorial" => "article",
                            "conference-paper" => "conference paper", "book-chapter" => "book section", "book" => "book",
                            "report" => "report", "dissertation" => "thesis", "preprint" => "preprint")

"""
    doi_resource(doi; contact = "") -> Union{Resource,Nothing}

The work with DOI `doi` as a resource (see [`Resource`](@ref)), from OpenAlex's record: its title,
authors, year, type, the journal, proceedings or book it appeared in and its publisher, its `doi.org`
address, and its abstract where OpenAlex has one, as its note. `nothing` when OpenAlex does not know it.
"""
function doi_resource(doi::AbstractString; contact::AbstractString = "")
    w = openalex_work(; doi, contact)
    (w === nothing || w["title"] === nothing) && return nothing
    r = work_record(w)
    source = something(get(something(w["primary_location"], Dict()), "source", nothing), Dict())
    return Resource(; key = doi, title = r.title, authors = r.authors, date = something(r.year, ""), doi,
                    type = get(OPENALEX_TYPES, something(get(w, "type", nothing), ""), "document"),
                    url = "https://doi.org/" * doi, note = something(r.abstract, ""),
                    container = something(r.journal, ""), publisher = something(get(source, "host_organization_name", nothing), ""))
end

"Where a DOI's record is looked up as a resource (see [`doi_resource`](@ref)); tests put a stand-in here."
const DOI_RESOURCE = Ref{Function}(doi_resource)

"""
    openalex_arxiv(dois, contact = "") -> Dict{String,Union{String,Nothing}}

What each of `dois` (at most 50) is on arXiv as, by OpenAlex's record of where the work is posted:
an arXiv id, or `nothing` when OpenAlex knows the work but not on arXiv. A DOI OpenAlex does not
know is left out. `contact`, an email address, identifies the caller.
"""
function openalex_arxiv(dois::AbstractVector{<:AbstractString}, contact::AbstractString = "")
    query = ["filter" => "doi:" * join(dois, '|'), "per-page" => "50", "select" => "doi,locations"]
    works = openalex_get(query; contact, timeout = 60)
    out = Dict{String,Union{String,Nothing}}()
    for w in works
        doi = normalize_doi(something(w["doi"], ""))
        isempty(doi) && continue
        found = nothing
        for l in something(w["locations"], [])
            id = parse_arxiv_id(something(get(l, "landing_page_url", nothing), ""))
            id === nothing || (found = id.id; break)
        end
        out[doi] = found
    end
    return out
end


# Each result uses the same title/abstract placement as an arXiv discovery.
const WATCH_WORK_FIELDS = "id,doi,title,type,publication_date,publication_year,authorships,primary_location,locations,biblio,abstract_inverted_index,referenced_works"

function watch_work(w, reason)
    is_paper(w) && !isempty(something(get(w, "title", nothing), "")) || return nothing
    ref = openalex_reference(w)
    work_id = watch_url(get(w, "id", nothing))
    landing = watch_url(get(something(w["primary_location"], Dict()), "landing_page_url", nothing))
    url = something(landing, work_id, Some(nothing))
    url === nothing && ref.arxiv === nothing && ref.doi === nothing && return nothing
    r = work_record(w)
    id = ref.arxiv !== nothing ? ref.arxiv : ref.doi !== nothing ? ref.doi : watch_resource_id(url)
    return (; doc_id = id, r.title, r.authors, abstract = something(r.abstract, ""),
            published = something(w["publication_date"], ""), primary_category = something(r.journal, ""),
            doi = ref.doi, work_id, origins = [reason], url, aliases = unique(String[k for k in (landing, work_id) if k !== nothing]))
end

"Published identifiers for the group's literature whose incoming citations may be watched."
function watch_library_dois(kb)
    out = String[]
    for r in query(kb, "SELECT doc_id, doi FROM papers WHERE $(literature_sql())")
        ismissing(r.doi) || push!(out, normalize_doi(r.doi))
        is_arxiv_id(r.doc_id) && push!(out, "10.48550/arxiv." * lowercase(r.doc_id))
    end
    return unique!(out)
end

function openalex_watch(kb, since; cancelled = () -> false, page = openalex_page)
    c = kb.config
    filters = Pair{String,String}[]
    for s in unique(c.watch_venues)
        push!(filters, "primary_location.source.id:$s" => "OpenAlex venue $s")
    end
    for a in unique(c.watch_authors)
        orcid = orcid_uri(a)
        filter = orcid === nothing ? "author.id:$a" : "author.orcid:$orcid"
        push!(filters, filter => "OpenAlex author $a")
    end
    seeds = Dict{String,String}()
    if c.watch_citing_library
        for batch in Iterators.partition(watch_library_dois(kb), 50)
            cancelled() && return []
            data = page(["filter" => "doi:" * join(batch, '|'), "select" => "id,doi", "per_page" => "100"]; c.contact)
            for w in data["results"]
                seeds[last(split(w["id"], '/'))] = normalize_doi(w["doi"])
            end
        end
        for ids in Iterators.partition(sort!(collect(keys(seeds))), 50)
            push!(filters, "cites:" * join(ids, '|') => "Cites the library")
        end
    end
    found = []
    for (filter, reason) in filters
        cursor = "*"
        while true
            cancelled() && return found
            data = page(["filter" => "$filter,from_publication_date:$since", "cursor" => cursor,
                         "per_page" => "100", "select" => WATCH_WORK_FIELDS]; c.contact)
            for w in data["results"]
                m = watch_work(w, reason)
                m === nothing && continue
                if startswith(filter, "cites:")
                    matches = [seeds[id] for url in something(get(w, "referenced_works", nothing), [])
                               for id in (last(split(url, '/')),) if haskey(seeds, id)]
                    isempty(matches) || (m = merge(m, (; origins = ["Cites $doi" for doi in matches])))
                end
                push!(found, m)
            end
            next = get(data["meta"], "next_cursor", nothing)
            (next === nothing || isempty(data["results"])) && break
            next == cursor && error("OpenAlex repeated its pagination cursor")
            cursor = next
        end
    end
    return found
end

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
