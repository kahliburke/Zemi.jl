# OpenAlex, the open catalogue of scholarly works: the published record of an uploaded paper (see
# `lookup_upload`), and where the works the papers cite are posted (see `find_on_arxiv!`).

const OPENALEX_WORKS = "https://api.openalex.org/works"

"""
    openalex_get(query; contact = "", timeout = 30) -> Vector

The works OpenAlex finds for `query` (its parameters), asked as [`with_retry`](@ref) does: a busy
spell waited out for a while, a failure tried once more. `contact`, an email address, puts the
request in OpenAlex's polite pool.
"""
function openalex_get(query::AbstractVector; contact::AbstractString = "", timeout::Real = 30)
    isempty(contact) || (query = [query; "mailto" => contact])
    r = with_retry("OpenAlex"; tries = 2, patience = 30) do
        HTTP.get(OPENALEX_WORKS; query, retry = false, connect_timeout = 20, response_header_timeout = timeout,
                 read_idle_timeout = timeout)
    end
    return JSON.parse(body_text(r.body))["results"]
end

"""
    openalex_work(; doi = nothing, title = nothing, contact = "") -> Union{AbstractDict,Nothing}

OpenAlex's record of a work, by its DOI or by its exact title, or `nothing` when it has none.
`contact`, an email address, puts the request in OpenAlex's polite pool.
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
    authors = String[a["author"]["display_name"] for a in something(w["authorships"], [])
                     if get(something(a["author"], Dict()), "display_name", nothing) !== nothing]
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
    return (; title = String(w["title"]), authors, year = year === nothing ? nothing : string(year), journal, journal_ref = ref, doi, abstract)
end

"""
    openalex_arxiv(dois, contact = "") -> Dict{String,Union{String,Nothing}}

What each of `dois` (at most 50) is on arXiv as, by OpenAlex's record of where the work is posted:
an arXiv id, or `nothing` when OpenAlex knows the work but not on arXiv. A DOI OpenAlex does not
know is left out. `contact`, an email address, puts the request in OpenAlex's polite pool.
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

