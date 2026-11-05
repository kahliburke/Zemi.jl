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
