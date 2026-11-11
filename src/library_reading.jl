# Reading people's libraries (see library_store.jl): what a person puts in their space comes into the
# knowledge base as theirs alone (see document_access.jl). A vault (a folder holding `.obsidian`) is
# read as notes (see obsidian.jl), and a PDF anywhere in the space as a document, read in full. A
# change to a space through the API queues it to be read, and every space is read as the service
# starts, catching up with what changed while it was not running.

"Whether a change to a space through the API has it read (tests that read spaces themselves turn it off)."
const READ_LIBRARIES = Ref(true)

"The person whose space `space` is (their user id), or `nothing` for whoever runs the knowledge base on their own machine."
space_holder(space::AbstractString) = (m = match(r"^people/(\d+)$", space); m === nothing ? nothing : parse(Int, m[1]))

"What is known of how a space was last read: its vaults, and each PDF's hash and document."
library_state_key(space::AbstractString) = "library_state:" * space
load_library_state(kb::KB, space::AbstractString) =
    Dict{String,Any}(JSON.parse(coalesce(scalar(kb, "SELECT value FROM kv WHERE key = ?", (library_state_key(space),)), "{}")))
save_library_state!(kb::KB, space::AbstractString, d) =
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (library_state_key(space), JSON.json(d)))

"The spaces there is anything to read in: those holding files, and those read before (whose files may all be gone)."
library_spaces(kb::KB) = sort!(unique([[String(r.space) for r in query(kb, "SELECT DISTINCT space FROM library_files")];
                                       [String(r.key)[ncodeunits(library_state_key(""))+1:end]
                                        for r in query(kb, "SELECT key FROM kv WHERE key LIKE 'library_state:%'")]]))

"""
    release!(kb, id, holder)

Person `holder` no longer brings document `id` in: they are no longer one of its holders, and a
private document no one holds any more is removed, with everything made from it.
"""
function release!(kb::KB, id::AbstractString, holder::Union{Integer,Nothing})
    holder === nothing && return nothing
    execute!(kb, "DELETE FROM document_holders WHERE user_id = ? AND paper_id = (SELECT id FROM papers WHERE doc_id = ?)", (holder, id))
    coalesce(scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,)), "") == "private" &&
        isempty(document_holders(kb, id)) && remove_paper!(kb, id)
    return nothing
end

"A PDF of a space as the document it is, brought in for the space's person and queued to be read; `nothing` when it cannot be."
function library_pdf!(kb::KB, space::AbstractString, f, holder)
    bytes = read_library_file(kb, space, f.path)
    bytes === nothing && return nothing
    dir = mktempdir()
    try
        path = joinpath(dir, basename(f.path))                    # its name, a title for one that gives none
        write(path, bytes)
        id = add_pdf!(kb, path; source = "library", holder)
        READ_PUT[] && queue_reading!(kb, [id])
        return id
    catch e
        e isa InterruptException && rethrow()
        e isa DroppedError && return nothing
        @warn "A PDF in a library could not be brought in; it is tried again when it changes" file = f.path exception = e
        return nothing
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    read_space!(kb, space; job = nothing)

Bring the knowledge base in step with library `space`: its vaults read as notes (see
[`read_vault!`](@ref)), one gone forgotten; its PDFs brought in as documents, a changed one again,
and one gone no longer held for its person (see [`release!`](@ref)).
"""
function read_space!(kb::KB, space::AbstractString; job::Union{Job,Nothing} = nothing)
    holder = space_holder(space)
    files = library_files(kb, space)
    state = load_library_state(kb, space)
    run = SourceRun(kb, registered_source("obsidian"), job; holder)
    roots = vault_roots(files)
    try
        for root in roots
            read_vault!(run, vault_config(kb, space, root))
        end
        for root in get(state, "vaults", String[])
            root in roots || forget_vault!(run, VaultConfig(; space = String(space), root = String(root)))
        end
        state["vaults"] = roots
        pdfs = Dict{String,Any}(get(state, "pdfs", Dict{String,Any}()))
        state["pdfs"] = pdfs
        here = Dict(f.path => f for f in files if lowercase(splitext(f.path)[2]) == ".pdf" && !any(startswith("."), split(f.path, '/')))
        # A document is released only when no other file of the space is it.
        let_go(id) = any(e -> e["id"] == id, values(pdfs)) || release!(kb, id, holder)
        for (path, f) in sort!(collect(here); by = first)
            cancelled(run) && break
            e = get(pdfs, path, nothing)
            e !== nothing && e["sha"] == f.sha256 && continue
            id = library_pdf!(kb, space, f, holder)
            id === nothing && continue
            pdfs[path] = Dict{String,Any}("sha" => f.sha256, "id" => id)
            e === nothing || e["id"] == id || let_go(e["id"])
        end
        for path in collect(keys(pdfs))
            haskey(here, path) && continue
            id = pop!(pdfs, path)["id"]
            let_go(id)
        end
    finally
        save_library_state!(kb, space, state)
    end
    return nothing
end

"The spaces waiting to be read, and the job reading them."
const LIBRARY_READING = (; spaces = Set{String}(), job = Ref{Union{Job,Nothing}}(nothing), lock = ReentrantLock())

"""
    queue_library!(kb, spaces) -> Job

Have library `spaces` read (see [`read_space!`](@ref)), by the job reading them now or a new one. A
space queued while it is being read is read again after it.
"""
function queue_library!(kb::KB, spaces)
    lock(LIBRARY_READING.lock) do
        union!(LIBRARY_READING.spaces, spaces)
        j = LIBRARY_READING.job[]
        j !== nothing && j.finished === nothing && return j
        LIBRARY_READING.job[] = start_job("read libraries") do job
            n = 0
            while !cancelled(job)
                space = lock(LIBRARY_READING.lock) do
                    # Done: the next space queued starts a job of its own.
                    isempty(LIBRARY_READING.spaces) ? (LIBRARY_READING.job[] = nothing) : pop!(LIBRARY_READING.spaces)
                end
                space === nothing && return "$n read"
                report!(job, "reading a library")
                try
                    read_space!(kb, space; job)
                catch e
                    e isa InterruptException && rethrow()
                    e isa SourceStopped || @warn "A library could not be read; it is read again when it changes" exception = e
                end
                n += 1
            end
            lock(() -> (LIBRARY_READING.job[] = nothing), LIBRARY_READING.lock)
            return "$n read; cancelled"
        end
    end
end

"Read every library, catching up with what changed while the service was not running."
catch_up_libraries!(kb::KB) = (s = library_spaces(kb); isempty(s) ? nothing : queue_library!(kb, s))
