# Record sources: what brings records (see records.jl) in from other systems, registered with
# `record_source!` by Zemi (the upload source, upload_source.jl) and by the packages the config loads
# as plugins (see plugins.jl). A source is given only its run (see `SourceRun`): it hands records in,
# and Zemi writes them, labels them as the source's registration says and keeps the source's state,
# so everything a source made can be told apart and removed. A source that polls runs on a schedule
# in the serving processes, each run a job.

"The version of the interface sources are written for: a source registered for another is refused."
const PLUGIN_API = 1

"How much a source's run may do unless its registration says otherwise (see [`record_source!`](@ref))."
const DEFAULT_BUDGET = (; records = 500, figure_bytes = 200_000_000, seconds = 1800.0)

"The modes a source may run in: `zemi`, for one person, and `zemi --shared`."
const SOURCE_MODES = (:local, :shared)

"""
A source of records, as [`record_source!`](@ref) registered it: `every` in seconds (0 for one that
does not poll), `configured` whether it runs only where the config has its section, `summarized`
whether its records are summarized, `about` what its records are as readers and agents are told,
and `plugin` the package that registered it, empty for Zemi's own.
"""
struct RecordSource
    name::String
    label::String
    modes::Vector{Symbol}
    every::Float64
    poll::Union{Function,Nothing}
    accepts::Union{Function,Nothing}
    read::Union{Function,Nothing}
    budget::typeof(DEFAULT_BUDGET)
    configured::Bool
    summarized::Bool
    about::String
    plugin::String
end

"The sources, in the order they were registered. Registering one again replaces it."
const SOURCES = Ref(RecordSource[])
const SOURCES_LOCK = ReentrantLock()

"""
    record_source!(name; label, modes = (:local, :shared), every = nothing, poll = nothing,
                   accepts = nothing, read = nothing, budget = (;), configured = false,
                   summarized = true, about = RECORD_ABOUT, api) -> RecordSource

Register a source of records, or replace the one of that name. A source is code that reads another
system and hands Zemi what it finds; it is given only a run (see [`SourceRun`](@ref)), and Zemi
writes, labels and guards what it hands in.

- `name`: lower case letters, digits and dashes; its records' ids, its section of the config
  (`[sources.<name>]`) and its state are all under it
- `label`: how its records were made, as readers are told it ("Written up by a meeting service from
  its recordings"); every record it hands in carries it, whatever the record says
- `modes`: where it runs, `:local` (`zemi`) and `:shared` (`zemi --shared`)
- `poll(run)`, run every `every` (a period, or seconds): its scheduled work
- `accepts(path)` and `read(run, path)`: a file someone uploads that it knows how to read
- `configured`: it runs, and is listed among the sources, only where the config has its section
  (`[sources.<name>]`): one Zemi has that only some knowledge bases use
- `summarized`: its records are summarized as records are; `false`, they are read and embedded for
  searching without a model writing summaries of them (a person's many short notes, say)
- `about`: what its records are, as readers and agents are told wherever one is given them ("a
  person's own note"); by default, a record of the group's own work
- `budget`: the most a run may do, as `records` written, `figure_bytes` of their figures and
  `seconds` (see `DEFAULT_BUDGET`); a run that has spent it is stopped
- `api`: the version of this interface it was written for; one that is not [`PLUGIN_API`](@ref) is refused

A source polls, reads uploads, or both. Pass named functions: Revise applies edits to their methods
to the source as registered.
"""
function record_source!(name::AbstractString; label::AbstractString, modes = SOURCE_MODES, every = nothing,
                        poll::Union{Function,Nothing} = nothing, accepts::Union{Function,Nothing} = nothing,
                        read::Union{Function,Nothing} = nothing, budget = (;), configured::Bool = false,
                        summarized::Bool = true, about::AbstractString = RECORD_ABOUT, api::Integer)
    api == PLUGIN_API ||
        error("Source $name is written for Zemi's plugin interface $api, and this Zemi's is $PLUGIN_API: update the one or the other")
    name = record_source(name)
    label = String(strip(label))
    1 <= length(label) <= RECORD_LIMITS.label || error("Source $name needs a label of at most $(RECORD_LIMITS.label) characters")
    about = String(strip(about))
    1 <= length(about) <= RECORD_LIMITS.label || error("Source $name says what its records are in at most $(RECORD_LIMITS.label) characters")
    modes = unique(Symbol.(collect(modes)))
    !isempty(modes) && all(in(SOURCE_MODES), modes) || error("Source $name's modes are among $(join(SOURCE_MODES, " and ")): $modes")
    poll === nothing && read === nothing && error("Source $name neither polls nor reads uploads")
    (poll === nothing) == (every === nothing) || error("Source $name polls every so often: it needs both `poll` and `every`")
    (accepts === nothing) == (read === nothing) || error("Source $name reads uploads with both `accepts` and `read`")
    seconds = every === nothing ? 0.0 : every isa Real ? Float64(every) : Dates.toms(every) / 1000
    every === nothing || seconds > 0 || error("Source $name polls every so often: `every` is a positive period")
    extra = setdiff(keys(budget), keys(DEFAULT_BUDGET))
    isempty(extra) || error("Source $name's budget is $(join(keys(DEFAULT_BUDGET), ", ")), not $(join(extra, ", "))")
    b = (; (k => convert(fieldtype(typeof(DEFAULT_BUDGET), k), get(budget, k, DEFAULT_BUDGET[k])) for k in keys(DEFAULT_BUDGET))...)
    all(>(0), values(b)) || error("Source $name's budget is positive: $b")
    s = RecordSource(name, label, modes, seconds, poll, accepts, read, b, configured, summarized, about,
                     get(task_local_storage(), :zemi_plugin, ""))
    lock(SOURCES_LOCK) do
        i = findfirst(x -> x.name == name, SOURCES[])
        SOURCES[] = i === nothing ? [SOURCES[]; s] : [SOURCES[][1:i-1]; s; SOURCES[][i+1:end]]
    end
    return s
end

"The source registered as `name`, or `nothing`."
registered_source(name::AbstractString) = (i = findfirst(s -> s.name == name, SOURCES[]); i === nothing ? nothing : SOURCES[][i])

"The mode this process serves the knowledge base in, as a source's `modes` name it."
serving_mode() = SHARED_MODE[] ? :shared : :local

"Whether source `s` runs in this process's mode."
runs_here(s::RecordSource) = serving_mode() in s.modes

"Whether source `s` is one this knowledge base uses: any, but one `configured` only where the config has its section."
used_here(kb::KB, s::RecordSource) = !s.configured || haskey(kb.config.sources, s.name)

# ── A run ─────────────────────────────────────────────────────────────────────────────────────────

"""
    SourceRun

What a source's `poll` and `read` are given: the one way it reaches the knowledge base. Its fields
are Zemi's; a source uses these:

- `put!(run, record)`: hand in a record (a [`Record`](@ref), or the NamedTuple or Dict of its
  fields), returning its id. Zemi writes it with the source's name and label, counting it against
  the budget; an unchanged one is skipped, and one a person dropped is kept out (`nothing`). Once the run is stopped (its budget spent, cancelled,
  the service stopping) it throws, which ends the run cleanly
- `remove!(run, key)`: remove the record the source keeps as `key`, whose item is gone from it,
  returning its id (`nothing` for none)
- `rekey!(run, from, to)`: keep the record kept as `from` as `to` instead, for an item that moved in
  the source, so it keeps its id, links and the findings citing it
- `state(run)` and `save_state!(run, dict)`: a small JSON document kept for the source between runs,
  what it last saw, say
- `settings(run)`: its section of the config, `[sources.<name>]`, with the settings file's over it
- `secret(run, key)`: the secret a `file:` or `env:` reference among those settings names
- `progress(run, msg)`: say how the run is going, shown with its job
- `cancelled(run)`: whether it should stop
- `upload(run)`: for a file someone uploaded, `(; name, date, project, by)`: the file's name, the date
  given with it (or `nothing`), the project of the page it was uploaded on (or `""`) and who uploaded
  it; `nothing` for a scheduled run
"""
mutable struct SourceRun
    const kb::KB
    const source::RecordSource
    const job::Union{Job,Nothing}
    const started::Float64
    const upload::Union{NamedTuple,Nothing}
    const ids::Vector{String}
    added::Int
    changed::Int
    skipped::Int
    dropped::Int
    removed::Int
    figure_bytes::Int
    spent::String
end
SourceRun(kb::KB, s::RecordSource, job = nothing; upload = nothing) = SourceRun(kb, s, job, time(), upload, String[], 0, 0, 0, 0, 0, 0, "")

Base.show(io::IO, run::SourceRun) = print(io, "SourceRun(", run.source.name, ")")

"A run ended before its source finished: `why`, and whether because its budget was spent."
struct SourceStopped <: Exception
    why::String
    spent::Bool
end
Base.showerror(io::IO, e::SourceStopped) = print(io, "The run stopped: ", e.why)

"Why `run` should stop, or `\"\"` while it may go on (see [`cancelled`](@ref))."
function stop_reason(run::SourceRun)
    STOPPING[] && return "the service is stopping"
    run.job !== nothing && cancelled(run.job) && return "it was cancelled"
    isempty(run.spent) || return run.spent
    b = run.source.budget
    time() - run.started > b.seconds && (run.spent = "it took its $(round(Int, b.seconds)) seconds")
    return run.spent
end

cancelled(run::SourceRun) = !isempty(stop_reason(run))

function spend!(run::SourceRun, why::AbstractString)
    run.spent = why
    throw(SourceStopped(why, true))
end

function Base.put!(run::SourceRun, r)
    why = stop_reason(run)
    isempty(why) || throw(SourceStopped(why, !isempty(run.spent)))
    r = as_record(r)
    s, b = run.source, run.source.budget
    run.added + run.changed < b.records || spend!(run, "it wrote its $(b.records) records")
    bytes = sum(f -> length(f.image), r.figures; init = 0)
    run.figure_bytes + bytes <= b.figure_bytes || spend!(run, "its records' figures reached $(b.figure_bytes) bytes")
    # A record uploaded on a project's page is that project's too.
    if run.upload !== nothing && !isempty(run.upload.project) && !(run.upload.project in r.projects)
        r = Record(r.key, r.title, r.date, r.people, r.sections, r.figures, r.transcript, r.url, [r.projects; run.upload.project],
                   r.access, r.label)
    end
    new = ismissing(scalar(run.kb, "SELECT 1 FROM records WHERE source = ? AND key = ?", (s.name, r.key)))
    id, changed = try
        put_record!(run.kb, s.name, r; read = READ_PUT[], label = s.label, by = run.upload === nothing ? nothing : run.upload.by)
    catch e
        e isa DroppedError || rethrow()
        run.dropped += 1
        return nothing
    end
    push!(run.ids, id)
    if changed
        new ? (run.added += 1) : (run.changed += 1)
        run.figure_bytes += bytes
    else
        run.skipped += 1
    end
    return id
end

"The id of the record source `name` keeps as `key`, or `nothing`."
source_record(kb::KB, name::AbstractString, key::AbstractString) =
    (id = scalar(kb, "SELECT p.doc_id FROM records x JOIN papers p ON p.id = x.paper_id WHERE x.source = ? AND x.key = ?", (name, key));
     ismissing(id) ? nothing : String(id))

function remove!(run::SourceRun, key::AbstractString)
    why = stop_reason(run)
    isempty(why) || throw(SourceStopped(why, !isempty(run.spent)))
    id = source_record(run.kb, run.source.name, key)
    id === nothing && return nothing
    delete_record!(run.kb, id)
    run.removed += 1
    return id
end

function rekey!(run::SourceRun, from::AbstractString, to::AbstractString)
    name = run.source.name
    to = record_key(to)
    id = source_record(run.kb, name, from)
    id === nothing && error("Source $name keeps no record as $(repr(from))")
    source_record(run.kb, name, to) === nothing || error("Source $name keeps another record as $(repr(to)) already")
    execute!(run.kb, "UPDATE records SET key = ? WHERE source = ? AND key = ?", (to, name, from))
    return id
end

"Whether the records sources hand in are read as they arrive (tests turn it off; a sync reads them later)."
const READ_PUT = Ref(true)

"The most a source's state may hold, as JSON."
const SOURCE_STATE_MAX = 1_000_000

source_state_key(name) = "source_state:$name"

"The state source `run`'s source saved last (see [`save_state!`](@ref)), empty before it has."
state(run::SourceRun) = source_state(run.kb, run.source.name)
source_state(kb::KB, name::AbstractString) =
    Dict{String,Any}(JSON.parse(coalesce(scalar(kb, "SELECT value FROM kv WHERE key = ?", (source_state_key(name),)), "{}")))

"Keep `d` as the state of `run`'s source, given back by [`state`](@ref) in its next runs."
function save_state!(run::SourceRun, d::AbstractDict)
    text = JSON.json(d)
    length(text) <= SOURCE_STATE_MAX || error("Source $(run.source.name)'s state is more than $SOURCE_STATE_MAX bytes of JSON")
    execute!(run.kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (source_state_key(run.source.name), text))
    return nothing
end

"The settings of `run`'s source: its section of the config, `[sources.<name>]` (a copy)."
settings(run::SourceRun) = deepcopy(Dict{String,Any}(get(run.kb.config.sources, run.source.name, Dict{String,Any}())))

"""
    secret(run, key) -> String

The secret setting `key` of `run`'s source names: a `file:` reference (the file's first line) or an
`env:` one (the environment variable), so the secret itself is never written in the config.
"""
function secret(run::SourceRun, key::AbstractString)
    v = get(settings(run), key, nothing)
    who = "Source $(run.source.name)'s setting $key"
    v isa AbstractString && (startswith(v, "file:") || startswith(v, "env:")) ||
        error("$who is a file: or env: reference to a secret", v === nothing ? ", and is not set" : "")
    return resolve_key(v, who)
end

"Say how `run` is going: its job's message, or the log's for a run that is no job."
progress(run::SourceRun, msg::AbstractString) =
    run.job === nothing ? (@info "[$(run.source.name)] $msg"; nothing) : report!(run.job, "$(run.source.name): $msg")

"The file `run` reads, as it was uploaded (see [`SourceRun`](@ref)), or `nothing` for a scheduled run."
upload(run::SourceRun) = run.upload

# ── Status ────────────────────────────────────────────────────────────────────────────────────────

# Each source's status, kept across restarts in `kv`: its last run (`started`, `finished`,
# `outcome`, `added`, `changed`, `skipped`, `error`, `trigger`), whether it is `paused`, its failures
# in a row, and when it next runs (`next_at`, Unix seconds).
source_status_key(name) = "source_status:$name"
const SOURCE_STATUS_LOCK = ReentrantLock()

source_status(kb::KB, name::AbstractString) =
    Dict{String,Any}(JSON.parse(coalesce(scalar(kb, "SELECT value FROM kv WHERE key = ?", (source_status_key(name),)), "{}")))

"Change source `name`'s status: what `kw` says, the rest as it was. Returns the status."
function source_status!(kb::KB, name::AbstractString; kw...)
    lock(SOURCE_STATUS_LOCK) do
        st = merge(source_status(kb, name), Dict{String,Any}(String(k) => v for (k, v) in kw))
        execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (source_status_key(name), JSON.json(st)))
        return st
    end
end

"""
How long after its `failures`th failure in a row a source polling every `every` seconds is tried
again: a minute (or `every`, if shorter), doubling with each failure, up to `SOURCE_RETRY_CAP` (or
`every`, if longer).
"""
retry_wait(every::Real, failures::Integer) = min(min(every, 60.0) * 2.0^(failures - 1), max(every, SOURCE_RETRY_CAP))
const SOURCE_RETRY_CAP = 6 * 3600.0

# ── Running ───────────────────────────────────────────────────────────────────────────────────────

"The scheduled run of each source going on, by its name: one at a time each."
const SOURCE_RUNS = Dict{String,Job}()
const SOURCE_RUNS_LOCK = ReentrantLock()

source_running(name::AbstractString) = lock(() -> haskey(SOURCE_RUNS, name), SOURCE_RUNS_LOCK)

"""
    run_source!(kb, s, job = nothing; path = nothing, upload = nothing) -> SourceRun

Run source `s` once: its `poll`, or with `path`, its `read` of that file, uploaded as `upload` says.
Its status records the run; a scheduled one (`path` absent) also sets when it next runs: after
`every`, or after a failure, later each time (see [`retry_wait`](@ref)). A run stopped (see
[`SourceStopped`](@ref)) has done what it did; one that failed throws, once its status says so.
"""
function run_source!(kb::KB, s::RecordSource, job::Union{Job,Nothing} = nothing; path = nothing, upload = nothing)
    run = SourceRun(kb, s, job; upload)
    scheduled = path === nothing
    source_status!(kb, s.name; started = now_iso(), trigger = scheduled ? "scheduled" : "upload")
    outcome, why = "ok", ""
    try
        scheduled ? Base.invokelatest(s.poll, run) : Base.invokelatest(s.read, run, path)
        isempty(run.spent) || (outcome = "spent"; why = run.spent)
    catch e
        e isa SourceStopped || (outcome = "failed"; why = failure_message(e); rethrow())
        outcome, why = e.spent ? "spent" : "stopped", e.why
    finally
        run.dropped > 0 && @info "$(s.name): $(run.dropped) dropped $(run.dropped == 1 ? "item" : "items") kept out"
        failures = outcome == "failed" ? get(source_status(kb, s.name), "failures", 0) + 1 : 0
        source_status!(kb, s.name; finished = now_iso(), outcome, error = why, run.added, run.changed, run.skipped,
                       (scheduled ? (; failures, next_at = time() + (failures == 0 ? s.every : retry_wait(s.every, failures))) : (;))...)
    end
    return run
end

"What a run did, in a line: `3 added, 1 changed, 12 skipped, 2 removed, 1 dropped kept out`, and why it stopped if it did."
function run_summary(run::SourceRun)
    line = "$(run.added) added, $(run.changed) changed, $(run.skipped) skipped" * (run.removed > 0 ? ", $(run.removed) removed" : "") *
           (run.dropped > 0 ? ", $(run.dropped) dropped kept out" : "")
    return isempty(run.spent) ? line : "$line; stopped as $(run.spent)"
end

"""
    start_source_run(kb, s) -> Job

Run source `s`'s `poll` as a job (see [`run_source!`](@ref)), unless it is running already.
"""
function start_source_run(kb::KB, s::RecordSource)
    lock(SOURCE_RUNS_LOCK) do
        haskey(SOURCE_RUNS, s.name) && error("Source $(s.name) is running already")
        job = start_job("source $(s.name)"; changes = changes_stamp(kb.config)) do job
            try
                run_summary(run_source!(kb, s, job))
            finally
                lock(() -> get(SOURCE_RUNS, s.name, nothing) === job && delete!(SOURCE_RUNS, s.name), SOURCE_RUNS_LOCK)
            end
        end
        SOURCE_RUNS[s.name] = job
        return job
    end
end

"""
    due_sources!(kb; at = time()) -> Vector{Job}

Start a run of each source that polls, runs in this mode, is not paused or running and whose next
run is due at `at`; returns their jobs.
"""
function due_sources!(kb::KB; at::Real = time())
    jobs = Job[]
    for s in SOURCES[]
        (s.poll === nothing || !runs_here(s) || !used_here(kb, s) || source_running(s.name)) && continue
        st = source_status(kb, s.name)
        get(st, "paused", false) || get(st, "next_at", 0.0) > at || push!(jobs, start_source_run(kb, s))
    end
    return jobs
end

"""
    follow_sources(kb; tick = 1, stop = Ref(false))

Run the sources that poll, each when it is due (see [`due_sources!`](@ref)), checking every `tick`
seconds until the process is stopping (or `stop[]`), having first queued the records never read
(see [`queue_unread_records!`](@ref)). Only the serving processes do; a `zemi
<command>` never runs a source.
"""
function follow_sources(kb::KB; tick::Real = 1, stop::Ref{Bool} = Ref(false))
    queue_unread_records!(kb)
    return Threads.@spawn begin
        warned = false
        while !STOPPING[] && !stop[]
            try
                Base.invokelatest(due_sources!, kb)
                warned = false
            catch e
                STOPPING[] && break
                warned || @warn "Starting the record sources' runs failed; trying again" exception = e
                warned = true
            end
            pause(tick)
        end
    end
end

"Source `name`, registered, polling and running in this mode, or a refusal saying which it is not."
function polling_source(name::AbstractString)
    s = registered_source(name)
    s === nothing && not_found("No source $name is registered here")
    s.poll === nothing && error("Source $name does not poll: it reads only what is uploaded")
    runs_here(s) || error("Source $name runs only in $(join(s.modes, " and ")) mode")
    return s
end

"Run source `name` now, whether or not it is due or paused; its job."
run_source_now!(kb::KB, name::AbstractString) = start_source_run(kb, polling_source(name))

"Pause source `name`'s scheduled runs, or with `paused` false resume them; kept across restarts."
pause_source!(kb::KB, name::AbstractString, paused::Bool = true) = (polling_source(name); source_status!(kb, name; paused); nothing)

"""
    forget_source!(kb, name) -> Int

Remove everything source `name` made (see [`purge_source!`](@ref)) and the state it kept, returning
how many records it had. A source still registered that polls is paused, so its next run does not
bring them back before someone resumes it.
"""
function forget_source!(kb::KB, name::AbstractString)
    name = record_source(name)
    n = purge_source!(kb, name)
    # Its state, and any a source of Zemi's own keeps beside it (`source_state:<name>:<part>`).
    execute!(kb, "DELETE FROM kv WHERE key = ? OR key LIKE ?", (source_state_key(name), source_state_key(name) * ":%"))
    s = registered_source(name)
    source_status!(kb, name; purged = now_iso(), added = 0, changed = 0, skipped = 0,
                   (s !== nothing && s.poll !== nothing ? (; paused = true) : (;))...)
    return n
end

# ── What the Status page shows ────────────────────────────────────────────────────────────────────

"""
    sources_status(kb) -> Vector{Dict}

Every source the knowledge base knows of, those registered first: each one's registration (its
label, the plugin it came from, its modes and whether it runs here, whether it polls and how often,
whether it reads uploads), how many records it has, and its status (see `source_status!`): its last
run, whether it is running or paused, and when it next runs. A source whose records or status are
kept but that is not registered (its package not loaded) is listed as such.
"""
function sources_status(kb::KB)
    counts = Dict(String(r.source) => Int(r.n) for r in query(kb, "SELECT source, count(*) AS n FROM records GROUP BY source"))
    kept = [String(r.key)[length("source_status:")+1:end] for r in query(kb, "SELECT key FROM kv WHERE key LIKE 'source_status:%'")]
    names = unique([[s.name for s in SOURCES[] if used_here(kb, s)]; sort!(unique([collect(keys(counts)); kept]))])
    return map(names) do name
        s, st = registered_source(name), source_status(kb, name)
        polls = s !== nothing && s.poll !== nothing
        paused = get(st, "paused", false)
        next = polls && runs_here(s) && !paused ? iso(max(get(st, "next_at", 0.0), time())) : nothing
        Dict{String,Any}("name" => name, "registered" => s !== nothing, "plugin" => s === nothing ? "" : s.plugin,
             "label" => s === nothing ? "" : s.label, "modes" => s === nothing ? String[] : string.(s.modes),
             "here" => s !== nothing && runs_here(s), "polls" => polls, "every" => polls ? s.every : 0.0,
             "uploads" => s !== nothing && s.read !== nothing, "records" => get(counts, name, 0),
             "running" => source_running(name), "paused" => paused, "next" => next,
             (k => get(st, k, nothing) for k in ("started", "finished", "outcome", "trigger"))...,
             (k => get(st, k, 0) for k in ("added", "changed", "skipped", "failures"))..., "error" => get(st, "error", ""))
    end
end

# The sources, and what became of each plugin the config names (see `load_plugins!`).
route!(c -> Dict("sources" => sources_status(c.kb), "plugins" => PLUGINS[], "mode" => string(serving_mode())), "GET", "/api/sources";
       need = "paper.manage")
route!(c -> Dict("job" => run_source_now!(c.kb, c[:name]).id), "POST", "/api/sources/:name/run"; need = "paper.manage")
route!(c -> (pause_source!(c.kb, c[:name]); ok_json()), "POST", "/api/sources/:name/pause"; need = "paper.manage")
route!(c -> (pause_source!(c.kb, c[:name], false); ok_json()), "POST", "/api/sources/:name/resume"; need = "paper.manage")

# Remove every record a source made: `{"count": N}`, N the number of its records as the person was
# shown it. Another count is refused with the number there is, so what goes is what was confirmed.
route!("POST", "/api/sources/:name/purge"; need = "records.purge") do c
    name = record_source(c[:name])
    n = Int(scalar(c.kb, "SELECT count(*) FROM records WHERE source = ?", (name,)))
    get(json_body(c), "count", nothing) == n ||
        return json_response(Dict("error" => "Confirm removing $name's $n record(s) by sending their count", "count" => n); status = 409)
    Dict("removed" => forget_source!(c.kb, name))
end
