"""
    Job

Long-running work (ingesting many papers) run on its own task. `message` is the latest progress
line; `cancel` is checked between steps; `ids` are the documents it works on, if any. Jobs live in memory and are lost on restart; the work
itself is resumable, since every ingest step skips what is already done.
"""
mutable struct Job
    id::String
    name::String
    status::Symbol
    message::String
    started::DateTime
    finished::Union{DateTime,Nothing}
    result::Any
    error::Union{String,Nothing}
    cancel::Threads.Atomic{Bool}
    ids::Vector{String}
    done::Base.Event
end

"Wait until `job` has ended, however it ends."
Base.wait(job::Job) = (wait(job.done); job)

"""
Whether the process is stopping: the loops that run in the background (the arXiv watch, following
the dataset, closing idle tutors) end quietly rather than report the knowledge base closing under them.
"""
const STOPPING = Ref(false)

"Wait `seconds`, or until the process is stopping (see [`STOPPING`](@ref)), whichever comes first."
function pause(seconds::Real)
    until = time() + seconds
    while !STOPPING[] && time() < until
        sleep(min(5.0, until - time()))
    end
end

"""
    every!(f, what; seconds) -> Task

Run `f()` now and every `seconds` after, on a thread of its own, until the process is stopping. A
failure is warned of, as `what` failing, once until a run succeeds again. `f` runs in the newest
world, so code revised since it started is the code it runs.
"""
function every!(f, what::AbstractString; seconds::Real)
    return Threads.@spawn begin
        warned = false
        while !STOPPING[]
            try
                Base.invokelatest(f)
                warned = false
            catch e
                STOPPING[] && break
                warned || @warn "$what failed; trying again" exception = e
                warned = true
            end
            pause(seconds)
        end
    end
end

const JOBS = Dict{String,Job}()
const JOBS_LOCK = ReentrantLock()
const JOB_COUNTER = Threads.Atomic{Int}(0)

"How long a finished job is kept, with its result, for those following it to read how it ended."
const JOB_KEEP = Hour(24)

# Finished jobs past `JOB_KEEP` are forgotten; called with `JOBS_LOCK` held.
function forget_old_jobs!(at::DateTime = now())
    for (id, j) in collect(JOBS)
        j.finished !== nothing && at - j.finished > JOB_KEEP || continue
        delete!(JOBS, id)
        delete!(JOB_STARTERS, id)
    end
end

"""
The documents changed since the site served last took them (see [`take_changes!`](@ref)): their ids,
or `nothing` for a change naming none, which the whole site takes. It starts as `nothing`, so the
first refresh after a start is whole.
"""
const CHANGED = Ref{Union{Set{String},Nothing}}(nothing)
const CHANGED_LOCK = ReentrantLock()

"Note that the documents `ids` changed, or with none, that something did that names none."
note_changes!(ids) = lock(CHANGED_LOCK) do
    CHANGED[] === nothing && return
    isempty(ids) ? (CHANGED[] = nothing) : union!(CHANGED[], ids)
    return
end

"The documents noted as changed since the last take (see [`note_changes!`](@ref)), or `nothing` when a change named none."
take_changes!() = lock(CHANGED_LOCK) do
    c = CHANGED[]
    CHANGED[] = Set{String}()
    return c
end

"""
    start_job(f, name; ids = String[], changes = nothing) -> Job

Run `f(job)` on a new task, working on the documents `ids`. `changes` is a file to touch when the
job ends, however it ends (see [`changes_stamp`](@ref)), the documents first noted as changed (see
[`note_changes!`](@ref); with none, everything is). `f` reports progress with `report!(job, msg)` and should return early
when `cancelled(job)`.
"""
function start_job(f, name::AbstractString; ids = String[], changes::Union{String,Nothing} = nothing)
    id = "j$(Threads.atomic_add!(JOB_COUNTER, 1) + 1)"
    job = Job(id, name, :running, "starting", now(), nothing, nothing, nothing, Threads.Atomic{Bool}(false),
              String.(ids), Base.Event())
    starter = get(task_local_storage(), :kb_caller, nothing)
    lock(JOBS_LOCK) do
        forget_old_jobs!()
        JOBS[id] = job
        starter === nothing || (JOB_STARTERS[id] = starter.user_id)
    end
    Threads.@spawn begin
        try
            job.result = f(job)
            job.status = job.cancel[] ? :cancelled : :done
            note_failures!(job)
        catch e
            job.status = :failed
            job.error = failure_message(e)          # (the backtrace goes to the log)
            @error "Job $id ($name) failed" exception = (e, catch_backtrace())
        finally
            # The documents it worked on are noted before the stamp moves, for the refresh it starts.
            changes === nothing || (note_changes!(job.ids); try touch(changes) catch end)
            job.finished = now()
            notify(job.done)
        end
    end
    return job
end

"""
A job over documents that returned each one's result (`ok`, and `error` for one that failed): its
message says how many failed, and it failed if every one did.
"""
function note_failures!(job::Job)
    r = job.result
    r isa AbstractVector && !isempty(r) && all(x -> x isa NamedTuple && haskey(x, :ok), r) || return
    failed = filter(x -> !x.ok, r)
    isempty(failed) && return
    job.message = "$(length(failed)) of $(length(r)) failed: $(first(get(first(failed), :error, ""), 300))"
    if length(failed) == length(r) && job.status == :done
        job.status = :failed
        job.error = join(("$(get(x, :id, "?")): $(get(x, :error, ""))" for x in failed), "\n")
    end
end

# Who started each job through the API (see `handle`), by its id: a job is theirs to follow, and
# everyone's for those with `jobs.view`.
const JOB_STARTERS = Dict{String,Union{Int,Nothing}}()

"Whether `caller` may follow job `job`: one they started, or any with `jobs.view`."
job_visible(job::Job, caller) =
    caller.via == :local || can(caller, "jobs.view") || lock(() -> get(JOB_STARTERS, job.id, -1), JOBS_LOCK) == caller.user_id

report!(job::Job, msg::AbstractString) = (job.message = msg; @info "[$(job.id)] $msg"; nothing)
cancelled(job::Job) = job.cancel[]
cancel!(job::Job) = (job.cancel[] = true; job)

get_job(id::AbstractString) = lock(() -> get(JOBS, id, nothing), JOBS_LOCK)
list_jobs() = lock(() -> sort!(collect(values(JOBS)); by = j -> j.started, rev = true), JOBS_LOCK)

function elapsed(job::Job)
    s = round(Int, (something(job.finished, now()) - job.started).value / 1000)
    return s < 60 ? "$(s)s" : "$(s ÷ 60)m$(lpad(s % 60, 2, '0'))s"
end
