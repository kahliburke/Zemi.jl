# Tools for agents to read and draft findings (see findings.jl), served with the tools for tasks.

"""
    findings(project::String; status::String="") -> String

Project `project`'s findings, the latest changed first: what its work concluded, each a claim
with a write-up and its sources, referred to as `KB-F3`. `status`: draft, accepted, contested or
superseded. Read one with `finding`. Each comes with the address of its page, to give people.
"""
findings_tool(project::String; status::String = "")::String = refusing() do
    tool_needs(project, VIEW)
    fs = findings(kb(); project, status)
    isempty(fs) ? "No findings in $(uppercase(strip(project)))$(isempty(status) ? "" : " $status")." :
        join(("$(f.ref) [$(f.status)] $(f.claim)" * linked(ref_link(kb().config, f.ref)) for f in fs), "\n")
end
tool!("findings", findings_tool; need = "tasks.view")

"""
    finding(ref::String) -> String

Finding `ref` (`KB-F3`) in full: its claim, status, write-up and sources (its evidence and what
the write-up cites), and the findings that build on or contradict it. The newest images in it and its
comments are shown, and the other files attached are listed (see `media`).
"""
finding_tool(ref::String)::String = refusing() do
    tool_needs(ref, VIEW)
    f = finding(kb(), ref)
    texts = [f.claim; f.body; f.status_reason; [e.excerpt * " " * e.note for e in f.evidence]; [a.text for a in finding_activity(kb(), ref)]]
    images, shown = attached_images(texts)
    with_images(format_finding(ref) * attachments_text(texts, shown), images)
end
tool!("finding", finding_tool; need = "tasks.view")

"""
    finding_draft(project::String, claim::String; body::String="", task::String="") -> String

Record what work concluded as a finding in `project`: the `claim` in a sentence or two, and the
write-up in `body` (Markdown, with math in `\$…\$`): what shows it, how it was found, its
limits. Cite what it rests on in the text: `@arXiv:2401.00001`, `@doc-…`, `@rec-…` (a record: what was said),
`@[label](notebook:path)`, `@code:path#name` (in the project's codebase), `@KB-12`, `@KB-F3`.
Give `task`, the task the work was done under, which becomes its first source; add passages and
computed results with `finding_evidence`. It stays a draft until a person accepts it.
"""
finding_draft_tool(project::String, claim::String; body::String = "", task::String = "")::String = refusing() do
    tool_needs(project, CONTRIBUTE)
    isempty(task) || tool_needs(task, VIEW)
    ref = create_finding!(kb(), project, claim; body = attach_local_files(body, project), task, by = tool_actor())
    "Drafted $ref." * linked(ref_link(kb().config, ref))
end
tool!("finding_draft", finding_draft_tool; need = "tasks.edit")

"""
    finding_update(ref::String; claim::String="", body::String="") -> String

Revise draft finding `ref`: a new `claim` or `body` replaces it whole (empty leaves it). The
earlier text is kept. Only a person changes a finding once it is accepted, contested or superseded.
"""
finding_update_tool(ref::String; claim::String = "", body::String = "")::String = refusing() do
    tool_needs(ref, CONTRIBUTE)
    update_finding!(kb(), ref; claim = isempty(claim) ? nothing : claim, body = isempty(body) ? nothing : attach_local_files(body, ref_project(ref)),
                    by = tool_actor())
    "Updated $(uppercase(strip(ref)))." * linked(ref_link(kb().config, ref))
end
tool!("finding_update", finding_update_tool; need = "tasks.edit")

"""
    finding_comment(ref::String, text::String; note::Int=0) -> String

Comment on finding `ref`: a question about it, an objection, a suggestion, a reply to what people
said in its activity (`finding` shows it). Markdown, with @-references. To correct a comment of
your own, give its number as `note`, and `text` replaces it whole (the earlier text is kept). A
change to the claim or write-up itself goes through `finding_update` instead.
"""
finding_comment_tool(ref::String, text::String; note::Int = 0)::String = refusing() do
    tool_needs(ref, CONTRIBUTE)
    text = attach_local_files(text, ref_project(ref))
    if note > 0
        edit_finding_comment!(kb(), ref, note, text; by = tool_actor())
        return "Edited comment $note on $(uppercase(strip(ref)))."
    end
    "Commented on $(uppercase(strip(ref))) (comment $(comment_finding!(kb(), ref, text; by = tool_actor())))."
end
tool!("finding_comment", finding_comment_tool; need = "tasks.edit")

"""
    finding_evidence(ref::String, source::String; note::String="", relation::String="", excerpt::String="",
                     detail::String="", remove::Int=0) -> String

Add a source to draft finding `ref`, where the text's citations do not say enough, named as an
@-reference in `source`, with a `note` (Markdown) on what it shows:
- a paper: `@arXiv:2401.00001#p5` or `@doc-…`, `#p` and its page where it rests on one; the
  passage itself, quoted, in `excerpt`
- a record of the group's: `@rec-…`, what was said, quoted, in `excerpt`
- a notebook: `@[label](notebook:notebooks/…/name.jl)`, the cell in `detail`
- code: `@code:path` or `@code:path#name` in the project's codebase
- a task it came from: `@KB-12`
- another finding: `@KB-F3`, which it builds on, or `relation="contradicts"`
- something computed: `result:` and an attached file (`media/…`) or a value, with where it came
  from in `detail` as JSON (`{"notebook": "…", "cell": "…", "commit": "…", "job": "…"}`)
`relation` is `supports` (the default) or `contradicts`. `remove`, a source's number as `finding`
shows it, takes that one away instead.
"""
function finding_evidence_tool(ref::String, source::String; note::String = "", relation::String = "", excerpt::String = "",
                               detail::String = "", remove::Int = 0)::String
    refusing() do
        tool_needs(ref, CONTRIBUTE)
        remove > 0 && (remove_evidence!(kb(), ref, remove; by = tool_actor()); return "Removed source $remove from $(uppercase(strip(ref))).")
        d = isempty(strip(detail)) ? Dict{String,Any}() : JSON.parse(detail)
        d isa AbstractDict || error("detail is a JSON object: $detail")
        src = startswith(lowercase(strip(source)), "result:") ? (; kind = "result", target = String(strip(strip(source)[8:end])), page = 0) :
              evidence_source(source)
        src.kind in ("task", "finding") && tool_needs(src.target, VIEW)
        id = add_evidence!(kb(), ref; src.kind, src.target, src.page, relation = isempty(relation) ? "supports" : relation,
                           excerpt, note, detail = d, by = tool_actor())
        "Added source $id to $(uppercase(strip(ref)))."
    end
end
tool!("finding_evidence", finding_evidence_tool; need = "tasks.edit")

"A link put after a tool's line: the address on a line of its own, indented; nothing without one."
linked(link::AbstractString) = isempty(link) ? "" : "\n  " * link

"The address of a finding's source's page: a paper's or record's, a task's or another finding's; empty for the rest."
source_link(c::Config, kind::AbstractString, target::AbstractString) =
    kind in ("paper", "record") ? document_link(c, target) : kind in ("task", "finding") ? ref_link(c, target) : ""

"""
    format_finding(ref) -> String

Finding `ref` as an agent reads it: claim, status, the address of its page, write-up and its
sources, numbered where they are evidence and each with its page's address, leaving out tasks,
findings and documents the person the agent works for does not see. A record cited is said to be one
(see [`record_note`](@ref)).
"""
function format_finding(ref::AbstractString)
    f = finding(kb(), ref)
    unseen = hidden_documents(kb(), tool_caller())
    hidden(kind, target) = kind in ("task", "finding") ? !tool_sees(target) : kind in ("paper", "record") && target in unseen
    io = IOBuffer()
    println(io, "$(f.ref) [$(f.status)] $(f.claim)")
    page = ref_link(kb().config, f.ref)
    isempty(page) || println(io, "Page: ", page)
    isempty(f.status_reason) || println(io, uppercasefirst(f.status), " by ", f.status_by, ": ", plain_at_references(f.status_reason))
    println(io, "By $(f.created_by)$(f.by_agent ? " (agent)" : ""), $(f.created_at); changed $(f.updated_at)",
            f.versions > 0 ? "; $(f.versions) earlier version$(f.versions == 1 ? "" : "s")" : "")
    isempty(f.body) || println(io, "\n", plain_at_references(f.body))
    isempty(f.recheck) || println(io, "\n## Its evidence changed since it was written\n\n", join(("- $r" for r in f.recheck), "\n"))
    sources = [x for x in finding_sources(kb(), ref) if !hidden(x.kind, x.target)]
    if !isempty(sources)
        println(io, "\n## Sources\n")
        for x in sources
            what = x.kind == "finding" ? replace(x.relation, "_" => " ") : x.kind
            print(io, "- ", x.evidence > 0 ? "[$(x.evidence)] " : "", what, " ", x.target)
            isempty(x.label) || x.label == x.target || print(io, " (", x.label, ")")
            x.page > 0 && print(io, ", p. ", x.page)
            x.kind != "finding" && x.relation == "contradicts" && print(io, ", contradicts it")
            x.evidence > 0 || print(io, ", cited")
            isempty(x.detail) || print(io, "; ", join(("$k $v" for (k, v) in x.detail), ", "))
            print(io, linked(source_link(kb().config, x.kind, x.target)))
            println(io)
            isempty(x.excerpt) || println(io, "  > ", replace(x.excerpt, "\n" => "\n  > "))
            x.kind == "record" && (note = record_note(kb(), x.target); isempty(note) || println(io, "  (", note, ")"))
            isempty(x.note) || println(io, "  ", replace(x.note, "\n" => "\n  "))
        end
    end
    used = [u for u in f.used_by if tool_sees(u.ref)]
    isempty(used) || println(io, "\n## Used by\n\n", join(("- $(u.ref) $(replace(u.relation, "_" => " ")) it: $(u.claim)" for u in used), "\n"))
    # What people and agents said about it, among its changes (see finding_comments.jl).
    act = finding_activity(kb(), ref)
    if any(a -> a.kind == "comment", act)
        println(io, "\n## Activity (comment with finding_comment)\n")
        for a in act
            what = a.kind == "comment" ? "wrote [comment $(a.id)$(a.edited ? ", edited" : "")]: " * plain_at_references(a.text) :
                   a.kind == "created" ? "drafted it" : a.text
            println(io, "- $(first(a.at, 16)) $(a.who)$(a.by_agent ? " (agent)" : ""): $what")
        end
    end
    return String(take!(io))
end
