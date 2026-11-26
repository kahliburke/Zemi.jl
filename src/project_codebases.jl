# A project's codebases (`project_codebases`), in the order they were added: the first is its main one,
# which `@code:path` references and new tasks' code are in, until another is made main. All of them
# lead agents working in their directories to the project, have their commits recorded against its
# tasks, and are seen by its members. A project may also take in a GitHub organization's (or
# account's) repositories (`project_orgs`): each is linked as a codebase of the project, and the
# organization is listed again each day (see `list_project_orgs!`) for the ones added since. A
# repository archived when it is listed is left out; one archived after it was linked stays, marked,
# and is not fetched again. One no longer listed is marked gone, not unlinked.

migration!(32, [
    """CREATE TABLE project_orgs (
           id INTEGER PRIMARY KEY,
           project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
           host TEXT NOT NULL,
           owner TEXT NOT NULL,
           forks INTEGER NOT NULL DEFAULT 0,
           added_by TEXT NOT NULL DEFAULT '',
           added_at TEXT NOT NULL,
           listed_at TEXT,
           problem TEXT,
           UNIQUE (project_id, host, owner))""",
    """CREATE TABLE project_codebases (
           project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
           codebase_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
           position INTEGER NOT NULL,
           org_id INTEGER REFERENCES project_orgs(id) ON DELETE SET NULL,
           gone_at TEXT,
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
organization it came in through (`owner`, or `""` for one linked by itself), `gone` whether that
organization no longer lists it, `archived` whether its repository is archived.
"""
function project_codebases(kb::KB, key::AbstractString)
    rows = query(kb, """
        SELECT d.doc_id, d.title, d.repository_archived_at AS archived, pc.gone_at, o.owner
        FROM project_codebases pc JOIN projects p ON p.id = pc.project_id JOIN papers d ON d.id = pc.codebase_id
        LEFT JOIN project_orgs o ON o.id = pc.org_id
        WHERE p.key = ? ORDER BY pc.position, pc.added_at, d.doc_id""", (uppercase(strip(key)),))
    return [(; id = String(r.doc_id), title = String(coalesce(r.title, r.doc_id)), main = i == 1, org = String(coalesce(r.owner, "")),
               gone = !ismissing(r.gone_at), archived = !ismissing(r.archived)) for (i, r) in enumerate(rows)]
end

"Project `key`'s main codebase (its id), or `\"\"` when it has none."
project_codebase(kb::KB, key::AbstractString) =
    String(coalesce(scalar(kb, """SELECT d.doc_id FROM project_codebases pc JOIN projects p ON p.id = pc.project_id
                                  JOIN papers d ON d.id = pc.codebase_id WHERE p.key = ?
                                  ORDER BY pc.position, pc.added_at, d.doc_id LIMIT 1""", (uppercase(strip(key)),)), ""))

"The organizations project `key` takes repositories from: `(; host, owner, forks, listed_at, problem)`."
project_orgs(kb::KB, key::AbstractString) =
    [(; host = String(r.host), owner = String(r.owner), forks = r.forks == 1, listed_at = String(coalesce(r.listed_at, "")),
        problem = String(coalesce(r.problem, "")))
     for r in query(kb, """SELECT o.* FROM project_orgs o JOIN projects p ON p.id = o.project_id WHERE p.key = ?
                           ORDER BY o.host, o.owner""", (uppercase(strip(key)),))]

"""
Link codebase `cid` (its row id) to project `pid`, after its others (`org` the organization it came
through); whether it is new to the project.
"""
function link_codebase!(kb::KB, pid::Integer, cid::Integer; by::AbstractString, org = missing)
    linked = 0 < changed!(kb, """INSERT OR IGNORE INTO project_codebases (project_id, codebase_id, position, org_id, added_by, added_at)
                             SELECT ?, ?, coalesce(max(position) + 1, 0), ?, ?, ? FROM project_codebases WHERE project_id = ?""",
                      (pid, cid, org, by, now_iso(), pid))
    linked || ismissing(org) ||
        execute!(kb, "UPDATE project_codebases SET gone_at = NULL WHERE project_id = ? AND codebase_id = ? AND org_id = ?", (pid, cid, org))
    return linked
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

"""
    project_codebase!(kb, key, codebase; remove = false, main = false, forks = false, add = true, read = true, by,
                      caller = local_caller()) -> Vector{String}

Link project `key` to `codebase`: a codebase (`code-…`), a repository's address or a folder (see
[`codebase_id`](@ref), for `add` and `caller`), or a GitHub organization or account (see
[`named_org`](@ref)), whose repositories are each linked, forks only with `forks`, archived ones
not. A codebase new to the knowledge base is read at once (unless `read` is false). The first
codebase is the project's main one; `main` makes this one main. With `remove`, unlinks the codebase,
or the organization and the codebases it brought. Returns the codebases linked or unlinked.
"""
function project_codebase!(kb::KB, key::AbstractString, codebase::AbstractString; remove::Bool = false, main::Bool = false,
                           forks::Bool = false, add::Bool = true, read::Bool = true, by::Actor, caller::Caller = local_caller())
    pid = project_id(kb, key)
    org = named_org(codebase)
    out = if org !== nothing
        remove ? remove_project_org!(kb, pid, org...) :
                 (add || not_permitted("Not permitted: an organization's repositories are added by someone with paper.add");
                  add_project_org!(kb, pid, org...; forks, by = by.name, read))
    else
        cid = remove ? linked_codebase(kb, pid, codebase) : codebase_id(kb, codebase; add, caller)
        ismissing(cid) && error("Name a codebase: its id (code-…), a repository's address, a folder, or github.com/<organization>")
        id = String(scalar(kb, "SELECT doc_id FROM papers WHERE id = ?", (cid,)))
        if remove
            execute!(kb, "DELETE FROM project_codebases WHERE project_id = ? AND codebase_id = ?", (pid, cid))
        else
            link_codebase!(kb, pid, cid; by = by.name)
            main && make_main_codebase!(kb, pid, cid)
        end
        [id]
    end
    tasks_changed!()
    return out
end

"The codebase (its row id) of project `pid` that `codebase` names: by its id, its repository's address or its folder."
function linked_codebase(kb::KB, pid::Integer, codebase::AbstractString)
    s = strip(codebase)
    for r in query(kb, """SELECT d.id, d.doc_id, d.remote, d.source_path FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
                          WHERE pc.project_id = ?""", (pid,))
        (r.doc_id == s || (is_repository(s) && coalesce(r.remote, "") == clone_url(s)) ||
         (is_folder(s) && coalesce(r.source_path, "") == full_folder(s))) && return Int(r.id)
    end
    not_found("$s is not one of the project's codebases")
end

"Take in organization `owner`'s repositories for project `pid` (see [`list_org!`](@ref)); the codebases it linked."
function add_project_org!(kb::KB, pid::Integer, host::AbstractString, owner::AbstractString; forks::Bool, by::AbstractString,
                          read::Bool = true)
    execute!(kb, """INSERT INTO project_orgs (project_id, host, owner, forks, added_by, added_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, host, owner) DO UPDATE SET forks = excluded.forks""",
             (pid, host, owner, forks ? 1 : 0, by, now_iso()))
    oid = Int(scalar(kb, "SELECT id FROM project_orgs WHERE project_id = ? AND host = ? AND owner = ?", (pid, host, owner)))
    return list_org!(kb, oid; read)
end

"Stop taking in organization `owner`'s repositories for project `pid`, unlinking those it brought; returns them."
function remove_project_org!(kb::KB, pid::Integer, host::AbstractString, owner::AbstractString)
    oid = scalar(kb, "SELECT id FROM project_orgs WHERE project_id = ? AND host = ? AND owner = ? COLLATE NOCASE", (pid, host, owner))
    ismissing(oid) && not_found("The project does not take in $host/$owner")
    ids = [String(r.doc_id) for r in query(kb, """SELECT d.doc_id FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
                                                  WHERE pc.org_id = ? ORDER BY d.doc_id""", (oid,))]
    transaction(kb) do
        execute!(kb, "DELETE FROM project_codebases WHERE org_id = ?", (oid,))
        execute!(kb, "DELETE FROM project_orgs WHERE id = ?", (oid,))
    end
    return ids
end

"""
    list_org!(kb, oid; read = true) -> Vector{String}

List the repositories of organization `oid` (a `project_orgs` row) and bring its project up to date
with them: a new repository is linked (and with `read`, read at once), unless it is archived, a fork
(without the organization's `forks`) or one a person dropped; one linked already that is now
archived is marked so; one the organization no longer lists is marked gone. Returns the codebases
linked. What stopped the listing is kept with the organization, and thrown; either way the time it
was listed is kept, for [`list_project_orgs!`](@ref).
"""
function list_org!(kb::KB, oid::Integer; read::Bool = true)
    o = only(query(kb, "SELECT * FROM project_orgs WHERE id = ?", (oid,)))
    repos = try
        org_repositories(kb.config, String(o.owner))
    catch e
        execute!(kb, "UPDATE project_orgs SET listed_at = ?, problem = ? WHERE id = ?", (now_iso(), failure_message(e), oid))
        rethrow()
    end
    linked = Dict(String(r.remote) => Int(r.id) for r in query(kb, """
        SELECT d.id, d.remote FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
        WHERE pc.project_id = ? AND d.remote IS NOT NULL""", (o.project_id,)))
    new = String[]
    listed = Set{Int}()
    for r in repos
        remote = clone_url(r.url)
        cid = get(linked, remote, nothing)
        if cid !== nothing
            push!(listed, cid)
            execute!(kb, "UPDATE papers SET repository_archived_at = ? WHERE id = ? AND (repository_archived_at IS NULL) = ?",
                     (r.archived ? now_iso() : missing, cid, r.archived ? 1 : 0))
            link_codebase!(kb, Int(o.project_id), cid; by = String(o.added_by), org = oid)
            continue
        end
        (r.archived || (r.fork && o.forks == 0)) && continue
        id = try
            link_repository!(kb, remote)
        catch e
            e isa DroppedError && continue
            rethrow()
        end
        cid = Int(paper_id(kb, id))
        push!(listed, cid)
        link_codebase!(kb, Int(o.project_id), cid; by = String(o.added_by), org = oid) && push!(new, id)
    end
    for r in query(kb, "SELECT codebase_id FROM project_codebases WHERE org_id = ? AND gone_at IS NULL", (oid,))
        Int(r.codebase_id) in listed ||
            execute!(kb, "UPDATE project_codebases SET gone_at = ? WHERE org_id = ? AND codebase_id = ?", (now_iso(), oid, r.codebase_id))
    end
    execute!(kb, "UPDATE project_orgs SET listed_at = ?, problem = NULL WHERE id = ?", (now_iso(), oid))
    read && !isempty(new) && start_codebases_reading(kb, new)
    tasks_changed!()
    return new
end

"""
    list_project_orgs!(kb; every = Hour(20), now = now(UTC)) -> Int

List again each project's organization not listed for `every` (see [`list_org!`](@ref)), as
[`follow_commits`](@ref) asks for: the repositories added to it since are linked and read. A failure
is kept with its organization and logged, tried again after `every` too, and the others are listed
still. Returns how many codebases were linked.
"""
function list_project_orgs!(kb::KB; every::Period = Hour(20), now::DateTime = Dates.now(UTC))
    n = 0
    for r in query(kb, "SELECT id, owner FROM project_orgs WHERE listed_at IS NULL OR listed_at < ? ORDER BY id", (iso(now - every),))
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
