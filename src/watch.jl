# Watching arXiv for new papers the group would want: recent submissions in the watched categories,
# each placed against the focus areas and the library as the landscape places papers, and kept with
# the library papers nearest it, so a reader sees why it was picked.

# A group without focus areas places papers by the library alone: their area and its score are NULL.
migration!(21, ["""CREATE TABLE watch_new (
                       doc_id TEXT PRIMARY KEY,
                       title TEXT NOT NULL,
                       authors TEXT NOT NULL,
                       abstract TEXT NOT NULL,
                       published TEXT NOT NULL,
                       category TEXT NOT NULL,
                       score REAL NOT NULL,
                       area TEXT,
                       area_score REAL,
                       nearest TEXT NOT NULL,
                       found_at TEXT NOT NULL,
                       relevance INTEGER,
                       reason TEXT,
                       judged_by TEXT,
                       taken TEXT,
                       taken_at TEXT)""",
                "INSERT INTO watch_new SELECT * FROM watch",
                "DROP TABLE watch",
                "ALTER TABLE watch_new RENAME TO watch"])

# Each watched paper's embedding by title and abstract, unit length, as `Float32`s: placed again
# against changed focus areas without embedding it again.
migration!(22, ["ALTER TABLE watch ADD COLUMN vector BLOB"])

migration!(34, ["ALTER TABLE watch ADD COLUMN doi TEXT",
                "ALTER TABLE watch ADD COLUMN work_id TEXT",
                "ALTER TABLE watch ADD COLUMN origins TEXT NOT NULL DEFAULT '[]'"])

# A DOI candidate can already have been added manually as an uploaded paper or resource.
unheld_watch_sql() = """watch.doc_id NOT IN (SELECT doc_id FROM papers)
    AND (watch.doi IS NULL OR (NOT EXISTS (SELECT 1 FROM papers p WHERE lower(p.doi) = watch.doi)
        AND NOT EXISTS (SELECT 1 FROM doi_arxiv d JOIN papers p ON p.doc_id = d.doc_id WHERE d.doi = watch.doi)))"""

watch_sources_enabled(c) = !isempty(c.watch_categories) || !isempty(c.watch_venues) ||
                           !isempty(c.watch_authors) || c.watch_citing_library || c.watch_missing_per_check > 0

"""
    watch!(kb; list = list_new_papers, now = now(UTC), progress, cancelled) -> Int

Ask arXiv for the new papers in each of the config's `watch_categories` (`list(category, since,
config)`, by default from OAI-PMH, see [`list_new_papers`](@ref)), and place those posted within
`watch_days` that are neither in the knowledge base nor already watched: embedded by title
and abstract in the landscape layer (see [`landscape_layer`](@ref)), each is scored by its nearest
focus area and by its nearest paper of the library, its score the mean of the two. They are kept in
the `watch` table, and entries older than four times `watch_days` are let go. Those watched already
are placed again first when the group has changed (see [`replace_watched!`](@ref)). Returns how many
new papers were placed.
"""
function watch!(kb::KB; list = (cat, since, c) -> list_new_papers(cat, since, c; patience = WATCH_PATIENCE), now::DateTime = Dates.now(UTC),
                progress = msg -> nothing, cancelled = () -> false, openalex = openalex_watch, references = missing_watch)
    c = kb.config
    since = Date(now) - Day(c.watch_days)
    execute!(kb, """DELETE FROM watch WHERE published < ? AND coalesce(taken, '') <> 'deferred'
                        AND NOT EXISTS (SELECT 1 FROM json_each(watch.origins) WHERE value = ?)""", (string(Date(now) - Day(4 * c.watch_days)), MISSING_ORIGIN))
    replace_watched!(kb; progress)
    candidates = []
    for cat in c.watch_categories
        cancelled() && return 0
        progress("asking arXiv for new papers in $cat")
        for m in list(cat, since, c)
            (isempty(m.published) || Date(m.published) < since) && continue
            push!(candidates, (; m.doc_id, m.title, m.authors, m.abstract, m.published, m.primary_category,
                                doi = m.doi, work_id = nothing, origins = ["arXiv: $cat"]))
        end
    end
    append!(candidates, openalex(kb, since; cancelled))
    cancelled() && return 0
    append!(candidates, references(kb; cancelled))
    cancelled() && return 0
    n = place_watch_candidates!(kb, candidates; progress)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('watch_checked_at', ?)", (now_iso(),))
    return n
end

# Match each discovery by all its identifiers before paying for an embedding or a
# judgment. A later source can add evidence to a previously judged watch entry.
function place_watch_candidates!(kb, candidates; progress = msg -> nothing, place = place_new_watch)
    isempty(candidates) && return 0
    c = kb.config
    held = Set{String}()
    for r in query(kb, "SELECT doc_id, doi FROM papers")
        push!(held, r.doc_id)
        ismissing(r.doi) || push!(held, normalize_doi(r.doi))
    end
    union!(held, (r.doi for r in query(kb, "SELECT doi FROM doi_arxiv WHERE doc_id IN (SELECT doc_id FROM papers)")))
    aliases = Dict{String,String}()
    origins = Dict{String,Vector{String}}()
    for r in query(kb, "SELECT doc_id, doi, work_id, origins FROM watch")
        for k in skipmissing((r.doc_id, r.doi, r.work_id))
            aliases[k] = r.doc_id
        end
        origins[r.doc_id] = json_list(r.origins)
    end
    found = []
    updates = Dict{String,NamedTuple}()
    for m in candidates
        doi = isnothing(m.doi) ? nothing : normalize_doi(m.doi)
        ids = String[k for k in (m.doc_id, doi, m.work_id) if k !== nothing]
        any(in(held), ids) && continue
        dropped_as(kb; id = m.doc_id, doi = something(doi, "")) === nothing || continue
        existing = findfirst(k -> haskey(aliases, k), ids)
        id = existing === nothing ? m.doc_id : aliases[ids[existing]]
        existing === nothing && push!(found, m)
        for k in ids
            aliases[k] = id
        end
        union!(get!(Vector{String}, origins, id), m.origins)
        old = get(updates, id, (; doi = missing, work_id = missing))
        updates[id] = (; doi = something(doi, old.doi), work_id = something(m.work_id, old.work_id))
    end
    placed = isempty(found) ? [] : place(c, found, progress)
    transaction(kb) do
        for (; m, near, u, area, fit, score) in placed
            execute!(kb, """INSERT OR IGNORE INTO watch (doc_id, title, authors, abstract, published, category,
                                score, area, area_score, nearest, found_at, vector) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (m.doc_id, m.title, JSON.json(m.authors), m.abstract, m.published, m.primary_category,
                 score, area, fit, JSON.json(near), now_iso(), vector_blob(u)))
        end
        for (id, ids) in updates
            execute!(kb, """UPDATE watch SET doi = coalesce(?,doi), work_id = coalesce(?,work_id), origins = ?
                            WHERE doc_id = ?""", (ids.doi, ids.work_id, JSON.json(origins[id]), id))
        end
    end
    return length(found)
end

function place_new_watch(c, found, progress)
    l = landscape_layer(c)
    progress("placing $(length(found)) new papers against the focus areas and the library")
    vectors = watch_vectors(c, l, [(m.title, m.abstract) for m in found])
    areas = focus_vectors(c, l)
    coll = collection_name(c, l)
    # Placed first, then written in one short transaction: the searches are not made holding the lock.
    return map(zip(found, vectors)) do (m, u)
        near = [(id = String(split(h.key, ':'; limit = 2)[2]), score = round(h.score; digits = 4))
                for h in vector_search(coll, u; limit = 3)]
        (; m, near, u, place_watched(c, areas, u, isempty(near) ? 0.0 : first(near).score)...)
    end
end

"What the watched papers are placed and judged against: the group as agents are told of it (see [`group_brief`](@ref))."
watch_basis(c::Config) = bytes2hex(sha256(group_brief(c)))

"Papers' embeddings by title and abstract in layer `l`, each of unit length."
function watch_vectors(c::Config, l::Layer, papers::AbstractVector)
    prep(title, abstract) = first(l.doc_prefix * "$title\n\n$abstract", l.max_chars)
    vs = reduce(vcat, (embed(c, l, [prep(p...) for p in batch]) for batch in Iterators.partition(papers, 32)); init = Vector{Float64}[])
    return [Float64.(v) ./ max(norm(v), eps()) for v in vs]
end

"The focus areas' embeddings in layer `l` as unit columns; `nothing` when the group has none."
focus_vectors(c::Config, l::Layer) = isempty(c.group.focus_areas) ? nothing :
    unit_columns(reduce(hcat, [Float64.(query_vector(c, l, f.description)) for f in c.group.focus_areas]))

"""
A watched paper's place, from its unit embedding `u` and the score of its nearest library paper:
`(; area, fit, score)`, its nearest focus area and how near, and its score, the mean of the two
nearnesses. Without focus areas a paper is placed by the library alone, its area `missing`.
"""
function place_watched(c::Config, areas, u::AbstractVector, library::Real)
    areas === nothing && return (; area = missing, fit = missing, score = round(library; digits = 4))
    f = areas' * u
    a = argmax(f)
    fit = round(f[a]; digits = 4)
    return (; area = c.group.focus_areas[a].name, fit, score = round((fit + library) / 2; digits = 4))
end

vector_blob(u::AbstractVector) = collect(reinterpret(UInt8, Float32.(u)))
blob_vector(b::AbstractVector{UInt8}) = Float64.(reinterpret(Float32, b))

"""
    note_watch_basis!(kb)

Record the group as it is now as what the watched papers were placed and judged against, where no
basis is recorded yet (see [`replace_watched!`](@ref)): before a change to the group, so the change
is seen as one.
"""
note_watch_basis!(kb::KB) = execute!(kb, "INSERT OR IGNORE INTO kv VALUES ('watch_basis', ?)", (watch_basis(kb.config),))

"""
    replace_watched!(kb; progress) -> Int

When the group has changed since the watched papers were placed and judged (see [`watch_basis`](@ref)),
place those not in the knowledge base again against its focus areas, from their stored embeddings (embedding any
stored without one), and clear their ratings for the judge to rate them again (see
[`judge_watched!`](@ref)). A knowledge base that recorded no basis yet takes the group as it is now
as what its papers were judged against. Returns how many were placed again.
"""
function replace_watched!(kb::KB; progress = msg -> nothing)
    c = kb.config
    basis = watch_basis(c)
    stored = scalar(kb, "SELECT value FROM kv WHERE key = 'watch_basis'")
    record() = execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('watch_basis', ?)", (basis,))
    ismissing(stored) && (record(); return 0)
    stored == basis && return 0
    rows = query(kb, """SELECT doc_id, title, abstract, nearest, vector FROM watch
                        WHERE taken IS NULL AND doc_id NOT IN (SELECT doc_id FROM papers)""")
    isempty(rows) && (record(); return 0)
    progress("placing the $(length(rows)) watched papers again for the group as it is now")
    l = landscape_layer(c)
    areas = focus_vectors(c, l)
    vectors = Dict(r.doc_id => blob_vector(r.vector) for r in rows if !ismissing(r.vector))
    if areas !== nothing
        bare = [r for r in rows if !haskey(vectors, r.doc_id)]
        for (r, u) in zip(bare, watch_vectors(c, l, [(r.title, r.abstract) for r in bare]))
            vectors[r.doc_id] = u
        end
    end
    placed = map(rows) do r
        near = JSON.parse(r.nearest)
        library = isempty(near) ? 0.0 : Float64(first(near)["score"])
        u = get(vectors, r.doc_id, nothing)
        (; id = r.doc_id, u, (u === nothing ? place_watched(c, nothing, Float64[], library) : place_watched(c, areas, u, library))...)
    end
    transaction(kb) do
        for (; id, u, area, fit, score) in placed
            execute!(kb, """UPDATE watch SET area = ?, area_score = ?, score = ?, vector = ?, relevance = NULL, reason = NULL,
                                judged_by = NULL WHERE doc_id = ?""", (area, fit, score, u === nothing ? missing : vector_blob(u), id))
        end
        record()
    end
    return length(placed)
end

"""
    fill_from_watch!(kb, ids = nothing) -> Int

Give papers without their arXiv record yet (of `ids`, or all) the title, authors, abstract, date and
category the watch found them with, where they lack them, so a paper is never known by its id alone
while arXiv is asked. The record, once fetched, replaces them. Returns the number of papers filled.
"""
function fill_from_watch!(kb::KB, ids::Union{AbstractVector{<:AbstractString},Nothing} = nothing)
    ids !== nothing && isempty(ids) && return 0
    w(col) = "(SELECT nullif(w.$col, '') FROM watch w WHERE w.doc_id = papers.doc_id)"
    only_these = ids === nothing ? "" : "AND doc_id IN ($(join(fill("?", length(ids)), ", ")))"
    sql = """
        UPDATE papers SET title = coalesce(title, $(w("title"))), abstract = coalesce(nullif(abstract, ''), $(w("abstract"))),
                          authors = coalesce(authors, $(w("authors"))), published = coalesce(published, $(w("published"))),
                          primary_category = coalesce(primary_category, $(w("category")))
        WHERE metadata_at IS NULL AND (title IS NULL OR coalesce(abstract, '') = '')
          AND doc_id IN (SELECT doc_id FROM watch) $only_these"""
    return lock(kb.lock) do
        DBInterface.close!(DBInterface.execute(kb.db, sql, ids === nothing ? () : Tuple(ids)))
        c = DBInterface.execute(kb.db, "SELECT changes() AS n")
        n = Int(first(c).n)
        DBInterface.close!(c)
        n
    end
end

# One small counter per UTC date and source. Write before checking so competing
# connections cannot both reserve the last slot. Only this ISO week's rows survive.
function reserve_watch_read!(kb, source; day = Date(now(UTC)))
    monday = day - Day(dayofweek(day) - 1)
    prefix = "watch_reads/"
    key = "$prefix$day/$source"
    return transaction(kb) do
        execute!(kb, "DELETE FROM kv WHERE key >= ? AND key < ?", (prefix, prefix * string(monday)))
        counts = query(kb, """SELECT key, CAST(value AS INTEGER) AS n FROM kv
                              WHERE key >= ? AND key < ?""", (prefix * string(monday), prefix * string(day + Day(1))))
        c = kb.config
        today = sum((r.n for r in counts if startswith(r.key, "$prefix$day/")); init = 0)
        week = sum((r.n for r in counts); init = 0)
        (c.watch_daily_reads >= 0 && today >= c.watch_daily_reads) && return false
        (c.watch_weekly_reads >= 0 && week >= c.watch_weekly_reads) && return false
        if source == "missing"
            used = sum((r.n for r in counts if endswith(r.key, "/missing")); init = 0)
            used >= c.watch_missing_weekly_reads && return false
        end
        execute!(kb, """INSERT INTO kv VALUES (?, '1') ON CONFLICT(key)
                        DO UPDATE SET value = CAST(value AS INTEGER) + 1""", (key,))
        return true
    end
end

function read_watched!(kb, ids, step, cancelled)
    results = ingest!(kb, ids; progress = step, cancelled, source = "watch")
    isempty(results) && return false
    r = only(results)
    r.ok || error("Reading $(r.id) failed: $(r.error)")
    return true
end

"""
    take_watched!(kb; progress, cancelled, read_in_full, record) -> (; read, recorded)

Take the judged watched papers into the knowledge base by their rating: those rated at least
`watch_read_from` read in full (see [`ingest!`](@ref)) one by one, until `cancelled()` leaves the
rest to the next watch, and those rated at least `watch_record_from` recorded (the arXiv record
fetched, the title and abstract embedded, see [`embed_records!`](@ref)).
Each arrives as "added from the arXiv watch", with its rating and the judge's sentence. Where papers
cannot be read here they are recorded instead. Returns the ids taken each way. `read_in_full(ids, progress)`
and `record(ids)` do the reading and recording (stand-ins in tests, which reach no arXiv).
"""
function take_watched!(kb::KB; progress = msg -> nothing, cancelled = () -> false,
                       read_in_full = (ids, step) -> read_watched!(kb, ids, step, cancelled),
                       today = () -> Date(now(UTC)),
                       record = ids -> (refresh_metadata!(kb, ids);
                                        isempty(cannot_run(kb, "embed", ids)) && embed_records!(kb, ids; progress, cancelled)))
    c = kb.config
    rows = query(kb, """SELECT doc_id AS id, relevance, coalesce(reason, '') AS reason, taken, origins FROM watch
                        WHERE relevance IS NOT NULL AND ((taken IS NULL AND $(unheld_watch_sql())) OR taken = 'arriving'
                            OR (taken = 'deferred' AND doc_id IN (SELECT doc_id FROM papers)))
                          AND doc_id NOT IN (SELECT doc_id FROM dropped WHERE restored_at IS NULL)
                        ORDER BY relevance DESC, score DESC, found_at, doc_id""")
    read = [String(r.id) for r in rows if r.relevance >= c.watch_read_from]
    recorded = [String(r.id) for r in rows if c.watch_record_from <= r.relevance < c.watch_read_from]
    if !isempty(read) && !isempty(cannot_run(kb, "ingest", PAPER))
        newly_recorded = [r.id for r in rows if r.relevance >= c.watch_read_from && !isequal(r.taken, "deferred")]
        recorded, read = [newly_recorded; recorded], String[]
    end
    why = Dict(String(r.id) => "$(RELEVANCE[r.relevance+1]): $(r.reason)" for r in rows)
    function arrived!(id, how)
        # Discovery may name a paper by DOI. In the library its ID can be an arXiv
        # ID, uploaded PDF or bibliography resource. Keep all later joins on that ID.
        # Record intent before resolving a DOI, which can involve network I/O.
        # An interrupted arrival is selected again even if its document now exists.
        execute!(kb, "UPDATE watch SET taken = 'arriving' WHERE doc_id = ?", (id,))
        ids = add_papers!(kb, [id]; source = "watch")
        if isempty(ids)
            execute!(kb, "DELETE FROM watch WHERE doc_id = ? AND taken = 'arriving'", (id,))
            return nothing
        end
        local_id = only(ids)
        transaction(kb) do
            execute!(kb, "UPDATE mentions SET message = ? WHERE paper_id = ? AND source = 'watch'", (why[id], paper_id(kb, local_id)))
            execute!(kb, "UPDATE watch SET doc_id = ?, taken = ?, taken_at = ? WHERE doc_id = ?", (local_id, how, now_iso(), id))
        end
        return local_id
    end
    records = String[]
    for id in recorded
        local_id = arrived!(id, "recorded")
        local_id === nothing || push!(records, local_id)
    end
    isempty(records) || record(records)
    missing_ids = Set(r.id for r in rows if MISSING_ORIGIN in json_list(r.origins))
    deferred = Set(r.id for r in rows if isequal(r.taken, "deferred"))
    done = String[]
    for (i, id) in enumerate(read)
        cancelled() && break
        local_id = id in deferred ? id : arrived!(id, "deferred")
        local_id === nothing && continue
        if is_resource(local_id)
            execute!(kb, "UPDATE watch SET taken = 'recorded' WHERE doc_id = ?", (local_id,))
            push!(records, local_id)
            continue
        end
        source = id in missing_ids ? "missing" : "watch"
        if !reserve_watch_read!(kb, source; day = today())
            if !(id in deferred)
                record([local_id])
                push!(records, local_id)
            end
            continue
        end
        read_in_full([local_id], m -> progress("reading new paper $i of $(length(read)) in full: $m")) === false && break
        execute!(kb, "UPDATE watch SET taken = 'read', taken_at = ? WHERE doc_id = ?", (now_iso(), local_id))
        push!(done, local_id)
    end
    return (; read = done, recorded = records)
end

"""
    watch_taken(kb) -> Vector{NamedTuple}

The watched papers taken into the knowledge base and still in it, latest first: `(; id, title,
relevance, reason, taken, taken_at, read)`, `taken` how ("read" or "recorded") and `read` whether it
is read in full now.
"""
watch_taken(kb::KB) =
    [(; id = String(r.id), title = String(coalesce(r.title, r.id)), relevance = Int(r.relevance), reason = coalesce(r.reason, ""),
        origins = json_list(r.origins), taken = String(r.taken), taken_at = String(r.taken_at), read = r.read == 1)
     for r in query(kb, """SELECT w.doc_id AS id, coalesce(p.title, w.title) AS title, w.relevance, w.reason, w.origins, w.taken, w.taken_at,
                                  EXISTS (SELECT 1 FROM parses x WHERE x.paper_id = p.id) AS read
                           FROM watch w JOIN papers p ON p.doc_id = w.doc_id WHERE w.taken IS NOT NULL AND p.access = 'open'
                           ORDER BY w.taken_at DESC, w.relevance DESC""")]

"The watched papers taken in, as the New on arXiv page lists them (see [`watch_taken`](@ref))."
watch_taken_json(kb::KB) = [Dict("id" => t.id, "slug" => page_slug(t.id), "title" => t.title, "relevance" => t.relevance,
                                 "reason" => t.reason, "origins" => t.origins, "taken" => t.taken, "taken_at" => t.taken_at, "read" => t.read)
                            for t in watch_taken(kb)]

"""
    watched(kb) -> Vector{NamedTuple}

The watched papers not in the knowledge base, best placed first: `(; id, title, authors, abstract,
published, category, score, area, area_score, nearest, relevance, reason)`, `nearest` the library
papers nearest each (`(; id, title, score)`), `area` and `area_score` `missing` where the group has
no focus areas, `relevance` the judge's 0–3 (`missing` until judged).
"""
function watched(kb::KB)
    rows = query(kb, """SELECT * FROM watch WHERE taken IS NULL AND $(unheld_watch_sql()) ORDER BY score DESC""")
    titles = Dict(r.id => coalesce(r.title, r.id) for r in query(kb, "SELECT doc_id AS id, title FROM papers"))
    return map(rows) do r
        near = [(id = String(n["id"]), title = get(titles, n["id"], n["id"]), score = Float64(n["score"]))
                for n in JSON.parse(r.nearest)]
        (; id = r.doc_id, r.title, authors = json_list(r.authors), r.abstract, r.published, r.category,
           origins = json_list(r.origins), r.score, r.area, r.area_score, nearest = near, relevance = r.relevance, reason = coalesce(r.reason, ""))
    end
end

"The watched papers as the site's list shows them (see [`watched`](@ref))."
watch_json(kb::KB) = [Dict("id" => w.id, "title" => w.title, "authors" => first(w.authors, 6), "abstract" => w.abstract,
                           "published" => w.published, "category" => w.category, "origins" => w.origins, "score" => w.score, "area" => coalesce(w.area, nothing),
                           "area_score" => coalesce(w.area_score, nothing), "relevance" => coalesce(w.relevance, nothing), "reason" => w.reason,
                           "nearest" => [Dict("id" => n.id, "slug" => page_slug(n.id), "title" => n.title, "score" => n.score)
                                         for n in w.nearest])
                      for w in watched(kb)]

"""
    watch_regrouped!(kb) -> Union{Job,Nothing}

A watch job (see [`start_watch`](@ref)) when the group has changed since the watched papers were
placed and judged, to place and judge them again (see [`replace_watched!`](@ref)), where they can be
embedded here; `nothing` otherwise.
"""
function watch_regrouped!(kb::KB)
    stored = scalar(kb, "SELECT value FROM kv WHERE key = 'watch_basis'")
    (ismissing(stored) || stored == watch_basis(kb.config)) && return nothing
    ismissing(scalar(kb, "SELECT 1 FROM watch WHERE taken IS NULL AND doc_id NOT IN (SELECT doc_id FROM papers) LIMIT 1")) && return nothing
    isempty(cannot_run(kb, "embed", String[])) || return nothing
    return start_watch(kb)
end

"""
    start_watch(kb) -> Job

Run [`watch!`](@ref) as a background job, or return the watch job already running.
"""
function start_watch(kb::KB)
    running = filter(j -> j.status == :running && j.name == "paper watch", list_jobs())
    isempty(running) || return first(running)
    # The papers it reads or records, and the watch's own page, change the site.
    return start_job("paper watch"; changes = changes_stamp(kb.config)) do job
        n = watch!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        # Every new paper is judged and taken in by its rating, and today gets its paper, where the judge can run here.
        judged, taken = 0, (; read = String[], recorded = String[])
        if isempty(cannot_run(kb, "classify", String[]))
            report!(job, "judging the new papers")
            judged = judge_watched!(kb)
            taken = take_watched!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
            ismissing(scalar(kb, "SELECT 1 FROM daily WHERE day = ?", (utc_today(),))) && start_daily(kb; automatic = true)
        end
        "$n new paper(s) placed by the watch; $judged judged; " *
        "$(length(taken.read)) read in full and $(length(taken.recorded)) recorded."
    end
end

"How long the watch waits out arXiv being too busy to answer, in seconds (see [`arxiv_get`](@ref))."
const WATCH_PATIENCE = 900

"How soon a watch check that failed is tried again, in seconds."
const WATCH_RETRY = 1800

"""
    start_watch!(kb) -> Union{Task,Nothing}

`zemi`'s timer: every `watch_hours`, a [`start_watch`](@ref) job, the first once that long has
passed since the last check, so restarting `zemi` does not check again early; a check that fails is
tried again after [`WATCH_RETRY`](@ref). Nothing when `watch_hours` is 0, or where papers cannot be
embedded.
"""
function start_watch!(kb::KB)
    c = kb.config
    (c.watch_hours > 0 && watch_sources_enabled(c)) || return nothing
    period = c.watch_hours * 3600
    return Threads.@spawn while !STOPPING[]
        try
            last = scalar(kb, "SELECT value FROM kv WHERE key = 'watch_checked_at'")
            since = ismissing(last) ? Inf : seconds_since(last)
            if since < period
                pause(max(60.0, period - since))
                continue
            end
            if !isempty(cannot_run(kb, "embed", String[]))
                @info "Paper watch unavailable here: papers cannot be embedded on this machine"
                pause(period)
                continue
            end
            # A check that fails leaves the time of the last one; it is tried again soon, not a period later.
            job = start_watch(kb)
            while job.finished === nothing && !STOPPING[]
                sleep(10)
            end
            job.status == :done || pause(min(WATCH_RETRY, period))
        catch e
            (e isa InterruptException || STOPPING[]) && break
            @warn "Paper watch failed; trying again later" exception = e
            pause(period)
        end
    end
end
