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

Bring the knowledge base in step with library `space`: its bibliographies' entries brought in as
documents (see [`read_bibliographies!`](@ref)), first, so that its notes cite by their keys; its vaults
read as notes (see [`read_vault!`](@ref)), one gone forgotten; and its other PDFs brought in as
documents, a changed one again. A document none of the space's files brings in any more is no longer
held for its person (see [`release!`](@ref)).
"""
function read_space!(kb::KB, space::AbstractString; job::Union{Job,Nothing} = nothing)
    holder = space_holder(space)
    files = library_files(kb, space)
    state = load_library_state(kb, space)
    run = SourceRun(kb, registered_source("obsidian"), job; holder)
    roots = vault_roots(files)
    pdfs = Dict{String,Any}(get(state, "pdfs", Dict{String,Any}()))
    held() = union(Set{String}(String(e["id"]) for e in values(pdfs)), bib_documents(state))
    before = held()
    try
        linked = read_bibliographies!(kb, space, files, state; holder, run)
        for root in roots
            read_vault!(run, vault_config(kb, space, root))
        end
        for root in get(state, "vaults", String[])
            root in roots || forget_vault!(run, VaultConfig(; space = String(space), root = String(root)))
        end
        state["vaults"] = roots
        state["pdfs"] = pdfs
        # The PDFs an entry of a bibliography links are read as that entry.
        here = Dict(f.path => f for f in files if lowercase(splitext(f.path)[2]) == ".pdf" && !any(startswith("."), split(f.path, '/')) &&
                                                 !(f.path in linked))
        for (path, f) in sort!(collect(here); by = first)
            cancelled(run) && break
            e = get(pdfs, path, nothing)
            e !== nothing && e["sha"] == f.sha256 && continue
            id = library_pdf!(kb, space, f, holder)
            id === nothing && continue
            pdfs[path] = Dict{String,Any}("sha" => f.sha256, "id" => id)
        end
        foreach(path -> haskey(here, path) || delete!(pdfs, path), collect(keys(pdfs)))
    finally
        save_library_state!(kb, space, state)
    end
    foreach(id -> release!(kb, id, holder), setdiff(before, held()))
    return nothing
end

"The spaces waiting to be read, and the job reading them."
const LIBRARY_READING = (; spaces = Set{String}(), job = Ref{Union{Job,Nothing}}(nothing), reading = Ref(""), lock = ReentrantLock())

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
                LIBRARY_READING.reading[] = space
                try
                    read_space!(kb, space; job)
                catch e
                    e isa InterruptException && rethrow()
                    e isa SourceStopped || @warn "A library could not be read; it is read again when it changes" exception = e
                finally
                    LIBRARY_READING.reading[] = ""
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

"Whether space `space` is being read, or waits to be."
being_read(space::AbstractString) =
    lock(() -> space in LIBRARY_READING.spaces || LIBRARY_READING.reading[] == space, LIBRARY_READING.lock)

"""
    library_overview(kb, caller) -> Dict

What `caller`'s library holds and what keeps it in step: each folder (its files, bytes, whether it is a
vault, its bibliographies (see [`bib_overview`](@ref)), the documents read from it and when it last changed), how much the space uses of its limit,
whether it is being read, the `zemi connect` sign-ins that reach it (tokens of scope `library`), and
whose it is (`person`, their name and email).
"""
function library_overview(kb::KB, caller::Caller)
    space = library_space(caller)
    files, changes = library_files(kb, space), library_changes(kb, space)
    state = load_library_state(kb, space)
    vaults = Set(get(state, "vaults", String[]))
    pdfs = get(state, "pdfs", Dict{String,Any}())
    folders = Dict{String,Any}[]
    byfolder = Dict{String,Vector{eltype(files)}}()
    foreach(f -> push!(get!(byfolder, library_folder(f.path), eltype(files)[]), f), files)
    for (name, fs) in sort!(collect(byfolder); by = first)
        prefix = isempty(name) ? "$space/" : "$space/$name/"
        notes = scalar(kb, "SELECT count(*) FROM records WHERE source = 'obsidian' AND substr(key, 1, ?) = ?", (length(prefix), prefix))
        push!(folders, Dict("name" => name, "files" => length(fs), "bytes" => sum(f.size for f in fs),
                            "vault" => name in vaults, "bibliographies" => bib_overview(state, name),
                            "documents" => Int(notes) + count(p -> library_folder(p) == name, keys(pdfs)) +
                                           sum((b["documents"] for b in bib_overview(state, name)); init = 0),
                            "changed" => get(changes, name, maximum(f.modified for f in fs))))
    end
    connections = caller.user_id === nothing ? Dict{String,Any}[] :
        [Dict("id" => Int(t.id), "name" => String(t.name), "created_at" => String(t.created_at), "last_used" => coalesce(t.last_used, ""))
         for t in query(kb, """SELECT id, name, created_at, last_used FROM api_tokens WHERE user_id = ? AND scope = 'library'
                               AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC""",
                        (caller.user_id, now_iso()))]
    return Dict("folders" => folders, "used" => library_usage(kb, space), "limit" => library_limit(kb.config),
                "reading" => being_read(space), "connections" => connections,
                "this_machine" => space == "people/local" ? local_syncing() : nothing,
                "person" => Dict("name" => caller_name(caller), "email" => caller.email))
end

"""
    local_syncing() -> Union{Dict,Nothing}

How `zemi connect` on this machine keeps folders in step with the knowledge base run here, from the
status it keeps (see [`Syncer`](@ref)): who syncs (`by`: the knowledge base, `zemi connect`, or ""
for no one now), when it last wrote (`updated`), an `error` that stopped its last pass, and each
folder's `name`, `state` and `message`. `nothing` when its folders go elsewhere, or there are none.
"""
function local_syncing()
    c = try load_connect_config() catch; return nothing end
    get(c, "site", "") == "local" && !isempty(get(c, "folders", Any[])) || return nothing
    s = read_connect_status()
    by = syncing_pid() === nothing ? "" : isempty(s["by"]) ? "zemi connect" : String(s["by"])
    return Dict("by" => by, "updated" => s["updated"], "paused" => get(c, "paused", false) === true, "error" => s["error"],
                "folders" => [Dict("name" => f["name"], "state" => f["state"], "message" => f["message"]) for f in s["folders"]])
end

# What one's library holds, and what keeps it in step.
route!("GET", "/api/library"; need = "library") do c
    library_overview(c.kb, c.caller)
end
