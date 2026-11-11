# Bringing the whole knowledge base up to date: finding every document whose reading is unfinished or
# out of date, and running the steps that are missing. The Status page, the `sync` tool and a
# notebook all use these.

"""
    SyncTask

One thing [`sync!`](@ref) would do: `action` is `:metadata` (fetch the arXiv record), `:ingest` (read
the document, or bring its reading up to date), `:embed` (embed a recorded paper's title and
abstract), `:classify`, or `:missing` (a codebase that can't be read here, which sync can only
report). `reason` says why, in a few words.
"""
struct SyncTask
    id::String
    title::String
    action::Symbol
    reason::String
end

"The reason given for a paper that is only recorded, not read."
const UNREAD = "not read yet"

"""
    sync_plan(kb; unread = false) -> Vector{SyncTask}

What is out of date, without changing anything. A document counts once its reading has started (its
PDF fetched, or it is an upload or a codebase): it needs ingesting when it was never parsed, was
parsed by an older parser, is a codebase whose files changed, lacks summaries or has summaries from
another model or prompt, or has embeddings that don't match its current text in a layer ingesting
keeps (trial layers are left alone). A read
document with no classification, or one by another model than the configured summarizer, needs classifying. A paper only recorded (shared, not yet read in full)
needs its title and abstract embedding, for the landscape; with `unread` it is ingested instead.
"""
function sync_plan(kb::KB; unread::Bool = false)
    tasks = SyncTask[]
    docs = query(kb, """
        SELECT p.id AS pid, p.doc_id AS id, coalesce(p.title, p.doc_id) AS title, p.source_path, p.metadata_at,
               x.file_sha, x.parser_version,
               EXISTS (SELECT 1 FROM files f WHERE f.paper_id = p.id) AS fetched,
               (SELECT classifier FROM classifications c WHERE c.paper_id = p.id) AS classifier,
               EXISTS (SELECT 1 FROM dataset_docs dd WHERE dd.doc_id = p.doc_id) AS from_dataset
        FROM papers p LEFT JOIN parses x ON x.paper_id = p.id ORDER BY p.id""")
    consumer = kb.config.dataset.role == :consume
    for d in docs
        consumer && d.from_dataset == 1 && continue          # the dataset keeps these up to date
        kind = document_kind(d.id)
        kind === nothing && continue                         # of no kind the knowledge base reads
        task(action, reason) = push!(tasks, SyncTask(d.id, d.title, action, reason))
        arxiv = is_arxiv_id(d.id)
        arxiv && ismissing(d.metadata_at) && task(:metadata, "no arXiv record yet")
        if arxiv && d.fetched != 1 && ismissing(d.file_sha)
            if unread
                task(:ingest, UNREAD)
            elseif !ismissing(d.metadata_at) && any(l -> !isempty(embedding_diff(kb, l, d.id).todo), record_layers(kb.config))
                task(:embed, "title and abstract not embedded")
            end
            continue
        end
        if kind.tree && !isdir(codebase_dir(kb, d.id))
            task(:missing, codebase_problem(kb, d.id))
            continue
        end
        reasons = reading_out_of_date(kb, d)
        isempty(reasons) || task(:ingest, join(reasons, "; "))
        (ismissing(d.file_sha) || !kind.classified) && continue
        if ismissing(d.classifier)
            task(:classify, "not classified")
        elseif d.classifier != kb.config.summarizer
            task(:classify, "classified by $(d.classifier)")
        end
    end
    return tasks
end

function reading_out_of_date(kb::KB, d)
    ismissing(d.file_sha) && return ["not parsed"]
    reasons = String[]
    if is_kind(k -> k.tree, d.id)
        tree_sha(codebase_dir(kb, d.id)) == d.file_sha || push!(reasons, "files changed")
    end
    if is_record(d.id)
        r = record_row(kb, d.id)
        stored = stored_reading_sha(kb, d.id)
        stored === nothing || stored == d.file_sha || push!(reasons, "its source changed it")
    end
    if is_resource(d.id)
        r = resource_row(kb, d.id)
        r === nothing || r.content_sha == d.file_sha || push!(reasons, "its source changed it")
    end
    d.parser_version == PARSER_VERSION || push!(reasons, "parsed by an older version of the reader")
    layers = document_layers(kb, d.id, ingest_layers(kb.config))
    for s in unique(summarizer_for(kb.config, l, d.id) for l in layers if !isempty(l.source))
        name = s.name
        rows = query(kb, "SELECT unit_key, model, prompt_version FROM summaries WHERE paper_id = ? AND summarizer = ?", (d.pid, name))
        if !any(r -> startswith(r.unit_key, "p:"), rows)
            push!(reasons, "not summarized by $name")
        elseif any(r -> r.model != s.model || r.prompt_version != prompt_version(s), rows)
            push!(reasons, "summaries by $name from another model or prompt")
        end
    end
    stale = [l.name for l in layers if (e = embedding_diff(kb, l, d.id); !isempty(e.todo) || !isempty(e.stale))]
    isempty(stale) || push!(reasons, "embeddings out of date in $(join(stale, ", "))")
    return reasons
end

"""
    sync!(kb; unread = false, arxiv = true, classify = true, plan = nothing, pull, publish = false,
          resummarize = false, progress, cancelled) -> NamedTuple

Carry out a [`sync_plan`](@ref): fetch missing arXiv records, embed the titles and abstracts of
papers only recorded, ingest every document it lists, and with `classify`, alongside the reading, classify documents that are read but not classified by the configured summarizer (including those
just read). With `arxiv`,
arXiv is also asked whether papers read in full (a consumer's own, not those it imported) have a
newer version, each as often as its age warrants (see [`version_check_due`](@ref)), and those are
read again. What this machine cannot run (see
[`cannot_run`](@ref)) is skipped and reported as failed.
Documents whose agent summaries reading would replace are read only up to [`RESUMMARIZE_LIMIT`](@ref)
of them, unless `resummarize` (see [`resummarizes`](@ref)); past it they are left and reported.
With `pull` (the default for a member of a dataset) the dataset is imported first, and the plan made
after it. Unless this is a consumer, the landscape is brought up to date (see
[`landscape!`](@ref)); with `publish`, the knowledge base is published at the end (see dataset.jl).
Each step is resumable, so a sync that fails or is cancelled can simply be run again. Returns
`(; metadata, embedded, newer, ingested, classified, failed, pulled, landscape, published, missing)`:
the number of records fetched and of abstracts embedded, the papers with new versions, [`ingest!`](@ref)'s results, the ids classified,
`id => error` pairs for failures outside ingesting (and for work skipped here), what [`pull!`](@ref),
[`landscape!`](@ref) and [`publish!`](@ref) returned (or `nothing`), and the tasks sync could not act on.
"""
function sync!(kb::KB; unread::Bool = false, arxiv::Bool = true, classify::Bool = true, plan = nothing,
               pull::Bool = kb.config.dataset.role != :none, publish::Bool = false, resummarize::Bool = false,
               progress = msg -> nothing, cancelled = () -> false)
    failed = Pair{String,String}[]
    pulled = nothing
    if pull
        progress("Importing the published dataset")
        try
            pulled = pull!(kb; progress, cancelled)
        catch e
            e isa InterruptException && rethrow()
            push!(failed, "dataset" => failure_message(e))
        end
    end
    plan === nothing && (plan = sync_plan(kb; unread))
    ids(action) = unique([t.id for t in plan if t.action == action])
    metadata = 0
    if !isempty(ids(:metadata))
        progress("Fetching arXiv records for $(length(ids(:metadata))) paper(s)")
        metadata = try
            refresh_metadata!(kb, ids(:metadata))
        catch e
            push!(failed, "arXiv records" => failure_message(e)); 0
        end
    end
    # Uploads not yet matched to their published record, so a title misread from a PDF corrects itself.
    if !cancelled()
        try
            heal_uploads!(kb; progress)
        catch e
            e isa InterruptException && rethrow()
            push!(failed, "uploads' published records" => failure_message(e))
        end
    end
    embedded = 0
    records = ids(:embed)
    if !isempty(records) && !cancelled()
        blocked = cannot_run(kb, "embed", records)
        if !isempty(blocked)
            push!(failed, "embedding $(length(records)) abstract(s)" => join(blocked, "; "))
        else
            embedded = try
                embed_records!(kb, records; progress, cancelled)
            catch e
                e isa InterruptException && rethrow()
                push!(failed, "abstracts" => failure_message(e)); 0
            end
        end
    end
    newer = String[]
    if arxiv && !cancelled()
        # A consumer's imported papers are the publisher's to read again, and a paper is asked about
        # only when it is due (see `version_check_due`).
        arxiv_read = [r.id for r in query(kb, """
            SELECT p.doc_id AS id, p.published, p.updated, p.metadata_at FROM papers p JOIN parses x ON x.paper_id = p.id
            WHERE ? = 0 OR p.doc_id NOT IN (SELECT doc_id FROM dataset_docs)""",
            (Int(kb.config.dataset.role == :consume),)) if is_arxiv_id(r.id) && version_check_due(coalesce(r.updated, r.published), r.metadata_at)]
        before = Dict(id => paper_row(kb, id).version for id in arxiv_read)
        if !isempty(arxiv_read)
            progress("Asking arXiv for newer versions of $(length(arxiv_read)) paper(s)")
            try
                refresh_metadata!(kb, arxiv_read; force = true)
                newer = [id for id in arxiv_read if !isequal(paper_row(kb, id).version, before[id])]
            catch e
                push!(failed, "arXiv versions" => failure_message(e))
            end
        end
    end
    todo = unique([ids(:ingest); newer])
    # An agent's summaries are a long and costly read, so a sync replaces them for a few documents at
    # most (a paper revised on arXiv, an upload's text changed). More would mean a changed model or
    # prompt reading everything again: those documents wait until a sync is asked to `resummarize`.
    if !resummarize
        redo = filter(id -> resummarizes(kb, id; newer = id in newer), todo)
        if length(redo) > RESUMMARIZE_LIMIT
            push!(failed, "summarizing $(length(redo)) document(s) again" =>
                "their agent summaries would be replaced (a changed model, prompt or text); sync with resummarize to replace them")
            todo = setdiff(todo, redo)
        end
    end
    # What this machine cannot read or classify is left for one that can, and reported.
    blocked = cannot_run(kb, "ingest", todo)
    if !isempty(todo) && !isempty(blocked)
        push!(failed, "reading $(length(todo)) document(s)" => join(blocked, "; "))
        todo = String[]
    end
    # Classifying goes alongside reading: the documents that need it are queued (those already read
    # first, then each as soon as it is read) and classified four at a time, since an agent
    # classifier takes a minute or so a document. A long sync so classifies as it goes, and stopping
    # it loses only the classifications under way.
    classified, skipped = String[], String[]
    queue = Channel{String}(Inf)
    blocked = cannot_run(kb, "classify", String[])
    function enqueue(id)
        classify || return
        isequal(scalar(kb, "SELECT classifier FROM classifications WHERE paper_id = ?", (paper_id(kb, id),)),
                kb.config.summarizer) && return
        isempty(blocked) ? put!(queue, id) : push!(skipped, id)
    end
    classifier = @async asyncmap(queue; ntasks = 4) do id
        cancelled() && return
        try
            classify!(kb, id)
            push!(classified, id)
            progress("classified $id ($(length(classified)) so far)")
        catch e
            e isa InterruptException && rethrow()
            push!(failed, id => failure_message(e))
        end
    end
    ingested = try
        foreach(enqueue, setdiff(ids(:classify), todo))           # (those to be read wait until they are)
        isempty(todo) || cancelled() || summarize_ahead!(kb, todo; progress, cancelled)
        isempty(todo) || cancelled() ? [] : ingest!(kb, todo; classify = false, progress, cancelled, on_read = enqueue)
    finally
        close(queue)
        wait(classifier)
    end
    isempty(skipped) || push!(failed, "classifying $(length(skipped)) document(s)" => join(blocked, "; "))
    # The landscape follows what changed. A consumer's comes with the dataset.
    landscape = nothing
    if kb.config.dataset.role != :consume && !cancelled()
        blocked = cannot_run(kb, "landscape", String[])
        if isempty(blocked)
            try
                landscape = landscape!(kb; progress, cancelled)
            catch e
                e isa InterruptException && rethrow()
                push!(failed, "landscape" => failure_message(e))
            end
        end
    end
    published = nothing
    # Not after a failed import: this knowledge base may not hold what its stream does.
    pull && pulled === nothing && publish && (push!(failed, "publishing" => "not published, as the dataset could not be imported"); publish = false)
    if publish && !cancelled()
        progress("Publishing the dataset")
        try
            published = publish!(kb; progress, cancelled)
        catch e
            e isa InterruptException && rethrow()
            push!(failed, "publishing" => failure_message(e))
        end
    end
    return (; metadata, embedded, newer, ingested, classified, failed, pulled, landscape, published,
              missing = [t for t in plan if t.action == :missing])
end

"How many documents' agent summaries a sync replaces without being asked to `resummarize`."
const RESUMMARIZE_LIMIT = 10

"The agent summarizers that write summaries of document `id`."
agent_summarizers(kb::KB, id::AbstractString) =
    unique(s for s in (summarizer_for(kb.config, l, id) for l in document_layers(kb, id, ingest_layers(kb.config)) if !isempty(l.source))
           if s.kind == :agent)

"""
    resummarizes(kb, id; newer = false) -> Bool

Whether reading document `id` would replace summaries an agent has written of it: they are out of
date for its text, model or prompt, or, with `newer`, it is to be read again from a newer version.
"""
function resummarizes(kb::KB, id::AbstractString; newer::Bool = false)
    is_kind(k -> k.tree, id) && return false
    return any(s -> (state = agent_summaries(kb, s, id); state == :stale || (newer && state != :none)), agent_summarizers(kb, id))
end

"""
    version_check_due(latest, checked; now = now(UTC)) -> Bool

Whether to ask arXiv again whether a paper read in full has a newer version, given the date of its
latest version and when its record was last fetched. Papers are revised mostly soon after they
appear, so the wait between checks is a quarter of the time since the latest version: a week at
least, half a year at most.
"""
function version_check_due(latest, checked; now::DateTime = Dates.now(UTC))
    when(s) = ismissing(s) ? nothing : tryparse(DateTime, first(replace(string(s), "Z" => ""), 19))
    last_check = when(checked)
    last_check === nothing && return true
    since = when(latest)
    age = since === nothing ? Day(365) : Day(max(Dates.value(Date(now) - Date(since)), 0))
    wait = clamp(Day(Dates.value(age) ÷ 4), Day(7), Day(182))
    return now - last_check >= wait
end

"""
    summarize_ahead!(kb, ids; ntasks = 4, progress, cancelled)

Have agent summarizers summarize the parsed documents among `ids` that they have not summarized for
their current text, `ntasks` papers at a time. An agent takes minutes a paper and ingesting goes one
paper at a time, so this runs first; ingesting then finds those summaries current. A failure here is
left for ingesting to meet again and report.
"""
function summarize_ahead!(kb::KB, ids::AbstractVector{<:AbstractString}; ntasks::Integer = 4,
                          progress = msg -> nothing, cancelled = () -> false)
    parsed = Set(r.id for r in query(kb, "SELECT p.doc_id AS id FROM papers p JOIN parses x ON x.paper_id = p.id"))
    work = [(s, id) for id in ids if id in parsed for s in agent_summarizers(kb, id)]
    isempty(work) && return
    done = Threads.Atomic{Int}(0)
    asyncmap(work; ntasks) do (s, id)
        cancelled() && return
        try
            lock(() -> summarize_paper!(kb, s, id), paper_lock(id))
        catch e
            e isa InterruptException && rethrow()
            @warn "Agent summarizing failed; ingesting will try again" id summarizer = s.name exception = e
        end
        progress("[$(Threads.atomic_add!(done, 1) + 1)/$(length(work))] $(s.name) summarized $id")
    end
    return nothing
end

"""
    start_sync(kb; unread = false) -> Job

Run [`sync!`](@ref) as a background job working on the planned documents, or return the sync job
already running: two at once would only do the same work twice.
"""
function start_sync(kb::KB; unread::Bool = false, publish::Bool = false, resummarize::Bool = false)
    running = running_sync()
    running === nothing || return running
    # A consumer's plan depends on what the import brings, so it is made after importing.
    plan = kb.config.dataset.role == :consume ? nothing : sync_plan(kb; unread)
    n = plan === nothing ? "" : ": $(length(unique(t.id for t in plan if t.action != :missing))) document(s)"
    return start_job("sync$n"; ids = plan === nothing ? String[] : unique(t.id for t in plan), changes = changes_stamp(kb.config)) do job
        format_sync(sync!(kb; unread, plan, publish, resummarize, progress = m -> report!(job, m), cancelled = () -> cancelled(job)))
    end
end

"The sync job that is running, if any."
running_sync() = (jobs = filter(j -> j.status == :running && startswith(j.name, "sync"), list_jobs());
                  isempty(jobs) ? nothing : first(jobs))

# ── Nightly ingest ────────────────────────────────────────────────────────────────────────────────
# A shared service reads its linked codebases again each night, so their summaries, pages and search
# follow the code without anyone asking. Only codebases whose files changed are read, and of those
# only the changed files are summarized and embedded.

"""
    nightly_due(at, tz, t) -> DateTime

The latest time of night `at` (a `Time` in zone `tz`) at or before `t`, both in UTC. On a night the
clocks skip that time it is taken an hour later, and on one they pass it twice, the first time.
"""
function nightly_due(at::Time, tz::TimeZones.TimeZone, t::DateTime)
    function utc(day)
        here = DateTime(day, at)
        z = try
            TimeZones.ZonedDateTime(here, tz)
        catch e
            e isa TimeZones.NonExistentTimeError ? TimeZones.ZonedDateTime(here + Hour(1), tz) :
            e isa TimeZones.AmbiguousTimeError ? TimeZones.ZonedDateTime(here, tz, 1) : rethrow()
        end
        return DateTime(z, UTC)
    end
    today = Date(TimeZones.ZonedDateTime(t, tz; from_utc = true))
    due = utc(today)
    return due <= t ? due : utc(today - Day(1))
end

"""
    changed_codebases(kb) -> Vector{String}

The codebases linked to a project whose files, as they are here, differ from their last reading (or
that were never read).
"""
function changed_codebases(kb::KB)
    rows = query(kb, """
        SELECT DISTINCT d.doc_id AS id, x.file_sha FROM projects p JOIN papers d ON d.id = p.codebase_id
        LEFT JOIN parses x ON x.paper_id = d.id ORDER BY d.doc_id""")
    return [String(r.id) for r in rows
            if (dir = codebase_dir(kb, r.id); !isempty(dir) && isdir(dir) && (ismissing(r.file_sha) || tree_sha(dir) != r.file_sha))]
end

"""
    nightly_ingest!(kb; now = now(UTC)) -> Union{Job,Nothing}

The nightly pass, which [`follow_commits`](@ref) asks for on a shared service once it has fetched the
repositories: when the time of `[shared] nightly_ingest` (in `[shared] timezone`) has come since
the last pass, ingest each [changed codebase](@ref changed_codebases) as one job. A night missed
while the service was down is caught up when it next runs. A codebase another job is working on is
left to it, and the next night sees what that job did not read. Returns the job, or `nothing` when
no pass is due or nothing changed.
"""
function nightly_ingest!(kb::KB; now::DateTime = Dates.now(UTC))
    sh = kb.config.shared
    at = nightly_time(sh)
    at === nothing && return nothing
    due = nightly_due(at, time_zone(sh), now)
    last = scalar(kb, "SELECT value FROM kv WHERE key = 'nightly_ingest_at'")
    !ismissing(last) && parse_iso(last) >= due && return nothing
    # A pass is counted when it starts: one that fails is not retried until the next night.
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('nightly_ingest_at', ?)", (iso(now),))
    busy = Set(id for j in list_jobs() if j.status == :running for id in j.ids)
    ids = filter(!in(busy), changed_codebases(kb))
    isempty(ids) && return nothing
    blocked = cannot_run(kb, "ingest", ids)
    isempty(blocked) || (@warn "The nightly ingest cannot run here" codebases = ids blocked; return nothing)
    return start_job("nightly ingest: $(length(ids)) codebase(s)"; ids, changes = changes_stamp(kb.config)) do job
        ingest!(kb, ids; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
    end
end

"The plan as a list for people: one line per document and action, with the reason."
function format_sync_plan(plan::AbstractVector{SyncTask})
    isempty(plan) && return "Everything is up to date."
    verbs = Dict(:metadata => "fetch record", :embed => "embed abstract", :ingest => "read", :classify => "classify",
                 :missing => "cannot sync")
    return join(("$(t.id)  $(verbs[t.action]): $(t.reason)  ($(first(t.title, 70)))" for t in plan), "\n")
end

"What a sync did, for people."
function format_sync(r)
    io = IOBuffer()
    r.pulled === nothing || println(io, format_pull(r.pulled))
    r.metadata > 0 && println(io, "Fetched $(r.metadata) arXiv record(s).")
    r.embedded > 0 && println(io, "Embedded $(r.embedded) title(s) and abstract(s).")
    isempty(r.newer) || println(io, "Newer versions on arXiv: ", join(r.newer, ", "))
    isempty(r.ingested) || print(io, format_ingest(r.ingested))
    isempty(r.classified) || println(io, "Classified: ", join(r.classified, ", "))
    for (id, err) in r.failed
        println(io, "✗ $id: ", first(err, 500))
    end
    for t in r.missing
        println(io, "⚠ $(t.id): ", t.reason)
    end
    r.landscape === nothing || !r.landscape.changed ||
        println(io, "Mapped $(length(r.landscape.data["papers"])) papers into $(length(r.landscape.data["clusters"])) clusters.")
    r.published === nothing || println(io, format_publish(r.published))
    text = String(take!(io))
    return isempty(text) ? "Everything was up to date." : text
end
