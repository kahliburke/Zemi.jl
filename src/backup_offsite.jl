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
    send_offsite!(config; store, snap = latest_snapshot(config)) -> NamedTuple

Copy snapshot `snap` to the store (see the top of this file): its files the store lacks, then its
state, what its files are, and last its `snapshot.toml`. Returns `(; stamp, sent)`, `sent` the files
sent.
"""
function send_offsite!(c::Config; store = offsite_store(c), snap = latest_snapshot(c))
    store === nothing && error("[backup.offsite] names no store")
    snap === nothing && error("No snapshot to copy: take one first (zemi backup)")
    stamp = basename(snap)
    return lock(OFFSITE_LOCK) do
        key = offsite_data_key(c, store; create = true)
        rows = c.backup.offsite.files ? snapshot_file_hashes(c, snap) : NamedTuple[]
        have = Set(list_objects(store, "files/"))
        sent = 0
        for r in rows
            name = offsite_file_name(key, r.hash)
            name in have && continue
            bytes = read(joinpath(snap, "files", r.path))
            bytes2hex(sha256(bytes)) == r.hash || error("$(r.path) changed while it was being copied")
            write_object!(store, name, seal(key, name, bytes))
            push!(have, name)
            sent += 1
        end
        meta = TOML.parsefile(joinpath(snap, "snapshot.toml"))
        # Without its files, a copy restores none, rather than emptying the folders the snapshot had.
        c.backup.offsite.files || (meta["files"] = String[])
        put(part, bytes) = (name = "snapshots/$stamp/$part"; write_object!(store, name, seal(key, name, bytes)))
        put("state", read(joinpath(snap, "state.tar.zst")))
        put("files", Vector{UInt8}(join(("$(r.path)\t$(r.size)\t$(r.mtime)\t$(r.hash)\n" for r in rows))))
        put("done", Vector{UInt8}(sprint(TOML.print, meta)))
        return (; stamp, sent)
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
                length(p) == 4 && push!(named, offsite_file_name(key, p[4]))
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
    offsite!(config) -> NamedTuple

Copy the latest snapshot off this machine (taking one first when there is none), and thin the
copies, noting how it went for the Status page. Returns what [`send_offsite!`](@ref) did.
"""
function offsite!(c::Config)
    started = time()
    try
        latest_snapshot(c) === nothing && backup!(c)
        r = send_offsite!(c)
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
        c.backup.enabled && !isempty(c.backup.offsite.store.store) && offsite_due(c) && offsite!(c)
    end
end

"""
    fetch_offsite!(config, stamp, dest; store, passphrase = nothing) -> String

Fetch copy `stamp` from the store into snapshot folder `dest`, laid out as [`snapshot!`](@ref) lays
one out: each part checked as it is unsealed, each file against its hash. Opened with the server's
key, or with the recovery `passphrase`. Returns `dest`.
"""
function fetch_offsite!(c::Config, stamp::AbstractString, dest::AbstractString; store = offsite_store(c),
                        passphrase::Union{AbstractString,Nothing} = nothing)
    store === nothing && error("[backup.offsite] names no store")
    parse_backup_stamp(stamp) === nothing && error("A copy is named by its time, as `zemi backups --offsite` lists them: $stamp")
    key = offsite_data_key(c, store; passphrase)
    fetch(name) = (b = read_object(store, name); b === nothing ? not_found("The store has no $name") : unseal(key, name, b))
    meta = String(fetch("snapshots/$stamp/done"))               # missing for a copy never completed
    part = dest * ".part"
    rm(part; force = true, recursive = true)
    mkpath(joinpath(part, "files"))
    try
        write(joinpath(part, "state.tar.zst"), fetch("snapshots/$stamp/state"))
        open(joinpath(part, "files.tsv"), "w") do manifest
            for l in eachline(IOBuffer(fetch("snapshots/$stamp/files")))
                p = split(l, '\t')
                length(p) == 4 || continue
                bytes = fetch(offsite_file_name(key, p[4]))
                bytes2hex(sha256(bytes)) == p[4] || error("$(p[1]) in the store is not the file its copy names")
                to = joinpath(part, "files", p[1])
                mkpath(dirname(to))
                write(to, bytes)
                println(manifest, p[1], '\t', p[2], '\t', p[3])
            end
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
    restore_offsite!(config, stamp; passphrase = nothing, config_files = false, included = false) -> String

Fetch copy `stamp` (see [`fetch_offsite!`](@ref)) into the snapshot kept as `offsite-<stamp>`, then
restore it (see [`restore_backup!`](@ref)). Needs only `[backup.offsite]` and its key, or the
recovery `passphrase`: on a new machine the knowledge base is put back from the store alone. Returns
the name of the snapshot what was there is kept as.
"""
function restore_offsite!(c::Config, stamp::AbstractString; passphrase::Union{AbstractString,Nothing} = nothing,
                          config_files::Bool = false, included::Bool = false)
    name = "offsite-$stamp"
    fetch_offsite!(c, stamp, joinpath(backup_root(c), "kept", name); passphrase)
    return restore_backup!(c, name; config_files, included)
end

"""
    check_offsite(config; stamp = the latest complete copy, passphrase = nothing) -> NamedTuple

Prove a copy can be restored with the key at hand (the server's, or the recovery `passphrase`):
fetch it whole into a folder of its own, unsealing and checking every part, and check its database's
integrity. Nothing here is changed. Returns `(; stamp, files, bytes)`.
"""
function check_offsite(c::Config; stamp::Union{AbstractString,Nothing} = nothing, passphrase::Union{AbstractString,Nothing} = nothing)
    store = offsite_store(c)
    store === nothing && error("[backup.offsite] names no store")
    if stamp === nothing
        i = findfirst(x -> x.complete, offsite_copies(c; store))
        i === nothing && error("The store has no complete copy")
        stamp = offsite_copies(c; store)[i].stamp
    end
    work = mktempdir()
    try
        dest = fetch_offsite!(c, stamp, joinpath(work, stamp); store, passphrase)
        state = joinpath(work, "state")
        open(io -> Tar.extract(ZstdDecompressorStream(io), state), joinpath(dest, "state.tar.zst"))
        check = sqlite_value(joinpath(state, "kb.sqlite3"), "PRAGMA integrity_check")
        check == "ok" || error("The copy's database fails its integrity check: $check")
        files = countlines(joinpath(dest, "files.tsv"))
        bytes = sum(filesize(joinpath(d, f)) for (d, _, fs) in walkdir(dest) for f in fs; init = 0)
        return (; stamp = String(stamp), files, bytes)
    finally
        rm(work; force = true, recursive = true)
    end
end

"The copies off this machine, for the Status page: whether they are on, where they go, and how the last went."
function offsite_json(c::Config)
    o = c.backup.offsite
    s = o.store
    where = isempty(s.store) ? "" : startswith(s.store, "dir:") ? s.store[5:end] : join(filter(!isempty, [s.endpoint, s.bucket, s.prefix]), " · ")
    return merge(Dict{String,Any}(string(k) => v isa String && occursin(r"^\d{4}-\d\d-\d\dT", v) ? v * "Z" : v for (k, v) in pairs(OFFSITE_STATE[])),
                 Dict{String,Any}("enabled" => !isempty(s.store), "where" => where, "every_hours" => o.every_hours, "keep_days" => o.keep_days))
end
