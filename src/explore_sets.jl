# A map of some of the documents only: a cluster of the full map, a project's library, what a search
# finds, or the documents a drift passed through. Laid out and clustered by itself, a subset spreads
# over the whole map, and a cluster of the full map comes apart into its own.

"The fewest documents a subset is mapped with: fewer have no structure to lay out."
const SUBSET_LEAST = Ref(20)

"The most documents a subset is mapped with."
const SUBSET_MOST = 2000

"How many documents a search's subset takes, by default and at most."
const SUBSET_SEARCH = (default = 100, most = 500)

"How many of each drifted-through document's nearest join a drift's subset, so its path has context."
const SUBSET_DRIFT_NEAR = 5

"""
    explore_set(kb, caller, spec; abstracts = false, n = 100) -> (; spec, kind, name, ids)

The documents of subset `spec` that `caller` may see and the full map places:

- `cluster:<id>`: a cluster of the full map (of the documents read in full, or with `abstracts` of all);
- `project:<KEY>`: the papers project `KEY`'s library keeps and the documents the project holds;
- `q:<query>`: the `n` documents a search for the query ranks first;
- `docs:<id>,<id>,…`: those documents (a drift's) and the nearest few of each.

`name` says what the subset is, for the page's breadcrumb.
"""
function explore_set(kb::KB, caller::Caller, spec::AbstractString; abstracts::Bool = false, n::Integer = SUBSET_SEARCH.default)
    kind, arg = occursin(':', spec) ? split(spec, ':'; limit = 2) : (spec, "")
    kind, arg = String(kind), String(strip(arg))
    isempty(arg) && error("Which documents? Give $kind:<…>.")
    m = read_explore(kb.config)
    m === nothing && error("The map is not made yet.")
    views = get(m, "views", Dict())
    placed = get(get(views, "all", Dict()), "docs", Dict())
    hidden = unfound_documents(kb, caller)
    ids, name = if kind == "cluster"
        v = get(views, abstracts ? "all" : "read", nothing)
        v === nothing && error("The map has no such view.")
        j = tryparse(Int, arg)
        cl = j === nothing ? nothing : findfirst(c -> c["id"] == j, v["clusters"])
        cl === nothing && error("No cluster $arg on the map.")
        label = v["clusters"][cl]["name"]
        [id for (id, d) in v["docs"] if d["c"] == j], isempty(label) ? "Cluster $j" : label
    elseif kind == "project"
        key = uppercase(arg)
        key in visible_projects(kb, caller) || sees_everything(caller) || error("No project $key.")
        held = [d for (d, ks) in documents_projects(kb) if key in ks]
        collect(union(library_papers(kb, key), held)), "$key's library"
    elseif kind == "q"
        hits = search(kb, arg; limit = clamp(n, 1, SUBSET_SEARCH.most), except = hidden)
        [h.doc_id for h in hits], "“$(arg)”"
    elseif kind == "docs"
        given = unique(String.(strip.(split(arg, ','))))
        out = copy(given)
        for id in given, (near, _) in Iterators.take(get(get(placed, id, Dict()), "near", ()), SUBSET_DRIFT_NEAR)
            push!(out, String(near))
        end
        unique(out), "A drift through $(length(given)) documents"
    else
        error("No kind of subset $kind: cluster, project, q or docs.")
    end
    ids = sort!([String(id) for id in ids if haskey(placed, id) && !(id in hidden)])
    length(ids) > SUBSET_MOST && (ids = ids[1:SUBSET_MOST])
    return (; spec = String(spec), kind, name, ids)
end

# The subsets' maps, by the documents and the full map they were made with: the most recently used kept.
const SUBSET_VIEWS = Dict{String,Any}()
const SUBSET_USED = String[]
const SUBSET_KEPT = 24
const SUBSET_LOCK = ReentrantLock()
const SUBSET_JOBS = Dict{String,Job}()

"""
What a subset's map is made from: its documents, and the full map's input, which changes as their
vectors and titles do (see [`explore_input`](@ref)).
"""
subset_key(m, ids) = bytes2hex(sha256(JSON.json((get(m, "input_sha", ""), ids))))

"The map of subset `ids` made already, or `nothing` (see [`subset_view!`](@ref))."
function cached_subset(kb::KB, ids)
    m = read_explore(kb.config)
    m === nothing && return nothing
    key = subset_key(m, ids)
    lock(SUBSET_LOCK) do
        v = get(SUBSET_VIEWS, key, nothing)
        v === nothing || (filter!(!=(key), SUBSET_USED); push!(SUBSET_USED, key))
        v
    end
end

"""
    subset_view!(kb, ids; progress, cancelled) -> Union{Dict,Nothing}

The map of documents `ids` alone, made as the full map is (see [`explore_view`](@ref)), with clusters
of its own: kept for the next to ask, as long as the full map is as it was.
"""
function subset_view!(kb::KB, ids; progress = msg -> nothing, cancelled = () -> false)
    v = cached_subset(kb, ids)
    v === nothing || return v
    c, m = kb.config, read_explore(kb.config)
    l = landscape_layer(c)
    want = Set(ids)
    rows = [r for r in explore_rows(kb, l) if r.id in want]
    got = fetch_vectors(collection_name(c, l), [r.point_id for r in rows])
    rows = [r for r in rows if haskey(got, r.point_id)]
    length(rows) < 3 && return nothing
    X = unit_columns(reduce(hcat, [Float64.(got[r.point_id][1]) for r in rows]))
    v = explore_view(c, X, rows, nothing; progress, cancelled, what = "documents in this set", clusters = 0)
    (v === nothing || cancelled()) && return nothing
    key = subset_key(m, ids)
    lock(SUBSET_LOCK) do
        SUBSET_VIEWS[key] = v
        filter!(!=(key), SUBSET_USED); push!(SUBSET_USED, key)
        while length(SUBSET_USED) > SUBSET_KEPT
            delete!(SUBSET_VIEWS, popfirst!(SUBSET_USED))
        end
    end
    return v
end

"The job making subset `ids`' map (see [`subset_view!`](@ref)), one at a time for each subset."
function subset_soon!(kb::KB, ids)
    key = subset_key(read_explore(kb.config), ids)
    lock(SUBSET_LOCK) do
        j = get(SUBSET_JOBS, key, nothing)
        j !== nothing && j.status == :running && return j
        SUBSET_JOBS[key] = start_job("explore a set") do job
            try
                subset_view!(kb, ids; progress = msg -> report!(job, msg), cancelled = () -> cancelled(job))
            finally
                lock(() -> delete!(SUBSET_JOBS, key), SUBSET_LOCK)
            end
            nothing
        end
    end
end

"""
    explore_set_graph(kb, caller, spec; n, kwargs...) -> Dict

The graph of subset `spec` (see [`explore_set`](@ref)) for the explore page: as [`explore_graph`](@ref)
draws the full map's, with `set` saying what the subset is. While its map is being made the graph is
empty and `job` the job making it; with fewer than `SUBSET_LEAST` documents it is empty and `set.few`.
"""
function explore_set_graph(kb::KB, caller::Caller, spec::AbstractString; abstracts::Bool = false,
                           n::Integer = SUBSET_SEARCH.default, kw...)
    s = explore_set(kb, caller, spec; abstracts, n)
    about = Dict{String,Any}("spec" => s.spec, "kind" => s.kind, "name" => s.name, "count" => length(s.ids),
                             "least" => SUBSET_LEAST[], "few" => length(s.ids) < SUBSET_LEAST[])
    empty(; job = nothing) = Dict{String,Any}("nodes" => [], "links" => [], "similar" => [], "clusters" => [],
                                              "built_at" => nothing, "abstracts" => true, "abstract_only" => 0,
                                              "set" => about, "job" => job)
    about["few"] && return empty()
    v = cached_subset(kb, s.ids)
    v === nothing && return empty(; job = subset_soon!(kb, s.ids).id)
    g = explore_graph(kb, caller; kw..., view = v, only = Set(s.ids))
    g["set"], g["job"] = about, nothing
    return g
end
