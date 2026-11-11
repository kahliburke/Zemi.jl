# Sharing what machines have read and computed. A publisher reads papers and codebases with the
# dataset's models and publishes what it read: every document's record, parsed text, summaries,
# classification and vectors. Consumers import the dataset into their own database and Qdrant instead
# of doing that work, and keep adding documents of their own. Any number of members can publish to one
# dataset, each to a stream of their own, and each imports the others' streams.
#
# A dataset holds:
#
#     profile.json              the layers and summarizers every stream's documents are made with
#     streams/<name>.json       a stream's manifest: its documents, with the content hash of each
#                               document's data, the content files it changed (see content_sync.jl),
#                               and its landscape, papers of the day and site parts
#     history/<name>/<time>.json  the stream's earlier manifests
#     docs/<hash>.json.gz       a document's data, and its vectors in docs/<hash>.vec.gz (half precision)
#     figures/<sha>.webp        a figure or table cut from a document's PDF, which its data names
#                               (`.png` in what was published before figures were WebP)
#     content/<hash>            a content file's data
#     landscape/<hash>.json.gz  a landscape; daily/<hash>.json.gz the papers of the day, their figures
#                               in daily/figures/<sha>.webp (or .png)
#     site/, notebooks/         the site's parts (see site_publish.jl)
#
# Objects are named by their content and shared by the streams, so the same data published twice is
# stored once, publishing uploads only documents that changed, importing downloads only those, and a
# manifest, written last, never names an object that is not there yet. Only the site's parts are
# pruned: the earlier copies of documents, content, landscapes and papers of the day stay, as the
# history's manifests name them, so the store grows with each change published. A member publishes the documents
# it read itself (see [`own_documents`](@ref)), not those it imported unchanged; where streams carry the
# same document, the most complete copy is imported, then the newest (see [`stream_winners`](@ref)).

const DATASET_FORMAT = 3

"""
    valid_stream(name) -> Bool

Whether `name` can name a stream: lowercase letters, digits, `.`, `_` and `-`, starting with a
letter or digit.
"""
valid_stream(name::AbstractString) = occursin(r"^[a-z0-9][a-z0-9._-]{0,63}$", name)

"""
    stream_name(config) -> String

The stream this knowledge base publishes to: `[dataset] stream`, or the user's login name.
"""
function stream_name(c::Config)
    s = c.dataset.stream
    isempty(s) && (s = replace(lowercase(get(ENV, "USER", get(ENV, "USERNAME", "member"))), r"[^a-z0-9._-]" => "-"))
    valid_stream(s) || error("[dataset] stream \"$s\" must be lowercase letters, digits, '.', '_' or '-'")
    return s
end

# ── Where a dataset lives ─────────────────────────────────────────────────────────────────────────

"""
    dataset_store(config) -> DatasetStore

The store the config's `[dataset]` table names.
"""
function dataset_store(c::Config)
    d = c.dataset
    return open_store(StoreConfig(; d.store, d.endpoint, d.bucket, d.prefix, d.region, d.credentials); table = "[dataset]")
end

# ── What a document holds ─────────────────────────────────────────────────────────────────────────

"""
    set_shared!(kb, ids, shared) -> String

Mark documents added here (uploads and codebases, of a kind published when shared, see
[`DocumentKind`](@ref)) as shared (published with the dataset) or not. arXiv papers are always
published, so marking them changes nothing.
"""
function set_shared!(kb::KB, ids::AbstractVector{<:AbstractString}, shared::Bool)
    own = filter(id -> (k = local_kind(id); k !== nothing && k.published), ids)
    for id in own
        execute!(kb, "UPDATE papers SET shared = ? WHERE doc_id = ?", (Int(shared), id))
    end
    what = shared ? "shared" : "no longer shared"
    return isempty(own) ? "arXiv papers are always published." : "$(join(own, ", ")) $(length(own) == 1 ? "is" : "are") $what."
end

"""
Whether a document is published: none that is not open to every reader (see document_access.jl);
every arXiv paper, and documents of one's own of a kind published
when shared (see [`DocumentKind`](@ref)) marked shared, but not one open only to its projects'
members, which another member's service would show to all its readers. A document of no kind is not.
"""
function publishable(kb::KB, doc_id::AbstractString)
    coalesce(scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (doc_id,)), "open") == "open" || return false
    is_arxiv_id(doc_id) && return true
    kind = local_kind(doc_id)
    (kind === nothing || !kind.published) && return false
    r = query(kb, "SELECT shared, access FROM papers WHERE doc_id = ?", (doc_id,))
    return !isempty(r) && first(r).shared == 1 && (!kind.access || first(r).access == "open")
end

rows_as_dicts(rows) = [Dict{String,Any}(String(k) => v for (k, v) in pairs(r)) for r in rows]

"""
    export_document(kb, doc_id) -> (doc, vectors, lost)

A document's data for publishing: its record, mentions, parse, summaries by the configured
summarizer and by those its summary layers embed, classification, and its vectors in the layers ingesting keeps, as a Dict and the
vectors' bytes (half precision, in the order `doc["embeddings"]` lists them). `lost` counts the
vectors recorded that Qdrant no longer has, which are left out (and forgotten, see
[`forget_lost_vectors!`](@ref)).
"""
function export_document(kb::KB, doc_id::AbstractString)
    p = paper_row(kb, doc_id)
    pid = p.id
    paper = Dict{String,Any}(k => getproperty(p, Symbol(k)) for k in
        ("doc_id", "version", "title", "abstract", "authors", "published", "updated", "primary_category", "categories",
         "doi", "journal_ref", "metadata_at", "added_at", "kind"))
    parse = query(kb, "SELECT file_sha, parser_version, pages FROM parses WHERE paper_id = ?", (pid,))
    layers = ingest_layers(kb.config)
    # The summaries its pages show, and those its summary layers embed.
    shown = kind_summarizer(kb.config, doc_id)
    sources = unique([shown; [summarizer_for(kb.config, l, doc_id).name for l in layers if !isempty(l.source)]])
    classification = query(kb, "SELECT classifier, model, data, created_at FROM classifications WHERE paper_id = ?", (pid,))
    embeddings = Dict{String,Any}[]
    io = IOBuffer()
    lost = 0
    for l in layers
        rows = query(kb, "SELECT unit_key, text_sha, point_id FROM embeddings WHERE layer = ? AND paper_id = ? ORDER BY unit_key", (l.name, pid))
        isempty(rows) && continue
        got = fetch_vectors(collection_name(kb.config, l), [r.point_id for r in rows])
        missing_points = [r.point_id for r in rows if !haskey(got, r.point_id)]
        lost += length(missing_points)
        forget_lost_vectors!(kb, l.name, missing_points)
        for r in rows
            haskey(got, r.point_id) || continue
            vector, payload = got[r.point_id]
            push!(embeddings, Dict{String,Any}("layer" => l.name, "unit_key" => r.unit_key, "text_sha" => r.text_sha,
                                               "payload" => payload))
            write(io, Float16.(vector))
        end
    end
    vectors = take!(io)
    doc = Dict{String,Any}(
        "doc_id" => String(doc_id), "paper" => paper,
        "mentions" => rows_as_dicts(query(kb, "SELECT source, channel, posted_at, author, url, message FROM mentions WHERE paper_id = ? ORDER BY posted_at", (pid,))),
        "parse" => isempty(parse) ? nothing : only(rows_as_dicts(parse)),
        "sections" => rows_as_dicts(query(kb, "SELECT ord, level, number, title, path, page_start, page_end FROM sections WHERE paper_id = ? ORDER BY ord", (pid,))),
        "blocks" => rows_as_dicts(query(kb, "SELECT ord, section, kind, page, x0, y0, x1, y1, text FROM blocks WHERE paper_id = ? ORDER BY ord", (pid,))),
        "chunks" => rows_as_dicts(query(kb, "SELECT ord, section, page_start, page_end, text FROM chunks WHERE paper_id = ? ORDER BY ord", (pid,))),
        "summaries" => rows_as_dicts(query(kb, """SELECT unit_key, summarizer, model, prompt_version, input_sha, text, created_at
            FROM summaries WHERE paper_id = ? AND summarizer IN ($(in_marks(max(length(sources), 1)))) ORDER BY summarizer, unit_key""",
            (pid, (isempty(sources) ? [""] : sources)...))),
        "classification" => isempty(classification) ? nothing : only(rows_as_dicts(classification)),
        "figures" => export_figures(kb, doc_id),
        "embeddings" => embeddings, "vectors_sha" => bytes2hex(sha256(vectors)))
    return doc, vectors, lost
end

"""
    export_figures(kb, doc_id) -> Vector{Dict}

The figures and tables cut from a document's PDF as its data carries them: each one's record, with
the hash of its image (published as `figures/<sha>.webp`, see [`figure_key`](@ref)), so members who import the document, and have
no PDF to cut them from, show them too.
"""
function export_figures(kb::KB, doc_id::AbstractString)
    dir = figures_dir(kb.config, doc_id)
    return [Dict{String,Any}("kind" => f.kind, "number" => f.number, "label" => f.label, "caption" => f.caption,
                             "file" => f.file, "sha" => bytes2hex(open(sha256, joinpath(dir, f.file))))
            for f in paper_figures(kb, doc_id) if isfile(joinpath(dir, f.file))]
end

"""
A figure's name in a dataset: a plain name in its paper's folder, a WebP image, or a PNG one as
published before figures were WebP.
"""
const FIGURE_NAME = r"^[A-Za-z0-9][A-Za-z0-9._-]*\.(webp|png)$"

"Whether a figure a document's data names is a plain image name in its paper's folder (see `FIGURE_NAME`), with a hash for its image."
figure_ok(f) = occursin(FIGURE_NAME, string(get(f, "file", ""))) && occursin(r"^[0-9a-f]{64}$", string(get(f, "sha", "")))

"""
    figure_key(prefix, sha, file) -> String

The object a figure's image is stored as, under `prefix` (`figures` or `daily/figures`): named by its
hash, with the extension of its file, `.webp` or `.png`.
"""
figure_key(prefix::AbstractString, sha::AbstractString, file::AbstractString) = "$prefix/$sha$(lowercase(splitext(file)[2]))"

layer_json(l::Layer) = Dict("name" => l.name, "model" => l.model, "unit" => string(l.unit), "source" => l.source,
                            "query_prefix" => l.query_prefix, "doc_prefix" => l.doc_prefix, "max_chars" => l.max_chars)
summarizer_json(s::Summarizer) = Dict("name" => s.name, "kind" => string(s.kind), "model" => s.model, "url" => s.url,
                                      "reads" => string(s.reads))

# ── The profile ───────────────────────────────────────────────────────────────────────────────────

"""
    dataset_profile(config) -> Dict

The profile of a dataset made with `config`'s models: the layers ingesting keeps, the summarizers
the pages show, and those summarizers' models.
"""
function dataset_profile(c::Config)
    names = unique([c.summarizer; c.code_summarizer])
    return Dict{String,Any}("format" => DATASET_FORMAT, "summarizer" => c.summarizer, "code_summarizer" => c.code_summarizer,
        "summarizers" => [summarizer_json(summarizer(c, n)) for n in names],
        "layers" => [layer_json(l) for l in ingest_layers(c)])
end

"""
    profile_differences(profile, config) -> Vector{String}

How `config` makes documents differently from the dataset's `profile`, for people; empty when it
makes them the same way.
"""
function profile_differences(p::AbstractDict, c::Config)
    mine = dataset_profile(c)
    out = String[]
    for k in ("summarizer", "code_summarizer")
        p[k] == mine[k] || push!(out, "the $(replace(k, '_' => ' ')) is $(mine[k]) here and $(p[k]) in the dataset")
    end
    models = Dict(s["name"] => s["model"] for s in p["summarizers"])
    for s in mine["summarizers"]
        get(models, s["name"], s["model"]) == s["model"] ||
            push!(out, "$(s["name"]) runs $(s["model"]) here and $(models[s["name"]]) in the dataset")
    end
    theirs = Dict(l["name"] => l for l in p["layers"])
    ours = Dict(l["name"] => l for l in mine["layers"])
    for n in sort!(collect(keys(theirs)))
        haskey(ours, n) || push!(out, "the layer $n is not kept here")
    end
    for n in sort!(collect(keys(ours)))
        !haskey(theirs, n) ? push!(out, "the layer $n is not the dataset's") :
        ours[n] == theirs[n] || push!(out, "the layer $n is made differently here")
    end
    return out
end

"The dataset's profile, or `nothing` before anything is published to it."
function read_profile(store::DatasetStore)
    raw = read_object(store, "profile.json")
    raw === nothing && return nothing
    p = JSON.parse(String(raw))
    get(p, "format", 0) == DATASET_FORMAT ||
        error("The dataset is format $(get(p, "format", "?")); this code reads format $DATASET_FORMAT")
    return p
end

"""
    check_profile!(kb, store) -> Dict

The dataset's profile, written from this knowledge base's config when the dataset has none yet, and
kept as the config follows it (see [`follow_profile`](@ref)). An error when this knowledge base makes
documents another way: their summaries and vectors could not be mixed with the dataset's.
"""
function check_profile!(kb::KB, store::DatasetStore)
    p = read_profile(store)
    if p === nothing
        p = merge(dataset_profile(kb.config), Dict("created_at" => now_iso(), "stream" => stream_name(kb.config)))
        write_object!(store, "profile.json", Vector{UInt8}(JSON.json(p)); content_type = "application/json")
    else
        diffs = profile_differences(p, kb.config)
        isempty(diffs) || error("This knowledge base does not make documents the way the dataset does: $(join(diffs, "; ")). " *
                                "Import the dataset, and the config follows the dataset's models")
    end
    mkpath(kb.config.data_dir)
    write(profile_cache(kb.config), JSON.json(p))
    kb.config = follow_profile(kb.config)
    return p
end

# ── Streams ───────────────────────────────────────────────────────────────────────────────────────

"Every stream's manifest, by the stream's name."
function read_streams(store::DatasetStore)
    names = [k[9:end-5] for k in list_objects(store, "streams/") if endswith(k, ".json") && !occursin('/', k[9:end])]
    found = asyncmap(names; ntasks = 8) do n
        raw = read_object(store, "streams/$n.json")
        raw === nothing ? nothing : n => JSON.parse(String(raw))
    end
    return Dict{String,Dict{String,Any}}(something.(filter(!isnothing, found)))
end

"""
    stream_winners(streams) -> Dict{String,Tuple{String,Dict}}

For each document a stream carries, the stream whose copy is imported, with its entry: the copy of
the latest version of the paper, then the most complete (parsed, then embedded in more layers, then
summarized at all: a version's sections vary in number, so not by how many summaries), then the
newest, then that of the stream whose name sorts last, so every member picks the same.
"""
function stream_winners(streams::AbstractDict)
    best = Dict{String,Tuple{String,Dict{String,Any}}}()
    version(d) = something(tryparse(Int, replace(string(get(d, "version", "")), r"^v" => "")), 0)
    rank(name, d) = (version(d), Int(d["complete"][1]), Int(d["complete"][2]), Int(d["complete"][3] > 0), d["at"], name)
    for name in sort!(collect(keys(streams))), (id, d) in streams[name]["documents"]
        was = get(best, id, nothing)
        (was === nothing || isless(rank(was...), rank(name, d))) && (best[id] = (name, d))
    end
    return best
end

"How complete a document's data is, as [`stream_winners`](@ref) compares copies: parsed, layers, summaries."
completeness(doc::AbstractDict) =
    [Int(doc["parse"] !== nothing), length(unique(e["layer"] for e in doc["embeddings"])), length(doc["summaries"])]

"The stream of these manifests published last, of those for which `has` is true, other than `skip`; or `nothing`."
function latest_stream(has, streams::AbstractDict; skip = "")
    names = [n for (n, m) in streams if n != skip && has(m)]
    isempty(names) && return nothing
    return last(sort!(names; by = n -> (streams[n]["published_at"], n)))
end

"What this knowledge base last imported of each stream, as `name => published_at`."
streams_imported(kb::KB) = JSON.parse(coalesce(scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_streams'"), "{}"))

# ── Publishing ────────────────────────────────────────────────────────────────────────────────────

"""
    fingerprints(kb, ids; record = true) -> Dict{String,String}

A fingerprint of what each document would publish: its record, and the count and latest time of its
mentions, parse, summaries, classification and embeddings in the published layers, with the
published summarizers and layers. When a document's fingerprint has not moved since it was
published, neither has its data, so it need not be exported again. Without `record`, the fingerprint
of its reading alone, leaving out the arXiv record any member refreshes (see [`own_documents`](@ref)).
"""
function fingerprints(kb::KB, ids; record::Bool = true)
    layers = [l.name for l in ingest_layers(kb.config)]
    sources = unique([[kind_summarizer(kb.config, k) for k in DOCUMENT_KINDS]; [l.source for l in ingest_layers(kb.config) if !isempty(l.source)]])
    marks(xs) = in_marks(max(length(xs), 1))
    wanted = Set(ids)
    # (Named in the query when they are few; most of the knowledge base is read at once.)
    few = length(wanted) <= 200
    rows = query(kb, """
        SELECT p.doc_id AS id, p.version,
               $(record ? "p.title, p.abstract, p.authors, p.published, p.updated, p.primary_category, p.categories, p.doi, p.journal_ref, p.metadata_at, p.kind," : "")
               (SELECT parser_version || ' ' || parsed_at FROM parses x WHERE x.paper_id = p.id) AS parse,
               (SELECT count(*) || ' ' || coalesce(max(posted_at), '') FROM mentions m WHERE m.paper_id = p.id) AS mentions,
               (SELECT count(*) || ' ' || coalesce(max(created_at), '') FROM summaries s
                WHERE s.paper_id = p.id AND s.summarizer IN ($(marks(sources)))) AS summaries,
               (SELECT classifier || ' ' || created_at FROM classifications c WHERE c.paper_id = p.id) AS classification,
               (SELECT count(*) || ' ' || coalesce(max(embedded_at), '') FROM embeddings e
                WHERE e.paper_id = p.id AND e.layer IN ($(marks(layers)))) AS embeddings,
               (SELECT c.file_sha || ' ' || c.at || ' ' ||
                       coalesce((SELECT group_concat(file, ',') FROM (SELECT file FROM figures f WHERE f.paper_id = p.id ORDER BY file)), '')
                FROM figure_cuts c WHERE c.paper_id = p.id) AS figures
        FROM papers p $(few ? "WHERE p.doc_id IN ($(marks(wanted)))" : "")""",
        (sources..., (isempty(layers) ? [""] : layers)..., (few ? (isempty(wanted) ? [""] : collect(wanted)) : [])...))
    context = "$DATASET_FORMAT|$(join(sources, ","))|$(join(layers, ","))"
    # Figures count only where they were cut here, by their cut and their files' names (so converting
    # them counts): an imported document's come with it, and leave its fingerprint as it was imported
    # (see `own_documents`).
    print(r) = context * "|" * join((string(coalesce(getproperty(r, k), "")) for k in propertynames(r) if k != :figures), "|") *
               (ismissing(r.figures) ? "" : "|figures " * r.figures)
    return Dict(String(r.id) => bytes2hex(sha256(print(r))) for r in rows if r.id in wanted)
end

"""
    own_documents(kb, ids) -> Vector{String}

Of `ids`, those this knowledge base publishes to its stream: those it did not import from another
stream, and those it read again since it imported them (their reading's fingerprint moved, see
[`fingerprints`](@ref)). A document imported and left as it came stays its stream's.
"""
function own_documents(kb::KB, ids)
    me = stream_name(kb.config)
    imported = Dict(r.doc_id => r.fingerprint for r in query(kb, "SELECT doc_id, fingerprint FROM dataset_docs WHERE stream != ?", (me,)))
    prints = fingerprints(kb, [id for id in ids if haskey(imported, id)]; record = false)
    return [id for id in ids if !haskey(imported, id) || get(prints, id, "") != imported[id]]
end

"""
    publish!(kb; store = dataset_store(kb.config), ntasks = 8, progress, cancelled, site_parts) -> NamedTuple

Publish this knowledge base's stream (see [`stream_name`](@ref)): the publishable documents (see
[`publishable`](@ref)) that are its own (see [`own_documents`](@ref)), the landscape as last built (see
[`landscape!`](@ref)), the papers of the day (see [`export_daily`](@ref)), with `site_parts` the site's
(see site_publish.jl), then the stream's manifest. The dataset's profile is checked first, and written
by the first publish (see [`check_profile!`](@ref)). Only documents whose data changed since they were
published are exported (see [`fingerprints`](@ref)), and only those no stream has are uploaded,
`ntasks` at a time. Returns `(; stream, documents, changed, uploaded, bytes)`.
"""
publish!(kb::KB; kw...) = lock(() -> publish_dataset!(kb; kw...), DATASET_LOCK)

function publish_dataset!(kb::KB; store::DatasetStore = dataset_store(kb.config), ntasks::Integer = 8,
                          progress = msg -> nothing, cancelled = () -> false, site_parts::Bool = SITE_PARTS[])
    stop() = error("Publishing was cancelled; the stream's manifest is unchanged")
    stream = stream_name(kb.config)
    check_profile!(kb, store)
    at = now_iso()
    ids = own_documents(kb, [r.id for r in query(kb, "SELECT doc_id AS id FROM papers ORDER BY id") if publishable(kb, r.id)])
    progress("Checking $(length(ids)) documents against the stream $stream")
    streams = read_streams(store)
    published = get(streams, stream, Dict{String,Any}())
    # Published since this machine last took it (from another machine, or before this one imported
    # it): this publish would carry only what is here, and drop the rest of the stream.
    isempty(published) || isequal(get(published, "id", nothing), scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_stream_id'")) ||
        error("The stream $stream was published at $(published["published_at"]), not from here as it now is: " *
              "import the dataset first (zemi pull), then publish")
    remote = get(published, "documents", Dict{String,Any}())
    in_store = Set(d["hash"] for m in values(streams) for d in values(m["documents"]))
    stored = Dict(r.doc_id => (r.fingerprint, r.hash) for r in query(kb, "SELECT doc_id, fingerprint, hash FROM published_docs"))
    prints = fingerprints(kb, ids)
    documents = Dict{String,Any}()
    hashes = Dict{String,String}()
    changed = String[]
    for id in ids
        was = get(stored, id, nothing)
        if was !== nothing && was[1] == prints[id] && haskey(remote, id) && remote[id]["hash"] == was[2]
            documents[id] = remote[id]
            hashes[id] = was[2]
        else
            push!(changed, id)
        end
    end
    progress("Checked $(length(ids)) documents: $(length(changed)) changed since they were published")
    exports = []
    incomplete = String[]
    for (i, id) in enumerate(changed)
        cancelled() && stop()
        doc, vectors, lost = export_document(kb, id)
        # Without vectors Qdrant lost, members would drop theirs: the copy published before stays
        # until a sync has embedded them again.
        if lost > 0
            push!(incomplete, id)
            haskey(remote, id) && (documents[id] = remote[id]; hashes[id] = remote[id]["hash"])
            continue
        end
        json = Vector{UInt8}(JSON.json(doc))
        hash = bytes2hex(sha256(json))
        # A copy published before keeps its time, so republishing it does not make it the newest.
        when = haskey(remote, id) && remote[id]["hash"] == hash ? remote[id]["at"] : at
        documents[id] = Dict("hash" => hash, "kind" => doc["paper"]["kind"], "title" => doc["paper"]["title"],
                             "version" => something(doc["paper"]["version"], ""),
                             "vectors" => !isempty(vectors), "complete" => completeness(doc), "at" => when)
        hashes[id] = hash
        figures = [(f["sha"], joinpath(figures_dir(kb.config, id), f["file"])) for f in doc["figures"]]
        hash in in_store || push!(exports, (; id, hash, json, vectors, figures))
        progress("Exporting [$i/$(length(changed))] $id")
    end
    uploaded = Threads.Atomic{Int}(0)
    bytes = Threads.Atomic{Int}(0)
    asyncmap(exports; ntasks) do e
        cancelled() && return
        if !isempty(e.vectors)
            v = gzip(e.vectors)
            write_object!(store, "docs/$(e.hash).vec.gz", v)
            Threads.atomic_add!(bytes, length(v))
        end
        for (sha, path) in e.figures
            key = figure_key("figures", sha, path)
            has_object(store, key) && continue
            image = read(path)
            write_object!(store, key, image; content_type = image_type(path))
            Threads.atomic_add!(bytes, length(image))
        end
        j = gzip(e.json)
        write_object!(store, "docs/$(e.hash).json.gz", j)            # after its vectors and figures: it marks the document complete
        Threads.atomic_add!(bytes, length(j))
        n = Threads.atomic_add!(uploaded, 1) + 1
        progress("Uploading [$n/$(length(exports))] $(round(bytes[] / 1e6; digits = 1)) MB · $(e.id)")
    end
    cancelled() && stop()
    dims = Dict(r.name => r.dim for r in query(kb, "SELECT name, dim FROM layers"))
    # The landscape goes with the documents, under its content's hash like them.
    landscape = nothing
    if isfile(landscape_path(kb.config))
        map_json = read(landscape_path(kb.config))
        landscape = bytes2hex(sha256(map_json))
        get(published, "landscape", nothing) == landscape ||
            write_object!(store, "landscape/$landscape.json.gz", gzip(map_json))
    end
    # So do the papers of the day: their analyses as one object, each figure as one of its own, both
    # under their contents' hashes, so a figure is uploaded once.
    daily = nothing
    archive, figures = export_daily(kb)
    if archive != "[]"
        daily = bytes2hex(sha256(archive))
        if get(published, "daily", nothing) != daily
            for (sha, path) in unique(figures)
                key = figure_key("daily/figures", sha, path)
                has_object(store, key) || write_object!(store, key, read(path); content_type = image_type(path))
            end
            write_object!(store, "daily/$daily.json.gz", gzip(Vector{UInt8}(archive)))
        end
    end
    content = kb.config.dataset.content ? publish_content!(kb, store, streams, published, at) : Dict{String,Any}()
    # The streams this knowledge base had imported, and this one: what its site was built from.
    imported = merge(streams_imported(kb), Dict(stream => at))
    # The site's rendered notebooks and its build, a new consumer's head start (see site_publish.jl).
    parts = !site_parts ? (; notebooks = Dict{String,Any}(), site = nothing) :
            publish_site_parts!(kb, store, published; dataset = imported, progress)
    # Each publish's own mark (its time may be another's, to the second): what a machine that takes
    # the stream, or publishes it, compares with what it last took (see `pull!`).
    manifest = Dict("format" => DATASET_FORMAT, "stream" => stream, "id" => string(uuid4()), "published_at" => at, "schema" => schema_version(),
        "dims" => Dict(l.name => dims[l.name] for l in ingest_layers(kb.config) if haskey(dims, l.name)),
        "documents" => documents, "content" => content, "landscape" => landscape, "daily" => daily,
        "notebooks" => parts.notebooks, "site" => parts.site)
    m = Vector{UInt8}(JSON.json(manifest))
    write_object!(store, "history/$stream/$(replace(at, r"[:-]" => "")).json", m; content_type = "application/json")
    write_object!(store, "streams/$stream.json", m; content_type = "application/json")
    # The streams as they are now: another member may have published since this publish began.
    site_parts && prune_site_parts!(store, [collect(values(read_streams(store))); manifest], published; progress)
    transaction(kb) do
        execute!(kb, "DELETE FROM published_docs")
        for id in ids
            id in incomplete && continue                                # exported again once embedded
            execute!(kb, "INSERT INTO published_docs VALUES (?, ?, ?, ?)", (id, prints[id], hashes[id], at))
        end
        execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_published_at', ?)", (at,))
        execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_stream_id', ?)", (manifest["id"],))
    end
    isempty(incomplete) || progress("Left out $(length(incomplete)) documents whose vectors Qdrant lost, until a sync embeds them again: $(join(first(incomplete, 5), ", "))")
    return (; stream, documents = length(documents), changed = length(changed), uploaded = uploaded[], bytes = bytes[],
              incomplete = length(incomplete))
end

# ── Importing ─────────────────────────────────────────────────────────────────────────────────────

"""
    pull!(kb; store = dataset_store(kb.config), ntasks = 8, progress, cancelled, site_parts) -> NamedTuple

Import the dataset: of each document a stream carries, the copy [`stream_winners`](@ref) picks,
downloaded when its content hash differs from what was last imported (`ntasks` at a time) and merged
into the database and Qdrant as it arrives; and remove the documents imported that no stream carries
any more. A publisher's own documents are left alone: those its stream carries, and those it read
since. Without Qdrant the vectors are left out, and a later import with Qdrant running adds them. The
landscape and the site's parts come from the stream published last, replacing a consumer's own
landscape, and the papers of the day from every stream (see [`import_daily!`](@ref)). Figures
published as PNG images are converted to WebP (see [`webp_figures!`](@ref)). The profile is
kept, and the config follows the dataset's models from then on (see [`follow_profile`](@ref)). Returns `(; streams, documents, imported, removed)`. While
it runs, the site waits to be built (see [`IMPORTS`](@ref)).
"""
function pull!(kb::KB; kw...)
    Threads.atomic_add!(IMPORTS, 1)
    try
        return lock(() -> pull_dataset!(kb; kw...), DATASET_LOCK)
    finally
        Threads.atomic_sub!(IMPORTS, 1)
    end
end

"""
Held while the dataset is imported or published: one of each at a time, so a publish never reads a
knowledge base half imported, nor two imports take the same documents (an import started while a
sync imports, say).
"""
const DATASET_LOCK = ReentrantLock()

"""
How many imports of the dataset are running. A site built during one would read a knowledge base
half imported: pages linking to papers not in it yet, notebooks citing nothing. So a build waits.
"""
const IMPORTS = Threads.Atomic{Int}(0)

function pull_dataset!(kb::KB; store::DatasetStore = dataset_store(kb.config), ntasks::Integer = 8,
                       progress = msg -> nothing, cancelled = () -> false, site_parts::Bool = SITE_PARTS[])
    progress("Reading the dataset's profile and streams")
    publisher = kb.config.dataset.role == :publish
    profile = read_profile(store)
    if profile === nothing
        # A publisher may be the first: there is nothing to import yet.
        publisher && return (; streams = 0, documents = 0, imported = 0, removed = 0)
        error("The dataset has no profile.json; nothing has been published there yet")
    end
    mkpath(kb.config.data_dir)
    write(profile_cache(kb.config), JSON.json(profile))
    kb.config = follow_profile(kb.config)
    streams = read_streams(store)
    # A publisher's own stream is not imported when it is as this machine last published it. Published
    # since from elsewhere (the member on a new machine, or on two), it is taken as it is, and what it
    # takes stays the stream's (see `own_documents`); this machine then publishes on from there.
    own = publisher ? get(streams, stream_name(kb.config), nothing) : nothing
    taken = own === nothing || isequal(get(own, "id", nothing), scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_stream_id'"))
    me = publisher && taken ? stream_name(kb.config) : ""
    dims = Dict{String,Int}(k => v for m in values(streams) for (k, v) in get(m, "dims", Dict()))
    layers = Dict(l["name"] => (manifest_layer(l), dims[l["name"]]) for l in profile["layers"] if haskey(dims, l["name"]))
    winners = stream_winners(streams)
    qdrant = Qdrant.ping()
    qdrant || progress("Qdrant is not running: importing without vectors, so search uses keywords until a later import adds them")
    have = Dict(r.doc_id => r.hash for r in query(kb, "SELECT doc_id, hash FROM dataset_docs"))
    without = Set(r.doc_id for r in query(kb, "SELECT doc_id FROM dataset_docs WHERE vectors = 0"))
    # What a person here dropped stays out (see dropped.jl).
    out = Set(d.id for d in dropped_documents(kb))
    todo = [(id, name, d) for (id, (name, d)) in winners if name != me && !(id in out) &&
            (get(have, id, "") != d["hash"] || (qdrant && d["vectors"] && id in without))]
    kept_out = count(in(out), keys(winners))
    kept_out > 0 && progress("Keeping out $kept_out dropped $(kept_out == 1 ? "document" : "documents")")
    bytes = Threads.Atomic{Int}(0)
    # Documents are imported as their downloads arrive, one at a time on this task (the database
    # connection is shared), so one slow download holds up no others and an interrupted import keeps
    # what it finished. A failed download closes the channel with its error.
    fetched = Channel{Any}(2ntasks) do ready
        asyncmap(todo; ntasks) do (id, stream, d)
            cancelled() && return
            hash = d["hash"]
            json = read_object(store, "docs/$hash.json.gz")
            json === nothing && error("The stream $stream names docs/$hash.json.gz for $id, which is missing")
            Threads.atomic_add!(bytes, length(json))
            json = gunzip(json)
            bytes2hex(sha256(json)) == hash || error("docs/$hash.json.gz does not match its hash")
            doc = JSON.parse(String(json))
            vectors = UInt8[]
            if d["vectors"] && qdrant
                v = something(read_object(store, "docs/$hash.vec.gz"), UInt8[])
                Threads.atomic_add!(bytes, length(v))
                vectors = gunzip(v)
            end
            qdrant && (bytes2hex(sha256(vectors)) == doc["vectors_sha"] || error("The vectors of $id do not match their hash"))
            Threads.atomic_add!(bytes, import_figures!(kb, store, id, get(doc, "figures", [])))
            put!(ready, (; id, stream, hash, doc, vectors))
        end
    end
    imported = 0
    for f in fetched
        cancelled() && break
        lock(paper_lock(f.id)) do
            import_document!(kb, f.doc, f.vectors, layers; vectors_too = qdrant)
            # Its reading as it came, so reading it again here makes it this knowledge base's own.
            print = fingerprints(kb, [f.id]; record = false)[f.id]
            execute!(kb, "INSERT OR REPLACE INTO dataset_docs VALUES (?, ?, ?, ?, ?, ?)", (f.id, f.hash, now_iso(), Int(qdrant), f.stream, print))
        end
        imported += 1
        progress("Importing [$imported/$(length(todo))] $(round(bytes[] / 1e6; digits = 1)) MB · $(f.id)")
    end
    close(fetched)                      # (stops the downloads when cancelled)
    # Cancelled, it has imported only some of the documents: nothing else is taken, and no stream is
    # noted as imported, so the next import takes up from here.
    cancelled() && return (; streams = length(streams), documents = length(winners), imported, removed = 0)
    # What no stream carries any more goes, unless this knowledge base has read it since.
    kept = publisher ? Set(own_documents(kb, collect(keys(have)))) : Set{String}()
    gone = [id for id in keys(have) if !haskey(winners, id) && !(id in kept)]
    for id in gone
        ismissing(paper_id(kb, id)) || remove_paper!(kb, id)
        execute!(kb, "DELETE FROM dataset_docs WHERE doc_id = ?", (id,))
    end
    from = latest_stream(m -> m["landscape"] !== nothing, streams)
    landscape = from === nothing || from == me ? nothing : streams[from]["landscape"]
    path = landscape_path(kb.config)
    if landscape !== nothing && (!isfile(path) || bytes2hex(sha256(read(path))) != landscape)
        progress("Importing the landscape")
        got = read_object(store, "landscape/$landscape.json.gz")
        got === nothing && error("The stream $from names landscape/$landscape.json.gz, which is missing")
        map_json = gunzip(got)
        bytes2hex(sha256(map_json)) == landscape || error("landscape/$landscape.json.gz does not match its hash")
        write(path, map_json)
    end
    dailies = sort!([n => m["daily"] for (n, m) in streams if n != me && m["daily"] !== nothing])
    mark = join(("$n:$h" for (n, h) in dailies), ",")
    if !isempty(dailies) && !isequal(scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_daily'"), mark)
        progress("Importing the papers of the day")
        import_daily!(kb, store, last.(dailies))
        execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_daily', ?)", (mark,))
    end
    # Figures published before they were WebP come as PNG images, and are converted here.
    webp_figures!(kb; progress, cancelled)
    if kb.config.dataset.content
        got = import_content!(kb, store, streams; skip = me)
        got.conflicts > 0 && progress("$(got.conflicts) content file(s) were changed by another member as well as here: see the conflicts to settle")
    end
    seen = Dict(n => m["published_at"] for (n, m) in streams if n != me)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_streams', ?)", (JSON.json(seen),))
    site = latest_stream(m -> m["site"] !== nothing || !isempty(something(m["notebooks"], Dict())), streams; skip = me)
    site_parts && site !== nothing && install_site_parts!(kb, store, streams[site]; progress)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_pulled', ?)", (now_iso(),))
    taken || execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_stream_id', ?)", (own["id"],))
    return (; streams = length(streams), documents = length(winners), imported, removed = length(gone))
end

"""
    export_daily(kb) -> (json, figures)

The papers of the day as the dataset carries them: the finished days' picks with their analyses and
every figure cut from their papers (`gallery`), as JSON, each figure named by its contents' hash, and
the figures as `(sha, path)` pairs.
"""
function export_daily(kb::KB)
    figures = Tuple{String,String}[]
    days = map(query(kb, "SELECT * FROM daily WHERE status = 'done' ORDER BY day, picked_at")) do r
        figs = JSON.parse(coalesce(r.figures, "[]"))
        gallery = [Dict{String,Any}(String(k) => v for (k, v) in pairs(g)) for g in paper_figures(kb, r.doc_id)]
        for f in [figs; gallery]
            haskey(f, "file") || continue
            path = joinpath(figures_dir(kb.config, r.doc_id), f["file"])
            isfile(path) || (delete!(f, "file"); continue)
            f["sha"] = bytes2hex(open(sha256, path))
            push!(figures, (f["sha"], path))
        end
        filter!(g -> haskey(g, "file"), gallery)
        Dict("day" => r.day, "doc_id" => r.doc_id, "source" => r.source, "why" => r.why, "analysis" => coalesce(r.analysis, ""),
             "figures" => figs, "computable" => JSON.parse(coalesce(r.computable, "{}")), "notebook" => coalesce(r.notebook, nothing),
             "notebook_status" => coalesce(r.notebook_status, nothing), "picked_at" => r.picked_at, "done_at" => coalesce(r.done_at, nothing),
             "relevance" => coalesce(r.relevance, nothing), "gallery" => gallery)
    end
    return JSON.json(days), unique(figures)
end

"When a day's paper was finished, as the papers of the day are merged by."
daily_time(d) = something(d["done_at"], d["picked_at"])

"""
Whether a paper of the day from another stream names only files of its paper's figures: the day as a
date, its paper as an id, and each figure as a plain image name (see `FIGURE_NAME`), which a stream
could otherwise use to have a file written anywhere on an importer's machine.
"""
function imported_day_ok(d::AbstractDict)
    figure_ok(f) = !haskey(f, "file") || occursin(FIGURE_NAME, string(f["file"]))
    return occursin(r"^\d{4}-\d{2}-\d{2}$", string(d["day"])) && occursin(r"^[A-Za-z0-9][A-Za-z0-9.\-/]*$", string(d["doc_id"])) &&
           !occursin("..", string(d["doc_id"])) && all(figure_ok, [d["figures"]; get(d, "gallery", [])])
end

"""
    import_daily!(kb, store, hashes)

Take in the streams' papers of the day (the objects `daily/<hash>.json.gz`): each day's pick and
analysis, the one finished last where streams pick differently, unless the day here was finished as
late; and its paper's figures where this knowledge base lacks them, each checked against its hash.
"""
function import_daily!(kb::KB, store::DatasetStore, hashes)
    best = Dict{String,Any}()
    for hash in hashes
        got = read_object(store, "daily/$hash.json.gz")
        got === nothing && error("The dataset names daily/$hash.json.gz, which is missing")
        json = gunzip(got)
        bytes2hex(sha256(json)) == hash || error("daily/$hash.json.gz does not match its hash")
        for d in JSON.parse(String(json))
            imported_day_ok(d) || (@warn "A paper of the day in the dataset names a file outside its paper's figures, left out" d["day"]; continue)
            was = get(best, d["day"], nothing)
            (was === nothing || isless(daily_time(was), daily_time(d))) && (best[d["day"]] = d)
        end
    end
    here = Dict(r.day => coalesce(r.done_at, r.picked_at) for r in query(kb, "SELECT day, done_at, picked_at FROM daily WHERE status = 'done'"))
    days = sort!([d for d in values(best) if !(haskey(here, d["day"]) && here[d["day"]] >= daily_time(d))]; by = d -> d["day"])
    for d in days, f in [d["figures"]; get(d, "gallery", [])]
        haskey(f, "sha") && haskey(f, "file") || continue
        path = joinpath(figures_dir(kb.config, d["doc_id"]), f["file"])
        isfile(path) && bytes2hex(open(sha256, path)) == f["sha"] && continue
        key = figure_key("daily/figures", f["sha"], f["file"])
        image = read_object(store, key)
        image === nothing && error("The dataset names $key, which is missing")
        bytes2hex(sha256(image)) == f["sha"] || error("$key does not match its hash")
        mkpath(dirname(path))
        write(path, image)
    end
    transaction(kb) do
        for d in days
            # One this machine finished earlier for the day gives way, so every member shows the same paper.
            execute!(kb, "DELETE FROM daily WHERE day = ? AND doc_id != ? AND status = 'done'", (d["day"], d["doc_id"]))
            execute!(kb, """INSERT OR REPLACE INTO daily (day, doc_id, source, why, status, analysis, figures, computable,
                                                          error, picked_at, done_at, notebook, notebook_status, relevance)
                            VALUES (?, ?, ?, ?, 'done', ?, ?, ?, NULL, ?, ?, ?, ?, ?)""",
                     (d["day"], d["doc_id"], d["source"], d["why"], d["analysis"], JSON.json(d["figures"]),
                      JSON.json(d["computable"]), d["picked_at"], something(d["done_at"], missing),
                      something(d["notebook"], missing), something(d["notebook_status"], missing),
                      something(get(d, "relevance", nothing), missing)))
            haskey(d, "gallery") || continue
            pid = paper_id(kb, d["doc_id"])
            ismissing(pid) && continue
            execute!(kb, "DELETE FROM figures WHERE paper_id = ?", (pid,))
            for g in d["gallery"]
                execute!(kb, "INSERT INTO figures VALUES (?, ?, ?, ?, ?, ?)", (pid, get(g, "kind", "figure"), g["number"], g["label"], g["caption"], g["file"]))
            end
        end
    end
    return length(days)
end

"""
    import_document!(kb, doc, vectors, layers; vectors_too = true)

Replace one document's data with the dataset's: its record, mentions, parse, the summaries and
classification it carries, and (with `vectors_too`) its vectors in the dataset's `layers`
(name => (layer, dim)).
"""
function import_document!(kb::KB, doc::AbstractDict, vectors::AbstractVector{UInt8}, layers::AbstractDict; vectors_too::Bool = true)
    id = doc["doc_id"]
    P = doc["paper"]
    val(x) = x === nothing ? missing : x
    transaction(kb) do
        execute!(kb, """
            INSERT INTO papers (doc_id, version, title, abstract, authors, published, updated, primary_category, categories,
                                doi, journal_ref, metadata_at, added_at, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (doc_id) DO UPDATE SET version = excluded.version, title = excluded.title,
                abstract = excluded.abstract, authors = excluded.authors, published = excluded.published,
                updated = excluded.updated, primary_category = excluded.primary_category, categories = excluded.categories,
                doi = excluded.doi, journal_ref = excluded.journal_ref, metadata_at = excluded.metadata_at,
                kind = excluded.kind""",
            Tuple(val(P[k]) for k in ("doc_id", "version", "title", "abstract", "authors", "published", "updated",
                                      "primary_category", "categories", "doi", "journal_ref", "metadata_at", "added_at", "kind")))
        pid = paper_id(kb, id)
        execute!(kb, "DELETE FROM mentions WHERE paper_id = ?", (pid,))
        for x in doc["mentions"]
            execute!(kb, "INSERT OR IGNORE INTO mentions (paper_id, source, channel, posted_at, author, url, message) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (pid, x["source"], val(x["channel"]), val(x["posted_at"]), val(x["author"]), val(x["url"]), val(x["message"])))
        end
        execute!(kb, "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE paper_id = ?)", (pid,))
        for t in ("chunks", "blocks", "sections", "parses")
            execute!(kb, "DELETE FROM $t WHERE paper_id = ?", (pid,))
        end
        if doc["parse"] !== nothing
            x = doc["parse"]
            execute!(kb, "INSERT INTO parses VALUES (?, ?, ?, ?, ?)", (pid, x["file_sha"], x["parser_version"], val(x["pages"]), now_iso()))
            for x in doc["sections"]
                execute!(kb, "INSERT INTO sections VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (pid, x["ord"], x["level"], val(x["number"]), x["title"], x["path"], val(x["page_start"]), val(x["page_end"])))
            end
            for x in doc["blocks"]
                execute!(kb, "INSERT INTO blocks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (pid, x["ord"], x["section"], x["kind"], x["page"], val(x["x0"]), val(x["y0"]), val(x["x1"]), val(x["y1"]), x["text"]))
            end
            paths = Dict(x["ord"] => x["path"] for x in doc["sections"])
            title = coalesce(val(P["title"]), id)
            for x in doc["chunks"]
                execute!(kb, "INSERT INTO chunks (paper_id, ord, section, page_start, page_end, text) VALUES (?, ?, ?, ?, ?, ?)",
                    (pid, x["ord"], x["section"], val(x["page_start"]), val(x["page_end"]), x["text"]))
                execute!(kb, "INSERT INTO chunks_fts (rowid, text, section, title) VALUES (last_insert_rowid(), ?, ?, ?)",
                    (x["text"], x["section"] == 0 ? "Abstract" : get(paths, x["section"], ""), title))
            end
        end
        for name in unique(x["summarizer"] for x in doc["summaries"])
            execute!(kb, "DELETE FROM summaries WHERE paper_id = ? AND summarizer = ?", (pid, name))
        end
        for x in doc["summaries"]
            execute!(kb, "INSERT OR REPLACE INTO summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (pid, x["unit_key"], x["summarizer"], x["model"], x["prompt_version"], x["input_sha"], x["text"], missing, missing, x["created_at"]))
        end
        c = doc["classification"]
        c === nothing || execute!(kb, "INSERT OR REPLACE INTO classifications VALUES (?, ?, ?, ?, ?)",
            (pid, c["classifier"], c["model"], c["data"], c["created_at"]))
        # Data published before figures travelled carries none, and leaves those here alone.
        if haskey(doc, "figures")
            execute!(kb, "DELETE FROM figures WHERE paper_id = ?", (pid,))
            for f in doc["figures"]
                figure_ok(f) && isfile(joinpath(figures_dir(kb.config, id), f["file"])) || continue
                execute!(kb, "INSERT OR REPLACE INTO figures VALUES (?, ?, ?, ?, ?, ?)",
                         (pid, f["kind"], f["number"], f["label"], f["caption"], f["file"]))
            end
        end
    end
    vectors_too && import_vectors!(kb, id, doc["embeddings"], vectors, layers)
    return nothing
end

"""
    import_figures!(kb, store, id, figures) -> Int

Download the images of the figures a document's data names (see [`export_figures`](@ref)) into its
paper's folder, each checked against its hash, unless it is there already. A figure whose name or image
is not as it should be is left out. Returns the bytes downloaded.
"""
function import_figures!(kb::KB, store::DatasetStore, id::AbstractString, figures)
    got = 0
    for f in figures
        figure_ok(f) || (@warn "A figure in the dataset is named outside its paper's figures, left out" id; continue)
        path = joinpath(figures_dir(kb.config, id), f["file"])
        isfile(path) && bytes2hex(open(sha256, path)) == f["sha"] && continue
        image = read_object(store, figure_key("figures", f["sha"], f["file"]))
        if image === nothing || bytes2hex(sha256(image)) != f["sha"]
            @warn "A figure the dataset names is missing or does not match its hash, left out" id f["file"]
            continue
        end
        mkpath(dirname(path))
        write(path, image)
        got += length(image)
    end
    return got
end

function import_vectors!(kb::KB, id::AbstractString, embeddings, vectors::AbstractVector{UInt8}, layers::AbstractDict)
    pid = paper_id(kb, id)
    values = reinterpret(Float16, collect(vectors))
    offset = 0
    by_layer = Dict{String,Vector{Any}}()
    for e in embeddings
        l, dim = layers[e["layer"]]
        push!(get!(by_layer, l.name, []), (e, Float32.(values[offset+1:offset+dim])))
        offset += dim
    end
    offset == length(values) || error("The vectors of $id do not match its embeddings")
    for (name, (l, dim)) in layers
        entries = get(by_layer, name, [])
        stored = [r.unit_key for r in query(kb, "SELECT unit_key FROM embeddings WHERE layer = ? AND paper_id = ?", (name, pid))]
        stale = setdiff(stored, (e["unit_key"] for (e, _) in entries))
        isempty(entries) && isempty(stale) && continue
        coll = ensure_layer!(kb, l, dim)
        isempty(stale) || delete_vectors!(coll, [point_id(name, k) for k in stale])
        ids = [point_id(name, e["unit_key"]) for (e, _) in entries]
        isempty(entries) || upsert_vectors!(coll, ids, [v for (_, v) in entries], [e["payload"] for (e, _) in entries])
        transaction(kb) do
            for k in stale
                execute!(kb, "DELETE FROM embeddings WHERE layer = ? AND unit_key = ?", (name, k))
            end
            for ((e, _), pt) in zip(entries, ids)
                execute!(kb, "INSERT OR REPLACE INTO embeddings VALUES (?, ?, ?, ?, ?, ?)", (name, e["unit_key"], pid, e["text_sha"], pt, now_iso()))
            end
        end
    end
    return nothing
end

"What a publication did, for people."
format_publish(r) = "Published $(r.documents) documents to the stream $(r.stream): $(r.changed) changed since they were last published, " *
                    "$(r.uploaded) uploaded ($(round(r.bytes / 1e6; digits = 1)) MB)."

"What an import did, for people."
format_pull(r) = "Imported $(r.imported) of the $(r.documents) documents of the dataset's $(r.streams) stream(s)" *
                 (r.removed > 0 ? "; removed $(r.removed)." : ".")

"""
    start_publish(kb) -> Job

Publish the knowledge base's stream as a background job.
"""
function start_publish(kb::KB)
    kb.config.dataset.role == :publish ||
        error("This knowledge base is not a dataset publisher: set [dataset] role = \"publish\" in its config")
    return start_job("publish") do job
        format_publish(publish!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job)))
    end
end

"""
    start_import(kb) -> Job

Bring in the dataset as a background job: for a consumer, a sync, which imports it first (see
[`sync!`](@ref)); for a publisher, only the import, its own reading being a sync of its own.
"""
function start_import(kb::KB)
    kb.config.dataset.role == :consume && return start_sync(kb)
    running = filter(j -> j.status == :running && j.name == "import the dataset", list_jobs())
    isempty(running) || return first(running)
    return start_job("import the dataset"; changes = changes_stamp(kb.config)) do job
        format_pull(pull!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job)))
    end
end

"""
    new_publish(kb; store = dataset_store(kb.config)) -> Union{String,Nothing}

When another member's stream was last published, if this knowledge base has not imported that
publish; `nothing` when there is nothing new. Reads only the streams' manifests, and notes the
time of the check.
"""
function new_publish(kb::KB; store::DatasetStore = dataset_store(kb.config))
    me = kb.config.dataset.role == :publish ? stream_name(kb.config) : ""
    streams = read_streams(store)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_checked', ?)", (now_iso(),))
    seen = streams_imported(kb)
    newer = [m["published_at"] for (n, m) in streams if n != me && get(seen, n, nothing) != m["published_at"]]
    return isempty(newer) ? nothing : maximum(newer)
end

"""
    follow_dataset!(kb) -> Task

While this knowledge base is a member of a dataset with `check_hours > 0`, check that often for a
stream published since the last import (see [`new_publish`](@ref)) and import it (see
[`start_import`](@ref)). The settings are read each minute, so joining a dataset in Setup, or a new
interval on the Configuration page, takes effect without a restart. `zemi` starts this, so a site
left running stays current.
"""
function follow_dataset!(kb::KB)
    return Threads.@spawn begin
        checked = time()
        while !STOPPING[]
            pause(60)
            d = kb.config.dataset
            (d.role != :none && d.check_hours > 0 && time() - checked >= d.check_hours * 3600) || continue
            checked = time()
            try
                new_publish(kb) === nothing || running_sync() !== nothing || start_import(kb)
            catch e
                (e isa InterruptException || STOPPING[]) && break
                @warn "Checking the dataset for a new publish failed; trying again later" exception = e
            end
        end
    end
end

"""
    start_autosync!(kb) -> Union{Task,Nothing}

A publisher's timer, started once in a process where the tools are served (see
[`create_tools`](@ref)): every `autosync_hours`, sync (reading every recorded paper when
`read_unread`) and publish. Runs come one period after the last run, whether it published or not
(before any, after the last publication), so restarting neither resets the clock nor starts a long
run unasked.
"""
function start_autosync!(kb::KB)
    d = kb.config.dataset
    (d.role == :publish && d.autosync_hours > 0) || return nothing
    period = d.autosync_hours * 3600
    return Threads.@spawn while !STOPPING[]
        # From the last run, whether it published or not: one that failed (or was cancelled) is not
        # run again at once, at the cost of reading every unread paper again.
        last = scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_autosync_at'")
        ismissing(last) && (last = scalar(kb, "SELECT value FROM kv WHERE key = 'dataset_published_at'"))
        since = ismissing(last) ? 0.0 : seconds_since(last)
        pause(max(60.0, period - since))
        STOPPING[] && break
        try
            execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('dataset_autosync_at', ?)", (now_iso(),))
            job = start_sync(kb; unread = d.read_unread, publish = true)
            wait(job)
            job.status == :done || @warn "Autosync did not finish; the next is in $(d.autosync_hours) hours" status = job.status error = job.error
        catch e
            (e isa InterruptException || STOPPING[]) && break
            @error "Autosync failed" exception = (e, catch_backtrace())
        end
    end
end
