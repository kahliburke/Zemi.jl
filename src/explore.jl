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

# ── The map ───────────────────────────────────────────────────────────────────────────────────────

const EXPLORE_VERSION = 3

"How many of its nearest documents each document is drawn to."
const EXPLORE_NEIGHBOURS = 10

"""
The most documents laid out by t-SNE, whose cost grows with the square of their number: the rest are
placed among their nearest documents.
"""
const EXPLORE_LAYOUT_LIMIT = 4000

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

"Positions `Y` (one row each) scaled into -1 to 1 along their widest axis, about their centre."
function centred(Y::AbstractMatrix)
    Y = Y .- sum(Y; dims = 1) ./ size(Y, 1)
    return Y ./ max(maximum(abs, Y), eps())
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
a 3D space (t-SNE, the most often near others first where there are more than `EXPLORE_LAYOUT_LIMIT`),
and its cluster. The clusters are the landscape's, named from documents every reader sees; a document
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

"One map (see [`explore_map!`](@ref)): of the documents `rows`, whose unit vectors are `X`'s columns."
function explore_view(c::Config, X::AbstractMatrix, rows, land; progress, cancelled, what)
    n = length(rows)
    progress("Exploring $n $what: finding each one's nearest")
    near = nearest_columns(X, EXPLORE_NEIGHBOURS)
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
    clusters, assign = Dict{String,Any}[], ones(Int, n)
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
        k = c.landscape_clusters > 0 ? c.landscape_clusters : clamp(round(Int, sqrt(n / 4)), 2, 16)
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

    r4(x) = round(x; digits = 4)
    docs = Dict(r.id => Dict("x" => r4.(pos2[i, :]), "p" => r4.(pos3[i, :]), "c" => assign[i],
                             "near" => [[rows[m].id, r4(s)] for (m, s) in near[i]])
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
const GRAPH_LINKS = ("cites", "refers", "evidence", "task")

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
"""
function explore_graph(kb::KB, caller::Caller; center::AbstractString = "", depth::Integer = 1, links = GRAPH_LINKS,
                       kinds = ("paper", "record", "code", "resource", "finding"), project::AbstractString = "", limit::Integer = 3000, abstracts::Bool = false)
    hidden = unfound_documents(kb, caller)
    rows = Dict(String(r.doc_id) => r for r in query(kb, """
        SELECT p.id, p.doc_id, p.kind, coalesce(p.title, w.title) AS title, coalesce(p.published, w.published) AS published, p.access,
               EXISTS (SELECT 1 FROM parses s WHERE s.paper_id = p.id) AS read
        FROM papers p LEFT JOIN watch w ON w.doc_id = p.doc_id"""))
    abstracts = abstracts || !isempty(center) && haskey(rows, center) && !Bool(rows[center].read)
    m = read_explore(kb.config)
    v = m === nothing ? nothing : get(get(m, "views", Dict()), abstracts ? "all" : "read", nothing)
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
        for (b, s) in d["near"]
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
                             "page" => document_link(kb.config, id), "links" => get(degree, id, 0),
                             "access" => coalesce(r.access, "open"), "mine" => id in held, "read" => Bool(r.read))
        if d !== nothing
            n["x"], n["p"], n["cluster"] = d["x"], d["p"], d["c"]
        end
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
                "similar" => [Any[at[a], at[b], s, (a, b) in linked] for ((a, b), s) in S if haskey(at, a) && haskey(at, b)],
                "clusters" => clusters, "built_at" => m === nothing ? nothing : m["built_at"], "abstracts" => abstracts,
                "abstract_only" => count(id -> seen(id) && !Bool(rows[id].read), keys(everything)))
end

# The graph of what the caller may see, for the explore page (see `explore_graph`): `?center=<id>` and
# `?depth=1|2|3`, `?links=cites,refers,evidence,task`, `?kinds=paper,record,…`, `?project=KEY`,
# `?limit=`, `?abstracts=1` with the documents known only by their abstract. Asking starts bringing the
# map up to date where it is behind (`job`, while it runs).
route!("GET", "/api/graph") do c
    p = c.params
    list(k, default) = isempty(get(p, k, "")) ? default : Tuple(String.(strip.(split(p[k], ','))))
    g = explore_graph(c.kb, c.caller; center = get(p, "center", ""), depth = int_param(p, "depth", 1, 1:3),
                      links = list("links", GRAPH_LINKS), kinds = list("kinds", ("paper", "record", "code", "resource", "finding")),
                      project = get(p, "project", ""), limit = int_param(p, "limit", 3000, 1:20000),
                      abstracts = get(p, "abstracts", "") in ("1", "true"))
    job = try explore_soon!(c.kb) catch e
        @warn "The map could not be brought up to date" exception = e maxlog = 1
        nothing
    end
    g["job"] = job === nothing ? nothing : job.id
    return g
end
