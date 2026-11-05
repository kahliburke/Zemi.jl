# A small client for Qdrant's REST API: the collections and points the embedding layers keep their
# vectors in. Failures are logged and answered as `false` (or, for a search, an entry with an
# "error"), which `vectors.jl` turns into errors that say what failed.
module Qdrant

using HTTP, JSON
import ..with_retry, ..body_text

const URL = Ref("http://localhost:6333")
const KEY = Ref("")
# Where Qdrant is and the key it takes, `() -> (url, key)`, asked again every few seconds: a Qdrant
# Kaimon runs takes a new key, and may take another port, each time it starts (see `qdrant_endpoint`).
const ENDPOINT = Ref{Any}(nothing)
const RESOLVED_AT = Ref(0.0)
const RESOLVE_SECONDS = 5.0

"Use the Qdrant at `url`, with API key `key`; or the one `f() -> (url, key)` says, asked again as it goes."
use!(url::AbstractString, key::AbstractString = "") = (ENDPOINT[] = nothing; URL[] = rstrip(url, '/'); KEY[] = key; nothing)
use!(f::Function) = (ENDPOINT[] = f; RESOLVED_AT[] = 0.0; url(); nothing)

"The Qdrant in use: its address."
function url()
    f = ENDPOINT[]
    if f !== nothing && time() - RESOLVED_AT[] > RESOLVE_SECONDS
        try
            u, k = f()
            URL[], KEY[] = rstrip(u, '/'), k
        catch e
            @warn "Where Qdrant is could not be worked out" exception = e maxlog = 1
        end
        RESOLVED_AT[] = time()
    end
    return URL[]
end

_headers(extra::Pair...) = isempty(KEY[]) ? Pair{String,String}[extra...] : Pair{String,String}["api-key" => KEY[], extra...]
_json() = _headers("Content-Type" => "application/json")
_get(path; kw...) = HTTP.get(url() * path, _headers(); kw...)
_put(path, body) = HTTP.put(url() * path, _json(), JSON.json(body))
_delete(path) = HTTP.delete(url() * path, _headers())
# Every POST here (search, delete by id, fetch by id) is safe to repeat, so it is retried as a GET
# would be: a kept-alive connection Qdrant closed while idle then reconnects rather than failing.
_post(path, body) = HTTP.post(url() * path, _json(), JSON.json(body); retry_non_idempotent = true)

_ok(r) = get(JSON.parse(body_text(r.body)), "status", "") == "ok"

"Whether Qdrant answers, and takes the key it is sent (its health check needs none, so the collections are asked for)."
function ping()
    try
        _get("/collections"; connect_timeout = 2, read_idle_timeout = 3, retry = false).status == 200
    catch
        false
    end
end

"The collections there are."
function list_collections()
    try
        r = _get("/collections")
        return [String(c["name"]) for c in JSON.parse(body_text(r.body))["result"]["collections"]]
    catch e
        @error "Listing Qdrant's collections failed" exception = e
        return String[]
    end
end

collection_exists(collection::AbstractString) = collection in list_collections()

"Create a collection of `vector_size`-d vectors compared by `distance`; one already there will do."
function create_collection(collection::AbstractString; vector_size::Integer, distance::AbstractString = "Cosine")
    try
        r = _put("/collections/$collection", Dict("vectors" => Dict("size" => vector_size, "distance" => distance)))
        return get(JSON.parse(body_text(r.body)), "result", false) == true
    catch e
        e isa HTTP.StatusError && e.status == 409 && return true
        @error "Creating the Qdrant collection failed" collection exception = e
        return false
    end
end

function delete_collection(collection::AbstractString)
    try
        r = _delete("/collections/$collection")
        return get(JSON.parse(body_text(r.body)), "result", false) == true
    catch e
        @error "Deleting the Qdrant collection failed" collection exception = e
        return false
    end
end

"Add or replace points (`id`, `vector`, `payload`), retrying a connection that drops under load."
function upsert_points(collection::AbstractString, points::AbstractVector)
    try
        return with_retry(() -> _ok(_put("/collections/$collection/points", Dict("points" => points))), "Upserting into Qdrant"; tries = 4)
    catch e
        @error "Upserting into Qdrant failed" collection reason = sprint(showerror, e)
        return false
    end
end

# Qdrant tells 1 from "1": numbers, and strings of digits, are sent as integers.
_point_id(id::Integer) = id
_point_id(id::Real) = isinteger(id) ? Int(id) : id
_point_id(id::AbstractString) = something(tryparse(Int, id), String(id))
_point_id(id) = id

function delete_points(collection::AbstractString, ids::AbstractVector)
    isempty(ids) && return true
    try
        return _ok(_post("/collections/$collection/points/delete", Dict("points" => map(_point_id, ids))))
    catch e
        @error "Deleting points from Qdrant failed" collection exception = e
        return false
    end
end

"""
The `limit` points nearest `vector` (each a Dict with its `score` and `payload`), or one entry with an
`error`. A collection not made yet (nothing has been embedded in its layer) has none.
"""
function search(collection::AbstractString, vector::AbstractVector; limit::Integer = 5, filter = nothing,
                score_threshold::Real = 0.0)
    body = Dict{String,Any}("vector" => vector, "limit" => limit, "score_threshold" => score_threshold,
                            "with_payload" => true, "with_vector" => false)
    filter === nothing || (body["filter"] = filter)
    try
        return get(JSON.parse(body_text(_post("/collections/$collection/points/search", body).body)), "result", [])
    catch e
        e isa HTTP.StatusError && e.status == 404 && return Dict{String,Any}[]
        @error "Searching Qdrant failed" collection exception = e
        return [Dict("error" => sprint(showerror, e))]
    end
end

"Point `id` with its vector, or an empty Dict."
function get_point(collection::AbstractString, id)
    try
        r = _get("/collections/$collection/points/$(_point_id(id))")
        return get(JSON.parse(body_text(r.body)), "result", Dict())
    catch e
        @error "Reading a point from Qdrant failed" collection id exception = e
        return Dict()
    end
end

"""
    get_points(collection, ids) -> Vector{Dict}

Points by id, each with its vector and payload; ids Qdrant does not have are left out.
"""
get_points(collection::AbstractString, ids::AbstractVector) =
    JSON.parse(body_text(_post("/collections/$collection/points",
                            Dict("ids" => map(_point_id, ids), "with_payload" => true, "with_vector" => true)).body))["result"]

end
