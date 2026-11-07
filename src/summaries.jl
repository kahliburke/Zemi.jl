# LLM-written summaries of sections and papers. A section summary is written from the section's
# parsed text; the paper summary from the title, abstract and the section summaries, so it covers
# the whole paper without sending the whole paper. Summaries are stored with a hash of their input
# and the prompt version, so they are rewritten only when the text or the prompt changes.

"""Bump when the prompts change, so existing summaries are rewritten."""
const SUMMARY_PROMPT_VERSION = 1

"""Bump when the agent summarizers' brief (see `agent_brief`) changes, so their summaries are rewritten."""
const AGENT_BRIEF_VERSION = 2

"The version of the instructions summarizer `s` writes from: the prompts, or for an agent its brief."
prompt_version(s::Summarizer) = s.kind == :agent ? AGENT_BRIEF_VERSION : SUMMARY_PROMPT_VERSION

"What a whole-paper summary is written from, for its hash: the summarizable sections' text, in order."
paper_input(sections) = join((t.text for t in sections), "\n\n")

"The hash a summary is stored with: its input, and what wrote it from that input."
summary_input_sha(s::Summarizer, text::AbstractString) = text_sha("$(s.model)|$(prompt_version(s))|$text")

"Whether `s` is an agent that reads a paper's PDF rather than the text extracted from it."
reads_pdf(s::Summarizer) = s.kind == :agent && s.reads == :pdf

"""
    summary_inputs(kb, s, doc_id, sections) -> (; paper, sections)

What a paper's summaries by `s` are current against: the text of each section and the paper's (see
[`paper_input`](@ref)), or, for an agent that reads the PDF, the PDF's hash with the section list, so
reading the same PDF better leaves its summaries current. A document long enough to be summarized a
batch at a time is read from its text (see [`agent_summarize_long!`](@ref)), and judged by it.
`sections` maps each section's `ord` to its input.
"""
function summary_inputs(kb::KB, s::Summarizer, doc_id::AbstractString, sections)
    if reads_pdf(s) && is_kind(k -> k.pdf, doc_id) && length(paper_input(sections)) <= LONG_DOCUMENT_CHARS
        pdf = "pdf:" * coalesce(scalar(kb, "SELECT file_sha FROM parses WHERE paper_id = ?", (paper_id(kb, doc_id),)), "")
        heading(t) = "$(t.ord): $(t.path)"
        return (; paper = pdf * "\n" * join(heading.(sections), "\n"), sections = Dict(t.ord => pdf * "\n" * heading(t) for t in sections))
    end
    return (; paper = paper_input(sections), sections = Dict(t.ord => t.text for t in sections))
end

"""
    rekey_pdf_summaries!(kb) -> Int

Once per knowledge base: the summaries by agents that read the PDF, current against the text they were
judged by before, are judged by the PDF and its section list from then on (see [`summary_inputs`](@ref)).
Run before a new reading of the papers changes their text. Returns the papers rekeyed.
"""
function rekey_pdf_summaries!(kb::KB)
    ismissing(scalar(kb, "SELECT value FROM kv WHERE key = 'pdf_summary_keys'")) || return 0
    n = 0
    for s in kb.config.summarizers
        reads_pdf(s) || continue
        for r in query(kb, "SELECT DISTINCT p.doc_id AS id FROM summaries x JOIN papers p ON p.id = x.paper_id WHERE x.summarizer = ?", (s.name,))
            is_kind(k -> k.pdf, r.id) || continue
            pid = paper_id(kb, r.id)
            sections = section_texts(kb, r.id)
            have = Dict(x.unit_key => x.input_sha for x in query(kb,
                "SELECT unit_key, input_sha FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, pid)))
            old(text) = summary_input_sha(s, text)
            get(have, "p:$(r.id)", "") == old(paper_input(sections)) &&
                all(t -> get(have, "s:$(r.id):$(t.ord)", "") == old(t.text), sections) || continue
            inputs = summary_inputs(kb, s, r.id, sections)
            set(key, input) = execute!(kb, "UPDATE summaries SET input_sha = ? WHERE paper_id = ? AND summarizer = ? AND unit_key = ?",
                                       (summary_input_sha(s, input), pid, s.name, key))
            transaction(kb) do
                set("p:$(r.id)", inputs.paper)
                foreach(t -> set("s:$(r.id):$(t.ord)", inputs.sections[t.ord]), sections)
            end
            n += 1
        end
    end
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('pdf_summary_keys', ?)", (now_iso(),))
    return n
end

"What summarizers are told they are doing: summarizing papers for researchers in the group's field."
summary_system(c::Config) = "You write summaries of research papers for a searchable knowledge base used by researchers$(in_field(c))."

const CODE_SUMMARY_SYSTEM = "You write summaries of a codebase's files and directories, for a searchable knowledge base " *
                            "used by developers and researchers finding their way around it."

"The system prompt for summarizing document `id`: its kind's (see [`DocumentKind`](@ref))."
summary_system(c::Config, id::AbstractString) = summary_prompts(id).system(c)

"The prompts that summarize document `id`: its kind's, a paper's for an id of no kind."
summary_prompts(id::AbstractString) = something(document_kind(id), PAPER).prompts

section_prompt(title, path, text) = """
    Paper: $title
    Section: $path

    Summarize this section in 3–6 sentences for a researcher deciding whether to read it. Say concretely \
    what it does: the question or setup, the methods and assumptions, the main results (with numbers \
    where the text gives them), and how it connects to the rest of the paper. Describe key equations in \
    words and keep the paper's notation for named quantities. Write plain prose: no heading, no bullet \
    points, no preamble.

    The text was extracted from a PDF, so equations may be garbled; infer what they say from context \
    rather than reproducing them.

    Section text:
    $text"""

paper_prompt(title, abstract, sections) = """
    Paper: $title

    Abstract: $abstract

    Section summaries:
    $sections

    Summarize the paper in one paragraph of 5–8 sentences: the problem it addresses, its approach, its \
    main results, and what is new about them. Then, on a new line beginning "Topics:", list 5–10 \
    specific technical topics it covers, separated by commas. No heading and no preamble."""

code_section_prompt(title, path, text) = """
    Codebase: $title
    File: $path

    Summarize this file in 3–6 sentences for a developer finding their way around the codebase: what
    the file is for, the main types and functions it defines and what each does, and how it connects
    to the rest of the code. Name the important functions and types. Write plain prose: no heading, no
    bullet points, no preamble.

    File contents:
    $text"""

code_paper_prompt(title, readme, files) = """
    Codebase: $title

    README opening: $readme

    File summaries:
    $files

    Summarize the codebase in one paragraph of 5–8 sentences: what it is for, how it is organized,
    its main components and how data flows between them, and how it is used. Then, on a new line
    beginning "Topics:", list 5–10 specific technical topics it covers, separated by commas. No heading
    and no preamble."""

api_key(s::Summarizer) = resolve_key(s.key, "Summarizer $(s.name)")

"""
    complete(summarizer, system, prompt; preamble = "", pdfs = String[]) -> (text, input_tokens, output_tokens)

One chat completion. `pdfs` are files sent ahead of the prompt as file parts, for APIs that read
PDFs (OpenAI's does); the model then sees the pages as typeset, not as extracted text. `preamble` is
text sent ahead of everything else, for a long part shared by many requests (such as a whole paper)
that a caching API then bills at its cached rate.
"""
function complete(s::Summarizer, system::AbstractString, prompt::AbstractString;
                  preamble::AbstractString = "", pdfs::AbstractVector{<:AbstractString} = String[])
    files = [Dict("type" => "file", "file" => Dict("filename" => basename(f),
                  "file_data" => "data:application/pdf;base64," * base64encode(read(f)))) for f in pdfs]
    part(t) = Dict("type" => "text", "text" => t)
    content = isempty(files) && isempty(preamble) ? prompt :
              [(isempty(preamble) ? [] : [part(preamble)]); files; part(prompt)]
    body = merge(s.request, Dict("model" => s.model,
        "messages" => [Dict("role" => "system", "content" => system), Dict("role" => "user", "content" => content)]))
    data = openai_post(s.url, "/chat/completions", api_key(s), body; what = "Summarizer $(s.name)")
    text = strip(String(data["choices"][1]["message"]["content"]))
    isempty(text) && error("Summarizer $(s.name) returned an empty summary")
    usage = get(data, "usage", Dict())
    return (text, get(usage, "prompt_tokens", missing), get(usage, "completion_tokens", missing))
end

"""
    reply_json(text, who) -> Dict

The JSON object in an LLM's reply, which may come wrapped in prose. Backslashes that are not JSON
escapes (LaTeX such as `\\(p\\)`, which models write inside strings) are kept as backslashes, and
when the reply still does not parse, quotation marks inside a string (`the "last chain" holds`) are
read as text (see [`escape_inner_quotes`](@ref)).
"""
function reply_json(text::AbstractString, who::AbstractString)
    m = match(r"\{.*\}"s, text)
    m === nothing && error("$who did not return JSON: $(first(text, 200))")
    # Escapes are read in pairs, so an escaped backslash is never mistaken for the start of another.
    keep(e) = e[2] in "\"\\/bfnrt" || occursin(r"^\\u[0-9a-fA-F]{4}$", e)
    json = replace(m.match, r"\\(u[0-9a-fA-F]{4}|.)"s => e -> keep(e) ? e : "\\" * e)
    return try
        JSON.parse(json)
    catch e
        e isa ArgumentError || rethrow()
        try JSON.parse(escape_inner_quotes(json)) catch; error("$who returned JSON that does not parse: $(failure_message(e))") end
    end
end

"""
    escape_inner_quotes(json) -> String

`json` with each quotation mark inside a string escaped unless it ends the string: one that ends a
string is followed by `,`, `}`, `]`, `:` or the end, after any spaces.
"""
function escape_inner_quotes(json::AbstractString)
    io, chars = IOBuffer(), collect(json)
    inside, i = false, 1
    while i <= length(chars)
        c = chars[i]
        if inside && c == '\\'                       # an escape: copied with what it escapes
            print(io, c, i < length(chars) ? chars[i+1] : "")
            i += 2
            continue
        end
        if c == '"'
            if !inside
                inside = true
            else
                j = findnext(!isspace, chars, i + 1)
                closes = j === nothing || chars[j] in (',', '}', ']', ':')
                closes ? (inside = false) : (print(io, '\\'))
            end
        end
        print(io, c)
        i += 1
    end
    return String(take!(io))
end

# Parsed block kinds that make up a section's text for summarizing.
const SUMMARIZED_KINDS = ("paragraph", "equation", "caption", "code")

"""
    section_texts(kb, doc_id) -> Vector{NamedTuple}

Each section's own text (not its subsections'), in order, skipping references and sections with
too little text to summarize.
"""
function section_texts(kb::KB, doc_id::AbstractString)
    pid = paper_id(kb, doc_id)
    secs = query(kb, "SELECT ord, path FROM sections WHERE paper_id = ? ORDER BY ord", (pid,))
    blocks = query(kb, "SELECT section, kind, text FROM blocks WHERE paper_id = ? ORDER BY ord", (pid,))
    out = []
    for s in secs
        occursin(REFERENCES, last(split(s.path, " › "))) && continue
        text = join((b.text for b in blocks if b.section == s.ord && b.kind in SUMMARIZED_KINDS), "\n\n")
        length(text) >= 300 && push!(out, (; ord = s.ord, s.path, text))
    end
    return out
end

"""
    summarize_paper!(kb, summarizer, doc_id; progress = msg -> nothing) -> Int

Write the missing or outdated section summaries and the paper summary for one parsed paper,
returning how many were written. Sections are summarized concurrently.
"""
function summarize_paper!(kb::KB, s::Summarizer, doc_id::AbstractString; progress = msg -> nothing)
    s.kind == :agent && return agent_summarize_paper!(kb, s, doc_id; progress)
    p = paper_row(kb, doc_id)
    title = coalesce(p.title, doc_id)
    have = Dict(r.unit_key => r.input_sha for r in query(kb,
        "SELECT unit_key, input_sha FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    input_sha(text) = summary_input_sha(s, text)

    sections = section_texts(kb, doc_id)
    prompts = summary_prompts(doc_id)
    tree = is_kind(k -> k.tree, doc_id)
    todo = [(; key = "s:$doc_id:$(x.ord)", prompt = prompts.section(title, x.path, first(x.text, s.max_input_chars)))
            for x in sections]
    todo = filter(t -> get(have, t.key, "") != input_sha(t.prompt), todo)
    # Read once, before anything below replaces or deletes a summary, so any of them can be reused.
    earlier = earlier_summaries(kb, p.id, s)
    todo = filter(t -> !reuse_summary!(kb, p.id, t.key, s, input_sha(t.prompt), earlier), todo)
    progress("summarizing $(length(todo)) of $(length(sections)) sections")
    system = summary_system(kb.config, doc_id)
    written = asyncmap(todo; ntasks = 6) do t
        text, tin, tout = complete(s, system, t.prompt)
        save_summary!(kb, p.id, t.key, s, input_sha(t.prompt), text, tin, tout)
        1
    end

    n = sum(written; init = 0)
    # A codebase's directories are summarized from what they hold, deepest first.
    dir_keys = String[]
    if tree
        # A file too short to summarize must not leave an older summary for its directory to read.
        file_keys = Set("s:$doc_id:$(x.ord)" for x in sections)
        for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ?", (p.id,))
            k = "s:$doc_id:$(r.ord)"
            is_dir_section(r.title) || k in file_keys ||
                execute!(kb, "DELETE FROM summaries WHERE summarizer = ? AND paper_id = ? AND unit_key = ?", (s.name, p.id, k))
        end
        d = summarize_directories!(kb, s, p, title, have, input_sha, earlier; progress)
        n += d.written
        dir_keys = d.keys
    end

    # The paper summary reads the section summaries, so it is redone whenever any of them changes.
    # A codebase's reads only its top level: the files and directories at its root.
    current = Dict(r.unit_key => r.text for r in query(kb,
        "SELECT unit_key, text FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    parts = if tree
        top = query(kb, "SELECT ord, title FROM sections WHERE paper_id = ? ORDER BY title", (p.id,))
        ["$(x.title): $(current["s:$doc_id:$(x.ord)"])" for x in top
         if parent_dir(x.title) == "" && haskey(current, "s:$doc_id:$(x.ord)")]
    else
        ["$(x.path): $(current["s:$doc_id:$(x.ord)"])" for x in sections if haskey(current, "s:$doc_id:$(x.ord)")]
    end
    prompt = prompts.whole(title, coalesce(p.abstract, ""), join(parts, "\n\n"))
    if get(have, "p:$doc_id", "") != input_sha(prompt)
        progress("summarizing the paper")
        text, tin, tout = complete(s, system, prompt)
        save_summary!(kb, p.id, "p:$doc_id", s, input_sha(prompt), text, tin, tout)
        n += 1
    end
    # Sections that no longer exist (after a re-parse) lose their summaries.
    keep = Set(["p:$doc_id"; ["s:$doc_id:$(x.ord)" for x in sections]; dir_keys])
    for k in keys(have)
        k in keep || execute!(kb, "DELETE FROM summaries WHERE summarizer = ? AND unit_key = ?", (s.name, k))
    end
    return n
end

code_dir_prompt(title, dir, contents) = """
    Codebase: $title
    Directory: $dir

    Summaries of what it contains:
    $contents

    Summarize this directory in 2–5 sentences for a developer finding their way around: what it is
    for, how its contents divide the work, and which files or subdirectories matter most. Write plain
    prose: no heading, no bullet points, no preamble."""

"""
    summarize_directories!(kb, summarizer, p, title, have, input_sha, earlier; progress) -> (; written, keys)

Summarize each directory of a codebase from the summaries of the files and directories directly in
it, deepest directories first so their parents can read them. A directory is summarized again only
when what it holds has changed.
"""
function summarize_directories!(kb::KB, s::Summarizer, p, title, have, input_sha, earlier; progress = msg -> nothing)
    secs = query(kb, "SELECT ord, title, level FROM sections WHERE paper_id = ?", (p.id,))
    dirs = [x for x in secs if is_dir_section(x.title)]
    key(x) = "s:$(p.doc_id):$(x.ord)"
    written = 0
    for level in sort!(unique(x.level for x in dirs); rev = true)
        current = Dict(r.unit_key => r.text for r in query(kb,
            "SELECT unit_key, text FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
        todo = []
        for d in dirs
            d.level == level || continue
            parts = ["$(c.title): $(current[key(c)])" for c in sort(secs; by = c -> c.title)
                     if parent_dir(c.title) == d.title && haskey(current, key(c))]
            if isempty(parts)
                # Nothing summarized in it: no summary either, so its parent does not read an old one.
                execute!(kb, "DELETE FROM summaries WHERE summarizer = ? AND paper_id = ? AND unit_key = ?", (s.name, p.id, key(d)))
                continue
            end
            prompt = code_dir_prompt(title, d.title, first(join(parts, "\n\n"), s.max_input_chars))
            get(have, key(d), "") == input_sha(prompt) || reuse_summary!(kb, p.id, key(d), s, input_sha(prompt), earlier) ||
                push!(todo, (; key = key(d), prompt))
        end
        isempty(todo) && continue
        progress("summarizing $(length(todo)) directories at depth $level")
        written += sum(asyncmap(todo; ntasks = 6) do t
            text, tin, tout = complete(s, CODE_SUMMARY_SYSTEM, t.prompt)
            save_summary!(kb, p.id, t.key, s, input_sha(t.prompt), text, tin, tout)
            1
        end)
    end
    # The directories with something summarized in them; any others lose a summary they had.
    current = Set(r.unit_key for r in query(kb, "SELECT unit_key FROM summaries WHERE summarizer = ? AND paper_id = ?", (s.name, p.id)))
    keys = [key(d) for d in dirs if any(c -> parent_dir(c.title) == d.title && key(c) in current, secs)]
    return (; written, keys)
end

"The summaries a paper has from a summarizer, by the hash of their input, read before any is replaced."
earlier_summaries(kb::KB, pid, s::Summarizer) = Dict(r.input_sha => r.text for r in query(kb,
    "SELECT input_sha, text FROM summaries WHERE paper_id = ? AND summarizer = ?", (pid, s.name)))

"""
    reuse_summary!(kb, paper_id, key, summarizer, sha, earlier) -> Bool

Give `key` a summary the paper already had from the same input, if `earlier` (from
[`earlier_summaries`](@ref), read before any summary is written) holds one: a section renumbered
with its path and text unchanged (a codebase's file after one added or removed before it) costs no
summary. A file renamed or moved is summarized again, as its prompt names its path.
"""
function reuse_summary!(kb::KB, pid, key, s::Summarizer, sha, earlier::AbstractDict)
    haskey(earlier, sha) || return false
    save_summary!(kb, pid, key, s, sha, earlier[sha], missing, missing)   # no tokens spent on a copy
    return true
end

"""
    import_summaries!(kb, s, doc_id; sections, paper) -> Int

Store summaries written outside the pipeline (by an agent, say) as the summarizer `s`'s:
`sections` maps a section's `ord` to its summary, and `paper` is the paper summary with its
"Topics:" line. Sections the pipeline would not summarize are rejected, so imported and generated
summaries cover the same units and can be compared. Returns the number stored.
"""
function import_summaries!(kb::KB, s::Summarizer, doc_id::AbstractString; sections::AbstractDict, paper::AbstractString)
    sections = Dict{Int,String}(Int(k) => String(v) for (k, v) in sections)
    p = paper_row(kb, doc_id)
    listed = section_texts(kb, doc_id)
    texts = Dict(t.ord => t.text for t in listed)
    extra = setdiff(keys(sections), keys(texts))
    isempty(extra) || error("$doc_id has no summarizable sections $(sort!(collect(extra)))")
    input_sha(text) = summary_input_sha(s, text)
    inputs = summary_inputs(kb, s, doc_id, listed)
    transaction(kb) do
        for (ord, text) in sections
            save_summary!(kb, p.id, "s:$doc_id:$ord", s, input_sha(inputs.sections[ord]), strip(text), missing, missing)
        end
        save_summary!(kb, p.id, "p:$doc_id", s, input_sha(inputs.paper), strip(paper), missing, missing)
    end
    return length(sections) + 1
end

save_summary!(kb, pid, key, s, sha, text, tin, tout) =
    execute!(kb, "INSERT OR REPLACE INTO summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (pid, key, s.name, s.model, prompt_version(s), sha, text, tin, tout, now_iso()))

"""
    shown_summarizer(kb, doc_id) -> Union{String,Nothing}

Whose summaries to show for a document, where several summarizers have written them: the one
configured for its kind (`code_summarizer` for a codebase) once it has summarized the document, and
until then the one that summarized it most recently. `nothing` when there are none.
"""
function shown_summarizer(kb::KB, doc_id::AbstractString)
    want = kind_summarizer(kb.config, doc_id)
    have = query(kb, """SELECT summarizer, max(created_at) AS t FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%'
                        GROUP BY summarizer ORDER BY t DESC""", (paper_id(kb, doc_id),))
    isempty(have) && return nothing
    return any(r -> r.summarizer == want, have) ? want : first(have).summarizer
end

"""
    summaries(kb, doc_id; summarizer = nothing) -> Vector{NamedTuple}

A paper's stored summaries, the paper summary first, then sections in order (a codebase's by path).
"""
function summaries(kb::KB, doc_id::AbstractString; summarizer = nothing)
    rows = query(kb, """
        SELECT s.summarizer, s.model, s.unit_key, s.text, s.input_tokens, s.output_tokens, x.path
        FROM summaries s JOIN papers p ON p.id = s.paper_id
        LEFT JOIN sections x ON x.paper_id = s.paper_id AND 's:' || p.doc_id || ':' || x.ord = s.unit_key
        WHERE p.doc_id = ? AND (? IS NULL OR s.summarizer = ?)""",
        (doc_id, something(summarizer, missing), something(summarizer, missing)))
    tree = is_kind(k -> k.tree, doc_id)
    order(r) = startswith(r.unit, "p:") ? (-1, "") : tree ? (0, r.section) : (parse(Int, split(r.unit, ':')[3]), "")
    return sort([(; r.summarizer, r.model, unit = r.unit_key, section = coalesce(r.path, "(paper)"), r.text,
                   r.input_tokens, r.output_tokens) for r in rows]; by = r -> (r.summarizer, order(r)))
end
