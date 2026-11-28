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
