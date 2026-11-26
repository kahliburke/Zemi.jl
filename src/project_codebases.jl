# A project's codebases (`project_codebases`), in the order they were added: the first is its main one,
# which `@code:path` references are in, until another is made main. All of them lead agents working in
# their directories to the project, have their commits recorded against its tasks, and are seen by its
# members. Codebases are linked one by one, by their ids, repositories' addresses or folders, or chosen
# from the repositories of a GitHub organization (or account) the project lists (`project_orgs`): its
# repositories are its candidates (`org_repositories`), listed again each day (see
# `list_project_orgs!`), and only those chosen are linked and read, unless the organization links new
# ones as they appear (`auto`, forks only with `forks`, archived ones never). A candidate unlinked is
# declined, and not linked again by itself. A codebase whose repository is archived stays linked,
# marked, and is not fetched again; one its organization no longer lists is marked gone.

migration!(32, [
    """CREATE TABLE project_orgs (
           id INTEGER PRIMARY KEY,
           project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
           host TEXT NOT NULL,
           owner TEXT NOT NULL,
           forks INTEGER NOT NULL DEFAULT 0,
           auto INTEGER NOT NULL DEFAULT 0,
           added_by TEXT NOT NULL DEFAULT '',
           added_at TEXT NOT NULL,
           listed_at TEXT,
           problem TEXT,
           UNIQUE (project_id, host, owner))""",
    """CREATE TABLE org_repositories (
           org_id INTEGER NOT NULL REFERENCES project_orgs(id) ON DELETE CASCADE,
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
           org_id INTEGER REFERENCES project_orgs(id) ON DELETE SET NULL,
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
        LEFT JOIN project_orgs o ON o.id = pc.org_id LEFT JOIN org_repositories r ON r.org_id = pc.org_id AND r.remote = d.remote
        WHERE p.key = ? ORDER BY pc.position, pc.added_at, d.doc_id""", (uppercase(strip(key)),))
    return [(; id = String(r.doc_id), title = String(coalesce(r.title, r.doc_id)), main = i == 1, org = String(coalesce(r.owner, "")),
               gone = !ismissing(r.gone_at), archived = !ismissing(r.archived)) for (i, r) in enumerate(rows)]
end

"Project `key`'s main codebase (its id), or `\"\"` when it has none."
project_codebase(kb::KB, key::AbstractString) =
    String(coalesce(scalar(kb, """SELECT d.doc_id FROM project_codebases pc JOIN projects p ON p.id = pc.project_id
                                  JOIN papers d ON d.id = pc.codebase_id WHERE p.key = ?
                                  ORDER BY pc.position, pc.added_at, d.doc_id LIMIT 1""", (uppercase(strip(key)),)), ""))

"""
    project_orgs(kb, key) -> Vector{NamedTuple}

The organizations project `key` lists, `(; host, owner, forks, auto, listed_at, problem, repositories)`,
each repository `(; name, remote, fork, archived, gone, declined, new, codebase)`: `new` one first seen
after the organization's first listing and neither linked nor declined, `codebase` the project's
codebase from it (`""` when it is not linked).
"""
function project_orgs(kb::KB, key::AbstractString)
    pid = project_id(kb, key)
    linked = Dict(String(r.remote) => String(r.doc_id) for r in query(kb, """
        SELECT d.remote, d.doc_id FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
        WHERE pc.project_id = ? AND d.remote IS NOT NULL""", (pid,)))
    return [begin
        repos = [(; name = String(r.name), remote = String(r.remote), fork = r.fork == 1, archived = r.archived == 1,
                    gone = !ismissing(r.gone_at), declined = !ismissing(r.declined_at),
                    new = r.first_seen_at > o.added_at && !haskey(linked, r.remote) && ismissing(r.declined_at),
                    codebase = get(linked, String(r.remote), ""))
                 for r in query(kb, "SELECT * FROM org_repositories WHERE org_id = ? ORDER BY lower(name)", (o.id,))]
        (; host = String(o.host), owner = String(o.owner), forks = o.forks == 1, auto = o.auto == 1,
           listed_at = String(coalesce(o.listed_at, "")), problem = String(coalesce(o.problem, "")), repositories = repos)
    end for o in query(kb, "SELECT * FROM project_orgs WHERE project_id = ? ORDER BY host, owner", (pid,))]
end

"""
Link codebase `cid` (its row id) to project `pid`, after its others; whether it is new to the
project. One that is a candidate of an organization the project lists is that organization's, and
no longer declined.
"""
function link_codebase!(kb::KB, pid::Integer, cid::Integer; by::AbstractString)
    remote = scalar(kb, "SELECT remote FROM papers WHERE id = ?", (cid,))
    org = ismissing(remote) ? missing :
        scalar(kb, """SELECT r.org_id FROM org_repositories r JOIN project_orgs o ON o.id = r.org_id
                      WHERE o.project_id = ? AND r.remote = ? ORDER BY r.org_id LIMIT 1""", (pid, remote))
    linked = 0 < changed!(kb, """INSERT OR IGNORE INTO project_codebases (project_id, codebase_id, position, org_id, added_by, added_at)
                                 SELECT ?, ?, coalesce(max(position) + 1, 0), ?, ?, ? FROM project_codebases WHERE project_id = ?""",
                          (pid, cid, org, by, now_iso(), pid))
    ismissing(org) || execute!(kb, """UPDATE org_repositories SET declined_at = NULL WHERE remote = ?
                                      AND org_id IN (SELECT id FROM project_orgs WHERE project_id = ?)""", (remote, pid))
    return linked
end

"Decline repository `remote` among the candidates of project `pid`'s organizations: it is not linked again by itself."
decline_candidate!(kb::KB, pid::Integer, remote::AbstractString) =
    0 < changed!(kb, """UPDATE org_repositories SET declined_at = ? WHERE remote = ? AND declined_at IS NULL
                        AND org_id IN (SELECT id FROM project_orgs WHERE project_id = ?)""", (now_iso(), remote, pid))

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
                      read = true, by, caller = local_caller()) -> Vector{String}

Link project `key` to each of `codebases` (one, or several as [`named_codebases`](@ref) reads them):
a codebase (`code-…`), a repository's address or a folder (see [`codebase_id`](@ref), for `add` and
`caller`), or a GitHub organization or account (see [`named_org`](@ref)), whose repositories are
listed as the project's candidates to choose from (see [`list_org!`](@ref)), and linked as they appear
only with `auto` (forks only with `forks`). Those linked new to the knowledge base are read together,
at once, unless `read` is false. The first codebase is the project's main one; `main` makes this one
main. With `remove`, unlinks a codebase, declining it if it is a candidate (one not linked is
declined too), or stops listing an organization; the codebases chosen from it stay. Returns the
codebases linked or unlinked.
"""
function project_codebase!(kb::KB, key::AbstractString, codebases; remove::Bool = false, main::Bool = false,
                           forks::Bool = false, auto::Bool = false, add::Bool = true, read::Bool = true, by::Actor,
                           caller::Caller = local_caller())
    pid = project_id(kb, key)
    names = codebases isa AbstractString ? named_codebases(codebases) : String.(codebases)
    isempty(names) && error("Name a codebase: its id (code-…), a repository's address, a folder, or github.com/<organization>")
    out = String[]
    for name in names
        org = named_org(name)
        if org !== nothing
            remove ? remove_project_org!(kb, pid, org...) :
                (add || not_permitted("Not permitted: an organization's repositories are added by someone with paper.add");
                 append!(out, add_project_org!(kb, pid, org...; forks, auto, by = by.name)))
        elseif remove
            cid = linked_codebase(kb, pid, name)
            if cid === nothing
                is_repository(name) && decline_candidate!(kb, pid, clone_url(name)) && continue
                not_found("$name is not one of the project's codebases")
            end
            execute!(kb, "DELETE FROM project_codebases WHERE project_id = ? AND codebase_id = ?", (pid, cid))
            remote = scalar(kb, "SELECT remote FROM papers WHERE id = ?", (cid,))
            ismissing(remote) || decline_candidate!(kb, pid, remote)
            push!(out, String(scalar(kb, "SELECT doc_id FROM papers WHERE id = ?", (cid,))))
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

"List organization `owner`'s repositories for project `pid` (see [`list_org!`](@ref)), with its settings; the codebases it linked."
function add_project_org!(kb::KB, pid::Integer, host::AbstractString, owner::AbstractString; forks::Bool, auto::Bool,
                          by::AbstractString)
    execute!(kb, """INSERT INTO project_orgs (project_id, host, owner, forks, auto, added_by, added_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (project_id, host, owner) DO UPDATE SET forks = excluded.forks, auto = excluded.auto""",
             (pid, host, owner, forks ? 1 : 0, auto ? 1 : 0, by, now_iso()))
    oid = Int(scalar(kb, "SELECT id FROM project_orgs WHERE project_id = ? AND host = ? AND owner = ?", (pid, host, owner)))
    return list_org!(kb, oid; read = false)
end

"Stop listing organization `owner`'s repositories for project `pid`; the codebases chosen from it stay linked."
function remove_project_org!(kb::KB, pid::Integer, host::AbstractString, owner::AbstractString)
    0 < changed!(kb, "DELETE FROM project_orgs WHERE project_id = ? AND host = ? AND owner = ? COLLATE NOCASE", (pid, host, owner)) ||
        not_found("The project does not list $host/$owner")
    return nothing
end

"""
    list_org!(kb, oid; read = true) -> Vector{String}

List the repositories of organization `oid` (a `project_orgs` row) as its project's candidates:
each one new is recorded, with whether it is a fork or archived, and one no longer listed is marked
gone. A codebase of the project whose repository is now archived is marked so. With the
organization's `auto`, a candidate neither archived, declined nor a fork (without `forks`) is linked,
and with `read` read at once. Returns the codebases linked. What stopped the listing is kept with the
organization, and thrown; either way the time it was listed is kept, for [`list_project_orgs!`](@ref).
"""
function list_org!(kb::KB, oid::Integer; read::Bool = true)
    o = only(query(kb, "SELECT * FROM project_orgs WHERE id = ?", (oid,)))
    repos = try
        org_repositories(kb.config, String(o.owner))
    catch e
        execute!(kb, "UPDATE project_orgs SET listed_at = ?, problem = ? WHERE id = ?", (now_iso(), failure_message(e), oid))
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
        execute!(kb, """UPDATE papers SET repository_archived_at = ? WHERE remote = ? AND (repository_archived_at IS NULL) = ?
                        AND id IN (SELECT codebase_id FROM project_codebases WHERE project_id = ?)""",
                 (r.archived ? now_iso() : missing, remote, r.archived ? 1 : 0, o.project_id))
    end
    for r in query(kb, "SELECT remote FROM org_repositories WHERE org_id = ? AND gone_at IS NULL", (oid,))
        r.remote in listed || execute!(kb, "UPDATE org_repositories SET gone_at = ? WHERE org_id = ? AND remote = ?", (now_iso(), oid, r.remote))
    end
    execute!(kb, "UPDATE project_orgs SET listed_at = ?, problem = NULL WHERE id = ?", (now_iso(), oid))
    new = String[]
    if o.auto == 1
        for r in query(kb, """SELECT remote FROM org_repositories r WHERE org_id = ? AND gone_at IS NULL AND declined_at IS NULL
                                  AND archived = 0 AND (fork = 0 OR ? = 1)
                                  AND NOT EXISTS (SELECT 1 FROM project_codebases pc JOIN papers d ON d.id = pc.codebase_id
                                                  WHERE pc.project_id = ? AND d.remote = r.remote)""", (oid, o.forks, o.project_id))
            id = try
                link_repository!(kb, r.remote)
            catch e
                e isa DroppedError && continue
                rethrow()
            end
            link_codebase!(kb, Int(o.project_id), Int(paper_id(kb, id)); by = String(o.added_by)) && push!(new, id)
        end
        read && read_unread!(kb, new)
    end
    tasks_changed!()
    return new
end

"""
    list_project_orgs!(kb; every = Hour(20), now = now(UTC)) -> Int

List again each project's organization not listed for `every` (see [`list_org!`](@ref)), as
[`follow_commits`](@ref) asks for: the repositories added to it since are the project's candidates,
or with its `auto`, linked and read. A failure is kept with its organization and logged, tried again
after `every` too, and the others are listed still. Returns how many codebases were linked.
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
