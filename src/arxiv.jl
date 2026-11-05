"""
    PaperMeta

Metadata for one paper from arXiv: its record from OAI-PMH (see [`fetch_metadata`](@ref)), or an
entry of a search (see [`search_arxiv`](@ref)).
"""
Base.@kwdef struct PaperMeta
    doc_id::String
    version::String
    title::String
    abstract::String
    authors::Vector{String}
    published::String
    updated::String
    primary_category::String
    categories::Vector{String}
    doi::Union{String,Nothing} = nothing
    journal_ref::Union{String,Nothing} = nothing
end

# arXiv asks clients to leave 3 seconds between requests. Each of its hosts is spaced on its own
# (the search API, OAI-PMH, the PDFs), so a slow answer from one holds up no request to another.
const ARXIV_INTERVAL = 3.0

"One arXiv host's turn: held by the request being made to it, and when the last one was."
mutable struct HostTurn
    lock::ReentrantLock
    last::Float64
end
const ARXIV_HOSTS = LockedDict{String,HostTurn}()

"""
    arxiv_get(url, c; patience = 0, kw...) -> HTTP.Response

Ask arXiv for `url`, 3 s after the last request to its host. A busy spell's answer (429, or 503) fails
at once, unless there is `patience` (seconds): then it waits as arXiv's `Retry-After` says (or 60 s,
doubling) and asks again, until the patience is spent, holding the host's turn meanwhile.
"""
function arxiv_get(url::AbstractString, c::Config; patience::Real = 0, kw...)
    turn = get!(() -> HostTurn(ReentrantLock(), 0.0), ARXIV_HOSTS, HTTP.URI(url).host)
    ua = "Zemi/" * string(pkgversion(@__MODULE__)) * (isempty(c.contact) ? "" : " (mailto:$(c.contact))")
    spaced() = (wait = turn.last + ARXIV_INTERVAL - time(); wait > 0 && sleep(wait))
    lock(turn.lock) do
        with_retry("arXiv"; tries = 1, patience, pause = 60.0, before = spaced) do
            try
                # Every phase has a limit, so a request arXiv never answers fails.
                HTTP.get(url; headers = ["User-Agent" => ua], retry = false,
                         connect_timeout = 30, response_header_timeout = 60, read_idle_timeout = 120, kw...)
            finally
                turn.last = time()
            end
        end
    end
end

const ATOM_NS = ["a" => "http://www.w3.org/2005/Atom", "x" => "http://arxiv.org/schemas/atom"]

squash(s::AbstractString) = join(split(s), ' ')

"""
    parse_arxiv_feed(xml) -> Vector{PaperMeta}

Parse an arXiv API Atom response. Entries the API returns as errors (unknown ids) are skipped.
"""
function parse_arxiv_feed(xml::AbstractString)
    root = EzXML.root(EzXML.parsexml(xml))
    out = PaperMeta[]
    for e in findall("a:entry", root, ATOM_NS)
        text(xpath) = (n = findfirst(xpath, e, ATOM_NS); n === nothing ? nothing : squash(EzXML.nodecontent(n)))
        id = parse_arxiv_id(something(text("a:id"), ""))
        id === nothing && continue
        primary = findfirst("x:primary_category", e, ATOM_NS)
        push!(out, PaperMeta(;
            doc_id = id.id,
            version = id.version,
            title = something(text("a:title"), ""),
            abstract = something(text("a:summary"), ""),
            authors = [squash(EzXML.nodecontent(n)) for n in findall("a:author/a:name", e, ATOM_NS)],
            published = first(something(text("a:published"), ""), 10),
            updated = first(something(text("a:updated"), ""), 10),
            primary_category = primary === nothing ? "" : primary["term"],
            categories = [n["term"] for n in findall("a:category", e, ATOM_NS)],
            doi = text("x:doi"),
            journal_ref = text("x:journal_ref")))
    end
    return out
end

"Where arXiv's OAI-PMH service and its search API answer (stand-ins' addresses in tests)."
const OAI_URL = Ref("https://oaipmh.arxiv.org/oai")
const ARXIV_API = Ref("https://export.arxiv.org/api/query")
const OAI_NS = ["o" => "http://www.openarchives.org/OAI/2.0/", "a" => "http://arxiv.org/OAI/arXiv/", "r" => "http://arxiv.org/OAI/arXivRaw/"]

"""
    parse_oai_records(xml) -> (; papers::Vector{PaperMeta}, token::String)

The papers of an OAI-PMH answer in the `arXiv` format (a `GetRecord` or a page of `ListRecords`),
and the resumption token for the next page (empty on the last). Their version is not in this
format (see [`parse_oai_versions`](@ref)). An answer that names no record (an id arXiv does not
have) has none.
"""
function parse_oai_records(xml::AbstractString)
    root = EzXML.root(EzXML.parsexml(xml))
    papers = PaperMeta[]
    for a in findall("//a:arXiv", root, OAI_NS)
        text(x) = (n = findfirst(x, a, OAI_NS); n === nothing ? nothing : squash(EzXML.nodecontent(n)))
        name(n) = join(filter(!isempty, [squash(EzXML.nodecontent(x)) for f in ("a:forenames", "a:keyname", "a:suffix")
                                         for x in findall(f, n, OAI_NS)]), ' ')
        categories = split(something(text("a:categories"), ""))
        push!(papers, PaperMeta(; doc_id = something(text("a:id"), ""), version = "",
            title = something(text("a:title"), ""), abstract = something(text("a:abstract"), ""),
            authors = [name(n) for n in findall("a:authors/a:author", a, OAI_NS)],
            published = something(text("a:created"), ""), updated = something(text("a:updated"), text("a:created"), ""),
            primary_category = isempty(categories) ? "" : String(first(categories)), categories = String.(categories),
            doi = text("a:doi"), journal_ref = text("a:journal-ref")))
    end
    t = findfirst("//o:resumptionToken", root, OAI_NS)
    return (; papers, token = t === nothing ? "" : strip(EzXML.nodecontent(t)))
end

"""
    parse_oai_versions(xml) -> Vector{@NamedTuple{version::String, date::String}}

A paper's versions, oldest first, from its OAI-PMH record in the `arXivRaw` format, each with the
day it was submitted (`yyyy-mm-dd`).
"""
function parse_oai_versions(xml::AbstractString)
    root = EzXML.root(EzXML.parsexml(xml))
    day(s) = (d = tryparse(DateTime, replace(squash(s), r" GMT$" => ""), dateformat"e, d u y H:M:S"); d === nothing ? "" : Dates.format(d, "yyyy-mm-dd"))
    date(v) = (n = findfirst("r:date", v, OAI_NS); n === nothing ? "" : day(EzXML.nodecontent(n)))
    return [(; version = v["version"], date = date(v)) for v in findall("//r:version", root, OAI_NS)]
end

oai_get(c::Config, query; patience = 0) = String(arxiv_get(OAI_URL[], c; query, patience).body)

"""
    fetch_metadata(ids, config; patience = 0) -> Dict{String,PaperMeta}

Look up papers' records on arXiv's OAI-PMH service, which answers when its search API is too busy
to: each one's fields from the `arXiv` format, and its versions (the latest is its version, the day
of the first when it was published and of the latest when updated) from `arXivRaw`. When OAI-PMH
does not answer, the rest come from the search API (see [`fetch_metadata_api`](@ref)). An id arXiv
does not have is left out. See [`arxiv_get`](@ref) for `patience`.
"""
function fetch_metadata(ids::AbstractVector{<:AbstractString}, c::Config; patience::Real = 0)
    out = Dict{String,PaperMeta}()
    todo = unique(ids)
    for (i, id) in enumerate(todo)
        record(prefix) = oai_get(c, ["verb" => "GetRecord", "identifier" => "oai:arXiv.org:$id", "metadataPrefix" => prefix]; patience)
        found = try
            parse_oai_records(record("arXiv")).papers
        catch e
            e isa InterruptException && rethrow()
            @warn "arXiv's OAI-PMH did not answer; asking its search API instead" exception = e
            return merge!(out, fetch_metadata_api(todo[i:end], c; patience))
        end
        isempty(found) && continue
        m = first(found)
        vs = parse_oai_versions(record("arXivRaw"))
        out[m.doc_id] = isempty(vs) ? m : PaperMeta(; (f => getfield(m, f) for f in fieldnames(PaperMeta))...,
                                                        version = last(vs).version,
                                                        published = isempty(first(vs).date) ? m.published : first(vs).date,
                                                        updated = isempty(last(vs).date) ? m.updated : last(vs).date)
    end
    return out
end

"""
    fetch_metadata_api(ids, config; patience = 0) -> Dict{String,PaperMeta}

Papers' records from arXiv's search API, asked for by id: the same fields as OAI-PMH gives, the
dates those of the first version and the latest. An id arXiv does not have is left out.
"""
function fetch_metadata_api(ids::AbstractVector{<:AbstractString}, c::Config; patience::Real = 0)
    out = Dict{String,PaperMeta}()
    for batch in Iterators.partition(ids, 50)
        r = arxiv_get(ARXIV_API[], c; patience, query = ["id_list" => join(batch, ","), "max_results" => string(length(batch))])
        foreach(m -> out[m.doc_id] = m, parse_arxiv_feed(String(r.body)))
    end
    return out
end

"""
    oai_set(category, config) -> String

The OAI-PMH set of an arXiv category (`physics.optics` → `physics:physics:optics`, `q-bio.PE` →
`q-bio:q-bio:PE`), from arXiv's list of sets, read once.
"""
function oai_set(category::AbstractString, c::Config)
    sets = lock(OAI_SETS_LOCK) do
        isempty(OAI_SETS) && append!(OAI_SETS, [String(EzXML.nodecontent(n)) for n in
            findall("//o:setSpec", EzXML.root(EzXML.parsexml(oai_get(c, ["verb" => "ListSets"]))), OAI_NS)])
        copy(OAI_SETS)
    end
    want = split(category, '.')                       # its archive, and its subject class if it has one
    i = findfirst(s -> split(s, ':')[max(1, end - length(want) + 1):end] == want, sets)
    i === nothing && error("arXiv has no OAI-PMH set for the category $category")
    return sets[i]
end
const OAI_SETS = String[]
const OAI_SETS_LOCK = ReentrantLock()

"""
    list_new_papers(category, since, config; patience = 0) -> Vector{PaperMeta}

The papers in arXiv `category` (a paper listed in it as a secondary one too) whose records changed
since the day `since`, from OAI-PMH, every page of the listing. Their `published` says which are
new. When OAI-PMH does not answer, they come from the search API (see
[`list_new_papers_api`](@ref)). See [`arxiv_get`](@ref) for `patience`.
"""
function list_new_papers(category::AbstractString, since::Date, c::Config; patience::Real = 0)
    out = PaperMeta[]
    try
        set = oai_set(category, c)
        page = oai_get(c, ["verb" => "ListRecords", "metadataPrefix" => "arXiv", "set" => set, "from" => string(since)]; patience)
        while true
            got = parse_oai_records(page)
            append!(out, filter(m -> category in m.categories, got.papers))
            isempty(got.token) && return out
            page = oai_get(c, ["verb" => "ListRecords", "resumptionToken" => got.token]; patience)
        end
    catch e
        e isa InterruptException && rethrow()
        @warn "arXiv's OAI-PMH did not answer; asking its search API instead" category exception = e
        return list_new_papers_api(category, since, c; patience)
    end
end

"""
    list_new_papers_api(category, since, config; patience = 0) -> Vector{PaperMeta}

The papers in arXiv `category` submitted since the day `since`, from the search API, newest first,
page by page until one reaches back past `since`.
"""
function list_new_papers_api(category::AbstractString, since::Date, c::Config; patience::Real = 0, page_size::Integer = 200)
    out = PaperMeta[]
    since_day(m) = !isempty(m.published) && Date(m.published) >= since
    start = 0
    while true
        page = search_arxiv("cat:$category", c; max_results = page_size, sort = "submittedDate", start, patience)
        append!(out, filter(since_day, page))
        (length(page) < page_size || !all(since_day, page)) && return out
        start += page_size
    end
end

"""
    search_arxiv(query, config; max_results = 50, sort = "relevance") -> Vector{PaperMeta}

Papers matching an arXiv API search query (its `search_query` syntax: `abs:coral AND
abs:bleaching`, `ti:"graph neural network"`, `cat:q-bio.PE`, …), most relevant first, or with
`sort = "submittedDate"` newest first, from the `start`th. Only arXiv's search API searches, and it is often too busy to
answer: see [`arxiv_get`](@ref) for `patience`.
"""
function search_arxiv(query::AbstractString, c::Config; max_results::Integer = 50, sort::AbstractString = "relevance",
                      start::Integer = 0, patience::Real = 0)
    r = arxiv_get(ARXIV_API[], c; patience,
        query = ["search_query" => query, "start" => string(start), "max_results" => string(max_results), "sortBy" => sort,
                 "sortOrder" => "descending"])
    return parse_arxiv_feed(String(r.body))
end

pdf_filename(doc_id, version) = replace(doc_id, "/" => "_") * version * ".pdf"

"Where arXiv serves its PDFs (a stand-in's address in tests)."
const ARXIV_PDF = Ref("https://arxiv.org/pdf")
# One download at a time: reading a paper and looking at its PDF may ask for the same file at once.
const PDF_DOWNLOAD_LOCK = ReentrantLock()

"""
    download_pdf(doc_id, version, config) -> String

Download a paper's PDF into the data directory, reusing an existing download, and return its path.
"""
function download_pdf(doc_id::AbstractString, version::AbstractString, c::Config)
    path = joinpath(pdf_dir(c), pdf_filename(doc_id, version))
    isfile(path) && return path
    lock(PDF_DOWNLOAD_LOCK) do
        isfile(path) && return path
        r = arxiv_get("$(ARXIV_PDF[])/$doc_id$version", c)
        startswith(String(r.body[1:min(end, 5)]), "%PDF") ||
            error("arXiv did not return a PDF for $doc_id$version")
        tmp = path * ".part"
        write(tmp, r.body)
        mv(tmp, path; force = true)
        return path
    end
end
