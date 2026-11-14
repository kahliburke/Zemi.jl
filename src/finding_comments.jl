# What people and agents say about a finding, apart from its write-up: questions, objections,
# suggestions, replies. A comment can be corrected by whoever wrote it, keeping what it said before.
# With the finding's own changes (drafted, revised, accepted, contested, its sources), they make its
# activity, which its page and the agents' tools show.

"The name a comment's writer goes by now (see `named_now`)."
const COMMENTER = named_now("who", "by_agent", "by_person")

"""
    comment_finding!(kb, ref, text; by) -> Int

Say `text` (Markdown, with @-references) about finding `ref`, as `by`; returns the comment's number.
"""
function comment_finding!(kb::KB, ref::AbstractString, text::AbstractString; by::Actor)
    isempty(strip(text)) && error("A comment needs text")
    id = finding_id(kb, ref)
    use_media!(kb, something(ref_project(ref)), text)
    n = insert_row!(kb, "INSERT INTO finding_comments (finding_id, who, by_agent, by_person, text, at) VALUES (?, ?, ?, ?, ?, ?)",
                    (id, by.name, by.agent ? 1 : 0, by.id, strip(text), now_iso()))
    tasks_changed!()
    return n
end

"""
    edit_finding_comment!(kb, ref, n, text; by)

Correct comment `n` on finding `ref`: only its writer does. What it said before is kept.
"""
function edit_finding_comment!(kb::KB, ref::AbstractString, n::Integer, text::AbstractString; by::Actor)
    isempty(strip(text)) && error("A comment needs text")
    rows = query(kb, "SELECT $(COMMENTER) AS who, by_agent, by_person, text, earlier FROM finding_comments WHERE id = ? AND finding_id = ?",
                 (n, finding_id(kb, ref)))
    isempty(rows) && not_found("No comment $n on $(uppercase(strip(ref)))")
    c = first(rows)
    # One's own comment is one's by who one is, whatever one has been named since.
    mine = (c.by_agent == 1) == by.agent && (by.agent || isempty(by.id) ? c.who == by.name : c.by_person == by.id)
    mine || error("Only $(c.who) corrects their comment")
    strip(text) == c.text && return
    use_media!(kb, something(ref_project(ref)), text)
    earlier = push!(JSON.parse(c.earlier), Dict("text" => c.text, "until" => now_iso()))
    execute!(kb, "UPDATE finding_comments SET text = ?, edited_at = ?, earlier = ? WHERE id = ?", (strip(text), now_iso(), JSON.json(earlier), n))
    tasks_changed!()
    return
end

"""
    finding_activity(kb, ref) -> Vector{NamedTuple}

What happened to finding `ref`, oldest first: its comments and its own changes, each `(; kind, id,
who, by_agent, at, text, edited)`. `kind` is "comment", "created", "revised" (its claim or write-up),
"status" (`text` saying from what to what, with the reason), or "source" (evidence added).
"""
function finding_activity(kb::KB, ref::AbstractString)
    id = finding_id(kb, ref)
    f = first(query(kb, "SELECT f.claim, f.body, f.status, f.status_reason, f.by_agent, f.created_at, $FINDING_NAMES FROM findings f WHERE f.id = ?", (id,)))
    out = NamedTuple[]
    push!(out, (; kind = "created", id = 0, who = String(f.created_now), by_agent = f.by_agent == 1, at = String(f.created_at), text = "", edited = false))
    # Each version is what a change replaced; what it became is the next version, or the finding as it is.
    versions = query(kb, "SELECT *, $(VERSION_CHANGER) AS changed_now FROM finding_versions WHERE finding_id = ? ORDER BY id", (id,))
    states = [[(; v.claim, v.body, v.status, v.status_reason) for v in versions]; (; f.claim, f.body, f.status, f.status_reason)]
    for (i, v) in enumerate(versions)
        was, now = states[i], states[i+1]
        who, agent, at = String(v.changed_now), v.by_agent == 1, String(v.changed_at)
        if was.status != now.status
            push!(out, (; kind = "status", id = 0, who, by_agent = agent, at, edited = false,
                          text = "moved it from $(was.status) to $(now.status)" * (isempty(now.status_reason) ? "" : ": $(now.status_reason)")))
        end
        if (was.claim, was.body) != (now.claim, now.body)
            push!(out, (; kind = "revised", id = 0, who, by_agent = agent, at, edited = false,
                          text = was.claim != now.claim ? "revised the claim" * (was.body != now.body ? " and the write-up" : "") : "revised the write-up"))
        end
    end
    for e in query(kb, "SELECT kind, target, added_by, $(EVIDENCE_ADDER) AS added_now, added_at FROM finding_evidence WHERE finding_id = ? ORDER BY id", (id,))
        # Agents act as "<agent> for <person>" (see tool_actor).
        push!(out, (; kind = "source", id = 0, who = String(e.added_now), by_agent = occursin(r"\S for \S", String(e.added_by)),
                      at = String(e.added_at), text = "added $(e.kind) $(e.target) as a source", edited = false))
    end
    for c in query(kb, "SELECT *, $(COMMENTER) AS named FROM finding_comments WHERE finding_id = ? ORDER BY id", (id,))
        push!(out, (; kind = "comment", id = Int(c.id), who = String(c.named), by_person = String(c.by_person), by_agent = c.by_agent == 1, at = String(c.at),
                      text = String(c.text), edited = !ismissing(c.edited_at)))
    end
    # Within a second (times are kept to the second), in the order such things happen.
    rank = Dict("created" => 0, "source" => 1, "revised" => 2, "status" => 3, "comment" => 4)
    return sort!(out; by = x -> (x.at, rank[x.kind]))
end
