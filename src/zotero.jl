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
    zotero_items(group, since; key = "", keys = nothing) -> (; items, version)

The items of Zotero group `group` changed since library version `since` (0 for all of them), with
the library's version now; with `keys`, those items alone (at most fifty). Read a hundred at a time.
"""
function zotero_items(group::AbstractString, since::Integer; key::AbstractString = "", keys = nothing)
    headers = ["Zotero-API-Version" => "3"; isempty(key) ? Pair{String,String}[] : ["Zotero-API-Key" => key]]
    # Unchanged since, Zotero answers that alone: a run with nothing new costs one small request.
    since > 0 && keys === nothing && push!(headers, "If-Modified-Since-Version" => string(since))
    items, start, version = Any[], 0, since
    chosen = keys === nothing ? Pair{String,String}[] : ["itemKey" => join(keys, ',')]
    while true
        query = vcat(["since" => string(since), "format" => "json", "limit" => "100", "start" => string(start)], chosen)
        r = HTTP.get("$(ZOTERO_API[])/groups/$group/items"; headers, query, status_exception = false, connect_timeout = 20, readtimeout = 60)
        r.status == 304 && return (; items, version)
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
                     for c in zotero_creators(d)]
zotero_creators(d) = [c for c in get(d, "creators", []) if get(c, "creatorType", "author") in ("author", "editor", "programmer", "contributor")]
"Which of an item's authors are organizations: those Zotero names in one field, not as a first and last name."
zotero_organizations(d) = String[strip(c["name"]) for c in zotero_creators(d) if haskey(c, "name")]

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

"Where an item appeared: its journal, newspaper, website, book or proceedings, or the `Published:` line of its `extra`."
function zotero_container(d)
    for f in ("publicationTitle", "bookTitle", "proceedingsTitle", "websiteTitle", "blogTitle", "forumTitle", "programTitle",
              "encyclopediaTitle", "dictionaryTitle")
        v = strip(get(d, f, ""))
        isempty(v) || return String(v)
    end
    m = match(r"(?m)^\s*Published:\s*(.+?)\s*$", get(d, "extra", ""))
    return m === nothing ? "" : String(m[1])
end

"Who published an item: its publisher, or the institution, company or university that issued it."
function zotero_publisher(d)
    for f in ("publisher", "institution", "company", "university", "repository", "network", "label")
        v = strip(get(d, f, ""))
        isempty(v) || return String(v)
    end
    return ""
end

"""
When an item was accessed, as `yyyy-mm-dd`: its `accessDate`, else a note that says so ("Accessed 5
November 2026"); `""` when neither does.
"""
function zotero_accessed(d, notes)
    m = match(r"^(\d{4}-\d{2}-\d{2})", strip(get(d, "accessDate", "")))
    m === nothing || return String(m[1])
    for n in notes
        m = match(r"(?i)accessed\s+(\d{1,2}\s+[a-z]+\s+\d{4}|\d{4}-\d{2}-\d{2})", n)
        m === nothing && continue
        t = m[1]
        occursin('-', t) && return String(t)
        parsed = tryparse(Date, titlecase(t), dateformat"d U y")
        parsed === nothing || return string(parsed)
    end
    return ""
end

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
    r = Resource(; key = String(item["key"]), title, type = get(ZOTERO_TYPES, d["itemType"], d["itemType"]), authors,
                 organizations = zotero_organizations(d), date,
                 url, doi, note = join(filter(!isempty, [strip(get(d, "abstractNote", "")); notes]), "\n\n"),
                 container = zotero_container(d), publisher = zotero_publisher(d), accessed = zotero_accessed(d, notes),
                 projects = isempty(project) ? String[] : [project])
    return first(put_resource!(kb, source, r; by, read = READ_PUT[]))
end

"""
What a run reads of an item. A run made by an older one reads each group's whole library once more,
so what it brought in gains what is read now.
"""
const ZOTERO_READING = 2

"""
    zotero_poll(run)

A run of the Zotero source: each group in its settings read for the items changed since the last run,
and each brought in (see [`zotero_item!`](@ref)). An item that fails is told in the log and tried
again in the next run. The state keeps each group's library version, the document each item became,
the document each work became (by its DOI or, without one, its title), and the items to try again.
"""
function zotero_poll(run)
    d = settings(run)
    groups = get(d, "groups", Dict())
    key = haskey(d, "key") ? secret(run, "key") : ""
    st = state(run)
    versions = get(st, "reading", 1) < ZOTERO_READING ? Dict{String,Any}() : Dict{String,Any}(get(st, "versions", Dict()))
    made = Dict{String,Any}(get(st, "items", Dict()))
    titled = Dict{String,Any}(get(st, "titles", Dict()))
    again = Dict{String,Any}(get(st, "retry", Dict()))
    kb = run.kb
    for (group, project) in groups
        group, project = string(group), String(project)
        isempty(project) || project_id(kb, project)
        got = zotero_items(group, Int(get(versions, group, 0)); key)
        retry = String.(get(again, group, String[]))
        listed = Set(String(it["key"]) for it in got.items)
        for ks in Iterators.partition(filter(!in(listed), retry), 50)
            append!(got.items, zotero_items(group, 0; key, keys = collect(ks)).items)
        end
        failed = String[]
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
            # Become another document since (a resource read in full): that one; removed here: not brought in again.
            was = get(made, k, nothing)
            was === nothing || (made[k] = current_document(kb, was))
            haskey(made, k) && ismissing(paper_id(kb, made[k])) && continue
            # Read in full since from a PDF uploaded here: the paper it became stays what it is.
            if was !== nothing && made[k] != was
                isempty(project) || library_add!(kb, project, made[k]; by = Actor("zotero", false))
                continue
            end
            # The same work as an item seen before: by its DOI, or by its title where it has none.
            doi = normalize_doi(strip(get(it["data"], "DOI", "")))
            t = isempty(doi) ? "title:" * normalize_title(get(it["data"], "title", "")) : "doi:" * doi
            haskey(titled, t) && (titled[t] = current_document(kb, titled[t]))
            # Its own resource, read again, is brought up to date instead.
            if haskey(titled, t) && !ismissing(paper_id(kb, titled[t])) && !own_resource(kb, titled[t], it["key"])
                isempty(project) || library_add!(kb, project, titled[t]; by = Actor("zotero", false))
                made[k] = titled[t]
                continue
            end
            id = try
                zotero_item!(kb, it, get(notes, it["key"], String[]); project)
            catch e
                e isa InterruptException && rethrow()
                @warn "Zotero item $k could not be brought in; it is tried again in the next run" exception = e
                push!(failed, String(it["key"]))
                continue
            end
            id === nothing && continue
            made[k] = titled[t] = id
            is_resource(id) || is_codebase(id) || READ_PUT[] && queue_reading!(kb, [id])
        end
        cancelled(run) || (versions[group] = got.version)
        again[group] = failed
        save_state!(run, Dict("versions" => versions, "items" => made, "titles" => titled, "retry" => again, "reading" => ZOTERO_READING))
    end
end

"Whether document `id` is the resource Zotero item `key` made."
own_resource(kb::KB, id::AbstractString, key::AbstractString) =
    is_resource(id) && (r = resource_row(kb, id); r !== nothing && r.key == key)

record_source!("zotero"; label = "From a Zotero library", every = 3600, poll = zotero_poll, configured = true,
               budget = (; seconds = 3600.0), api = PLUGIN_API)
