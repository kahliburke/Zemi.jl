# Searching the tasks and findings by meaning: each task's title and plan, and each comment,
# progress note and question on it, and each finding's claim and write-up, embedded with the papers'
# passage layer into Qdrant collections of their own. Kept current in the background as they change
# (see `follow_task_vectors`); `search_tasks` and `search_findings` fuse what they find with their
# keyword rankings.

"The layer tasks are embedded with: the config's first passage layer (not a trial's, nor one over summaries), or `nothing`."
function task_layer(c::Config)
    i = findfirst(l -> l.unit == :chunk && !l.trial && isempty(l.source), c.layers)
    return i === nothing ? nothing : c.layers[i]
end

task_collection(c::Config, l::Layer) = "$(c.collection_prefix)_tasks_$(replace(l.name, r"[^A-Za-z0-9_-]" => "_"))"
finding_collection(c::Config, l::Layer) = "$(c.collection_prefix)_findings_$(replace(l.name, r"[^A-Za-z0-9_-]" => "_"))"

# Point ids of tasks' own text, kept apart from notes' (which are their event ids).
const TASK_POINT = 1_000_000_000_000
point_id(key::AbstractString) = startswith(key, "t:") ? TASK_POINT + parse(Int, key[3:end]) : parse(Int, key[3:end])

"""
    task_documents(kb) -> Dict{String,Tuple{Int,String}}

What there is to embed, `key => (task id, text)`: `t:<task>` a task's title and plan, `e:<event>` a
note on it.
"""
function task_documents(kb::KB)
    out = Dict{String,Tuple{Int,String}}()
    for r in query(kb, "SELECT id, title, body FROM tasks")
        out["t:$(r.id)"] = (Int(r.id), String(strip(r.title * "\n\n" * r.body)))
    end
    for r in query(kb, """SELECT id, task_id, text FROM task_events
                          WHERE kind IN ('comment', 'progress', 'question') AND coalesce(text, '') != ''""")
        out["e:$(r.id)"] = (Int(r.task_id), String(r.text))
    end
    return out
end

"What there is to embed of the findings, `f:<finding> => (finding id, claim and write-up)`."
finding_documents(kb::KB) =
    Dict("f:$(r.id)" => (Int(r.id), String(strip(r.claim * "\n\n" * r.body))) for r in query(kb, "SELECT id, claim, body FROM findings"))

"""
    embed_tasks!(kb) -> Int

Embed the tasks' documents (see [`task_documents`](@ref)) that are new or changed since they were
last embedded, and drop those that are gone. Returns how many were embedded; nothing without a
passage layer (see [`task_layer`](@ref)).
"""
function embed_tasks!(kb::KB)
    l = task_layer(kb.config)
    l === nothing && return 0
    return embed_documents!(kb, l, task_collection(kb.config, l), task_documents(kb), k -> !startswith(k, "f:"), "task")
end

"Embed the findings' documents (see [`finding_documents`](@ref)) as [`embed_tasks!`](@ref) does the tasks'."
function embed_findings!(kb::KB)
    l = task_layer(kb.config)
    l === nothing && return 0
    return embed_documents!(kb, l, finding_collection(kb.config, l), finding_documents(kb), k -> startswith(k, "f:"), "finding")
end

# Embed `docs` (key => (owner id, text)) into `coll`, those changed since they were last embedded,
# and drop from it the documents gone; `ours` says which keys of `task_vectors` are this
# collection's, and `owner` names the owner's id in each point's payload.
function embed_documents!(kb::KB, l::Layer, coll::AbstractString, docs::Dict{String,Tuple{Int,String}}, ours::Function, owner::String)
    hash(text) = bytes2hex(sha1(text))
    have = Dict(String(r.key) => String(r.hash) for r in query(kb, "SELECT key, hash FROM task_vectors") if ours(String(r.key)))
    todo = [k for (k, (_, text)) in docs if get(have, k, "") != hash(text)]
    gone = [k for k in keys(have) if !haskey(docs, k)]
    for batch in Iterators.partition(todo, 128)
        vecs = embed(kb.config, l, [first(l.doc_prefix * docs[k][2], l.max_chars) for k in batch])
        Qdrant.collection_exists(coll) ||
            qdrant_check(Qdrant.create_collection(coll; vector_size = length(first(vecs)), distance = "Cosine"), "creating $coll")
        upsert_vectors!(coll, point_id.(batch), vecs, [Dict("unit" => k, owner => docs[k][1]) for k in batch])
        transaction(kb) do
            foreach(k -> execute!(kb, "INSERT OR REPLACE INTO task_vectors VALUES (?, ?)", (k, hash(docs[k][2]))), batch)
        end
    end
    if !isempty(gone)
        Qdrant.collection_exists(coll) && delete_vectors!(coll, point_id.(gone))
        transaction(kb) do
            foreach(k -> execute!(kb, "DELETE FROM task_vectors WHERE key = ?", (k,)), gone)
        end
    end
    return length(todo)
end

"""
    task_meaning_ranking(kb, text; limit = 40) -> Vector{Tuple{Int,String}}

Tasks whose documents are nearest `text` in meaning, best first, as `(task id, document key)`, a
task once; empty when tasks have not been embedded, or the embedding service or Qdrant cannot be
reached (a keyword search then stands alone).
"""
task_meaning_ranking(kb::KB, text::AbstractString; limit::Integer = 40) =
    meaning_ranking(kb, text, task_collection, "task", "SELECT 1 FROM task_vectors WHERE key NOT LIKE 'f:%' LIMIT 1"; limit)

"""
    finding_meaning_ranking(kb, text; limit = 40) -> Vector{Tuple{Int,String}}

Findings nearest `text` in meaning, best first, as `(finding id, document key)`, as
[`task_meaning_ranking`](@ref) finds tasks.
"""
finding_meaning_ranking(kb::KB, text::AbstractString; limit::Integer = 40) =
    meaning_ranking(kb, text, finding_collection, "finding", "SELECT 1 FROM task_vectors WHERE key LIKE 'f:%' LIMIT 1"; limit)

"""
    task_meaning_rankings(kb, texts; limit = 40) -> Vector{Vector{Tuple{Int,String}}}

[`task_meaning_ranking`](@ref) for many texts, all embedded in one request: one ranking per text,
each empty where search by meaning is unavailable.
"""
function task_meaning_rankings(kb::KB, texts::AbstractVector{<:AbstractString}; limit::Integer = 40)
    none = [Tuple{Int,String}[] for _ in texts]
    l = task_layer(kb.config)
    (l === nothing || isempty(texts) || ismissing(scalar(kb, "SELECT 1 FROM task_vectors WHERE key NOT LIKE 'f:%' LIMIT 1"))) && return none
    try
        vectors = embed(kb.config, l, [l.query_prefix * t for t in texts])
        coll = task_collection(kb.config, l)
        return map(vectors) do v
            out, seen = Tuple{Int,String}[], Set{Int}()
            for h in vector_search(coll, v; limit = 3limit)
                id = Int(h.payload["task"])
                id in seen && continue
                push!(seen, id); push!(out, (id, h.key))
                length(out) >= limit && break
            end
            out
        end
    catch e
        @debug "Search by meaning is unavailable" exception = e
        return none
    end
end

function meaning_ranking(kb::KB, text::AbstractString, collection::Function, owner::String, embedded::String; limit::Integer = 40)
    l = task_layer(kb.config)
    (l === nothing || isempty(strip(text)) || ismissing(scalar(kb, embedded))) && return Tuple{Int,String}[]
    hits = try
        vector_search(collection(kb.config, l), query_vector(kb.config, l, text); limit = 3limit)
    catch e
        @debug "Search by meaning is unavailable" exception = e
        return Tuple{Int,String}[]
    end
    out, seen = Tuple{Int,String}[], Set{Int}()
    for h in hits
        id = Int(h.payload[owner])
        id in seen && continue
        push!(seen, id); push!(out, (id, h.key))
        length(out) >= limit && break
    end
    return out
end

"""
    follow_task_vectors(kb)

For a running service: embed the tasks and findings now, and again a few seconds after they change,
for as long as the process runs. A failure (the embedding service or Qdrant away) is logged once and retried
with the next change.
"""
function follow_task_vectors(kb::KB)
    task_layer(kb.config) === nothing && return nothing
    Threads.@spawn begin
        warned = false
        while !STOPPING[]
            try
                Base.invokelatest(embed_tasks!, kb)           # the code as it is now, revised or not
                Base.invokelatest(embed_findings!, kb)
                warned = false
            catch e
                STOPPING[] && break
                warned || @warn "Tasks and findings could not be embedded for search by meaning; trying again when they change" exception = e
                warned = true
            end
            wait_tasks_changed(TASKS_VERSION[]; timeout = 3600)
            pause(3)                                   # changes come in bursts
        end
    end
    return nothing
end
