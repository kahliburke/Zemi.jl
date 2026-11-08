# The landscape: where the papers lie relative to each other and to the group's focus areas. Every
# paper is placed by the vector of its title and abstract: its closeness to each focus area is its
# similarity to that area's description, clusters group papers by similarity, and a 2D map lays them
# out so that neighbours on the map are neighbours in meaning. The result is a JSON file the site
# draws from, published with the dataset, so seeing it needs neither Qdrant nor a model.

const LANDSCAPE_VERSION = 2

landscape_path(c::Config) = joinpath(c.data_dir, "landscape.json")

"The landscape last built or imported, or `nothing`."
function read_landscape(c::Config)
    path = landscape_path(c)
    return isfile(path) ? JSON.parsefile(path) : nothing
end

"""
    landscape!(kb; force = false, progress, cancelled) -> Union{Nothing,NamedTuple}

Build the landscape from the vectors in the landscape layer (see [`landscape_layer`](@ref)) and
save it as `landscape.json` in the data directory, returning `(; data, changed)`. Nothing is
rebuilt while the papers' vectors and classifications, the focus areas and the settings are as they
were and every cluster has its name. A publisher maps only what it publishes, and no codebase only
its projects' members see is mapped. Clusters are named by the configured summarizer in one
request, and keep their names while their papers stay much the same; when the summarizer cannot run
here, a cluster is labelled with its most distinctive title words until it can.
Returns `nothing` when no layer embeds papers by title and abstract, or fewer than five papers have
vectors there.
"""
function landscape!(kb::KB; force::Bool = false, progress = msg -> nothing, cancelled = () -> false)
    c = kb.config
    isempty(c.landscape_layer) && isempty(record_layers(c)) && return nothing
    l = landscape_layer(c)
    rows = [r for r in query(kb, """
        SELECT p.doc_id AS id, p.title, p.kind, p.published, p.added_at, p.primary_category AS category, e.point_id, e.text_sha,
               (SELECT min(posted_at) FROM mentions m WHERE m.paper_id = p.id) AS posted,
               (SELECT data FROM classifications k WHERE k.paper_id = p.id) AS classification
        FROM embeddings e JOIN papers p ON p.id = e.paper_id
        WHERE e.layer = ? AND e.unit_key LIKE 'p:%' AND $(kind_in(k -> k.landscape; on = "p")) AND $(open_sql(on = "p"))
        ORDER BY p.doc_id""", (l.name,))
            # The site every reader is served draws it: not a document only some may see.
            if c.dataset.role != :publish || publishable(kb, r.id)]
    length(rows) < 5 && return nothing
    k = c.landscape_clusters > 0 ? c.landscape_clusters : clamp(round(Int, sqrt(length(rows) / 4)), 2, 16)
    input_sha = bytes2hex(sha256(JSON.json(Dict("version" => LANDSCAPE_VERSION, "layer" => l.name, "k" => k,
        "areas" => [(f.name, f.description) for f in c.group.focus_areas],
        # A paper's classification is shown with it, so classifying one rebuilds the landscape too.
        "papers" => [(r.id, r.text_sha, coalesce(r.title, ""), coalesce(r.classification, "")) for r in rows]))))
    last = read_landscape(c)
    if !force && last !== nothing && get(last, "input_sha", "") == input_sha && all(cl -> cl["named"], last["clusters"])
        return (; data = last, changed = false)
    end

    progress("Mapping $(length(rows)) papers: reading their vectors")
    coll = collection_name(c, l)
    got = Qdrant.collection_exists(coll) ? fetch_vectors(coll, [r.point_id for r in rows]) : Dict()
    forget_lost_vectors!(kb, l.name, [r.point_id for r in rows if !haskey(got, r.point_id)])
    rows = [r for r in rows if haskey(got, r.point_id)]
    length(rows) < 5 && return nothing
    X = unit_columns(reduce(hcat, [Float64.(got[r.point_id][1]) for r in rows]))
    focus = c.group.focus_areas
    # papers × areas: cosine similarity. Without focus areas no paper is nearer one than another.
    scores = isempty(focus) ? zeros(size(X, 2), 0) :
        X' * unit_columns(reduce(hcat, [Float64.(query_vector(c, l, f.description)) for f in focus]))
    relevance = isempty(focus) ? zeros(size(X, 2)) : vec(maximum(scores; dims = 2))
    nearest = [isempty(focus) ? nothing : argmax(view(scores, i, :)) for i in axes(scores, 1)]
    cancelled() && return nothing

    progress("Mapping $(length(rows)) papers: finding $k clusters")
    assign, centres = spherical_kmeans(X, k)
    progress("Mapping $(length(rows)) papers: laying out the map")
    Y = tsne(X)
    Y = (Y .- minimum(Y; dims = 1)) ./ max.(maximum(Y; dims = 1) .- minimum(Y; dims = 1), eps())

    members = [findall(==(j), assign) for j in 1:k]
    # The most typical papers first: those nearest the cluster's centre.
    typical = [sort(m; by = i -> -dot(view(X, :, i), view(centres, :, j))) for (j, m) in enumerate(members)]
    titles = [coalesce(r.title, r.id) for r in rows]
    progress("Mapping $(length(rows)) papers: naming the clusters")
    # Named from the titles papers have: an id says nothing a name could be made from.
    named_from = [[rows[i].title for i in m if !ismissing(rows[i].title) && !isempty(rows[i].title)] for m in typical]
    names = name_clusters!(kb, [[rows[i].id for i in m] for m in typical], named_from, titles)

    mean(v) = isempty(v) ? 0.0 : sum(v) / length(v)
    r3(x) = round(x; digits = 4)
    # When a paper was published (a year, a month or a day, as known), and when the group first had it:
    # first mentioned, or else added.
    published(r) = (d = strip(coalesce(r.published, "")); occursin(r"^\d{4}(-\d{2}){0,2}", d) ? match(r"^\d{4}(-\d{2}){0,2}", d).match : "")
    added(r) = !ismissing(r.posted) ? Dates.format(unix2datetime(r.posted), "yyyy-mm-dd") : first(r.added_at, 10)
    function llm(r)
        ismissing(r.classification) && return (nothing, nothing)
        d = JSON.parse(r.classification)
        return (get(d, "relevance", nothing), get(d, "one_line", nothing))
    end
    papers = map(enumerate(rows)) do (i, r)
        rel, line = llm(r)
        Dict("id" => r.id, "title" => titles[i], "kind" => r.kind, "category" => coalesce(r.category, ""),
             "page" => document_page(r.id),
             "published" => published(r), "added" => added(r), "x" => r3(Y[i, 1]), "y" => r3(Y[i, 2]), "cluster" => assign[i],
             "scores" => r3.(scores[i, :]), "relevance" => r3(relevance[i]), "area" => nearest[i],
             "llm_relevance" => rel, "one_line" => line)
    end
    clusters = [Dict("id" => j, "name" => names[j].name, "description" => names[j].description,
                     "named" => names[j].named, "size" => length(m),
                     "x" => r3(mean(Y[m, 1])), "y" => r3(mean(Y[m, 2])),
                     "scores" => [r3(mean(scores[m, a])) for a in axes(scores, 2)],
                     "relevance" => r3(mean(relevance[m])))
                for (j, m) in enumerate(members)]
    data = Dict("version" => LANDSCAPE_VERSION, "input_sha" => input_sha, "built_at" => now_iso(), "layer" => l.name,
                "named_by" => c.summarizer,
                "focus_areas" => [Dict("name" => f.name, "description" => f.description) for f in c.group.focus_areas],
                "clusters" => clusters, "papers" => papers)
    mkpath(c.data_dir)
    write(landscape_path(c), JSON.json(data))
    return (; data, changed = true)
end

unit_columns(X) = X ./ max.(sqrt.(sum(abs2, X; dims = 1)), eps())

# ── Naming the clusters ───────────────────────────────────────────────────────────────────────────

const CLUSTER_SYSTEM = "You name groups of research papers for a research group's knowledge base. Reply with a JSON object only."

"""
    name_clusters!(kb, members, member_titles, all_titles) -> Vector{NamedTuple}

A `(; name, description, named)` for each cluster, given its papers' ids and titles (most typical
first). A cluster whose papers were named before keeps that name, as does one that shares at least
60% of its papers with a named one. The rest are named together by the configured summarizer, so
their names tell them apart; where it cannot run, or a cluster has no titles yet, they get their
most distinctive title words and `named = false`.
"""
function name_clusters!(kb::KB, members, member_titles, all_titles)
    known = [(; ids = Set{String}(JSON.parse(r.members)), r.name, r.description)
             for r in query(kb, "SELECT members, name, description FROM cluster_names")]
    jaccard(a, b) = length(intersect(a, b)) / max(length(union(a, b)), 1)
    out = Vector{Any}(nothing, length(members))
    for (j, ids) in enumerate(members)
        s = Set(ids)
        best = isempty(known) ? nothing : argmax(n -> jaccard(n.ids, s), known)
        if best !== nothing && jaccard(best.ids, s) >= 0.6
            out[j] = (; best.name, best.description, named = true)
            remember_cluster!(kb, ids, best.name, best.description)
        end
    end
    todo = [j for j in eachindex(out) if out[j] === nothing && !isempty(member_titles[j])]
    s = summarizer(kb.config, kb.config.summarizer)
    if !isempty(todo) && summarizer_problem(s) === nothing
        try
            taken = [o.name for o in out if o !== nothing]
            reply = reply_json(ask(s, CLUSTER_SYSTEM, cluster_prompt(kb.config, todo, member_titles, taken)), "The cluster namer")
            for g in get(reply, "groups", [])
                j = get(g, "group", nothing)
                (j isa Integer && j in todo && out[j] === nothing) || continue
                name, description = String(get(g, "name", "")), String(get(g, "description", ""))
                isempty(name) && continue
                out[j] = (; name, description, named = true)
                remember_cluster!(kb, members[j], name, description)
            end
        catch e
            e isa InterruptException && rethrow()
            @warn "Naming the landscape's clusters failed; they are labelled by their words for now" exception = e
        end
    end
    for j in eachindex(out)
        out[j] === nothing || continue
        out[j] = (; name = keyword_label(member_titles[j], all_titles), description = "", named = false)
    end
    return out
end

function remember_cluster!(kb::KB, ids, name, description)
    sorted = sort(collect(ids))
    execute!(kb, "INSERT OR REPLACE INTO cluster_names VALUES (?, ?, ?, ?, ?)",
             (bytes2hex(sha256(join(sorted, ","))), JSON.json(sorted), name, description, now_iso()))
end

function cluster_prompt(c::Config, todo, member_titles, taken)
    io = IOBuffer()
    println(io, "The group: ", c.group.description, "\n")
    println(io, "Its focus areas:")
    foreach(f -> println(io, "- ", f.name, ": ", f.description), c.group.focus_areas)
    println(io, """

        The papers the group has shared were clustered by the similarity of their titles and abstracts.
        Name each group below: a name of two to five words saying what its papers have in common,
        specific enough to tell it apart from the other groups, and a one-sentence description.""")
    isempty(taken) || println(io, "Groups already named (use other names): ", join(taken, "; "), ".")
    for j in todo
        ts = member_titles[j]
        println(io, "\nGroup $j ($(length(ts)) papers; the most typical first):")
        foreach(t -> println(io, "- ", t), first(ts, 25))
    end
    println(io, """\nReply as {"groups": [{"group": <number>, "name": "...", "description": "..."}]}, one entry per group.""")
    return String(take!(io))
end

const LABEL_STOPWORDS = Set(split("""a an and are as at by for from in into is of on or the to with via using use based
    its their this that we our new study analysis towards toward under over between through than via""", r"\s+"))

"A cluster's three most distinctive title words, against all titles."
function keyword_label(titles, all_titles)
    words(t) = unique(w for w in (lowercase(m.match) for m in eachmatch(r"[\p{L}][\p{L}\p{N}-]+", t))
                      if length(w) > 2 && !(w in LABEL_STOPWORDS))
    df = Dict{String,Int}()
    foreach(t -> foreach(w -> df[w] = get(df, w, 0) + 1, words(t)), all_titles)
    tf = Dict{String,Int}()
    foreach(t -> foreach(w -> tf[w] = get(tf, w, 0) + 1, words(t)), titles)
    score(w) = tf[w] / length(titles) * log(length(all_titles) / df[w])
    top = first(sort!(collect(keys(tf)); by = w -> (-score(w), w)), 3)
    return isempty(top) ? "Unnamed" : join(top, " · ")
end

# ── Clustering and layout ─────────────────────────────────────────────────────────────────────────

"""
    spherical_kmeans(X, k; iterations = 100, seed = 1) -> (assign, centres)

Cluster the unit columns of `X` by cosine similarity: k-means++ starting centres from a fixed
seed, so the same vectors give the same clusters. Clusters are numbered by size, largest first.
"""
function spherical_kmeans(X::AbstractMatrix, k::Integer; iterations::Integer = 100, seed::Integer = 1)
    n = size(X, 2)
    k = min(k, n)
    rng = Random.Xoshiro(seed)
    picks = [rand(rng, 1:n)]
    far = 1 .- X' * X[:, picks[1]]
    while length(picks) < k
        w = max.(far, 0) .^ 2
        i = sum(w) > 0 ? searchsortedfirst(cumsum(w), rand(rng) * sum(w)) : rand(rng, 1:n)
        push!(picks, clamp(i, 1, n))
        far = min.(far, 1 .- X' * X[:, picks[end]])
    end
    C = X[:, picks]
    assign = zeros(Int, n)
    for _ in 1:iterations
        S = C' * X
        next = [argmax(view(S, :, i)) for i in 1:n]
        next == assign && break
        assign = next
        for j in 1:k
            m = vec(sum(X[:, assign .== j]; dims = 2))
            if iszero(m)                       # an empty cluster restarts at the worst-placed paper
                worst = argmin([S[assign[i], i] for i in 1:n])
                m = X[:, worst]
                assign[worst] = j
            end
            C[:, j] = m / norm(m)
        end
    end
    order = sortperm([count(==(j), assign) for j in 1:k]; rev = true)
    renumber = invperm(order)
    return [renumber[a] for a in assign], C[:, order]
end

"""
    tsne(X; perplexity = 30, iterations = 1000) -> Matrix

A 2D layout of the unit columns of `X` (one row per column) by t-SNE over their cosine distances,
starting from their two principal components, so the layout is the same for the same vectors and
moves little as papers are added.
"""
function tsne(X::AbstractMatrix; perplexity::Real = 30, iterations::Integer = 1000)
    n = size(X, 2)
    D = max.(2 .- 2 .* (X' * X), 0)                 # squared distances between unit vectors
    P = zeros(n, n)
    target = log(min(perplexity, (n - 1) / 3))
    for i in 1:n
        d = D[:, i]
        nearest = minimum(d[j] for j in 1:n if j != i)    # (subtracted before exponentiating, for range)
        lo, hi, beta = 0.0, Inf, 1.0
        p = zeros(n)
        for _ in 1:100
            p .= exp.(-beta .* (d .- nearest))
            p[i] = 0
            s = sum(p)
            H = log(s) + beta * (sum(d .* p) / s - nearest)     # the entropy of row i
            abs(H - target) < 1e-5 && break
            if H > target
                lo = beta; beta = isinf(hi) ? 2beta : (beta + hi) / 2
            else
                hi = beta; beta = (beta + lo) / 2
            end
        end
        P[:, i] = p ./ sum(p)
    end
    P = max.((P .+ P') ./ (2n), 1e-12)
    # Start from the principal components, each signed so its skew is positive, at a small scale.
    centred = X .- sum(X; dims = 2) ./ n
    U, S, _ = svd(centred')
    Y = U[:, 1:2] .* S[1:2]'
    for a in 1:2
        sum(Y[:, a] .^ 3) < 0 && (Y[:, a] .*= -1)
    end
    Y .*= 1e-4 / max(sqrt(sum(abs2, Y[:, 1]) / n), eps())
    gains, step = ones(n, 2), zeros(n, 2)
    rate = max(n / 48, 50.0)
    for it in 1:iterations
        exaggeration, momentum = it <= 250 ? (12.0, 0.5) : (1.0, 0.8)
        sq = sum(abs2, Y; dims = 2)
        num = 1 ./ (1 .+ sq .+ sq' .- 2 .* (Y * Y'))
        num[diagind(num)] .= 0
        Q = max.(num ./ sum(num), 1e-12)
        W = (exaggeration .* P .- Q) .* num
        grad = 4 .* (vec(sum(W; dims = 2)) .* Y .- W * Y)
        same = sign.(grad) .== sign.(step)
        gains .= max.(ifelse.(same, gains .* 0.8, gains .+ 0.2), 0.01)
        step .= momentum .* step .- rate .* gains .* grad
        Y .+= step
        Y .-= sum(Y; dims = 1) ./ n
    end
    return Y
end
