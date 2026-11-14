# Searching the projects: every task's title and plan, and each comment, progress note and question
# on it, as rows of a full-text index, ranked by BM25 with titles counting most. A query mixes
# words with filters (`status:ready`, `is:open`, `assignee:me`, `milestone:"…"`, …); its last word
# matches as a prefix, so results come while it is being typed.

const SEARCHED_NOTES = ("comment", "progress", "question")

"Index task `id`'s title and plan again, as they are now."
function index_task_text!(kb::KB, id::Integer)
    execute!(kb, "DELETE FROM task_search WHERE task_id = ? AND event_id IS NULL", (id,))
    t = first(query(kb, "SELECT title, body FROM tasks WHERE id = ?", (id,)))
    execute!(kb, "INSERT INTO task_search (title, plan, note, task_id) VALUES (?, '', '', ?)", (t.title, id))
    isempty(t.body) || execute!(kb, "INSERT INTO task_search (title, plan, note, task_id) VALUES ('', ?, '', ?)", (t.body, id))
end

"Index note `event_id` of task `id`, its `text`."
index_note!(kb::KB, id::Integer, event_id::Integer, text::AbstractString) =
    execute!(kb, "INSERT INTO task_search (title, plan, note, task_id, event_id) VALUES ('', '', ?, ?, ?)", (text, id, event_id))

"Drop what the index holds for tasks that no longer exist."
prune_task_search!(kb::KB) = execute!(kb, "DELETE FROM task_search WHERE task_id NOT IN (SELECT id FROM tasks)")

"""
    TaskQuery

A parsed search: the `words` and quoted `phrases` to find (the last word as a prefix when
`prefix`), the task references named (`refs`), and the `filters`, as name => value pairs. A person
named as `@[Ada](person:ada@x.org)` is a `person` filter.
"""
struct TaskQuery
    words::Vector{String}
    phrases::Vector{String}
    refs::Vector{String}
    filters::Vector{Pair{String,String}}
    prefix::Bool
end

const TASK_FILTERS = ("status", "is", "assignee", "milestone", "project", "by", "person")

"""
    parse_task_query(q) -> TaskQuery

Words, `"exact phrases"`, task references (`KB-12`), and filters written `name:value` or
`name:"two words"` (see [`search_tasks`](@ref)). The last word matches as a prefix unless the query
ends with a space.
"""
function parse_task_query(q::AbstractString)
    words, phrases, refs, filters = String[], String[], String[], Pair{String,String}[]
    for m in eachmatch(r"@\[[^\]\n]*\]\(person:([^)\s]+)\)", q)
        push!(filters, "person" => String(m[1]))
    end
    q = replace(q, r"@\[[^\]\n]*\]\(person:[^)\s]+\)" => " ")
    for m in eachmatch(r"(\w+):(?:\"([^\"]*)\"?|(\S+))|\"([^\"]+)\"?|(\S+)", q)
        if m[1] !== nothing && lowercase(m[1]) in TASK_FILTERS
            push!(filters, lowercase(m[1]) => String(something(m[2], m[3], "")))
        elseif m[4] !== nothing
            push!(phrases, strip(m[4]))
        else
            tok = String(something(m[5], m.match))
            is_task_ref(lstrip(tok, '@')) ? push!(refs, uppercase(lstrip(tok, '@'))) :
                append!(words, [w.match for w in eachmatch(r"[\p{L}\p{N}]+", tok)])
        end
    end
    prefix = !isempty(words) && !endswith(q, ' ') && !endswith(q, '"') && endswith(rstrip(q), last(words))
    return TaskQuery(words, phrases, refs, filters, prefix)
end

"The FTS5 query for `tq`'s words and phrases (all of them must match), or `\"\"` when it has none."
function fts_query(tq::TaskQuery)
    parts = ["\"$(replace(w, '"' => ""))\"" for w in tq.words]
    tq.prefix && !isempty(parts) && (parts[end] *= "*")
    append!(parts, ["\"$(replace(p, '"' => ""))\"" for p in tq.phrases if !isempty(p)])
    return join(parts, " ")
end

"""
    fts_rows(kb, sql, args) -> rows

The rows of a full-text query, none for a query FTS5 cannot parse.
"""
function fts_rows(kb::KB, sql::AbstractString, args)
    try
        return query(kb, sql, args)
    catch e
        e isa SQLite.SQLiteException || rethrow()
        return Any[]
    end
end

"`tq`'s words and phrases as text to search by meaning, or `nothing` when there is too little of it to mean something."
function meaning_text(tq::TaskQuery)
    text = join([tq.words; tq.phrases], " ")
    return length(replace(text, r"\s" => "")) >= 4 ? text : nothing
end

"""
    rrf_scores(rankings...; k = 10) -> Dict

Reciprocal rank fusion: each id scores `1 / (k + rank)` in every one of `rankings` (ids, best first)
it is in, summed.
"""
function rrf_scores(rankings...; k::Real = 10)
    out = Dict{Any,Float64}()
    for r in rankings, (rank, id) in enumerate(r)
        out[id] = get(out, id, 0.0) + 1 / (k + rank)
    end
    return out
end

"""
    rank_found(named, rankings...) -> (ids, score)

What a search of tasks or findings found, put together: the ids `named` by reference, then those
in `rankings` (by words, by meaning, …), each once; and `score(id)`, the reciprocal rank fusion of
the rankings (see [`rrf_scores`](@ref)), with 1 more for one named, which puts it first.
"""
function rank_found(named, rankings...)
    scores = rrf_scores(rankings...)
    score(id) = (id in named ? 1.0 : 0.0) + get(scores, id, 0.0)
    return unique(Iterators.flatten((named, rankings...))), score
end

"""
SQL conditions on the task listing (see `TASK_SELECT`) for `tq`'s filters, with their arguments,
and whether the filters ask for archived or declined tasks. `me` is whom `assignee:me` means.
"""
function filter_conditions(kb::KB, tq::TaskQuery; me::AbstractString = "")
    conds, args = String[], Any[]
    archived = declined = false
    for (name, v) in tq.filters
        v = strip(v)
        if name == "status"
            push!(conds, "t.status = ?"); push!(args, check_status(replace(lowercase(v), r"[\s-]+" => "_")))
        elseif name == "is"
            w = lowercase(v)
            w == "archived" ? (archived = true) : w == "declined" ? (declined = true) :
            w == "open" ? push!(conds, "t.status != 'done'") :
            w == "blocked" ? push!(conds, "t.blocked != ''") :
            w in ("sent-back", "sentback", "sent_back") ? push!(conds, SENT_BACK) :
            w in ("subtask", "sub") ? push!(conds, "t.parent_id IS NOT NULL") :
            w in ("top", "task") ? push!(conds, "t.parent_id IS NULL") :
            (push!(conds, "t.status = ?"); push!(args, check_status(replace(w, r"[\s-]+" => "_"))))
        elseif name == "assignee"
            w = lowercase(v)
            w == "me" ? (push!(conds, "t.assignee = ?"); push!(args, me)) :
            w in ("agent", "agents") ? push!(conds, "t.assignee LIKE 'agent:%'") :
            w in ("none", "nobody") ? push!(conds, "t.assignee = ''") :
            (push!(conds, "lower(t.assignee) LIKE ?"); push!(args, "%$w%"))
        elseif name == "milestone"
            lowercase(v) == "none" ? push!(conds, "t.milestone_id IS NULL") : (push!(conds, "lower(m.name) = ?"); push!(args, lowercase(v)))
        elseif name == "project"
            push!(conds, "p.key = ?"); push!(args, uppercase(v))
        elseif name == "by"
            push!(conds, "lower(t.created_by) LIKE ?"); push!(args, "%$(lowercase(v))%")
        elseif name == "person"
            ids = collect(keys(person_tasks(kb, people_named(kb, v))))
            push!(conds, isempty(ids) ? "0" : "t.id IN ($(join(ids, ',')))")
        end
    end
    push!(conds, declined ? "t.declined_at IS NOT NULL" : archived ? "t.archived_at IS NOT NULL AND t.declined_at IS NULL" :
                 "t.archived_at IS NULL")
    return conds, args
end

"What a task found by meaning alone shows: the start of the document that was nearest (see `task_documents`)."
function meaning_match(kb::KB, key::AbstractString)
    if startswith(key, "e:")
        e = first(query(kb, "SELECT text, $(event_who("task_events")) AS who, at, kind FROM task_events WHERE id = ?", (parse(Int, key[3:end]),)))
        return (; field = "note", snippet = first(String(e.text), 200), event = parse(Int, key[3:end]), who = String(e.who),
                  at = String(e.at), kind = String(e.kind))
    end
    t = first(query(kb, "SELECT title, body FROM tasks WHERE id = ?", (parse(Int, key[3:end]),)))
    return (; field = isempty(t.body) ? "title" : "plan", snippet = first(String(isempty(t.body) ? t.title : t.body), 200),
              event = 0, who = "", at = "", kind = "")
end

"""
    people_named(kb, who) -> Vector{NamedTuple}

The people `who` names, as `(; name, email)`: an email, or a name written as the beginnings of its
words (`Ben`, `Ben Ma`), a longer word allowed one letter off (`Benedict` for `Benedikt`). Every
word of `who` must begin one of the person's.
"""
function people_named(kb::KB, who::AbstractString)
    w = lowercase(strip(who))
    isempty(w) && return NamedTuple[]
    list = [(; name = p.label, email = p.id) for p in people(kb) if !p.agent]
    occursin('@', w) && return filter(p -> lowercase(p.email) == w, list)
    words = [m.match for m in eachmatch(r"[\p{L}\p{N}]+", w)]
    isempty(words) && return NamedTuple[]
    close(word, token) = startswith(token, word) || (length(word) >= 5 && levenshtein(word, first(token, length(word))) <= 1)
    named(p) = (tokens = [m.match for m in eachmatch(r"[\p{L}\p{N}]+", lowercase(p.name * " " * split(p.email, '@')[1]))];
                all(word -> any(t -> close(word, t), tokens), words))
    return filter(named, list)
end

"The edit distance between `a` and `b`: letters to insert, delete or change to make one the other."
function levenshtein(a::AbstractString, b::AbstractString)
    a, b = collect(a), collect(b)
    d = collect(0:length(b))
    for i in 1:length(a)
        prev, d[1] = d[1], i
        for j in 1:length(b)
            prev, d[j+1] = d[j+1], min(d[j+1] + 1, d[j] + 1, prev + (a[i] == b[j] ? 0 : 1))
        end
    end
    return d[end]
end

"""
    person_tasks(kb, people) -> Dict{Int,Vector{NamedTuple}}

The tasks `people` took part in, by task id, each with what they did, the latest first: created,
commented on, moved, edited, asked about it (an agent working for them counts as them), are
assigned to, or are named in (a person link, which an @-mention also makes). Each is `(; event, who, at, kind, what)`; being assigned has `event` 0.
"""
function person_tasks(kb::KB, people)
    out = Dict{Int,Vector{NamedTuple}}()
    for p in people
        names = unique([p.name, p.email])
        marks = in_marks(length(names))
        rows = query(kb, """SELECT id, task_id, $(event_who("task_events")) AS who, at, kind, text, detail FROM task_events
                            WHERE (by_person = ? COLLATE NOCASE AND by_person != '') OR who IN ($marks) OR who LIKE ? OR who LIKE ?
                            ORDER BY id DESC""",
                     Tuple([p.email; names; "% for " * p.name; "% for " * p.email]))
        for r in rows
            e = (; kind = String(r.kind), text = coalesce(r.text, ""), detail = JSON.parse(coalesce(r.detail, "{}")))
            what = try event_text(e) catch; String(r.kind) end
            push!(get!(Vector{NamedTuple}, out, Int(r.task_id)),
                  (; event = Int(r.id), who = String(r.who), at = String(r.at), kind = e.kind, what = first(what, 200)))
        end
        for r in query(kb, "SELECT id, updated_at FROM tasks WHERE assignee IN ($marks)", Tuple(names))
            push!(get!(Vector{NamedTuple}, out, Int(r.id)), (; event = 0, who = p.name, at = String(r.updated_at), kind = "assigned", what = "assigned to it"))
        end
        # Tasks that name them: a person link, which an @-mention in a plan or note also makes.
        for r in query(kb, """SELECT t.id, coalesce((SELECT max(e.at) FROM task_events e WHERE e.task_id = t.id AND e.kind = 'link'
                                                        AND e.text LIKE '%' || l.target || '%'), t.created_at) AS at
                              FROM task_links l JOIN tasks t ON t.id = l.task_id WHERE l.kind = 'person' AND l.target IN ($marks)""",
                       Tuple(names))
            push!(get!(Vector{NamedTuple}, out, Int(r.id)), (; event = 0, who = p.name, at = String(r.at), kind = "named", what = "named in it"))
        end
    end
    foreach(v -> sort!(v; by = x -> x.at, rev = true), values(out))
    return out
end

"""
    search_tasks(kb, q; project = "", me = "", limit = 30, projects = nothing) -> Vector{NamedTuple}

Tasks matching search `q`, best first: its words in a task's title, plan or notes (comments,
progress notes, questions), with these filters, any of them:

- `status:ready` (or `is:ready`), any column; `is:open`, `is:blocked`, `is:sent-back`,
  `is:subtask`, `is:archived`, `is:declined` (archived and declined tasks are otherwise left out)
- `assignee:me` (`me`), `assignee:agent`, `assignee:none`, or part of a name
- `milestone:"UI Improvements"` (or `milestone:none`), `project:KB`, `by:<who planned it>`
- `person:Ada` (a name, the beginnings of its words, or an email; or `@[Ada](person:ada@x.org)`):
  the tasks the person created, commented on, moved, edited or is assigned to
- task references, `KB-12`, which match that task first, and within one project a number, `12`

A query that is only a person's name (`Benjamin`) also finds the tasks they took part in, the
latest first, alongside the tasks whose text matches.

Words are also searched by meaning, where the tasks have been embedded (see task_vectors.jl): the
two rankings are fused, so a task can be found by what it is about in other words. `meaning` gives
that ranking (for tests).

Each is a task as [`tasks`](@ref) gives it, with `score` (higher is better) and `matches`: up to
three `(; field, snippet, event, who, at, kind)`, `field` being "title", "plan" or "note" (a note's
`event`, `who`, `at` and `kind` say which), or "person", what a person named in the query did on
it (its snippet saying what, as plain text). A snippet marks the matching words with `\\x01` … `\\x02`;
one found by meaning alone has none. Filters alone list the tasks they match, most recently changed
first.
"""
function search_tasks(kb::KB, q::AbstractString; project::AbstractString = "", me::AbstractString = "", limit::Integer = 30,
                      meaning = task_meaning_ranking, projects = nothing)
    tq = parse_task_query(q)
    isempty(project) || any(f -> first(f) == "project", tq.filters) || push!(tq.filters, "project" => project)
    conds, args = filter_conditions(kb, tq; me)
    # Only in the projects the searcher sees, before the limit is taken, so others' tasks take none of it.
    if projects !== nothing
        isempty(projects) && return NamedTuple[]
        push!(conds, "p.key IN ($(in_marks(length(projects))))")
        append!(args, collect(projects))
    end
    fts = fts_query(tq)
    found = Dict{Int,Vector{Any}}()                      # task id => its matching rows, best first
    if !isempty(fts)
        rows = fts_rows(kb, """SELECT task_id, event_id, bm25(task_search, 10.0, 4.0, 1.0) AS rank,
                                      snippet(task_search, -1, char(1), char(2), '…', 14) AS snip,
                                      CASE WHEN title != '' THEN 'title' WHEN plan != '' THEN 'plan' ELSE 'note' END AS field
                               FROM task_search WHERE task_search MATCH ? ORDER BY rank LIMIT 600""", (fts,))
        for r in rows
            push!(get!(Vector{Any}, found, Int(r.task_id)), r)
        end
    end
    refs = Int[]
    for ref in tq.refs
        id = task_id_or_nothing(kb, ref)
        id === nothing || push!(refs, id)
    end
    # A number, within one project, is also its task with that number (`130` is KB-130).
    key = something(findlast(f -> first(f) == "project", tq.filters), 0)
    if key > 0
        for w in tq.words
            occursin(r"^\d+$", w) || continue
            id = task_id_or_nothing(kb, "$(uppercase(strip(last(tq.filters[key]))))-$w")
            id === nothing || id in refs || push!(refs, id)
        end
    end
    # By meaning too, once there is enough of the query to mean something.
    text = meaning_text(tq)
    nearest = text === nothing ? Tuple{Int,String}[] : meaning(kb, text)
    # A query that is only a person's name: the tasks they took part in, the latest first.
    named = !isempty(tq.words) && isempty(tq.phrases) && isempty(tq.refs) && sum(length, tq.words) >= 3 ?
            people_named(kb, join(tq.words, " ")) : NamedTuple[]
    took_part = person_tasks(kb, named)
    by_person = sort!(collect(keys(took_part)); by = id -> first(took_part[id]).at, rev = true)
    # What the people named in a filter did, to show with each task.
    filtered = person_tasks(kb, [p for (n, v) in tq.filters if n == "person" for p in people_named(kb, v)])
    by_words = sort!(collect(keys(found)); by = id -> first(found[id]).rank)          # BM25: lower is better
    key_meaning = Dict(nearest)
    textual = !isempty(fts) || !isempty(tq.refs) || !isempty(nearest) || !isempty(by_person)
    ids, score = rank_found(refs, by_words, first.(nearest), by_person)
    textual && isempty(ids) && return NamedTuple[]
    where = textual ? ["t.id IN ($(join(ids, ',')))"; conds] : conds
    order = textual ? "" : " ORDER BY t.updated_at DESC LIMIT $(Int(limit))"
    rows = query(kb, TASK_SELECT * " WHERE " * join(where, " AND ") * order, Tuple(args))
    out = NamedTuple[]
    for r in rows
        t = task_row(r)
        id = Int(r.id)
        hits = get(found, id, Any[])
        did = [get(took_part, id, NamedTuple[]); get(filtered, id, NamedTuple[])]
        took = [(; field = "person", snippet = x.what, event = x.event, who = x.who, at = x.at, kind = x.kind)
                for x in first(unique(x -> x.event == 0 ? (x.who, x.kind) : x.event, did), 2)]
        matches = isempty(hits) && haskey(key_meaning, id) ? [meaning_match(kb, key_meaning[id])] : map(first(hits, 3)) do h
            ev = ismissing(h.event_id) ? [] : query(kb, "SELECT $(event_who("task_events")) AS who, at, kind FROM task_events WHERE id = ?", (h.event_id,))
            e = isempty(ev) ? nothing : first(ev)
            (; field = String(h.field), snippet = String(h.snip), event = ismissing(h.event_id) ? 0 : Int(h.event_id),
               who = e === nothing ? "" : String(e.who), at = e === nothing ? "" : String(e.at), kind = e === nothing ? "" : String(e.kind))
        end
        push!(out, merge(t, (; score = score(id), matches = [took; isempty(took) ? matches : first(matches, 1)])))
    end
    textual && sort!(out; by = t -> -t.score)
    return first(out, limit)
end

# ── Matching text to tasks ────────────────────────────────────────────────────────────────────────
# A note, a meeting's follow-up or a question is matched to the tasks it is about: to find work
# already planned or decided, or what to link it to. Its words are searched together but not all
# required, since a sentence's words are rarely all in one title or note, and a task's best rows
# (its title, its plan, its notes) count together. Archived tasks are searched too: finished work is
# often what answers. Without meaning, it is a read of the database alone, so it is quick even while
# long jobs run.

"Words too common to tell tasks apart."
const MATCH_STOP_WORDS = Set(split("""
    a about above after again against all also am an and any are as at be because been before being below between
    both but by can could did do does doing done down during each few for from further had has have having he her
    here hers him his how i if in into is it its itself just let like may me might more most must my no nor not now
    of off on once only or other our ours out over own same she should so some such than that the their theirs them
    then there these they this those through to too under until up upon us very was we were what when where which
    while who whom why will with would you your yours get got make made need needs use used using want would""", ' '))

"""
    match_terms(text) -> Vector{String}

The words of `text` worth searching for: not the common ones, each once, at most 40. Identifiers
and file names count by their parts, as the index holds them (`task_search` is `task` and `search`).
"""
function match_terms(text::AbstractString)
    # Short words only as acronyms or numbers ("EC", "3D").
    kept(w) = length(w) >= 3 || any(isdigit, w) || (length(w) == 2 && all(isuppercase, w))
    words = [lowercase(m.match) for m in eachmatch(r"[\p{L}\p{N}]+", text) if kept(m.match)]
    return first(unique(w for w in words if !(w in MATCH_STOP_WORDS)), 40)
end

"""
    match_tasks(kb, items; project = "", limit = 5, archived = true, meaning = false, visible = ref -> true)
        -> Vector{NamedTuple}

The tasks each of `items` (`(; id, text)`) is about, best first: `(; id, tasks)`, each task as
[`tasks`](@ref) lists it with `score` (higher is better), `archived`, and `matches`, its best one or
two rows as `(; field, snippet, who, at, kind)` as in [`search_tasks`](@ref). An item's distinctive
words are searched together, any of them (see [`match_terms`](@ref)), and a task's three best rows
add up, its title counting most. With `archived` archived tasks are searched too; declined ones
never are. With `meaning`, every item's text is embedded in one request and that ranking fused
with the words'. `visible` says which tasks the caller may see.
"""
function match_tasks(kb::KB, items; project::AbstractString = "", limit::Integer = 5, archived::Bool = true,
                     meaning::Bool = false, visible = ref -> true, rankings = task_meaning_rankings)
    texts = [String(it.text) for it in items]
    nearest = meaning ? rankings(kb, texts) : [Tuple{Int,String}[] for _ in texts]
    conds = ["t.declined_at IS NULL"]
    archived || push!(conds, "t.archived_at IS NULL")
    args = Any[]
    isempty(project) || (push!(conds, "p.key = ?"); push!(args, uppercase(project)))
    return map(zip(items, texts, nearest)) do (it, text, near)
        terms = match_terms(text)
        rows = isempty(terms) ? Any[] :
            fts_rows(kb, """SELECT task_id, event_id, bm25(task_search, 10.0, 4.0, 1.0) AS rank,
                                   snippet(task_search, -1, char(1), char(2), '…', 14) AS snip,
                                   CASE WHEN title != '' THEN 'title' WHEN plan != '' THEN 'plan' ELSE 'note' END AS field
                            FROM task_search WHERE task_search MATCH ? ORDER BY rank LIMIT 2000""",
                     (join(("\"$w\"" for w in terms), " OR "),))
        found = Dict{Int,Vector{Any}}()
        for r in rows
            push!(get!(Vector{Any}, found, Int(r.task_id)), r)
        end
        # A task's best row counts in full, its next two half and a quarter: a title and a note naming
        # the same thing outweigh one row, without a long discussion outweighing a precise title.
        words = Dict(id => sum(-r.rank * w for (r, w) in zip(rs, (1.0, 0.5, 0.25))) for (id, rs) in found)
        by_words = sort!(collect(keys(words)); by = id -> -words[id])
        rrf = rrf_scores(by_words, first.(near))
        key_meaning = Dict(near)
        ids = unique([first(by_words, 100); first.(near)])
        isempty(ids) && return (; id = it.id, tasks = NamedTuple[])
        listed = query(kb, TASK_SELECT * " WHERE t.id IN ($(join(ids, ','))) AND " * join(conds, " AND "), Tuple(args))
        out = NamedTuple[]
        for r in listed
            t = task_row(r)
            visible(t.ref) || continue
            id = Int(r.id)
            score = meaning ? get(rrf, id, 0.0) : get(words, id, 0.0)
            hits = get(found, id, Any[])
            matches = isempty(hits) ? (haskey(key_meaning, id) ? [meaning_match(kb, key_meaning[id])] : NamedTuple[]) : map(first(hits, 2)) do h
                e = ismissing(h.event_id) ? nothing : first(query(kb, "SELECT $(event_who("task_events")) AS who, at, kind FROM task_events WHERE id = ?", (h.event_id,)))
                (; field = String(h.field), snippet = String(h.snip), event = ismissing(h.event_id) ? 0 : Int(h.event_id),
                   who = e === nothing ? "" : String(e.who), at = e === nothing ? "" : String(e.at), kind = e === nothing ? "" : String(e.kind))
            end
            push!(out, merge(t, (; score, archived = !isempty(t.archived_at), matches)))
        end
        sort!(out; by = t -> -t.score)
        (; id = it.id, tasks = first(out, limit))
    end
end

"""
    task_statuses(kb, refs) -> Vector{NamedTuple}

Where each of `refs` stands, for a client following a set of tasks: `(; ref, status, archived,
updated_at, last_note_at)`, `last_note_at` the time of its latest comment, progress note or question
(`""` for none). A reference to no task is left out.
"""
function task_statuses(kb::KB, refs)
    out = NamedTuple[]
    for ref in refs
        id = task_id_or_nothing(kb, String(ref))
        id === nothing && continue
        r = first(query(kb, """SELECT t.status, t.archived_at, t.updated_at, p.key, t.number,
                                      (SELECT max(e.at) FROM task_events e WHERE e.task_id = t.id AND e.kind IN ('comment', 'progress', 'question')) AS noted
                               FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.id = ?""", (id,)))
        push!(out, (; ref = "$(r.key)-$(r.number)", status = String(r.status), archived = !ismissing(r.archived_at),
                      updated_at = String(r.updated_at), last_note_at = coalesce(r.noted, "")))
    end
    return out
end
