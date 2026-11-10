# Summarizing and asking through Kaimon's agent system. An agent summarizer (a Claude model through a
# Claude subscription, a local model, or any agent Kaimon drives) reads a whole paper, from its PDF or
# its extracted text, before writing every summary. The work happens in a directory of its own under
# ~/.cache/zemi/agents, and the agent may only read and write files: nothing else of the
# user's is in reach.

"""
Kaimon, where it is loaded in this process: run by Kaimon as its extension, or the shared service's
own (see [`start_embedded!`](@ref)). The extension that loads with it sets this
(`ext/ZemiKaimonExt.jl`). Elsewhere Zemi reaches the Kaimon running on this machine through
KaimonGate (see kaimon_link.jl).
"""
const KAIMON = Ref{Union{Module,Nothing}}(nothing)

"Kaimon, or an error saying it is needed."
function kaimon()
    KAIMON[] === nothing && error("This needs Kaimon, for its agents and tools: add Kaimon to the environment and load it")
    return KAIMON[]
end

# How a Kaimon server tool is called: through the Kaimon session this code runs in. Tests swap in a
# stand-in for the agent tools.
const AGENT_CALL = Ref{Function}((name, args) -> KaimonGate.call_tool(name, args))

"A Kaimon server tool's reply, parsed from JSON when it is JSON."
function kaimon_tool(name::Symbol, args::Dict{String,Any})
    reply = try
        AGENT_CALL[](name, args)
    catch e
        e isa InterruptException && rethrow()
        msg = failure_message(e)
        occursin("no ZMQ context", msg) || occursin("service endpoint not available", msg) || rethrow()
        error("Agent summarizers work through Kaimon: run this from the zemi extension, a Slate notebook " *
              "or the zemi command, with Kaimon running ($msg)")
    end
    reply isa AbstractString || return reply
    s = strip(reply)
    startswith(s, "{") || startswith(s, "[") || error("Kaimon $name: $(first(s, 300))")
    return JSON.parse(s)
end

agents_dir(parts...) = joinpath(xdg_home("XDG_CACHE_HOME", ".cache"), "zemi", "agents", parts...)

"""
    open_agent(dir; id, model, tools = String[], system = "", effort = nothing) -> String

Open agent `id` with `model` working in `dir`, allowed only its file tools, kept to `dir` (see
[`file_tools`](@ref)), and `tools`; and to read the targets of the links in `dir` (see
[`agent_reads`](@ref)). Returns the id Kaimon gives it.
"""
function open_agent(dir::AbstractString; id::AbstractString, model::AbstractString,
                    tools::AbstractVector{<:AbstractString} = String[], system::AbstractString = "", effort = nothing)
    args = Dict{String,Any}("cwd" => dir, "id" => id, "model" => model, "permission" => "default",
        "allowed_tools" => [file_tools(dir); tools], "only" => true, "confine_allow" => agent_reads(dir), "system_prompt" => system)
    effort === nothing || (args["effort"] = effort)
    return kaimon_tool(:agent_open, args)["agent_id"]
end

"""
    with_agent(f, s, dir; system = "", tools = String[])

Open an agent for summarizer `s` working in `dir` (see [`open_agent`](@ref)), run `f(agent_id)`,
and close it however `f` ends.
"""
function with_agent(f, s::Summarizer, dir::AbstractString; system::AbstractString = "",
                    tools::AbstractVector{<:AbstractString} = String[])
    id = open_agent(dir; id = "zemi-" * string(rand(UInt32); base = 16), s.model, tools, system)
    try
        return f(id)
    finally
        try
            kaimon_tool(:agent_close, Dict{String,Any}("agent_id" => id))
        catch e
            @warn "Could not close agent $id" exception = e
        end
    end
end

"""
    agent_turn(id, text; timeout = 1800, poll = 5, partial = nothing, activity = nothing) -> String

Send the agent a turn and wait for it to end, returning its reply. Waiting polls rather than
blocking on one call, so a long turn (a long paper) is not cut off by the call's time limit.
`partial`, given, is called with the reply as written so far at each poll, and `activity` with each
tool call the agent makes, as a [`agent_step`](@ref).
"""
function agent_turn(id::AbstractString, text::AbstractString; timeout::Real = 1800, poll::Real = 5, partial = nothing,
                    activity = nothing)
    seen = Ref(activity === nothing ? 0 : length(agent_events(id)))
    turn = kaimon_tool(:agent_send, Dict{String,Any}("agent_id" => id, "text" => text))["turn"]
    t0 = time()
    while true
        out = kaimon_tool(:agent_output, Dict{String,Any}("agent_id" => id, "turn" => turn, "max_chars" => 200_000))
        get(out, "done", false) === true && return String(get(out, "text", ""))
        partial === nothing || isempty(get(out, "text", "")) || partial(String(out["text"]))
        if activity !== nothing
            events = agent_events(id)
            for e in events[seen[]+1:end]
                step = agent_step(e)
                step === nothing || activity(step)
            end
            seen[] = length(events)
        end
        get(out, "status", "") == "dead" && error("Agent $id stopped during its turn")
        if time() - t0 > timeout
            try kaimon_tool(:agent_interrupt, Dict{String,Any}("agent_id" => id)) catch end
            error("Agent $id did not finish within $(round(Int, timeout)) s")
        end
        sleep(poll)
    end
end

"""
Where the Kaimon this process's agents run in keeps its logs: the service's own (`KAIMON_CACHE_DIR`,
see [`start_embedded!`](@ref)) in shared mode, as Kaimon finds it.
"""
kaimon_cache() = kaimon_cache_dir()

"The events Kaimon has logged of agent `id`'s work: each a `Dict` with its `kind`, `turn` and `data`."
function agent_events(id::AbstractString)
    log = joinpath(kaimon_cache(), "agents", "$id.events.jsonl")
    isfile(log) || return Dict{String,Any}[]
    out = Dict{String,Any}[]
    for line in eachline(log)
        e = try JSON.parse(line) catch; nothing end
        e isa AbstractDict && push!(out, e)
    end
    return out
end

"The Slate notebook addresses (`http://…/n/<name>`) the tools agent `id` used answered with: those it has open."
agent_urls(id::AbstractString) =
    unique(String(m.match) for e in agent_events(id) if get(e, "kind", "") == "tool_result"
           for m in eachmatch(r"https?://[\w.\-]+:\d+/n/[\w\-]+", JSON.json(get(e, "data", nothing))))

"""
    agent_step(event) -> Union{NamedTuple,Nothing}

What a logged tool call of an agent does, as `(; tool, says)`: `tool` the tool's short name
(`add_cell`, `run`, `Read`, …) and `says` a phrase for people ("running cell `setup`"). A call is
logged as it starts, by name, and again with its inputs once they are written, which for a long file
can take a while; the first says what kind of thing is being done, the second which. Nothing for an
event that is not a tool call, or for looking up a tool.
"""
function agent_step(e::AbstractDict)
    get(e, "kind", "") == "tool_use" || return nothing
    call = get(something(get(e, "data", nothing), Dict()), "call", nothing)
    call isa AbstractDict || return nothing
    input = get(call, "rawInput", nothing)
    input isa AbstractDict || (input = Dict{String,Any}())
    name = String(something(get(call, "title", nothing), ""))
    name in ("", "ToolSearch") && return nothing
    tool = replace(name, r"^mcp__\w+?__[a-z]+_" => "")       # mcp__kaimon__slate_add_cell → add_cell
    cell = get(input, "cell", get(input, "id", get(input, "cell_id", "")))
    cell = isempty(string(cell)) ? "" : " `$(cell)`"
    says = if tool == "Read"
        f = basename(String(get(input, "file_path", "")))
        pages = get(input, "pages", nothing)
        f == "paper.pdf" ? "reading the paper" * (pages === nothing ? "" : " (pages $pages)") :
        f == "paper.txt" ? "reading the paper's text" :
        f == "context.md" ? "reading the paper's summaries" : isempty(f) ? "reading" : "reading $f"
    elseif tool == "Write"
        f = basename(String(get(input, "file_path", "")))
        ext = lowercase(splitext(f)[2])
        isempty(f) ? "writing" : ext in (".svg", ".png") ? "drawing a figure" : ext == ".html" ? "building a page" : "writing $f"
    elseif tool == "add_cell"
        "adding a $(get(input, "kind", "")) cell$cell"
    elseif tool == "edit_cell"
        "changing cell$cell"
    elseif tool == "delete_cell"
        "removing cell$cell"
    elseif tool in ("run", "check_eval")
        isempty(cell) ? "running the notebook" : "running cell$cell"
    elseif tool in ("inspect", "view", "read")
        "looking at" * (isempty(cell) ? " the notebook" : " cell$cell")
    elseif tool == "open"
        "opening the notebook"
    elseif tool == "pkg"
        pkgs = get(input, "packages", get(input, "add", get(input, "name", nothing)))
        pkgs = pkgs isa AbstractVector ? join(pkgs, ", ") : string(something(pkgs, ""))
        isempty(pkgs) ? "checking the notebook's packages" : "adding packages: " * pkgs
    elseif tool == "eval"
        "trying code in the notebook"
    elseif tool in ("api", "search_docs")
        "looking up Slate's helpers"
    elseif startswith(tool, "zemi") || occursin("zemi", name)
        "searching the knowledge base"
    else
        name
    end
    return (; tool, says)
end

agent_system(c::Config) = "You are a specialist who writes summaries of research papers for a searchable knowledge " *
                          "base used by researchers$(in_field(c)). Use only the Read and Write tools."

function agent_brief(reads::Symbol)
    reading = reads == :pdf ?
        """
        1. Read the whole paper first from its original PDF, paper.pdf, with the Read tool (at most 20 pages per \
        request: pages "1-20", then "21-40", and so on). The listed headings come from text extracted from that PDF, \
        which is in paper.txt if you need to match a listed section to the PDF. Read equations, figures and tables \
        from the PDF itself, and describe them correctly.""" :
        """
        1. Read the whole paper first: paper.txt holds its text, extracted from the PDF. Equations and symbols may be \
        garbled there (fractions flattened, overbars, signs and square roots lost); use the rest of the paper to work \
        out what they really say, and describe them correctly rather than copying the garbled form."""
    """
    task.md names the paper and lists the sections to summarize, each with a number (its "ord") and its heading path.

    $reading
    2. Summarize each listed section in 3–7 sentences for a researcher deciding whether to read it. Cover every main \
    point the section makes, not only the first or the most striking: the question or setup, the methods and \
    assumptions, each main result (with numbers where the paper gives them), and how it connects to the rest of the \
    paper. Keep the specifics a researcher would search for: named methods, devices, codes, quantities and values. \
    Describe key equations in words and keep the paper's notation for named quantities. Plain prose: no heading, no \
    bullet points, no preamble.
    3. Summarize the whole paper in one paragraph of 5–8 sentences: the problem it addresses, its approach, its main \
    results, and what is new about them. Then, on a new line beginning "Topics:", list 5–10 specific technical topics \
    it covers, separated by commas.

    Use the rest of the paper to interpret a section (notation, acronyms, what came before), but say only what the \
    paper supports: never expand an acronym or name a method in a way the paper does not, never add results it does \
    not report, and do not pad with remarks such as "no numerical results appear here".

    Write the result to summaries.json as a JSON object: {"sections": {"<ord>": "<summary>", ...}, "paper": \
    "<paper summary>\\nTopics: ..."} with exactly one entry per listed section (an empty "sections" object if none \
    are listed). Write the JSON carefully: you have no tool to check it. Then reply with one line saying it is written.
    """
end

"""
    agent_summaries(kb, s, doc_id) -> Symbol

Whether agent summarizer `s` has summarized the paper: `:none` when it has written nothing for it,
`:current` when every summary it would write is stored for the paper's current text, model and
prompt, and `:stale` when it has summaries that summarizing would replace.
"""
function agent_summaries(kb::KB, s::Summarizer, doc_id::AbstractString; sections = section_texts(kb, doc_id))
    have = Dict(r.unit_key => r.input_sha for r in query(kb,
        "SELECT unit_key, input_sha FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, paper_id(kb, doc_id))))
    isempty(have) && return :none
    input_sha(text) = summary_input_sha(s, text)
    inputs = summary_inputs(kb, s, doc_id, sections)
    current = get(have, "p:$doc_id", "") == input_sha(inputs.paper) &&
              all(t -> get(have, "s:$doc_id:$(t.ord)", "") == input_sha(inputs.sections[t.ord]), sections)
    return current ? :current : :stale
end

"""
    agent_summarize_paper!(kb, s, doc_id; progress) -> Int

Have agent summarizer `s` read the paper and write its section and paper summaries, then store them.
Skipped (returning 0) when every summary it would write is already stored for the current text.
Returns the number of summaries stored.
"""
function agent_summarize_paper!(kb::KB, s::Summarizer, doc_id::AbstractString; progress = msg -> nothing)
    is_kind(k -> k.tree, doc_id) && return agent_summarize_code!(kb, s, doc_id; progress)
    p = paper_row(kb, doc_id)
    sections = section_texts(kb, doc_id)
    agent_summaries(kb, s, doc_id; sections) == :current && return 0
    length(paper_input(sections)) > LONG_DOCUMENT_CHARS && return agent_summarize_long!(kb, s, doc_id, sections; progress)
    dir = agents_dir(s.name, doc_id)
    rm(dir; force = true, recursive = true)
    mkpath(dir)
    prompts = summary_prompts(doc_id)
    reads = reads_pdf(s) && is_kind(k -> k.pdf, doc_id) ? :pdf : :text    # a document not read from a PDF, from its text
    write(joinpath(dir, "BRIEF.md"), prompts.agent_brief(reads))
    write(joinpath(dir, "task.md"), "Paper: $(coalesce(p.title, doc_id))\n\nSections to summarize (ord: heading path):\n" *
        join(("- $(t.ord): $(t.path)\n" for t in sections)))
    write(joinpath(dir, "paper.txt"), read_paper(kb, doc_id; max_chars = typemax(Int)))
    if reads == :pdf
        f = query(kb, "SELECT path FROM files WHERE paper_id = ?", (p.id,))
        (isempty(f) || !isfile(first(f).path)) && error("$doc_id has no PDF for $(s.name) to read")
        symlink(first(f).path, joinpath(dir, "paper.pdf"))
    end
    progress("$(s.model) agent reading the paper")
    with_agent(s, dir; system = prompts.agent_system(kb.config)) do id
        agent_turn(id, "Read BRIEF.md and follow it for the paper in task.md."; timeout = s.timeout)
    end
    out = joinpath(dir, "summaries.json")
    isfile(out) || error("The $(s.name) agent wrote no summaries.json")
    d = reply_json(read(out, String), "The $(s.name) agent")
    written = Dict{Int,String}(parse(Int, string(k)) => String(v) for (k, v) in get(d, "sections", Dict()))
    missed = setdiff((t.ord for t in sections), keys(written))
    isempty(missed) || error("The $(s.name) agent left out sections $(sort!(collect(missed)))")
    return import_summaries!(kb, s, doc_id; sections = written, paper = String(d["paper"]))
end

# ── Long documents ──────────────────────────────────────────────────────────────────────────────
# A book or handbook is more than one agent can read and summarize in a turn: its sections go to agents
# a batch at a time, each summary stored as its batch is done, and the whole is summarized from them.

"How much summarizable text makes a document long (see [`agent_summarize_long!`](@ref))."
const LONG_DOCUMENT_CHARS = 400_000

const LONG_PART_BRIEF = """
    The task file names a long document and lists sections of it to summarize, each with a number (its "ord")
    and its heading path. Their text is in the part file the task names: the sections in order, each opening
    with a line "=== <ord>: <heading path> ===". The whole document's text is in paper.txt; look things up in
    it where a section depends on what came before (notation, acronyms, earlier chapters), without reading it
    all. The text was extracted from a PDF, so equations and symbols may be garbled: work out what they say
    from the context and describe them correctly rather than copying the garbled form.

    Summarize each listed section in 3–7 sentences for a reader deciding whether to read it. Cover every main
    point the section makes, not only the first or the most striking: its purpose or setup, the methods,
    processes or assumptions it describes, its main results or recommendations (with numbers where it gives
    them), and how it connects to the rest of the document. Keep the specifics a reader would search for:
    named methods, processes, devices, codes, quantities and values. Plain prose: no heading, no bullet
    points, no preamble. Say only what the document supports: never expand an acronym or name a method in a
    way it does not, never add results it does not report.

    Write the result to the JSON file the task names, as an object {"<ord>": "<summary>", ...} with exactly one
    entry per listed section. Write the JSON carefully: you have no tool to check it. Then reply with one line
    saying it is written.
    """

const LONG_WHOLE_BRIEF = """
    whole.md names a long document and gives the summary of each of its sections, in order. Summarize the whole
    document in one paragraph of 5–8 sentences: what it addresses, how it is organized, its main content and
    results, and what it is for. Then, on a new line beginning "Topics:", list 5–10 specific technical topics it
    covers, separated by commas. Work from the section summaries; the document's text is in paper.txt if one
    needs checking. Say only what the document supports.

    Write whole.json as an object {"paper": "<summary>\\nTopics: ..."}. Write the JSON carefully: you have no
    tool to check it. Then reply with one line saying it is written.
    """

"""
    agent_summarize_long!(kb, s, id, sections; batch_chars = 120_000, progress) -> Int

Have agent summarizer `s` summarize a long document: its sections whose summaries are missing or out
of date, by agents that each read a batch of them (at most `batch_chars` of text, several batches at
once, each batch's summaries stored as it is done), then the whole document, by one agent working
from the section summaries. A run stopped part way loses only the batches under way. Returns the
number of summaries stored.
"""
function agent_summarize_long!(kb::KB, s::Summarizer, id::AbstractString, sections; batch_chars::Integer = 120_000,
                               progress = msg -> nothing)
    p = paper_row(kb, id)
    key(ord) = "s:$id:$ord"
    sha(text) = summary_input_sha(s, text)
    have = Dict(r.unit_key => r.input_sha for r in query(kb,
        "SELECT unit_key, input_sha FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    todo = [t for t in sections if get(have, key(t.ord), "") != sha(t.text)]
    dir = agents_dir(s.name, id)
    rm(dir; force = true, recursive = true)
    mkpath(dir)
    write(joinpath(dir, "BRIEF-part.md"), LONG_PART_BRIEF)
    write(joinpath(dir, "BRIEF-whole.md"), LONG_WHOLE_BRIEF)
    write(joinpath(dir, "paper.txt"), read_paper(kb, id; max_chars = typemax(Int)))
    title = coalesce(p.title, id)
    batches = Vector{Vector{eltype(todo)}}()
    for t in todo
        (isempty(batches) || sum(length(x.text) for x in last(batches)) + length(t.text) > batch_chars) && push!(batches, [])
        push!(last(batches), t)
    end
    progress("$(s.model) agents reading $(length(todo)) sections of a long document in $(length(batches)) batch(es)")
    done = Threads.Atomic{Int}(0)
    asyncmap(enumerate(batches); ntasks = 4) do (k, batch)
        write(joinpath(dir, "part-$k.txt"), join(("=== $(t.ord): $(t.path) ===\n$(t.text)\n" for t in batch), "\n"))
        write(joinpath(dir, "part-$k.md"), "Document: $title\n\nSection text: part-$k.txt. Write the result to part-$k.json.\n\n" *
            "Sections to summarize (ord: heading path):\n" * join(("- $(t.ord): $(t.path)\n" for t in batch)))
        with_agent(s, dir; system = summary_prompts(id).agent_system(kb.config)) do agent
            agent_turn(agent, "Read BRIEF-part.md and follow it for the sections in part-$k.md."; timeout = s.timeout)
        end
        got = agent_json(dir, "part-$k.json", s)
        for t in batch
            text = get(got, string(t.ord), nothing)
            text === nothing && error("The $(s.name) agent left out section $(t.ord), $(t.path)")
            save_summary!(kb, p.id, key(t.ord), s, sha(t.text), strip(String(text)), missing, missing)
        end
        progress("[$(Threads.atomic_add!(done, 1) + 1)/$(length(batches))] batches of sections summarized")
    end
    current = Dict(r.unit_key => r.text for r in query(kb,
        "SELECT unit_key, text FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    write(joinpath(dir, "whole.md"), "Document: $title\n\nIts sections and their summaries, in order:\n\n" *
        join(("$(t.path): $(get(current, key(t.ord), "(no summary)"))\n\n" for t in sections)))
    progress("$(s.model) agent summarizing the whole document")
    with_agent(s, dir; system = summary_prompts(id).agent_system(kb.config)) do agent
        agent_turn(agent, "Read BRIEF-whole.md and follow it for the document in whole.md."; timeout = s.timeout)
    end
    got = agent_json(dir, "whole.json", s)
    save_summary!(kb, p.id, "p:$id", s, sha(paper_input(sections)), strip(String(got["paper"])), missing, missing)
    return length(todo) + 1
end

"""
    ask(s, system, prompt; preamble = "", pdfs = String[]) -> String

One question to summarizer `s` of either kind, returning its answer: a chat completion for an API
summarizer; for an agent, one turn of a fresh agent, which finds the preamble in `preamble.txt` and
the PDFs in its working directory.
"""
function ask(s::Summarizer, system::AbstractString, prompt::AbstractString;
             preamble::AbstractString = "", pdfs::AbstractVector{<:AbstractString} = String[])
    s.kind == :api && return first(complete(s, system, prompt; preamble, pdfs))
    dir = mkpath(agents_dir(s.name, "ask-" * string(rand(UInt32); base = 16)))
    try
        notes = String[]
        if !isempty(preamble)
            write(joinpath(dir, "preamble.txt"), preamble)
            push!(notes, "preamble.txt holds material for this question: read it first.")
        end
        for f in pdfs
            symlink(abspath(f), joinpath(dir, basename(f)))
            push!(notes, "$(basename(f)) is attached; read it with the Read tool.")
        end
        text = isempty(notes) ? prompt : join(notes, "\n") * "\n\n" * prompt
        return with_agent(s, dir; system) do id
            agent_turn(id, text; timeout = s.timeout)
        end
    finally
        rm(dir; force = true, recursive = true)
    end
end

# ── Codebases ───────────────────────────────────────────────────────────────────────────────────

const CODE_AGENT_SYSTEM = "You write summaries of a codebase's files and directories for developers finding their " *
                          "way around it. Use only the Read and Write tools; the codebase is read-only."

const CODE_FILES_BRIEF = """
    The codebase is in repo/ (read-only). The task file lists files to summarize, each with a number (its "ord")
    and its path under repo/.

    Read each listed file in full, and summarize it in Markdown for a developer finding their way around the
    codebase. Open other files in repo/ where that helps.

    - A source, configuration or documentation file: one sentence on what the file is for and how it connects to
      the rest of the code. Then its main pieces as a short list, one line each: a type, function or section, its
      name in backticks, and what it does. A short file with one or two pieces gets a sentence more instead of a
      list.
    - A Kaimon Slate notebook (it imports KaimonSlate on its first line and is divided into `#%%` cells): one
      sentence on what it studies. Then "Computes:" and a short list of what it computes. Then "Found:" and a
      short list of what its results show, from its text and its outputs. Leave out "Found:" where it shows no
      results yet.

    No heading and no preamble, at most six items in a list, names in backticks.

    Write the result to the JSON file the task names, as an object {"<ord>": "<summary>", ...} with exactly one
    entry per listed file, line breaks in a summary written as \\n. Write the JSON carefully: you have no tool to
    check it. Then reply with one line saying it is written.
    """

const CODE_TREE_BRIEF = """
    The codebase is in repo/ (read-only). tree.md lists every summarized file with its summary, then the directories
    to summarize, each with a number (its "ord").

    1. Summarize each listed directory in 2–5 sentences for a developer finding their way around: what it is for,
       how its contents divide the work, and which files or subdirectories matter most. Work from the summaries of
       what it contains, and open files in repo/ where that helps.
    2. Summarize the whole codebase in one paragraph of 5–8 sentences: what it is for, how it is organized, its main
       components and how data flows between them, and how it is used. Then, on a new line beginning "Topics:", list
       5–10 specific technical topics it covers, separated by commas.

    Plain prose: no heading, no bullet points, no preamble. Write tree.json as an object {"dirs": {"<ord>":
    "<summary>", ...}, "codebase": "<summary>\\nTopics: ..."} with exactly one entry per listed directory. Write the
    JSON carefully: you have no tool to check it. Then reply with one line saying it is written.
    """

"Read a JSON file an agent wrote, or fail naming the agent's summarizer."
function agent_json(dir::AbstractString, file::AbstractString, s::Summarizer)
    path = joinpath(dir, file)
    isfile(path) || error("The $(s.name) agent wrote no $file")
    return reply_json(read(path, String), "The $(s.name) agent")
end

"""
    agent_summarize_code!(kb, s, id; batch_chars = 150_000, progress) -> Int

Have agent summarizer `s` summarize a codebase: its files, by agents that each read a batch of them
(at most `batch_chars` of source, several batches at once), then its directories and the whole
codebase, by one agent working from the file summaries. Only what changed is redone: a file whose
text changed, a directory with a changed file under it, and the codebase summary when any file
changed. Returns the number of summaries stored.
"""
function agent_summarize_code!(kb::KB, s::Summarizer, id::AbstractString; batch_chars::Integer = 150_000,
                               progress = msg -> nothing)
    p = paper_row(kb, id)
    root = codebase_dir(kb, id)
    isdir(root) || error("Codebase $id can't be read here: $(codebase_problem(kb, id))")
    files = section_texts(kb, id)
    dirs = [r for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ? ORDER BY title", (p.id,))
            if is_dir_section(r.title)]
    under(d) = [f for f in files if startswith(f.path, d.title)]
    dirs = filter(d -> !isempty(under(d)), dirs)
    key(ord) = "s:$id:$ord"
    sha(text) = summary_input_sha(s, text)
    dir_sha(d) = sha(paper_input(under(d)))
    have = Dict(r.unit_key => r.input_sha for r in query(kb,
        "SELECT unit_key, input_sha FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    changed_files = [f for f in files if get(have, key(f.ord), "") != sha(f.text)]
    # A file renamed or moved with its text unchanged takes the summary it had (see reuse_summary!).
    earlier = earlier_summaries(kb, p.id, s)
    filter!(f -> !reuse_summary!(kb, p.id, key(f.ord), s, sha(f.text), earlier), changed_files)
    changed_dirs = [d for d in dirs if get(have, key(d.ord), "") != dir_sha(d)]
    whole = sha(paper_input(files))
    n = 0
    if !(isempty(changed_files) && isempty(changed_dirs) && get(have, "p:$id", "") == whole)
        dir = agents_dir(s.name, id)
        rm(dir; force = true, recursive = true)
        mkpath(dir)
        symlink(root, joinpath(dir, "repo"))
        write(joinpath(dir, "BRIEF-files.md"), CODE_FILES_BRIEF)
        write(joinpath(dir, "BRIEF-tree.md"), CODE_TREE_BRIEF)
        # Files, in batches of at most `batch_chars` of source.
        batches = Vector{Vector{eltype(changed_files)}}()
        for f in changed_files
            (isempty(batches) || sum(length(g.text) for g in last(batches)) + length(f.text) > batch_chars) && push!(batches, [])
            push!(last(batches), f)
        end
        progress("$(s.model) agents reading $(length(changed_files)) files in $(length(batches)) batch(es)")
        # A batch read by an agent: the summaries it wrote are kept, and the files it left out returned.
        function read_batch(name, batch)
            write(joinpath(dir, "$name.md"), "Write the result to $name.json.\n\nFiles to summarize (ord: path under repo/):\n" *
                join(("- $(f.ord): $(f.path)\n" for f in batch)))
            with_agent(s, dir; system = CODE_AGENT_SYSTEM) do agent
                agent_turn(agent, "Read BRIEF-files.md and follow it for the files in $name.md."; timeout = s.timeout)
            end
            got = agent_json(dir, "$name.json", s)
            for f in batch
                text = get(got, string(f.ord), nothing)
                text === nothing || save_summary!(kb, p.id, key(f.ord), s, sha(f.text), strip(String(text)), missing, missing)
            end
            return [f for f in batch if !haskey(got, string(f.ord))]
        end
        asyncmap(enumerate(batches); ntasks = 4) do (k, batch)
            left = read_batch("files-$k", batch)
            # An agent reading many files may pass over one: those it left out are asked for once more.
            isempty(left) || (left = read_batch("files-$k-again", left))
            isempty(left) || error("The $(s.name) agent left out $(join((f.path for f in left), ", "))")
        end
        n += length(changed_files)
        # Directories and the codebase, from the file summaries.
        current = Dict(r.unit_key => r.text for r in query(kb,
            "SELECT unit_key, text FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
        write(joinpath(dir, "tree.md"), "Codebase: $(coalesce(p.title, id))\n\nFiles and their summaries:\n\n" *
            join(("$(f.path): $(get(current, key(f.ord), "(no summary)"))\n\n" for f in files)) *
            "Directories to summarize (ord: path under repo/):\n" * join(("- $(d.ord): $(d.title)\n" for d in changed_dirs)))
        progress("$(s.model) agent summarizing $(length(changed_dirs)) directories and the codebase")
        with_agent(s, dir; system = CODE_AGENT_SYSTEM) do agent
            agent_turn(agent, "Read BRIEF-tree.md and follow it for the codebase in tree.md."; timeout = s.timeout)
        end
        got = agent_json(dir, "tree.json", s)
        written = get(got, "dirs", Dict())
        for d in changed_dirs
            text = get(written, string(d.ord), nothing)
            text === nothing && error("The $(s.name) agent left out directory $(d.title)")
            save_summary!(kb, p.id, key(d.ord), s, dir_sha(d), strip(String(text)), missing, missing)
        end
        save_summary!(kb, p.id, "p:$id", s, whole, strip(String(got["codebase"])), missing, missing)
        n += length(changed_dirs) + 1
    end
    # Summaries of files and directories that are gone, or too short to summarize now, go too.
    keep = Set(["p:$id"; [key(f.ord) for f in files]; [key(d.ord) for d in dirs]])
    for k in keys(have)
        k in keep || execute!(kb, "DELETE FROM summaries WHERE summarizer = ? AND unit_key = ?", (s.name, k))
    end
    return n
end
