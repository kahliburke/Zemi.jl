# Zotero: a group's library, read through Zotero's web API and kept in step. Each item comes in as what
# it is: a work with a DOI and a copy to read (see `add_doi!`) as the knowledge base's paper, a
# repository as its codebase, and anything else, a work with no copy to read among them, as a resource
# (see resources.jl). Each is kept in the library of the project its group is mapped to:
#
#     [sources.zotero]
#     groups = { 6748949 = "EHS" }               # a group's id, and the project keeping its items ("" for none)
#     key = "file:/srv/zemi/.config/zemi/zotero"  # an API key, for a group whose library is not public
#
# Zotero numbers each change to a library, so a run asks for the items changed since the last. One
# item is one document: the same DOI, or for a work without one the same title, is the item seen
# first. An item whose document was removed here is not brought in again.

"Zotero's web API (a stand-in's address in tests)."
const ZOTERO_API = Ref("https://api.zotero.org")

"""
    zotero_items(group, since; key = "") -> (; items, version)

The items of Zotero group `group` changed since library version `since` (0 for all of them), with
the library's version now. Read a hundred at a time.
"""
function zotero_items(group::AbstractString, since::Integer; key::AbstractString = "")
    headers = ["Zotero-API-Version" => "3"; isempty(key) ? Pair{String,String}[] : ["Zotero-API-Key" => key]]
    items, start, version = Any[], 0, since
    while true
        r = HTTP.get("$(ZOTERO_API[])/groups/$group/items"; headers, status_exception = false, connect_timeout = 20, readtimeout = 60,
                     query = ["since" => string(since), "format" => "json", "limit" => "100", "start" => string(start)])
        r.status == 403 && error("Zotero refused group $group: it is not public, and no key that may read it is set")
        r.status == 200 || error("Zotero answered HTTP $(r.status) for group $group")
        page = JSON.parse(String(r.body))
        append!(items, page)
        version = parse(Int, HTTP.header(r, "Last-Modified-Version", string(since)))
        total = parse(Int, HTTP.header(r, "Total-Results", "0"))
        start += length(page)
        (isempty(page) || start >= total) && return (; items, version)
    end
end

"How Zotero's item types are named on a resource."
const ZOTERO_TYPES = Dict("journalArticle" => "article", "conferencePaper" => "conference paper", "bookSection" => "book section",
                          "computerProgram" => "software", "webpage" => "web page", "newspaperArticle" => "news",
                          "magazineArticle" => "magazine article", "statute" => "law", "bill" => "law", "case" => "court case",
                          "thesis" => "thesis", "report" => "report", "book" => "book", "dataset" => "dataset", "map" => "map",
                          "document" => "document", "preprint" => "preprint", "presentation" => "presentation")

"An item's authors, as `First Last`, its institution where a work names no person."
zotero_authors(d) = String[strip(get(c, "name", "") * get(c, "firstName", "") * " " * get(c, "lastName", ""))
                     for c in get(d, "creators", []) if get(c, "creatorType", "author") in ("author", "editor", "programmer", "contributor")]

"An item's year, or the date as precise as it gives it, from its free-form `date`."
function zotero_date(d)
    s = strip(get(d, "date", ""))
    m = match(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", s)
    m === nothing && return ""
    return join(filter(!isnothing, [m[1], m[2], m[3]]), "-")
end

"Whether `url` is a repository on a code host (GitHub, GitLab, Codeberg, Bitbucket): an owner and a name, and no more."
code_host_repository(url::AbstractString) =
    occursin(r"^https?://(www\.)?(github\.com|gitlab\.com|codeberg\.org|bitbucket\.org)/[^/\s]+/[^/\s#?]+?(\.git)?/?$"i, strip(url))

"The text of Zotero notes, without their HTML."
note_text(html::AbstractString) = strip(replace(replace(replace(html, r"<[^>]+>" => " "), "&nbsp;" => " ", "&amp;" => "&",
                                                          "&lt;" => "<", "&gt;" => ">"), r"\s+" => " "))

"""
    zotero_item!(kb, item, notes; project, source = "zotero", by = nothing) -> Union{String,Nothing}

Bring Zotero item `item` (with the text of its `notes`) into the knowledge base as what it is (see the
top of zotero.jl), kept in `project`'s library ("" for none), and return its document's id: a codebase
for a repository it links, the paper its DOI has a copy of, else a resource. `nothing` for an item
with no title.
"""
function zotero_item!(kb::KB, item, notes::AbstractVector{<:AbstractString}; project::AbstractString, source::AbstractString = "zotero",
                      by = nothing)
    d = item["data"]
    title = strip(get(d, "title", ""))
    isempty(title) && return nothing
    url, doi = strip(get(d, "url", "")), strip(get(d, "DOI", ""))
    keep(id) = (isempty(project) || library_add!(kb, project, id; by = Actor(something(by, source), false)); id)
    if code_host_repository(url)
        return keep(link_repository!(kb, url))
    end
    authors = zotero_authors(d)
    date = zotero_date(d)
    if !isempty(doi)
        id = add_doi!(kb, doi; title, authors, published = isempty(date) ? nothing : first(date, 4), source, by)
        id === nothing || return keep(id)
    end
    r = Resource(; key = String(item["key"]), title, type = get(ZOTERO_TYPES, d["itemType"], d["itemType"]), authors, date,
                 url, doi, note = join(filter(!isempty, [strip(get(d, "abstractNote", "")); notes]), "\n\n"),
                 projects = isempty(project) ? String[] : [project])
    return first(put_resource!(kb, source, r; by, read = READ_PUT[]))
end

"""
    zotero_poll(run)

A run of the Zotero source: each group in its settings read for the items changed since the last run,
and each brought in (see [`zotero_item!`](@ref)). The state keeps each group's library version, the
document each item became, and by title the document a work without a DOI became.
"""
function zotero_poll(run)
    d = settings(run)
    groups = get(d, "groups", Dict())
    key = haskey(d, "key") ? secret(run, "key") : ""
    st = state(run)
    versions = Dict{String,Any}(get(st, "versions", Dict()))
    made = Dict{String,Any}(get(st, "items", Dict()))
    titled = Dict{String,Any}(get(st, "titles", Dict()))
    kb = run.kb
    for (group, project) in groups
        group, project = string(group), String(project)
        isempty(project) || project_id(kb, project)
        got = zotero_items(group, Int(get(versions, group, 0)); key)
        notes = Dict{String,Vector{String}}()
        for it in got.items
            p = get(it["data"], "parentItem", "")
            it["data"]["itemType"] == "note" && !isempty(p) && push!(get!(Vector{String}, notes, p), note_text(it["data"]["note"]))
        end
        tops = [it for it in got.items if !(it["data"]["itemType"] in ("note", "attachment", "annotation"))]
        progress(run, "group $group: $(length(tops)) items changed")
        for it in tops
            cancelled(run) && break
            k = "$group/$(it["key"])"
            # Removed here since: not brought in again.
            haskey(made, k) && ismissing(paper_id(kb, made[k])) && continue
            t = normalize_title(get(it["data"], "title", ""))
            if isempty(strip(get(it["data"], "DOI", ""))) && haskey(titled, t) && !ismissing(paper_id(kb, titled[t])) && !haskey(made, k)
                isempty(project) || library_add!(kb, project, titled[t]; by = Actor("zotero", false))
                made[k] = titled[t]
                continue
            end
            id = zotero_item!(kb, it, get(notes, it["key"], String[]); project)
            id === nothing && continue
            made[k] = id
            isempty(strip(get(it["data"], "DOI", ""))) && (titled[t] = id)
            is_resource(id) || is_codebase(id) || READ_PUT[] && queue_reading!(kb, [id])
        end
        cancelled(run) || (versions[group] = got.version)
        save_state!(run, Dict("versions" => versions, "items" => made, "titles" => titled))
    end
end

record_source!("zotero"; label = "From a Zotero library", every = 3600, poll = zotero_poll, configured = true,
               budget = (; seconds = 3600.0), api = PLUGIN_API)
