# A project's codebases (`project_codebases`), in the order they were added: the first is its main one,
# which `@code:path` references are in, until another is made main. All of them lead agents working in
# their directories to the project, have their commits recorded against its tasks, and are seen by its
# members. Codebases are linked one by one, by their ids, repositories' addresses or folders, or chosen
# from the repositories of a GitHub organization (or account) listed for the project (`code_orgs`).
# The knowledge base lists organizations of its own the same way, from the Codebases page, its
# codebases chosen from them added to it without a project. An organization's repositories are its
# candidates (`org_repositories`), listed again each day (see `list_code_orgs!`), and only those chosen
# are linked (or added) and read, unless the organization takes new ones as they appear (`auto`, forks
# only with `forks`, archived ones never). A candidate unlinked or declined is not taken again by
# itself. A codebase whose repository is archived stays, marked, and is not fetched again; one its
# organization no longer lists is marked gone.

migration!(32, [
    """CREATE TABLE code_orgs (
           id INTEGER PRIMARY KEY,
           project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
           host TEXT NOT NULL,
           owner TEXT NOT NULL,
           forks INTEGER NOT NULL DEFAULT 0,
           auto INTEGER NOT NULL DEFAULT 0,
           added_by TEXT NOT NULL DEFAULT '',
           added_at TEXT NOT NULL,
           listed_at TEXT,
           problem TEXT)""",
    "CREATE UNIQUE INDEX code_orgs_named ON code_orgs (coalesce(project_id, 0), host, owner COLLATE NOCASE)",
    """CREATE TABLE org_repositories (
           org_id INTEGER NOT NULL REFERENCES code_orgs(id) ON DELETE CASCADE,
           remote TEXT NOT NULL,
           name TEXT NOT NULL,
           fork INTEGER NOT NULL DEFAULT 0,
           archived INTEGER NOT NULL DEFAULT 0,
           first_seen_at TEXT NOT NULL,
           gone_at TEXT,
           declined_at TEXT,
           PRIMARY KEY (org_id, remote))""",
    """CREATE TABLE project_codebases (
           project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
           codebase_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
           position INTEGER NOT NULL,
           org_id INTEGER REFERENCES code_orgs(id) ON DELETE SET NULL,
           added_by TEXT NOT NULL DEFAULT '',
           added_at TEXT NOT NULL,
           PRIMARY KEY (project_id, codebase_id))""",
    "CREATE INDEX project_codebases_codebase ON project_codebases (codebase_id)",
    """INSERT INTO project_codebases (project_id, codebase_id, position, added_by, added_at)
       SELECT id, codebase_id, 0, created_by, created_at FROM projects WHERE codebase_id IS NOT NULL""",
    "ALTER TABLE projects DROP COLUMN codebase_id",
    # When a codebase's repository was seen archived (see `list_org!`): it is not fetched again.
    "ALTER TABLE papers ADD COLUMN repository_archived_at TEXT"])

"""
    project_codebases(kb, key) -> Vector{NamedTuple}

Project `key`'s codebases, the main one first: `(; id, title, main, org, gone, archived)`, `org` the
organization it was chosen from (`owner`, or `""` for one linked by itself), `gone` whether that
organization no longer lists it, `archived` whether its repository is archived.
"""
function project_codebases(kb::KB, key::AbstractString)
    rows = query(kb, """
        SELECT d.doc_id, d.title, d.repository_archived_at AS archived, r.gone_at, o.owner
        FROM project_codebases pc JOIN projects p ON p.id = pc.project_id JOIN papers d ON d.id = pc.codebase_id
        LEFT JOIN code_orgs o ON o.id = pc.org_id LEFT JOIN org_repositories r ON r.org_id = pc.org_id AND r.remote = d.remote
        WHERE p.key = ? ORDER BY pc.position, pc.added_at, d.doc_id""", (uppercase(strip(key)),))
    return [(; id = String(r.doc_id), title = String(coalesce(r.title, r.doc_id)), main = i == 1, org = String(coalesce(r.owner, "")),
               gone = !ismissing(r.gone_at), archived = !ismissing(r.archived)) for (i, r) in enumerate(rows)]
end

"Project `key`'s main codebase (its id), or `\"\"` when it has none."
project_codebase(kb::KB, key::AbstractString) =
    String(coalesce(scalar(kb, """SELECT d.doc_id FROM project_codebases pc JOIN projects p ON p.id = pc.project_id
                                  JOIN papers d ON d.id = pc.codebase_id WHERE p.key = ?
                                  ORDER BY pc.position, pc.added_at, d.doc_id LIMIT 1""", (uppercase(strip(key)),)), ""))

# Where an organization is listed: for project `pid`, or for the knowledge base itself (`nothing`).
const Scope = Union{Integer,Nothing}
in_scope(pid::Scope) = pid === nothing ? ("project_id IS NULL", ()) : ("project_id = ?", (pid,))

"The codebases taken in `pid`'s scope, by their repositories: a project's codebases, or every codebase of the knowledge base."
taken(kb::KB, pid::Scope) = Dict(String(r.remote) => String(r.doc_id) for r in (pid === nothing ?
    query(kb, "SELECT remote, doc_id FROM papers WHERE $(kind_in(CODEBASE)) AND remote IS NOT NULL") :
    query(kb, """SELECT d.remote, d.doc_id FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
                 WHERE pc.project_id = ? AND d.remote IS NOT NULL""", (pid,))))

"""
    code_orgs(kb, pid) -> Vector{NamedTuple}

The organizations listed for project `pid` (its row id), or for the knowledge base itself
(`nothing`): `(; host, owner, forks, auto, listed_at, problem, repositories)`, each repository
`(; name, remote, fork, archived, gone, declined, new, codebase)`, `new` one first seen after the
organization's first listing and neither taken nor declined, `codebase` the codebase taken from it in
that scope (`""` for none). [`project_orgs`](@ref) gives a project's by its key.
"""
function code_orgs(kb::KB, pid::Scope)
    have = taken(kb, pid)
    where, args = in_scope(pid)
    return [begin
        repos = [(; name = String(r.name), remote = String(r.remote), fork = r.fork == 1, archived = r.archived == 1,
                    gone = !ismissing(r.gone_at), declined = !ismissing(r.declined_at),
                    new = r.first_seen_at > o.added_at && !haskey(have, r.remote) && ismissing(r.declined_at),
                    codebase = get(have, String(r.remote), ""))
                 for r in query(kb, "SELECT * FROM org_repositories WHERE org_id = ? ORDER BY lower(name)", (o.id,))]
        (; host = String(o.host), owner = String(o.owner), forks = o.forks == 1, auto = o.auto == 1,
           listed_at = String(coalesce(o.listed_at, "")), problem = String(coalesce(o.problem, "")), repositories = repos)
    end for o in query(kb, "SELECT * FROM code_orgs WHERE $where ORDER BY host, owner", args)]
end
project_orgs(kb::KB, key::AbstractString) = code_orgs(kb, project_id(kb, key))

"The organization `host`/`owner` listed in `pid`'s scope (its row id), or `nothing`."
function find_org(kb::KB, pid::Scope, host::AbstractString, owner::AbstractString)
    where, args = in_scope(pid)
    id = scalar(kb, "SELECT id FROM code_orgs WHERE $where AND host = ? AND owner = ? COLLATE NOCASE", (args..., host, owner))
    return ismissing(id) ? nothing : Int(id)
end

"""
Link codebase `cid` (its row id) to project `pid`, after its others; whether it is new to the
project. One that is a candidate of an organization listed for the project is that organization's,
and no longer declined.
"""
function link_codebase!(kb::KB, pid::Integer, cid::Integer; by::AbstractString)
    remote = scalar(kb, "SELECT remote FROM papers WHERE id = ?", (cid,))
    org = ismissing(remote) ? missing :
        scalar(kb, """SELECT r.org_id FROM org_repositories r JOIN code_orgs o ON o.id = r.org_id
                      WHERE o.project_id = ? AND r.remote = ? ORDER BY r.org_id LIMIT 1""", (pid, remote))
    linked = 0 < changed!(kb, """INSERT OR IGNORE INTO project_codebases (project_id, codebase_id, position, org_id, added_by, added_at)
                                 SELECT ?, ?, coalesce(max(position) + 1, 0), ?, ?, ? FROM project_codebases WHERE project_id = ?""",
                          (pid, cid, org, by, now_iso(), pid))
    ismissing(remote) || decline!(kb, pid, [remote]; on = false)
    return linked
end

"Decline (or, without `on`, no longer decline) `remotes` among the candidates of the organizations in `pid`'s scope."
function decline!(kb::KB, pid::Scope, remotes; on::Bool = true)
    where, args = in_scope(pid)
    for remote in remotes
        execute!(kb, """UPDATE org_repositories SET declined_at = ? WHERE remote = ? AND (declined_at IS NULL) = ?
                        AND org_id IN (SELECT id FROM code_orgs WHERE $where)""", (on ? now_iso() : missing, remote, on ? 1 : 0, args...))
    end
end

"Make codebase `cid` project `pid`'s main one: first of its codebases."
make_main_codebase!(kb::KB, pid::Integer, cid::Integer) =
    execute!(kb, """UPDATE project_codebases SET position = (SELECT min(position) - 1 FROM project_codebases WHERE project_id = ?)
                    WHERE project_id = ? AND codebase_id = ?""", (pid, pid, cid))

"A GitHub organization or account named by `s` (`github.com/<owner>`, its web page, or `org:<owner>`), as `(host, owner)`, or `nothing`."
function named_org(s::AbstractString)
    m = match(r"^(?:org:|(?:https?://)?(?:www\.)?github\.com/)([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/?$"i, strip(s))
    return m === nothing ? nothing : ("github.com", String(m[1]))
end

"The codebases, repositories, folders or organizations named in `s`, given together: one per line, or apart by commas."
named_codebases(s::AbstractString) = String.(filter(!isempty, strip.(split(s, r"[\n,]"))))

"""
    project_codebase!(kb, key, codebases; remove = false, main = false, forks = false, auto = false, add = true,
                      read = true, by, caller = local_caller(kb)) -> Vector{String}

Link project `key` to each of `codebases` (one, or several as [`named_codebases`](@ref) reads them):
a codebase (`code-…`), a repository's address or a folder (see [`codebase_id`](@ref), for `add` and
`caller`), or a GitHub organization or account (see [`named_org`](@ref)), whose repositories are
listed as the project's candidates to choose from (see [`add_org!`](@ref)), and linked as they
appear only with `auto` (forks only with `forks`). Those linked new to the knowledge base are read
together, at once, unless `read` is false. The first codebase is the project's main one; `main` makes
this one main. With `remove`, unlinks a codebase, declining it if it is a candidate (one not linked is
declined too), or stops listing an organization; the codebases chosen from it stay. Returns the
codebases linked or unlinked.
"""
function project_codebase!(kb::KB, key::AbstractString, codebases; remove::Bool = false, main::Bool = false,
                           forks::Bool = false, auto::Bool = false, add::Bool = true, read::Bool = true, by::Actor,
                           caller::Caller = local_caller(kb))
    pid = project_id(kb, key)
    names = codebases isa AbstractString ? named_codebases(codebases) : String.(codebases)
    isempty(names) && error("Name a codebase: its id (code-…), a repository's address, a folder, or github.com/<organization>")
    out = String[]
    for name in names
        org = named_org(name)
        if org !== nothing
            remove ? remove_org!(kb, pid, org...) : append!(out, add_org!(kb, pid, org...; forks, auto, add, by = by.name))
        elseif remove
            id = unlink_codebase!(kb, pid, name)
            id === nothing || push!(out, id)
        else
            cid = codebase_id(kb, name; add, read = false, caller)
            ismissing(cid) && error("Name a codebase: its id (code-…), a repository's address, a folder, or github.com/<organization>")
            link_codebase!(kb, pid, cid; by = by.name)
            main && make_main_codebase!(kb, pid, cid)
            push!(out, String(scalar(kb, "SELECT doc_id FROM papers WHERE id = ?", (cid,))))
        end
    end
    remove || !read || read_unread!(kb, out)
    tasks_changed!()
    return out
end

"""
Unlink the codebase of project `pid` that `name` names, declining it if it is a candidate; returns its
id. A candidate named without being linked is declined, and `nothing` returned.
"""
function unlink_codebase!(kb::KB, pid::Integer, name::AbstractString)
    cid = linked_codebase(kb, pid, name)
    if cid === nothing
        remote = is_repository(name) ? clone_url(name) : ""
        candidate = !isempty(remote) && !ismissing(scalar(kb, """SELECT 1 FROM org_repositories r JOIN code_orgs o ON o.id = r.org_id
                                                                 WHERE o.project_id = ? AND r.remote = ?""", (pid, remote)))
        candidate || not_found("$name is not one of the project's codebases")
        decline!(kb, pid, [remote])
        return nothing
    end
    execute!(kb, "DELETE FROM project_codebases WHERE project_id = ? AND codebase_id = ?", (pid, cid))
    remote = scalar(kb, "SELECT remote FROM papers WHERE id = ?", (cid,))
    ismissing(remote) || decline!(kb, pid, [remote])
    return String(scalar(kb, "SELECT doc_id FROM papers WHERE id = ?", (cid,)))
end

"Read those of codebases `ids` not read yet nor being read, together (see [`start_codebases_reading`](@ref))."
function read_unread!(kb::KB, ids)
    busy = Set(id for j in list_jobs() if j.status == :running for id in j.ids)
    unread = [id for id in unique(ids) if !(id in busy) && !codebase_read(kb, id)]
    isempty(unread) || start_codebases_reading(kb, unread)
    return nothing
end

"The codebase (its row id) of project `pid` that `codebase` names, by its id, its repository's address or its folder, or `nothing`."
function linked_codebase(kb::KB, pid::Integer, codebase::AbstractString)
    s = strip(codebase)
    for r in query(kb, """SELECT d.id, d.doc_id, d.remote, d.source_path FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
                          WHERE pc.project_id = ?""", (pid,))
        (r.doc_id == s || (is_repository(s) && coalesce(r.remote, "") == clone_url(s)) ||
         (is_folder(s) && coalesce(r.source_path, "") == full_folder(s))) && return Int(r.id)
    end
    return nothing
end

"""
    add_org!(kb, pid, host, owner; forks = false, auto = false, add = true, by) -> Vector{String}

List organization `owner`'s repositories in `pid`'s scope (a project's row id, or `nothing` for the
knowledge base itself), recording it with its settings, or changing them (see [`list_org!`](@ref)):
the codebases it took. Takes `add`, as it may add repositories the knowledge base does not have.
"""
function add_org!(kb::KB, pid::Scope, host::AbstractString, owner::AbstractString; forks::Bool = false, auto::Bool = false,
                  add::Bool = true, by::AbstractString)
    add || not_permitted("Not permitted: an organization's repositories are listed by someone with paper.add")
    oid = find_org(kb, pid, host, owner)
    if oid === nothing
        execute!(kb, "INSERT INTO code_orgs (project_id, host, owner, forks, auto, added_by, added_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                 (something(pid, missing), host, owner, forks ? 1 : 0, auto ? 1 : 0, by, now_iso()))
        oid = find_org(kb, pid, host, owner)
    else
        execute!(kb, "UPDATE code_orgs SET forks = ?, auto = ? WHERE id = ?", (forks ? 1 : 0, auto ? 1 : 0, oid))
    end
    return list_org!(kb, oid; read = false)
end

"Stop listing organization `owner` in `pid`'s scope; the codebases taken from it stay."
function remove_org!(kb::KB, pid::Scope, host::AbstractString, owner::AbstractString)
    oid = find_org(kb, pid, host, owner)
    oid === nothing && not_found("$host/$owner is not listed here")
    execute!(kb, "DELETE FROM code_orgs WHERE id = ?", (oid,))
    tasks_changed!()
    return String[]
end

"""
    choose_org!(kb, pid, host, owner; take = [], untake = [], decline = [], undecline = [], add = true, read = true,
                by, caller = local_caller(kb)) -> Vector{String}

Choose among the candidates of organization `owner` in `pid`'s scope, by their repositories'
addresses: `take` them (linked to the project, or for the knowledge base, added to it; read together
unless `read` is false), `untake` codebases (unlinked from the project and declined; the knowledge
base's own are dropped from it on the Documents page instead), `decline` candidates, or `undecline`
them. Returns the codebases taken.
"""
function choose_org!(kb::KB, pid::Scope, host::AbstractString, owner::AbstractString; take = String[], untake = String[],
                     decline = String[], undecline = String[], add::Bool = true, read::Bool = true, by::AbstractString,
                     caller::Caller = local_caller(kb))
    oid = find_org(kb, pid, host, owner)
    oid === nothing && not_found("$host/$owner is not listed here")
    candidates = Set(String(r.remote) for r in query(kb, "SELECT remote FROM org_repositories WHERE org_id = ?", (oid,)))
    out = String[]
    for remote in clone_url.(take)
        remote in candidates || not_found("$remote is not one of $owner's repositories")
        cid = codebase_id(kb, remote; add, read = false, caller)
        pid === nothing ? decline!(kb, nothing, [remote]; on = false) : link_codebase!(kb, pid, cid; by)
        push!(out, String(scalar(kb, "SELECT doc_id FROM papers WHERE id = ?", (cid,))))
    end
    isempty(untake) || pid === nothing && error("A codebase is taken out of the knowledge base by dropping it, on the Documents page")
    foreach(id -> unlink_codebase!(kb, pid, id), untake)
    decline!(kb, pid, filter(in(candidates), clone_url.(decline)))
    decline!(kb, pid, filter(in(candidates), clone_url.(undecline)); on = false)
    read && read_unread!(kb, out)
    tasks_changed!()
    return out
end

"""
    list_org!(kb, oid; read = true) -> Vector{String}

List the repositories of organization `oid` (a `code_orgs` row) as candidates in its scope: each one
new is recorded, with whether it is a fork or archived, and one no longer listed is marked gone. A
codebase whose repository is now archived is marked so. With the organization's `auto`, a candidate
neither taken, archived, declined nor a fork (without `forks`) is taken (linked to its project, or
added to the knowledge base), and with `read` read at once. Returns the codebases taken. What stopped
the listing is kept with the organization, and thrown; either way the time it was listed is kept, for
[`list_code_orgs!`](@ref).
"""
function list_org!(kb::KB, oid::Integer; read::Bool = true)
    o = only(query(kb, "SELECT * FROM code_orgs WHERE id = ?", (oid,)))
    pid = ismissing(o.project_id) ? nothing : Int(o.project_id)
    repos = try
        org_repositories(kb.config, String(o.owner))
    catch e
        execute!(kb, "UPDATE code_orgs SET listed_at = ?, problem = ? WHERE id = ?", (now_iso(), failure_message(e), oid))
        rethrow()
    end
    # The repositories of the first listing are the organization's from the start, not new.
    seen = ismissing(o.listed_at) ? String(o.added_at) : now_iso()
    listed = Set{String}()
    for r in repos
        remote = clone_url(r.url)
        push!(listed, remote)
        execute!(kb, """INSERT INTO org_repositories (org_id, remote, name, fork, archived, first_seen_at) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (org_id, remote) DO UPDATE SET name = excluded.name, fork = excluded.fork,
                                                                   archived = excluded.archived, gone_at = NULL""",
                 (oid, remote, r.name, r.fork ? 1 : 0, r.archived ? 1 : 0, seen))
        execute!(kb, """UPDATE papers SET repository_archived_at = ? WHERE remote = ? AND $(kind_in(CODEBASE))
                        AND (repository_archived_at IS NULL) = ?""", (r.archived ? now_iso() : missing, remote, r.archived ? 1 : 0))
    end
    for r in query(kb, "SELECT remote FROM org_repositories WHERE org_id = ? AND gone_at IS NULL", (oid,))
        r.remote in listed || execute!(kb, "UPDATE org_repositories SET gone_at = ? WHERE org_id = ? AND remote = ?", (now_iso(), oid, r.remote))
    end
    execute!(kb, "UPDATE code_orgs SET listed_at = ?, problem = NULL WHERE id = ?", (now_iso(), oid))
    new = String[]
    if o.auto == 1
        have = taken(kb, pid)
        for r in query(kb, """SELECT remote FROM org_repositories WHERE org_id = ? AND gone_at IS NULL AND declined_at IS NULL
                              AND archived = 0 AND (fork = 0 OR ? = 1) ORDER BY lower(name)""", (oid, o.forks))
            haskey(have, r.remote) && continue
            id = try
                link_repository!(kb, r.remote)
            catch e
                e isa DroppedError && continue
                rethrow()
            end
            pid === nothing || link_codebase!(kb, pid, Int(paper_id(kb, id)); by = String(o.added_by))
            push!(new, id)
        end
        read && read_unread!(kb, new)
    end
    tasks_changed!()
    return new
end

"""
    list_code_orgs!(kb; every = Hour(20), now = now(UTC)) -> Int

List again each organization not listed for `every` (see [`list_org!`](@ref)), as
[`follow_commits`](@ref) asks for: the repositories added to it since are candidates, or with its
`auto`, taken and read. A failure is kept with its organization and logged, tried again after `every`
too, and the others are listed still. Returns how many codebases were taken.
"""
function list_code_orgs!(kb::KB; every::Period = Hour(20), now::DateTime = Dates.now(UTC))
    n = 0
    for r in query(kb, "SELECT id, owner FROM code_orgs WHERE listed_at IS NULL OR listed_at < ? ORDER BY id", (iso(now - every),))
        try
            n += length(list_org!(kb, Int(r.id)))
        catch e
            e isa InterruptException && rethrow()
            @warn "The repositories of $(r.owner) could not be listed" problem = failure_message(e)
        end
    end
    return n
end

"""
    org_repositories(c, owner) -> Vector{NamedTuple}

The repositories of GitHub organization or account `owner`, `(; url, name, fork, archived)`: those
the GitHub App is installed on, where it is installed for `owner`, else the public ones.
"""
function org_repositories(c::Config, owner::AbstractString)
    app = c.shared.github_app
    token = isempty(app.client_id) ? nothing : org_installation_token(app, owner)
    repos = token === nothing ? public_repositories(owner) :
            [r for r in github_pages("$(GITHUB_API[])/installation/repositories", token; key = "repositories")
             if lowercase(String(r["owner"]["login"])) == lowercase(owner)]
    return [(; url = String(get(r, "clone_url", nothing) === nothing ? r["html_url"] : r["clone_url"]), name = String(r["name"]),
               fork = something(get(r, "fork", false), false) == true, archived = something(get(r, "archived", false), false) == true)
            for r in repos]
end

"The public repositories of `owner`, an organization's or else a person's account's."
function public_repositories(owner::AbstractString)
    for kind in ("orgs", "users")
        repos = github_pages("$(GITHUB_API[])/$kind/$owner/repos?type=$(kind == "orgs" ? "public" : "owner")", nothing)
        repos === nothing || return repos
    end
    not_found("No GitHub organization or account $owner")
end

"""
Every page of GitHub list `url` (as `token`, or without one), its items under `key` where the
answer is an object; `nothing` when GitHub answers 404.
"""
function github_pages(url::AbstractString, token; key = nothing)
    out = Any[]
    headers = token === nothing ? filter(h -> first(h) != "Authorization", github_headers("")) : github_headers(token)
    for page in 1:100
        r = HTTP.get("$url$(occursin('?', url) ? '&' : '?')per_page=100&page=$page", headers; status_exception = false, retry = false)
        r.status == 404 && return nothing
        r.status == 200 || error("GitHub answered $(r.status) listing $(replace(url, GITHUB_API[] => ""))")
        b = JSON.parse(String(r.body))
        items = key === nothing ? b : b[key]
        append!(out, items)
        length(items) < 100 && break
    end
    return out
end

"""
A token for listing the repositories of the GitHub App's installation for `owner` (an organization
or a person's account), kept until five minutes before it expires, or `nothing` when the App is not
installed for `owner`.
"""
function org_installation_token(app::GitHubApp, owner::AbstractString)
    key = "org:" * lowercase(owner)
    have = get(APP_TOKENS, key, nothing)
    have !== nothing && have[2] > time() + 300 && return have[1]
    headers = github_headers(app_jwt(app))
    installation = nothing
    for kind in ("orgs", "users")
        r = HTTP.get("$(GITHUB_API[])/$kind/$owner/installation", headers; status_exception = false, retry = false)
        r.status == 404 && continue
        r.status == 200 || error("GitHub answered $(r.status) looking for the App's installation for $owner")
        installation = JSON.parse(String(r.body))["id"]
        break
    end
    installation === nothing && return nothing
    r = HTTP.post("$(GITHUB_API[])/app/installations/$installation/access_tokens", headers,
                  JSON.json(Dict("permissions" => Dict("metadata" => "read"))); status_exception = false, retry = false)
    r.status == 201 || error("GitHub answered $(r.status) for a token to list $owner's repositories")
    b = JSON.parse(String(r.body))
    APP_TOKENS[key] = (String(b["token"]), datetime2unix(DateTime(replace(String(b["expires_at"]), r"Z$" => ""))))
    return String(b["token"])
end
