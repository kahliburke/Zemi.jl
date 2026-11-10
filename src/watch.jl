# Watching arXiv for new papers the group would want: recent submissions in the watched categories,
# each placed against the focus areas and the library as the landscape places papers, and kept with
# the library papers nearest it, so a reader sees why it was picked.

"""
    watch!(kb; list = list_new_papers, now = now(UTC), progress, cancelled) -> Int

Ask arXiv for the new papers in each of the config's `watch_categories` (`list(category, since,
config)`, by default from OAI-PMH, see [`list_new_papers`](@ref)), and place those posted within
`watch_days` that are neither in the knowledge base nor already watched: embedded by title
and abstract in the landscape layer (see [`landscape_layer`](@ref)), each is scored by its nearest
focus area and by its nearest paper of the library, its score the mean of the two. They are kept in
the `watch` table, and entries older than four times `watch_days` are let go. Returns how many new
papers were placed.
"""
function watch!(kb::KB; list = (cat, since, c) -> list_new_papers(cat, since, c; patience = WATCH_PATIENCE), now::DateTime = Dates.now(UTC),
                progress = msg -> nothing, cancelled = () -> false)
    c = kb.config
    l = landscape_layer(c)
    since = Date(now) - Day(c.watch_days)
    execute!(kb, "DELETE FROM watch WHERE published < ?", (string(Date(now) - Day(4 * c.watch_days)),))
    seen = Set{String}(r.id for r in query(kb, "SELECT doc_id AS id FROM papers UNION SELECT doc_id FROM watch"))
    found = []
    for cat in c.watch_categories
        cancelled() && return 0
        progress("asking arXiv for new papers in $cat")
        for m in list(cat, since, c)
            (m.doc_id in seen || isempty(m.published) || Date(m.published) < since) && continue
            push!(seen, m.doc_id)
            push!(found, m)
        end
    end
    # Asked of every category: checked, whether or not there was anything new.
    checked() = execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('watch_checked_at', ?)", (now_iso(),))
    isempty(found) && (checked(); return 0)
    progress("placing $(length(found)) new papers against the focus areas and the library")
    prep(text) = first(l.doc_prefix * text, l.max_chars)
    vectors = reduce(vcat, (embed(c, l, [prep("$(m.title)\n\n$(m.abstract)") for m in batch])
                            for batch in Iterators.partition(found, 32)))
    focus = c.group.focus_areas
    areas = isempty(focus) ? nothing : unit_columns(reduce(hcat, [Float64.(query_vector(c, l, f.description)) for f in focus]))
    coll = collection_name(c, l)
    # Placed first, then written in one short transaction: the searches are not made holding the lock.
    placed = map(zip(found, vectors)) do (m, v)
        u = Float64.(v) ./ max(norm(v), eps())
        near = [(id = String(split(h.key, ':'; limit = 2)[2]), score = round(h.score; digits = 4))
                for h in vector_search(coll, u; limit = 3)]
        library = isempty(near) ? 0.0 : first(near).score
        # Without focus areas a paper is placed by the library alone.
        area, fit = if areas === nothing
            missing, missing
        else
            f = areas' * u
            a = argmax(f)
            focus[a].name, round(f[a]; digits = 4)
        end
        score = round(fit === missing ? library : (fit + library) / 2; digits = 4)
        (; m, near, area, fit, score)
    end
    transaction(kb) do
        for (; m, near, area, fit, score) in placed
            execute!(kb, """INSERT OR REPLACE INTO watch (doc_id, title, authors, abstract, published, category,
                                score, area, area_score, nearest, found_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (m.doc_id, m.title, JSON.json(m.authors), m.abstract, m.published, m.primary_category,
                 score, area, fit, JSON.json(near), now_iso()))
        end
    end
    checked()
    return length(found)
end

"""
    take_watched!(kb; progress, cancelled, read_in_full, record) -> (; read, recorded)

Take the judged watched papers into the knowledge base by their rating: those rated at least
`watch_read_from` read in full (see [`ingest!`](@ref)), those rated at least `watch_record_from`
recorded (the arXiv record fetched, the title and abstract embedded, see [`embed_records!`](@ref)).
Each arrives as "added from the arXiv watch", with its rating and the judge's sentence. Where papers
cannot be read here they are recorded instead. Returns the ids taken each way. `read_in_full(ids)`
and `record(ids)` do the reading and recording (stand-ins in tests, which reach no arXiv).
"""
function take_watched!(kb::KB; progress = msg -> nothing, cancelled = () -> false,
                       read_in_full = ids -> ingest!(kb, ids; progress, cancelled, source = "watch"),
                       record = ids -> (refresh_metadata!(kb, ids);
                                        isempty(cannot_run(kb, "embed", ids)) && embed_records!(kb, ids; progress, cancelled)))
    c = kb.config
    rows = query(kb, """SELECT doc_id AS id, relevance, coalesce(reason, '') AS reason FROM watch
                        WHERE relevance IS NOT NULL AND taken IS NULL AND doc_id NOT IN (SELECT doc_id FROM papers)
                          AND doc_id NOT IN (SELECT doc_id FROM dropped WHERE restored_at IS NULL)
                        ORDER BY relevance DESC, score DESC""")
    read = [String(r.id) for r in rows if r.relevance >= c.watch_read_from]
    recorded = [String(r.id) for r in rows if c.watch_record_from <= r.relevance < c.watch_read_from]
    if !isempty(read) && !isempty(cannot_run(kb, "ingest", read))
        recorded, read = [read; recorded], String[]
    end
    why = Dict(String(r.id) => "$(RELEVANCE[r.relevance+1]): $(r.reason)" for r in rows)
    function arrived!(ids, how)
        add_papers!(kb, ids; source = "watch")
        transaction(kb) do
            for id in ids
                execute!(kb, "UPDATE mentions SET message = ? WHERE paper_id = ? AND source = 'watch'", (why[id], paper_id(kb, id)))
                execute!(kb, "UPDATE watch SET taken = ?, taken_at = ? WHERE doc_id = ?", (how, now_iso(), id))
            end
        end
    end
    if !isempty(recorded)
        progress("recording $(length(recorded)) new paper(s)")
        arrived!(recorded, "recorded")
        record(recorded)
    end
    if !isempty(read) && !cancelled()
        progress("reading $(length(read)) new paper(s) in full")
        arrived!(read, "read")
        read_in_full(read)
    end
    return (; read, recorded)
end

"""
    watch_taken(kb) -> Vector{NamedTuple}

The watched papers taken into the knowledge base and still in it, latest first: `(; id, title,
relevance, reason, taken, taken_at, read)`, `taken` how ("read" or "recorded") and `read` whether it
is read in full now.
"""
watch_taken(kb::KB) =
    [(; id = String(r.id), title = String(coalesce(r.title, r.id)), relevance = Int(r.relevance), reason = coalesce(r.reason, ""),
        taken = String(r.taken), taken_at = String(r.taken_at), read = r.read == 1)
     for r in query(kb, """SELECT w.doc_id AS id, coalesce(p.title, w.title) AS title, w.relevance, w.reason, w.taken, w.taken_at,
                                  EXISTS (SELECT 1 FROM parses x WHERE x.paper_id = p.id) AS read
                           FROM watch w JOIN papers p ON p.doc_id = w.doc_id WHERE w.taken IS NOT NULL
                           ORDER BY w.taken_at DESC, w.relevance DESC""")]

"The watched papers taken in, as the New on arXiv page lists them (see [`watch_taken`](@ref))."
watch_taken_json(kb::KB) = [Dict("id" => t.id, "slug" => page_slug(t.id), "title" => t.title, "relevance" => t.relevance,
                                 "reason" => t.reason, "taken" => t.taken, "taken_at" => t.taken_at, "read" => t.read)
                            for t in watch_taken(kb)]

"""
    watched(kb) -> Vector{NamedTuple}

The watched papers not in the knowledge base, best placed first: `(; id, title, authors, abstract,
published, category, score, area, area_score, nearest, relevance, reason)`, `nearest` the library
papers nearest each (`(; id, title, score)`), `relevance` the judge's 0–3 (`missing` until judged).
"""
function watched(kb::KB)
    rows = query(kb, """SELECT * FROM watch WHERE doc_id NOT IN (SELECT doc_id FROM papers) ORDER BY score DESC""")
    titles = Dict(r.id => coalesce(r.title, r.id) for r in query(kb, "SELECT doc_id AS id, title FROM papers"))
    return map(rows) do r
        near = [(id = String(n["id"]), title = get(titles, n["id"], n["id"]), score = Float64(n["score"]))
                for n in JSON.parse(r.nearest)]
        (; id = r.doc_id, r.title, authors = json_list(r.authors), r.abstract, r.published, r.category,
           r.score, r.area, r.area_score, nearest = near, relevance = r.relevance, reason = coalesce(r.reason, ""))
    end
end

"The watched papers as the site's list shows them (see [`watched`](@ref))."
watch_json(kb::KB) = [Dict("id" => w.id, "title" => w.title, "authors" => first(w.authors, 6), "abstract" => w.abstract,
                           "published" => w.published, "category" => w.category, "score" => w.score, "area" => w.area,
                           "area_score" => w.area_score, "relevance" => coalesce(w.relevance, nothing), "reason" => w.reason,
                           "nearest" => [Dict("id" => n.id, "slug" => page_slug(n.id), "title" => n.title, "score" => n.score)
                                         for n in w.nearest])
                      for w in watched(kb)]

"""
    start_watch(kb) -> Job

Run [`watch!`](@ref) as a background job, or return the watch job already running.
"""
function start_watch(kb::KB)
    running = filter(j -> j.status == :running && j.name == "watch arXiv", list_jobs())
    isempty(running) || return first(running)
    # The papers it reads or records, and the watch's own page, change the site.
    return start_job("watch arXiv"; changes = changes_stamp(kb.config)) do job
        n = watch!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        # Every new paper is judged and taken in by its rating, and today gets its paper, where the judge can run here.
        judged, taken = 0, (; read = String[], recorded = String[])
        if isempty(cannot_run(kb, "classify", String[]))
            report!(job, "judging the new papers")
            judged = judge_watched!(kb)
            taken = take_watched!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
            ismissing(scalar(kb, "SELECT 1 FROM daily WHERE day = ?", (utc_today(),))) && start_daily(kb)
        end
        "$n new paper(s) placed from $(join(kb.config.watch_categories, ", ")); $judged judged; " *
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
    (c.watch_hours > 0 && !isempty(c.watch_categories)) || return nothing
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
                @info "Not watching arXiv here: papers cannot be embedded on this machine"
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
            @warn "Watching arXiv failed; trying again later" exception = e
            pause(period)
        end
    end
end
