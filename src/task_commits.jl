# Commits against tasks: a commit names the tasks it did in a trailer at the end of its message,
#
#     Tasks: KB-105, KB-100
#
# and the codebases projects are linked to are read for commits on every branch, as they come: all
# of them, for the codebase's activity (see `code_activity`), and those naming tasks linked to them,
# so a task shows the commits that did its work and its diff, and a file the tasks that changed it.

"""
What a reading records of a commit, as a version: a reading of a newer version reads every codebase
again from the start, rebuilding what it recorded (as after history is rewritten, when commits have
new hashes).
"""
const COMMIT_READER = 4

# A list of task references joined by commas, "and" or "&".
const TASK_REFS = Regex("($(TASK_REF.pattern)(?:\\s*(?:,|;|&|\\band\\b)\\s*$(TASK_REF.pattern))*)")
# Words that say a commit finished a task, as code hosts read them ("Fixes KB-12 and KB-14"), and
# that it was part of one ("Part of KB-12"); a trailer line naming tasks says the latter too.
const FINISHES_TASK = Regex("\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|implement(?:s|ed)?|finish(?:e[sd])?|complete[sd]?)\\s*:?\\s+" *
                            TASK_REFS.pattern, "i")
const PART_OF_TASK = Regex("\\bpart\\s+of\\s*:?\\s+" * TASK_REFS.pattern, "i")
const TASKS_TRAILER = r"^(?:Tasks?|Refs?|References):[ \t]*(.+)$"mi
# A task only mentioned, written as tasks are (`KB-12`): not `utf-8` or `x86-64`.
const MENTIONED_TASK = r"(?<![\w-])[A-Z][A-Z0-9]*-\d+(?![\w-])"

const RELATIONS = ("finishes", "part", "mentions")      # strongest first

"""
    commit_relations(message) -> Vector{Pair{String,String}}

The tasks a commit `message` names, upper-cased, each with what it says of it, the strongest when it
says more than one:

- `"finishes"`: after `Fixes`, `Closes`, `Resolves`, `Implements`, `Finishes` or `Completes`, in any
  tense; read as it comes, such a commit moves the task to review (see [`read_commits!`](@ref))
- `"part"`: on a trailer line (`Tasks:`, `Task:`, `Refs:`, `Ref:` or `References:`) or after `Part of`
- `"mentions"`: anywhere else, written in capitals as a task is

A commit that finishes or is part of a task is its work: in its commits, its diff and its files'
history. One that only mentions it is listed with it, apart.
"""
function commit_relations(message::AbstractString)
    found = Dict{String,String}()
    note!(ref, relation) = (r = uppercase(ref); haskey(found, r) && findfirst(==(found[r]), RELATIONS) <= findfirst(==(relation), RELATIONS) ||
                            (found[r] = relation))
    order = String[]
    for m in eachmatch(TASKS_TRAILER, message), w in split(m[1], r"[\s,;]+")
        is_task_ref(w) && (push!(order, uppercase(w)); note!(w, "part"))
    end
    for (pattern, relation) in ((FINISHES_TASK, "finishes"), (PART_OF_TASK, "part")), m in eachmatch(pattern, message), r in eachmatch(TASK_REF, m[1])
        push!(order, uppercase(r.match)); note!(r.match, relation)
    end
    for m in eachmatch(MENTIONED_TASK, message)
        push!(order, m.match); note!(m.match, "mentions")
    end
    return [r => found[r] for r in unique(order)]
end

"The tasks a commit `message` says it did: those it finishes or is part of (see [`commit_relations`](@ref))."
commit_tasks(message::AbstractString) = [r for (r, rel) in commit_relations(message) if rel != "mentions"]

"Whether `root` is in a git repository (a checkout or a worktree)."
in_git(root::AbstractString) = isdir(root) && success(pipeline(`git -C $root rev-parse --git-dir`; stdout = devnull, stderr = devnull))

"The commit ids of the branch tips and HEAD of the repository at `root`, each with its name."
function git_tips(root::AbstractString)
    tips = Pair{String,String}[]
    for l in readlines(`git -C $root for-each-ref "--format=%(objectname)%09%(refname)" refs/heads refs/remotes refs/tags`)
        sha, name = split(l, '\t'; limit = 2)
        push!(tips, String(sha) => String(name))
    end
    head = try readchomp(pipeline(`git -C $root rev-parse HEAD`; stderr = devnull)) catch; "" end
    isempty(head) || push!(tips, head => "HEAD")
    return tips
end

"""
    read_commits!(kb, codebase) -> Int

Read codebase `codebase`'s repository for commits not read before (all of them when an older reader
read it, see `COMMIT_READER`), on every branch, record them, and link each to the tasks in the
knowledge base it names, as it names them (see [`commit_relations`](@ref)). A commit new since the
last reading that finishes tasks moves each to review that is in progress and has not changed
column since the commit was made (a later move by hand stands); a first reading, or one again from
the start, only records. Returns how many commits were read; 0 when the
codebase is not in a git repository.
"""
function read_commits!(kb::KB, codebase::AbstractString)
    cid = paper_id(kb, codebase)
    root = codebase_dir(kb, codebase)
    (isempty(root) || !in_git(root)) && return 0
    tips = git_tips(root)
    # The tips it was last read to, unless an older reader read it (see COMMIT_READER): then all of it again.
    reader = "commit_reader:$codebase"
    current = coalesce(scalar(kb, "SELECT value FROM kv WHERE key = ?", (reader,)), "") == string(COMMIT_READER)
    seen = current ? Set(String(r.sha) for r in query(kb, "SELECT sha FROM codebase_tips WHERE codebase_id = ?", (cid,))) : Set{String}()
    new = unique([name for (sha, name) in tips if !(sha in seen)])
    isempty(new) && return 0
    # From the new tips, leaving out what was read from the old ones (those that still exist).
    old = [s for s in seen if success(pipeline(`git -C $root cat-file -e "$(s)^{commit}"`; stderr = devnull))]
    out = read(`git -C $root log --reverse --source --format=%x1e%H%x1f%aI%x1f%an%x1f%S%x1f%B%x1f --numstat $new --not $old --`, String)
    n = 0
    # Only the tasks of projects linked to this codebase: a commit naming another project's task (one
    # its author may not even see, or of a key that happens to match) does nothing to it.
    linked = Set(Int(r.id) for r in query(kb, "SELECT t.id FROM tasks t JOIN projects p ON p.id = t.project_id WHERE p.codebase_id = ?", (cid,)))
    incremental = current && !isempty(seen)
    finishing = Tuple{Int,String,String,String,String}[]    # (task, commit, its time, subject, author), to move to review
    transaction(kb) do
        current || execute!(kb, "DELETE FROM commits WHERE codebase_id = ?", (cid,))   # from the start: rebuilt
        for record in split(out, '\x1e'; keepempty = false)
            fields = split(record, '\x1f')
            length(fields) >= 6 || continue
            sha, at, author, ref, message, stat = fields
            named = [(id, rel) for (id, rel) in ((task_id_or_nothing(kb, r), rel) for (r, rel) in commit_relations(message))
                     if id !== nothing && id in linked]
            files = Any[]
            for l in split(strip(stat), '\n'; keepempty = false)
                parts = split(l, '\t'; limit = 3)
                length(parts) == 3 || continue
                push!(files, Dict("path" => parts[3], "added" => something(tryparse(Int, parts[1]), 0),
                                  "removed" => something(tryparse(Int, parts[2]), 0)))
            end
            subject = String(strip(first(split(message, '\n'))))
            new_commit = changed!(kb, """INSERT INTO commits (codebase_id, sha, at, author, subject, ref, files) VALUES (?, ?, ?, ?, ?, ?, ?)
                                         ON CONFLICT (codebase_id, sha) DO NOTHING""",
                                  (cid, sha, iso(parse_iso(at)), author, subject, replace(ref, r"^refs/(heads|remotes|tags)/" => ""), JSON.json(files))) == 1
            commit = Int(scalar(kb, "SELECT id FROM commits WHERE codebase_id = ? AND sha = ?", (cid, sha)))
            for (id, rel) in named
                execute!(kb, """INSERT INTO task_commits (task_id, commit_id, relation) VALUES (?, ?, ?)
                                ON CONFLICT (task_id, commit_id) DO UPDATE SET relation = excluded.relation""", (id, commit, rel))
                incremental && new_commit && rel == "finishes" && push!(finishing, (id, String(sha), iso(parse_iso(at)), subject, String(author)))
            end
            n += 1
        end
        execute!(kb, "DELETE FROM codebase_tips WHERE codebase_id = ?", (cid,))
        foreach(sha -> execute!(kb, "INSERT OR IGNORE INTO codebase_tips VALUES (?, ?)", (cid, sha)), unique(first.(tips)))
        execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (reader, string(COMMIT_READER)))
    end
    for (id, sha, at, subject, author) in finishing
        scalar(kb, "SELECT status FROM tasks WHERE id = ?", (id,)) == "in_progress" || continue
        moved = coalesce(scalar(kb, "SELECT max(at) FROM task_events WHERE task_id = ? AND kind = 'status'", (id,)), "")
        moved > at && continue                         # moved since the commit: that decision stands
        ref = String(scalar(kb, "SELECT p.key || '-' || t.number FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.id = ?", (id,)))
        by = Actor("commit $(first(sha, 8))", true)
        try
            update_task!(kb, ref; status = "review", by)
            note_task!(kb, ref, "Commit `$(first(sha, 8))` by $author, \"$subject\", says it finishes this: moved to Review."; kind = "progress", by)
        catch e
            @warn "A commit could not move $ref to review" exception = e
        end
    end
    n > 0 && tasks_changed!()
    return n
end

"Read the commits of every codebase a project is linked to (see [`read_commits!`](@ref)); returns how many were recorded."
read_all_commits!(kb::KB) =
    sum((read_commits!(kb, String(r.doc_id)) for r in query(kb,
        "SELECT DISTINCT d.doc_id FROM projects p JOIN papers d ON d.id = p.codebase_id")); init = 0)

"""
    follow_commits(kb; every = 30)

For a running service: read the linked codebases' commits now and every `every` seconds, for as long
as the process runs, in shared mode fetching each codebase's repository first, and then mark the
findings whose evidence changed (see [`check_findings!`](@ref)). In shared mode it then starts the
nightly ingest when it is due (see [`nightly_ingest!`](@ref)), from the repositories just fetched. A
failure is logged once and tried again next time.
"""
function follow_commits(kb::KB; every::Real = 30)
    every!("Reading commits for tasks"; seconds = every) do
        fetch_codebases!(kb)               # the clones of the repositories codebases are read from, first
        read_all_commits!(kb)
        check_findings!(kb)                # with the code read, what changed under findings
        SHARED_MODE[] && nightly_ingest!(kb)
    end
    return nothing
end

"""
    task_commits(kb, id) -> Vector{NamedTuple}

The commits recorded against task `id` and the tasks under it at every depth, oldest first:
`(; sha, at, author, subject, ref, files, added, removed, url, task)`, `url` the commit on its
repository's web page where its remote has one, `task` the reference of the task it names.
"""
function task_commits(kb::KB, id::Integer)
    rows = query(kb, """
        WITH RECURSIVE below(id) AS (SELECT ? UNION ALL SELECT t.id FROM tasks t JOIN below b ON t.parent_id = b.id)
        SELECT c.sha, c.at, c.author, c.subject, c.ref, c.files, d.doc_id AS codebase, min(p.key || '-' || t.number) AS task
        FROM task_commits tc JOIN below b ON b.id = tc.task_id AND tc.relation != 'mentions' JOIN commits c ON c.id = tc.commit_id
        JOIN papers d ON d.id = c.codebase_id JOIN tasks t ON t.id = tc.task_id JOIN projects p ON p.id = t.project_id
        GROUP BY c.id ORDER BY c.at, c.id""", (id,))
    dirs = Dict{String,String}()
    dir(codebase) = get!(() -> codebase_dir(kb, codebase), dirs, codebase)
    return [begin
        files = JSON.parse(r.files)
        root = dir(String(r.codebase))
        (; sha = String(r.sha), at = String(r.at), author = String(r.author), subject = String(r.subject), ref = String(r.ref),
           files, added = sum(f -> f["added"], files; init = 0), removed = sum(f -> f["removed"], files; init = 0),
           url = commit_url(root, r.sha), task = String(r.task), root)
    end for r in rows]
end

const REMOTE_URLS = LockedDict{String,String}()

"The web page of the repository at `root`, from its `origin` remote (GitHub, GitLab and the like), or `\"\"`."
function remote_url(root::AbstractString)
    isempty(root) && return ""
    get!(REMOTE_URLS, root) do
        m = match(r"^(?:git@([^:]+):|https?://(?:[^@/]+@)?([^/]+)/)(.+?)(?:\.git)?/?$", git_origin(root))
        m === nothing ? "" : "https://$(something(m[1], m[2]))/$(m[3])"
    end
end

commit_url(root::AbstractString, sha::AbstractString) = (u = remote_url(root); isempty(u) ? "" : "$u/commit/$sha")

"""
    task_diff(kb, ref; max_chars = 60_000) -> String

The changes made by task `ref`'s commits (and those of the tasks under it), oldest first, each as
`git show` gives it, cut at `max_chars`.
"""
function task_diff(kb::KB, ref::AbstractString; max_chars::Integer = 60_000)
    cs = task_commits(kb, task_ref(kb, ref))
    isempty(cs) && return ""
    io = IOBuffer()
    for c in cs
        in_git(c.root) || continue
        write(io, read(`git -C $(c.root) show --stat --patch --format=commit\ %H%nAuthor:\ %an%nDate:\ \ \ %aI%n%n%B $(c.sha)`, String))
        println(io)
        position(io) > max_chars && break
    end
    text = String(take!(io))
    return length(text) > max_chars ? first(text, max_chars) * "\n… (cut at $max_chars characters)" : text
end

"""
    file_work(kb, codebase, path) -> Vector{NamedTuple}

The tasks whose commits changed file `path` of `codebase`, the latest first: `(; ref, title, status,
commits, at)`, `commits` how many of theirs changed it and `at` when the last did.
"""
file_work(kb::KB, codebase::AbstractString, path::AbstractString) =
    [(; ref = String(r.ref), title = String(r.title), status = String(r.status), commits = Int(r.n), at = String(r.at))
     for r in query(kb, """
        SELECT p.key || '-' || t.number AS ref, t.title, t.status, count(DISTINCT c.id) AS n, max(c.at) AS at
        FROM commits c JOIN json_each(c.files) f JOIN task_commits tc ON tc.commit_id = c.id AND tc.relation != 'mentions'
        JOIN tasks t ON t.id = tc.task_id JOIN projects p ON p.id = t.project_id
        WHERE c.codebase_id = ? AND json_extract(f.value, '\$.path') = ? AND t.declined_at IS NULL
        GROUP BY t.id ORDER BY max(c.at) DESC""", (paper_id(kb, codebase), path))]

"""
    code_activity(kb, key; days = nothing, now = now(UTC)) -> Union{Dict,Nothing}

What project `key`'s codebase has seen, as a code host shows it, or `nothing` without a codebase.
Over the last `days` (all of its history when `nothing`):

- `totals`: `commits`, lines `added` and `removed`, `files` changed, `contributors`, and `with_tasks`
  (commits whose trailer names a task)
- `step` ("day", "week" or "month") and `buckets`, each with `start`, `commits`, `added` and `removed`
- `authors`, the most commits first: `name`, `commits`, `added`, `removed`, `first` and `last`

and, whatever `days` is, `calendar`: the commits of each day of the last year that had any (`day`,
`commits`), with `today`.
"""
function code_activity(kb::KB, key::AbstractString; days::Union{Integer,Nothing} = nothing, now::DateTime = Dates.now(UTC))
    cid = scalar(kb, "SELECT codebase_id FROM projects WHERE key = ?", (uppercase(strip(key)),))
    ismissing(cid) && return nothing
    rows = [(; at = parse_iso(String(r.at)), author = String(r.author), files = JSON.parse(r.files), tasked = r.tasked == 1)
            for r in query(kb, """SELECT c.at, c.author, c.files, EXISTS (SELECT 1 FROM task_commits tc WHERE tc.commit_id = c.id AND tc.relation != 'mentions') AS tasked
                                  FROM commits c WHERE c.codebase_id = ? ORDER BY c.at""", (cid,))]
    added(r) = sum(f -> f["added"], r.files; init = 0)
    removed(r) = sum(f -> f["removed"], r.files; init = 0)
    from = days === nothing ? (isempty(rows) ? now : first(rows).at) : now - Day(days)
    span = [r for r in rows if from <= r.at <= now]
    step, width = now - from <= Day(31) ? ("day", Day(1)) : now - from <= Day(400) ? ("week", Week(1)) : ("month", Month(1))
    buckets = Dict{String,Any}[]
    for s in floor(from, width):width:now
        in_it = [r for r in span if s <= r.at < s + width]
        push!(buckets, Dict("start" => iso(s), "commits" => length(in_it),
                            "added" => sum(added, in_it; init = 0), "removed" => sum(removed, in_it; init = 0)))
    end
    authors = Dict{String,Dict{String,Any}}()
    for r in span
        a = get!(() -> Dict{String,Any}("name" => r.author, "commits" => 0, "added" => 0, "removed" => 0, "first" => iso(r.at)), authors, r.author)
        a["commits"] += 1; a["added"] += added(r); a["removed"] += removed(r); a["last"] = iso(r.at)
    end
    year = now - Day(365)
    calendar = Dict{String,Int}()
    for r in rows
        r.at >= year && (calendar[Dates.format(r.at, dateformat"yyyy-mm-dd")] = get(calendar, Dates.format(r.at, dateformat"yyyy-mm-dd"), 0) + 1)
    end
    return Dict(
        "totals" => Dict("commits" => length(span), "added" => sum(added, span; init = 0), "removed" => sum(removed, span; init = 0),
                         "files" => length(unique(f["path"] for r in span for f in r.files)), "contributors" => length(authors),
                         "with_tasks" => count(r -> r.tasked, span)),
        "step" => step, "buckets" => buckets,
        "authors" => sort!(collect(values(authors)); by = a -> -a["commits"]),
        "calendar" => Any[Dict("day" => d, "commits" => n) for (d, n) in sort!(collect(calendar))],
        "today" => Dates.format(now, dateformat"yyyy-mm-dd"))
end

"""
    task_mentions(kb, id) -> Vector{NamedTuple}

The commits that only mention task `id` (see [`commit_relations`](@ref)), oldest first: `(; sha, at,
author, subject, url)`.
"""
task_mentions(kb::KB, id::Integer) =
    [(; sha = String(r.sha), at = String(r.at), author = String(r.author), subject = String(r.subject),
        url = commit_url(codebase_dir(kb, String(r.codebase)), r.sha))
     for r in query(kb, """SELECT c.sha, c.at, c.author, c.subject, d.doc_id AS codebase FROM task_commits tc
                           JOIN commits c ON c.id = tc.commit_id JOIN papers d ON d.id = c.codebase_id
                           WHERE tc.task_id = ? AND tc.relation = 'mentions' ORDER BY c.at, c.id""", (id,))]
