# Vector storage in Qdrant through the package's own client (qdrant.jl), which logs failures and
# returns false or an error Dict; these wrappers turn those into exceptions.

collection_name(c::Config, l::Layer) = "$(c.collection_prefix)_$(replace(l.name, r"[^A-Za-z0-9_-]" => "_"))"

function qdrant_check(ok, what)
    ok === true && return nothing
    error("Qdrant: $what failed (is Qdrant running at $(Qdrant.url())?)")
end

"""
    ensure_layer!(kb, layer, dim) -> String

Make sure the layer is recorded and its collection exists with vectors of size `dim`, returning the
collection name. A layer's model is fixed once it has vectors: changing the model under an
existing layer name is an error rather than a silent mix of incompatible vectors.
"""
function ensure_layer!(kb::KB, l::Layer, dim::Integer)
    coll = collection_name(kb.config, l)
    rows = query(kb, "SELECT model, unit, dim FROM layers WHERE name = ?", (l.name,))
    if isempty(rows)
        execute!(kb, "INSERT INTO layers VALUES (?, ?, ?, ?, ?, ?)",
            (l.name, l.model, string(l.unit), dim, coll, now_iso()))
    else
        r = first(rows)
        (r.model == l.model && r.dim == dim && r.unit == string(l.unit)) || error(
            "Layer $(l.name) holds $(r.dim)-d $(r.unit) vectors from $(r.model); the config now says " *
            "$(l.unit) with $(l.model) ($dim-d). Give the new configuration its own layer name, or " *
            "drop the old layer with `drop_layer!`.")
    end
    if !Qdrant.collection_exists(coll)
        qdrant_check(Qdrant.create_collection(coll; vector_size = Int(dim), distance = "Cosine"), "creating $coll")
    end
    return coll
end

function upsert_vectors!(coll::AbstractString, ids, vectors, payloads)
    points = Dict[Dict("id" => id, "vector" => v, "payload" => p) for (id, v, p) in zip(ids, vectors, payloads)]
    for batch in Iterators.partition(points, 256)
        qdrant_check(Qdrant.upsert_points(coll, collect(batch)), "upserting into $coll")
    end
end

function delete_vectors!(coll::AbstractString, ids)
    isempty(ids) && return
    qdrant_check(Qdrant.delete_points(coll, collect(ids)), "deleting from $coll")
end

"""
    vector_search(coll, vector; limit, filter) -> Vector{@NamedTuple{key::String, score::Float64, payload}}
"""
function vector_search(coll::AbstractString, vector::AbstractVector; limit::Integer = 50, filter = nothing)
    res = Qdrant.search(coll, Float64.(vector); limit = Int(limit), filter)
    if length(res) == 1 && haskey(first(res), "error")
        error("Qdrant search in $coll failed: $(first(res)["error"])")
    end
    return [(key = String(r["payload"]["unit"]), score = Float64(r["score"]), payload = r["payload"]) for r in res]
end

"""
    drop_layer!(kb, name)

Delete a layer's collection and its embedding records.
"""
function drop_layer!(kb::KB, name::AbstractString)
    rows = query(kb, "SELECT collection FROM layers WHERE name = ?", (name,))
    isempty(rows) && not_found("No layer named $name has been embedded")
    # Unreachable, Qdrant would seem to have no collection, and the records would go while it stayed.
    Qdrant.ping() || error("Qdrant is not reachable at $(Qdrant.url()), so the layer was left as it is")
    Qdrant.collection_exists(first(rows).collection) &&
        qdrant_check(Qdrant.delete_collection(first(rows).collection), "deleting $(first(rows).collection)")
    transaction(kb) do
        execute!(kb, "DELETE FROM embeddings WHERE layer = ?", (name,))
        execute!(kb, "DELETE FROM layers WHERE name = ?", (name,))
    end
end

"""
    forget_lost_vectors!(kb, layer, point_ids) -> Bool

Forget the embedding records of points Qdrant no longer has (its storage lost, say), so a sync embeds
them again rather than taking them to be done; only while Qdrant answers, since unreachable it would
seem to have none. Returns whether they were forgotten.
"""
function forget_lost_vectors!(kb::KB, layer::AbstractString, point_ids)
    (isempty(point_ids) || !Qdrant.ping()) && return false
    @warn "Qdrant has lost $(length(point_ids)) vector(s) in $layer; a sync embeds them again"
    transaction(kb) do
        foreach(p -> execute!(kb, "DELETE FROM embeddings WHERE layer = ? AND point_id = ?", (layer, p)), point_ids)
    end
    return true
end

"""
    fetch_vectors(coll, ids) -> Dict{String,Tuple{Vector{Float32},Dict{String,Any}}}

Points by id, each with its vector and payload; ids Qdrant does not have are left out.
"""
function fetch_vectors(coll::AbstractString, ids)
    out = Dict{String,Tuple{Vector{Float32},Dict{String,Any}}}()
    for batch in Iterators.partition(collect(String, ids), 256)
        # Retried: Qdrant closes idle kept-alive connections, and the next request on one is reset.
        points = with_retry(() -> Qdrant.get_points(coll, batch), "Qdrant fetch from $coll")
        for p in points
            out[string(p["id"])] = (Float32.(p["vector"]), Dict{String,Any}(p["payload"]))
        end
    end
    return out
end
