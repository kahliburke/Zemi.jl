# Promoting new papers, and a paper of the day. The judge (the config's `watch_judge`, else its
# summarizer) reads the abstracts of the best placed new papers in one go and says how much each
# matters to the group; those it rates related or central are promoted. Each day one paper, from the
# promoted ones or from the library's unread papers, is picked, read in full and analysed for the
# group, with its key figures cut from the PDF.

judge(c::Config) = summarizer(c, isempty(c.watch_judge) ? c.summarizer : c.watch_judge)

"Today's date in UTC, as the papers of the day are kept by: `yyyy-mm-dd`."
utc_today() = string(Date(now(UTC)))

const WATCH_JUDGE_SYSTEM = "You judge which new research papers a research group should read. Reply with a JSON object only."


"""
    judge_watched!(kb; batch = 15) -> Int

Have the judge rate every watched paper not yet judged, best placed first, reading the abstracts of
`batch` together at a time: 0 unrelated, 1 peripheral, 2 related or 3 central to the group's work,
with a sentence on why. Returns how many were judged.
"""
function judge_watched!(kb::KB; batch::Integer = 15)
    judged = 0
    while true
        n = judge_batch!(kb, batch)
        n == 0 && return judged
        judged += n
    end
end

# One batch of `judge_watched!`: how many were judged (0 when none is left, or the judge rated none).
function judge_batch!(kb::KB, n::Integer)
    rows = query(kb, """SELECT doc_id AS id, title, abstract FROM watch
                        WHERE relevance IS NULL AND doc_id NOT IN (SELECT doc_id FROM papers)
                        ORDER BY score DESC LIMIT ?""", (n,))
    isempty(rows) && return 0
    s = judge(kb.config)
    prompt = group_brief(kb.config) * "\nNew papers:\n\n" * join(("[$(r.id)] $(r.title)\n$(r.abstract)\n\n" for r in rows)) * """
        For each paper, judge how much it matters to the group's work: 0 unrelated, 1 peripheral, 2 related,
        3 central. Give one sentence a group member would find useful: what the paper does that bears on
        their work, or why it does not. Reply as JSON: {"papers": [{"id": "...", "relevance": 0, "reason": "..."}]},
        one entry per paper."""
    d = reply_json(ask(s, WATCH_JUDGE_SYSTEM, prompt), "The judge")
    judged = 0
    asked = Set(String(r.id) for r in rows)
    transaction(kb) do
        for p in get(d, "papers", [])
            rel = get(p, "relevance", nothing)
            rel isa Integer || continue
            # As the judge may write it (`arXiv:2610.01234v1`), and only one it was asked about.
            id = replace(String(get(p, "id", "")), r"^arXiv:"i => "", r"v\d+$" => "")
            id in asked || continue
            execute!(kb, "UPDATE watch SET relevance = ?, reason = ?, judged_by = ? WHERE doc_id = ?",
                     (clamp(rel, 0, 3), String(get(p, "reason", "")), s.name, id))
            judged += 1
        end
    end
    # None of those asked about rated: they would only be asked about again, so the judging stops here.
    judged == 0 && !isempty(rows) && @warn "The judge rated none of the new papers it was given; they are left unrated" batch = length(rows)
    return judged
end

"""
    daily_candidates(kb; new = 8, library = 5) -> Vector{NamedTuple}

What the paper of the day is picked from: the promoted new papers (rated related or central, taken
into the knowledge base or not; see [`take_watched!`](@ref)) and the library's papers recorded but
not read, those the landscape places nearest the focus areas first, leaving out papers picked before. `(; id, title, abstract, source, why, relevance)`, `relevance`
the judge's rating of a new paper (`nothing` for one from the library).
"""
function daily_candidates(kb::KB; new::Integer = 8, library::Integer = 5)
    picked = Set(r.id for r in query(kb, "SELECT doc_id AS id FROM daily"))
    out = Any[(; id = r.id, title = r.title, abstract = r.abstract, source = "new", why = coalesce(r.reason, ""),
                 relevance = Int(r.relevance))
           for r in query(kb, """SELECT doc_id AS id, title, abstract, reason, relevance FROM watch
                                 WHERE relevance >= 2 ORDER BY relevance DESC, score DESC""") if !(r.id in picked)]
    out = first(out, new)
    land = read_landscape(kb.config)
    near = land === nothing ? Dict{String,Float64}() : Dict(String(p["id"]) => Float64(p["relevance"]) for p in land["papers"])
    unread = [r for r in query(kb, """SELECT doc_id AS id, title, abstract FROM papers p
                                      WHERE $(literature_sql()) AND title IS NOT NULL
                                        AND NOT EXISTS (SELECT 1 FROM parses x WHERE x.paper_id = p.id)""")
              if !(r.id in picked) && is_arxiv_id(r.id)]
    sort!(unread; by = r -> -get(near, r.id, 0.0))
    append!(out, [(; id = r.id, title = r.title, abstract = coalesce(r.abstract, ""), source = "library", why = "",
                     relevance = nothing)
                  for r in first(unread, library)])
    return out
end

"""
    pick_daily!(kb; day = today) -> NamedTuple

Have the judge pick, from [`daily_candidates`](@ref), the paper most worth the group's close
reading, and record it as the paper of `day` (a day can have several: the latest is its paper),
with how much it matters to the group: a new paper's rating, or the judge's rating of a library paper
as it picks it. Returns `(; id, why, source, relevance)`.
"""
function pick_daily!(kb::KB; day::AbstractString = utc_today())
    cands = daily_candidates(kb)
    isempty(cands) && error("Nothing to pick a paper of the day from: no promoted new papers, and no unread papers in the library")
    prompt = group_brief(kb.config) * "\nCandidates:\n\n" *
        join(("[$(c.id)] ($(c.source == "new" ? "new on arXiv" : "in the library, unread")) $(c.title)\n$(c.abstract)" *
              (isempty(c.why) ? "" : "\nJudged: $(c.why)") * "\n\n" for c in cands)) * """
        Pick the one paper that most rewards a close reading by the group now: substantive, new to them, and
        bearing on their work. Reply as JSON: {"id": "...", "why": "two or three sentences for the group on why this one",
        "relevance": how much it matters to the group's work, 0 unrelated, 1 peripheral, 2 related or 3 central}."""
    d = reply_json(ask(judge(kb.config), WATCH_JUDGE_SYSTEM, prompt), "The judge")
    id = String(d["id"])
    c = findfirst(x -> x.id == id, cands)
    c === nothing && error("The judge picked $id, which was not a candidate")
    rated = get(d, "relevance", nothing)
    relevance = something(cands[c].relevance, rated isa Integer ? clamp(rated, 0, 3) : nothing, Some(nothing))
    execute!(kb, "INSERT OR REPLACE INTO daily (day, doc_id, source, why, status, picked_at, relevance) VALUES (?, ?, ?, ?, 'picked', ?, ?)",
             (day, id, cands[c].source, String(get(d, "why", "")), now_iso(), something(relevance, missing)))
    return (; id, why = String(get(d, "why", "")), source = cands[c].source, relevance)
end

analyst_system(c::Config) = "You are a senior researcher writing for a research group$(in_field(c)). You read papers " *
                       "closely and critically. Use only the Read tool. Reply with a JSON object only."

function analysis_prompt(c::Config)
    return group_brief(c) * """

        The paper is attached as a PDF; preamble.txt holds its summaries and the papers of the group's library
        nearest it, with their ids. Read the paper itself, figures and equations included, then write an
        analysis of it for the group: newcomers to the field among them, so explain what needs explaining.

        Write Markdown with these sections:
        ## What it does — the problem, the approach, the main results with their numbers.
        ## What is new — against what came before, as the paper and the library papers show it.
        ## Where it touches our work — cite the library papers it bears on as [arXiv:id], only ids from preamble.txt.
        ## Assumptions and limits — what the results rest on and where they may not hold.
        ## Questions worth asking — two to four, for a group discussion.
        ## Computing with it — whether a notebook could compute something useful from the paper (a model, a
        scaling, an equation to evaluate or a result to reproduce at small scale), and if so what.

        Write mathematics as LaTeX: inline between single dollar signs (\$\\alpha = 0.05\$, \$x_i^2\$), and
        displayed equations in a fenced block whose language is math. Not Unicode symbols standing in for it.

        Pick one to three figures that carry the main results, named exactly as their captions begin
        ("Figure 3", "Fig. 2").

        Reply as JSON: {"analysis": "<Markdown>", "figures": [{"label": "Figure 3", "why": "what it shows"}],
        "computable": {"tractable": true, "idea": "one paragraph"}}."""
end

"""
    feature_daily!(kb, day, id; progress) -> NamedTuple

Make paper `id` the feature of `day`: read it in full (recording it first if need be), have the
configured summarizer write an analysis of it for the group from its PDF, its summaries and the
library papers nearest it, and cut the figures it names from the PDF (see [`cut_figure`](@ref)).
"""
function feature_daily!(kb::KB, day::AbstractString, id::AbstractString; progress = msg -> nothing)
    setstatus(status, err = missing) = execute!(kb, "UPDATE daily SET status = ?, error = ? WHERE day = ? AND doc_id = ?",
                                                (status, err, day, id))
    try
        setstatus("reading")
        add_papers!(kb, [id]; source = "daily")
        refresh_metadata!(kb, [id])
        progress("reading $id in full")
        r = only(ingest!(kb, [id]; progress))
        r.ok || error("Reading $id failed: $(r.error)")
        setstatus("analysing")
        p = paper_row(kb, id)
        who = something(shown_summarizer(kb, id), "")
        sums = query(kb, "SELECT unit_key, text FROM summaries WHERE paper_id = ? AND summarizer = ? ORDER BY unit_key", (p.id, who))
        near = related_papers(kb, id; limit = 8)
        io = IOBuffer()
        println(io, "Paper: [arXiv:$id] ", coalesce(p.title, id), "\n\nIts summaries:\n")
        foreach(r -> println(io, r.text, "\n"), sums)
        println(io, "\nPapers of the group's library nearest it:\n")
        for n in near
            s = coalesce(scalar(kb, "SELECT text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%' LIMIT 1", (paper_id(kb, n.doc_id),)), "")
            println(io, "[arXiv:", n.doc_id, "] ", n.title, "\n", first(s, 1200), "\n")
        end
        pdf = first(query(kb, "SELECT path FROM files WHERE paper_id = ?", (p.id,))).path
        progress("analysing $id")
        d = reply_json(ask(purpose(kb.config, :analyst), analyst_system(kb.config), analysis_prompt(kb.config);
                           preamble = String(take!(io)), pdfs = [pdf]), "The analyst")
        figures = [Dict{String,Any}("label" => String(get(f, "label", "")), "why" => String(get(f, "why", "")))
                   for f in get(d, "figures", [])]
        cut = cut_figures!(kb, id, figures)
        execute!(kb, "UPDATE daily SET status = 'done', analysis = ?, figures = ?, computable = ?, done_at = ?, error = NULL WHERE day = ? AND doc_id = ?",
                 (String(d["analysis"]), JSON.json(figures), JSON.json(get(d, "computable", Dict())), now_iso(), day, id))
        return (; id, figures = cut)
    catch e
        e isa InterruptException && rethrow()
        setstatus("failed", sprint(showerror, e))
        rethrow()
    end
end

"""
    start_daily(kb; another = false, again = false, day = "") -> Job

Pick and feature today's paper as a job: when today has none yet, or with `another`, a new one. With
`again`, the paper of `day` (today when empty) is analysed again instead (its reading is kept), its
figures cut anew.
Returns the job already doing it, if one is.
"""
function start_daily(kb::KB; another::Bool = false, again::Bool = false, day::AbstractString = "")
    again || isempty(day) || error("A day other than today can only have its paper analysed again")
    running = filter(j -> j.status == :running && j.name == "paper of the day", list_jobs())
    isempty(running) || return first(running)
    return start_job("paper of the day"; changes = changes_stamp(kb.config)) do job
        day = isempty(day) ? utc_today() : String(day)
        if again
            d = findfirst(r -> r.day == day, dailies(kb))
            d === nothing && error("$day has no paper to analyse again")
            id = dailies(kb)[d].id
            r = feature_daily!(kb, day, id; progress = m -> report!(job, m))
            return "Paper of the day: $id analysed again, with $(r.figures) figure(s)."
        end
        if !another && !ismissing(scalar(kb, "SELECT 1 FROM daily WHERE day = ? AND status = 'done'", (day,)))
            return "Today's paper is already chosen."
        end
        report!(job, "judging the new papers")
        judge_watched!(kb)
        report!(job, "picking the paper of the day")
        p = pick_daily!(kb; day)
        r = feature_daily!(kb, day, p.id; progress = m -> report!(job, m))
        "Paper of the day: $(p.id), with $(r.figures) figure(s)."
    end
end

"""
    cut_figures!(kb, id, figures) -> Int

Cut every figure and table of paper `id` (see [`cut_paper_figures!`](@ref)), and point each of `figures` (the
analysis's picks, `Dict`s with a `"label"`) at its own, setting `"file"` and `"caption"` on those
found; a figure not found is kept without them, to try again (see [`refigure_daily!`](@ref)).
Returns how many of the picks were found.
"""
function cut_figures!(kb::KB, id::AbstractString, figures)
    cut = Dict((f.kind, f.number) => f for f in cut_paper_figures!(kb, id))
    n = 0
    for f in figures
        named = parse_figure_label(f["label"])
        g = named === nothing ? nothing : get(cut, named, nothing)
        if g === nothing
            delete!(f, "file")
        else
            f["file"], f["caption"] = g.file, g.caption
            n += 1
        end
    end
    return n
end

"""
    sweep_daily_figures!(kb; progress) -> Int

Bring every finished day's figures into its paper's folder of figures, once (it is recorded in `kv`
as `daily_figures_swept`): where the paper's PDF is here, every figure is cut (see
[`cut_figures!`](@ref)) and the analysis's picks pointed at them; where it is not (a dataset's
consumer), the picks' files are moved over as they are. Returns the number of days.
"""
function sweep_daily_figures!(kb::KB; progress = msg -> nothing)
    days = [d for d in dailies(kb) if d.status == "done"]
    for (i, d) in enumerate(days)
        progress("[$i/$(length(days))] the figures of $(d.id)")
        old = joinpath(kb.config.data_dir, "daily", d.day)
        figures = Dict{String,Any}.(d.figures)
        pdf = query(kb, "SELECT path FROM files WHERE paper_id = ?", (paper_id(kb, d.id),))
        try
            if !isempty(pdf) && isfile(first(pdf).path)
                cut_figures!(kb, d.id, figures)
                execute!(kb, "UPDATE daily SET figures = ? WHERE day = ? AND doc_id = ?", (JSON.json(figures), d.day, d.id))
            else
                for f in figures
                    from = joinpath(old, get(f, "file", ""))
                    haskey(f, "file") && isfile(from) && (mkpath(figures_dir(kb.config, d.id)); mv(from, joinpath(figures_dir(kb.config, d.id), f["file"]); force = true))
                end
            end
        catch e
            e isa InterruptException && rethrow()
            @warn "Could not bring the figures of $(d.day) over" exception = e
            continue
        end
        # What the day's folder held is in the paper's now, or cut again there.
        isdir(old) && foreach(f -> occursin(r"\.(png|theme)$", f) && rm(joinpath(old, f)), readdir(old))
    end
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('daily_figures_swept', ?)", (now_iso(),))
    return length(days)
end

"""
    start_figure_sweep(kb) -> Union{Job,Nothing}

As a job, what a knowledge base from before every figure was cut needs, once: the papers of the day's
figures brought into their papers' folders (see [`sweep_daily_figures!`](@ref)), every read paper's
figures and tables cut (see [`cut_papers_figures!`](@ref)), and the figures cut or imported as PNG
images converted to WebP (see [`webp_figures!`](@ref)). `nothing` when none of these is left.
"""
function start_figure_sweep(kb::KB)
    days = ismissing(scalar(kb, "SELECT value FROM kv WHERE key = 'daily_figures_swept'"))
    papers = !isempty(query(kb, uncut_sql() * " LIMIT 1"))
    pngs = !isempty(png_figure_papers(kb))
    days || papers || pngs || return nothing
    return start_job("figures of the papers read"; changes = changes_stamp(kb.config)) do job
        d = days ? sweep_daily_figures!(kb; progress = m -> report!(job, m)) : 0
        n = cut_papers_figures!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        w = webp_figures!(kb; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        "Figures brought over for $d day(s), cut from $n paper(s), and $w converted to WebP."
    end
end

"""
    refigure_daily!(kb, day) -> Int

Cut the figures of `day`'s paper again. Where its analysis named none that are kept, the summarizer
picks them from the paper's captions and the analysis. Returns how many were cut.
"""
function refigure_daily!(kb::KB, day::AbstractString)
    d = first(r for r in dailies(kb) if r.day == day)
    figures = Dict{String,Any}.(d.figures)
    if isempty(figures)
        captions = [r.text for r in query(kb, "SELECT text FROM blocks WHERE paper_id = ? AND kind = 'caption' ORDER BY ord",
                                          (paper_id(kb, d.id),)) if occursin(r"^fig"i, r.text)]
        isempty(captions) && return 0
        prompt = "An analysis of a paper:\n\n$(d.analysis)\n\nThe paper's figure captions:\n\n" * join(captions, "\n\n") * """

            Pick one to three figures that carry the paper's main results, named exactly as their captions begin
            ("Figure 3", "Fig. 2"). Reply as JSON: {"figures": [{"label": "Figure 3", "why": "what it shows"}]}."""
        got = reply_json(ask(purpose(kb.config, :analyst), analyst_system(kb.config), prompt), "The analyst")
        figures = [Dict{String,Any}("label" => String(f["label"]), "why" => String(get(f, "why", ""))) for f in get(got, "figures", [])]
    end
    n = cut_figures!(kb, d.id, figures)
    execute!(kb, "UPDATE daily SET figures = ? WHERE day = ? AND doc_id = ?", (JSON.json(figures), day, d.id))
    return n
end

"""
    dailies(kb) -> Vector{NamedTuple}

The papers of the day, latest first: for each day its latest pick, with `(; day, id, title, source,
why, status, analysis, figures, gallery, computable, error, notebooks, notebook_status, relevance,
relevance_note)`: `figures` the analysis's picks, `gallery` every figure cut from the paper (see
[`paper_figures`](@ref)), as `Dict`s, the paper's notebooks as its page shows them (see
[`paper_notebooks`](@ref)), how the latest made or added stands, and how much the paper matters to the group (0 to 3, or `nothing`): its
classification's rating, from the paper read in full, else the rating it was picked with.
"""
function dailies(kb::KB)
    rows = query(kb, """SELECT d.*, p.title FROM daily d LEFT JOIN papers p ON p.doc_id = d.doc_id
                        WHERE d.picked_at = (SELECT max(picked_at) FROM daily e WHERE e.day = d.day)
                        ORDER BY d.day DESC""")
    return [(; r.day, id = r.doc_id, title = coalesce(r.title, r.doc_id), r.source, r.why, r.status,
               analysis = coalesce(r.analysis, ""), figures = ismissing(r.figures) ? [] : JSON.parse(r.figures),
               gallery = [Dict{String,Any}(String(k) => v for (k, v) in pairs(f)) for f in paper_figures(kb, r.doc_id)],
               computable = ismissing(r.computable) ? Dict() : JSON.parse(r.computable), error = coalesce(r.error, ""),
               notebooks = paper_notebooks(kb, r.doc_id),
               notebook_status = (n = notebook_states(kb, r.doc_id); isempty(n) ? "" : last(n).status),
               day_relevance(kb, r)...)
            for r in rows]
end

# A day's relevance: its paper's classification's, else the rating it was picked with.
function day_relevance(kb::KB, r)
    c = something(classification(kb, r.doc_id), Dict{String,Any}())
    rel = get(c, "relevance", nothing)
    rel isa Integer && 0 <= rel <= 3 && return (; relevance = Int(rel), relevance_note = string(something(get(c, "relevance_note", nothing), "")))
    return (; relevance = ismissing(r.relevance) ? nothing : Int(r.relevance), relevance_note = "")
end

"`day`'s entry among `days` (see [`dailies`](@ref)), or the latest one done when `day` is empty; `nothing` for none."
function daily_entry(days, day::AbstractString)
    isempty(days) && return nothing
    isempty(strip(day)) && return days[something(findfirst(d -> d.status == "done", days), 1)]
    i = findfirst(d -> d.day == strip(day), days)
    return i === nothing ? nothing : days[i]
end

"""
    format_daily(kb, day = ""; site = the service's address) -> String

The paper of `day` (`YYYY-MM-DD`; the latest when empty) as text for an agent: the paper, how and why
it was picked, the analysis, the figures it singled out (their images are [`daily_figures`](@ref))
and the notebooks made from it, then the other days with a paper. With `site`, the address of the
day's page and of each figure on it, to link to.
"""
function format_daily(kb::KB, day::AbstractString = ""; site::AbstractString = site_base(kb.config))
    days = dailies(kb)
    isempty(days) && return "No paper of the day has been picked yet."
    d = daily_entry(days, day)
    d === nothing && return "No paper of the day on $(strip(day)). Days with one: " * join((e.day for e in first(days, 30)), ", ")
    io = IOBuffer()
    println(io, "Paper of the day, $(d.day): $(d.title) (arXiv:$(d.id))")
    at = rstrip(site, '/')
    isempty(at) || println(io, "Page: $at/generated/kb/daily/$(d.day)/index.html")
    println(io, d.source == "new" ? "New on arXiv" : "From the library", isempty(d.why) ? "" : ". Why: $(d.why)")
    d.relevance === nothing ||
        println(io, "Relevance to the group: $(d.relevance) of 3, $(RELEVANCE[d.relevance+1])", isempty(d.relevance_note) ? "" : ". $(d.relevance_note)")
    d.status == "done" || println(io, "Status: $(d.status)", isempty(d.error) ? "" : " ($(d.error))")
    isempty(d.analysis) || println(io, "\n## Analysis\n\n", d.analysis)
    figures = [f for f in d.figures if haskey(f, "file")]
    if !isempty(figures)
        println(io, "\n## Figures\n\nTheir images follow, in this order.\n")
        for f in figures
            println(io, "- ", f["label"], isempty(get(f, "why", "")) ? "" : ": $(f["why"])",
                    isempty(at) ? "" : "\n  Image: $at/api/daily/$(d.day)/$(f["file"])",
                    isempty(get(f, "caption", "")) ? "" : "\n  Caption: $(first(f["caption"], 300))")
        end
    end
    picked = Set(f["file"] for f in figures)
    rest = [g for g in d.gallery if !(g["file"] in picked)]
    if !isempty(rest)
        println(io, "\n## Its other figures\n")
        for g in rest
            println(io, "- ", g["label"], ": ", first(g["caption"], 300), isempty(at) ? "" : "\n  Image: $at/api/daily/$(d.day)/$(g["file"])")
        end
    end
    isempty(d.notebooks) || println(io, "\n## Notebooks\n\n", join(("- $(n.title) ($(n.path))" for n in d.notebooks), "\n"))
    others = [e for e in days if e.day != d.day && e.status == "done"]
    isempty(others) || println(io, "\n## Other days\n\n", join(("- $(e.day): $(e.title) (arXiv:$(e.id))" for e in first(others, 14)), "\n"))
    return String(take!(io))
end

"""
    daily_figures(kb, day = "") -> Vector{NamedTuple}

The figures cut from `day`'s paper (the latest when empty), as images an agent can be shown, `(; bytes,
type)`, in the order [`format_daily`](@ref) lists them.
"""
function daily_figures(kb::KB, day::AbstractString = "")
    d = daily_entry(dailies(kb), day)
    d === nothing && return NamedTuple[]
    files = [joinpath(figures_dir(kb.config, d.id), f["file"]) for f in d.figures if haskey(f, "file")]
    return [(; bytes = read(p), type = image_type(p)) for p in files if isfile(p) && filesize(p) <= 5 * 1024^2]
end

# ── On the site ──────────────────────────────────────────────────────────────────────────────────
# The Paper of the Day page shows the latest day's paper; each day has a page of its own at
# `daily/<day>/`, made from a template like a paper's (see `TEMPLATED`, KBDayPage.vue), with its
# figures beside its analysis and links to the days either side.

"""
    analysis_text(kb, text) -> String

An analysis as a day's page renders it (KBDayPage.vue, with kbMarkdown): its sections under the
paper's heading, and its `[arXiv:id]` citations as links to the papers' pages, or to arXiv for a
paper not here. Its mathematics stays as written.
"""
function analysis_text(kb::KB, text::AbstractString)
    title(id) = (t = scalar(kb, "SELECT title FROM papers WHERE doc_id = ?", (id,)); ismissing(t) ? nothing : t)
    text = replace(text, r"^(#{1,5}) "m => s"#\1 ")
    return replace(text, r"\[(arXiv:[^\]]+)\]" => function (group)
        ids = [String(m[1]) for m in eachmatch(r"arXiv:\s*([^\s;,\]]+)", group)]
        links = map(ids) do id
            name = title(id)
            name === nothing ? "[arXiv:$id](https://arxiv.org/abs/$id)" :
                               "[$(replace(name, r"([\[\]])" => s"\\\1"))](/generated/kb/papers/$(page_slug(id)).html)"
        end
        "(" * join(links, "; ") * ")"
    end)
end

"""
    figure_places(markdown, figures) -> Vector

`markdown` in pieces, with each of `figures` (an index, by the `(kind, number)` a mention of it
names, see [`figure_mentions`](@ref)) after the first paragraph that mentions it; those it never
mentions go before it. Each piece is Markdown text or a figure's index. Headings, code, tables and
quotes are not paragraphs here.
"""
function figure_places(markdown::AbstractString, figures::AbstractDict)
    # Blocks are separated by blank lines, a fenced block (math, code) kept whole.
    blocks, current, fenced = String[], String[], false
    for line in split(markdown, '\n')
        startswith(lstrip(line), "```") && (fenced = !fenced)
        if !fenced && isempty(strip(line)) && !startswith(lstrip(line), "```")
            isempty(current) || push!(blocks, join(current, '\n'))
            empty!(current)
        else
            push!(current, line)
        end
    end
    isempty(current) || push!(blocks, join(current, '\n'))
    left = Dict(figures)
    out, text = Any[], String[]
    flush!() = (isempty(text) || push!(out, join(text, "\n\n")); empty!(text))
    for b in blocks
        push!(text, b)
        occursin(r"^\s*(#|```|\||>)", b) && continue
        for key in figure_mentions(b)
            haskey(left, key) && (flush!(); push!(out, pop!(left, key)))
        end
    end
    flush!()
    return [[left[k] for k in sort!(collect(keys(left)))]; out]
end

"""
    day_json(kb, d; before = nothing, after = nothing) -> Dict

A day's data file: what its page shows (KBDayPage.vue lays it out). Its analysis is in pieces, text
and the picked figures placed beside the paragraphs that discuss them (see [`figure_places`](@ref));
a pick whose file the site lacks is left out (a knowledge base can hold a day whose paper's figures
were not cut on this machine; see `write_site`). `before` and `after` are the days either side.
"""
function day_json(kb::KB, d; before = nothing, after = nothing)
    picks = [f for f in d.figures if haskey(f, "file") && !get(f, "missing", false)]
    named = Dict(first(figure_mentions(f["label"])) => i - 1 for (i, f) in enumerate(picks) if !isempty(figure_mentions(f["label"])))
    c = d.computable
    neighbour(e) = e === nothing ? nothing : Dict("day" => e.day, "title" => e.title)
    return Dict{String,Any}(
        "day" => d.day, "id" => d.id, "slug" => page_slug(d.id), "title" => d.title, "local" => !is_arxiv_id(d.id),
        "source" => d.source == "new" ? "new on arXiv" : "from the library", "why" => d.why,
        "relevance" => d.relevance === nothing ? nothing :
                       Dict("level" => d.relevance, "label" => RELEVANCE_BADGE[d.relevance+1], "note" => something(d.relevance_note, "")),
        "figures" => [Dict(k => f[k] for k in ("label", "why", "file", "light", "dark", "width") if haskey(f, k)) for f in picks],
        "analysis" => [x isa Integer ? Dict("figure" => x) : Dict("text" => x) for x in figure_places(analysis_text(kb, d.analysis), named)],
        "gallery" => Dict("figures" => count(g -> g["kind"] == "figure", d.gallery), "tables" => count(g -> g["kind"] == "table", d.gallery),
                          "discussed" => [f["file"] for f in d.figures if haskey(f, "file")]),
        "notebooks" => [Dict("title" => nb.title, "page" => notebook_page_name(nb), "summary" => first(nb.summary, 240),
                             "by" => nb.kind == "agent" ? "made by an agent" : !isempty(nb.added_by) ? "added by " * nb.added_by : "added")
                        for nb in d.notebooks],
        "idea" => get(c, "tractable", false) === true && !isempty(get(c, "idea", "")) ? c["idea"] : nothing,
        "before" => neighbour(before), "after" => neighbour(after))
end

"""
    daily_json(days) -> Vector{Dict}

The days with a paper, latest first, for the calendar on the Paper of the Day's pages
(KBDayCalendar.vue, which reads them from the site's `daily.json`): each one's `day`, and its
paper's `id` and `title`.
"""
daily_json(days) = [Dict("day" => d.day, "id" => d.id, "title" => d.title) for d in days if d.status == "done"]

"""
    daily_pages(kb, days) -> (; pages, data)

The Paper of the Day's pages, as `path => Markdown` under the knowledge base's pages: `daily.md`,
showing the latest day's paper, and a stub page `daily/<day>/index.md` for each day (see
`TEMPLATED`); and each day's data file, as `"<day>/index" => Dict` (see [`day_json`](@ref)).
"""
function daily_pages(kb::KB, days)
    done = [d for d in days if d.status == "done"]
    landing = """
        # Paper of the Day

        One paper a day, from new arXiv papers or unread ones in the library, read in full and analysed for the group.

        ```@raw html
        <KBDaily />
        ```

        """ * (isempty(done) ? "No paper has been picked yet.\n" : "```@raw html\n<KBDayPage latest />\n```\n")
    pages = ["daily.md" => landing]
    data = Pair{String,Dict{String,Any}}[]
    for (i, d) in enumerate(done)        # latest first: the day before is the next one in the list
        push!(pages, "daily/$(d.day)/index.md" => template_markdown("daily"))
        push!(data, "$(d.day)/index" => day_json(kb, d; before = get(done, i + 1, nothing), after = i > 1 ? done[i - 1] : nothing))
    end
    return (; pages, data)
end
