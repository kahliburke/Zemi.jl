# Findings: what a project's work concludes, kept as knowledge. A finding is a claim in a sentence or
# two, a write-up in Markdown, and its sources: papers and documents (a passage quoted, where it
# rests on one), the group's records (see records.jl), notebooks, code in the project's codebase,
# computed results with where they came from, the tasks it came from, and other findings it builds on
# or contradicts. Sources are those
# added as evidence and those the write-up cites with @-references (see `finding_sources`). It belongs to its project (see project_access.jl) and is referred to as
# `KB-F3`, numbered in its project apart from tasks. Agents draft findings; people accept, contest
# or supersede them. Every change keeps what it replaced.

const FINDING_STATUSES = ("draft", "accepted", "contested", "superseded")
const EVIDENCE_KINDS = ("paper", "record", "notebook", "code", "result", "task", "finding")
const EVIDENCE_RELATIONS = ("supports", "contradicts", "builds_on")

# Evidence may be a record: the table is made again with a CHECK that allows one, its rows as they were.
migration!(5, ["""CREATE TABLE finding_evidence_new (
                      id INTEGER PRIMARY KEY,
                      finding_id INTEGER NOT NULL REFERENCES findings(id) ON DELETE CASCADE,
                      kind TEXT NOT NULL CHECK (kind IN ('paper', 'record', 'notebook', 'code', 'result', 'task', 'finding')),
                      target TEXT NOT NULL,
                      relation TEXT NOT NULL DEFAULT 'supports' CHECK (relation IN ('supports', 'contradicts', 'builds_on')),
                      excerpt TEXT NOT NULL DEFAULT '',
                      page INTEGER NOT NULL DEFAULT 0,
                      detail TEXT NOT NULL DEFAULT '{}',
                      added_by TEXT NOT NULL,
                      added_at TEXT NOT NULL,
                      note TEXT NOT NULL DEFAULT '',
                      basis TEXT)""",
               "INSERT INTO finding_evidence_new SELECT * FROM finding_evidence",
               "DROP TABLE finding_evidence",
               "ALTER TABLE finding_evidence_new RENAME TO finding_evidence",
               "CREATE INDEX finding_evidence_finding ON finding_evidence (finding_id, id)"])

"The id of finding `ref` (`KB-F3`)."
function finding_id(kb::KB, ref::AbstractString)
    parts = finding_parts(ref)
    parts === nothing && error("A finding is referred to as KEY-Fnumber, like KB-F3: $ref")
    id = scalar(kb, "SELECT f.id FROM findings f JOIN projects p ON p.id = f.project_id WHERE p.key = ? AND f.number = ?", parts)
    ismissing(id) && not_found("No finding $(uppercase(strip(ref)))")
    return Int(id)
end

"""
    create_finding!(kb, key, claim; body = "", task = "", evidence = [], by) -> String

A finding in project `key`: its `claim`, a `body` in Markdown, and `evidence` (each as
[`add_evidence!`](@ref) takes it, a NamedTuple or Dict). `task`, the task it comes from, is its
first evidence. It starts as a draft. Returns its reference.
"""
function create_finding!(kb::KB, key::AbstractString, claim::AbstractString; body::AbstractString = "", task::AbstractString = "",
                         evidence = [], by::Actor)
    isempty(strip(claim)) && error("A finding needs a claim")
    pid = project_id(kb, key)
    use_media!(kb, key, claim, body, (string(v) for e in evidence for v in values(e))...)
    isempty(strip(task)) || (task_ref(kb, task); evidence = [(; kind = "task", target = task); collect(evidence)])
    ref = transaction(kb) do
        n = Int(scalar(kb, "SELECT next_finding FROM projects WHERE id = ?", (pid,)))
        execute!(kb, "UPDATE projects SET next_finding = next_finding + 1 WHERE id = ?", (pid,))
        now = now_iso()
        execute!(kb, """INSERT INTO findings (project_id, number, claim, body, created_by, by_agent, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""", (pid, n, strip(claim), strip(body), by.name, by.agent ? 1 : 0, now, now))
        "$(uppercase(strip(key)))-F$n"
    end
    for e in evidence
        g(k, d) = e isa AbstractDict ? get(e, String(k), d) : get(e, k, d)
        add_evidence!(kb, ref; kind = g(:kind, ""), target = g(:target, ""), relation = g(:relation, "supports"),
                      excerpt = g(:excerpt, ""), page = g(:page, 0), detail = g(:detail, Dict{String,Any}()), by)
    end
    tasks_changed!()
    return ref
end

"""
    update_finding!(kb, ref; claim = nothing, body = nothing, status = nothing, reason = nothing, by)

Change finding `ref`, keeping what the change replaces (see [`finding_versions`](@ref)). An agent
edits only a draft and leaves it a draft; a person accepts, contests, supersedes or returns it to
draft (one of `FINDING_STATUSES`). Contesting or superseding it needs a `reason` (for the latter,
what supersedes it, as `@KB-F5`), which stays with it while it has that status.
"""
function update_finding!(kb::KB, ref::AbstractString; claim = nothing, body = nothing, status = nothing, reason = nothing, by::Actor)
    id = finding_id(kb, ref)
    use_media!(kb, something(ref_project(ref)), claim, body, reason)
    f = first(query(kb, "SELECT claim, body, status, status_reason, status_by FROM findings WHERE id = ?", (id,)))
    new_claim = claim === nothing ? f.claim : String(strip(claim))
    new_body = body === nothing ? f.body : String(strip(body))
    new_status = status === nothing ? f.status : lowercase(strip(status))
    isempty(new_claim) && error("A finding needs a claim")
    new_status in FINDING_STATUSES || error("A finding is $(join(FINDING_STATUSES, ", ", " or ")): $status")
    if by.agent
        f.status == "draft" || error("$(uppercase(strip(ref))) is $(f.status): an agent changes only drafts")
        new_status == "draft" || error("Only a person accepts, contests or supersedes a finding")
    end
    # A new status starts without the old one's reason; a reason can be given again on its own.
    new_reason = reason !== nothing ? String(strip(reason)) : new_status == f.status ? f.status_reason : ""
    new_status in ("contested", "superseded") && isempty(new_reason) &&
        error(new_status == "contested" ? "Say why it is contested" : "Say what supersedes it")
    (new_claim, new_body, new_status, new_reason) == (f.claim, f.body, f.status, f.status_reason) && return ref
    status_by = (new_status, new_reason) == (f.status, f.status_reason) ? f.status_by : by.name
    now = now_iso()
    transaction(kb) do
        execute!(kb, """INSERT INTO finding_versions (finding_id, claim, body, status, status_reason, changed_by, by_agent, changed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""", (id, f.claim, f.body, f.status, f.status_reason, by.name, by.agent ? 1 : 0, now))
        execute!(kb, "UPDATE findings SET claim = ?, body = ?, status = ?, status_reason = ?, status_by = ?, updated_at = ? WHERE id = ?",
                 (new_claim, new_body, new_status, new_reason, status_by, now, id))
    end
    tasks_changed!()
    return ref
end

"""
    evidence_basis(kb, kind, target) -> String

What a piece of evidence is now, to tell later whether it changed: a paper's arXiv version, the hash
of a record's content (see [`record_sha`](@ref)), a hash of a notebook's or a code file's text, a
finding's status; `""` for one that does not change (a task, a result) or is not here.
"""
function evidence_basis(kb::KB, kind::AbstractString, target::AbstractString)
    hashed(path) = isfile(path) ? bytes2hex(open(sha256, path)) : ""
    kind == "paper" && return String(coalesce(scalar(kb, "SELECT version FROM papers WHERE doc_id = ?", (target,)), ""))
    kind == "record" && return (r = record_row(kb, target); r === nothing ? "" : String(r.content_sha))
    kind == "notebook" && return hashed(content_path(kb.config, target))
    if kind == "code" && occursin(':', target)
        codebase, path = split(target, ':'; limit = 2)
        dir = codebase_dir(kb, codebase)
        return isempty(dir) ? "" : hashed(joinpath(dir, first(split(path, '#'))))
    end
    kind == "finding" && return String(coalesce(scalar(kb, """SELECT f.status FROM findings f JOIN projects p ON p.id = f.project_id
                                                              WHERE p.key || '-F' || f.number = ?""", (target,)), ""))
    return ""
end

"""
    evidence_change(kind, target, was, now) -> Union{String,Nothing}

What changed in a piece of evidence, from what it was (`was`) to what it is (`now`, see
[`evidence_basis`](@ref)), or `nothing` for no change that matters: a paper's newer version, a
record, notebook or code file changed or gone, a finding contested or superseded.
"""
function evidence_change(kind::AbstractString, target::AbstractString, was::AbstractString, now::AbstractString)
    was == now && return nothing
    kind == "paper" && return isempty(was) || isempty(now) ? nothing : "$(cited_as(target)) has a new version, $now (it was $was)"
    kind == "finding" && return now in ("contested", "superseded") ? "$target is $now" : nothing
    if kind in ("record", "notebook", "code")
        name = kind == "code" ? split(target, ':'; limit = 2)[2] : target
        return isempty(now) ? "$name is gone" : "$name changed"
    end
    return nothing
end

"""
    check_findings!(kb) -> Int

Look at every finding's evidence for what changed since it was added (see [`evidence_change`](@ref)),
and mark each finding with changes for a second look, with what changed (`recheck`), until someone
says it still holds (see [`keep_finding!`](@ref)). Evidence added before this was kept takes what
it is now. Superseded and archived findings are left alone. Returns how many findings are marked.
"""
function check_findings!(kb::KB)
    marked = 0
    for f in query(kb, "SELECT id, recheck FROM findings WHERE archived_at IS NULL AND status != 'superseded'")
        reasons = String[]
        for e in query(kb, "SELECT id, kind, target, basis FROM finding_evidence WHERE finding_id = ?", (f.id,))
            now = evidence_basis(kb, e.kind, e.target)
            if ismissing(e.basis)
                execute!(kb, "UPDATE finding_evidence SET basis = ? WHERE id = ?", (now, e.id))
                continue
            end
            why = evidence_change(e.kind, e.target, e.basis, now)
            why === nothing || push!(reasons, why)
        end
        list = JSON.json(unique(reasons))
        list == f.recheck || (execute!(kb, "UPDATE findings SET recheck = ? WHERE id = ?", (list, f.id)); tasks_changed!())
        isempty(reasons) || (marked += 1)
    end
    return marked
end

"""
    keep_finding!(kb, ref; by)

Say finding `ref` still holds with its evidence as it is now: what each piece is becomes what it is
compared with from then on, and the finding is no longer marked for a second look.
"""
function keep_finding!(kb::KB, ref::AbstractString; by::Actor)
    by.agent && error("Only a person says a finding still holds")
    id = finding_id(kb, ref)
    for e in query(kb, "SELECT id, kind, target FROM finding_evidence WHERE finding_id = ?", (id,))
        execute!(kb, "UPDATE finding_evidence SET basis = ? WHERE id = ?", (evidence_basis(kb, e.kind, e.target), e.id))
    end
    execute!(kb, "UPDATE findings SET recheck = '[]', updated_at = ? WHERE id = ?", (now_iso(), id))
    tasks_changed!()
    return nothing
end

"""
    recheck_task!(kb, ref; by) -> String

A task for an agent to re-check finding `ref` against what changed in its evidence: re-run what it
computed, compare, and propose keeping, revising or contesting it. Ready, in the finding's project,
assigned to the agent; returns its reference.
"""
function recheck_task!(kb::KB, ref::AbstractString; by::Actor)
    f = finding(kb, ref)
    isempty(f.recheck) && error("$(f.ref)'s evidence has not changed")
    body = "What changed in the evidence of @$(f.ref), \"$(f.claim)\", since it was written:\n\n" *
           join(("- $r" for r in f.recheck), "\n") * "\n\n" *
           "Re-run what the finding computed with what changed (its notebooks, its code), compare the results with " *
           "what it says, and report whether it still holds, needs revising (say how), or should be contested (say why). " *
           "A person then keeps, revises or contests it."
    return create_task!(kb, f.project, "Re-check $(f.ref): its evidence changed"; body, status = "ready", assignee = "agent:Claude", by)
end

"""
    evidence_source(source) -> (; kind, target, page)

The source a piece of evidence names, written as an @-reference (see at_references.jl), the `@`
optional: a paper, `@arXiv:2401.00001` or `@doc-…`, with `#p5` for a page; a record, `@rec-…`; a
task, `@KB-12`; a finding, `@KB-F3`; code, `@code:path#name`; a notebook, `@[label](notebook:path)`.
"""
function evidence_source(source::AbstractString)
    s = String(strip(source))
    startswith(s, "@") || (s = "@" * s)
    page = 0
    m = match(r"^(@(?:arXiv:\S+?|doc-[0-9a-f]{10}))#p\.?(\d+)$"i, s)
    m === nothing || ((s, page) = (String(m[1]), parse(Int, m[2])))
    refs = filter(r -> r.kind in EVIDENCE_KINDS, at_references(s))
    if isempty(refs)
        id = parse_arxiv_id(s[2:end])                     # an arXiv id written without `arXiv:`
        id === nothing || return (; kind = "paper", target = id.id, page)
    end
    length(refs) == 1 || error("Name one source: @arXiv:2401.00001#p5, @doc-…, @rec-…, @KB-12, @KB-F3, @code:path#name " *
                               "or @[label](notebook:path), not $(repr(String(strip(source))))")
    r = only(refs)
    return (; kind = r.kind, target = r.target, page)
end

"""
    add_evidence!(kb, ref; kind, target, relation = "supports", excerpt = "", page = 0, note = "", detail = Dict(), by) -> Int
    add_evidence!(kb, ref; source, relation = "supports", note = "", by) -> Int

Add evidence to finding `ref`, returning its id, with a `note` (Markdown) on what it shows. The source
is named by its `kind` and `target`, or by `source`, an @-reference (see [`evidence_source`](@ref)):

- `paper`: a paper or document in the knowledge base (`target` its id), the passage it rests on in
  `excerpt` and its `page`
- `record`: a record of the group's (`target` its id), what was said in `excerpt`
- `notebook`: a notebook (`target` its path, `notebooks/…/name.jl`), the cell in `detail`
- `code`: a file or definition (`path` or `path#name`) in the codebase of the finding's project, or
  `codebase:path#name` in another
- `result`: something computed: `target` an attached file's address (`media/…`) or a value, and
  where it came from in `detail` (`notebook`, `cell`, `commit`, `machine`, `job`, …)
- `task`: a task the finding came from (`target` its reference)
- `finding`: another finding, which this one `builds_on` or `contradicts` (`relation`)

`relation` is `supports` for the others.
"""
function add_evidence!(kb::KB, ref::AbstractString; source::AbstractString = "", kind::AbstractString = "",
                       target::AbstractString = "", relation::AbstractString = "supports", excerpt::AbstractString = "",
                       page::Integer = 0, note::AbstractString = "", detail = Dict{String,Any}(), by::Actor)
    isempty(strip(source)) || ((kind, target, page) = evidence_source(source))
    id = finding_id(kb, ref)
    by.agent && scalar(kb, "SELECT status FROM findings WHERE id = ?", (id,)) != "draft" &&
        error("$(uppercase(strip(ref))) is not a draft: an agent changes only drafts")
    use_media!(kb, something(ref_project(ref)), target, excerpt, note)
    kind, target, relation = lowercase(strip(kind)), String(strip(target)), lowercase(strip(relation))
    kind in EVIDENCE_KINDS || error("Evidence is a $(join(EVIDENCE_KINDS, ", ", " or ")): $kind")
    relation in EVIDENCE_RELATIONS || error("Evidence $(join(EVIDENCE_RELATIONS, ", ", " or ")) a finding: $relation")
    isempty(target) && error("Evidence needs a target")
    kind == "paper" && is_record(target) && (kind = "record")          # a record named as a document
    if kind == "paper"
        ismissing(paper_id(kb, target)) && not_found("No paper $target in the knowledge base")
    elseif kind == "record"
        record_row(kb, target) === nothing && not_found("No record $target in the knowledge base")
    elseif kind == "code" && !occursin(':', target)
        codebase = project_codebase(kb, something(ref_project(ref), ""))
        isempty(codebase) && error("$(ref_project(ref)) has no codebase: name one as codebase:path")
        target = "$codebase:$target"
    elseif kind == "task"
        target = uppercase(target); task_ref(kb, target)
    elseif kind == "finding"
        target = uppercase(target); finding_id(kb, target) == id && error("A finding is not its own evidence")
        relation == "supports" && (relation = "builds_on")
    end
    kind == "finding" || relation != "builds_on" || error("Only a finding is built on")
    eid = insert_row!(kb, """INSERT INTO finding_evidence (finding_id, kind, target, relation, excerpt, page, note, detail, added_by, added_at, basis)
                             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                      (id, kind, target, relation, strip(excerpt), page, strip(note), JSON.json(detail), by.name, now_iso(),
                       evidence_basis(kb, kind, target)))
    execute!(kb, "UPDATE findings SET updated_at = ? WHERE id = ?", (now_iso(), id))
    tasks_changed!()
    return eid
end

"Take evidence `evidence` off finding `ref`."
function remove_evidence!(kb::KB, ref::AbstractString, evidence::Integer; by::Actor)
    id = finding_id(kb, ref)
    by.agent && scalar(kb, "SELECT status FROM findings WHERE id = ?", (id,)) != "draft" &&
        error("$(uppercase(strip(ref))) is not a draft: an agent changes only drafts")
    execute!(kb, "DELETE FROM finding_evidence WHERE id = ? AND finding_id = ?", (evidence, id))
    tasks_changed!()
    return nothing
end

"""
    delete_finding!(kb, ref; by)

Delete draft finding `ref` with its evidence and history: one made by mistake, or not worth keeping.
Only a person deletes one, and only a draft that no other finding builds on or contradicts; any other
is archived (see [`archive_finding!`](@ref)).
"""
function delete_finding!(kb::KB, ref::AbstractString; by::Actor)
    id = finding_id(kb, ref)
    r = uppercase(strip(ref))
    by.agent && error("Only a person deletes a finding")
    scalar(kb, "SELECT status FROM findings WHERE id = ?", (id,)) == "draft" || error("$r is not a draft: archive it instead")
    users = [u.ref for u in findings_citing(kb, "finding", r)]
    isempty(users) || error("$(join(unique(users), ", ")) cite$(length(unique(users)) == 1 ? "s" : "") $r: take it off there first")
    transaction(kb) do
        execute!(kb, "DELETE FROM findings WHERE id = ?", (id,))       # its evidence and versions go with it
        execute!(kb, "DELETE FROM task_links WHERE kind = 'finding' AND target = ?", (r,))
    end
    tasks_changed!()
    return nothing
end

"""
    archive_finding!(kb, ref; restore = false, by)

Archive finding `ref`: kept, with its history, but out of its project's list, the searches, what
waits on people and what agents are given. `restore = true` brings it back. Only a person does either.
"""
function archive_finding!(kb::KB, ref::AbstractString; restore::Bool = false, by::Actor)
    id = finding_id(kb, ref)
    by.agent && error("Only a person archives a finding")
    restore ? execute!(kb, "UPDATE findings SET archived_at = NULL, archived_by = '' WHERE id = ?", (id,)) :
              execute!(kb, "UPDATE findings SET archived_at = ?, archived_by = ? WHERE id = ? AND archived_at IS NULL", (now_iso(), by.name, id))
    tasks_changed!()
    return nothing
end

finding_ref(r) = "$(r.key)-F$(r.number)"

"The codebase (its id) project `key` is linked to, or `\"\"`."
project_codebase(kb::KB, key::AbstractString) =
    String(coalesce(scalar(kb, "SELECT d.doc_id FROM projects p JOIN papers d ON d.id = p.codebase_id WHERE p.key = ?",
                           (uppercase(strip(key)),)), ""))

"""
What source `target` of `kind` is called: a paper's title, a record's with its date, a task's title,
a finding's claim, a notebook's name.
"""
function source_label(kb::KB, kind::AbstractString, target::AbstractString)
    kind == "paper" && return String(coalesce(scalar(kb, "SELECT title FROM papers WHERE doc_id = ?", (target,)), target))
    if kind == "record"
        r = record_row(kb, target)
        r === nothing && return target
        return String(coalesce(scalar(kb, "SELECT title FROM papers WHERE doc_id = ?", (target,)), target)) * ", " * record_day(r.happened)
    end
    kind == "task" && return String(coalesce(scalar(kb, """SELECT t.title FROM tasks t JOIN projects p ON p.id = t.project_id
                                                          WHERE p.key || '-' || t.number = ?""", (target,)), ""))
    kind == "finding" && return String(coalesce(scalar(kb, """SELECT f.claim FROM findings f JOIN projects p ON p.id = f.project_id
                                                             WHERE p.key || '-F' || f.number = ?""", (target,)), ""))
    kind == "notebook" && return replace(basename(target), r"\.jl$" => "")
    return ""
end

"""
    finding_sources(kb, ref) -> Vector{NamedTuple}

What finding `ref` rests on: its evidence, then what its claim and body cite with @-references (see
[`at_references`](@ref)) that is not already evidence, each `(; kind, target, label, relation,
excerpt, page, detail, evidence, cited)`: `evidence` the evidence's id (`0` for a citation only) and
`cited` whether the text cites it. Code is named as `codebase:path#name`; people and authors cited
are not sources.
"""
function finding_sources(kb::KB, ref::AbstractString)
    f = finding(kb, ref)
    codebase = project_codebase(kb, f.project)
    cited = Tuple{String,String,String}[]
    for r in at_references(f.claim * "\n\n" * f.body)
        r.kind in ("person", "author") && continue
        target = r.kind in ("task", "finding") ? uppercase(r.target) :
                 r.kind == "code" && !occursin(':', r.target) ? (isempty(codebase) ? r.target : "$codebase:$(r.target)") : r.target
        (r.kind, target) == ("finding", f.ref) || push!(cited, (r.kind, target, r.label == r.target ? "" : r.label))
    end
    incited(kind, target) = any(c -> c[1] == kind && c[2] == target, cited)
    out = [(; e.kind, e.target, label = source_label(kb, e.kind, e.target), e.relation, e.excerpt, e.page, e.note, e.detail,
              evidence = e.id, cited = incited(e.kind, e.target)) for e in f.evidence]
    for (kind, target, label) in cited
        any(s -> s.kind == kind && s.target == target, out) && continue
        push!(out, (; kind, target, label = isempty(label) ? source_label(kb, kind, target) : label,
                      relation = kind == "finding" ? "builds_on" : "supports", excerpt = "", page = 0, note = "",
                      detail = Dict{String,Any}(), evidence = 0, cited = true))
    end
    return out
end

finding_row(r) = (; ref = finding_ref(r), project = String(r.key), claim = String(r.claim), body = String(r.body), status = String(r.status),
                    status_reason = String(r.status_reason), status_by = String(r.status_by),
                    archived_at = coalesce(r.archived_at, ""), archived_by = String(r.archived_by),
                    created_by = String(r.created_by), by_agent = r.by_agent == 1, created_at = String(r.created_at),
                    updated_at = String(r.updated_at), published_at = coalesce(r.published_at, ""),
                    recheck = String.(JSON.parse(r.recheck)))

const FINDING_SELECT = "SELECT f.*, p.key FROM findings f JOIN projects p ON p.id = f.project_id"

"""
    findings_citing(kb, kind, target) -> Vector{NamedTuple}

The findings whose evidence is `target` (a task's or finding's reference, a paper's id) of `kind`,
oldest first: `(; ref, claim, status, relation)`.
"""
findings_citing(kb::KB, kind::AbstractString, target::AbstractString) =
    [(; ref = finding_ref(r), claim = String(r.claim), status = String(r.status), relation = String(r.relation))
     for r in query(kb, """SELECT f.*, p.key, e.relation FROM finding_evidence e JOIN findings f ON f.id = e.finding_id
                           JOIN projects p ON p.id = f.project_id WHERE e.kind = ? AND e.target = ? ORDER BY f.id""",
                    (kind, kind in ("task", "finding") ? uppercase(strip(target)) : strip(target)))]

"""
    paper_findings(kb, id; projects) -> Vector{NamedTuple}

The findings of `projects` (keys) that rest on paper or record `id`, oldest first, archived ones left
out, each once for each piece of evidence: `(; ref, project, claim, status, relation, page, excerpt, note)`.
"""
paper_findings(kb::KB, id::AbstractString; projects) =
    [(; ref = finding_ref(r), project = String(r.key), claim = String(r.claim), status = String(r.status),
        relation = String(r.relation), page = Int(r.page), excerpt = String(r.excerpt), note = String(r.note))
     for r in query(kb, """SELECT f.*, p.key, e.relation, e.page, e.excerpt, e.note FROM finding_evidence e
                           JOIN findings f ON f.id = e.finding_id JOIN projects p ON p.id = f.project_id
                           WHERE e.kind IN ('paper', 'record') AND e.target = ? AND f.archived_at IS NULL ORDER BY f.id, e.id""", (strip(id),))
     if String(r.key) in projects]

"""
    finding(kb, ref) -> NamedTuple

Finding `ref` in full: as [`findings`](@ref) gives it, with its `evidence`, each `(; id, kind, target,
relation, excerpt, page, note, detail, added_by, added_at)`, how many earlier `versions` it has, and the
findings that build on or contradict it (`used_by`, see [`findings_citing`](@ref)).
"""
function finding(kb::KB, ref::AbstractString)
    id = finding_id(kb, ref)
    f = finding_row(first(query(kb, FINDING_SELECT * " WHERE f.id = ?", (id,))))
    evidence = [(; id = Int(e.id), kind = String(e.kind), target = String(e.target), relation = String(e.relation),
                   excerpt = String(e.excerpt), page = Int(e.page), note = String(e.note), detail = JSON.parse(e.detail), added_by = String(e.added_by),
                   added_at = String(e.added_at))
                for e in query(kb, "SELECT * FROM finding_evidence WHERE finding_id = ? ORDER BY id", (id,))]
    versions = Int(scalar(kb, "SELECT count(*) FROM finding_versions WHERE finding_id = ?", (id,)))
    return merge(f, (; evidence, versions, used_by = findings_citing(kb, "finding", f.ref)))
end

"""
    findings(kb; project = "", status = "", archived = false) -> Vector{NamedTuple}

The findings, the latest changed first, of `project` and in `status` when given, those not archived
(with `archived`, only those archived): each `(; ref, project, claim, body, status, status_reason,
status_by, archived_at, archived_by, created_by, by_agent, created_at, updated_at, published_at)`.
"""
function findings(kb::KB; project::AbstractString = "", status::AbstractString = "", archived::Bool = false)
    where, args = String[archived ? "f.archived_at IS NOT NULL" : "f.archived_at IS NULL"], Any[]
    isempty(project) || (push!(where, "p.key = ?"); push!(args, uppercase(strip(project))))
    isempty(status) || (push!(where, "f.status = ?"); push!(args, lowercase(strip(status))))
    sql = FINDING_SELECT * (isempty(where) ? "" : " WHERE " * join(where, " AND ")) * " ORDER BY f.updated_at DESC, f.id DESC"
    return [finding_row(r) for r in query(kb, sql, Tuple(args))]
end

"""
    finding_versions(kb, ref) -> Vector{NamedTuple}

What each change to finding `ref` replaced, oldest first: `(; claim, body, status, status_reason,
changed_by, by_agent, changed_at)`.
"""
finding_versions(kb::KB, ref::AbstractString) =
    [(; claim = String(v.claim), body = String(v.body), status = String(v.status), status_reason = String(v.status_reason), changed_by = String(v.changed_by),
        by_agent = v.by_agent == 1, changed_at = String(v.changed_at))
     for v in query(kb, "SELECT * FROM finding_versions WHERE finding_id = ? ORDER BY id", (finding_id(kb, ref),))]
