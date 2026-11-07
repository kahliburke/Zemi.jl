# Codebases as documents. A codebase is read from a directory: each file is a section, cut into
# pieces at its top-level definitions (Julia), headings (Markdown) or runs of lines (other text),
# and passages are consecutive pieces of one file. From there it goes through the same pipeline as a
# paper: summaries of each file and of the project, embeddings in every layer, search, the site.

"The id of a codebase: `code-` and its name in lower case."
code_id(name::AbstractString) = CODEBASE.prefix * lowercase(replace(name, r"\.jl$" => "", r"[^A-Za-z0-9]+" => "-"))

"""
    free_code_id(kb, name, other; same) -> String

The id of a codebase named `name`: [`code_id`](@ref)'s, unless a codebase recorded under it is not
this one (`same(row)` false for its row of `papers`), when `other` (its owner, or its folder's) names
it too, then a number.
"""
function free_code_id(kb::KB, name::AbstractString, other::AbstractString; same)
    for (i, candidate) in enumerate(Iterators.flatten(([code_id(name), code_id("$other-$name")],
                                                        (code_id("$other-$name-$n") for n in 2:99))))
        rows = query(kb, "SELECT source_path, remote FROM papers WHERE doc_id = ?", (candidate,))
        (isempty(rows) || same(first(rows))) && return candidate
    end
    error("No free id for the codebase $name")
end

const CODE_EXTENSIONS = Set([".jl", ".md", ".toml", ".js", ".ts", ".vue", ".py", ".sh", ".yaml", ".yml", ".css"])
const CODE_SKIP = r"(^|/)(Manifest(-v[\d.]+)?\.toml|node_modules/|build/|generated/|data/|baseset/|\.vitepress/cache/)"
const CODE_MAX_BYTES = 200_000

"""
    code_files(root) -> Vector{String}

The files of a codebase worth reading, relative to `root`: those git tracks (so `.gitignore` is
respected) or, outside a repository, every file under it; limited to source, documentation,
configuration and scripts, and skipping manifests, data and build output.
"""
function code_files(root::AbstractString)
    files = isdir(joinpath(root, ".git")) ?
        split(read(`git -C $root ls-files -z`, String), '\0'; keepempty = false) :
        [relpath(joinpath(d, f), root) for (d, _, fs) in walkdir(root) for f in fs]
    keep(f) = !occursin(CODE_SKIP, f) && readable_file(root, f) && filesize(joinpath(root, f)) <= CODE_MAX_BYTES &&
              (lowercase(splitext(f)[2]) in CODE_EXTENSIONS || script(joinpath(root, f)))
    return sort!(filter(keep, files))
end

"""
Whether `f`, under `root`, is a file of the codebase to read: there (git may track one deleted from
the folder), and not a link, which could lead out of the repository to anything on this machine.
"""
function readable_file(root::AbstractString, f::AbstractString)
    path = joinpath(root, f)
    islink(path) && return false
    isfile(path) || return false
    real, top = realpath(path), realpath(root)
    return startswith(real, top * "/")
end

script(path) = isfile(path) && isempty(splitext(path)[2]) && startswith(String(read(path, 2)), "#!")

function git_rev(root::AbstractString)
    isdir(joinpath(root, ".git")) || return ""
    try
        rev = readchomp(`git -C $root rev-parse --short HEAD`)
        dirty = !isempty(readchomp(`git -C $root status --porcelain --untracked-files=no`))
        return dirty ? rev * "+" : rev
    catch
        return ""
    end
end

"""
    code_pieces(path, text) -> Vector{UnitRange{Int}}

Line ranges to cut a file into: for Julia, one per top-level definition (with its docstring and the
comments just above it, looking inside modules); for Markdown, one per heading; otherwise runs of
about 60 lines. Julia that does not parse is cut into runs of lines too.
"""
function code_pieces(path::AbstractString, text::AbstractString)
    lines = split(text, '\n')
    n = length(lines)
    ext = lowercase(splitext(path)[2])
    starts = if ext == ".jl"
        julia_starts(text)
    elseif ext == ".md"
        [i for (i, l) in enumerate(lines) if startswith(l, "#")]
    else
        Int[]
    end
    starts = isempty(starts) ? collect(1:60:max(n, 1)) : sort!(unique([1; starts]))
    # Comments and blank lines just above a definition belong to it.
    starts = map(starts) do s
        while s > 1 && (isempty(strip(lines[s-1])) || startswith(lstrip(lines[s-1]), "#")) && ext == ".jl"
            s -= 1
        end
        s
    end
    starts = sort!(unique(starts))
    ranges = [starts[i]:(i < length(starts) ? starts[i+1] - 1 : n) for i in eachindex(starts)]
    return filter(r -> any(l -> !isempty(strip(l)), lines[r]), ranges)
end

function julia_starts(text::AbstractString)
    ex = try
        Meta.parseall(text)
    catch
        return Int[]
    end
    starts = Int[]
    function visit(block)
        line = 0
        for x in block.args
            if x isa LineNumberNode
                line = x.line
            elseif x isa Expr && x.head === :module
                push!(starts, line)
                visit(x.args[3])
            elseif x isa Expr && x.head === :error
                return
            else
                push!(starts, line)
            end
        end
    end
    visit(ex)
    return filter(>(0), starts)
end

"""
    parse_codebase(root; numbers = Dict(), used = 0) -> (parsed, abstract, tree_sha)

Read a codebase into the same structure a parsed paper has. Each file is a section (its title the
path relative to `root`) with a `:code` piece (or `:paragraph` for Markdown) per definition or
heading; each directory holding files is a section too, titled with a trailing `/`, with the
nesting depth as its level. `numbers` are the section numbers of the last read, by path: a file or
directory keeps its number from one read to the next, a new one takes the next number above both
those and `used` (the highest any earlier read gave), and one gone leaves its number unused. Summaries and vectors are kept by these numbers (see
[`chunk_code`](@ref)), so only what changed is redone. `abstract` is the README's opening
paragraph; `tree_sha` changes whenever any file read does.
"""
function parse_codebase(root::AbstractString; numbers::AbstractDict = Dict{String,Int}(), used::Integer = 0)
    pieces = Piece[]
    sections = Section[]
    texts = code_texts(root)
    next = Ref(max(maximum(values(numbers); init = 0), used))
    number(path) = haskey(numbers, path) ? Int(numbers[path]) : (next[] += 1)
    for (f, text) in texts
        lines = split(text, '\n')
        ord = number(f)
        push!(sections, Section(ord, length(splitpath(f)), "", f, f, 1, length(lines)))
        kind = lowercase(splitext(f)[2]) == ".md" ? :paragraph : :code
        for r in code_pieces(f, text)
            push!(pieces, Piece(kind, 1, (Float64(first(r)), 0.0, Float64(last(r)), 0.0),
                                rstrip(join(lines[r], '\n')), ord, 0, ""))
        end
    end
    dirs = sort!(unique(d for s in sections for d in parent_dirs(s.title)))
    for d in dirs
        push!(sections, Section(number(d), length(splitpath(d)), "", d, d, 1, 1))
    end
    readme = something(findfirst(s -> lowercase(s.title) == "readme.md", sections), 0)
    abstract = readme == 0 ? "" : first_paragraph([p.text for p in pieces if p.section == sections[readme].ord])
    return ParsedPaper(1, pieces, sections), abstract, tree_sha(texts)
end

"The files of a codebase that are read (those that are text), each path paired with its contents."
code_texts(root::AbstractString) =
    [f => text for f in code_files(root) for text in (read(joinpath(root, f), String),) if isvalid(text)]

"""
    tree_sha(root) -> String

A hash of a codebase's files and their contents, as last read: it changes whenever any file read does.
"""
tree_sha(root::AbstractString) = tree_sha(code_texts(root))
tree_sha(texts::AbstractVector{<:Pair}) = bytes2hex(sha256(join((f * ":" * bytes2hex(sha256(t)) for (f, t) in texts), '\n')))

"The directories a relative path sits in, outermost first, each with a trailing `/`."
function parent_dirs(path::AbstractString)
    parts = splitpath(rstrip(path, '/'))
    return [join(parts[1:i], '/') * "/" for i in 1:length(parts)-1]
end

"The directory a path sits in (`\"\"` at the top), with a trailing `/`."
parent_dir(path::AbstractString) = (d = parent_dirs(path); isempty(d) ? "" : last(d))

is_dir_section(title::AbstractString) = endswith(title, "/")

function first_paragraph(texts)
    for t in texts, para in split(t, r"\n\s*\n")
        p = strip(para)
        (isempty(p) || startswith(p, "#") || startswith(p, "```")) && continue
        return String(p)
    end
    return ""
end

"""
The highest section number codebase `pid` has had: in its sections, and in the summaries and vectors
still kept under a gone file's number, so a new file never takes it and shows what was the old one's.
"""
function numbers_used(kb::KB, pid::Integer)
    keys = [String(r.k) for r in query(kb, """SELECT unit_key AS k FROM summaries WHERE paper_id = ? AND unit_key LIKE 's:%'
                                             UNION SELECT unit_key FROM embeddings WHERE paper_id = ? AND unit_key LIKE 's:%'""", (pid, pid))]
    from_keys = maximum((something(tryparse(Int, last(split(k, ':'))), 0) for k in keys); init = 0)
    return max(from_keys, Int(coalesce(scalar(kb, "SELECT max(ord) FROM sections WHERE paper_id = ?", (pid,)), 0)))
end

"""
The order a document's sections are shown in, for SQL over `sections`: a paper's in its own order,
a codebase's (a tree of files, see `DocumentKind`) by path (its numbers are kept from read to read,
not ordered; see `parse_codebase`). A function, so a kind added later is ordered by its entry too.
"""
section_order() = "CASE WHEN (SELECT $(kind_in(k -> k.tree)) FROM papers WHERE papers.id = sections.paper_id) THEN sections.title END, sections.ord"

"How many passages a file's numbers leave room for: its passage `k` is numbered `file × CHUNK_STRIDE + k`."
const CHUNK_STRIDE = 10_000

"""
    chunk_code(parsed) -> Vector{Chunk}

Passages from a parsed codebase: consecutive pieces of one file up to `CHUNK_TARGET` characters,
and a piece longer than `CHUNK_MAX` cut into runs of whole lines. A passage is numbered within its
file (see `CHUNK_STRIDE`), so changing one file leaves the others' passages, and their vectors, as
they are.
"""
function chunk_code(p::ParsedPaper)
    chunks = Chunk[]
    for s in p.sections
        is_dir_section(s.title) && continue
        k = Ref(0)
        add!(section, text) = (k[] < CHUNK_STRIDE || error("$(s.title) makes more than $CHUNK_STRIDE passages");
                               push!(chunks, Chunk(section * CHUNK_STRIDE + k[], section, 1, 1, text)); k[] += 1)
        buf = String[]
        for piece in (x for x in p.pieces if x.section == s.ord)
            for text in split_lines(piece.text)
                if !isempty(buf) && sum(length, buf) + length(text) > CHUNK_TARGET
                    add!(s.ord, join(buf, "\n\n")); empty!(buf)
                end
                push!(buf, text)
            end
        end
        isempty(buf) || add!(s.ord, join(buf, "\n\n"))
    end
    return chunks
end

function split_lines(text::AbstractString)
    length(text) <= CHUNK_MAX && return [String(text)]
    out, cur = String[], IOBuffer()
    for l in split(text, '\n')
        if position(cur) > 0 && position(cur) + length(l) > CHUNK_TARGET
            push!(out, String(take!(cur)))
        end
        println(cur, l)
    end
    position(cur) > 0 && push!(out, rstrip(String(take!(cur))))
    return out
end

"""
    add_codebase!(kb, root; name = basename(root), by = nothing, anyway = false) -> String

Record a codebase to be read from the directory `root`, and the repository it is a clone of, returning its id (`code-…`). Ingesting it
([`ingest!`](@ref)) reads the files, summarizes each file and the project, and embeds them; doing
so again after the code changes redoes only what changed. One a person dropped is refused with a
[`DroppedError`](@ref), unless `anyway`, which restores it (`by` the person adding it).
"""
function add_codebase!(kb::KB, root::AbstractString; name::AbstractString = basename(rstrip(abspath(root), '/')), by = nothing,
                       anyway::Bool = false)
    root = abspath(expanduser(root))
    isdir(root) || error("No directory $root")
    # Another folder of the same name is another codebase.
    id = free_code_id(kb, name, basename(dirname(root)); same = r -> coalesce(r.source_path, root) == root)
    ismissing(paper_id(kb, id)) && keep_out!(kb, anyway; by, id)
    execute!(kb, """
        INSERT INTO papers (doc_id, version, title, authors, published, primary_category, categories, kind,
                            source_path, remote, metadata_at, added_at)
        VALUES (?, ?, ?, '[]', ?, 'code', '[]', 'code', ?, ?, ?, ?)
        ON CONFLICT (doc_id) DO UPDATE SET source_path = excluded.source_path, remote = coalesce(excluded.remote, remote)""",
        (id, git_rev(root), name, Dates.format(today(), "yyyy-mm-dd"), root, origin_url(root), now_iso(), now_iso()))
    return id
end

"""
    parse_code!(kb, id; force = false) -> Bool

Read a recorded codebase from its directory (see [`codebase_dir`](@ref)), replacing its sections, pieces and passages. Skipped
(returning false) when no file read has changed since the last time.
"""
function parse_code!(kb::KB, id::AbstractString; force::Bool = false)
    p = paper_row(kb, id)
    root = codebase_dir(kb, id)
    isdir(root) || error("Codebase $id can't be read here: $(codebase_problem(kb, id))")
    # Each file and directory keeps the number it had, so what it is kept by stays its own.
    numbers = Dict(String(r.title) => Int(r.ord) for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ?", (p.id,)))
    parsed, abstract, sha = parse_codebase(root; numbers, used = numbers_used(kb, p.id))
    prev = query(kb, "SELECT file_sha, parser_version FROM parses WHERE paper_id = ?", (p.id,))
    unchanged = !isempty(prev) && first(prev).file_sha == sha && first(prev).parser_version == PARSER_VERSION
    execute!(kb, "UPDATE papers SET version = ?, abstract = ? WHERE id = ?", (git_rev(root), abstract, p.id))
    (unchanged && !force) && return false
    store_parse!(kb, id, parsed; file_sha = sha, chunks = chunk_code(parsed))
    return true
end

"How a codebase is read as its kind's entry says (see [`DocumentKind`](@ref)): from its files."
read_codebase!(kb::KB, id::AbstractString; force::Bool = false, step = msg -> nothing) =
    (step("reading the code"); parse_code!(kb, id; force))

# ── Browsing a codebase ──────────────────────────────────────────────────────────────────────────

"A file's page name: its path with everything but letters and digits replaced (`src/search.jl` → `src_search_jl`)."
file_slug(path::AbstractString) = replace(rstrip(path, '/'), r"[^A-Za-z0-9]+" => "_")

"""
    code_tree(kb, id) -> Dict

A codebase as a tree for browsing: directories (`"kind" => "dir"`) holding directories and files
(`"file"`), each with its path, its summary, and for files the number of lines and definitions
and the name of its page. Directories come before files, each in name order.
"""
function code_tree(kb::KB, id::AbstractString)
    pid = paper_id(kb, id)
    secs = query(kb, "SELECT ord, title, page_end AS lines FROM sections WHERE paper_id = ? ORDER BY title", (pid,))
    sums = Dict(r.unit_key => r.text for r in query(kb, "SELECT unit_key, text FROM summaries WHERE paper_id = ? AND summarizer = ?",
                                                     (pid, something(shown_summarizer(kb, id), ""))))
    defs = Dict(r.section => r.n for r in query(kb,
        "SELECT section, count(*) AS n FROM blocks WHERE paper_id = ? AND kind = 'code' GROUP BY section", (pid,)))
    root = Dict{String,Any}("name" => "", "path" => "", "kind" => "dir", "summary" => nothing, "children" => Any[])
    nodes = Dict{String,Any}("" => root)
    for x in secs
        dir = is_dir_section(x.title)
        nodes[x.title] = Dict{String,Any}("name" => basename(rstrip(x.title, '/')) * (dir ? "/" : ""), "path" => x.title,
            "kind" => dir ? "dir" : "file", "summary" => get(sums, "s:$id:$(x.ord)", nothing),
            "lines" => dir ? nothing : x.lines, "definitions" => dir ? nothing : get(defs, x.ord, 0),
            "page" => dir ? nothing : file_slug(x.title), "children" => Any[])
    end
    for x in secs
        push!(get(nodes, parent_dir(x.title), root)["children"], nodes[x.title])
    end
    for n in values(nodes)
        sort!(n["children"]; by = c -> (c["kind"] == "file", lowercase(c["name"])))
    end
    return root
end

"""
    code_stats(kb, id) -> NamedTuple

Files, lines and definitions in a codebase, and how many files of each language.
"""
function code_stats(kb::KB, id::AbstractString)
    pid = paper_id(kb, id)
    files = [r for r in query(kb, "SELECT title, page_end AS lines FROM sections WHERE paper_id = ?", (pid,)) if !is_dir_section(r.title)]
    languages = Dict{String,Int}()
    for f in files
        l = language(f.title)
        languages[l] = get(languages, l, 0) + 1
    end
    definitions = scalar(kb, "SELECT count(*) FROM blocks WHERE paper_id = ? AND kind = 'code'", (pid,))
    return (; files = length(files), lines = sum(f -> f.lines, files; init = 0), definitions,
              languages = sort!(collect(languages); by = x -> -x.second))
end

const LANGUAGES = Dict(".jl" => "Julia", ".md" => "Markdown", ".toml" => "TOML", ".js" => "JavaScript",
                       ".ts" => "TypeScript", ".vue" => "Vue", ".py" => "Python", ".sh" => "Shell",
                       ".yaml" => "YAML", ".yml" => "YAML", ".css" => "CSS")
language(path) = get(LANGUAGES, lowercase(splitext(path)[2]), isempty(splitext(path)[2]) ? "Shell" : "Other")

"""
    Definition

One piece of a file as a reader browses it: its `name` (a function, type, constant or heading;
the lines it spans otherwise), the `signature` line, the first paragraph of its docstring, its line
range and its source.
"""
struct Definition
    name::String
    signature::String
    doc::String
    first_line::Int
    last_line::Int
    source::String
end

"""
    file_definitions(kb, id, path) -> Vector{Definition}
"""
function file_definitions(kb::KB, id::AbstractString, path::AbstractString)
    pid = paper_id(kb, id)
    ord = scalar(kb, "SELECT ord FROM sections WHERE paper_id = ? AND title = ?", (pid, path))
    ismissing(ord) && return Definition[]
    blocks = query(kb, "SELECT text, x0, x1 FROM blocks WHERE paper_id = ? AND section = ? ORDER BY ord", (pid, ord))
    return [definition(path, b.text, round(Int, b.x0), round(Int, b.x1)) for b in blocks]
end

const DEF_NAME = [r"^(?:export\s+|public\s+)?(?:function|macro)\s+([^\s(]+)", r"^(?:mutable\s+|abstract\s+)?(?:Base\.@kwdef\s+|@kwdef\s+)?struct\s+(\w+)",
                  r"^(?:abstract|primitive)\s+type\s+(\w+)", r"^const\s+(\w+)", r"^module\s+(\w+)",
                  r"^(?:export\s+)?(?:async\s+)?function\s+(\w+)", r"^(?:export\s+)?(?:const|let)\s+(\w+)",
                  r"^([\w.!]+(?:\{[^}]*\})?)\([^=]*\)\s*(?:::\s*\S+\s*)?=(?!=)", r"^#+\s+(.+)$", r"^\[([\w.]+)\]"]

function definition(path, text, first_line, last_line)
    lines = split(text, '\n')
    i = 1
    doc = IOBuffer()
    # Leading comments and a docstring describe the definition; the first other line is its signature.
    while i <= length(lines) && (isempty(strip(lines[i])) || startswith(lstrip(lines[i]), "#") && !endswith(lowercase(path), ".md"))
        startswith(lstrip(lines[i]), "#") && println(doc, lstrip(lstrip(lines[i]), ['#', ' ']))
        i += 1
    end
    if i <= length(lines) && (m = match(r"^\s*\"((?:[^\"\\\\]|\\\\.)*)\"\s*$", lines[i])) !== nothing
        # A one-line docstring.
        print(doc, m[1])
        i += 1
    elseif i <= length(lines) && startswith(lstrip(lines[i]), "\"\"\"")
        j = findnext(l -> endswith(rstrip(l), "\"\"\""), lines, lstrip(lines[i]) == "\"\"\"" ? i + 1 : i)
        j === nothing && (j = i)
        # Only blank lines are trimmed: the indentation of a signature line is what marks it.
        body = strip(==('\n'), replace(join(lines[i:j], '\n'), "\"\"\"" => ""))
        paras = split(body, r"\n\s*\n")
        # A docstring opening with an indented signature: its first prose paragraph is the description.
        desc = [p for p in paras if !startswith(p, "    ") && !isempty(strip(p))]
        print(doc, isempty(desc) ? "" : first(desc))
        i = j + 1
    end
    signature = i <= length(lines) ? String(strip(lines[i])) : ""
    name = ""
    for re in DEF_NAME
        m = match(re, signature)
        m === nothing || (name = String(m[1]); break)
    end
    isempty(name) && (name = "lines $(first_line)–$(last_line)")
    return Definition(name, signature, strip(String(take!(doc))), first_line, last_line, String(text))
end
