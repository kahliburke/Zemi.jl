# @-references in a task's plan and comments: what the text is about, named as `@KB-12` (a task),
# `@arXiv:2401.00001` (a paper), `@doc-5f13926ae1` (an uploaded one), `@res-zotero-ab12cd34` (a resource),
# `@rec-notes-2026-10-02` (a record),
# or `@[label](kind:target)` for any kind, which allows spaces in the
# label: `@[Ada Lovelace](author:lovelace|a)`, `@[Rowan Hale](person:rowan@example.org)`,
# `@code:src/tasks.jl#update_project!` (a file or a definition in the project's codebase), `@KB-F3` (a finding),
# `@[Error scaling](notebook:notebooks/papers/2409-00785/scaling.jl)`. Each is also one of the
# task's links. Code spans and blocks are left alone.

const AT_REFERENCE_KINDS = ("task", "paper", "record", "author", "person", "notebook", "code", "finding")

const AT_FULL = Regex("@\\[([^\\]\\n]+)\\]\\(($(join(AT_REFERENCE_KINDS, '|'))):([^)\\n]+)\\)")
const AT_TASK = Regex("(?<![\\w@/])@($(TASK_REF.pattern))\\b")
const AT_PAPER = Regex("(?<![\\w@/])@arXiv:$ARXIV_ID", "i")
const AT_DOC = r"(?<![\w@/])@(doc-[0-9a-f]{10})\b"
const AT_RESOURCE = r"(?<![\w@/])@(res-[a-z0-9]+(?:-[a-z0-9]+)*)"
const AT_RECORD = r"(?<![\w@/])@(rec-[a-z0-9]+(?:-[a-z0-9]+)*)"
# A file of the project's codebase, or a definition in it: a path ending in a letter or digit, then `#name`.
const AT_CODE_REF = r"(?<![\w@/])@code:([\w./-]*\w)(?:#([\w!?]+(?:\.[\w!?]+)*))?"
const AT_FINDING = Regex("(?<![\\w@/])@($(FINDING_REF.pattern))\\b")
const AT_CODE = r"```[\s\S]*?```|`[^`\n]*`"

"`text`'s pieces outside code, each with whether it is prose (`true`) or code."
function prose_pieces(text::AbstractString)
    out = Tuple{String,Bool}[]
    i = 1
    for m in eachmatch(AT_CODE, text)
        m.offset > i && push!(out, (text[i:prevind(text, m.offset)], true))
        push!(out, (m.match, false))
        i = m.offset + ncodeunits(m.match)
    end
    i <= ncodeunits(text) && push!(out, (text[i:end], true))
    return out
end

"""
    at_references(text) -> Vector{NamedTuple}

What `text` refers to with `@`, in order and once each: `(; kind, target, label)`.
"""
function at_references(text::AbstractString)
    found = Tuple{Int,NamedTuple}[]
    for (piece, prose) in prose_pieces(text)
        prose || continue
        full = collect(eachmatch(AT_FULL, piece))
        inside(m) = any(f -> f.offset <= m.offset < f.offset + ncodeunits(f.match), full)
        for m in full
            push!(found, (m.offset, (; kind = String(m[2]), target = String(strip(m[3])), label = String(strip(m[1])))))
        end
        for m in eachmatch(AT_TASK, piece)
            inside(m) || push!(found, (m.offset, (; kind = "task", target = uppercase(m[1]), label = uppercase(m[1]))))
        end
        for m in [collect(eachmatch(AT_PAPER, piece)); collect(eachmatch(AT_DOC, piece)); collect(eachmatch(AT_RESOURCE, piece))]
            inside(m) || push!(found, (m.offset, (; kind = "paper", target = String(m[1]), label = String(m[1]))))
        end
        for m in eachmatch(AT_RECORD, piece)
            inside(m) || push!(found, (m.offset, (; kind = "record", target = String(m[1]), label = String(m[1]))))
        end
        for m in eachmatch(AT_FINDING, piece)
            inside(m) || push!(found, (m.offset, (; kind = "finding", target = uppercase(m[1]), label = uppercase(m[1]))))
        end
        for m in eachmatch(AT_CODE_REF, piece)
            target = m[2] === nothing ? String(m[1]) : "$(m[1])#$(m[2])"
            inside(m) || push!(found, (m.offset, (; kind = "code", target, label = target)))
        end
    end
    refs = [r for (_, r) in sort!(found; by = first)]
    return unique(r -> (r.kind, r.target), refs)
end

"""
    link_at_references!(kb, ref, text; by)

Make what `text` refers to (see [`at_references`](@ref)) links of task `ref`, those it does not
have yet, without noting each in the activity, where the text shows them. A task that does not
exist, or the task itself, is not linked. Code is linked as `<codebase>:<path>`, in the codebase of
the task's project, and not linked when the project has none.
"""
function link_at_references!(kb::KB, ref::AbstractString, text::AbstractString; by::Actor)
    id = task_ref(kb, ref)
    for r in at_references(text)
        kind, target = r.kind, r.kind == "task" ? uppercase(r.target) : r.target
        if kind == "task"
            other = task_id_or_nothing(kb, target)
            (other === nothing || other == id) && continue
        elseif kind == "finding"
            target = uppercase(target)
            ismissing(scalar(kb, "SELECT 1 FROM findings f JOIN projects p ON p.id = f.project_id WHERE p.key || '-F' || f.number = ?",
                             (target,))) && continue
        elseif kind == "paper"
            target = current_document(kb, target)
        elseif kind == "code" && !occursin(':', target)
            codebase = task_codebase(kb, id)
            isempty(codebase) && continue
            target = "$codebase:$target"
        end
        ismissing(scalar(kb, "SELECT 1 FROM task_links WHERE task_id = ? AND kind = ? AND target = ?", (id, kind, target))) || continue
        link_task!(kb, ref, kind, target; label = r.label == target ? "" : r.label, quiet = true, by)
    end
end

"The codebase (its id) of task `id`'s project, or `\"\"`."
task_codebase(kb::KB, id::Integer) = String(coalesce(scalar(kb, """SELECT d.doc_id FROM tasks t JOIN projects p ON p.id = t.project_id
                                                                   JOIN papers d ON d.id = p.codebase_id WHERE t.id = ?""", (id,)), ""))

task_id_or_nothing(kb::KB, ref::AbstractString) = try task_ref(kb, ref) catch e; reason(e) === nothing ? rethrow() : nothing end

"""
    plain_at_references(text) -> String

`text` with its references as an agent reads them best: `@KB-12`, `@arXiv:2401.00001`, `@doc-5f13926ae1`
and `@rec-…` as they are, the others as `@label (kind target)`.
"""
plain_at_references(text::AbstractString) = join(prose ? replace(piece, AT_FULL => function (s)
        m = match(AT_FULL, s)
        kind, target, label = m[2], strip(m[3]), strip(m[1])
        kind in ("task", "finding") ? "@$(uppercase(target))" : kind in ("paper", "record") ? "@$(cited_as(target)) ($label)" :
            "@$label ($kind $target)"
    end) : piece for (piece, prose) in prose_pieces(text))

"""
    readable_at_references(kb, text) -> String

`text` with its references as a person reads them in plain text (a notification, say): a task or
finding as its reference (`@KB-12`), a person by the name their account has now, the others by
their label. Code is left as written.
"""
readable_at_references(kb::KB, text::AbstractString) = join(prose ? replace(piece, AT_FULL => function (s)
        m = match(AT_FULL, s)
        kind, target, label = m[2], strip(m[3]), strip(m[1])
        kind in ("task", "finding") && return "@$(uppercase(target))"
        kind == "person" || return "@$label"
        name = scalar(kb, "SELECT nullif(name, '') FROM users WHERE email = ? COLLATE NOCASE", (target,))
        return "@" * (ismissing(name) ? label : String(name))
    end) : piece for (piece, prose) in prose_pieces(text))

# A codebase's files and named definitions, `(; path, name, line)` (`name` empty for a file), kept
# for the picker until the codebase is read again.
const CODE_NAMES = LockedDict{String,Tuple{String,Vector{NamedTuple{(:path, :name, :line),Tuple{String,String,Int}}}}}()

function code_names(kb::KB, codebase::AbstractString)
    pid = paper_id(kb, codebase)
    stamp = string(coalesce(scalar(kb, "SELECT file_sha FROM parses WHERE paper_id = ?", (pid,)), ""))
    known = get(CODE_NAMES, codebase, nothing)
    known !== nothing && first(known) == stamp && return last(known)
    out = NamedTuple{(:path, :name, :line),Tuple{String,String,Int}}[]
    paths = Dict{Int,String}()
    for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ? ORDER BY title", (pid,))
        is_dir_section(r.title) && continue
        paths[r.ord] = r.title
        push!(out, (; path = String(r.title), name = "", line = 1))
    end
    for b in query(kb, "SELECT section, text, x0, x1 FROM blocks WHERE paper_id = ? AND kind = 'code' ORDER BY section, ord", (pid,))
        path = get(paths, b.section, nothing)
        path === nothing && continue
        d = definition(path, b.text, round(Int, b.x0), round(Int, b.x1))
        startswith(d.name, "lines ") || push!(out, (; path, name = d.name, line = d.first_line))
    end
    CODE_NAMES[codebase] = (stamp, out)
    return out
end

"""
    code_reference_matches(kb, codebase, q; limit = 8) -> Vector{NamedTuple}

Files and definitions of `codebase` for the picker, as [`at_reference_matches`](@ref) gives them
(`kind = "code"`, `target` the path or `path#name`): definitions named, and files whose name or path,
begin with `q`, then those with `q` inside their name or path.
"""
function code_reference_matches(kb::KB, codebase::AbstractString, q::AbstractString; limit::Integer = 8)
    q = lowercase(replace(strip(q), r"^code:" => ""))
    isempty(q) && return NamedTuple[]
    rank(n) = (l = lowercase(isempty(n.name) ? basename(n.path) : n.name);
               startswith(l, q) ? 0 : startswith(lowercase(n.path), q) ? 1 : occursin(q, l) || occursin(q, lowercase(n.path)) ? 2 : 3)
    hits = sort!([n for n in code_names(kb, codebase) if rank(n) < 3]; by = n -> (rank(n), isempty(n.name), length(n.path)))
    return [(; kind = "code", target = isempty(n.name) ? n.path : "$(n.path)#$(n.name)",
               label = isempty(n.name) ? n.path : n.name, detail = isempty(n.name) ? "file" : "$(n.path):$(n.line)")
            for n in first(hits, limit)]
end

"""
    at_reference_matches(kb, q; limit = 5, project = "", caller = local_caller()) -> Vector{NamedTuple}

What a reference being typed as `@q` may mean, for the board's picker: tasks, papers, the records
`caller` may see, authors, people and notebooks with a word beginning `q`, up to `limit` of each kind,
as `(; kind, target, label, detail)`, and with a `project` that has a codebase `caller` may see, its files and definitions (see
[`code_reference_matches`](@ref)). Those whose label `q` begins come first, then those with a word
of the label beginning it.
"""
function at_reference_matches(kb::KB, q::AbstractString; limit::Integer = 5, project::AbstractString = "",
                              caller::Caller = local_caller())
    codebase = isempty(project) ? "" :
        String(coalesce(scalar(kb, "SELECT d.doc_id FROM projects p JOIN papers d ON d.id = p.codebase_id WHERE p.key = ?",
                               (uppercase(strip(project)),)), ""))
    code = isempty(codebase) || !document_visible(kb, caller, codebase) ? NamedTuple[] : code_reference_matches(kb, codebase, q)
    startswith(lowercase(strip(q)), "code:") && return code
    q = lowercase(strip(q))
    esc = replace(q, r"[%_\\]" => s"\\\0")
    starts, word = esc * "%", "% " * esc * "%"
    # Text matched at the start of a word: a space put before it lets the first word match too.
    found = NamedTuple[]
    for r in query(kb, """SELECT p.key || '-' || t.number AS ref, t.title FROM tasks t JOIN projects p ON p.id = t.project_id
                          WHERE t.archived_at IS NULL AND (lower(p.key || '-' || t.number) LIKE ? ESCAPE '\\' OR ' ' || lower(t.title) LIKE ? ESCAPE '\\')
                          ORDER BY lower(p.key || '-' || t.number) = ? DESC, t.updated_at DESC LIMIT ?""", (starts, word, q, limit))
        push!(found, (; kind = "task", target = String(r.ref), label = String(r.ref), detail = String(r.title)))
    end
    hidden = hidden_documents(kb, caller)
    n = 0
    for r in query(kb, """SELECT doc_id, title FROM papers WHERE $(literature_sql(closed = true)) AND metadata_at IS NOT NULL
                          AND (lower(doc_id) LIKE ? ESCAPE '\\' OR ' ' || lower(title) LIKE ? ESCAPE '\\')
                          ORDER BY published DESC""", (starts, word))
        r.doc_id in hidden && continue
        push!(found, (; kind = "paper", target = String(r.doc_id), label = String(r.doc_id), detail = coalesce(r.title, "")))
        (n += 1) >= limit && break
    end
    n = 0
    for r in query(kb, """SELECT p.doc_id, p.title, x.happened FROM papers p JOIN records x ON x.paper_id = p.id
                          WHERE lower(p.doc_id) LIKE ? ESCAPE '\\' OR ' ' || lower(p.title) LIKE ? ESCAPE '\\'
                          ORDER BY x.happened DESC""", (starts, word))
        r.doc_id in hidden && continue
        push!(found, (; kind = "record", target = String(r.doc_id), label = String(r.doc_id), detail = "$(r.title), $(record_day(r.happened))"))
        (n += 1) >= limit && break
    end
    if !isempty(q)
        n = 0
        for a in authors(kb; coauthors = 0)
            any(v -> author_matches(v, q), a.variants) || continue
            push!(found, (; kind = "author", target = a.key, label = a.name, detail = "$(length(a.papers)) paper$(length(a.papers) == 1 ? "" : "s")"))
            (n += 1) >= limit && break
        end
    end
    for r in query(kb, """SELECT p.key || '-F' || f.number AS ref, f.claim FROM findings f JOIN projects p ON p.id = f.project_id
                          WHERE lower(p.key || '-F' || f.number) LIKE ? ESCAPE '\\' OR ' ' || lower(f.claim) LIKE ? ESCAPE '\\'
                          ORDER BY f.updated_at DESC LIMIT ?""", (starts, word, limit))
        push!(found, (; kind = "finding", target = String(r.ref), label = String(r.ref), detail = String(r.claim)))
    end
    for p in people(kb)
        (startswith(lowercase(p.id), q) || occursin(" " * q, " " * lowercase(p.label))) || continue
        push!(found, (; kind = "person", target = p.id, label = p.label, detail = p.agent ? "agent" : p.id == p.label ? "" : p.id))
    end
    for r in query(kb, """SELECT path, title, doc_id FROM notebooks WHERE status = 'done' AND ' ' || lower(coalesce(title, path)) LIKE ? ESCAPE '\\'
                          ORDER BY started_at DESC LIMIT ?""", (word, limit))
        push!(found, (; kind = "notebook", target = String(r.path), label = coalesce(r.title, basename(r.path)), detail = String(r.doc_id)))
    end
    rank(m) = (l = lowercase(m.label); l == q ? 0 : startswith(l, q) ? 1 : occursin(" " * q, " " * l) ? 2 : 3)
    return [sort(found; by = rank); code]  # stable: each kind's order within a rank
end
