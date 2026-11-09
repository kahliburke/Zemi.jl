# Questions on tasks. Each is asked of one recipient: the agents, a person, or anyone on the
# project. It waits on them until a comment replying to it answers it or someone marks it resolved;
# while a question asked back about it waits, it waits on that one's answer instead.

migration!(12, [
    "ALTER TABLE task_events ADD COLUMN by_person TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE task_events ADD COLUMN to_whom TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE task_events ADD COLUMN to_person TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE task_events ADD COLUMN reply_to INTEGER REFERENCES task_events(id) ON DELETE SET NULL",
    "CREATE INDEX task_events_reply ON task_events (reply_to)",
    "CREATE INDEX task_events_open_questions ON task_events (id) WHERE kind = 'question' AND resolved_at IS NULL",
    # People's notes by the person as tasks are assigned to them: their email, where they have an account.
    """UPDATE task_events SET by_person = coalesce((SELECT u.email FROM users u WHERE u.name = task_events.who OR u.email = task_events.who
                                                    ORDER BY u.id LIMIT 1), who)
       WHERE by_agent = 0""",
    # A person's question was the agents', an agent's anyone's.
    "UPDATE task_events SET to_whom = CASE by_agent WHEN 1 THEN 'anyone' ELSE 'agents' END WHERE kind = 'question'",
    # The first note from the other side after questions replies to the latest of them.
    """UPDATE task_events SET reply_to = (
           SELECT max(q.id) FROM task_events q WHERE q.task_id = task_events.task_id AND q.kind = 'question'
             AND q.id < task_events.id AND q.by_agent != task_events.by_agent
             AND NOT EXISTS (SELECT 1 FROM task_events x WHERE x.task_id = q.task_id AND x.id > q.id AND x.id < task_events.id
                             AND x.kind IN ('comment', 'question') AND x.by_agent != q.by_agent))
       WHERE kind IN ('comment', 'question')""",
    # The questions that note answered besides, or answered with a question, were settled when it was written.
    """UPDATE task_events SET resolved_at = (
           SELECT a.at FROM task_events a WHERE a.task_id = task_events.task_id AND a.id > task_events.id
             AND a.kind IN ('comment', 'question') AND a.by_agent != task_events.by_agent ORDER BY a.id LIMIT 1)
       WHERE kind = 'question' AND resolved_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM task_events c WHERE c.reply_to = task_events.id AND c.kind = 'comment')""",
])

# An agent's notes by the person it works for, from the name it signs with ("Claude for Ada").
migration!(13, ["""UPDATE task_events SET by_person = coalesce(
                       (SELECT u.email FROM users u WHERE u.name = substr(task_events.who, instr(task_events.who, ' for ') + 5)
                                                       OR u.email = substr(task_events.who, instr(task_events.who, ' for ') + 5)
                        ORDER BY u.id LIMIT 1), '')
                   WHERE by_agent = 1 AND instr(who, ' for ') > 0"""])

"""
    question_recipient(kb, ref, by, to; replied = nothing) -> (to_whom, to_person)

Whom a question on task `ref` by `by` is asked of: `("agents", "")`, `("anyone", "")` (anyone on
the project) or `("person", id)`. `to` names them: `"agents"`, `"anyone"`, or a person as tasks
are assigned (their email or name, see [`assignee_id`](@ref)). With no `to`, a question asked back
about question `replied` goes to whoever asked that: for an agent's, the person it works for, or
the agents when it works for no one. Else a person's goes to the agents, and an agent's to the
task's assignee, or anyone when no person is assigned.
"""
function question_recipient(kb::KB, ref::AbstractString, by::Actor, to::AbstractString; replied = nothing)
    to = strip(to)
    if isempty(to)
        replied === nothing || return !isempty(replied.by_person) ? ("person", String(replied.by_person)) :
                                      replied.by_agent == 1 ? ("agents", "") : ("anyone", "")
        by.agent || return ("agents", "")
        a = coalesce(scalar(kb, "SELECT assignee FROM tasks WHERE id = ?", (task_ref(kb, ref),)), "")
        return isempty(a) || startswith(a, "agent:") ? ("anyone", "") : ("person", String(a))
    end
    lowercase(to) in ("agents", "agent", "an agent") && return ("agents", "")
    lowercase(to) == "anyone" && return ("anyone", "")
    p = assignee_id(kb, to; project = something(ref_project(ref), ""))
    startswith(p, "agent:") && return ("agents", "")
    !by.agent && p == by.id && error("Ask someone else: a question to yourself waits on no one")
    return ("person", p)
end

"The labels of the people project `key`'s questions are asked of, by their id (see [`people`](@ref))."
person_labels(kb::KB, key::AbstractString) = Dict(p.id => p.label for p in people(kb; project = key) if !p.agent)

"""
    with_question_states(activity; labels) -> Vector{NamedTuple}

A task's `activity` with each note's `to_label` (whom a question is asked of, by `labels`) and
each question's `state`: `resolved`; `answered`, when a comment replies to it; `asked back`, while
a question asked back about it waits; else `open`. Other notes' state is `""`.
"""
function with_question_states(activity; labels::AbstractDict = Dict{String,String}())
    answered = Set(e.reply_to for e in activity if e.kind == "comment" && e.reply_to > 0)
    states = Dict{Int,String}()
    for e in Iterators.reverse(activity)               # a question asked back comes after the question
        e.kind == "question" || continue
        states[e.id] = !isempty(e.resolved_at) ? "resolved" : e.id in answered ? "answered" :
                       any(f -> f.kind == "question" && f.reply_to == e.id && states[f.id] in ("open", "asked back"), activity) ?
                       "asked back" : "open"
    end
    label(e) = e.to_whom == "person" ? get(labels, e.to_person, e.to_person) : e.to_whom == "agents" ? "the agents" :
               e.to_whom == "anyone" ? "anyone" : ""
    return [merge(e, (; to_label = label(e), state = get(states, e.id, ""))) for e in activity]
end

# A question answered: a comment replies to it.
const ANSWERED_SQL = "EXISTS (SELECT 1 FROM task_events a WHERE a.reply_to = e.id AND a.kind = 'comment')"
# A question waiting on its recipient: neither resolved nor answered, and no question asked back about it waiting.
const WAITS_SQL = """e.kind = 'question' AND e.resolved_at IS NULL AND NOT $ANSWERED_SQL
    AND NOT EXISTS (SELECT 1 FROM task_events f WHERE f.reply_to = e.id AND f.kind = 'question' AND f.resolved_at IS NULL
                    AND NOT EXISTS (SELECT 1 FROM task_events fa WHERE fa.reply_to = f.id AND fa.kind = 'comment'))"""

"""
    waiting_questions(kb; project = "") -> Vector{NamedTuple}

The questions waiting on their recipient (see [`with_question_states`](@ref)), on tasks not
archived, in `project` or all: each `(; note, task_id, ref, status, text, asker, by_agent, by_person,
to_whom, to_person)`, oldest first.
"""
function waiting_questions(kb::KB; project::AbstractString = "")
    k = uppercase(strip(project))
    [(; note = Int(r.id), task_id = Int(r.task_id), ref = String(r.ref), status = String(r.status), text = String(r.text),
        asker = String(r.who), by_agent = r.by_agent == 1, by_person = String(r.by_person), to_whom = String(r.to_whom),
        to_person = String(r.to_person))
     for r in query(kb, """SELECT e.id, e.task_id, p.key || '-' || t.number AS ref, t.status, e.text, e.who, e.by_agent, e.by_person,
                                  e.to_whom, e.to_person
                           FROM task_events e JOIN tasks t ON t.id = e.task_id JOIN projects p ON p.id = t.project_id
                           WHERE $WAITS_SQL AND t.archived_at IS NULL AND (? = '' OR p.key = ?) ORDER BY e.id""", (k, k))]
end

"Whether question `q` (see [`waiting_questions`](@ref)) waits on person `me`: asked of them, or of anyone and not by them."
asked_of(q, me::AbstractString) =
    q.to_whom == "person" ? q.to_person == me : q.to_whom == "anyone" && (isempty(me) || q.by_person != me)

"""
    concerns(kb, task_id, me) -> Bool

Whether task `task_id` is person `me`'s business: assigned to them, created by them or for them by
an agent, or worked on by an agent working for them.
"""
concerns(kb::KB, task_id::Integer, me::AbstractString) = !isempty(me) && !isempty(query(kb, """
    SELECT 1 FROM tasks t WHERE t.id = ? AND (t.assignee = ? OR EXISTS (
        SELECT 1 FROM task_events e WHERE e.task_id = t.id AND e.by_person = ? AND (e.kind = 'created' OR e.by_agent = 1)))""",
    (task_id, me, me)))

"""
    waiting(kb; me = "") -> NamedTuple

What waits on person `me` (an email in the shared service, a name run for one person), across
projects: `proposed`, plans waiting for approval (a whole plan once, and a subtask proposed under a
task already approved); `questions`, the questions asked of them or of anyone (see [`asked_of`](@ref)),
on tasks not done, each task with the `question`, its `note` and `asker`; `review`, tasks in Review;
`mine`, the open tasks assigned to them; `findings`, the findings agents drafted, to accept, and
those whose evidence changed, to look at again (see [`check_findings!`](@ref)); and `answered`, the
answers to their questions (see [`answered_questions`](@ref)). Plans and tasks in review say whether
they `concerns` the person (see [`concerns`](@ref)). With them, `asked`: the questions the person
asked, themselves or through an agent working for them, still waiting on whoever they asked, each
task with the `question`, its `note`, `to_whom` and `to_person`.
"""
function waiting(kb::KB; me::AbstractString = "")
    find(where, args = ()) = NamedTuple[task_row(r) for r in query(kb, TASK_SELECT * " WHERE t.archived_at IS NULL AND (" * where * ") ORDER BY p.key, t.priority, t.position", args)]
    marked(ts) = NamedTuple[merge(t, (; concerns = concerns(kb, task_ref(kb, t.ref), me))) for t in ts]
    open_questions = [q for q in waiting_questions(kb) if q.status != "done"]
    for_me = [q for q in open_questions if asked_of(q, me)]
    by_me = isempty(me) ? eltype(open_questions)[] : [q for q in open_questions if q.by_person == me]
    ids = unique(q.task_id for q in [for_me; by_me])
    rows = isempty(ids) ? Dict{Int,NamedTuple}() :
        Dict(Int(r.id) => task_row(r) for r in query(kb, TASK_SELECT * " WHERE t.id IN ($(join(ids, ',')))"))
    return (; proposed = marked(find("t.status = 'proposed' AND (t.parent_id IS NULL OR pt.status != 'proposed')")),
              questions = NamedTuple[merge(rows[q.task_id], (; question = q.text, note = q.note, asker = q.asker)) for q in for_me],
              review = marked(find("t.status = 'review'")),
              mine = isempty(me) ? NamedTuple[] : find("t.assignee = ? AND t.status != 'done'", (me,)),
              findings = filter(f -> (f.by_agent && f.status == "draft") || !isempty(f.recheck), findings(kb)),
              answered = isempty(me) ? NamedTuple[] : answered_questions(kb, me),
              asked = NamedTuple[merge(rows[q.task_id], (; question = q.text, note = q.note, to_whom = q.to_whom, to_person = q.to_person))
                                 for q in by_me])
end

"""
    answered_questions(kb, me) -> Vector{NamedTuple}

The questions person `me` asked, themselves or through an agent working for them, that a comment
answers, not resolved, while they have not written on the task since the answer: each task, as [`tasks`](@ref) gives it, with the `question`, its
`note`, the first `answer` and who wrote it (`answerer`), the latest answer first.
"""
function answered_questions(kb::KB, me::AbstractString)
    out = NamedTuple[]
    for q in query(kb, """
            SELECT e.id, e.task_id, e.text, a.text AS answer, a.who AS answerer
            FROM task_events e JOIN tasks t ON t.id = e.task_id
            JOIN task_events a ON a.id = (SELECT min(r.id) FROM task_events r WHERE r.reply_to = e.id AND r.kind = 'comment')
            WHERE e.kind = 'question' AND e.by_person = ? AND e.resolved_at IS NULL AND t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM task_events w WHERE w.task_id = e.task_id AND w.id > a.id AND w.by_agent = 0
                              AND w.by_person = ? AND w.kind IN ('comment', 'question'))
            ORDER BY a.id DESC""", (me, me))
        r = query(kb, TASK_SELECT * " WHERE t.id = ?", (q.task_id,))
        isempty(r) || push!(out, merge(task_row(first(r)), (; question = String(q.text), note = Int(q.id), answer = String(q.answer),
                                                             answerer = String(q.answerer))))
    end
    return out
end

"""
    resolve_question!(kb, ref, note; by)
    resolve_question!(kb, ref; by)

Mark question `note` on task `ref` resolved, settled some other way or no longer needing an answer,
so it waits on no one; without `note`, every question still open there. An agent resolves only its
own questions.
"""
function resolve_question!(kb::KB, ref::AbstractString, note::Integer = 0; by::Actor)
    id = task_ref(kb, ref)
    rows = query(kb, "SELECT id, who, by_agent FROM task_events WHERE task_id = ? AND kind = 'question' AND resolved_at IS NULL" *
                     (note > 0 ? " AND id = ?" : ""), note > 0 ? (id, note) : (id,))
    note > 0 && isempty(rows) && not_found("No open question $note on $(uppercase(strip(ref)))")
    for r in rows
        by.agent && !(r.by_agent == 1 && r.who == by.name) && error("An agent resolves only its own questions")
        execute!(kb, "UPDATE task_events SET resolved_at = ? WHERE id = ?", (now_iso(), r.id))
    end
    tasks_changed!()
    return ref
end

"""
    asked_of_agents(kb, key) -> Vector

The questions asked of the agents on project `key`'s tasks, archived ones aside, waiting for an
answer: each task (as [`tasks`](@ref) gives it) with the `question`, its `note` and who asked it
(`asker`).
"""
function asked_of_agents(kb::KB, key::AbstractString)
    asked = [q for q in waiting_questions(kb; project = key) if q.to_whom == "agents"]
    isempty(asked) && return NamedTuple[]
    rows = Dict(Int(r.id) => task_row(r) for r in query(kb, TASK_SELECT * " WHERE t.id IN ($(join(unique(q.task_id for q in asked), ',')))"))
    return NamedTuple[merge(rows[q.task_id], (; question = q.text, note = q.note, asker = q.asker)) for q in asked]
end
