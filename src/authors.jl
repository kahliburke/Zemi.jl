# The knowledge base's authors: names grouped by the person they most likely are (surname and first
# initial, accents and punctuation aside), each with their papers and the co-authors they share most.

"""
    author_key(name) -> String

The person a name most likely is: `surname|initial`, lower case without accents. "Ada Lovelace",
"A. Lovelace" and "Lovelace, Ada" all give `lovelace|a`; a surname particle stays with the
surname ("van der Berg"). A team or collaboration, or a one-word name, is its own key.
"""
function author_key(name::AbstractString)
    n = strip(replace(Base.Unicode.normalize(String(name); stripmark = true), r"[{}]" => ""))
    isempty(n) && return ""
    # A team or collaboration is no person's surname and initial: the whole name is its key.
    occursin(r"(?i)\b(team|collaboration|group|consortium)\b", n) && return lowercase(replace(n, r"^(?i)the\s+" => "")) * "|"
    if occursin(',', n)
        surname, given = strip.(split(n, ','; limit = 2))
    else
        parts = split(n)
        length(parts) == 1 && return lowercase(n) * "|"
        i = length(parts)
        while i > 2 && islowercase(first(parts[i-1]))      # "van der Berg"
            i -= 1
        end
        surname, given = join(parts[i:end], " "), join(parts[1:i-1], " ")
    end
    initial = isempty(given) ? "" : lowercase(string(first(given)))
    return lowercase(replace(surname, r"[^\p{L}\s'-]" => "")) * "|" * initial
end

"Whether every word of `query` begins a word of `name`, ignoring case and accents: \"love\", \"a lovelace\"."
function author_matches(name::AbstractString, query::AbstractString)
    words(s) = split(lowercase(Base.Unicode.normalize(String(s); stripmark = true)), r"[^\p{L}\p{N}'-]+"; keepempty = false)
    have = words(name)
    return all(q -> any(w -> startswith(w, q), have), words(query))
end

"""
    authors(kb) -> Vector{NamedTuple}

Every author of the knowledge base's papers and uploads, most papers first: `(; key, name, variants,
papers, coauthors)`. `name` is the fullest of the names the person appears under (`variants`, most
used first), `papers` their documents' ids, newest first, and `coauthors` the `(; key, name, count)`
of those they share most papers with.
"""
function authors(kb::KB; coauthors::Integer = 8)
    rows = query(kb, "SELECT doc_id AS id, authors, published FROM papers WHERE $(literature_sql()) ORDER BY coalesce(published, '') DESC")
    names = Dict{String,Dict{String,Int}}()
    papers = Dict{String,Vector{String}}()
    together = Dict{String,Dict{String,Int}}()
    for r in rows
        keys_here = String[]
        for a in json_list(r.authors)
            # The same name in another Unicode form or spacing is the same way of writing it.
            a = join(split(Base.Unicode.normalize(a, :NFC)), " ")
            k = author_key(a)
            isempty(k) && continue
            d = get!(Dict{String,Int}, names, k)
            d[a] = get(d, a, 0) + 1
            ids = get!(Vector{String}, papers, k)
            (isempty(ids) || last(ids) != r.id) && push!(ids, r.id)
            push!(keys_here, k)
        end
        for a in unique(keys_here), b in unique(keys_here)
            a == b && continue
            t = get!(Dict{String,Int}, together, a)
            t[b] = get(t, b, 0) + 1
        end
    end
    fullest(k) = argmax(n -> (length(split(n)[1]), names[k][n]), collect(keys(names[k])))
    display = Dict(k => fullest(k) for k in keys(names))
    out = [(; key = k, name = display[k], variants = sort!(collect(keys(names[k])); by = n -> -names[k][n]),
              papers = papers[k],
              coauthors = [(; key = c, name = display[c], count = n)
                           for (c, n) in first(sort!(collect(get(together, k, Dict{String,Int}())); by = x -> -x[2]), coauthors)])
           for k in keys(names)]
    return sort!(out; by = a -> (-length(a.papers), a.name))
end

"The authors as the site's Authors page reads them (see [`authors`](@ref))."
authors_json(kb::KB) = [Dict("key" => a.key, "name" => a.name, "variants" => a.variants, "papers" => a.papers,
                             "coauthors" => [Dict("key" => c.key, "name" => c.name, "count" => c.count) for c in a.coauthors])
                        for a in authors(kb)]


# ORCID assertions belong to a byline on one work. Save the names alongside the IDs so an edit
# or a reordered author list cannot attach a stored ID to the new occupant of a position.
migration!(31, ["ALTER TABLE papers ADD COLUMN author_orcids TEXT"])

"Canonical HTTPS ORCID URI, or nothing for a missing, malformed or mistyped identifier."
function orcid_uri(value)
    value isa AbstractString || return nothing
    m = match(r"^(?:https?://orcid\.org/)?([0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X])$"i, strip(value))
    m === nothing && return nothing
    id = uppercase(m[1])
    digits = replace(id, "-" => "")
    total = foldl((n, d) -> 2 * (n + Int(d - '0')), first(digits, 15); init = 0)
    check = mod(12 - mod(total, 11), 11)
    last(digits) == (check == 10 ? 'X' : '0' + check) || return nothing
    return "https://orcid.org/" * id
end

function stored_orcids(names, ids; curated = Int[])
    ids isa AbstractVector && length(ids) == length(names) || return missing
    uris = orcid_uri.(ids)
    all(isnothing, uris) && isempty(curated) && return missing
    return JSON.json((; names, ids = uris, curated))
end

function byline_record(names, stored)
    record = ismissing(stored) ? nothing : JSON.parse(stored)
    if record isa AbstractDict && get(record, "names", nothing) == names
        ids = get(record, "ids", nothing)
        if ids isa AbstractVector && length(ids) == length(names)
            curated = Int[i for i in get(record, "curated", []) if i isa Int && i in eachindex(names)]
            return (; ids = Union{String,Nothing}[orcid_uri(id) for id in ids], curated)
        end
    end
    return (; ids = Union{String,Nothing}[nothing for _ in names], curated = Int[])
end
byline_ids(names, stored) = byline_record(names, stored).ids
byline_name(n) = squash(String(Base.Unicode.normalize(n, :NFC)))

# An explicit catalogue correction, including the removal of an ID, survives subsequent
# metadata lookups while the byline list still matches the one the curator reviewed.
function refreshed_orcids(names, incoming, previous)
    record = byline_record(names, previous)
    ids = Union{String,Nothing}[incoming isa AbstractVector && length(incoming) == length(names) ?
                               orcid_uri(incoming[i]) : nothing for i in eachindex(names)]
    for i in record.curated
        ids[i] = record.ids[i]
    end
    return stored_orcids(names, ids; record.curated)
end

# One row per accessible publication. Counts and author labels have the same visibility
# as the publications that substantiate them.
function author_publications(kb::KB, caller = nothing)
    rows = transaction(kb) do
        hidden = caller === nothing ? () : hidden_documents(kb, caller)
        filter(r -> !(r.id in hidden), query(kb, """
            SELECT doc_id AS id, title, published, authors, author_orcids FROM papers
            WHERE metadata_at IS NOT NULL AND $(literature_sql(closed = caller !== nothing))
            ORDER BY published DESC, doc_id"""))
    end
    return map(rows) do r
        names = json_list(r.authors)
        ids = byline_ids(names, r.author_orcids)
        (; r.id, title = coalesce(r.title, r.id), published = coalesce(r.published, ""),
           authors = [(; name = byline_name(n), key = author_key(n), orcid = ids[i], position = i)
                      for (i, n) in enumerate(names) if !isempty(strip(n))])
    end
end
