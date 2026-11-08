# Snapshots of a knowledge base (`[backup]`, see `BackupConfig`), to put back what can't be rebuilt
# as it was at some hour. In the backups folder:
#
#   snapshots/<UTC time>/   taken every `every_hours`, thinned by age (see `thin_backups!`)
#   kept/<name>/            taken by name (before a migration, a restore, or when asked), kept until deleted
#
# Each holds `state.tar.zst` (the database, the config folder, the content and the records),
# `files/` (uploads, and with `files` the PDFs and figures, each hard-linked to the last snapshot's
# copy when unchanged, so an unchanged file takes no more space), `files.tsv` (what `files/` holds:
# path, size and modification time) and `snapshot.toml`. Left out, as they are rebuilt: the site,
# cloned codebases, Kaimon's index and the vectors.

"The data folder's own files and folders a snapshot's state holds, besides the database and the content."
const BACKUP_STATE_ITEMS = ("records", "landscape.json", "dataset-profile.json", "local_key", "push_key")

"The data folder's folders of files a snapshot copies: uploads always; with `[backup] files`, PDFs and figures too."
backup_file_dirs(c::Config) = c.backup.files ? ["media", "pdfs", "figures", "daily"] : ["media"]

const BACKUP_LOCK = ReentrantLock()

"""
What the backups last did, for the Status page (see [`backup_json`](@ref)): when the last snapshot
was taken and how long it took, the last failure while none has succeeded since, and the backups as
last counted.
"""
const BACKUP_STATE = Ref((; ok_at = "", seconds = 0.0, error = "", error_at = "", latest = "", count = 0, kept = 0, bytes = 0))

backup_stamp(t::DateTime) = Dates.format(t, dateformat"yyyymmdd\THHMMSS\Z")
parse_backup_stamp(s::AbstractString) =
    occursin(r"^\d{8}T\d{6}Z$", s) ? DateTime(s[1:end-1], dateformat"yyyymmdd\THHMMSS") : nothing

"Make the backups folder, readable only by its owner: a snapshot holds the config, and its secrets."
function backup_root(c::Config)
    root = backup_dir(c)
    for d in (root, joinpath(root, "snapshots"), joinpath(root, "kept"))
        mkpath(d)
    end
    Sys.isunix() && chmod(root, 0o700)
    return root
end

"""
    snapshot!(config; keep = "", at = now(UTC)) -> String

Take a snapshot of the knowledge base `config` names, returning its folder: one of the hourly ones,
or with `keep`, one kept by that name until deleted. The database is copied as of one moment while
it is written to, and checked. Refused when the disk has less than `[backup] min_free_gb` free.
"""
function snapshot!(c::Config; keep::AbstractString = "", at::DateTime = now(UTC))
    isfile(db_path(c)) || error("No database at $(db_path(c)) to back up")
    isempty(keep) || occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", keep) ||
        error("A kept snapshot's name is letters, digits, dots, dashes and underscores: $keep")
    lock(BACKUP_LOCK) do
        root = backup_root(c)
        free = Base.Filesystem.diskstat(root).available / 1e9
        free < c.backup.min_free_gb &&
            error("Only $(round(free; digits = 1)) GB free where the backups go ($root), less than [backup] min_free_gb = $(c.backup.min_free_gb)")
        final = isempty(keep) ? joinpath(root, "snapshots", backup_stamp(at)) : joinpath(root, "kept", keep)
        ispath(final) && error("There is a snapshot $(basename(final)) already")
        previous = latest_snapshot(c)
        part = final * ".part"
        rm(part; force = true, recursive = true)
        mkpath(part)
        try
            stage = joinpath(part, "state")
            mkpath(stage)
            copy_database(db_path(c), joinpath(stage, "kb.sqlite3"))
            schema = parse(Int, coalesce(sqlite_value(joinpath(stage, "kb.sqlite3"), "SELECT value FROM kv WHERE key = 'schema_version'"), "0"))
            conf = dirname(config_path())
            if isdir(conf)
                mkpath(joinpath(stage, "config"))
                # A file the service can't read there (another user's) is left out, not the snapshot.
                for f in readdir(conf)
                    path = joinpath(conf, f)
                    isfile(path) && !islink(path) || continue
                    try
                        cp(path, joinpath(stage, "config", f))
                    catch e
                        e isa Base.IOError || e isa SystemError || rethrow()
                        @warn "The snapshot leaves out $path, which can't be read" exception = e maxlog = 1
                    end
                end
            end
            isdir(c.content_dir) && cp(c.content_dir, joinpath(stage, "content"))
            for x in BACKUP_STATE_ITEMS
                ispath(joinpath(c.data_dir, x)) && cp(joinpath(c.data_dir, x), joinpath(stage, x))
            end
            open(joinpath(part, "state.tar.zst"), "w") do io
                z = ZstdCompressorStream(io; level = 10)
                Tar.create(stage, z)
                close(z)
            end
            rm(stage; recursive = true)
            dirs = copy_files!(c, part, previous)
            open(joinpath(part, "snapshot.toml"), "w") do io
                TOML.print(io, Dict("at" => string(at) * "Z", "schema" => schema, "data_dir" => c.data_dir,
                                    "content_dir" => c.content_dir, "config" => config_path(), "files" => dirs))
            end
            mv(part, final)
        catch
            rm(part; force = true, recursive = true)
            rethrow()
        end
        return final
    end
end

"The names of the files packed in snapshot `snap`'s state (its database, config, content and records)."
packed_names(snap::AbstractString) =
    open(io -> [basename(rstrip(h.path, '/')) for h in Tar.list(ZstdDecompressorStream(io))], joinpath(snap, "state.tar.zst"))

"Copy database `from` to `to` as of one moment, with SQLite's `VACUUM INTO`, while others write to it; then check the copy."
function copy_database(from::AbstractString, to::AbstractString)
    db = SQLite.DB(from)
    try
        DBInterface.close!(DBInterface.execute(db, "PRAGMA busy_timeout = 60000"))
        DBInterface.close!(DBInterface.execute(db, "VACUUM INTO '$(replace(to, "'" => "''"))'"))
    finally
        SQLite.close(db)
    end
    check = sqlite_value(to, "PRAGMA integrity_check")
    check == "ok" || error("The database's copy failed its integrity check: $check")
    return to
end

"The first value `sql` gives on database file `path`, or `missing`."
function sqlite_value(path::AbstractString, sql::AbstractString)
    db = SQLite.DB(path)
    try
        r = rows(db, sql, ())
        return isempty(r) ? missing : first(values(first(r)))
    catch e
        e isa SQLite.SQLiteException && occursin("no such table", sprint(showerror, e)) && return missing
        rethrow()
    finally
        SQLite.close(db)
    end
end

"""
Copy the data folder's folders of files (see [`backup_file_dirs`](@ref)) into snapshot `dest`'s
`files/`, each file hard-linked to `previous`'s copy when its size and modification time are those
`previous` recorded; returning the folders copied.
"""
function copy_files!(c::Config, dest::AbstractString, previous)
    before = Dict{String,Tuple{Int,Float64}}()
    if previous !== nothing && isfile(joinpath(previous, "files.tsv"))
        for l in eachline(joinpath(previous, "files.tsv"))
            p = split(l, '\t')
            length(p) == 3 && (before[p[1]] = (parse(Int, p[2]), parse(Float64, p[3])))
        end
    end
    dirs = String[]
    open(joinpath(dest, "files.tsv"), "w") do manifest
        for d in backup_file_dirs(c)
            src = joinpath(c.data_dir, d)
            isdir(src) || continue
            push!(dirs, d)
            mkpath(joinpath(dest, "files", d))
            for (dir, _, files) in walkdir(src), f in files
                path = joinpath(dir, f)
                st = lstat(path)
                isfile(st) || continue
                rel = join(splitpath(relpath(path, c.data_dir)), '/')
                to = joinpath(dest, "files", rel)
                mkpath(dirname(to))
                linked = get(before, rel, nothing) == (Int(st.size), st.mtime) &&
                         (try hardlink(joinpath(previous, "files", rel), to); true catch; false end)
                linked || cp(path, to)
                println(manifest, rel, '\t', st.size, '\t', st.mtime)
            end
        end
    end
    return dirs
end

"""
    backups(config) -> Vector{NamedTuple}

The snapshots in the backups folder, the latest first: each `(; name, path, kept, at, schema,
state_bytes)`, `at` when it was taken (UTC), `state_bytes` the size of its database, config and
content, packed.
"""
function backups(c::Config)
    root = backup_dir(c)
    out = NamedTuple[]
    for (sub, kept) in (("snapshots", false), ("kept", true))
        dir = joinpath(root, sub)
        isdir(dir) || continue
        for name in readdir(dir)
            path = joinpath(dir, name)
            isfile(joinpath(path, "snapshot.toml")) || continue
            meta = try TOML.parsefile(joinpath(path, "snapshot.toml")) catch; Dict{String,Any}() end
            at = something(parse_backup_stamp(name), tryparse(DateTime, rstrip(string(get(meta, "at", "")), 'Z')), DateTime(0))
            push!(out, (; name, path, kept, at, schema = Int(get(meta, "schema", 0)),
                          state_bytes = filesize(joinpath(path, "state.tar.zst"))))
        end
    end
    return sort!(out; by = b -> b.at, rev = true)
end

"The latest of the hourly snapshots, by its folder, or `nothing`."
function latest_snapshot(c::Config)
    dir = joinpath(backup_dir(c), "snapshots")
    isdir(dir) || return nothing
    names = sort!(filter(n -> parse_backup_stamp(n) !== nothing && isfile(joinpath(dir, n, "snapshot.toml")), readdir(dir)))
    return isempty(names) ? nothing : joinpath(dir, last(names))
end

"How much room the backups take: each file once, however many snapshots link to it."
function backups_bytes(c::Config)
    seen = Set{Tuple{UInt,UInt}}()
    total = 0
    root = backup_dir(c)
    isdir(root) || return 0
    for (dir, _, files) in walkdir(root), f in files
        st = lstat(joinpath(dir, f))
        isfile(st) || continue
        (st.device, st.inode) in seen && continue
        push!(seen, (st.device, st.inode))
        total += st.size
    end
    return total
end

"""
    thin_backups!(config; at = now(UTC)) -> Vector{String}

Delete the hourly snapshots past what `[backup]` keeps, returning their names: every one younger than
`keep_all_hours`; then the latest in each 12 hours younger than `keep_half_daily_days`, the latest in
each day younger than `keep_daily_days`, and none older. Past `max_gb`, the oldest go too, all but the
latest. Kept snapshots stay.
"""
function thin_backups!(c::Config; at::DateTime = now(UTC))
    b = c.backup
    lock(BACKUP_LOCK) do
        hourly = filter(s -> !s.kept, backups(c))               # the latest first
        seen = Set{Tuple{Symbol,Int}}()
        gone = String[]
        drop(s) = (rm(s.path; recursive = true, force = true); push!(gone, s.name))
        left = NamedTuple[]
        for s in hourly
            hours = (at - s.at) / Hour(1)
            unix = floor(Int, datetime2unix(s.at))
            bucket = hours < b.keep_all_hours ? nothing :
                     hours < 24 * b.keep_half_daily_days ? (:half, unix ÷ 43200) :
                     hours < 24 * b.keep_daily_days ? (:day, unix ÷ 86400) : (:gone, 0)
            if bucket !== nothing && (bucket[1] == :gone || bucket in seen)
                drop(s)
            else
                bucket === nothing || push!(seen, bucket)
                push!(left, s)
            end
        end
        if b.max_gb > 0
            while length(left) > 1 && backups_bytes(c) > b.max_gb * 1e9
                drop(pop!(left))                                # the oldest
            end
        end
        return gone
    end
end

"Whether an hourly snapshot is due: none taken `every_hours`, and none failed in the last ten minutes."
function backup_due(c::Config; at::DateTime = now(UTC))
    s = BACKUP_STATE[]
    !isempty(s.error_at) && at - DateTime(s.error_at) < Minute(10) && return false
    latest = latest_snapshot(c)
    latest === nothing && return true
    return (at - parse_backup_stamp(basename(latest))) / Hour(1) >= c.backup.every_hours - 1 / 60
end

"""
    backup!(config; keep = "") -> String

Take a snapshot (see [`snapshot!`](@ref)) and thin the hourly ones (see [`thin_backups!`](@ref)),
noting how it went for the Status page; returning the snapshot's folder.
"""
function backup!(c::Config; keep::AbstractString = "")
    started = time()
    try
        path = snapshot!(c; keep)
        thin_backups!(c)
        BACKUP_STATE[] = (; BACKUP_STATE[]..., ok_at = string(now(UTC)), seconds = round(time() - started; digits = 1), error = "", error_at = "")
        count_backups!(c)
        @info "Backed up the knowledge base to $path"
        return path
    catch e
        BACKUP_STATE[] = (; BACKUP_STATE[]..., error = failure_message(e), error_at = string(now(UTC)))
        rethrow()
    end
end

"Count the backups again, for the Status page."
function count_backups!(c::Config)
    all = backups(c)
    hourly = filter(s -> !s.kept, all)
    BACKUP_STATE[] = (; BACKUP_STATE[]..., latest = isempty(all) ? "" : string(first(all).at), count = length(hourly),
                        kept = length(all) - length(hourly), bytes = backups_bytes(c))
end

"The backups, for the Status page: whether they are on, where they go, and what [`BACKUP_STATE`](@ref) last noted (its times UTC)."
backup_json(c::Config) = merge(Dict{String,Any}(string(k) => v isa String && occursin(r"^\d{4}-", v) ? v * "Z" : v for (k, v) in pairs(BACKUP_STATE[])),
                               Dict{String,Any}("enabled" => c.backup.enabled, "dir" => backup_dir(c), "every_hours" => c.backup.every_hours))

"""
    follow_backups(kb) -> Task

The service's backups: each minute, while `[backup] enabled`, a snapshot when one is due (see
[`backup_due`](@ref)). The config is read each time, so reloading it takes effect.
"""
function follow_backups(kb::KB)
    try count_backups!(kb.config) catch e; @warn "Could not count the backups" exception = e end
    return every!("Backing up the knowledge base"; seconds = 60) do
        c = kb.config
        c.backup.enabled && backup_due(c) && backup!(c)
    end
end

"""
    backup_before_migrating(kb, version, latest)

Before the database is migrated from schema `version` to `latest`, a snapshot kept by the name
`before-schema-<latest>`, while `[backup] enabled`. A new database has nothing to keep.
"""
function backup_before_migrating(kb::KB, version::Integer, latest::Integer)
    (0 < version < latest && kb.config.backup.enabled) || return nothing
    name = "before-schema-$latest"
    isdir(joinpath(backup_dir(kb.config), "kept", name)) && (name *= "-" * backup_stamp(now(UTC)))
    try
        path = backup!(kb.config; keep = name)
        @info "Before migrating the database from schema $version to $latest, kept a snapshot: $path"
    catch e
        @error "Could not back up the database before migrating it from schema $version to $latest" exception = e
    end
    return nothing
end

"Find a snapshot by its name, or its folder."
function find_backup(c::Config, name::AbstractString)
    isfile(joinpath(name, "snapshot.toml")) && return abspath(name)
    for sub in ("kept", "snapshots")
        path = joinpath(backup_dir(c), sub, name)
        isfile(joinpath(path, "snapshot.toml")) && return path
    end
    not_found("No snapshot $name in $(backup_dir(c))")
end

"Delete kept snapshot `name`."
function delete_backup!(c::Config, name::AbstractString)
    path = joinpath(backup_dir(c), "kept", name)
    (occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", name) && isfile(joinpath(path, "snapshot.toml"))) || not_found("No kept snapshot $name")
    lock(() -> rm(path; recursive = true), BACKUP_LOCK)
    count_backups!(c)
    return nothing
end

"""
    restore_backup!(config, name; config_files = false) -> String

Put snapshot `name` (see [`find_backup`](@ref)) back into the data folder of the knowledge base
`config` names, which must not be running: its database, content, records and files, and with
`config_files` its config folder's files. What was there is first kept as a snapshot
`before-restore-<time>`, whose name is returned (`""` with no database to keep). Run as root, what is
put back is given the data folder's owner.
"""
function restore_backup!(c::Config, name::AbstractString; config_files::Bool = false)
    snap = find_backup(c, name)
    meta = TOML.parsefile(joinpath(snap, "snapshot.toml"))
    before = isfile(db_path(c)) ? basename(backup!(c; keep = "before-restore-" * backup_stamp(now(UTC)))) : ""
    mkpath(c.data_dir)
    work = mktempdir(dirname(rstrip(normpath(abspath(c.data_dir)), ['/', '\\'])))
    try
        state = joinpath(work, "state")
        open(io -> Tar.extract(ZstdDecompressorStream(io), state), joinpath(snap, "state.tar.zst"))
        put(from, to) = (rm(to; force = true, recursive = true); ispath(from) && mv(from, to))
        for f in ("kb.sqlite3-wal", "kb.sqlite3-shm")
            rm(joinpath(c.data_dir, f); force = true)
        end
        put(joinpath(state, "kb.sqlite3"), db_path(c))
        put(joinpath(state, "content"), c.content_dir)
        for x in BACKUP_STATE_ITEMS
            put(joinpath(state, x), joinpath(c.data_dir, x))
        end
        if config_files && isdir(joinpath(state, "config"))
            conf = dirname(config_path())
            mkpath(conf)
            for f in readdir(joinpath(state, "config"))
                cp(joinpath(state, "config", f), joinpath(conf, f); force = true)
            end
        end
        for d in get(meta, "files", String[])
            to = joinpath(c.data_dir, d)
            rm(to; force = true, recursive = true)
            cp(joinpath(snap, "files", d), to)
        end
        Sys.isunix() && ccall(:getuid, Cuint, ()) == 0 && give_owner(c)
    finally
        rm(work; force = true, recursive = true)
    end
    return before
end

"Give what a restore put back the owner of the data folder, as when run as root for a service's user."
function give_owner(c::Config)
    st = stat(c.data_dir)
    paths = [db_path(c), c.content_dir, (joinpath(c.data_dir, x) for x in BACKUP_STATE_ITEMS)...,
             (joinpath(c.data_dir, d) for d in ("media", "pdfs", "figures", "daily"))...]
    for p in paths
        ispath(p) || continue
        chown(p, st.uid, st.gid)
        isdir(p) || continue
        for (dir, ds, fs) in walkdir(p), x in [ds; fs]
            chown(joinpath(dir, x), st.uid, st.gid)
        end
    end
end
