# Files people and agents put into what they write (images, movies, code, documents): kept by their
# content under the data directory's media/, each recorded in `media`, and named in text by the
# address `media/<hash>/<name>`, the same in the service, on a published site and in a downloaded
# knowledge base (kbMarkdown.ts resolves it to wherever files are served). Files nothing refers to
# are swept after a while. With `[media.backup]` configured, every file is also copied to a private
# store, and a file missing from disk is restored from it.

media_dir(c::Config) = joinpath(c.data_dir, "media")
media_path(c::Config, hash::AbstractString) = joinpath(media_dir(c), hash[1:2], hash)

const MEDIA_TYPES = Dict(
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp",
    ".svg" => "image/svg+xml", ".mp4" => "video/mp4", ".webm" => "video/webm", ".mov" => "video/quicktime",
    ".pdf" => "application/pdf", ".json" => "application/json", ".csv" => "text/csv; charset=utf-8",
    ".html" => "text/html; charset=utf-8", ".zip" => "application/zip")
const TEXT_EXTENSIONS = (".txt", ".md", ".jl", ".py", ".toml", ".yaml", ".yml", ".sh", ".c", ".h", ".cpp", ".f90", ".m", ".tex",
                         ".js", ".ts", ".vue", ".css", ".r", ".rs", ".log")

"The type a file named `name` is served as, from its extension."
function media_type(name::AbstractString)
    ext = lowercase(splitext(name)[2])
    return ext in TEXT_EXTENSIONS ? "text/plain; charset=utf-8" : get(MEDIA_TYPES, ext, "application/octet-stream")
end

"`name` as it goes in an address: its last part, letters, digits, `.`, `_` and `-` only."
function media_name(name::AbstractString)
    n = replace(basename(replace(strip(name), '\\' => '/')), r"[^A-Za-z0-9._-]+" => "-")
    n = strip(n, ['-', '.'])
    return isempty(n) ? "file" : first(n, 120)
end

const MEDIA_ADDRESS = r"media/([0-9a-f]{64})/([A-Za-z0-9._-]+)"

"""
    add_media!(kb, bytes, name; by, user = nothing, project = nothing) -> NamedTuple

Keep file `bytes`, named `name`, attached by `by` (and their account, `user`, where they have one)
in `project` (its key) where given, and return `(; hash,
name, type, size, address)`, `address` what text refers to it by. The same content added again is
kept once, and belongs to each project it was attached in. Refused beyond the configured size
(`[media] max_mb`).
"""
function add_media!(kb::KB, bytes::AbstractVector{UInt8}, name::AbstractString; by::AbstractString,
                    user::Union{Integer,Nothing} = nothing, project::Union{AbstractString,Nothing} = nothing)
    max = kb.config.media_max_mb * 1024^2
    length(bytes) > max && throw(Refusal(413, "$(media_name(name)) is $(round(length(bytes) / 1024^2; digits = 1)) MB; files here are at most $(kb.config.media_max_mb) MB"))
    isempty(bytes) && error("$(media_name(name)) is empty")
    hash = bytes2hex(sha256(bytes))
    name, type = media_name(name), media_type(name)
    path = media_path(kb.config, hash)
    if !isfile(path)
        mkpath(dirname(path))
        tmp = path * ".part"
        write(tmp, bytes)
        mv(tmp, path; force = true)
    end
    execute!(kb, "INSERT OR IGNORE INTO media (hash, name, type, size, added_by, added_at, added_by_user) VALUES (?, ?, ?, ?, ?, ?, ?)",
             (hash, name, type, length(bytes), by, now_iso(), something(user, missing)))
    project === nothing || belongs!(kb, hash, project)
    back_up_soon(kb, hash)
    return (; hash, name, type, size = length(bytes), address = "media/$hash/$name")
end

belongs!(kb::KB, hash::AbstractString, project::AbstractString) =
    execute!(kb, "INSERT OR IGNORE INTO media_projects SELECT ?, id FROM projects WHERE key = ?", (hash, uppercase(strip(project))))

"""
    media_visible(kb, caller, hash) -> Bool

Whether `caller` may have file `hash`: it belongs to a project they see, or their account attached
it. Run for one person, every file is theirs.
"""
function media_visible(kb::KB, caller::Caller, hash::AbstractString)
    caller.via == :local && return true
    media_file(kb, hash) === nothing && return false
    caller.user_id === nothing || scalar(kb, "SELECT added_by_user FROM media WHERE hash = ?", (hash,)) === caller.user_id && return true
    return any(r -> project_access(kb, caller, String(r.key)) >= VIEW,
               query(kb, "SELECT p.key FROM media_projects m JOIN projects p ON p.id = m.project_id WHERE m.hash = ?", (hash,)))
end

"Who is writing: the person a request or tool call is for, or `nothing` for the knowledge base's own work."
writer() = something(get(task_local_storage(), :kb_caller, nothing), mcp_caller(), agent_caller(), Some(nothing))

"""
    use_media!(kb, project, texts...; record = true)

Text in `project` (its key) uses the files it names: each then belongs to the project too. The
writer must be one who may have each (see [`media_visible`](@ref)), so a file of one project reaches
another only through someone in both; refused otherwise, before anything is written. With `record
= false`, only that check.
"""
function use_media!(kb::KB, project::AbstractString, texts...; record::Bool = true)
    hashes = unique(String(m[1]) for t in texts if t !== nothing for m in eachmatch(MEDIA_ADDRESS, string(t)))
    isempty(hashes) && return nothing
    who = writer()
    for h in hashes
        media_file(kb, h) === nothing && continue          # not a file here: only text
        who === nothing || media_visible(kb, who, h) || not_permitted("Not permitted: media/$h/… is a file of a project you're not in")
    end
    record && foreach(h -> media_file(kb, h) === nothing || belongs!(kb, h, project), hashes)
    return nothing
end

"File `hash`'s record, `(; hash, name, type, size, added_by, added_at)`, or `nothing`."
function media_file(kb::KB, hash::AbstractString)
    occursin(r"^[0-9a-f]{64}$", hash) || return nothing
    rows = query(kb, "SELECT * FROM media WHERE hash = ?", (hash,))
    isempty(rows) ? nothing : (r = first(rows); (; hash = String(r.hash), name = String(r.name), type = String(r.type),
                                                   size = Int(r.size), added_by = String(r.added_by), added_at = String(r.added_at)))
end

"""
The response serving file `hash` as `name`: its type, kept for good (an address never changes what
it names), pages and SVG sandboxed so their scripts cannot run here, and kinds a browser does not
show offered as downloads.
"""
function media_response(kb::KB, hash::AbstractString, name::AbstractString)
    f = media_file(kb, hash)
    path = f === nothing ? "" : media_path(kb.config, hash)
    f !== nothing && !isfile(path) && restore_media!(kb, hash)
    (f === nothing || !isfile(path)) && return HTTP.Response(404, ["Content-Type" => "text/plain"], "No such file.")
    type = media_type(name) == "application/octet-stream" ? f.type : media_type(name)
    headers = ["Content-Type" => type, "X-Content-Type-Options" => "nosniff", "Cache-Control" => "private, max-age=31536000, immutable"]
    (startswith(type, "text/html") || startswith(type, "image/svg")) && push!(headers, "Content-Security-Policy" => "sandbox")
    shown = startswith(type, "image/") || startswith(type, "video/") || startswith(type, "text/") || type == "application/pdf"
    shown || push!(headers, "Content-Disposition" => "attachment; filename=\"$(media_name(name))\"")
    return HTTP.Response(200, headers, read(path))
end

# A file, to those who may have it: as no file, to anyone else.
route!("GET", "/api/media/:hash/:name"; need = "tasks.view") do c
    media_visible(c.kb, c.caller, c[:hash]) || return HTTP.Response(404, ["Content-Type" => "text/plain"], "No such file.")
    media_response(c.kb, c[:hash], c[:name])
end

# Attach a file: its bytes the body, its name `?name=`. In a project (`?project=`), by someone who
# works in it (see media_visible).
route!("POST", "/api/media"; need = "tasks.edit") do c
    project = get(c.params, "project", "")
    isempty(project) || need_project!(c.kb, c.caller, project, CONTRIBUTE)
    Dict(pairs(add_media!(c.kb, body_bytes(c), get(c.params, "name", "file"); by = caller_name(c.caller), user = c.caller.user_id,
                          project = isempty(project) ? nothing : project)))
end

"""
    media_in_use(kb) -> Set{String}

The files text refers to: in task titles and plans, notes and their earlier versions, project and
milestone descriptions, and findings (their write-ups, earlier versions and evidence).
"""
function media_in_use(kb::KB)
    used = Set{String}()
    for sql in ("SELECT title || ' ' || body AS text FROM tasks", "SELECT text FROM task_events", "SELECT text FROM task_note_edits",
                "SELECT description AS text FROM projects", "SELECT description AS text FROM milestones",
                "SELECT claim || ' ' || body || ' ' || status_reason AS text FROM findings",
                "SELECT claim || ' ' || body || ' ' || status_reason AS text FROM finding_versions",
                "SELECT target || ' ' || excerpt || ' ' || note AS text FROM finding_evidence",
                "SELECT text || ' ' || earlier AS text FROM finding_comments")
        for r in query(kb, "SELECT * FROM ($sql) WHERE text LIKE '%media/%'")
            foreach(m -> push!(used, m[1]), eachmatch(MEDIA_ADDRESS, coalesce(r.text, "")))
        end
    end
    return used
end

"""
    sweep_media!(kb; grace = Day(7), now = now(UTC)) -> Int

Forget the files nothing refers to (see [`media_in_use`](@ref)) that were added more than `grace`
ago, a file being written about before it is referred to. Returns how many were removed.
"""
function sweep_media!(kb::KB; grace::Period = Day(7), now::DateTime = Dates.now(UTC))
    used = media_in_use(kb)
    cutoff = iso(now - grace)
    gone = [String(r.hash) for r in query(kb, "SELECT hash FROM media WHERE added_at < ?", (cutoff,)) if !(r.hash in used)]
    store = media_backup(kb.config)
    for h in gone
        rm(media_path(kb.config, h); force = true)
        execute!(kb, "DELETE FROM media WHERE hash = ?", (h,))
        store === nothing || try delete_object!(store, media_key(h)) catch e
            @warn "The backup of a removed file could not be deleted; the next sweep tries again" hash = h exception = e
        end
    end
    return length(gone)
end

"For a running service: now and every few hours, sweep unused files and bring the backup up to date."
function follow_media(kb::KB; every::Real = 6 * 3600)
    every!("Sweeping and backing up files"; seconds = every) do
        n = sweep_media!(kb)
        n > 0 && @info "Removed $n file(s) nothing refers to"
        b = sync_media_backup!(kb)
        b.uploaded + b.restored > 0 && @info "Files backed up: $(b.uploaded); restored from the backup: $(b.restored)"
        b.lost > 0 && @warn "$(b.lost) file(s) are missing from disk and from the backup"
    end
    return nothing
end

# ── The backup ────────────────────────────────────────────────────────────────────────────────────

"The store files are backed up to (`[media.backup]`), or `nothing` when none is configured."
media_backup(c::Config) = isempty(c.media_backup.store) ? nothing : open_store(c.media_backup; table = "[media.backup]")

"A file's key in the backup: its content's hash."
media_key(hash::AbstractString) = "media/$hash"

"""
Copy file `hash` to the backup in the background, if there is one. A copy that fails is made by the
next catch-up (see [`sync_media_backup!`](@ref)).
"""
function back_up_soon(kb::KB, hash::AbstractString)
    store = media_backup(kb.config)
    store === nothing && return nothing
    return Threads.@spawn try
        write_object!(store, media_key(hash), read(media_path(kb.config, hash)); content_type = "application/octet-stream")
    catch e
        @warn "A file could not be backed up; the next catch-up tries again" hash exception = e
    end
end

"""
    restore_media!(kb, hash; store = media_backup(kb.config)) -> Bool

Fetch file `hash` from the backup onto disk, checked against its hash. Whether it was.
"""
function restore_media!(kb::KB, hash::AbstractString; store = media_backup(kb.config))
    store === nothing && return false
    bytes = try read_object(store, media_key(hash)) catch e
        @warn "A file could not be fetched from the backup" hash exception = e
        nothing
    end
    (bytes === nothing || bytes2hex(sha256(bytes)) != hash) && return false
    path = media_path(kb.config, hash)
    mkpath(dirname(path))
    write(path * ".part", bytes)
    mv(path * ".part", path; force = true)
    return true
end

"""
    sync_media_backup!(kb; store = media_backup(kb.config)) -> (; uploaded, restored, lost)

Bring the disk and the backup together: upload each recorded file the backup lacks, and restore
each one missing from disk that the backup has. `lost` counts those that are in neither.
"""
function sync_media_backup!(kb::KB; store = media_backup(kb.config))
    store === nothing && return (; uploaded = 0, restored = 0, lost = 0)
    backed = Set(list_objects(store, "media/"))
    uploaded = restored = lost = 0
    for r in query(kb, "SELECT hash FROM media")
        hash = String(r.hash)
        path = media_path(kb.config, hash)
        if isfile(path)
            media_key(hash) in backed && continue
            write_object!(store, media_key(hash), read(path); content_type = "application/octet-stream")
            uploaded += 1
        elseif media_key(hash) in backed && restore_media!(kb, hash; store)
            restored += 1
        else
            lost += 1
        end
    end
    return (; uploaded, restored, lost)
end

# ── Uploading from elsewhere ──────────────────────────────────────────────────────────────────────
# An agent on another machine cannot hand the service a path, and a file sent inside a tool call
# passes through the model, which has to reproduce every byte. Instead it asks for an upload link
# (`media_upload`) and sends the file to it itself (`curl -T plot.png <link>`): the bytes go
# straight to the service, which keeps them as it keeps any attached file.

"How long an upload link stays usable, in minutes."
const UPLOAD_MINUTES = 30

struct Upload
    by::Actor                              # who the file is attached as
    user::Union{Int,Nothing}               # their person's account
    ref::String                            # a task, a finding or a project
    project::String
    name::String
    caption::String
    post::Bool                             # posted to the task's activity once it arrives
    expires::DateTime
end

const UPLOADS = Dict{String,Upload}()
const UPLOADS_LOCK = ReentrantLock()

"""
    upload_link!(ref; name, caption = "", post = true, by, user = nothing) -> String

A link, usable once in the next `UPLOAD_MINUTES` minutes, to send file `name` to: kept as a file of
`ref`'s project (a task's, a finding's, or a project key), attached as `by`. With `post`, a file for a
task is shown in its activity, with `caption`, once it arrives. Returns the link's token.
"""
function upload_link!(ref::AbstractString, project::AbstractString; name::AbstractString, caption::AbstractString = "",
                      post::Bool = true, by::Actor, user::Union{Integer,Nothing} = nothing)
    isempty(strip(name)) && error("Name the file, with its extension: name=\"plot.png\"")
    ext = lowercase(splitext(name)[2])
    (haskey(MEDIA_TYPES, ext) || ext in TEXT_EXTENSIONS) ||
        error("$(media_name(name)): a file here is one of $(join(sort!([collect(keys(MEDIA_TYPES)); collect(TEXT_EXTENSIONS)]), ", "))")
    token = bytes2hex(rand(SECRET_RNG, UInt8, 24))
    up = Upload(by, user, uppercase(strip(ref)), uppercase(strip(project)), media_name(name), strip(caption), post,
                now(UTC) + Minute(UPLOAD_MINUTES))
    lock(UPLOADS_LOCK) do
        filter!(kv -> kv[2].expires > now(UTC), UPLOADS)
        UPLOADS[token] = up
    end
    return token
end

"""
    receive_upload!(kb, token, bytes) -> NamedTuple

Keep `bytes` sent to upload link `token` (see [`upload_link!`](@ref)), which is then used up, and
return the file as [`add_media!`](@ref) does, with `note`, the note it was posted as (or 0).
"""
function receive_upload!(kb::KB, token::AbstractString, bytes::AbstractVector{UInt8})
    up = lock(() -> get(UPLOADS, token, nothing), UPLOADS_LOCK)
    up === nothing && not_found("This upload link is unknown or used: ask media_upload for another")
    up.expires > now(UTC) || (lock(() -> delete!(UPLOADS, token), UPLOADS_LOCK); throw(Refusal(410, "This upload link expired: ask media_upload for another")))
    m = add_media!(kb, bytes, up.name; by = up.by.name, user = up.user, project = up.project)
    lock(() -> delete!(UPLOADS, token), UPLOADS_LOCK)            # used once it is kept
    note = 0
    if up.post && is_task_ref(up.ref)
        note = note_task!(kb, up.ref, media_note(m, up.caption); kind = "progress", by = up.by)
    end
    return merge(m, (; note, caption = up.caption))
end

"A file as a note shows it: an image or a movie inline, anything else as a link, after its caption."
function media_note(m, caption::AbstractString = "")
    shown = startswith(m.type, "image/") || startswith(m.type, "video/")
    link = shown ? "![$(isempty(caption) ? m.name : caption)]($(m.address))" : "[$(m.name)]($(m.address))"
    return isempty(caption) ? link : "$caption\n\n$link"
end

"""
    upload_response(kb, req, token) -> HTTP.Response

Answer a file sent to an upload link (`PUT` or `POST`, the file as the body): what it is kept as, for
the agent that sent it to use in its text.
"""
function upload_response(kb::KB, req::HTTP.Request, token::AbstractString)
    req.method in ("PUT", "POST") || return HTTP.Response(405, ["Allow" => "PUT, POST"], "Send the file with PUT: curl -T file <link>")
    try
        m = receive_upload!(kb, token, body_bytes(req))
        said = "Uploaded $(m.name) ($(round(m.size / 1024; digits = 1)) KB) as $(m.address)\n" *
               (m.note > 0 ? "Posted to the task's activity as note $(m.note).\n" : "") *
               "In Markdown: $(media_note(m) |> s -> isempty(m.caption) ? s : replace(s, "[$(m.name)]" => "[$(m.caption)]"))\n"
        return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], said)
    catch e
        log_failure(req, e, catch_backtrace())
        return HTTP.Response(error_status(e), ["Content-Type" => "text/plain; charset=utf-8"], client_message(e) * "\n")
    end
end
