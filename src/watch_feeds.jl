# Public links are kept verbatim except for the scheme, host, default port and fragment.
function watch_url(value)
    value isa AbstractString || return nothing
    s = strip(value)
    occursin(r"[\s\\\x00-\x1f]", s) && return nothing
    u = try HTTP.URI(s) catch; return nothing end
    scheme = lowercase(u.scheme)
    scheme in ("http", "https") && !isempty(u.host) && isempty(u.userinfo) || return nothing
    port = u.port == (scheme == "https" ? "443" : "80") ? nothing : u.port
    return try string(HTTP.URI(u; scheme, host = lowercase(u.host), port, fragment = nothing)) catch; nothing end
end

watch_resource_id(url) = resource_id("watch", bytes2hex(sha256(url))[1:32])

# Only strong identifiers match across sources. Opaque feed GUIDs are scoped to that feed.
function linked_candidate(; url, key, title, authors, abstract, published, category, origin, doi, arxiv)
    aliases = unique(filter(!isempty, [url, key]))
    id = arxiv === nothing ? something(doi, watch_resource_id(url)) : arxiv
    return (; doc_id = id, title, authors, abstract, published, primary_category = category,
            origins = [origin], doi, work_id = nothing, aliases, url)
end

function feed_date(raw)
    iso = match(r"^\d{4}-\d\d-\d\d", raw)
    iso === nothing || return tryparse(Date, iso.match)
    rss = match(r"^(?:\w+,\s*)?(\d{1,2} \w{3} \d{4})", raw)
    return rss === nothing ? nothing : tryparse(Date, rss[1], dateformat"d u yyyy")
end

const FEED_BYTES = 4 * 1024^2
function fetch_feed(url)
    body = Ref{String}()
    HTTP.open("GET", url, ["Accept-Encoding" => "identity"]; connect_timeout = 10, read_idle_timeout = 20) do io
        response = HTTP.startread(io)
        response.status == 200 || error("feed returned HTTP $(response.status)")
        bytes = read(io, FEED_BYTES + 1)
        length(bytes) <= FEED_BYTES || error("feed exceeds 4 MiB")
        body[] = String(bytes)
    end
    return body[]
end

function feed_candidates(xml, feed, since)
    ncodeunits(xml) <= FEED_BYTES && isvalid(xml) && !occursin('\0', xml) || error("invalid or oversized feed")
    occursin(r"<!\s*(DOCTYPE|ENTITY)"i, xml) && error("DTD declarations are unsupported in feeds")
    root = EzXML.root(EzXML.parsexml(xml))
    atom = EzXML.nodename(root) == "feed"
    nodes(n, path) = findall(path, n, NO_NAMESPACES)
    children(n, name) = nodes(n, "*[local-name()='$name']")
    field(n, name) = join((strip(EzXML.nodecontent(x)) for x in Iterators.take(children(n, name), 1)))
    entries = atom ? children(root, "entry") : nodes(root, "./*[local-name()='channel']/*[local-name()='item'] | ./*[local-name()='item']")
    title_nodes = atom ? children(root, "title") : nodes(root, "./*[local-name()='channel']/*[local-name()='title']")
    label = isempty(title_nodes) ? "" : strip(EzXML.nodecontent(first(title_nodes)))
    origin = "Feed: " * (isempty(label) ? HTTP.URI(feed).host : first(label, 200))
    result = []
    for e in entries
        title = field(e, "title")
        isempty(title) && continue
        guid = field(e, atom ? "id" : "guid")
        links = children(e, "link")
        hrefs = atom ? [l["href"] for l in links if haskey(l, "href") && (!haskey(l, "rel") || l["rel"] == "alternate")] :
                       [strip(EzXML.nodecontent(l)) for l in links]
        url = nothing
        for href in hrefs
            isempty(href) && continue
            resolved = try HTTP.URIs.resolvereference(HTTP.URI(feed), HTTP.URI(href)) catch; continue end
            url = watch_url(string(resolved))
            url === nothing || break
        end
        url === nothing && (url = watch_url(guid))
        doi = nothing
        for value in [field(e, "doi"), field(e, "identifier"), guid, something(url, "")]
            doi = parse_doi(value)
            doi === nothing || break
        end
        url === nothing && doi !== nothing && (url = "https://doi.org/$doi")
        url === nothing && continue
        date = nothing
        for name in ("published", "pubDate", "date", "updated")
            date = feed_date(field(e, name))
            date === nothing || break
        end
        date !== nothing && date < since && continue
        summary = field(e, atom ? "summary" : "description")
        authors = [strip(EzXML.nodecontent(a)) for a in nodes(e,
            "*[local-name()='author']/*[local-name()='name'] | *[local-name()='author' and not(*)] | *[local-name()='creator']")]
        arxiv = parse_arxiv_id(url)
        key = isempty(guid) ? "" : "feed:" * bytes2hex(sha256(feed * "\0" * guid))
        push!(result, linked_candidate(; url, key, title = first(title, 1500), authors,
            abstract = first(squash(replace(summary, r"<[^>]+>" => " ")), 12000),
            published = date === nothing ? "" : string(date), category = "", origin, doi,
            arxiv = arxiv === nothing ? nothing : arxiv.id))
        length(result) == 100 && break
    end
    return result
end

function feed_watch(kb, since; cancelled = () -> false, progress = msg -> nothing, fetch = fetch_feed)
    items = []
    for url in unique(kb.config.watch_feeds)
        cancelled() && break
        try
            append!(items, feed_candidates(fetch(url), url, since))
        catch e
            e isa InterruptException && rethrow()
            progress("Skipped feed on $(HTTP.URI(url).host): $(failure_message(e))")
        end
    end
    return items
end

# The watch and its Add button use the same saved metadata. A DOI supplied while
# the entry was awaiting review follows normal DOI resolution at arrival.
function add_watch_resource!(kb, id; by, anyway, holder)
    rows = query(kb, "SELECT * FROM watch WHERE doc_id = ? AND source_url IS NOT NULL", (id,))
    isempty(rows) && not_found("No watched document $id")
    w = only(rows)
    try
        ismissing(w.doi) || return add_work!(kb, w.doi; by, anyway, holder, source = "watch")
        key = chop(id; head = length("res-watch-"), tail = 0)
        r = Resource(; key, title = w.title, url = w.source_url, authors = json_list(w.authors),
                     date = w.published, note = w.abstract)
        local_id, _ = put_resource!(kb, "watch", r; by, anyway, read = false)
        bring_in!(kb, local_id, holder; new = true, source = "watch")
        return local_id
    catch e
        e isa DroppedError || rethrow()
        return nothing
    end
end

# Run inside the placement transaction. Keep the content fingerprint consistent
# with resource_content, so an explicit refresh can index the new identifier.
function attach_watch_doi!(kb, id, doi)
    row = resource_row(kb, id)
    (row === nothing || row.source != "watch" || !ismissing(row.doi)) && return
    changed!(kb, "UPDATE papers SET doi = ? WHERE id = ? AND access = 'open' AND doi IS NULL", (doi, row.pid)) == 0 && return
    r = Resource(; key = row.key, title = row.title, type = row.type, authors = json_list(row.authors),
                 organizations = json_list(row.organizations), date = coalesce(row.published, ""), url = row.url,
                 note = row.note, container = row.container, publisher = row.publisher, accessed = row.accessed, doi)
    sha = bytes2hex(sha256(JSON.json(resource_content(r))))
    execute!(kb, "UPDATE resources SET content_sha = ?, updated_at = ? WHERE paper_id = ?", (sha, now_iso(), row.pid))
end
