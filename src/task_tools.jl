# Tools for agents to plan and track work as tasks (see tasks.jl), served with the knowledge base's
# own tools. A change is recorded as the agent's, for the person it works for: over /mcp, the holder
# of the token its session was opened with (see `mcp_person`); otherwise whoever runs the knowledge base.

"The agent making a change through a tool, working for the person calling over /mcp or for whoever runs the knowledge base."
function tool_actor()
    c = something(mcp_caller(), agent_caller(), Some(nothing))
    agent("Claude for " * something(mcp_person(), local_user(), "this machine");
          id = c === nothing ? something(local_user(), "") : person_id(c))
end

"""
The person an agent's tool call works for, as a caller: the token's holder over /mcp, or the person
the service opened the agent for (see `act_for!`). Any other call is from this machine, whose
sessions act for whoever runs the knowledge base, except on a service serving /mcp (its own Kaimon,
see `EMBEDDED`): there the tools are reached from outside, so a call from no one known is refused.
"""
function tool_caller()
    c = something(mcp_caller(), agent_caller(), Some(nothing))
    c === nothing || return c
    SHARED_MODE[] && EMBEDDED[] !== nothing && not_permitted("Not permitted: this tool call is from no one the service knows")
    return local_caller()
end

"""
Refuse unless the person an agent works for reaches project `x` (a key, or a task's reference) at
`level` (see project_access.jl). A task reached is one the agent is at work on (see agent_activity.jl).
"""
function tool_needs(x::AbstractString, level::Integer)
    key = need_project!(kb(), tool_caller(), something(ref_project(x), x), level)
    is_task_ref(x) && agent_seen!(x, tool_actor().name)
    return key
end

"Whether the person an agent works for may see the task (or project) `x`."
tool_sees(x::AbstractString) = project_access(kb(), tool_caller(), something(ref_project(x), x)) >= VIEW

"""
Whether the agent runs where the knowledge base does, working for whoever runs it, and so may attach
files from this machine by their paths. One connected over /mcp sends a file's bytes instead: a
path it gives would be read from the service's disk.
"""
agent_on_this_machine() = tool_caller().via == :local

const LOCAL_FILE_LINK = r"(!?\[[^\]\n]*\]\()((?:/|~/)[^)\s]+)(\))"

"Whether `p` names a file on a machine (`~/…`, `/Users/…`, `/tmp/…`), rather than a page of the site (`/generated/…`)."
machine_path(p::AbstractString) =
    startswith(p, "~/") || occursin(r"^/(?:Users|home|private|tmp|var|opt|srv|mnt|Volumes|root|scratch|global|data)/", p) || isfile(p)

"""
    attach_local_files(text, project) -> String

`text` with the files it links to by a path on this machine (`![a plot](/tmp/plot.png)`,
`[the data](~/run.csv)`) kept (see media.jl) and linked by their addresses instead, for an agent
on this machine (see [`agent_on_this_machine`](@ref)), as files of `project` (its key). For an agent
elsewhere, or a path to no file, an error that says what to do: such a link would show nothing.
"""
function attach_local_files(text::AbstractString, project)
    paths = [m[2] for m in eachmatch(LOCAL_FILE_LINK, text) if machine_path(m[2])]
    isempty(paths) && return String(text)
    if !agent_on_this_machine()
        error("$(join(paths, ", ")) $(length(paths) == 1 ? "is a path" : "are paths") on your machine, which the knowledge base cannot read. " *
              "Upload each with media_upload and link it by the media/… reference it gives, then send this again.")
    end
    missing_files = filter(p -> !isfile(expanduser(p)), paths)
    isempty(missing_files) || error("No file $(join(missing_files, ", ")): link files that exist, then send this again.")
    return replace(text, LOCAL_FILE_LINK => function (s)
        m = match(LOCAL_FILE_LINK, s)
        machine_path(m[2]) || return s
        m[1] * add_media!(kb(), read(expanduser(m[2])), basename(m[2]); by = tool_actor().name, project).address * m[3]
    end)
end

"The newest images a task's plan and activity show, at most `n`, as `(; bytes, type)` an agent can be shown."
function task_images(t; n::Integer = 4)
    addresses = String[]
    for text in [t.body; [coalesce(e.text, "") for e in t.activity]]
        for m in eachmatch(MEDIA_ADDRESS, text)
            m.match in addresses || push!(addresses, m.match)
        end
    end
    out = NamedTuple[]
    for a in reverse(addresses)
        f = media_file(kb(), match(MEDIA_ADDRESS, a)[1])
        (f === nothing || !(f.type in ("image/png", "image/jpeg", "image/gif", "image/webp")) || f.size > 5 * 1024^2) && continue
        path = media_path(kb().config, f.hash)
        isfile(path) && push!(out, (; bytes = read(path), type = f.type))
        length(out) >= n && break
    end
    return reverse(out)
end

"A tool's answer of `text` followed by `images`, as MCP content blocks (see KaimonGate's `image_result`)."
function with_images(text::AbstractString, images)
    isempty(images) && return String(text)
    blocks = Any[Dict("type" => "text", "text" => text)]
    append!(blocks, [Dict("type" => "image", "data" => base64encode(i.bytes), "mimeType" => i.type) for i in images])
    return KaimonGate.MCP_CONTENT_SENTINEL * JSON.json(Dict("content" => blocks))
end

# A tool applies the code's changes first, where Revise is loaded (tool calls come through the gate,
# not the web server, which does this for its requests), and reports a refusal (a task an agent may
# not move, an unknown reference) as its answer.
function refusing(f)
    revise_code()
    try Base.invokelatest(f) catch e; reason(e) === nothing ? rethrow() : "⛔ " * reason(e) end
end

# ── The tools for projects and tasks ─────────────────────────────────────────────────────────────

"""
    projects(; path::String="") -> String

The projects work is planned in, with their keys (the prefix of their tasks' references, as
in KB-12) and how many tasks are open. With `path`, your working directory, only the projects
for the codebase you are in. Plan multi-step work as tasks in a project rather than writing
plan or design files: see `plan`.
"""
function projects_tool(; path::String = "")::String
    ps = [p for p in projects(kb(); path) if tool_sees(p.key)]
    isempty(ps) && return isempty(path) ? "No projects yet: make one with `project_create`." :
                          "No project for $path. `projects` lists them all; `project_create` makes one (with `codebase`, for this directory)."
    return join(("$(p.key): $(p.name) · $(p.open) open of $(p.tasks)" * (isempty(p.codebase) ? "" : " · codebase $(p.codebase)") *
                 (isempty(p.active_milestone) ? "" : " · active milestone $(p.active_milestone)") *
                 (isempty(p.description) ? "" : "\n  $(p.description)") for p in ps), "\n")
end
tool!("projects", projects_tool; need = "tasks.view")

"""
    tasks(; project::String="", status::String="", milestone::String="", assignee::String="", q::String="", all::Bool=false, archived::Bool=false, declined::Bool=false) -> String

Tasks on a project's board, column by column (proposed, backlog, ready, in_progress, review,
done), filtered by `status`, `milestone`, `assignee` or text `q`. Subtasks are shown under their
task in `task`; `all=true` lists them here too. `archived=true` lists the project's archive:
done tasks taken off the board, the latest first. `declined=true` lists the plans people declined;
look there before proposing something similar.
"""
function tasks_tool(; project::String = "", status::String = "", milestone::String = "", assignee::String = "",
                    q::String = "", all::Bool = false, archived::Bool = false, declined::Bool = false)::String
    refusing() do
        isempty(project) || tool_needs(project, VIEW)
        ts = [t for t in tasks(kb(); project, status, milestone, assignee, q, top = !all, archived, declined) if tool_sees(t.ref)]
        isempty(ts) && return "No tasks."
        join((task_line(t) for t in ts), "\n")
    end
end
tool!("tasks", tasks_tool; need = "tasks.view")

"Where a task matched, as a line of a tool's answer: what matched (a note with who wrote it and when), its matching words in bold."
match_line(m) = (m.field == "note" ? "$(m.who) ($(m.kind), $(first(m.at, 10))): " :
                 m.field == "person" ? "$(m.who), $(first(m.at, 10)): " : "$(m.field): ") *
                replace(m.snippet, '\x01' => "**", '\x02' => "**", '\n' => " ")

"""
    task_search(q::String; project::String="") -> String

Search the tasks: `q`'s words in titles, plans, comments, progress notes and questions, best
first, each with where it matched. Filters can be mixed in: `status:ready`, `is:open`,
`is:sent-back`, `is:archived`, `is:declined`, `assignee:agent`, `milestone:"…"`, `project:KB`,
and `person:"Ada Byron"` (or an email): the tasks someone created, commented on, moved, edited
or is assigned to, with what they did. A query that is only a name finds them too.
Use it to find what was decided or discussed before planning something new.
"""
function task_search_tool(q::String; project::String = "")::String
    refusing() do
        isempty(project) || tool_needs(project, VIEW)
        hits = [h for h in search_tasks(kb(), q; project, limit = 15, projects = visible_projects(kb(), tool_caller())) if tool_sees(h.ref)]
        isempty(hits) && return "Nothing matches."
        join((task_line(t) * join(("\n  " * match_line(m) for m in t.matches)) for t in hits), "\n")
    end
end
tool!("task_search", task_search_tool; need = "tasks.view")

"""
    task_match(items::String; project::String="", limit::Int=5, archived::Bool=true, meaning::Bool=false) -> String

Which existing tasks pieces of free text are about: a note, a follow-up from a meeting, a
question. Use it before planning, to find work already planned or decided, or to link text to
the work it refers to. `items` is a JSON array of `{"id": "…", "text": "…"}` (up to 50), or one
text. Each item's distinctive words are searched together (any of them, not all), and a task's
title, plan and notes count together. Archived tasks are included unless `archived=false`;
declined ones never are. With `meaning=true` the texts are also matched by meaning, all embedded
in one request (slower). For each item: its best `limit` tasks with their status and score, and
the one or two places each matched.
"""
function task_match_tool(items::String; project::String = "", limit::Int = 5, archived::Bool = true, meaning::Bool = false)::String
    refusing() do
        isempty(project) || tool_needs(project, VIEW)
        raw = strip(items)
        parsed = startswith(raw, "[") ? JSON.parse(raw) : [Dict("id" => "1", "text" => raw)]
        list = [(; id = string(get(x, "id", i)), text = string(get(x, "text", ""))) for (i, x) in enumerate(parsed)]
        length(list) <= 50 || error("At most 50 items at a time; got $(length(list))")
        out = match_tasks(kb(), list; project, limit = clamp(limit, 1, 20), archived, meaning, visible = tool_sees)
        join(map(out) do m
            isempty(m.tasks) && return "[$(m.id)] nothing matches"
            "[$(m.id)]\n" * join(map(m.tasks) do t
                "  " * task_line(t) * (t.archived ? " · archived" : "") * " (score $(round(t.score; digits = 3)))" *
                join(("\n    " * match_line(x) for x in t.matches))
            end, "\n")
        end, "\n")
    end
end
tool!("task_match", task_match_tool; need = "tasks.view")

"""
    task_status(refs::String) -> String

Where each of several tasks stands, in one call: `refs` comma- or space-separated (`KB-12, KB-14`).
For each: its status, whether it is archived, when it last changed, and when it last had a
comment, progress note or question. For following a set of tasks and noticing changes cheaply.
"""
function task_status_tool(refs::String)::String
    refusing() do
        wanted = [uppercase(String(r)) for r in split(refs, r"[,\s]+") if !isempty(r)]
        foreach(r -> tool_needs(r, VIEW), wanted)
        rows = task_statuses(kb(), wanted)
        isempty(rows) && return "No such tasks."
        join(("$(r.ref) $(r.status)$(r.archived ? " archived" : "") updated $(r.updated_at)" *
              (isempty(r.last_note_at) ? "" : " noted $(r.last_note_at)") for r in rows), "\n")
    end
end
tool!("task_status", task_status_tool; need = "tasks.view")

"""
    task(ref::String) -> String

Task `ref` (KB-12) in full: its plan, subtasks, links, what blocks it, and its activity, where
people's comments are.
"""
task_tool(ref::String)::String = refusing() do
    tool_needs(ref, VIEW)
    t = task(kb(), ref)
    with_images(format_task(t), task_images(t))
end
tool!("task", task_tool; need = "tasks.view")

"""
    next_task(project::String; take::Bool=false) -> String

What to work on next in `project`: the project's context (what its people say of it, what it has
found, and its library), then the questions asked of the agents on its tasks that wait for a reply
(answer each with `task_note(kind="comment", reply_to=<its note>)`), then the highest-priority approved task
that is assigned to an agent or to nobody and that nothing open blocks, in full (its plan,
subtasks and comments). A task a person has taken is theirs, though subtasks under it may be
assigned to an agent. With `take=true` it is also moved to in_progress and assigned to you. Work
through its subtasks (mark each done with `task_update`), report with `task_note` as you go, and
move it to review when it is finished.
"""
function next_task_tool(project::String; take::Bool = false)::String
    refusing() do
        tool_needs(project, CONTRIBUTE)
        questions = questions_text(asked_of_agents(kb(), project))
        ref = next_task(kb(), project)
        # The project's context comes with work to do: a question to answer or a task.
        asked = (ref === nothing && isempty(questions) ? "" : project_context(project)) * questions
        ref === nothing && return asked * "Nothing approved and unblocked in $(uppercase(project)): tasks waiting for approval stay in proposed. " *
                                  "Call task_wait to wait for a person to approve, answer or comment, instead of stopping."
        if take
            assigned = task(kb(), ref).assignee
            update_task!(kb(), ref; status = "in_progress", assignee = isempty(assigned) ? AGENT_ASSIGNEE : assigned, by = tool_actor())
        end
        asked * (take ? "Taken: " : "Next: ") * format_task(task(kb(), ref))
    end
end
tool!("next_task", next_task_tool; need = "tasks.edit")

"""
    plan(project::String, title::String; body::String="", subtasks::String="", milestone::String="", parent::String="", priority::String="normal") -> String

Plan work as a task in `project` (its key): `title`, the plan itself in `body` (Markdown), and
`subtasks`, one per line. Use this rather than writing a plan or design file whenever work
takes more than a step or two, or the person should see and steer it. The plan is proposed: a
person reads it, may edit it, and moves it on before you start. Then move the task and its subtasks
along with `task_update`, report with `task_note`, and link what you used with `task_link`. A
subtask can have subtasks of its own: plan them with `parent`. Plans and notes refer to things with
`@`: `@KB-12` a task, `@arXiv:2401.00001` a paper, and `@[label](author:key)`,
`@[label](person:id)` or `@[label](notebook:path)` the others; each becomes one of the task's links.
Build on what the project has found (`findings`), and cite the findings a plan rests on as `@KB-F3`.
"""
function plan_tool(project::String, title::String; body::String = "", subtasks::String = "", milestone::String = "",
                   parent::String = "", priority::String = "normal")::String
    refusing() do
        tool_needs(project, CONTRIBUTE)
        list = [String(strip(l, [' ', '-', '*', '\t'])) for l in split(subtasks, '\n') if !isempty(strip(l, [' ', '-', '*', '\t']))]
        ref = create_task!(kb(), project, title; body = attach_local_files(body, project), subtasks = list, milestone, parent,
                           priority = something(parse_priority(priority), 2), by = tool_actor())
        "$ref proposed, with $(length(list)) subtask(s). It waits for a person to move it on.\n\n" * format_task(task(kb(), ref))
    end
end
tool!("plan", plan_tool; need = "tasks.edit")

"""
    task_update(ref::String; status::String="", title::String="", body::String="", milestone::String="", assignee::String="", blocked::String="", unblock::Bool=false, priority::String="", parent::String="", with_subtasks::Bool=false) -> String

Change task `ref`: move it to `status` (backlog, ready, in_progress, review, done), retitle it,
rewrite its plan, set its `milestone` ("none" for none), `assignee` (a person, or `agent:Claude`)
or `priority` (asap, high, normal, low), put it under another task as a step (`parent`, "none"
for the top level), or say why it is `blocked` (`unblock=true` clears it). Empty fields are left
as they are. A proposed task stays proposed until a person moves it on. A task is done only when
its subtasks are: mark them done first, or give `with_subtasks=true` to mark them done with it.
"""
function task_update_tool(ref::String; status::String = "", title::String = "", body::String = "", milestone::String = "",
                          assignee::String = "", blocked::String = "", unblock::Bool = false, priority::String = "",
                          parent::String = "", with_subtasks::Bool = false)::String
    refusing() do
        nonempty(s) = isempty(s) ? nothing : s
        tool_needs(ref, CONTRIBUTE)
        update_task!(kb(), ref; status = nonempty(status), title = nonempty(title), body = nonempty(attach_local_files(body, ref_project(ref))),
                     parent = parent == "none" ? "" : nonempty(parent),
                     milestone = milestone == "none" ? "" : nonempty(milestone), assignee = nonempty(assignee),
                     blocked = unblock ? "" : nonempty(blocked), priority = parse_priority(priority),
                     with_subtasks, by = tool_actor())
        task_line(task(kb(), ref))
    end
end
tool!("task_update", task_update_tool; need = "tasks.edit")

"""
    task_note(ref::String, text::String; kind::String="progress", to::String="", reply_to::Int=0) -> String

Report on task `ref` in its activity: what you did, found or decided (`kind="progress"`), a
comment (`kind="comment"`), or a question (`kind="question"`), which waits on the list of whom it
is asked until they reply. Ask `to` a project member (their name or email), or `"anyone"` on the
project; with no `to`, a question goes to the task's assignee. To answer a question, give its note
number as `reply_to` with `kind="comment"`; with `kind="question"` you ask back about it, and
the question goes to whoever asked it. People read the activity to follow and steer the work.
Refer to tasks and papers as `@KB-12` and `@arXiv:2401.00001` (see `plan` for the other kinds);
each becomes one of the task's links.
"""
task_note_tool(ref::String, text::String; kind::String = "progress", to::String = "", reply_to::Int = 0)::String = refusing() do
    tool_needs(ref, CONTRIBUTE)
    note = note_task!(kb(), ref, attach_local_files(text, ref_project(ref)); kind, by = tool_actor(), to, reply_to)
    t = kind == "question" ? only(e for e in task(kb(), ref).activity if e.id == note) : nothing
    "Noted on $(uppercase(strip(ref))) (note $note)" * (t === nothing ? "." : ", asked of $(t.to_label).")
end
tool!("task_note", task_note_tool; need = "tasks.edit")

"""
    task_note_edit(ref::String, note::Int, text::String) -> String

Correct note `note` on task `ref`, one of your own (its number is shown in the task's activity,
and when you wrote it): `text` replaces it whole. The earlier text is kept in its history, and
the note is marked edited.
"""
task_note_edit_tool(ref::String, note::Int, text::String)::String =
    refusing(() -> (tool_needs(ref, CONTRIBUTE); edit_note!(kb(), ref, note, attach_local_files(text, ref_project(ref)); by = tool_actor()); "Edited note $note on $(uppercase(strip(ref)))."))
tool!("task_note_edit", task_note_edit_tool; need = "tasks.edit")

"""
    task_attach(ref::String; path::String="", media::String="", data::String="", name::String="", caption::String="") -> String

Attach a file to task `ref`, as a note in its activity: an image or a movie shown inline (a figure
from a notebook, an animation), anything else as a link (a data file, a PDF). Give `path`, a file on
this machine, when you run where the knowledge base does. From any other machine, upload it with
`media_upload` (which can post it here itself) and give its reference here as `media`
(`media/<hash>/plot.png`). `data`, the file base64-encoded with its `name`, is only for a few bytes:
the model has to reproduce every character. `caption` says what it shows. In plans, notes and
findings, `![caption](/path/to/plot.png)` attaches a file on this machine the same way. For a Slate
cell's figure, save it to a file in the notebook (`save("plot.png", fig)`) and attach that.
"""
function task_attach_tool(ref::String; path::String = "", media::String = "", data::String = "", name::String = "",
                          caption::String = "")::String
    refusing() do
        tool_needs(ref, CONTRIBUTE)
        if !isempty(media)                                  # a file already kept, uploaded with media_upload
            a = match(MEDIA_ADDRESS, media)
            f = a === nothing ? nothing : media_file(kb(), a[1])
            (f === nothing || !media_visible(kb(), tool_caller(), f.hash)) &&
                not_found("No file $media here: upload it with media_upload first")
            belongs!(kb(), f.hash, ref_project(ref))
            m = (; f.hash, name = String(a[2]), f.type, f.size, address = String(a.match))
            note = note_task!(kb(), ref, media_note(m, caption); kind = "progress", by = tool_actor())
            return "Attached $(m.name) to $(uppercase(strip(ref))) (note $note), as $(m.address)."
        end
        bytes, file = if !isempty(path)
            agent_on_this_machine() || error("A path is read on the knowledge base's machine: upload the file with media_upload, " *
                                             "and attach it with media=\"media/…\" (or let media_upload post it)")
            p = expanduser(path)
            isfile(p) || not_found("No file $path")
            (read(p), isempty(name) ? basename(p) : name)
        elseif !isempty(data)
            isempty(name) && error("Name the file: name=\"plot.png\"")
            (try base64decode(data) catch; error("data is not base64") end, name)
        else
            error("Give the file: path, or data with its name")
        end
        m = add_media!(kb(), bytes, file; by = tool_actor().name, project = ref_project(ref))
        note = note_task!(kb(), ref, media_note(m, caption); kind = "progress", by = tool_actor())
        "Attached $(m.name) to $(uppercase(strip(ref))) (note $note), as $(m.address)."
    end
end
tool!("task_attach", task_attach_tool; need = "tasks.edit")

"""
    media_upload(ref::String; name::String, caption::String="", post::Bool=true) -> String

Get a link to upload a file to the knowledge base from your own machine, without its bytes passing
through you: a figure, a PDF, a movie, a data file. `ref` is the task (`KB-12`), finding
(`KB-F3`) or project (`KB`) it is for; `name` the file's name with its extension (`fig.png`);
`caption` what it shows. Then send the file from your shell with the command given
(`curl -sS -T fig.png "<link>"`), within 30 minutes, once; it answers with the file's reference,
`media/<hash>/fig.png`, to use wherever Markdown goes: `![caption](media/…)` in a finding's body,
a note or a plan, or `result: media/…` as a source in `finding_evidence`. With `post`, a file for a
task is also shown in its activity with its caption. Files up to the service's limit (200 MB
unless configured otherwise): images (png, jpg, gif, webp, svg), pdf, movies (mp4, webm, mov),
csv, json, zip and text. The same file sent twice is kept once.
"""
function media_upload_tool(ref::String; name::String = "", caption::String = "", post::Bool = true)::String
    refusing() do
        key = tool_needs(ref, CONTRIBUTE)
        c = tool_caller()
        base = site_base(kb().config)
        isempty(base) && return "The knowledge base is not served from this process, so there is no link to upload to: " *
                                "attach the file by its path with task_attach(ref, path = …) instead."
        token = upload_link!(ref, key; name, caption, post, by = tool_actor(), user = c.user_id)
        link = "$base/api/media/upload/$token"
        "Send $(media_name(name)) from your shell, within $UPLOAD_MINUTES minutes, once:\n\n" *
        "    curl -sS -T $(media_name(name)) \"$link\"\n\n" *
        "(-T takes the file's path, from wherever it is.) It answers with the file's reference, media/<hash>/$(media_name(name)), " *
        "to use in Markdown: ![caption](media/…) in findings, notes and plans, or `result: media/…` in finding_evidence." *
        (post && is_task_ref(ref) ? " It is also posted to $(uppercase(strip(ref)))'s activity." : "") *
        " Files here are at most $(kb().config.media_max_mb) MB."
    end
end
tool!("media_upload", media_upload_tool; need = "tasks.edit")

"""
    task_diff(ref::String) -> String

The changes made by the commits recorded against task `ref` and the tasks under it, oldest first:
each commit's message, the files it changed and its patch. A commit is recorded against the tasks
its message names in a trailer line, `Tasks: KB-12, KB-14`.
"""
task_diff_tool(ref::String)::String = refusing() do
    tool_needs(ref, VIEW)
    d = task_diff(kb(), ref; max_chars = 20_000)       # what a tool result holds
    isempty(d) ? "No commits are recorded against $(uppercase(strip(ref))): a commit names its tasks in a `Tasks: $(uppercase(strip(ref)))` trailer." : d
end
tool!("task_diff", task_diff_tool; need = "tasks.view")

"""
    task_link(ref::String, kind::String, target::String; label::String="", remove::Bool=false) -> String

Link task `ref` to what it concerns: a `paper` (its arXiv id), a `notebook` (its path), `code`
(a codebase file, as codebase:path), a `chat` (a tutor conversation), a `url`, another `task`, or
a task this one `blocks`. `remove=true` takes the link away.
"""
task_link_tool(ref::String, kind::String, target::String; label::String = "", remove::Bool = false)::String =
    refusing(() -> (tool_needs(ref, CONTRIBUTE);
                    # A task linked to is one the agent's person may see: a link shows it on the task.
                    lowercase(kind) in ("task", "blocks") && tool_needs(target, VIEW);
                    link_task!(kb(), ref, kind, target; label, remove, by = tool_actor());
                    "$(remove ? "Unlinked" : "Linked") $(uppercase(strip(ref))) $(remove ? "from" : "to") $kind $target."))
tool!("task_link", task_link_tool; need = "tasks.edit")

"""
    project_create(name::String, key::String; description::String="", codebase::String="") -> String

A project to plan work in: `key` is its tasks' prefix (KB for KB-12), a letter and up to nine
letters or digits. Give `codebase` (its id, as `papers` lists codebases) for agents working in
that codebase's directory to find the project.
"""
project_create_tool(name::String, key::String; description::String = "", codebase::String = "")::String =
    refusing() do
        can(tool_caller(), "projects.create") || not_permitted("Not permitted: creating projects needs projects.create")
        "Project $(create_project!(kb(), name; key, description, codebase, owner = tool_caller().user_id,
                                   add_codebase = can(tool_caller(), "paper.add"), by = tool_actor(), caller = tool_caller())) made."
    end
tool!("project_create", project_create_tool; need = "tasks.edit")

"""
    project_codebase(project::String, codebase::String) -> String

Link project `project` to `codebase` (its id, `code-…`, as `papers` lists codebases, or its
repository's address, `https://github.com/owner/repo`), so agents working in that codebase's
directory find the project with `projects(path=…)`, and its commits are recorded against the
project's tasks. A shared service reads a codebase from its repository, so give the repository
for one it doesn't know; adding a repository it doesn't have takes paper.add. `"none"` unlinks it.
"""
project_codebase_tool(project::String, codebase::String)::String = refusing() do
    tool_needs(project, MAINTAIN)
    key = update_project!(kb(), project; codebase, add_codebase = can(tool_caller(), "paper.add"), by = tool_actor(),
                          caller = tool_caller())
    lowercase(strip(codebase)) in ("", "none") && return "Project $key is linked to no codebase."
    id = String(scalar(kb(), "SELECT d.doc_id FROM projects p JOIN papers d ON d.id = p.codebase_id WHERE p.key = ?", (key,)))
    SHARED_MODE[] || return "Project $key is linked to codebase $id."
    fetch_codebase!(kb(), id) || return "Project $key is linked to codebase $id, which can't be fetched yet: $(codebase_problem(kb(), id))."
    return "Project $key is linked to codebase $id, fetched from its repository."
end
tool!("project_codebase", project_codebase_tool; need = "tasks.edit")

"""
    library(project::String) -> String

Project `project`'s library: the papers, notebooks and codebases it works from, each with why
it matters to the project and the tasks and findings that cite it. Search within it with
`search(query; project=…)`.
"""
library_tool(project::String)::String = refusing(() -> (tool_needs(project, VIEW); format_library(kb(), project; caller = tool_caller())))
tool!("library", library_tool; need = "tasks.view")

"""
    library_add(project::String, source::String; why::String="") -> String

Propose `source` for project `project`'s library, with `why` it matters to the project: a paper
(`@arXiv:2401.00001`, `@doc-…`), a notebook (`@[label](notebook:path)`) or a codebase (`code-…`,
or its repository's address). A person keeps it or takes it out.
"""
library_add_tool(project::String, source::String; why::String = "")::String = refusing() do
    tool_needs(project, CONTRIBUTE)
    id = library_add!(kb(), project, source; why, by = tool_actor(), caller = tool_caller())
    "Proposed item $id for $(uppercase(strip(project)))'s library."
end
tool!("library_add", library_add_tool; need = "tasks.edit")

"""
    milestones(project::String) -> String

Project `project`'s milestones: each a goal with an optional date, and how many of its tasks are
done. New tasks go into the active one unless given another.
"""
milestones_tool(project::String)::String = refusing() do
    tool_needs(project, VIEW)
    ms = milestones(kb(), project)
    isempty(ms) ? "No milestones." :
        join(("$(m.name)$(isempty(m.start) ? "" : " · from $(m.start)")$(isempty(m.due) ? "" : " · due $(m.due)") · $(m.done)/$(m.total) done$(m.closed ? " · closed" : "")$(m.active ? " · active" : "")" *
              (isempty(m.description) ? "" : "\n  $(m.description)") for m in ms), "\n")
end
tool!("milestones", milestones_tool; need = "tasks.view")

"""
    milestone_create(project::String, name::String; start::String="", due::String="", description::String="", active::Bool=false) -> String

A milestone in `project`: a named goal, with the dates its work `start`s and is `due`
(YYYY-MM-DD), or none. With `active=true` it becomes the project's active milestone, where new tasks go.
"""
milestone_create_tool(project::String, name::String; start::String = "", due::String = "", description::String = "",
                      active::Bool = false)::String =
    refusing() do
        tool_needs(project, MAINTAIN)
        m = create_milestone!(kb(), project, name; due, start, description)
        active && set_active_milestone!(kb(), project, m)
        "Milestone $m added to $(uppercase(project))$(active ? ", and made active" : "")."
    end
tool!("milestone_create", milestone_create_tool; need = "tasks.edit")

"""
    milestone_update(project::String, name::String; start::String="", due::String="", description::String="", rename::String="") -> String

Change milestone `name` of `project`: when its work `start`s and when it is `due` (YYYY-MM-DD, or
"none" to clear one), its `description`, or its name (`rename`). What is left empty stays as it is.
"""
milestone_update_tool(project::String, name::String; start::String = "", due::String = "", description::String = "",
                      rename::String = "")::String =
    refusing() do
        tool_needs(project, MAINTAIN)
        date(d) = d == "none" ? "" : isempty(d) ? nothing : d
        m = update_milestone!(kb(), project, name; start = date(start), due = date(due),
                              description = isempty(description) ? nothing : description, rename = isempty(rename) ? nothing : rename)
        x = only(filter(x -> x.name == m, milestones(kb(), project)))
        "Milestone $m of $(uppercase(project)): " * (isempty(x.start) ? "" : "from $(x.start), ") *
            (isempty(x.due) ? "no end date" : "due $(x.due)") * "."
    end
tool!("milestone_update", milestone_update_tool; need = "tasks.edit")

"""
    task_wait(project::String; minutes::Float64=10) -> String

Wait for a person to do something on `project`'s tasks (approve or assign work, answer a
question, comment, move a task) for up to `minutes` (at most 25), and say what they did. Call it
when `next_task` has nothing for you instead of stopping, then call `next_task` again. Work
already approved, or a question already waiting for an agent, ends the wait at once.
"""
function task_wait_tool(project::String; minutes::Float64 = 10.0)::String
    refusing() do
        key = tool_needs(project, VIEW)
        # What is already there, approved since next_task last looked, is not waited for.
        ready = next_task(kb(), key)
        asked = asked_of_agents(kb(), key)
        ready === nothing && isempty(asked) || return "In $key, waiting for you already: " *
            join([ready === nothing ? String[] : ["$ready is approved and unblocked"];
                  isempty(asked) ? String[] : ["$(length(asked)) question(s) for an agent"]], "; ") * ".\n\nCall next_task to see it."
        minutes = clamp(minutes, 0.01, 25)
        since, deadline = last_event_id(kb()), time() + 60 * minutes
        agent = tool_actor().name
        agent_waiting!(key, agent, true)                  # shown on the board while it waits
        try
            v = TASKS_VERSION[]
            while time() < deadline
                v = wait_tasks_changed(v; timeout = min(20, max(deadline - time(), 0.01)))
                events = people_events(kb(), key, since)
                isempty(events) || return "In $key:\n" * people_events_text(events) * "\n\nCall next_task to see what to do now."
                # Progress keeps the call from being taken for a stalled one.
                KaimonGate.progress("Waiting for people on $key")
            end
            "Nothing from people on $key in $(round(minutes; digits = 1)) minutes. Wait again, or stop."
        finally
            agent_waiting!(key, agent, false)
        end
    end
end
# Its wait outlasts Kaimon's usual deadline: a declared budget past the longest wait.
tool!("task_wait", task_wait_tool; need = "tasks.view", timeout_ms = 27 * 60_000)

"""
    milestone_done(project::String, name::String; reopen::Bool=false) -> String

Mark milestone `name` of `project` done, archiving its completed tasks (unfinished ones stay on
the board), or open it again with `reopen=true`. Only a person marking it does this, never its date.
"""
milestone_done_tool(project::String, name::String; reopen::Bool = false)::String =
    refusing(() -> (tool_needs(project, MAINTAIN); finish_milestone!(kb(), project, name; reopen, by = tool_actor());
                    reopen ? "$name is open again." : "$name is done; its completed tasks are archived."))
tool!("milestone_done", milestone_done_tool; need = "tasks.edit")

"""
    milestone_activate(project::String, name::String) -> String

Make milestone `name` project `project`'s active one, where its new tasks go unless given
another ("" for none).
"""
milestone_activate_tool(project::String, name::String)::String =
    refusing(() -> (tool_needs(project, MAINTAIN); set_active_milestone!(kb(), project, name);
                    isempty(name) ? "$(uppercase(project)) has no active milestone now." : "$name is $(uppercase(project))'s active milestone."))
tool!("milestone_activate", milestone_activate_tool; need = "tasks.edit")

function task_line(t)
    bits = [STATUS_LABELS[t.status]]
    isempty(t.blocked) || push!(bits, "BLOCKED")
    t.priority == 2 || push!(bits, PRIORITIES[t.priority])
    isempty(t.milestone) || push!(bits, t.milestone)
    isempty(t.assignee) || push!(bits, "@" * t.assignee)
    t.subtasks > 0 && push!(bits, "$(t.subtasks_done)/$(t.subtasks) subtasks")
    return "$(t.ref) [$(join(bits, " · "))] $(t.title)"
end

"""
The person who sent task `t` back from Review or Done, and people's comments since it went there,
while it is being reworked (until it is back in review); `nothing` otherwise.
"""
function sent_back(t)
    finished = ("review", "done")
    i = findlast(e -> e.kind == "status" && (e.detail["from"] in finished || e.detail["to"] in finished), t.activity)
    i === nothing && return nothing
    e = t.activity[i]
    (e.detail["from"] in finished && !(e.detail["to"] in finished) && !e.by_agent) || return nothing
    j = findlast(x -> x.kind == "status" && x.detail["to"] in finished, t.activity)
    return (; who = e.who, comments = [x.text for x in t.activity[something(j, 1):end] if x.kind == "comment" && !x.by_agent])
end

"""
    project_context(key) -> String

What `next_task` gives agents about project `key` before the work: the context its people set for
it, what the project has found (its accepted findings, the latest `FINDINGS_IN_CONTEXT`, and those
contested, with why), and what it works from: its kept library, counted by kind, with the items
people said why they matter (a library brought in whole from a reference manager is a count).
"""
function project_context(key::AbstractString)
    k = uppercase(strip(key))
    p = filter(p -> p.key == k, projects(kb()))
    d = isempty(p) ? "" : only(p).description
    io = IOBuffer()
    isempty(d) || print(io, "## Project $k: context from its people\n\n$(plain_at_references(d))\n\n")
    accepted = findings(kb(); project = k, status = "accepted")
    contested = findings(kb(); project = k, status = "contested")
    if !isempty(accepted) || !isempty(contested)
        println(io, "## What $k has found (read one with `finding`)\n")
        for f in first(accepted, FINDINGS_IN_CONTEXT)
            println(io, "- $(f.ref) $(f.claim)")
        end
        length(accepted) > FINDINGS_IN_CONTEXT && println(io, "- … $(length(accepted) - FINDINGS_IN_CONTEXT) more: `findings(\"$k\")`")
        for f in contested
            println(io, "- $(f.ref) [contested: $(plain_at_references(f.status_reason))] $(f.claim)")
        end
        println(io)
    end
    kept = filter(x -> x.status == "kept", library(kb(), k; caller = tool_caller()))
    if any(x -> x.id > 0, kept)                       # more than the project's own codebase
        tally = Dict{String,Int}()
        foreach(x -> tally[library_noun(x)] = get(tally, library_noun(x), 0) + 1, kept)
        counts = sort!(collect(tally); by = c -> (-c[2], c[1]))
        println(io, "## What $k works from\n")
        println(io, "Its library holds ", join(("$n $(n == 1 ? w : w * "s")" for (w, n) in counts), ", ", " and "),
                ": `library(\"$k\")` lists them, and `search(query; project=\"$k\")` searches within them.\n")
        said = filter(x -> !isempty(x.why), kept)
        isempty(said) || println(io, "What its people said matters:\n")
        for x in first(said, LIBRARY_IN_CONTEXT)
            println(io, "- ", x.kind == "paper" ? cited_as(x.target) : x.target, isempty(x.label) || x.label == x.target ? "" : " $(x.label)",
                    ": $(x.why)")
        end
        length(said) > LIBRARY_IN_CONTEXT && println(io, "- … $(length(said) - LIBRARY_IN_CONTEXT) more")
        println(io)
    end
    out = String(take!(io))
    isempty(out) ? "" : out * "---\n\n"
end

"How many of a project's library items with a reason agents are given with its context."
const LIBRARY_IN_CONTEXT = 30

"How many of a project's accepted findings agents are given with its context, the latest changed first."
const FINDINGS_IN_CONTEXT = 20

"The questions people asked that wait for an agent, as `next_task` shows them before the task."
function questions_text(asked)
    isempty(asked) && return ""
    io = IOBuffer()
    println(io, "Questions asked of the agents, waiting for a reply. Answer each with ",
            "task_note(ref, text; kind=\"comment\", reply_to=<its note>), or ask back with kind=\"question\":\n")
    for q in asked
        println(io, "- ", task_line(q), "\n  ", q.asker, " asked [note $(q.note)]: ", replace(q.question, "\n" => "\n  "))
    end
    println(io)
    return String(take!(io))
end

"What question `e` of a task's activity waits on, as agents read it (see [`with_question_states`](@ref))."
question_state_text(e) =
    e.state == "resolved" ? "resolved" : e.state == "answered" ? "answered" :
    e.state == "asked back" ? "waiting on the answer to a question asked back" :
    e.to_whom == "agents" ? "waiting for an agent's reply" : "waiting for $(e.to_label)"

function format_task(t)
    io = IOBuffer()
    back = sent_back(t)
    if back !== nothing
        println(io, "Sent back from review by $(back.who)", isempty(back.comments) ? "." : ", who wrote:")
        foreach(c -> println(io, "> ", replace(c, "\n" => "\n> ")), back.comments)
        println(io)
    end
    println(io, task_line(t))
    page = ref_link(kb().config, t.ref)
    isempty(page) || println(io, "Page: ", page)
    println(io, "By $(t.created_by)$(t.by_agent ? " (agent)" : ""), $(t.created_at)" * (isempty(t.parent) ? "" : " · part of $(t.parent)"))
    isempty(t.blocked) || println(io, "Blocked: ", t.blocked)
    isempty(t.blocked_by) || println(io, "Blocked by: ", join(t.blocked_by, ", "))
    isempty(t.body) || println(io, "\n## Plan\n\n", plain_at_references(t.body))
    isempty(t.subtasks_list) || println(io, "\n## Subtasks\n\n", join(("- " * task_line(s) for s in t.subtasks_list), "\n"))
    isempty(t.links) || println(io, "\n## Links\n\n", join(("- $(l.kind) $(l.target)" * (isempty(l.label) ? "" : " ($(l.label))") for l in t.links), "\n"))
    isempty(t.commits) || println(io, "\n## Commits\n\n", join(("- $(first(c.sha, 10)) $(first(c.at, 10)) $(c.subject) ($(c.author)" *
        (isempty(c.ref) ? "" : ", $(c.ref)") * ", +$(c.added) −$(c.removed) in $(length(c.files)) file$(length(c.files) == 1 ? "" : "s")" *
        (c.task == t.ref ? "" : ", for $(c.task)") * ")" for c in t.commits), "\n"), "\n\n`task_diff` shows their changes.")
    isempty(t.findings) || println(io, "\n## Findings from it\n\n", join(("- $(f.ref) [$(f.status)] $(f.claim)" for f in t.findings), "\n"))
    isempty(t.mentions) || println(io, "\n## Mentioned in commits\n\n", join(("- $(first(c.sha, 10)) $(first(c.at, 10)) $(c.subject) ($(c.author))"
                                                                        for c in t.mentions), "\n"))
    println(io, "\n## Activity\n")
    for (i, e) in enumerate(t.activity)
        what = e.kind == "question" ? "asked $(e.to_label)" * (e.reply_to > 0 ? ", about note $(e.reply_to)" : "") *
                                      " ($(question_state_text(e))): " * plain_at_references(e.text) :
               event_text(e)
        note = e.kind in SEARCHED_NOTES ? " [note $(e.id)$(isempty(e.edited_at) ? "" : ", edited")]" : ""
        println(io, "- $(first(e.at, 16)) $(e.who)$(e.by_agent ? " (agent)" : "")$note: $what")
    end
    return String(take!(io))
end

"What event `e` of a task's activity did, as agents read it."
event_text(e) =
    e.kind == "question" ? (e.reply_to > 0 ? "asked back about note $(e.reply_to): " : "asked: ") * plain_at_references(e.text) :
    e.kind == "comment" && get(e, :reply_to, 0) > 0 ? "answered note $(e.reply_to): " * plain_at_references(e.text) :
    e.kind == "status" ? "moved it from $(STATUS_LABELS[e.detail["from"]]) to $(STATUS_LABELS[e.detail["to"]])" :
    e.kind == "edit" ? "changed its $(e.detail["field"])" * (haskey(e.detail, "to") && e.detail["field"] != "body" ? " to $(e.detail["to"])" : "") :
    e.kind in ("comment", "progress") ? Dict("progress" => "reported: ", "comment" => "wrote: ")[e.kind] * plain_at_references(e.text) :
    e.kind == "blocked" ? "blocked it: " * e.text : e.kind == "unblocked" ? "unblocked it" :
    e.kind == "link" ? "linked $(e.detail["kind"]) $(e.text)" :
    e.kind == "deleted" ? "deleted subtask $(e.text)" : e.kind in ("archived", "unarchived") ? "$(e.kind) it" :
    e.kind == "declined" ? "declined it" * (isempty(e.text) ? "" : ": " * e.text) : e.kind == "undeclined" ? "brought it back to Proposed" :
    e.kind == "created" ? "created it" : e.kind

"What people did on a project's tasks (see `people_events`), for an agent that waited for it."
people_events_text(events) =
    join(("- $(e.ref) ($(e.title)): $(e.who) $(event_text(e))" for e in events), "\n")
