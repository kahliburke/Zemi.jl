# Exploring the knowledge base: every document with a vector placed by meaning (its nearest
# documents, and where it lies on a 2D map and in a 3D space, by t-SNE as the landscape lays papers
# out), the links people made between documents (citations, references, the evidence findings rest
# on), and both served as one graph to whoever asks, as far as they may see it. The map is kept beside
# the data (`explore.json`), never published: it places private notes too.

# ── Links people made ─────────────────────────────────────────────────────────────────────────────

# The links read from documents' text: a paper's references to papers here (`cites`), and a record's
# `@` references to documents (`refers`). Each document's are read again once what they are read from
# changes (see `link_version`).
migration!(25, [
    """CREATE TABLE document_links (
        from_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        to_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        PRIMARY KEY (from_id, to_id, kind))""",
    "CREATE INDEX document_links_to ON document_links (to_id)",
    """CREATE TABLE document_links_read (
        paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
        version TEXT NOT NULL)"""])

"""
    link_versions(kb) -> Dict{Int,String}

What each document's links are read from, as it is now, by its row: a record's content, a paper's
parse (empty for a paper not read yet). A document whose version changes has its links read again.
"""
link_versions(kb::KB) = Dict(Int(r.id) => String(r.v) for r in query(kb, """
    SELECT p.id, CASE WHEN x.paper_id IS NOT NULL THEN 'r:' || x.content_sha
                      WHEN s.paper_id IS NOT NULL THEN 'p:' || s.file_sha || ':' || s.parser_version
                      ELSE '' END AS v
    FROM papers p LEFT JOIN records x ON x.paper_id = p.id LEFT JOIN parses s ON s.paper_id = p.id"""))

"The document kinds an `@` reference names that are documents here."
const LINKED_KINDS = ("paper", "record", "code", "resource")

"""
    links_from(kb, doc; index, rows) -> Vector{Tuple{Int,String}}

The documents `doc` links to, each `(row, kind)`: for a record, those its text refers to with `@`
(`refers`); for a paper, those its references cite (`cites`, see [`paper_references`](@ref)).
`rows` maps documents' ids to their rows.
"""
function links_from(kb::KB, doc::AbstractString; index::ReferenceIndex, rows::AbstractDict)
    out = Tuple{Int,String}[]
    if is_record(doc)
        for s in record_document(kb, doc)["sections"], r in at_references(String(s["text"]))
            r.kind in LINKED_KINDS && haskey(rows, r.target) && push!(out, (rows[r.target], "refers"))
        end
    else
        for r in paper_references(kb, doc; index)
            r.cites === nothing || haskey(rows, r.cites) && push!(out, (rows[r.cites], "cites"))
        end
    end
    return unique(out)
end

"""
    read_links!(kb; progress, cancelled) -> Int

Read the links of the documents whose text changed since theirs were read, or never were (see
[`link_versions`](@ref)); for a paper new here since the links were first read, the papers citing it
too. Returns how many documents were read.
"""
function read_links!(kb::KB; progress = msg -> nothing, cancelled = () -> false)
    versions = link_versions(kb)
    was = Dict(Int(r.paper_id) => String(r.version) for r in query(kb, "SELECT paper_id, version FROM document_links_read"))
    todo = sort!([id for (id, v) in versions if get(was, id, nothing) != v])
    isempty(todo) && return 0
    rows = Dict(String(r.doc_id) => Int(r.id) for r in query(kb, "SELECT id, doc_id FROM papers"))
    ids = Dict(v => k for (k, v) in rows)
    index = ReferenceIndex(kb)
    first_time = isempty(was)
    for (n, id) in enumerate(todo)
        cancelled() && break
        n % 200 == 1 && progress("Reading the links of $(length(todo)) documents: $n")
        doc = ids[id]
        out = try links_from(kb, doc; index, rows) catch e
            @warn "The links of $doc could not be read" exception = e maxlog = 5
            Tuple{Int,String}[]
        end
        # The links to a paper new here are in the papers read before it, which are not read again.
        citing = first_time || haskey(was, id) || is_record(doc) ? Int[] :
                 [rows[c.doc_id] for c in citing_papers(kb, doc; index) if haskey(rows, c.doc_id)]
        transaction(kb) do
            execute!(kb, "DELETE FROM document_links WHERE from_id = ? AND kind IN ('cites', 'refers')", (id,))
            for (to, kind) in out
                to == id || execute!(kb, "INSERT OR IGNORE INTO document_links (from_id, to_id, kind) VALUES (?, ?, ?)", (id, to, kind))
            end
            for from in citing
                execute!(kb, "INSERT OR IGNORE INTO document_links (from_id, to_id, kind) VALUES (?, ?, 'cites')", (from, id))
            end
            execute!(kb, "INSERT OR REPLACE INTO document_links_read (paper_id, version) VALUES (?, ?)", (id, versions[id]))
        end
    end
    return length(todo)
end

# ── Pairs people judged ───────────────────────────────────────────────────────────────────────────

# Pairs of documents a person judged from the explore page's suggestions: related, drawn as a link of
# their making (`related`), or not, no longer suggested. Each pair once, the lower row first.
migration!(26, [
    """CREATE TABLE document_pairs (
        a_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        b_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        related INTEGER NOT NULL,
        user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        judged_at TEXT NOT NULL,
        PRIMARY KEY (a_id, b_id))"""])

# The explore page's tables again, where missing: a database migrated while another migration was also
# numbered 25 recorded 25 and 26 as applied without them.
migration!(28, [
    """CREATE TABLE IF NOT EXISTS document_links (
        from_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        to_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        PRIMARY KEY (from_id, to_id, kind))""",
    "CREATE INDEX IF NOT EXISTS document_links_to ON document_links (to_id)",
    """CREATE TABLE IF NOT EXISTS document_links_read (
        paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
        version TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS document_pairs (
        a_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        b_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        related INTEGER NOT NULL,
        user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        judged_at TEXT NOT NULL,
        PRIMARY KEY (a_id, b_id))"""])

"""
    judge_pair!(kb, caller, a, b, related)

Record whether documents `a` and `b`, both seen by `caller`, are related (`true`), not (`false`), or
undecided again (`nothing`).
"""
function judge_pair!(kb::KB, caller::Caller, a::AbstractString, b::AbstractString, related::Union{Bool,Nothing})
    a == b && error("A document is not a pair with itself")
    seen_document(kb, caller, a); seen_document(kb, caller, b)
    x, y = minmax(Int(paper_id(kb, a)), Int(paper_id(kb, b)))
    if related === nothing
        execute!(kb, "DELETE FROM document_pairs WHERE a_id = ? AND b_id = ?", (x, y))
    else
        execute!(kb, "INSERT OR REPLACE INTO document_pairs (a_id, b_id, related, user_id, judged_at) VALUES (?, ?, ?, ?, ?)",
                 (x, y, Int(related), something(caller.user_id, missing), now_iso()))
    end
    return nothing
end

# A pair judged: `{a, b, related}`, `related` true, false or null to take the judgement back.
route!("POST", "/api/graph/pair"; need = "paper.add") do c
    d = json_body(c)
    r = get(d, "related", nothing)
    judge_pair!(c.kb, c.caller, String(get(d, "a", "")), String(get(d, "b", "")), r === nothing ? nothing : Bool(r))
    return Dict("ok" => true)
end

# ── What a pair shares ───────────────────────────────────────────────────────────────────────────

"""The words a text is made of, for comparing documents: lowercased, plurals folded, common words left out."""
function pair_words(t::AbstractString)
    fold(w) = length(w) > 4 && endswith(w, "s") && !endswith(w, "ss") ? String(chop(w)) : w
    return Set(fold(w) for w in (lowercase(m.match) for m in eachmatch(r"[\p{L}][\p{L}\p{N}-]+", t))
               if length(w) > 3 && !(w in LABEL_STOPWORDS))
end

const PAIR_WORDS = Ref{Any}(nothing)               # (stamp, documents, how many use each word)

"How many documents' titles and abstracts use each word, and of how many: worked out again as documents come."
function word_counts(kb::KB)
    stamp = String(scalar(kb, "SELECT count(*) || ':' || coalesce(max(id), 0) FROM papers"))
    last = PAIR_WORDS[]
    last !== nothing && last[1] == stamp && return last[2], last[3]
    df, n = Dict{String,Int}(), 0
    for r in query(kb, """SELECT coalesce(p.title, w.title, '') || ' ' || coalesce(nullif(p.abstract, ''), w.abstract, '') AS t
                          FROM papers p LEFT JOIN watch w ON w.doc_id = p.doc_id""")
        n += 1
        foreach(w -> df[w] = get(df, w, 0) + 1, pair_words(String(r.t)))
    end
    PAIR_WORDS[] = (stamp, n, df)
    return n, df
end

"A document's text to find shared words in: its title and abstract, a record's text too."
function pair_text(kb::KB, id::AbstractString)
    r = only(query(kb, """SELECT coalesce(p.title, w.title, '') AS title, coalesce(nullif(p.abstract, ''), w.abstract, '') AS abstract
                          FROM papers p LEFT JOIN watch w ON w.doc_id = p.doc_id WHERE p.doc_id = ?""", (id,)))
    text = "$(r.title) $(r.abstract)"
    is_record(id) && (text *= " " * first(join((String(x["text"]) for x in record_document(kb, id)["sections"]), " "), 6000))
    return text
end

"""
    shared_words(kb, caller, pairs; most = 5) -> Vector{Vector{String}}

For each pair of documents, the words both use that few others do, the rarest first: what the two
have in common, as far as their words show it. Empty for a pair `caller` may not see.
"""
function shared_words(kb::KB, caller::Caller, pairs; most::Integer = 5)
    n, df = word_counts(kb)
    words = Dict{String,Set{String}}()
    function of(id)
        get!(words, id) do
            try seen_document(kb, caller, id); pair_words(pair_text(kb, id)) catch; Set{String}() end
        end
    end
    return map(pairs) do (a, b)
        common = [w for w in intersect(of(a), of(b)) if get(df, w, 0) <= max(2, n ÷ 5)]
        first(sort!(common; by = w -> (get(df, w, 0), w)), most)
    end
end

# What pairs of documents share (`?pairs=a,b;c,d`): for each, its words.
route!("GET", "/api/graph/shared") do c
    pairs = [Tuple(String.(split(p, ','))) for p in split(get(c.params, "pairs", ""), ';') if count(==(','), p) == 1]
    return Dict("shared" => shared_words(c.kb, c.caller, first(pairs, 60)))
end

# ── The map ───────────────────────────────────────────────────────────────────────────────────────

const EXPLORE_VERSION = 8

"How many of its nearest documents each document is drawn to."
const EXPLORE_NEIGHBOURS = 10

"""
The most documents laid out by t-SNE (see [`tsne`](@ref)): the rest are placed among their nearest documents.
"""
const EXPLORE_LAYOUT_LIMIT = 50_000

explore_path(c::Config) = joinpath(c.data_dir, "explore.json")

const EXPLORE_READ = Ref{Any}(nothing)            # (path, mtime, map): the map last read

"The map last made (see [`explore_map!`](@ref)), or `nothing`; read again once its file changes."
function read_explore(c::Config)
    p = explore_path(c)
    isfile(p) || return nothing
    t = mtime(p)
    last = EXPLORE_READ[]
    last !== nothing && last[1] == p && last[2] == t && return last[3]
    m = JSON.parsefile(p)
    EXPLORE_READ[] = (p, t, m)
    return m
end

"""
The documents with a vector in layer `l`, whatever their access: `(; id, point_id, text_sha, title,
access, read)`, `read` when the document was read in full (not known by its abstract alone), its title
the watch's where it has none of its own yet.
"""
explore_rows(kb::KB, l) = [r for r in query(kb, """
    SELECT p.doc_id AS id, e.point_id, e.text_sha, coalesce(p.title, w.title) AS title, p.access,
           EXISTS (SELECT 1 FROM parses s WHERE s.paper_id = p.id) AS read
    FROM embeddings e JOIN papers p ON p.id = e.paper_id LEFT JOIN watch w ON w.doc_id = p.doc_id
    WHERE e.layer = ? AND e.unit_key LIKE 'p:%' ORDER BY p.doc_id""", (l.name,))]

"What the map is made from: the vectors, and the landscape's clusters it takes its own from."
function explore_input(l, rows, land)
    clusters = land === nothing ? nothing : (get(land, "input_sha", ""), [(c["id"], c["name"]) for c in land["clusters"]])
    return bytes2hex(sha256(JSON.json(Dict("version" => EXPLORE_VERSION, "layer" => l.name, "clusters" => clusters,
                                            "docs" => [(r.id, r.text_sha, coalesce(r.title, ""), Bool(r.read)) for r in rows]))))
end

"Whether the map is missing, or made from vectors or clusters other than those now."
function explore_stale(kb::KB)
    l = try landscape_layer(kb.config) catch; return false end
    last = read_explore(kb.config)
    rows = explore_rows(kb, l)
    length(rows) < 3 && return false
    return last === nothing || get(last, "input_sha", "") != explore_input(l, rows, read_landscape(kb.config))
end

"""
    nearest_columns(X, k) -> Vector{Vector{Tuple{Int,Float64}}}

For each unit column of `X`, the `k` others nearest it by cosine similarity, nearest first, with
their similarity. Worked out a block of columns at a time, so the whole similarity matrix is never held.
"""
function nearest_columns(X::AbstractMatrix, k::Integer)
    n = size(X, 2)
    k = min(k, n - 1)
    out = Vector{Vector{Tuple{Int,Float64}}}(undef, n)
    for block in Iterators.partition(1:n, 512)
        S = X' * X[:, block]
        for (j, i) in enumerate(block)
            s = view(S, :, j)
            order = partialsortperm(s, 1:min(k + 1, n); rev = true)
            out[i] = first([(m, Float64(s[m])) for m in order if m != i], k)
        end
    end
    return out
end

"""
    nearest_library(X, own, k) -> Dict{Int,Vector{Tuple{Int,Float64}}}

For each column of `X` marked `own` (a person's notes and records), the `k` columns not marked nearest
it, with their similarity: what in the library a note is closest to, though other notes are closer.
"""
function nearest_library(X::AbstractMatrix, own::AbstractVector{Bool}, k::Integer)
    mine, lib = findall(own), findall(!, own)
    (isempty(mine) || isempty(lib)) && return Dict{Int,Vector{Tuple{Int,Float64}}}()
    S = X[:, lib]' * X[:, mine]
    return Dict(i => [(lib[m], Float64(S[m, j])) for m in partialsortperm(view(S, :, j), 1:min(k, length(lib)); rev = true)]
                for (j, i) in enumerate(mine))
end

"""
Positions `Y` (one row each) about their centre, scaled so all but the farthest few lie within -1 to 1:
a layout's outliers do not crowd the rest together. Those beyond are drawn in to 1.3.
"""
function centred(Y::AbstractMatrix)
    Y = Y .- sum(Y; dims = 1) ./ size(Y, 1)
    r = sort!(vec(maximum(abs, Y; dims = 2)))
    Y = Y ./ max(r[clamp(ceil(Int, 0.98 * length(r)), 1, length(r))], eps())
    return clamp.(Y, -1.3, 1.3)
end

"""
The maps made: of the documents read in full (`read`), and of those and the documents known only by
their abstract (`all`), each laid out and clustered by itself so the one is not shaped by the other.
"""
const EXPLORE_VIEWS = ("read", "all")

"""
    explore_map!(kb; force = false, progress, cancelled) -> Union{Nothing,NamedTuple}

Make the maps of the documents with a vector in the landscape's layer (see [`landscape_layer`](@ref)),
whoever may see them: those read in full, and those with the papers known only by their abstract (see
[`EXPLORE_VIEWS`](@ref)). In each, every document's nearest documents, its position on a 2D map and in
a 3D space by t-SNE (the most often near others first where there are more than `EXPLORE_LAYOUT_LIMIT`)
and by UMAP (see [`umap`](@ref)), and its cluster. The clusters are the landscape's, named from documents every reader sees; a document
the landscape leaves out joins the cluster whose centre is nearest. Without a landscape a map makes its
own, labelled by the words of the open documents' titles. Saved as `explore.json` in the data
directory; returns `(; data, changed)`, or `nothing` with fewer than three documents. Nothing is made
again while the vectors and clusters are as they were.
"""
function explore_map!(kb::KB; force::Bool = false, progress = msg -> nothing, cancelled = () -> false)
    c = kb.config
    l = try landscape_layer(c) catch; return nothing end
    rows = explore_rows(kb, l)
    length(rows) < 3 && return nothing
    land = read_landscape(c)
    input_sha = explore_input(l, rows, land)
    last = read_explore(c)
    !force && last !== nothing && get(last, "input_sha", "") == input_sha && return (; data = last, changed = false)

    progress("Exploring $(length(rows)) documents: reading their vectors")
    coll = collection_name(c, l)
    got = Qdrant.collection_exists(coll) ? fetch_vectors(coll, [r.point_id for r in rows]) : Dict()
    rows = [r for r in rows if haskey(got, r.point_id)]
    length(rows) < 3 && return nothing
    X = unit_columns(reduce(hcat, [Float64.(got[r.point_id][1]) for r in rows]))
    views = Dict{String,Any}()
    for (name, keep) in (("read", findall(r -> Bool(r.read), rows)), ("all", collect(eachindex(rows))))
        cancelled() && return nothing
        length(keep) < 3 && continue
        views[name] = explore_view(c, X[:, keep], rows[keep], land; progress, cancelled,
                                   what = name == "read" ? "documents read in full" : "documents")
    end
    cancelled() && return nothing
    data = Dict("version" => EXPLORE_VERSION, "input_sha" => input_sha, "built_at" => now_iso(), "layer" => l.name,
                "views" => views)
    mkpath(c.data_dir)
    write_atomic(explore_path(c), JSON.json(data))
    return (; data, changed = true)
end

"""
One map (see [`explore_map!`](@ref)): of the documents `rows`, whose unit vectors are `X`'s columns.
Without the landscape's clusters (`land`), it makes `clusters` of its own, or as many as suit its size.
"""
function explore_view(c::Config, X::AbstractMatrix, rows, land; progress, cancelled, what, clusters::Integer = c.landscape_clusters)
    n = length(rows)
    progress("Exploring $n $what: finding each one's nearest")
    near = nearest_columns(X, EXPLORE_NEIGHBOURS)
    library = nearest_library(X, [is_record(r.id) for r in rows], 5)
    # Laid out by t-SNE: all of them, or the most often near others where there are too many.
    laid = if n <= EXPLORE_LAYOUT_LIMIT
        collect(1:n)
    else
        often = zeros(Int, n)
        foreach(ns -> foreach(((m, _),) -> often[m] += 1, ns), near)
        sort!(partialsortperm(often, 1:EXPLORE_LAYOUT_LIMIT; rev = true))
    end
    progress("Exploring $n $what: laying out the map")
    flat = centred(tsne(X[:, laid]; dims = 2))
    cancelled() && return nothing
    progress("Exploring $n $what: laying out the space")
    deep = centred(tsne(X[:, laid]; dims = 3))
    cancelled() && return nothing
    # UMAP too, which keeps more of how the groups lie to each other: every document, its cost growing with their number.
    progress("Exploring $n $what: laying out the map and the space by UMAP")
    uflat, udeep = centred(umap(X; dims = 2, min_dist = 0.4)), centred(umap(X; dims = 3, min_dist = 0.4))
    cancelled() && return nothing
    # And PaCMAP, which keeps the arrangement between groups better still.
    progress("Exploring $n $what: laying out the map and the space by PaCMAP")
    pflat, pdeep = centred(pacmap(X; dims = 2)), centred(pacmap(X; dims = 3))
    pos2, pos3 = zeros(n, 2), zeros(n, 3)
    pos2[laid, :], pos3[laid, :] = flat, deep
    # The rest among their nearest laid out, a little apart.
    placed = falses(n); placed[laid] .= true
    for i in 1:n
        placed[i] && continue
        ms = [m for (m, _) in near[i] if placed[m]]
        isempty(ms) && continue
        pos2[i, :] = sum(pos2[ms, :]; dims = 1) ./ length(ms) .+ 0.01 .* randn(1, 2)
        pos3[i, :] = sum(pos3[ms, :]; dims = 1) ./ length(ms) .+ 0.01 .* randn(1, 3)
    end

    # The landscape's clusters, each centred on its members here; every document joins the nearest.
    wanted, clusters, assign = clusters, Dict{String,Any}[], ones(Int, n)
    col = Dict(r.id => i for (i, r) in enumerate(rows))
    if land !== nothing && !isempty(land["clusters"])
        members = Dict{Int,Vector{Int}}()
        for p in land["papers"]
            haskey(col, p["id"]) && push!(get!(members, Int(p["cluster"]), Int[]), col[p["id"]])
        end
        named = [cl for cl in land["clusters"] if haskey(members, Int(cl["id"]))]
        if !isempty(named)
            C = unit_columns(reduce(hcat, [vec(sum(X[:, members[Int(cl["id"])]]; dims = 2)) for cl in named]))
            assign = [argmax(view(X' * C, i, :)) for i in 1:n]
            clusters = [Dict("id" => j, "name" => String(cl["name"]), "description" => String(get(cl, "description", "")))
                        for (j, cl) in enumerate(named)]
        end
    end
    # With no landscape, clusters of its own, labelled by the words of the titles every reader sees.
    if isempty(clusters)
        k = wanted > 0 ? wanted : clamp(round(Int, sqrt(n / 4)), 2, 16)
        assign, _ = spherical_kmeans(X, k)
        open_titles = [coalesce(r.title, "") for r in rows if coalesce(r.access, "open") == "open"]
        all_titles = [coalesce(r.title, "") for r in rows]
        clusters = map(1:maximum(assign)) do j
            titles = [coalesce(rows[i].title, "") for i in 1:n if assign[i] == j && coalesce(rows[i].access, "open") == "open"]
            # One of documents only some see is labelled for those who see them all (see `explore_graph`).
            Dict("id" => j, "name" => isempty(titles) ? "" : keyword_label(titles, open_titles), "description" => "",
                 "closed_name" => keyword_label([all_titles[i] for i in 1:n if assign[i] == j], all_titles))
        end
    end

    # How central each is to its cluster: its similarity to the cluster's mean direction.
    centre = Dict(j => unit_columns(reshape(vec(sum(X[:, assign .== j]; dims = 2)), :, 1)) for j in unique(assign))
    central = [Float64(dot(view(X, :, i), view(centre[assign[i]], :, 1))) for i in 1:n]
    r4(x) = round(x; digits = 4)
    docs = Dict(r.id => Dict("x" => r4.(pos2[i, :]), "p" => r4.(pos3[i, :]), "ux" => r4.(uflat[i, :]), "up" => r4.(udeep[i, :]),
                             "px" => r4.(pflat[i, :]), "pp" => r4.(pdeep[i, :]), "c" => assign[i],
                             "k" => r4(central[i]), "near" => [[rows[m].id, r4(s)] for (m, s) in near[i]],
                             "lib" => [[rows[m].id, r4(s)] for (m, s) in get(library, i, ())])
                for (i, r) in enumerate(rows))
    return Dict("clusters" => clusters, "docs" => docs)
end

"""
    explore!(kb; progress, cancelled)

Bring what the explore page draws up to date: the links read from documents changed since (see
[`read_links!`](@ref)), and, where Qdrant answers, the map (see [`explore_map!`](@ref)) when its
vectors or clusters changed.
"""
function explore!(kb::KB; progress = msg -> nothing, cancelled = () -> false)
    read_links!(kb; progress, cancelled)
    cancelled() || !can_map(kb) || explore_map!(kb; progress, cancelled)
    return nothing
end

"Whether the map can be made here: Qdrant, which holds the vectors, answers."
can_map(kb::KB) = isempty(cannot_run(kb, "explore", String[]))

"The job bringing the explore page's map up to date, while one runs."
const EXPLORE_JOB = Ref{Union{Job,Nothing}}(nothing)
const EXPLORE_JOB_LOCK = ReentrantLock()

"""
    explore_soon!(kb) -> Union{Job,Nothing}

Start a job bringing the map and links up to date (see [`explore!`](@ref)) when they are behind and
none runs; the job running, or `nothing` when there is nothing to do (the map is behind only where
Qdrant answers).
"""
function explore_soon!(kb::KB)
    lock(EXPLORE_JOB_LOCK) do
        j = EXPLORE_JOB[]
        j !== nothing && j.status == :running && return j
        links_behind(kb) || (explore_stale(kb) && can_map(kb)) || return nothing
        EXPLORE_JOB[] = start_job("explore") do job
            explore!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        end
    end
end

"Whether some document's links have not been read as its text now is."
links_behind(kb::KB) = !ismissing(scalar(kb, """
    SELECT 1 FROM papers p LEFT JOIN records x ON x.paper_id = p.id LEFT JOIN parses s ON s.paper_id = p.id
    LEFT JOIN document_links_read r ON r.paper_id = p.id
    WHERE r.paper_id IS NULL OR r.version != CASE WHEN x.paper_id IS NOT NULL THEN 'r:' || x.content_sha
                                                  WHEN s.paper_id IS NOT NULL THEN 'p:' || s.file_sha || ':' || s.parser_version
                                                  ELSE '' END
    LIMIT 1"""))

# ── The graph a caller sees ───────────────────────────────────────────────────────────────────────

"The kinds of link the graph draws, people's: a paper's citations, a record's references, a finding's evidence, a task's links."
const GRAPH_LINKS = ("cites", "refers", "related", "evidence", "task")

"""
    explore_graph(kb, caller; center, depth, links, kinds, project, limit) -> Dict

The graph of what `caller` may see, for the explore page: its nodes (documents, and findings and tasks
where asked for and they see projects), each with its place on the map and in the space where it has
one, its cluster, its access, whether it was read in full, and whether it is held for `caller`
(`mine`); the links of `links`' kinds between them; and each document's nearest by meaning (`similar`,
with the similarity, and whether a link joins the two already). The documents known only by their
abstract are left out, and the map of those read in full drawn, unless `abstracts` or `center` is one
of them (`abstract_only` counts those left out). `center` keeps the nodes within `depth` steps of that
one, `project` those of a project and the nodes next to them; past `limit` nodes, the most linked are kept.
`view`, a map of some documents only (see [`subset_view!`](@ref)), is drawn instead, of its documents (`only`).
"""
function explore_graph(kb::KB, caller::Caller; center::AbstractString = "", depth::Integer = 1, links = GRAPH_LINKS,
                       kinds = ("paper", "record", "code", "resource", "finding"), project::AbstractString = "", limit::Integer = 3000, abstracts::Bool = false,
                       view = nothing, only = nothing)
    hidden = unfound_documents(kb, caller)
    rows = Dict(String(r.doc_id) => r for r in query(kb, """
        SELECT p.id, p.doc_id, p.kind, coalesce(p.title, w.title) AS title, coalesce(p.published, w.published) AS published, p.access,
               EXISTS (SELECT 1 FROM parses s WHERE s.paper_id = p.id) AS read, w.relevance AS rating, p.metadata_at
        FROM papers p LEFT JOIN watch w ON w.doc_id = p.doc_id"""))
    abstracts = abstracts || view !== nothing || !isempty(center) && haskey(rows, center) && !Bool(rows[center].read)
    m = read_explore(kb.config)
    v = view !== nothing ? view : m === nothing ? nothing : get(get(m, "views", Dict()), abstracts ? "all" : "read", nothing)
    docs = v === nothing ? Dict{String,Any}() : v["docs"]
    held = caller.user_id === nothing ? Set{String}() : held_documents(kb, caller.user_id)
    byrow = Dict(Int(r.id) => d for (d, r) in rows)
    seen(id) = haskey(rows, id) && !(id in hidden) && String(rows[id].kind) in kinds
    shown(id) = seen(id) && (abstracts || Bool(rows[id].read))

    # Edges, by node ids: people's links, then the nearest by meaning.
    E = Tuple{String,String,String}[]
    if any(in(links), ("cites", "refers"))
        for r in query(kb, "SELECT from_id, to_id, kind FROM document_links")
            String(r.kind) in links || continue
            a, b = get(byrow, Int(r.from_id), nothing), get(byrow, Int(r.to_id), nothing)
            a === nothing || b === nothing || !shown(a) || !shown(b) || push!(E, (a, b, String(r.kind)))
        end
    end
    judged = Dict{Tuple{String,String},Bool}()      # pairs people judged, related or not
    for r in query(kb, "SELECT a_id, b_id, related FROM document_pairs")
        a, b = get(byrow, Int(r.a_id), nothing), get(byrow, Int(r.b_id), nothing)
        (a === nothing || b === nothing || !shown(a) || !shown(b)) && continue
        judged[a < b ? (a, b) : (b, a)] = Bool(r.related)
        Bool(r.related) && "related" in links && push!(E, (a, b, "related"))
    end
    extra = Dict{String,Dict{String,Any}}()        # findings and tasks
    projects = can(caller, "tasks.view") ? visible_projects(kb, caller) : Set{String}()
    if "finding" in kinds && "evidence" in links && !isempty(projects)
        for r in query(kb, """SELECT f.number, f.claim, f.status, p.key, e.kind, e.target FROM findings f
                              JOIN projects p ON p.id = f.project_id LEFT JOIN finding_evidence e ON e.finding_id = f.id
                              WHERE f.archived_at IS NULL""")
            String(r.key) in projects || continue
            ref = "$(r.key)-F$(r.number)"
            get!(extra, ref) do
                Dict{String,Any}("id" => ref, "kind" => "finding", "title" => String(r.claim), "status" => String(r.status),
                                 "project" => String(r.key), "page" => ref_link(kb.config, ref))
            end
            ismissing(r.target) && continue
            t = String(r.target)
            String(r.kind) == "finding" ? push!(E, (ref, uppercase(t), "evidence")) : shown(t) && push!(E, (ref, t, "evidence"))
        end
    end
    if "task" in kinds && "task" in links && !isempty(projects)
        for r in query(kb, """SELECT p.key || '-' || t.number AS ref, t.title, t.status, p.key, l.target FROM task_links l
                              JOIN tasks t ON t.id = l.task_id JOIN projects p ON p.id = t.project_id
                              WHERE t.archived_at IS NULL AND t.declined_at IS NULL""")
            String(r.key) in projects && shown(String(r.target)) || continue
            ref = String(r.ref)
            get!(extra, ref) do
                Dict{String,Any}("id" => ref, "kind" => "task", "title" => String(r.title), "status" => String(r.status),
                                 "project" => String(r.key), "page" => ref_link(kb.config, ref))
            end
            push!(E, (ref, String(r.target), "task"))
        end
    end
    filter!(e -> (shown(e[1]) || haskey(extra, e[1])) && (shown(e[2]) || haskey(extra, e[2])), E)
    linked = Set{Tuple{String,String}}()
    for (a, b, _) in E
        push!(linked, (a, b)); push!(linked, (b, a))
    end
    S = Dict{Tuple{String,String},Float64}()            # each pair once, the nearer way round
    for (a, d) in docs
        shown(a) || continue
        for (b, s) in Iterators.flatten((d["near"], get(d, "lib", ())))
            shown(b) || continue
            key = a < b ? (a, b) : (b, a)
            S[key] = max(get(S, key, 0.0), Float64(s))
        end
    end

    # The nodes: those placed on the map, those people's links reach, the findings and tasks.
    ids = Set{String}(a for a in keys(docs) if shown(a))
    for (a, b, _) in E
        push!(ids, a); push!(ids, b)
    end
    adjacent = Dict{String,Set{String}}()
    neighbour!(a, b) = (push!(get!(Set{String}, adjacent, a), b); push!(get!(Set{String}, adjacent, b), a))
    foreach(e -> neighbour!(e[1], e[2]), E)
    foreach(k -> neighbour!(k[1], k[2]), keys(S))
    function around(seeds, steps)
        keep = Set{String}(s for s in seeds if s in ids)
        edge = copy(keep)
        for _ in 1:steps
            edge = Set{String}(b for a in edge for b in get(adjacent, a, ()) if !(b in keep))
            union!(keep, edge)
        end
        return keep
    end
    if !isempty(project)
        key = uppercase(strip(project))
        key in projects || sees_everything(caller) || return Dict{String,Any}("nodes" => [], "links" => [], "similar" => [], "clusters" => [], "built_at" => nothing,
                                                                     "abstracts" => abstracts, "abstract_only" => 0)
        seeds = [d for (d, ks) in documents_projects(kb) if key in ks]
        append!(seeds, [x["id"] for x in values(extra) if x["project"] == key])
        ids = around(seeds, 1)
    end
    isempty(center) || (ids = around([String(center)], clamp(depth, 1, 3)))
    only === nothing || intersect!(ids, only)
    degree = Dict{String,Int}()
    for (a, b, _) in E
        degree[a] = get(degree, a, 0) + 1; degree[b] = get(degree, b, 0) + 1
    end
    if length(ids) > limit
        ranked = sort!(collect(ids); by = i -> (-(3 * get(degree, i, 0) + (haskey(docs, i) ? 1 : 0)), i))
        ids = Set(first(ranked, limit))
        isempty(center) || push!(ids, String(center))
    end

    order = sort!(collect(ids))
    at = Dict(id => i - 1 for (i, id) in enumerate(order))
    year(r) = (d = coalesce(r.published, ""); occursin(r"^\d{4}", d) ? d[1:4] : "")
    nodes = map(order) do id
        haskey(extra, id) && return merge(extra[id], Dict("links" => get(degree, id, 0)))
        r, d = rows[id], get(docs, id, nothing)
        n = Dict{String,Any}("id" => id, "kind" => String(r.kind), "title" => coalesce(r.title, id), "year" => year(r),
                             "page" => explore_page(kb.config, id, r.metadata_at), "links" => get(degree, id, 0),
                             "access" => coalesce(r.access, "open"), "mine" => id in held, "read" => Bool(r.read))
        if d !== nothing
            n["x"], n["p"], n["cluster"] = d["x"], d["p"], d["c"]
            haskey(d, "ux") && (n["ux"] = d["ux"]; n["up"] = d["up"])
            haskey(d, "px") && (n["px"] = d["px"]; n["pp"] = d["pp"])
            haskey(d, "k") && (n["central"] = d["k"])
        end
        ismissing(r.rating) || (n["rating"] = Int(r.rating))     # the watch's judge's, 0 to 3
        n
    end
    # A cluster no open document names is labelled by its own titles for one who sees every document in it.
    sees_all(j) = all(id -> !(id in hidden), (id for (id, d) in docs if d["c"] == j))
    name(cl) = !isempty(cl["name"]) || !haskey(cl, "closed_name") || !sees_all(cl["id"]) ? cl["name"] : cl["closed_name"]
    clusters = v === nothing ? [] : [Dict("id" => cl["id"], "name" => name(cl), "description" => cl["description"],
                                          "size" => count(n -> get(n, "cluster", 0) == cl["id"], nodes)) for cl in v["clusters"]]
    everything = m === nothing ? Dict() : get(get(get(m, "views", Dict()), "all", Dict()), "docs", Dict())
    return Dict{String,Any}("nodes" => nodes,
                "links" => [Any[at[a], at[b], k] for (a, b, k) in E if haskey(at, a) && haskey(at, b)],
                "similar" => [Any[at[a], at[b], s, (a, b) in linked || get(judged, (a, b), false), haskey(judged, (a, b)) && !judged[(a, b)]]
                              for ((a, b), s) in S if haskey(at, a) && haskey(at, b)],
                "clusters" => clusters, "built_at" => m === nothing ? nothing : m["built_at"], "abstracts" => abstracts,
                "abstract_only" => view !== nothing ? 0 : count(id -> seen(id) && !Bool(rows[id].read), keys(everything)))
end

# The graph of what the caller may see, for the explore page (see `explore_graph`): `?center=<id>` and
# `?depth=1|2|3`, `?links=cites,refers,evidence,task`, `?kinds=paper,record,…`, `?project=KEY`,
# `?limit=`, `?abstracts=1` with the documents known only by their abstract, `?set=` a subset mapped by
# itself (see `explore_set`, with `?n=` a search's documents). Asking starts bringing the map up to date
# where it is behind (`job`, while it runs), or making the subset's.
route!("GET", "/api/graph") do c
    p = c.params
    list(k, default) = isempty(get(p, k, "")) ? default : Tuple(String.(strip.(split(p[k], ','))))
    links, kinds = list("links", GRAPH_LINKS), list("kinds", ("paper", "record", "code", "resource", "finding"))
    abstracts = get(p, "abstracts", "") in ("1", "true")
    isempty(get(p, "set", "")) ||
        return explore_set_graph(c.kb, c.caller, p["set"]; abstracts, links, kinds,
                                 n = int_param(p, "n", SUBSET_SEARCH.default, 1:SUBSET_SEARCH.most))
    g = explore_graph(c.kb, c.caller; center = get(p, "center", ""), depth = int_param(p, "depth", 1, 1:3), links, kinds,
                      project = get(p, "project", ""), limit = int_param(p, "limit", 3000, 1:20000), abstracts)
    job = try explore_soon!(c.kb) catch e
        @warn "The map could not be brought up to date" exception = e maxlog = 1
        nothing
    end
    g["job"] = job === nothing ? nothing : job.id
    return g
end

"""
Where a document's page is: on the site, or, for an arXiv paper whose record has not come yet (the site
has no page of it, see [`site_papers`](@ref)), on arXiv.
"""
explore_page(c::Config, id::AbstractString, metadata_at) =
    is_arxiv_id(id) && ismissing(metadata_at) ? "https://arxiv.org/abs/$id" : document_link(c, id)

"""
    explore_node(kb, caller, id) -> Dict

What the explore page's card says of document `id`, as far as `caller` may see it: its title, authors,
date, venue and abstract (the watch's where the document has none of its own yet), its summary and
topics as the summarizer shown for its kind wrote them, and whether it was read in full.
"""
function explore_node(kb::KB, caller::Caller, id::AbstractString)
    seen_document(kb, caller, id)
    rows = query(kb, """
        SELECT p.id, p.kind, p.metadata_at, coalesce(p.title, w.title) AS title, coalesce(p.authors, w.authors) AS authors,
               coalesce(p.published, w.published) AS published, p.journal_ref, coalesce(p.abstract, w.abstract) AS abstract,
               EXISTS (SELECT 1 FROM parses s WHERE s.paper_id = p.id) AS read
        FROM papers p LEFT JOIN watch w ON w.doc_id = p.doc_id WHERE p.doc_id = ?""", (id,))
    isempty(rows) && not_found("No document $id in the knowledge base")
    r = only(rows)
    wrote = [s for s in query(kb, """SELECT summarizer, text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%'
                                     ORDER BY created_at DESC""", (Int(r.id),))]
    want = kind_summarizer(kb.config, id)
    pick = findfirst(s -> s.summarizer == want, wrote)
    pick === nothing && !isempty(wrote) && (pick = 1)
    summary, topics = pick === nothing ? ("", String[]) : split_topics(String(wrote[pick].text))
    authors = try json_list(r.authors) catch; String[] end
    return Dict{String,Any}("id" => id, "kind" => String(r.kind), "title" => coalesce(r.title, id), "authors" => authors,
                            "published" => coalesce(r.published, ""), "venue" => coalesce(r.journal_ref, ""),
                            "abstract" => coalesce(r.abstract, ""), "summary" => summary, "topics" => topics,
                            "read" => Bool(r.read), "page" => explore_page(kb.config, id, r.metadata_at))
end

# What the explore page's card says of one document (`?id=`, see `explore_node`).
route!("GET", "/api/graph/node") do c
    explore_node(c.kb, c.caller, get(c.params, "id", ""))
end
