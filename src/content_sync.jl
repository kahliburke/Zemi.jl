# The content a group writes (see `content_path`: its pages, studies, notebooks and images), shared
# through the dataset's streams with its documents. A stream carries the content files its member
# changed against the version imported: those created, edited or deleted there (see
# [`content_entries`](@ref)), each file's data an object `content/<hash>` named by its content.
# Importing takes the latest change to each file (see [`content_winner`](@ref)) where the file here
# has not changed since it was imported (or was never here), or the change was made to the file as it
# is here. Otherwise both changed it: the file here stands, and the other version is set aside for a
# person to settle (see [`resolve_conflict!`](@ref)).

"Whether a file is a notebook environment's manifest, which each machine resolves for itself."
env_manifest(f::AbstractString) = occursin(r"^(Julia)?Manifest(-v[\d.]+)?\.toml$", basename(f))

"""
    content_files(config) -> Dict{String,String}

The content's files, as their path in it (with `/`) => the SHA-256 of the file; hidden files and
notebook environments' manifests left out.
"""
function content_files(c::Config)
    root = c.content_dir
    return Dict(join(splitpath(relpath(f, root)), '/') => bytes2hex(open(sha256, f)) for f in tree_files(root) if !env_manifest(f))
end

"Whether `path` can name a content file: relative, within the content, and not hidden."
safe_content_path(path::AbstractString) =
    !isempty(path) && all(p -> !isempty(p) && !startswith(p, "."), split(path, '/')) && !occursin('\\', path)

"What this knowledge base imported of each content file, as path => (; hash, stream); `hash` empty for a file the import deleted."
imported_content(kb::KB) = Dict(r.path => (; r.hash, r.stream) for r in query(kb, "SELECT path, hash, stream FROM content_files"))

"""
    content_entries(kb, before, at) -> Dict{String,Any}

The content files this knowledge base publishes to its stream, as `path => {hash, base, at}`: those it
has other than as it imported them from another stream, and, with `hash` empty, those it deleted.
`base` is the version the change was made to (empty for a file created here), and `at` when the
stream first carried the change: from `before`, the stream's manifest before, or `at`.
"""
function content_entries(kb::KB, before::AbstractDict, at::AbstractString)
    me = stream_name(kb.config)
    files = content_files(kb.config)
    imported = imported_content(kb)
    prev = something(get(before, "content", nothing), Dict{String,Any}())
    out = Dict{String,Any}()
    for path in union(keys(files), keys(imported), keys(prev))
        hash = get(files, path, "")
        i = get(imported, path, nothing)
        if i === nothing || i.stream == me
            hash == "" && !haskey(prev, path) && continue        # (imported from its own stream as deleted)
        else
            i.hash == hash && continue                              # as imported
        end
        was = get(prev, path, nothing)
        base = i !== nothing && i.stream != me ? i.hash : was === nothing ? "" : was["base"]
        same = was !== nothing && was["hash"] == hash && was["base"] == base
        out[path] = Dict("hash" => hash, "base" => base, "at" => same ? was["at"] : at)
    end
    return out
end

"""
    publish_content!(kb, store, streams, before, at) -> Dict

Upload the content files this knowledge base changed (see [`content_entries`](@ref)) that no
stream's manifest (`streams`) names, and return the entries for its stream's manifest.
"""
function publish_content!(kb::KB, store::DatasetStore, streams::AbstractDict, before::AbstractDict, at::AbstractString)
    entries = content_entries(kb, before, at)
    stored = Set(e["hash"] for m in values(streams) for e in values(something(get(m, "content", nothing), Dict())))
    for (path, e) in entries
        (e["hash"] == "" || e["hash"] in stored) && continue
        bytes = read(content_path(kb.config, split(path, '/')...))
        hash = bytes2hex(sha256(bytes))
        hash == e["hash"] || (e["hash"] = hash; e["at"] = at)       # (changed since it was listed)
        write_object!(store, "content/$hash", gzip(bytes))
        push!(stored, hash)
    end
    return entries
end

"""
    import_content!(kb, store, streams; skip = "") -> (; written, removed, conflicts)

Take in the streams' changes to the content (every stream but `skip`, this knowledge base's own):
for each file, the change published last, written or deleted here when the file here is as it was
imported or the change was made to it as it is here, and set aside as a conflict when the file here
changed otherwise (see [`content_conflicts`](@ref)). Returns how many files were written, removed and
set aside.
"""
function import_content!(kb::KB, store::DatasetStore, streams::AbstractDict; skip::AbstractString = "")
    changes = Dict{String,Vector{Tuple{String,Dict{String,Any}}}}()
    for name in sort!(collect(keys(streams))), (path, e) in something(get(streams[name], "content", nothing), Dict())
        name == skip && continue
        safe_content_path(path) || (@warn "The stream $name names a content file outside the content, ignored" path; continue)
        push!(get!(changes, path, []), (name, e))
    end
    latest = Dict(path => content_winner(cs) for (path, cs) in changes)
    files = content_files(kb.config)
    imported = imported_content(kb)
    written, removed, conflicts = 0, 0, 0
    record!(path, hash, stream) = execute!(kb, "INSERT OR REPLACE INTO content_files VALUES (?, ?, ?, ?)", (path, hash, stream, now_iso()))
    for (path, (stream, e)) in latest
        hash, here = e["hash"], get(files, path, "")
        i = get(imported, path, nothing)
        if hash == here
            record!(path, hash, stream)
            execute!(kb, "DELETE FROM content_conflicts WHERE path = ?", (path,))
        elseif i !== nothing && hash == i.hash
            continue                                    # changed here since: this change stands
        elseif (i === nothing ? here == "" : here == i.hash) || e["base"] == here
            file = content_path(kb.config, split(path, '/')...)
            # A folder here where the stream has a file, or a file where it has a folder: neither is
            # put in the other's place.
            if isdir(file) || any(isfile, accumulate((a, b) -> joinpath(a, b), split(dirname(path), '/'); init = kb.config.content_dir))
                @warn "The stream $stream has a file where the content here has a folder, or the other way round; left as it is" path
                continue
            end
            if hash == ""
                rm(file; force = true)
                removed += 1
            else
                bytes = content_object(store, hash)
                mkpath(dirname(file))
                write(file * ".part", bytes)
                mv(file * ".part", file; force = true)
                written += 1
            end
            record!(path, hash, stream)
        else
            isempty(query(kb, "SELECT 1 FROM content_conflicts WHERE path = ? AND stream = ? AND hash = ?", (path, stream, hash))) || continue
            if hash != ""
                stash = joinpath(conflicts_dir(kb.config), hash)
                isfile(stash) || (mkpath(dirname(stash)); write(stash, content_object(store, hash)))
            end
            execute!(kb, "INSERT OR IGNORE INTO content_conflicts VALUES (?, ?, ?, ?, ?, ?)", (path, stream, hash, e["base"], e["at"], now_iso()))
            conflicts += 1
        end
    end
    return (; written, removed, conflicts)
end

"""
    content_winner(changes) -> (stream, entry)

Of the streams' changes to one file, as `(stream, entry)`, the one imported: of those no other change
was made to (a change to the version another carries comes after it), the one published last, then
that of the stream named last.
"""
function content_winner(changes)
    later = Set(e["base"] for (_, e) in changes if e["base"] != "")
    heads = [(n, e) for (n, e) in changes if !(e["hash"] in later) || all(x -> x[2]["hash"] == e["hash"], changes)]
    isempty(heads) && (heads = changes)                      # (changes made to each other: a cycle)
    return last(sort(heads; by = ((n, e),) -> (e["at"], n)))
end

"A content file's data from the store, checked against its hash."
function content_object(store::DatasetStore, hash::AbstractString)
    got = read_object(store, "content/$hash")
    got === nothing && error("The dataset names content/$hash, which is missing")
    bytes = gunzip(got)
    bytes2hex(sha256(bytes)) == hash || error("content/$hash does not match its hash")
    return bytes
end

"Where the versions of content files in conflict are kept, by their hash."
conflicts_dir(c::Config) = joinpath(c.data_dir, "conflicts")

"""
    content_conflicts(kb) -> Vector{NamedTuple}

The content files another member changed while they were changed here too: each with the stream,
the other version's `hash` (empty for a deletion), the version it was changed from (`base`), and
when it was published (`at`).
"""
content_conflicts(kb::KB) = [(; r.path, r.stream, r.hash, r.base, r.at) for r in
                             query(kb, "SELECT path, stream, hash, base, at FROM content_conflicts ORDER BY path, at")]

"""
    resolve_conflict!(kb, path; take, stream = "", hash = "") -> String

Settle the conflicts over a content file. With `take`, another member's version replaces the file
here (or deletes it): the one `stream` and `hash` name, else the one published last; without, the
file here stands, published as a change to that version, which the other members then take. Every
conflict over the file is settled either way. Returns what was done, for people.
"""
function resolve_conflict!(kb::KB, path::AbstractString; take::Bool, stream::AbstractString = "", hash::AbstractString = "")
    rows = content_conflicts(kb)
    filter!(r -> r.path == path, rows)
    isempty(rows) && not_found("No conflict over $path")
    chosen = isempty(stream) ? rows : filter(r -> r.stream == stream && r.hash == hash, rows)
    isempty(chosen) && not_found("No conflict over $path with $stream's version")
    r = last(chosen)
    file = content_path(kb.config, split(path, '/')...)
    if take
        if r.hash == ""
            rm(file; force = true)
        else
            mkpath(dirname(file))
            cp(joinpath(conflicts_dir(kb.config), r.hash), file; force = true)
        end
    end
    transaction(kb) do
        execute!(kb, "INSERT OR REPLACE INTO content_files VALUES (?, ?, ?, ?)", (path, r.hash, r.stream, now_iso()))
        execute!(kb, "DELETE FROM content_conflicts WHERE path = ?", (path,))
    end
    used = Set(x.hash for x in content_conflicts(kb))
    for x in rows
        x.hash == "" || x.hash in used || rm(joinpath(conflicts_dir(kb.config), x.hash); force = true)
    end
    return take ? "$path is now $(r.stream)'s version." : "$path stands as it is here; the next publish gives it to the others."
end
