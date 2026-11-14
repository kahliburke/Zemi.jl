# Zotero groups linked to projects from the site (see zotero.jl), by those who maintain a project
# (admins maintain every one). Links are kept here rather
# than in the config, and the Zotero source reads them with the groups the config names; a group is
# linked to one project. A private group's API key is checked with Zotero when it is linked and kept
# as a file in the config folder that the service alone reads; the link names the file, and the key
# is not shown again. Linking reads the group at once; unlinking stops reading it, and what it brought
# in stays.

migration!(20, ["""CREATE TABLE zotero_links (
                       group_id TEXT PRIMARY KEY,
                       project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                       name TEXT NOT NULL DEFAULT '',
                       key_file TEXT NOT NULL DEFAULT '',
                       linked_by TEXT NOT NULL,
                       linked_at TEXT NOT NULL)"""])

"A Zotero group's id, from its number or its address on zotero.org (`https://www.zotero.org/groups/6748949/reefs`)."
function zotero_group_id(s::AbstractString)
    s = strip(s)
    occursin(r"^\d+$", s) && return String(s)
    m = match(r"zotero\.org/groups/(\d+)", s)
    m === nothing && error("Give a Zotero group's address (zotero.org/groups/…) or its number, not $(repr(s))")
    return String(m[1])
end

"""
    zotero_group(id; key = "") -> NamedTuple

What Zotero says of group `id`, read with API `key` where given: `(; name, items)`, its name and how
many items its library holds. Refused when Zotero has no such group, or it may not be read so.
"""
function zotero_group(id::AbstractString; key::AbstractString = "")
    headers = ["Zotero-API-Version" => "3"; isempty(key) ? Pair{String,String}[] : ["Zotero-API-Key" => key]]
    get_(path, query = Pair{String,String}[]) =
        HTTP.get("$(ZOTERO_API[])/groups/$id$path"; headers, query, status_exception = false, connect_timeout = 20, readtimeout = 30)
    r = get_("/items/top", ["limit" => "1", "format" => "json"])
    r.status == 404 && not_found("Zotero has no group $id")
    r.status in (401, 403) && error(isempty(key) ? "Group $id is private: give an API key that may read its library" :
                                                  "Zotero refused that key for group $id: give one that may read its library")
    r.status == 200 || error("Zotero answered HTTP $(r.status) for group $id")
    items = something(tryparse(Int, HTTP.header(r, "Total-Results", "0")), 0)
    g = get_("")
    name = g.status == 200 ? String(get(get(JSON.parse(String(g.body)), "data", Dict()), "name", "")) : ""
    return (; name, items)
end

"Where the API keys of linked groups are kept: a folder beside the config, which the service alone reads."
zotero_key_dir() = joinpath(dirname(config_path()), "zotero-keys")

"""
    zotero_groups(kb) -> Vector{NamedTuple}

The groups the Zotero source reads: those the config names (`[sources.zotero] groups`) and those
linked here, each `(; group, project, key, name, linked_by, linked_at, configured)`, `key` a `file:`
or `env:` reference to its API key, or empty for the config's own key (or none).
"""
function zotero_groups(kb::KB)
    out = NamedTuple[]
    d = get(kb.config.sources, "zotero", Dict{String,Any}())
    for (g, p) in get(d, "groups", Dict())
        push!(out, (; group = string(g), project = String(p), key = "", name = "", linked_by = "", linked_at = "", configured = true))
    end
    # Who linked one goes by the name they have now (see `named_now`).
    for r in query(kb, """SELECT z.*, p.key AS project, $(named_now("z.linked_by", "0", "z.linked_by")) AS linker
                          FROM zotero_links z JOIN projects p ON p.id = z.project_id ORDER BY z.linked_at""")
        any(x -> x.group == r.group_id, out) && continue          # the config's naming stands
        push!(out, (; group = String(r.group_id), project = String(r.project), key = isempty(r.key_file) ? "" : "file:" * r.key_file,
                      name = String(r.name), linked_by = String(r.linker), linked_at = String(r.linked_at), configured = false))
    end
    return out
end

"Whether any Zotero group is linked here (the source is then in use, whatever the config says)."
zotero_linked(kb::KB) = scalar(kb, "SELECT count(*) FROM zotero_links") > 0

# Linking a project's groups: its maintainers.
need_zotero!(kb::KB, caller::Caller, project::AbstractString) = need_project!(kb, caller, project, MAINTAIN)

"""
    link_zotero!(kb, caller, project, group; key = "") -> NamedTuple

Link Zotero group `group` (its number or address) to `project`, read with API `key` when it is
private; returns `(; group, name, items)`. Refused when it is linked elsewhere or named in the config,
or Zotero will not let it be read so. Its items are read at once.
"""
function link_zotero!(kb::KB, caller::Caller, project::AbstractString, group::AbstractString; key::AbstractString = "")
    k = need_zotero!(kb, caller, project)
    id = zotero_group_id(group)
    other = [g for g in zotero_groups(kb) if g.group == id]
    if !isempty(other)
        g = only(other)
        g.configured && error("Group $id is named in the config's [sources.zotero]: change it there")
        g.project == k || error("Group $id is linked to $(g.project) already: unlink it there first")
    end
    key = strip(key)
    info = zotero_group(id; key)
    file = ""
    if !isempty(key)
        dir = zotero_key_dir()
        mkpath(dir); chmod(dir, 0o700)
        file = joinpath(dir, "$id.key")
        write_atomic(file, key * "\n")
        chmod(file, 0o600)
    elseif !isempty(other) && !isempty(only(other).key)
        file = only(other).key[6:end]                             # linked again without a key: the one it had stays
    end
    execute!(kb, """INSERT OR REPLACE INTO zotero_links (group_id, project_id, name, key_file, linked_by, linked_at)
                    VALUES (?, (SELECT id FROM projects WHERE key = ?), ?, ?, ?, ?)""",
             (id, k, info.name, file, person_id(caller), now_iso()))
    read_zotero_now(kb)
    return (; group = id, name = info.name, items = info.items)
end

"""
    unlink_zotero!(kb, caller, project, group)

Stop reading Zotero group `group` for `project`: its link and key go, and what it brought in stays.
Linked again later, it is read from the start.
"""
function unlink_zotero!(kb::KB, caller::Caller, project::AbstractString, group::AbstractString)
    k = need_zotero!(kb, caller, project)
    id = zotero_group_id(group)
    rows = query(kb, "SELECT z.key_file FROM zotero_links z JOIN projects p ON p.id = z.project_id WHERE z.group_id = ? AND p.key = ?", (id, k))
    isempty(rows) && not_found("Group $id is not linked to $k")
    isempty(first(rows).key_file) || rm(first(rows).key_file; force = true)
    execute!(kb, "DELETE FROM zotero_links WHERE group_id = ?", (id,))
    # Read from the start if linked again. (A run reading now drops it as it saves; see `zotero_poll`.)
    st = source_state(kb, "zotero")
    for part in ("versions", "status")
        haskey(st, part) && delete!(st[part], id)
    end
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (source_state_key("zotero"), JSON.json(st)))
end

"Have the Zotero source read now, unless it is reading already."
function read_zotero_now(kb::KB)
    s = registered_source("zotero")
    (s === nothing || source_running("zotero")) && return nothing
    try start_source_run(kb, s) catch e; @warn "Zotero could not be read now; it is read at its next run" exception = e end
    return nothing
end

"""
    zotero_links_json(kb, project = nothing) -> Vector{Dict}

The groups read, of `project` or all: each group's number, name, project, who linked it and when
(none for one the config names), and how its last reading went (`read`, `items`, `error`).
"""
function zotero_links_json(kb::KB, project::Union{AbstractString,Nothing} = nothing)
    status = get(source_state(kb, "zotero"), "status", Dict())
    [Dict("group" => g.group, "name" => g.name, "project" => g.project, "linked_by" => g.linked_by, "linked_at" => g.linked_at,
          "configured" => g.configured, "private" => !isempty(g.key),
          "read" => get(get(status, g.group, Dict()), "read", ""), "items" => get(get(status, g.group, Dict()), "items", 0),
          "error" => get(get(status, g.group, Dict()), "error", ""))
     for g in zotero_groups(kb) if project === nothing || g.project == uppercase(strip(project))]
end

# ── The API ───────────────────────────────────────────────────────────────────────────────────────

# A project's Zotero groups.
route!("GET", "/api/projects/:key/zotero"; need = "tasks.view") do c
    need_project!(c.kb, c.caller, c[:key], VIEW)
    Dict("groups" => zotero_links_json(c.kb, c[:key]),
         "may_link" => project_access(c.kb, c.caller, c[:key]) >= MAINTAIN)
end

# Link one: `{"group": "<number or address>", "key": "<API key, for a private group>"}`.
route!("POST", "/api/projects/:key/zotero"; need = "tasks.view") do c
    b = json_body(c)
    r = link_zotero!(c.kb, c.caller, c[:key], String(get(b, "group", "")); key = String(get(b, "key", "")))
    Dict("group" => r.group, "name" => r.name, "items" => r.items)
end

route!("POST", "/api/projects/:key/zotero/:group/unlink"; need = "tasks.view") do c
    unlink_zotero!(c.kb, c.caller, c[:key], c[:group])
    ok_json()
end

# Every group read, for the Configuration page.
route!("GET", "/api/zotero"; need = "config.view") do c
    Dict("groups" => zotero_links_json(c.kb), "prescreen" => get(get(c.kb.config.sources, "zotero", Dict()), "prescreen", true) !== false)
end
