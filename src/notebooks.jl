# Notebooks with papers: Slate notebooks computing from a paper, made by an agent given a Slate hub's
# tools (it writes the notebook through the hub, running and fixing it until every cell runs) or
# uploaded by someone. A paper can have several. Its page shows each, rendered by the site's build,
# and offers each for download. They live in the knowledge base's content, under
# notebooks/papers/<paper>/ (see `content_path`), and reach others with it.

"""
    notebook_hub() -> String

The Kaimon Slate extension a notebook agent works through, by its tools' namespace (`slate`,
`slatembse`, …): `ZEMI_NOTEBOOK_HUB`, else `slate`.
"""
notebook_hub() = get(ENV, "ZEMI_NOTEBOOK_HUB", "slate")

"The Slate hub's tools a notebook agent works with, beside its file tools."
notebook_tools(hub::AbstractString = notebook_hub()) = (["mcp__kaimon__$(hub)_" * t for t in
    ("open", "close", "read", "inspect", "view", "add_cell", "edit_cell", "delete_cell", "run", "check_eval",
     "api", "search_docs", "pkg")])

"Where the notebooks being made can be watched as they are built: notebook path => its Slate address."
const NOTEBOOK_LIVE = LockedDict{String,String}()

"The folder of paper `id`'s notebooks: `notebooks/papers/<paper>/` in the content (see [`content_path`](@ref))."
notebook_dir(c::Config, id::AbstractString) = content_path(c, "notebooks", "papers", page_slug(id))

"""
    paper_notebooks(kb, id) -> Vector{NamedTuple}

Paper `id`'s notebooks to show, oldest first: `(; path, title, kind, summary, added_by, idea)`, `path`
in the content (see [`content_path`](@ref)), `kind` "agent", "upload" or, for a notebook in the paper's folder that was not made or
added here (from someone else's copy of the content), "shared", and `idea` what an agent was asked to compute. One being made, or
whose making failed, is left out.
"""
function paper_notebooks(kb::KB, id::AbstractString)
    rows = query(kb, "SELECT * FROM notebooks WHERE doc_id = ? ORDER BY started_at", (id,))
    known = Set(r.path for r in rows)
    out = [(; r.path, title = coalesce(r.title, "Notebook"), r.kind, summary = coalesce(r.summary, ""),
              added_by = coalesce(r.added_by, ""), idea = coalesce(r.idea, ""))
           for r in rows if r.status == "done" && isfile(content_path(kb.config, r.path))]
    dir = notebook_dir(kb.config, id)
    if isdir(dir)
        for f in sort!(readdir(dir))
            endswith(f, ".jl") || continue
            path = relpath(joinpath(dir, f), kb.config.content_dir)
            path in known || push!(out, (; path, title = notebook_title(joinpath(dir, f)), kind = "shared", summary = "",
                                           added_by = "", idea = ""))
        end
    end
    return out
end

"A notebook's title: its first Markdown heading, else its file name."
function notebook_title(file::AbstractString)
    m = match(r"^#\s+(.+)$"m, read(file, String))
    return m === nothing ? replace(splitext(basename(file))[1], r"[-_]+" => " ") : strip(m[1])
end

"""
    notebook_states(kb, id) -> Vector{NamedTuple}

Every notebook made or added here for paper `id`, oldest first, with how it stands: `(; path,
title, kind, status, idea, summary, added_by)`, `status` "making", "done" or "failed: …".
"""
notebook_states(kb::KB, id::AbstractString) =
    [(; r.path, title = coalesce(r.title, "Notebook"), r.kind, r.status, idea = coalesce(r.idea, ""),
        summary = coalesce(r.summary, ""), added_by = coalesce(r.added_by, ""))
     for r in query(kb, "SELECT * FROM notebooks WHERE doc_id = ? ORDER BY started_at", (id,))]

notebook_system(c::Config) = "You are a computational researcher$(in_field(c)) writing a Julia notebook in Kaimon Slate that " *
                        "computes something from a research paper, for a research group. Work through the Slate " *
                        "tools you have; reply at the end with a JSON object only."

function notebook_prompt(path::AbstractString, idea::AbstractString, hub::AbstractString = notebook_hub(); others = String[])
    task = isempty(idea) ?
        """Decide what in the paper is most worth computing in a notebook: a model or equation to evaluate, a
        scaling to explore, or a result to reproduce at small scale, with the inputs the paper gives. If nothing in
        it can usefully be computed in a notebook, make none, and reply with ok false and why.""" :
        "Follow this idea:\n\n$idea"
    also = isempty(others) ? "" :
        "\n\nThe paper already has notebooks: $(join(others, "; ")). Compute something they do not."
    return """
        The paper is attached as a PDF; preamble.txt holds its summaries (and any analysis written of it for
        the group). Make a Slate notebook at $path that computes from the paper. $task$also

        Your Slate tools are those named mcp__kaimon__$(hub)_…. Open the notebook with the open tool (it
        creates the file; if it is there from an earlier attempt, read its cells and finish it rather than
        starting over), then build it cell by cell:
        - First a markdown cell opening with a heading that names what the notebook computes, then the
          equations from the paper it uses (in LaTeX, inline \$…\$ and fenced math blocks), and what to expect.
        - Then code cells, each doing one step, small and quick: the whole notebook should run in a few
          minutes on a laptop. Prefer Julia's standard library and packages already in the notebook's
          environment; add a package only when needed (the pkg tool). Plot with CairoMakie, using
          Makie's dark theme (set_theme!(theme_dark())).
        - Markdown cells between steps saying what each result shows.
        - Last, a markdown cell interpreting the results against the paper's, and the notebook's own
          simplifications and limits.
        Send markdown cells plain Markdown; Slate wraps them itself. Call the api tool before using
        Slate's own helpers. Run every cell and inspect its output; fix what fails until all run cleanly.
        Say only what the paper supports, and say plainly where the notebook simplifies it.

        Reply as JSON: {"ok": true, "title": "a short title", "summary": "two or three sentences on what the
        notebook computes and finds"}, or {"ok": false, "summary": "why it could not be done"}."""
end

"""
    make_notebook!(kb, id; idea = "", progress) -> NamedTuple

Have an agent (the configured summarizer, given the Slate tools of [`notebook_hub`](@ref)) make a
notebook computing from paper `id` in its folder (see [`notebook_dir`](@ref)), following `idea`, else
the computation its paper-of-the-day analysis suggests, else what the agent judges worth computing,
and something its other notebooks do not. An attempt that failed is finished rather than begun
again. A paper not yet read is read in full first. Returns `(; ok, path, title, summary)`.
"""
function make_notebook!(kb::KB, id::AbstractString; idea::AbstractString = "", progress = msg -> nothing)
    id = only(add_papers!(kb, [id]))
    is_kind(k -> k.pdf, id) || error("A notebook is made from a paper's PDF; $id is not read from one")
    analysis = query(kb, "SELECT analysis, computable FROM daily WHERE doc_id = ? AND status = 'done' ORDER BY picked_at DESC", (id,))
    others = paper_notebooks(kb, id)
    if isempty(strip(idea)) && !isempty(analysis) && isempty(others)
        idea = String(get(JSON.parse(coalesce(first(analysis).computable, "{}")), "idea", ""))
    end
    failed = query(kb, "SELECT path FROM notebooks WHERE doc_id = ? AND kind = 'agent' AND status LIKE 'failed%' ORDER BY started_at DESC", (id,))
    rel = if !isempty(failed)
        first(failed).path
    else
        relpath(free_notebook_file(kb, notebook_dir(kb.config, id), "computed"; numbered = true), kb.config.content_dir)
    end
    path = content_path(kb.config, rel)
    mkpath(dirname(path))
    set(cols...) = execute!(kb, "UPDATE notebooks SET " * join(("$k = ?" for (k, _) in cols), ", ") * " WHERE path = ?",
                            (map(last, cols)..., rel))
    execute!(kb, """INSERT INTO notebooks (doc_id, path, kind, title, status, idea, started_at) VALUES (?, ?, 'agent', ?, 'making', ?, ?)
                    ON CONFLICT (path) DO UPDATE SET status = 'making', idea = excluded.idea, started_at = excluded.started_at""",
             (id, rel, "A notebook from the paper", idea, now_iso()))
    try
        p = paper_row(kb, id)
        if ismissing(scalar(kb, "SELECT 1 FROM parses WHERE paper_id = ?", (p.id,)))
            refresh_metadata!(kb, [id])
            progress("reading $id in full first")
            r = only(ingest!(kb, [id]; progress))
            r.ok || error("Reading $id failed: $(r.error)")
            p = paper_row(kb, id)
        end
        who = something(shown_summarizer(kb, id), "")
        sums = query(kb, "SELECT text FROM summaries WHERE paper_id = ? AND summarizer = ? ORDER BY unit_key", (p.id, who))
        preamble = "Paper: [arXiv:$id] $(coalesce(p.title, id))\n\nIts summaries:\n\n" * join((r.text for r in sums), "\n\n") *
                   (isempty(analysis) ? "" : "\n\nThe analysis written of it for the group:\n\n" * coalesce(first(analysis).analysis, ""))
        pdf = first(query(kb, "SELECT path FROM files WHERE paper_id = ?", (p.id,))).path
        s = purpose(kb.config, :notebooker)
        dir = agents_dir(s.name, "notebook-" * page_slug(id))
        rm(dir; force = true, recursive = true)
        mkpath(dir)
        write(joinpath(dir, "preamble.txt"), preamble)
        symlink(pdf, joinpath(dir, "paper.pdf"))
        progress("an agent is making a notebook from $id")
        prompt = notebook_prompt(path, idea; others = [o.title for o in others])
        # Progress as it goes: the agent's latest step, and how many cells it has added, run and changed.
        count = Dict("add_cell" => 0, "run" => 0, "edit_cell" => 0)
        function step(st)
            haskey(count, st.tool) && (count[st.tool] += 1)
            progress(string(st.says, " · ", count["add_cell"], " cells added, ", count["run"], " runs, ",
                            count["edit_cell"], " fixes"))
        end
        reply = with_agent(s, dir; system = notebook_system(kb.config), tools = notebook_tools()) do agent
            # Once the agent has the notebook open, the hub's address for it, to watch it being built.
            watched(st) = (step(st); haskey(NOTEBOOK_LIVE, rel) || (u = agent_urls(agent); isempty(u) || (NOTEBOOK_LIVE[rel] = first(u))))
            try
                agent_turn(agent, "Read preamble.txt and paper.pdf, then:\n\n" * prompt; timeout = 3 * s.timeout, activity = watched)
            finally
                delete!(NOTEBOOK_LIVE, rel)
            end
        end
        r = reply_json(reply, "The notebook agent")
        summary = String(get(r, "summary", ""))
        ok = get(r, "ok", false) === true && isfile(path)
        title = String(something(get(r, "title", nothing), ok ? notebook_title(path) : "A notebook from the paper"))
        set("status" => ok ? "done" : "failed: " * first(summary, 300), "summary" => summary, "title" => title,
            "done_at" => ok ? now_iso() : missing)
        return (; ok, path, title, summary)
    catch e
        e isa InterruptException && rethrow()
        set("status" => "failed: " * first(client_message(e), 300))
        rethrow()
    end
end

"""
    start_notebook(kb, id; idea = "") -> Job

Make a notebook from paper `id` (see [`make_notebook!`](@ref)) as a job, or return the job already
making one; the site rebuilds when it is done.
"""
function start_notebook(kb::KB, id::AbstractString; idea::AbstractString = "")
    name = "notebook from $id"
    running = filter(j -> j.status == :running && j.name == name, list_jobs())
    isempty(running) || return first(running)
    return start_job(name; ids = [id], changes = changes_stamp(kb.config)) do job
        r = make_notebook!(kb, id; idea, progress = m -> report!(job, m))
        r.ok ? "Notebook made: $(r.title). $(r.summary)" : "No notebook: $(r.summary)"
    end
end

"""
    add_notebook!(kb, id, text; name, title = "", added_by = "") -> String

Attach a notebook someone wrote to paper `id`: its Julia source `text` is saved in the paper's
folder under `name` (a file name; a name taken gets a number), shown on the paper's page from the
next site build. Returns its path in the content.
"""
function add_notebook!(kb::KB, id::AbstractString, text::AbstractString; name::AbstractString,
                       title::AbstractString = "", added_by::AbstractString = "")
    id = only(add_papers!(kb, [id]))
    isvalid(text) || error("The notebook is not text")
    length(text) <= 5_000_000 || error("The notebook is larger than 5 MB")
    base = replace(lowercase(splitext(basename(name))[1]), r"[^a-z0-9]+" => "-")
    base = isempty(strip(base, '-')) ? "notebook" : strip(base, '-')
    dir = mkpath(notebook_dir(kb.config, id))
    file = free_notebook_file(kb, dir, base)
    write(file, text)
    rel = relpath(file, kb.config.content_dir)
    title = isempty(strip(title)) ? notebook_title(file) : strip(title)
    execute!(kb, """INSERT INTO notebooks (doc_id, path, kind, title, status, added_by, started_at, done_at)
                    VALUES (?, ?, 'upload', ?, 'done', ?, ?, ?)""", (id, rel, title, added_by, now_iso(), now_iso()))
    note_changes!([id])
    touch(changes_stamp(kb.config))
    return rel
end

"""
    free_notebook_file(kb, dir, base; numbered = false) -> String

A file in `dir` for a new notebook named after `base` (`base.jl`, else `base-2.jl`, …; with
`numbered`, `base-1.jl` first) that no notebook of the content has the name of, in any folder, nor
any notebook the knowledge base records: the site renders each notebook under its name alone, so two
of one name cannot both be shown.
"""
function free_notebook_file(kb::KB, dir::AbstractString, base::AbstractString; numbered::Bool = false)
    taken = Set(first.(site_notebooks(kb.config)))
    union!(taken, splitext(basename(r.path))[1] for r in query(kb, "SELECT path FROM notebooks"))
    n = numbered ? 1 : 0
    name(n) = n == 0 ? base : "$base-$n"
    while name(n) in taken
        n += n == 0 ? 2 : 1
    end
    return joinpath(dir, name(n) * ".jl")
end

"The name of a notebook's page, under its paper's: its file's name."
notebook_page_name(nb) = splitext(basename(nb.path))[1]

"""
    notebook_links(nbs; to) -> String

A Markdown list linking to notebooks `nbs` (see [`paper_notebooks`](@ref)), whose pages are under
the path `to` (the paper's folder of pages), each with who made it and what it computes.
"""
function notebook_links(nbs; to::AbstractString)
    io = IOBuffer()
    for nb in nbs
        by = nb.kind == "agent" ? "made by an agent" : !isempty(nb.added_by) ? "added by " * escape_text(nb.added_by) : "added"
        println(io, "- [", escape_text(nb.title), "](", to, notebook_page_name(nb), ".md) · ", by,
                isempty(nb.summary) ? "" : " · " * escape_text(first(nb.summary, 240)))
    end
    return String(take!(io))
end

"""
    notebook_page(nb, id, title) -> String

A notebook's own page, under its paper's (`papers/<paper>/<notebook>.md`): what it is, what it was
asked to compute (for one an agent made), a link back to paper `id` (titled `title`) and to download
it, and the notebook, rendered by the site's build (unless `ZEMI_SITE_NOTEBOOKS=0`).
"""
function notebook_page(nb, id::AbstractString, title::AbstractString)
    rel = replace(nb.path, r"^notebooks/" => "")
    by = nb.kind == "agent" ? "made by an agent" : !isempty(nb.added_by) ? "added by " * nb.added_by : "added"
    io = IOBuffer()
    println(io, "# ", escape_text(nb.title), "\n")
    # A paper's page is a copy of its template written after the build (see `TEMPLATED`), so the link
    # is HTML, which the build does not look for a page behind.
    println(io, "```@raw html\n<p><em>A notebook from <a href=\"../", page_slug(id), ".html\">", html_escape(title), "</a>, ",
            html_escape(by), ".</em></p>\n```\n")
    if nb.kind == "agent"           # what it was asked to compute, if it was asked
        println(io, isempty(strip(nb.idea)) ? "*The agent chose what to compute.*\n" :
                    "**Asked to compute:**\n\n" * join(("> " * md_escape(l) for l in split(strip(nb.idea), '\n')), "\n") * "\n")
    end
    isempty(nb.summary) || println(io, escape_text(nb.summary), "\n")
    println(io, "```@raw html\n<p><KBDownload src=\"/notebooks/", rel, "\">Download the notebook</KBDownload>",
            " (a Kaimon Slate notebook: open it in Slate to run and change it)</p>\n```\n")
    println(io, "```@raw html\n<KBInLibraries kind=\"notebook\" target=\"", html_escape(nb.path), "\" />\n```\n")
    # A site built with ZEMI_SITE_NOTEBOOKS=0 renders no notebooks (no Slate hub to run them).
    get(ENV, "ZEMI_SITE_NOTEBOOKS", "1") == "0" ? println(io, "*Not rendered in this build of the site.*") :
        println(io, "```@slate ../../../../../notebooks/", rel, "\n```")
    return String(take!(io))
end
