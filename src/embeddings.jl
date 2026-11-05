"The most texts sent to Ollama at once, and how many the first batch of an embedding sends, before
its batches are fitted to `BATCH_SECONDS`."
const EMBED_BATCH = 32
const EMBED_BATCH_START = 4
const HOSTED_EMBED_BATCH = 256

# Searches embed ahead of everything else this process embeds (reading, the watch), since a reader
# is waiting on them. A bulk embedding waits to send its next batch while a query is waiting, and
# sizes its batches to about `BATCH_SECONDS` of Ollama's work, so a query waits behind at most that.

"How long, in seconds, a batch sent to Ollama for bulk embedding should take."
const BATCH_SECONDS = 3.0

"The searches waiting for Ollama to embed their query."
const QUERIES_WAITING = Threads.Atomic{Int}(0)
const QUERY_DONE = Threads.Condition()

"Embed a search's query: `f()`, with bulk embeddings holding back their next batch until it is done."
function as_query(f)
    Threads.atomic_add!(QUERIES_WAITING, 1)
    try
        return f()
    finally
        Threads.atomic_sub!(QUERIES_WAITING, 1)
        lock(() -> notify(QUERY_DONE), QUERY_DONE)
    end
end

"Wait, before sending a bulk batch, until no search is waiting to embed its query."
function yield_to_queries()
    QUERIES_WAITING[] == 0 && return
    lock(QUERY_DONE) do
        while QUERIES_WAITING[] > 0
            wait(QUERY_DONE)
        end
    end
end

"""
    embed(config, layer, texts; size = Ref(EMBED_BATCH_START), query = false) -> Vector{Vector{Float32}}

Embed texts with the layer's model: through the config's Ollama (which truncates inputs longer than
the model's context), or through the OpenAI-compatible API at the layer's `url`. Transient failures
are retried; persistent ones throw. `size` is how many texts Ollama is sent at once, made smaller
when a request outlasts its timeout and fitted to `BATCH_SECONDS` as it goes; pass the same one to
later calls to keep that size. A `query` (a search's) is sent ahead of bulk batches.
"""
function embed(c::Config, l::Layer, texts::AbstractVector{<:AbstractString}; size = Ref(EMBED_BATCH_START), query::Bool = false)
    isempty(l.url) && return query ? as_query(() -> ollama_embed_batch(c, l.model, collect(texts))) : ollama_embed(c, l.model, texts; size)
    key = resolve_key(l.key, "Layer $(l.name)")
    out = Vector{Vector{Float32}}()
    for batch in Iterators.partition(texts, HOSTED_EMBED_BATCH)
        data = openai_post(l.url, "/embeddings", key, Dict("model" => l.model, "input" => collect(batch));
                           what = "Embedding ($(l.name))")
        items = sort(data["data"]; by = d -> d["index"])
        length(items) == length(batch) || error("$(l.url) returned $(length(items)) embeddings for $(length(batch)) inputs")
        append!(out, [Float32.(d["embedding"]) for d in items])
    end
    return out
end

function ollama_embed(c::Config, model::AbstractString, texts::AbstractVector{<:AbstractString}; timeout = 600,
                      size = Ref(EMBED_BATCH_START))
    out = Vector{Vector{Float32}}()
    while length(out) < length(texts)
        yield_to_queries()
        i = length(out) + 1
        n = min(size[], length(texts) - i + 1)
        t = time()
        append!(out, ollama_embed_batch(c, model, collect(texts[i:i+n-1]); timeout, size))
        # The next batch as large as about BATCH_SECONDS of work, by how long this one took.
        n == size[] && (size[] = clamp(round(Int, n * BATCH_SECONDS / max(time() - t, 0.01)), 1, EMBED_BATCH))
    end
    return out
end

# A batch that outlasts the timeout (long texts on a machine without a GPU) is embedded in halves,
# down to one text at a time, which is retried like any other failure.
function ollama_embed_batch(c::Config, model::AbstractString, batch::Vector; timeout = 600, size = Ref(length(batch)))
    body = JSON.json(Dict("model" => model, "input" => batch, "truncate" => true))
    request() = JSON.parse(String(HTTP.post("$(c.ollama_url)/api/embed", ["Content-Type" => "application/json"], body;
                                            read_idle_timeout = timeout).body))
    data = try
        request()
    catch e
        e isa InterruptException && rethrow()
        if length(batch) > 1 && timed_out(e)
            h = cld(length(batch), 2)
            size[] = min(size[], h)
            return [ollama_embed_batch(c, model, batch[1:h]; timeout, size); ollama_embed_batch(c, model, batch[h+1:end]; timeout, size)]
        end
        with_retry(request, "Ollama embedding ($model)")
    end
    vecs = data["embeddings"]
    length(vecs) == length(batch) || error("Ollama returned $(length(vecs)) embeddings for $(length(batch)) inputs")
    return [Float32.(v) for v in vecs]
end

# ── Units: what each layer embeds ───────────────────────────────────────────

"""
    Unit

One thing a layer embeds: a paper, a section or a chunk. `key` names it stably across re-parses
(`p:<id>`, `s:<id>:<ord>`, `c:<id>:<ord>`), so re-embedding overwrites its vector in place;
`payload` is stored alongside the vector in Qdrant.
"""
struct Unit
    key::String
    text::String
    payload::Dict{String,Any}
end

function paper_payload(p)
    Dict{String,Any}("paper" => p.doc_id, "category" => coalesce(p.primary_category, ""),
        "year" => something(tryparse(Int, first(coalesce(p.published, ""), 4)), 0))
end

"""
    units(kb, layer, doc_id) -> Vector{Unit}

The texts `layer` embeds for one paper, with the layer's document prefix applied and cut to its
`max_chars`. Chunks and sections are prefixed with the paper title and section path, so a
passage carries the context it came from.
"""
function units(kb::KB, l::Layer, doc_id::AbstractString)
    p = paper_row(kb, doc_id)
    title = coalesce(p.title, doc_id)
    prep(text) = first(l.doc_prefix * text, l.max_chars)
    base = paper_payload(p)
    isempty(l.source) || return summary_units(kb, l, p, prep, base)
    if l.unit == :paper
        text = "$title\n\n$(coalesce(p.abstract, ""))"
        return [Unit("p:$doc_id", prep(text), merge(base, Dict("kind" => "paper")))]
    end
    sections = Dict(r.ord => r.path for r in query(kb,
        "SELECT ord, path FROM sections WHERE paper_id = ?", (p.id,)))
    section_path(ord) = ord == 0 ? "Abstract" : get(sections, ord, "")
    chunks = query(kb, "SELECT ord, section, page_start, page_end, text FROM chunks WHERE paper_id = ? ORDER BY ord", (p.id,))
    if l.unit == :chunk
        return [Unit("c:$doc_id:$(c.ord)", prep("$title — $(section_path(c.section))\n\n$(c.text)"),
                    merge(base, Dict("kind" => "chunk", "ord" => c.ord, "section" => c.section)))
                for c in chunks]
    end
    out = Unit[]
    for sec in unique(c.section for c in chunks)
        body = join((c.text for c in chunks if c.section == sec), "\n\n")
        push!(out, Unit("s:$doc_id:$sec", prep("$title — $(section_path(sec))\n\n$body"),
            merge(base, Dict("kind" => "section", "section" => sec))))
    end
    return out
end

"Units for a layer over summaries: the paper summary, or each section's."
function summary_units(kb::KB, l::Layer, p, prep, base)
    rows = query(kb, "SELECT unit_key, text FROM summaries WHERE summarizer = ? AND paper_id = ?",
                 (summarizer_for(kb.config, l, p.doc_id).name, p.id))
    title = coalesce(p.title, p.doc_id)
    if l.unit == :paper
        return [Unit(r.unit_key, prep("$title\n\n$(r.text)"), merge(base, Dict("kind" => "paper")))
                for r in rows if startswith(r.unit_key, "p:")]
    end
    paths = Dict(r.ord => r.path for r in query(kb, "SELECT ord, path FROM sections WHERE paper_id = ?", (p.id,)))
    out = Unit[]
    for r in rows
        startswith(r.unit_key, "s:") || continue
        ord = parse(Int, split(r.unit_key, ':')[3])
        push!(out, Unit(r.unit_key, prep("$title — $(get(paths, ord, ""))\n\n$(r.text)"),
            merge(base, Dict("kind" => "section", "section" => ord))))
    end
    return out
end

text_sha(s) = bytes2hex(sha256(s))

"Deterministic Qdrant point id for a unit in a layer."
function point_id(layer_name::AbstractString, key::AbstractString)
    h = sha1("$layer_name|$key")[1:16]
    h[7] = (h[7] & 0x0f) | 0x50  # UUID version 5 layout
    h[9] = (h[9] & 0x3f) | 0x80
    return string(UUID(reinterpret(UInt128, reverse(h))[1]))
end
