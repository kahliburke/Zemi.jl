# Copies of the snapshots off this machine (`[backup.offsite]`, see `OffsiteConfig`), for losing the
# machine and its disk: every `every_hours` the latest hourly snapshot (see backup.jl) goes to a
# store, an S3-compatible bucket or a folder on a drive mounted here. In the store:
#
#   snapshots/<stamp>/state   the snapshot's state.tar.zst
#   snapshots/<stamp>/files   what its files/ holds: each file's path, size, modification time and hash
#   snapshots/<stamp>/done    its snapshot.toml, sent last: a copy without it is incomplete
#   files/<name>              each file once, named by a keyed hash of its content
#   keys/server               the data key, sealed with the server's key (`[backup.offsite] key`)
#   keys/recovery             the data key, sealed with a key derived from a recovery passphrase
#
# Every object is sealed with AES-256-GCM under the data key, a random key made with the store's
# first copy, with its name as associated data, so nothing can be read without it, nor one object
# passed off as another. The data key itself is kept only sealed, twice: with the server's key, and
# (once set with `zemi backup --offsite-recovery`) with a passphrase a person keeps, stretched with
# scrypt. Either opens the copies, so losing the server and its key loses nothing while the
# passphrase is known. Copies older than `keep_days` are deleted, all but the latest, and the files
# no copy left names with them.

"How the last copy went, for the Status page (see [`backup_json`](@ref))."
const OFFSITE_STATE = Ref((; ok_at = "", seconds = 0.0, error = "", error_at = "", latest = "", count = 0, sent = 0))

const OFFSITE_LOCK = ReentrantLock()

"The store the snapshots are copied to, or `nothing` when `[backup.offsite]` names none."
offsite_store(c::Config) = isempty(c.backup.offsite.store.store) ? nothing : open_store(c.backup.offsite.store; table = "[backup.offsite]")

"The key copies are sealed with: `[backup.offsite] key`, 64 hexadecimal digits (32 bytes)."
function offsite_key(c::Config)
    spec = c.backup.offsite.key
    isempty(spec) && error("[backup.offsite] has no key: make one with `zemi backup --offsite-key`")
    k = strip(resolve_key(spec, "[backup.offsite] key"))
    occursin(r"^[0-9a-fA-F]{64}$", k) || error("[backup.offsite] key must be 64 hexadecimal digits (32 bytes)")
    return hex2bytes(k)
end

"""
    new_offsite_key!(path) -> String

Write a new key for `[backup.offsite]` to `path`, readable only by its owner; refused where a file is
already. Returns the path.
"""
function new_offsite_key!(path::AbstractString)
    ispath(path) && error("There is a file at $path already: a key in use can't be replaced without losing what it sealed")
    mkpath(dirname(abspath(path)))
    return write_private(abspath(path), bytes2hex(rand(Random.RandomDevice(), UInt8, 32)) * "\n")
end

const SEALED_MAGIC = Vector{UInt8}("ZEMIBK1")

"`bytes` sealed under `key` for object `name`: a marker, a random nonce, then the ciphertext and its tag."
function seal(key::Vector{UInt8}, name::AbstractString, bytes::AbstractVector{UInt8})
    iv = rand(Random.RandomDevice(), UInt8, 12)
    return [SEALED_MAGIC; iv; aes_gcm_seal(key, iv, bytes; aad = Vector{UInt8}(name))]
end

"What [`seal`](@ref) sealed as object `name`; throws for another key, another object, or a change."
function unseal(key::Vector{UInt8}, name::AbstractString, bytes::AbstractVector{UInt8})
    n = length(SEALED_MAGIC)
    length(bytes) > n + 12 && bytes[1:n] == SEALED_MAGIC || error("$name is not a sealed copy")
    return aes_gcm_open(key, Vector{UInt8}(bytes[n+1:n+12]), bytes[n+13:end]; aad = Vector{UInt8}(name))
end

const SERVER_KEY_NAME = "keys/server"
const RECOVERY_KEY_NAME = "keys/recovery"
const RECOVERY_MAGIC = Vector{UInt8}("ZEMIRK1")
"scrypt's cost for a recovery passphrase: N = 2^17, r = 8, p = 1 (128 MB, about a second)."
const RECOVERY_LOG2_N = 17

"""
    scrypt_key(passphrase, salt; log2_n = RECOVERY_LOG2_N) -> Vector{UInt8}

A 32-byte key derived from `passphrase` with scrypt (OpenSSL's), slow and memory-hard so that
guessing passphrases is costly.
"""
function scrypt_key(passphrase::AbstractString, salt::Vector{UInt8}; log2_n::Integer = RECOVERY_LOG2_N)
    out = Vector{UInt8}(undef, 32)
    pass = Vector{UInt8}(passphrase)
    n, r, p = UInt64(1) << log2_n, UInt64(8), UInt64(1)
    ok = ccall((:EVP_PBE_scrypt, libcrypto), Cint,
               (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, UInt64, UInt64, UInt64, UInt64, Ptr{UInt8}, Csize_t),
               pass, length(pass), salt, length(salt), n, r, p, 2 * 128 * r * n, out, length(out))
    fill!(pass, 0x00)
    ossl(ok, "scrypt")
    return out
end

"""
    offsite_data_key(config, store; passphrase = nothing, create = false) -> Vector{UInt8}

The key the store's copies are sealed with, opened with the server's key (`[backup.offsite] key`),
or with `passphrase`, the recovery passphrase. With `create`, a store with none is given one, sealed
with the server's key.
"""
function offsite_data_key(c::Config, store; passphrase::Union{AbstractString,Nothing} = nothing, create::Bool = false)
    if passphrase !== nothing
        b = read_object(store, RECOVERY_KEY_NAME)
        b === nothing && error("The store has no recovery passphrase: set one with `zemi backup --offsite-recovery`")
        n = length(RECOVERY_MAGIC)
        length(b) > n + 17 && b[1:n] == RECOVERY_MAGIC || error("$RECOVERY_KEY_NAME is not a sealed key")
        wrap = scrypt_key(passphrase, Vector{UInt8}(b[n+1:n+16]); log2_n = b[n+17])
        return try unseal(wrap, RECOVERY_KEY_NAME, b[n+18:end]) catch
            error("That is not the store's recovery passphrase")
        end
    end
    key = offsite_key(c)
    b = read_object(store, SERVER_KEY_NAME)
    if b === nothing
        create || error("The store has no copies yet")
        has_object(store, RECOVERY_KEY_NAME) &&
            error("The store has a recovery key but no server key: restore with the passphrase (--recovery) rather than start it again")
        data = rand(Random.RandomDevice(), UInt8, 32)
        write_object!(store, SERVER_KEY_NAME, seal(key, SERVER_KEY_NAME, data))
        return data
    end
    return try unseal(key, SERVER_KEY_NAME, b) catch
        error("[backup.offsite] key is not the key this store's copies were made with: use that key, " *
              "or the recovery passphrase (--recovery)")
    end
end

"""
    set_offsite_recovery!(config, passphrase; store) -> Nothing

Seal the store's data key (opened with the server's key) with `passphrase` too, replacing any
passphrase set before, so that the copies can be restored with it alone.
"""
function set_offsite_recovery!(c::Config, passphrase::AbstractString; store = offsite_store(c))
    store === nothing && error("[backup.offsite] names no store")
    length(passphrase) >= 12 || error("A recovery passphrase needs 12 characters or more: several words, say")
    data = offsite_data_key(c, store; create = true)
    salt = rand(Random.RandomDevice(), UInt8, 16)
    sealed = seal(scrypt_key(passphrase, salt), RECOVERY_KEY_NAME, data)
    write_object!(store, RECOVERY_KEY_NAME, [RECOVERY_MAGIC; salt; UInt8(RECOVERY_LOG2_N); sealed])
    return nothing
end

"Whether the store has a recovery passphrase set."
has_offsite_recovery(store) = has_object(store, RECOVERY_KEY_NAME)

"A file's object in the store: named by a hash of its content keyed with `key`, so the names say nothing of it."
offsite_file_name(key::Vector{UInt8}, hash::AbstractString) = "files/" * bytes2hex(hmac_sha256(key, hex2bytes(hash)))

"""
    snapshot_file_hashes(c, snap) -> Vector{NamedTuple}

The files of snapshot `snap` (its `files.tsv`), each `(; path, size, mtime, hash)`, `hash` its
content's SHA-256: remembered in the backups folder by path, size and time, so only a file that
changed is read again.
"""
function snapshot_file_hashes(c::Config, snap::AbstractString)
    cache_file = joinpath(backup_dir(c), "offsite-hashes.tsv")
    known = Dict{Tuple{String,String,String},String}()
    if isfile(cache_file)
        for l in eachline(cache_file)
            p = split(l, '\t')
            length(p) == 4 && (known[(p[1], p[2], p[3])] = p[4])
        end
    end
    rows = NamedTuple[]
    manifest = joinpath(snap, "files.tsv")
    isfile(manifest) || return rows
    for l in eachline(manifest)
        p = split(l, '\t')
        length(p) == 3 || continue
        hash = get(known, (p[1], p[2], p[3]), nothing)
        hash === nothing && (hash = bytes2hex(open(sha256, joinpath(snap, "files", p[1]))))
        push!(rows, (; path = String(p[1]), size = String(p[2]), mtime = String(p[3]), hash))
    end
    write_atomic(cache_file, join(("$(r.path)\t$(r.size)\t$(r.mtime)\t$(r.hash)\n" for r in rows)))
    return rows
end

"""
Where the copy being sent says how far it has got, beside the backups: whichever process sends it
(the service, `zemi backup --offsite`, or one put in the background) writes it, and the Status page
and `zemi backup --offsite --follow` read it (see [`sending_offsite`](@ref)).
"""
offsite_progress_file(c::Config) = joinpath(backup_dir(c), "offsite-progress.json")

"Whether process `pid` still runs (on Windows, whether its progress was written in the last ten minutes)."
sender_alive(pid::Integer, file::AbstractString) =
    pid == getpid() || (Sys.iswindows() ? time() - mtime(file) < 600 : ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0)

"""
    sending_offsite(config) -> Union{Dict,Nothing}

The copy being sent now, by this process or another: `pid`, `stamp`, `started` (Unix time), `phase`
(`files`, then `state`), `files_done` of `files_total` and `bytes_done` of `bytes_total` still to send
when it began. `nothing` when none is, or the process that was sending it is gone.
"""
function sending_offsite(c::Config)
    f = offsite_progress_file(c)
    d = try JSON.parse(read(f, String)) catch; return nothing end
    d isa AbstractDict && sender_alive(Int(get(d, "pid", 0)), f) || return nothing
    return d
end

"""
    copy_digest(sealed) -> String

One SHA-256 over a copy's objects: each object's name and the SHA-256 of its sealed bytes, sorted by
name, a line each. The same objects as the store holds them give the same digest; any object missing,
added or changed gives another.
"""
copy_digest(sealed::AbstractDict) = bytes2hex(sha256(join(("$n\t$(sealed[n])\n" for n in sort!(collect(keys(sealed)))))))

"""
Where the SHA-256 of each object sent is kept, by its name, for the digests of later copies: one file
for each store, since one file sealed for two stores is two different objects.
"""
function sealed_hashes_file(c::Config)
    s = c.backup.offsite.store
    return joinpath(backup_dir(c), "offsite-sealed-$(first(bytes2hex(sha256(join([s.store, s.endpoint, s.bucket, s.prefix], '\n'))), 12)).tsv")
end

"The sealed objects' SHA-256 kept here (see [`sealed_hashes_file`](@ref)), by name."
sealed_hashes(c::Config) =
    (f = sealed_hashes_file(c); Dict{String,String}(isfile(f) ? (String(a) => String(b) for (a, b) in (split(l, '\t') for l in eachline(f)) ) : ()))

save_sealed_hashes!(c::Config, sealed::AbstractDict) =
    write_atomic(sealed_hashes_file(c), join(("$n\t$(sealed[n])\n" for n in sort!(collect(keys(sealed))))))

"How many files a copy sends or fetches at once: each is a request of its own, and one at a time the requests' latency, not the bandwidth, sets the pace."
const OFFSITE_PARALLEL = 16

"How far copy `d` (see [`sending_offsite`](@ref)) has got, for people: sent of total, the rate and the time left."
function offsite_progress_text(d::AbstractDict)
    mb(b) = round(b / 1e6; digits = 1)
    done, total = Int(d["bytes_done"]), Int(d["bytes_total"])
    took = max(time() - Float64(d["started"]), 1.0)
    rate = done / took
    left = rate > 0 && total > done ? (total - done) / rate : 0.0
    eta = left < 60 ? "under a minute left" : left < 3600 ? "about $(round(Int, left / 60)) min left" :
          "about $(round(left / 3600; digits = 1)) h left"
    what = d["phase"] == "state" ? "the packed state" : "$(d["files_done"]) of $(d["files_total"]) files"
    # Nothing measured yet (the first file, or the packed state, which goes as one): no rate to go by.
    pace = done == 0 ? "starting" : "$(round(rate / 1e6; digits = 2)) MB/s, $eta"
    doing = get(d, "doing", "Copying $(d["stamp"]) off this machine")
    return "$doing: $(mb(done)) of $(mb(total)) MB, $what · $pace"
end

"""
    send_offsite!(config; store, snap = latest_snapshot(config), progress = nothing) -> NamedTuple

Copy snapshot `snap` to the store (see the top of this file): its files the store lacks, then its
state, what its files are, and last its `snapshot.toml`. How far it has got is written for others to
read as it goes (see [`sending_offsite`](@ref)), and given to `progress` (a message) about every
second. A snapshot the store has a whole copy of already is not sent again. Refused while another
process sends one. Returns `(; stamp, sent)`, `sent` the files sent.
"""
function send_offsite!(c::Config; store = offsite_store(c), snap = latest_snapshot(c), progress = nothing)
    store === nothing && error("[backup.offsite] names no store")
    snap === nothing && error("No snapshot to copy: take one first (zemi backup)")
    stamp = basename(snap)
    return lock(OFFSITE_LOCK) do
        other = sending_offsite(c)
        other === nothing || other["pid"] == getpid() ||
            error("A copy is being sent already, by process $(other["pid"]): follow it with zemi backup --offsite --follow")
        any(x -> x.stamp == stamp && x.complete, offsite_copies(c; store)) && return (; stamp, sent = 0)
        key = offsite_data_key(c, store; create = true)
        rows = c.backup.offsite.files ? snapshot_file_hashes(c, snap) : NamedTuple[]
        have = Set(list_objects(store, "files/"))
        todo = [r for r in rows if !(offsite_file_name(key, r.hash) in have)]
        state = joinpath(snap, "state.tar.zst")
        file = offsite_progress_file(c)
        d = Dict{String,Any}("pid" => getpid(), "stamp" => stamp, "started" => time(), "phase" => "files",
                             "files_done" => 0, "files_total" => length(todo), "bytes_done" => 0,
                             "bytes_total" => sum(r -> parse(Int, r.size), todo; init = 0) + filesize(state))
        written = Ref(0.0)
        function note(; now = false)
            (now || time() - written[] >= 1) || return
            written[] = time()
            write_atomic(file, JSON.json(d))
            progress === nothing || progress(offsite_progress_text(d))
        end
        try
            note(; now = true)
            # Each object goes up whole, so the store keeps the SHA-256 it checked it against on arrival, and
            # its sealed bytes' hash is kept here for the copy's digest (see `sealed_hashes`).
            sealed = sealed_hashes(c)
            function put!(name, bytes)
                s = seal(key, name, bytes)
                write_object!(store, name, s; whole = true)
                sealed[name] = bytes2hex(sha256(s))
            end
            asyncmap(todo; ntasks = OFFSITE_PARALLEL) do r
                name = offsite_file_name(key, r.hash)
                bytes = read(joinpath(snap, "files", r.path))
                bytes2hex(sha256(bytes)) == r.hash || error("$(r.path) changed while it was being copied")
                put!(name, bytes)
                d["files_done"] += 1
                d["bytes_done"] += length(bytes)
                note()
            end
            # A file sent with an earlier copy, whose sealed hash this machine lacks: the store's, or, where the
            # store keeps none (one that went up in parts), the file sent again whole.
            names = [offsite_file_name(key, r.hash) for r in rows]
            asyncmap([(r, n) for (r, n) in zip(rows, names) if !haskey(sealed, n)]; ntasks = OFFSITE_PARALLEL) do (r, n)
                h = object_sha256(store, n)
                h === nothing ? put!(n, read(joinpath(snap, "files", r.path))) : (sealed[n] = h)
            end
            save_sealed_hashes!(c, sealed)
            meta = TOML.parsefile(joinpath(snap, "snapshot.toml"))
            # Without its files, a copy restores none, rather than emptying the folders the snapshot had.
            c.backup.offsite.files || (meta["files"] = String[])
            d["phase"] = "state"
            note(; now = true)
            put!("snapshots/$stamp/state", read(state))
            d["bytes_done"] += filesize(state)
            put!("snapshots/$stamp/files", Vector{UInt8}(join(("$(r.path)\t$(r.size)\t$(r.mtime)\t$(r.hash)\t$(sealed[n])\n"
                                                                for (r, n) in zip(rows, names)))))
            # The copy's digest: one hash over every object it is made of, each as the store holds it.
            parts = ["snapshots/$stamp/state", "snapshots/$stamp/files"]
            meta["sealed"] = Dict(p => sealed[p] for p in parts)
            meta["digest"] = copy_digest(Dict(n => sealed[n] for n in [names; parts]))
            put!("snapshots/$stamp/done", Vector{UInt8}(sprint(TOML.print, meta)))
            save_sealed_hashes!(c, sealed)
            note(; now = true)
            return (; stamp, sent = length(todo))
        finally
            rm(file; force = true)
        end
    end
end

"""
    offsite_copies(config; store) -> Vector{NamedTuple}

The copies in the store, the latest first: each `(; stamp, at, complete)`, `complete` once its
`snapshot.toml` was sent.
"""
function offsite_copies(c::Config; store = offsite_store(c))
    store === nothing && return NamedTuple[]
    parts = Dict{String,Set{String}}()
    for k in list_objects(store, "snapshots/")
        p = split(k, '/')
        length(p) == 3 && parse_backup_stamp(p[2]) !== nothing && push!(get!(parts, String(p[2]), Set{String}()), String(p[3]))
    end
    copies = [(; stamp, at = parse_backup_stamp(stamp), complete = "done" in ps) for (stamp, ps) in parts]
    return sort!(copies; by = x -> x.at, rev = true)
end

"""
    thin_offsite!(config; store, at = now(UTC)) -> Vector{String}

Delete the copies older than `[backup.offsite] keep_days`, all but the latest complete one, and
incomplete ones a day old; then the files no copy left names that are a day old (a copy being sent
from elsewhere names its files only once they are sent). Returns the stamps deleted.
"""
function thin_offsite!(c::Config; store = offsite_store(c), at::DateTime = now(UTC))
    store === nothing && return String[]
    lock(OFFSITE_LOCK) do
        key = offsite_data_key(c, store)
        copies = offsite_copies(c; store)
        latest = findfirst(x -> x.complete, copies)
        gone = String[]
        for (i, x) in enumerate(copies)
            age = (at - x.at) / Day(1)
            keep = i == latest || (x.complete ? age < c.backup.offsite.keep_days : age < 1)
            keep && continue
            foreach(p -> delete_object!(store, "snapshots/$(x.stamp)/$p"), ("done", "files", "state"))
            push!(gone, x.stamp)
        end
        named = Set{String}()
        for x in copies
            x.complete && !(x.stamp in gone) || continue
            name = "snapshots/$(x.stamp)/files"
            bytes = read_object(store, name)
            bytes === nothing && continue
            for l in eachline(IOBuffer(unseal(key, name, bytes)))
                p = split(l, '\t')
                length(p) >= 4 && push!(named, offsite_file_name(key, p[4]))
            end
        end
        for (k, t) in list_objects(store, "files/"; modified = true)
            k in named || at - t < Day(1) || delete_object!(store, k)
        end
        return gone
    end
end

# When a copy was last sent, kept in the backups folder so that one is not sent again at each start.
offsite_mark(c::Config) = joinpath(backup_dir(c), "offsite.toml")

"Whether a copy is due: none sent for `[backup.offsite] every_hours`, and none failed in the last ten minutes."
function offsite_due(c::Config; at::DateTime = now(UTC))
    s = OFFSITE_STATE[]
    !isempty(s.error_at) && at - DateTime(s.error_at) < Minute(10) && return false
    f = offsite_mark(c)
    isfile(f) || return true
    last = tryparse(DateTime, rstrip(string(get(TOML.parsefile(f), "sent_at", "")), 'Z'))
    return last === nothing || (at - last) / Hour(1) >= c.backup.offsite.every_hours - 1 / 60
end

"""
    offsite!(config; progress = nothing) -> NamedTuple

Copy the latest snapshot off this machine (taking one first when there is none), and thin the
copies, noting how it went for the Status page; `progress` is told how far it has got (see
[`send_offsite!`](@ref)). Returns what `send_offsite!` did.
"""
function offsite!(c::Config; progress = nothing)
    started = time()
    try
        latest_snapshot(c) === nothing && backup!(c)
        r = send_offsite!(c; progress)
        thin_offsite!(c)
        write_atomic(offsite_mark(c), sprint(TOML.print, Dict("sent_at" => string(now(UTC)) * "Z", "stamp" => r.stamp)))
        copies = offsite_copies(c)
        OFFSITE_STATE[] = (; ok_at = string(now(UTC)), seconds = round(time() - started; digits = 1), error = "", error_at = "",
                             latest = r.stamp, count = count(x -> x.complete, copies), sent = r.sent)
        @info "Copied the snapshot $(r.stamp) off this machine ($(r.sent) new file(s))"
        return r
    catch e
        OFFSITE_STATE[] = (; OFFSITE_STATE[]..., error = failure_message(e), error_at = string(now(UTC)))
        rethrow()
    end
end

"""
    follow_offsite(kb) -> Task

The service's copies off this machine: every ten minutes, while the backups are on and
`[backup.offsite]` names a store, a copy when one is due (see [`offsite_due`](@ref)).
"""
function follow_offsite(kb::KB)
    return every!("Copying the backups off this machine"; seconds = 600) do
        c = kb.config
        c.backup.enabled && !isempty(c.backup.offsite.store.store) && offsite_due(c) && sending_offsite(c) === nothing && offsite!(c)
    end
end

"""
    fetch_offsite!(config, stamp, dest; store, passphrase = nothing, progress = nothing) -> String

Fetch copy `stamp` from the store into snapshot folder `dest`, laid out as [`snapshot!`](@ref) lays
one out: each part checked as it is unsealed, each file against its hash, several files at once.
Opened with the server's key, or with the recovery `passphrase`. `progress` is told how far it has
got (a message) about every second. Returns `dest`.
"""
function fetch_offsite!(c::Config, stamp::AbstractString, dest::AbstractString; store = offsite_store(c),
                        passphrase::Union{AbstractString,Nothing} = nothing, progress = nothing)
    store === nothing && error("[backup.offsite] names no store")
    parse_backup_stamp(stamp) === nothing && error("A copy is named by its time, as `zemi backups --offsite` lists them: $stamp")
    key = offsite_data_key(c, store; passphrase)
    fetch(name) = (b = read_object(store, name); b === nothing ? not_found("The store has no $name") : unseal(key, name, b))
    meta = String(fetch("snapshots/$stamp/done"))               # missing for a copy never completed
    part = dest * ".part"
    rm(part; force = true, recursive = true)
    mkpath(joinpath(part, "files"))
    try
        rows = [p for p in (split(l, '\t') for l in eachline(IOBuffer(fetch("snapshots/$stamp/files")))) if length(p) >= 4]
        d = Dict{String,Any}("doing" => "Fetching $stamp", "stamp" => stamp, "started" => time(), "phase" => "state",
                             "files_done" => 0, "files_total" => length(rows), "bytes_done" => 0,
                             "bytes_total" => sum(p -> parse(Int, p[2]), rows; init = 0))
        said = Ref(0.0)
        note(; now = false) = progress === nothing || !(now || time() - said[] >= 1) || (said[] = time(); progress(offsite_progress_text(d)))
        note(; now = true)
        state = fetch("snapshots/$stamp/state")
        write(joinpath(part, "state.tar.zst"), state)
        d["phase"], d["bytes_total"] = "files", d["bytes_total"] + length(state)
        d["bytes_done"] += length(state)
        asyncmap(rows; ntasks = OFFSITE_PARALLEL) do p
            bytes = fetch(offsite_file_name(key, p[4]))
            bytes2hex(sha256(bytes)) == p[4] || error("$(p[1]) in the store is not the file its copy names")
            to = joinpath(part, "files", p[1])
            mkpath(dirname(to))
            write(to, bytes)
            d["files_done"] += 1
            d["bytes_done"] += length(bytes)
            note()
        end
        open(joinpath(part, "files.tsv"), "w") do manifest
            foreach(p -> println(manifest, p[1], '\t', p[2], '\t', p[3]), rows)
        end
        for d in get(TOML.parse(meta), "files", String[])
            mkpath(joinpath(part, "files", d))
        end
        write(joinpath(part, "snapshot.toml"), meta)
        rm(dest; force = true, recursive = true)
        mv(part, dest)
    catch
        rm(part; force = true, recursive = true)
        rethrow()
    end
    return dest
end

"""
    restore_offsite!(config, stamp; passphrase = nothing, config_files = false, included = false, progress = nothing) -> String

Fetch copy `stamp` (see [`fetch_offsite!`](@ref)) into the snapshot kept as `offsite-<stamp>`, then
restore it (see [`restore_backup!`](@ref)). Needs only `[backup.offsite]` and its key, or the
recovery `passphrase`: on a new machine the knowledge base is put back from the store alone. Returns
the name of the snapshot what was there is kept as.
"""
function restore_offsite!(c::Config, stamp::AbstractString; passphrase::Union{AbstractString,Nothing} = nothing,
                          config_files::Bool = false, included::Bool = false, progress = nothing)
    name = "offsite-$stamp"
    fetch_offsite!(c, stamp, joinpath(backup_root(c), "kept", name); passphrase, progress)
    return restore_backup!(c, name; config_files, included)
end

"""
    check_offsite(config; stamp = the latest complete copy, passphrase = nothing, full = false, sample = 8,
                  progress = nothing) -> NamedTuple

Prove a copy can be restored with the key at hand (the server's, or the recovery `passphrase`),
changing nothing here. The copy's list of its objects, opened with the key, must give the digest it
was sent with (see [`copy_digest`](@ref)), and every object the store holds must have the SHA-256
that list names, as the store checked it on arrival: so the store holds exactly what was sent, every
file and the packed state, whose database was checked when its snapshot was taken. `sample` files
are fetched at random whole, opened and checked against their hashes. That takes seconds and no
download of the copy. With `full`, every file is fetched and checked and the database unpacked and
checked, as a restore would (see [`fetch_offsite!`](@ref)). Returns `(; stamp, files, bytes, fetched,
digest)`.
"""
function check_offsite(c::Config; stamp::Union{AbstractString,Nothing} = nothing, passphrase::Union{AbstractString,Nothing} = nothing,
                       full::Bool = false, sample::Integer = 8, progress = nothing)
    store = offsite_store(c)
    store === nothing && error("[backup.offsite] names no store")
    if stamp === nothing
        i = findfirst(x -> x.complete, offsite_copies(c; store))
        i === nothing && error("The store has no complete copy")
        stamp = offsite_copies(c; store)[i].stamp
    end
    key = offsite_data_key(c, store; passphrase)
    fetch(name) = (b = read_object(store, name); b === nothing ? not_found("The store has no $name") : unseal(key, name, b))
    meta = TOML.parse(String(fetch("snapshots/$stamp/done")))
    digest = String(get(meta, "digest", ""))
    isempty(digest) && error("$stamp was sent before copies carried a digest: send a new copy (zemi backup --offsite)")
    work = mktempdir()
    try
        if full
            dest = fetch_offsite!(c, stamp, joinpath(work, stamp); store, passphrase, progress)
            database_intact(joinpath(dest, "state.tar.zst"), joinpath(work, "state"))
            files = countlines(joinpath(dest, "files.tsv"))
            bytes = sum(filesize(joinpath(d, f)) for (d, _, fs) in walkdir(dest) for f in fs; init = 0)
            return (; stamp = String(stamp), files, bytes, fetched = files, digest)
        end
        rows = [p for p in (split(l, '\t') for l in eachline(IOBuffer(fetch("snapshots/$stamp/files")))) if length(p) == 5]
        sealed = Dict{String,String}(offsite_file_name(key, p[4]) => String(p[5]) for p in rows)
        merge!(sealed, Dict{String,String}(String(k) => String(v) for (k, v) in get(meta, "sealed", Dict())))
        copy_digest(sealed) == digest || error("$stamp's list of its objects does not give the digest it was sent with")
        # What the store holds, by the SHA-256 it keeps of each object.
        names = sort!(collect(keys(sealed)))
        checked, wrong = Ref(0), String[]
        said = Ref(0.0)
        say(m; now = false) = progress === nothing || !(now || time() - said[] >= 1) || (said[] = time(); progress(m))
        asyncmap(names; ntasks = 4 * OFFSITE_PARALLEL) do n
            object_sha256(store, n) == sealed[n] || push!(wrong, n)
            checked[] += 1
            say("Checking $stamp: $(checked[]) of $(length(names)) objects as the store holds them")
        end
        isempty(wrong) || error("$(length(wrong)) of $stamp's $(length(names)) objects are missing from the store or not what was sent, " *
                                "$(first(wrong)) among them")
        picked = rows[Random.randperm(length(rows))[1:min(sample, length(rows))]]
        say("Checking $stamp: opening $(length(picked)) of its files"; now = true)
        asyncmap(picked; ntasks = OFFSITE_PARALLEL) do p
            bytes2hex(sha256(fetch(offsite_file_name(key, p[4])))) == p[4] || error("$(p[1]) in the store is not the file its copy names")
        end
        return (; stamp = String(stamp), files = length(rows), bytes = sum(p -> parse(Int, p[2]), rows; init = 0),
                  fetched = length(picked), digest)
    finally
        rm(work; force = true, recursive = true)
    end
end

"Unpack packed state `file` into `dir` and check its database's integrity; an error says what fails."
function database_intact(file::AbstractString, dir::AbstractString)
    open(io -> Tar.extract(ZstdDecompressorStream(io), dir), file)
    check = sqlite_value(joinpath(dir, "kb.sqlite3"), "PRAGMA integrity_check")
    check == "ok" || error("The copy's database fails its integrity check: $check")
    return nothing
end

"The copies off this machine, for the Status page: whether they are on, where they go, and how the last went."
function offsite_json(c::Config)
    o = c.backup.offsite
    s = o.store
    where = isempty(s.store) ? "" : startswith(s.store, "dir:") ? s.store[5:end] : join(filter(!isempty, [s.endpoint, s.bucket, s.prefix]), " · ")
    sending = sending_offsite(c)
    return merge(Dict{String,Any}(string(k) => v isa String && occursin(r"^\d{4}-\d\d-\d\dT", v) ? v * "Z" : v for (k, v) in pairs(OFFSITE_STATE[])),
                 Dict{String,Any}("enabled" => !isempty(s.store), "where" => where, "every_hours" => o.every_hours, "keep_days" => o.keep_days,
                                  "sending" => sending === nothing ? "" : offsite_progress_text(sending)))
end
