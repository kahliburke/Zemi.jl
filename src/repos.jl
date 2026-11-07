# Codebases from their repositories. A codebase records the repository it comes from (`remote`: the
# `origin` of the directory it was added from, or the repository it was linked to). A shared service
# reads no directory of the machine that added a codebase: it keeps a clone of each repository under
# its data directory, fetched before commits are read, and reads files and commits from there.
# Private repositories on GitHub are read as a GitHub App (`[shared.github_app]`) installed on them.

"""
    clone_url(url) -> String

A repository's address as it is cloned: a GitHub repository, given by its web page, `https` or
`git@` address, as `https://github.com/owner/repo.git`; any other address as it is.
"""
function clone_url(url::AbstractString)
    u = strip(url)
    m = match(r"^(?:https?://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", u)
    return m === nothing ? String(u) : "https://github.com/$(m[1])/$(m[2]).git"
end

"The owner and name of the GitHub repository at `url`, or `nothing` for one elsewhere."
function github_repo(url::AbstractString)
    m = match(r"^https://github\.com/([^/]+)/([^/]+)\.git$", clone_url(url))
    return m === nothing ? nothing : (String(m[1]), String(m[2]))
end

"Whether `s` names a repository rather than a codebase: an address with a scheme, or a `git@` one."
is_repository(s::AbstractString) = occursin(r"^[a-z][a-z0-9+.-]*://|^git@"i, strip(s))

"The `origin` remote of the repository at `root`, as it is configured, or `\"\"` for none."
function git_origin(root::AbstractString)
    (isempty(root) || !isdir(root)) && return ""
    return try readchomp(pipeline(`git -C $root remote get-url origin`; stderr = devnull)) catch; "" end
end

"The `origin` of the repository at `root`, as it is cloned, or `missing`."
origin_url(root::AbstractString) = (u = git_origin(root); isempty(u) ? missing : clone_url(u))

"Where the service keeps its clone of codebase `id`."
clone_dir(c::Config, id::AbstractString) = joinpath(c.data_dir, "codebases", id)

"""
    codebase_dir(kb, id) -> String

The directory codebase `id` is read from: in shared mode the service's clone of its repository
(`""` when it records none); run for one person, the folder it was added from, or for one added by
its repository's address, this knowledge base's clone of it.
"""
function codebase_dir(kb::KB, id::AbstractString)
    rows = query(kb, "SELECT source_path, remote FROM papers WHERE doc_id = ?", (id,))
    isempty(rows) && return ""
    r = first(rows)
    clone = ismissing(r.remote) ? "" : clone_dir(kb.config, id)
    SHARED_MODE[] && return clone
    return ismissing(r.source_path) ? clone : r.source_path
end

"""
    add_codebase_from!(kb, what; by = nothing, anyway = false) -> String

A codebase from `what`: a repository's address (`https://…`, `ssh://…`, `git@host:…`, `file://…`),
recorded with it and read from this knowledge base's clone of it (see [`fetch_codebase!`](@ref)); or,
run for one person, a folder on this machine. Returns its id. One a person dropped is refused, unless
`anyway` (see [`link_repository!`](@ref)).
"""
function add_codebase_from!(kb::KB, what::AbstractString; by = nothing, anyway::Bool = false)
    w = strip(what)
    occursin(r"^[a-z]+://|^[\w.-]+@[\w.-]+:", w) && return link_repository!(kb, w; by, anyway)
    SHARED_MODE[] && error("A shared service reads codebases from their repositories: give the repository's address")
    root = expanduser(w)
    isdir(root) || error("No folder at $w")
    return add_codebase!(kb, root; by, anyway)
end

"For tests: a shared service may clone repositories on this machine's disk (`file://`)."
const LOCAL_REPOSITORIES = Ref(false)

"""
    check_remote(remote)

Refuse an address a codebase may not be cloned from: one that is not a repository's (`https://`,
`ssh://` or `user@host:path`), or, in a shared service, one on its own disk (`file://`), which would
show its files to every reader.
"""
function check_remote(remote::AbstractString)
    occursin(r"^(https://|ssh://|[\w.-]+@[\w.-]+:)", remote) && return
    startswith(remote, "file://") && (!SHARED_MODE[] || LOCAL_REPOSITORIES[]) && return
    error(SHARED_MODE[] ? "A shared service clones codebases from https:// or ssh addresses only, not $remote" :
                          "Not a repository's address: $remote (https://, ssh:// or user@host:path)")
end

"""
    link_repository!(kb, url; by = nothing, anyway = false) -> String

The codebase of the repository at `url`, recorded with that repository when it is new or records
none, returning its id. Its name is the repository's; a new one's access is as
[`default_codebase_access`](@ref) says. A repository whose codebase a person dropped is refused with
a [`DroppedError`](@ref), unless `anyway`, which restores it (`by` the person adding it).
"""
function link_repository!(kb::KB, url::AbstractString; by = nothing, anyway::Bool = false)
    remote = clone_url(url)
    check_remote(remote)
    name = replace(basename(rstrip(remote, '/')), r"\.git$" => "")
    isempty(name) && error("No repository name in $url")
    # Another repository of the same name (another owner's) is another codebase.
    id = free_code_id(kb, name, basename(dirname(rstrip(remote, '/'))); same = r -> coalesce(r.remote, remote) == remote)
    ismissing(paper_id(kb, id)) && keep_out!(kb, anyway; by, source = "repository", key = remote)
    # A new one is open to every reader unless its repository is private (see document_access.jl); one
    # recorded already keeps its own.
    access = ismissing(paper_id(kb, id)) ? default_codebase_access(kb.config, remote) : "open"
    execute!(kb, """
        INSERT INTO papers (doc_id, version, title, authors, published, primary_category, categories, kind, remote,
                            metadata_at, added_at, access)
        VALUES (?, '', ?, '[]', ?, 'code', '[]', 'code', ?, ?, ?, ?)
        ON CONFLICT (doc_id) DO UPDATE SET remote = excluded.remote""",
        (id, name, Dates.format(today(), "yyyy-mm-dd"), remote, now_iso(), now_iso(), access))
    delete!(FETCH_PROBLEMS, id)
    return id
end

"Record the repository of each codebase that has none, from the `origin` of its directory where that is here."
function record_remotes!(kb::KB)
    for r in query(kb, "SELECT id, source_path FROM papers WHERE $(kind_in(CODEBASE)) AND remote IS NULL AND source_path IS NOT NULL")
        remote = origin_url(r.source_path)
        ismissing(remote) || execute!(kb, "UPDATE papers SET remote = ? WHERE id = ?", (remote, r.id))
    end
end

# ── Fetching ─────────────────────────────────────────────────────────────────────────────────────

"Why each codebase could not be fetched, the last time it was tried."
const FETCH_PROBLEMS = Dict{String,String}()
const FETCH_LOCK = ReentrantLock()

"""
    fetch_codebase!(kb, id) -> Bool

Bring the service's clone of codebase `id` up to date with its repository, cloning it the first
time: every branch and tag, and the files of the default branch checked out. On failure, the reason
is kept for the status (see [`codebase_problem`](@ref)) and `false` returned.
"""
function fetch_codebase!(kb::KB, id::AbstractString)
    remote = scalar(kb, "SELECT remote FROM papers WHERE doc_id = ?", (id,))
    if ismissing(remote)
        FETCH_PROBLEMS[id] = "no repository is recorded for it: link one with `project_codebase(project, \"https://github.com/owner/repo\")`"
        return false
    end
    dir = clone_dir(kb.config, id)
    lock(FETCH_LOCK) do
        try
            access = repository_access(kb.config, remote)
            try
                if isdir(joinpath(dir, ".git"))
                    git!(access.env, `-C $dir fetch --quiet --prune --tags origin`)
                    # origin/HEAD is set when cloning; a default branch renamed since would leave it dangling.
                    git!(access.env, `-C $dir remote set-head origin --auto`)
                    git!(access.env, `-C $dir reset --quiet --hard origin/HEAD`)
                else
                    # Cloned beside it and moved into place, so a failed clone leaves nothing half made.
                    mkpath(dirname(dir))
                    tmp = mktempdir(dirname(dir); prefix = ".clone-")
                    try
                        git!(access.env, `clone --quiet -- $remote $tmp/repo`)
                        mv(joinpath(tmp, "repo"), dir)
                    finally
                        rm(tmp; force = true, recursive = true)
                    end
                end
            catch e
                access.hint === nothing || error(access.hint)
                rethrow()
            end
            delete!(FETCH_PROBLEMS, id)
            return true
        catch e
            problem = e isa ErrorException ? e.msg : failure_message(e)
            get(FETCH_PROBLEMS, id, "") == problem || @warn "Codebase $id could not be fetched from $remote" problem
            FETCH_PROBLEMS[id] = problem
            return false
        end
    end
end

"""
Fetch every codebase read from a clone of its repository (see [`fetch_codebase!`](@ref)): in shared
mode every one that records its repository, run for one person those added by its address. Returns
how many are up to date.
"""
function fetch_codebases!(kb::KB)
    record_remotes!(kb)
    return count(r -> fetch_codebase!(kb, String(r.doc_id)),
                 query(kb, "SELECT doc_id FROM papers WHERE $(kind_in(CODEBASE)) AND remote IS NOT NULL AND (? = 1 OR source_path IS NULL)",
                       (Int(SHARED_MODE[]),)))
end

"Run git with `env` added to its environment, never asking for a password; an error gives what git said."
function git!(env::AbstractDict, args::Cmd)
    err = IOBuffer()
    ok = success(pipeline(addenv(`git $args`, "GIT_TERMINAL_PROMPT" => "0", env...); stdout = devnull, stderr = err))
    ok || error(strip(String(take!(err))))
    return nothing
end

"""
Why codebase `id` cannot be read here, for the status: its directory gone, or in shared mode what
stopped its repository being fetched.
"""
function codebase_problem(kb::KB, id::AbstractString)
    r = first(query(kb, "SELECT source_path, remote FROM papers WHERE doc_id = ?", (id,)))
    SHARED_MODE[] || ismissing(r.source_path) || return "its directory $(r.source_path) is gone"
    ismissing(r.remote) && return "no repository is recorded for it: link one with `project_codebase`"
    return get(FETCH_PROBLEMS, id, "it is not fetched from $(r.remote) yet")
end

# ── GitHub App ───────────────────────────────────────────────────────────────────────────────────

const GITHUB_API = Ref("https://api.github.com")

"An installation token for each repository (`owner/repo`), with when it expires (Unix time)."
const APP_TOKENS = LockedDict{String,Tuple{String,Float64}}()
const APP_SLUG = Ref("")

"""
    repository_access(c, remote) -> (; env, hint)

How git reaches `remote`: for a GitHub repository the GitHub App is installed on, `env` gives git
the installation's token in an `Authorization` header (in the environment, which only the service's
user can read, rather than in the command or the clone's config). `hint` says what to do if the
repository cannot be read: install the App on it, when it is not.
"""
function repository_access(c::Config, remote::AbstractString)
    app = c.shared.github_app
    repo = github_repo(remote)
    (repo === nothing || isempty(app.client_id)) && return (; env = Dict{String,String}(), hint = nothing)
    token = installation_token(app, repo...)
    if token === nothing
        link = isempty(app_slug(app)) ? "" : " (https://github.com/apps/$(APP_SLUG[])/installations/new)"
        return (; env = Dict{String,String}(), hint = "the GitHub App is not installed on $(join(repo, '/'))$link")
    end
    header = "Authorization: Basic " * base64encode("x-access-token:$token")
    return (; env = Dict("GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
                         "GIT_CONFIG_VALUE_0" => header), hint = nothing)
end

"""
    app_jwt(app; now = time()) -> String

A JSON Web Token the GitHub App authenticates with, valid for nine minutes: signed (RS256) with its
private key, by the `openssl` command.
"""
function app_jwt(app::GitHubApp; now::Real = time())
    isfile(app.private_key) || error("The GitHub App's private key is not at $(app.private_key)")
    t = floor(Int, now)
    data = base64url(JSON.json(Dict("alg" => "RS256", "typ" => "JWT"))) * "." *
           base64url(JSON.json(Dict("iat" => t - 60, "exp" => t + 540, "iss" => app.client_id)))
    signature = read(pipeline(`openssl dgst -sha256 -sign $(app.private_key)`; stdin = IOBuffer(data)))
    isempty(signature) && error("openssl could not sign with the GitHub App's private key")
    return data * "." * base64url(signature)
end

github_headers(token) = ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github+json",
                         "X-GitHub-Api-Version" => "2022-11-28", "User-Agent" => "zemi"]

"""
    installation_token(app, owner, repo) -> Union{String,Nothing}

A token for reading `owner/repo` as the GitHub App, kept until five minutes before it expires, or
`nothing` when the App is not installed on it.
"""
function installation_token(app::GitHubApp, owner::AbstractString, repo::AbstractString)
    key = "$owner/$repo"
    have = get(APP_TOKENS, key, nothing)
    have !== nothing && have[2] > time() + 300 && return have[1]
    headers = github_headers(app_jwt(app))
    r = HTTP.get("$(GITHUB_API[])/repos/$key/installation", headers; status_exception = false, retry = false)
    r.status == 404 && return nothing
    r.status == 200 || error("GitHub answered $(r.status) looking for the App's installation on $key")
    installation = JSON.parse(String(r.body))["id"]
    r = HTTP.post("$(GITHUB_API[])/app/installations/$installation/access_tokens", headers,
                  JSON.json(Dict("repositories" => [repo], "permissions" => Dict("contents" => "read")));
                  status_exception = false, retry = false)
    r.status == 201 || error("GitHub answered $(r.status) for a token to read $key")
    b = JSON.parse(String(r.body))
    expires = datetime2unix(DateTime(replace(String(b["expires_at"]), r"Z$" => "")))
    APP_TOKENS[key] = (String(b["token"]), expires)
    return String(b["token"])
end

"The GitHub App's name in its addresses (`github.com/apps/<slug>`), or `\"\"` when GitHub does not say."
function app_slug(app::GitHubApp)
    isempty(APP_SLUG[]) || return APP_SLUG[]
    try
        r = HTTP.get("$(GITHUB_API[])/app", github_headers(app_jwt(app)); status_exception = false, retry = false)
        r.status == 200 && (APP_SLUG[] = String(JSON.parse(String(r.body))["slug"]))
    catch
    end
    return APP_SLUG[]
end
