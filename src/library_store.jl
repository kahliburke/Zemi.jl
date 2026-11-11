# Each person's private library: their files (a vault's notes, PDFs) in a space of their own,
# `people/<user id>/` in the site's library store (`[library]`: a folder, by default under the data
# directory, or a bucket). Only the service holds the store's credentials and reads it; a person
# reaches their own space through the API, signed in as themselves (permission `library`), never
# another's. The store is kept apart from the dataset's, which others read (see `validate`), and each
# space is held to `[library] max_gb`. What a space holds is indexed here (`library_files`), so
# listing it, and how much it uses, need not ask the store.

migration!(16, ["""CREATE TABLE library_files (
                       space TEXT NOT NULL,
                       path TEXT NOT NULL,
                       size INTEGER NOT NULL,
                       sha256 TEXT NOT NULL,
                       modified TEXT NOT NULL,
                       PRIMARY KEY (space, path))""",
                # Every role keeps a library, the roles made before there were libraries too.
                """UPDATE roles SET permissions = json_insert(permissions, '\$[#]', 'library')
                   WHERE NOT EXISTS (SELECT 1 FROM json_each(roles.permissions) WHERE value = 'library')"""])

"The store the libraries are kept in: `[library]`'s, or a folder in the data directory."
library_store(c::Config) =
    isempty(c.library.store) ? DirStore(joinpath(c.data_dir, "library")) : open_store(c.library; table = "[library]")

"The most a person's space may hold, in bytes (`[library] max_gb`)."
library_limit(c::Config) = round(Int, c.library_max_gb * 1e9)

"""
    library_space(caller) -> String

The space of the person `caller` is: `people/<user id>`, or `people/local` for whoever runs the
knowledge base on their own machine. Refused for a caller who is no one.
"""
function library_space(caller::Caller)
    caller.via == :local && return "people/local"
    caller.user_id === nothing && not_permitted("A library is a person's: sign in")
    return "people/$(caller.user_id)"
end

"""
    library_path(path) -> String

`path` as a file's place in a space: relative, its parts joined by `/`, none empty, `.` or `..`, no
backslashes or control characters, in Unicode's composed form (as a Mac and Linux would write the
same name differently otherwise), each part at most 255 bytes and the whole at most 1024.
"""
function library_path(path::AbstractString)
    p = Base.Unicode.normalize(String(path), :NFC)
    parts = split(p, '/')
    ok = !isempty(p) && ncodeunits(p) <= 1024 && !occursin('\\', p) && !any(iscntrl, p) &&
         all(s -> !isempty(s) && s != "." && s != ".." && ncodeunits(s) <= 255, parts)
    ok || error("Not a file's place in a library: $(repr(path))")
    return p
end

"What a space holds, as `library_files` indexes it: each file's path, size, SHA-256 and when it last changed, by path."
library_files(kb::KB, space::AbstractString) =
    [(; path = String(r.path), size = Int(r.size), sha256 = String(r.sha256), modified = String(r.modified))
     for r in query(kb, "SELECT path, size, sha256, modified FROM library_files WHERE space = ? ORDER BY path", (space,))]

"How many bytes a space holds."
library_usage(kb::KB, space::AbstractString) = Int(scalar(kb, "SELECT coalesce(sum(size), 0) FROM library_files WHERE space = ?", (space,)))

library_row(kb::KB, space, path) =
    (r = query(kb, "SELECT size, sha256 FROM library_files WHERE space = ? AND path = ?", (space, path)); isempty(r) ? nothing : first(r))

# A change made against `base`, the SHA-256 of the file as the one changing it last saw it (empty for
# none there): refused when the file is otherwise now, so neither side's change is lost.
function check_base(row, base, path)
    base === nothing && return
    now = row === nothing ? "" : row.sha256
    now == base || throw(Refusal(409, "$path has changed since it was read: read it again"))
end

"""
    put_library_file!(kb, space, path, bytes; base = nothing, modified = nothing) -> NamedTuple

Write `bytes` as the file at `path` in `space`, returning its row (see [`library_files`](@ref)):
`modified`, when the file last changed where it came from (a `DateTime`, UTC), else now. With
`base`, only when the file there is the one whose SHA-256 that is (`""`: none is there), else refused
(409). Refused (413) when the space would hold more than its limit.
"""
function put_library_file!(kb::KB, space::AbstractString, path::AbstractString, bytes::AbstractVector{UInt8};
                           base::Union{AbstractString,Nothing} = nothing, modified::Union{DateTime,Nothing} = nothing)
    path = library_path(path)
    row = library_row(kb, space, path)
    check_base(row, base, path)
    sha = bytes2hex(sha256(bytes))
    row !== nothing && row.sha256 == sha && return only(filter(f -> f.path == path, library_files(kb, space)))
    limit = library_limit(kb.config)
    library_usage(kb, space) - (row === nothing ? 0 : row.size) + length(bytes) > limit &&
        throw(Refusal(413, "A library holds at most $(round(limit / 1e9; digits = 1)) GB: remove something first"))
    write_object!(library_store(kb.config), "$space/$path", bytes)
    at = iso(something(modified, now(UTC)))
    execute!(kb, """INSERT INTO library_files (space, path, size, sha256, modified) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (space, path) DO UPDATE SET size = excluded.size, sha256 = excluded.sha256, modified = excluded.modified""",
             (space, path, length(bytes), sha, at))
    return (; path, size = length(bytes), sha256 = sha, modified = at)
end

"The file at `path` in `space`, its bytes, or `nothing` when there is none."
function read_library_file(kb::KB, space::AbstractString, path::AbstractString)
    path = library_path(path)
    library_row(kb, space, path) === nothing && return nothing
    return read_object(library_store(kb.config), "$space/$path")
end

"""
    delete_library_file!(kb, space, path; base = nothing) -> Bool

Remove the file at `path` from `space`, returning whether one was there; with `base`, only when it is
the one whose SHA-256 that is (see [`put_library_file!`](@ref)).
"""
function delete_library_file!(kb::KB, space::AbstractString, path::AbstractString; base::Union{AbstractString,Nothing} = nothing)
    path = library_path(path)
    row = library_row(kb, space, path)
    check_base(row, base, path)
    row === nothing && return false
    delete_object!(library_store(kb.config), "$space/$path")
    execute!(kb, "DELETE FROM library_files WHERE space = ? AND path = ?", (space, path))
    return true
end

"""
    stores_overlap(a, b) -> Bool

Whether stores `a` and `b` (each with `store`, `endpoint`, `bucket` and `prefix`) may hold the same
objects: folders one within the other, or one bucket with prefixes one within the other.
"""
function stores_overlap(a, b)
    (isempty(a.store) || isempty(b.store)) && return false
    adir, bdir = startswith(a.store, "dir:"), startswith(b.store, "dir:")
    adir != bdir && return false
    if adir
        x, y = normpath(expanduser(a.store[5:end])), normpath(expanduser(b.store[5:end]))
        return x == y || within_dir(x, y) || within_dir(y, x)
    end
    same = rstrip(lowercase(a.endpoint), '/') == rstrip(lowercase(b.endpoint), '/') && a.bucket == b.bucket
    p(s) = (s = strip(s, '/'); isempty(s) ? "" : s * "/")
    return same && (startswith(p(a.prefix), p(b.prefix)) || startswith(p(b.prefix), p(a.prefix)))
end

"The library's store as configured, its default a folder in the data directory."
library_store_config(c::Config) =
    isempty(c.library.store) ? StoreConfig(; store = "dir:" * joinpath(c.data_dir, "library")) : c.library

# ── The API: one's own space ──────────────────────────────────────────────────────────────────────

"A file's row, as the API gives it."
library_file_json(f) = Dict("path" => f.path, "size" => f.size, "sha256" => f.sha256, "modified" => f.modified)

# What one's space holds, with how much it uses of its limit.
route!("GET", "/api/library/files"; need = "library") do c
    space = library_space(c.caller)
    Dict("files" => Any[library_file_json(f) for f in library_files(c.kb, space)],
         "used" => library_usage(c.kb, space), "limit" => library_limit(c.kb.config))
end

# A file of one's own, its bytes.
route!("GET", "/api/library/files/*path"; need = "library") do c
    bytes = read_library_file(c.kb, library_space(c.caller), c[:path])
    bytes === nothing && not_found("No file $(c[:path]) in your library")
    HTTP.Response(200, ["Content-Type" => "application/octet-stream", "Cache-Control" => "no-store"], bytes)
end

# A file written, the body its bytes (`?base=<sha256>`: only over that version, empty for none there;
# `?modified=<unix seconds>`: when it last changed where it came from).
route!("PUT", "/api/library/files/*path"; need = "library") do c
    base = haskey(c.params, "base") ? c.params["base"] : nothing
    m = get(c.params, "modified", "")
    modified = isempty(m) ? nothing : unix2datetime(something(tryparse(Float64, m), error("?modified= is a time in seconds since 1970")))
    library_file_json(put_library_file!(c.kb, library_space(c.caller), c[:path], body_bytes(c); base, modified))
end

# A file removed (`?base=<sha256>`: only that version).
route!("DELETE", "/api/library/files/*path"; need = "library") do c
    base = haskey(c.params, "base") ? c.params["base"] : nothing
    Dict("removed" => delete_library_file!(c.kb, library_space(c.caller), c[:path]; base))
end
