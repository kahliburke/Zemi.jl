# Where a dataset, or the backup of the files people attach, is kept: a directory, or an
# S3-compatible bucket (see s3.jl). Each store reads, writes, lists and deletes objects by key.

abstract type DatasetStore end

"A dataset in a directory: for tests, and for a drive shared some other way."
struct DirStore <: DatasetStore
    dir::String
end

function read_object(s::DirStore, key::AbstractString)
    f = joinpath(s.dir, key)
    return isfile(f) ? read(f) : nothing
end
has_object(s::DirStore, key::AbstractString) = isfile(joinpath(s.dir, key))
function list_objects(s::DirStore, prefix::AbstractString; modified::Bool = false)
    root = joinpath(s.dir, prefix)
    isdir(root) || return modified ? Pair{String,DateTime}[] : String[]
    keys = [prefix * join(splitpath(relpath(joinpath(d, f), root)), '/') for (d, _, fs) in walkdir(root) for f in fs
            if !endswith(f, ".part")]
    return modified ? [k => unix2datetime(mtime(joinpath(s.dir, k))) for k in keys] : keys
end
delete_object!(s::DirStore, key::AbstractString) = rm(joinpath(s.dir, key); force = true)
function write_object!(s::DirStore, key::AbstractString, bytes::AbstractVector{UInt8}; content_type = "",
                       progress = (sent, total) -> nothing)
    f = joinpath(s.dir, key)
    mkpath(dirname(f))
    write(f * ".part", bytes)
    mv(f * ".part", f; force = true)
    progress(length(bytes), length(bytes))
    return nothing
end

"""
    open_store(s::StoreConfig; table) -> DatasetStore

The store `s` names; `table`, the config table it came from, for the errors.
"""
function open_store(d::StoreConfig; table::AbstractString)
    startswith(d.store, "dir:") && return DirStore(expanduser(d.store[5:end]))
    d.store in ("s3", "r2") || error("$table store must be \"dir:<path>\" or \"s3\", got \"$(d.store)\"")
    (isempty(d.endpoint) || isempty(d.bucket)) && error("$table needs an endpoint and a bucket")
    isfile(d.credentials) || error("$table credentials: no file at $(d.credentials)")
    creds = TOML.parsefile(d.credentials)
    key, secret = get(creds, "access_key_id", ""), get(creds, "secret_access_key", "")
    (isempty(key) || isempty(secret)) && error("$table credentials: $(d.credentials) needs access_key_id and secret_access_key")
    return S3Store(d.endpoint, d.bucket, d.prefix, d.region, key, secret)
end

gzip(bytes) = transcode(GzipCompressor, bytes)
gunzip(bytes) = transcode(GzipDecompressor, bytes)
