# A codebase's pages on the site: its summary and tree of files, and each file with its definitions.
# Each is made from a template (see `TEMPLATED`) and drawn from its data file. Only open codebases are
# built into the site, which every reader is served; the service answers for the others, at the same
# addresses, to those who may see them (see `codebase_site_response`).

const FENCE_LANGUAGES = Dict(".jl" => "julia", ".ts" => "ts", ".vue" => "vue", ".js" => "js", ".toml" => "toml",
    ".md" => "markdown", ".sh" => "bash", ".css" => "css", ".yaml" => "yaml", ".yml" => "yaml", ".py" => "python")
fence_language(path) = get(FENCE_LANGUAGES, lowercase(splitext(path)[2]), isempty(splitext(path)[2]) ? "bash" : "text")

"""
    write_code_site(kb, dir, public; write) -> Vector{NamedTuple}

The pages of every open codebase (see document_access.jl) under `dir`: `index.md` listing them; for
each, the stub of its page, `<slug>/index.md`, and of every file's, `<slug>/files/<file>.md`, with
their data files under `data` (see [`codebase_page_json`](@ref), [`code_file_json`](@ref)). The tree
the browser reads goes to `public/<slug>.json`, and a notebook's cells beside it. Returns
`(; id, title, page)` for each codebase.
"""
function write_code_site(kb::KB, dir::AbstractString, public::AbstractString; write = write_if_changed,
                         data::AbstractString = joinpath(dirname(public), "kb-data"))
    codebases = query(kb, "SELECT * FROM papers WHERE $(kind_in(CODEBASE)) AND access = 'open' ORDER BY title")
    listing = IOBuffer()
    println(listing, "# Codebases\n\nRepositories, each summarized by file, by directory and as a whole.\n")
    out = []
    for p in codebases
        slug = page_slug(p.doc_id)
        page = codebase_page_json(kb, p)
        write(joinpath(dir, slug, "index.md"), template_markdown("codebase"))
        write(joinpath(data, "codebase", slug, "index.json"), JSON.json(page))
        tree = code_tree(kb, p.doc_id)
        write(joinpath(public, "$slug.json"), JSON.json(codebase_tree_json(p, tree)))
        for f in code_files_in(tree)
            file, cells = code_file_data(kb, p, f)
            cells === nothing || write(joinpath(public, slug, "notebooks", f["page"] * ".json"), JSON.json(cells))
            write(joinpath(dir, slug, "files", f["page"] * ".md"), template_markdown("code"))
            write(joinpath(data, "code", slug, f["page"] * ".json"), JSON.json(file))
        end
        println(listing, "- [", md_escape(page["title"]), "](./", slug, "/index.md): ", md_escape(page["one_line"]),
                " *(", page["files"], " files", isempty(page["commit"]) ? "" : ", commit `$(page["commit"])`", ")*")
        push!(out, (; id = p.doc_id, title = page["title"], page = "$slug/index.md"))
    end
    # The codebases of the reader's projects that are not open are listed as the page is read.
    println(listing, "```@raw html\n<KBCodebases", isempty(codebases) ? " none" : "", " />\n```\n")
    println(listing, "## Add a codebase\n")
    any_codebase = !ismissing(scalar(kb, "SELECT 1 FROM papers WHERE $(kind_in(CODEBASE)) LIMIT 1"))
    println(listing, "```@raw html\n<KBUpload codebases", any_codebase ? " manage" : "", " />\n```")
    write(joinpath(dir, "index.md"), String(take!(listing)))
    return out
end

code_files_in(node) = node["kind"] == "file" ? [node] : reduce(vcat, (code_files_in(c) for c in node["children"]); init = Any[])

first_sentence(s::AbstractString) = (m = match(r"^.*?[.!?](?=\s|$)"s, s); m === nothing ? String(s) : String(m.match))

"""
    codebase_page_json(kb, p) -> Dict

The data file of codebase `p`'s page (KBCodebasePage.vue lays it out): its one line, facts, summary
and topics, access, classification, and where its tree and its files' pages are.
"""
function codebase_page_json(kb::KB, p)
    slug = page_slug(p.doc_id)
    stats = code_stats(kb, p.doc_id)
    summary, topics = split_topics(coalesce(scalar(kb,
        "SELECT text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%' AND summarizer = ?",
        (p.id, something(shown_summarizer(kb, p.doc_id), ""))), ""))
    c = classification(kb, p.doc_id)
    one_line = c !== nothing && get(c, "one_line", nothing) !== nothing ? string(c["one_line"]) : first_sentence(summary)
    return Dict{String,Any}(
        "id" => p.doc_id, "slug" => slug, "title" => coalesce(p.title, p.doc_id), "one_line" => one_line,
        "commit" => coalesce(p.version, ""), "files" => stats.files, "lines" => stats.lines, "definitions" => stats.definitions,
        "languages" => [Dict("language" => l, "files" => n) for (l, n) in stats.languages],
        "summary" => summary, "topics" => topics, "access" => p.access,
        "classification" => c === nothing ? [] : [Dict("label" => l, "value" => v) for (l, v) in classification_rows(c)],
        "tree" => "/code/$slug.json", "pages" => "/generated/kb/code/$slug/files/")
end

"The file of codebase `p`'s tree, `tree` (see [`code_tree`](@ref)), as its page browses it (KBCodeTree.vue)."
codebase_tree_json(p, tree) = Dict("id" => p.doc_id, "title" => p.title, "tree" => tree)

"""
    code_file_data(kb, p, f) -> (file, cells)

The data file of the page of file `f` of codebase `p` (see [`code_file_json`](@ref)), and a
notebook's cells (see [`slate_cells`](@ref)), `nothing` for any other file.
"""
function code_file_data(kb::KB, p, f)
    cells = endswith(lowercase(f["path"]), ".jl") ? slate_cells(code_file_text(kb, p.doc_id, f["path"])) : nothing
    notebook = cells === nothing ? nothing : Dict("path" => f["path"], "cells" => [Dict(pairs(c)) for c in cells])
    return code_file_json(kb, p, f; notebook = cells !== nothing), notebook
end

"""
    code_file_json(kb, p, f; notebook = false) -> Dict

The data file of the page for one file `f` of codebase `p` (KBCodeFilePage.vue lays it out): its
place in the tree, summary, and definitions with their source; a `notebook`, where its cells are,
instead (see [`slate_cells`](@ref)), in the JSON beside the tree.
"""
function code_file_json(kb::KB, p, f; notebook::Bool = false)
    path, slug = f["path"], page_slug(p.doc_id)
    defs = notebook ? [] : file_definitions(kb, p.doc_id, path)
    return Dict{String,Any}(
        "codebase" => Dict("id" => p.doc_id, "slug" => slug, "title" => coalesce(p.title, p.doc_id)),
        "path" => path, "dirs" => rstrip.(parent_dirs(path), '/'), "lines" => f["lines"], "language" => language(path),
        "fence" => fence_language(path), "summary" => something(f["summary"], ""),
        "notebook" => notebook ? "/code/$slug/notebooks/$(f["page"]).json" : nothing,
        # A definition by its name, or a run of lines with none, as `lines a–b`.
        "definitions" => [Dict("name" => startswith(d.name, "lines ") ? "" : d.name, "doc" => d.doc,
                               "first_line" => d.first_line, "last_line" => d.last_line, "source" => rstrip(d.source)) for d in defs])
end

"A codebase file's text, as it was read: its pieces in order (see [`file_definitions`](@ref))."
code_file_text(kb::KB, id::AbstractString, path::AbstractString) = join((d.source for d in file_definitions(kb, id, path)), "\n")

"""
    slate_cells(text) -> Union{Vector{NamedTuple},Nothing}

The cells of a Slate notebook's source, in order, each `(; kind, id, source)`: `kind` as its marker
line names it (`#%% md id=intro`, `#%% code id=setup`), and a Markdown cell's text without its
`@md\"\"\"` wrapper. Slate's own blocks at the end (`# ╔═╡ Slate.env …` to `# ╚═╡`, its packages and
settings) are left out. `nothing` when `text` is not a notebook.
"""
function slate_cells(text::AbstractString)
    text = replace(text, r"^# ╔═╡.*?^# ╚═╡[^\n]*\n?"ms => "")
    marks = collect(eachmatch(r"^#%%[ \t]*(\w+)([^\n]*)$"m, text))
    isempty(marks) && return nothing
    cells = NamedTuple[]
    for (i, m) in enumerate(marks)
        start = m.offset + ncodeunits(m.match)
        stop = i < length(marks) ? prevind(text, marks[i + 1].offset) : lastindex(text)
        body = start > stop ? "" : String(strip(text[start:stop]))
        kind = String(m[1])
        id = (x = match(r"\bid=(\S+)", m[2]); x === nothing ? "" : String(x[1]))
        if kind == "md"
            w = match(r"^@?md\"\"\"\n?(.*?)\n?\"\"\"$"s, body)
            w === nothing || (body = String(w[1]))
        end
        push!(cells, (; kind, id, source = body))
    end
    return cells
end

# ── Codebases not built into the site ───────────────────────────────────────────────────────────

"""
The addresses of a codebase's pages, scripts and data on the site, each with the codebase's slug
(its id, which [`page_slug`](@ref) leaves as it is) and what it names: its page or a file's, the
page's script (a copy of its kind's template's, see [`stamp_templates!`](@ref)), or a data file.
"""
const CODEBASE_ADDRESSES = [
    r"^generated/kb/code/(?<slug>code-[a-z0-9-]+)(?:/|/index|/index\.html)?$" => :page,
    r"^generated/kb/code/(?<slug>code-[a-z0-9-]+)/files/(?<page>[^/]+?)(?:\.html)?$" => :file_page,
    r"^assets/generated_kb_code_(?<slug>code-[a-z0-9-]+)_index\.md(?<tail>\..+\.js)$" => :page_script,
    r"^assets/generated_kb_code_(?<slug>code-[a-z0-9-]+)_files_(?<page>.+)\.md(?<tail>\..+\.js)$" => :file_script,
    r"^kb-data/codebase/(?<slug>code-[a-z0-9-]+)/index\.json$" => :page_data,
    r"^kb-data/code/(?<slug>code-[a-z0-9-]+)/(?<page>[^/]+)\.json$" => :file_data,
    r"^code/(?<slug>code-[a-z0-9-]+)\.json$" => :tree,
    r"^code/(?<slug>code-[a-z0-9-]+)/notebooks/(?<page>[^/]+)\.json$" => :cells]

"""
    codebase_site_response(kb, caller, path; req = nothing) -> Union{HTTP.Response,Nothing}

The answer to a request for the site's `path` when it names a codebase the site is built without
(see [`write_code_site`](@ref)): to a caller who may see it (see [`document_visible`](@ref)), what a
built one has at that address, its page a copy of its kind's built template and its data from the
knowledge base; to anyone else, the site's 404 page. `nothing` for any other path, and for a page
whose template the site served lacks.
"""
function codebase_site_response(kb::KB, caller::Caller, path::AbstractString; req::Union{HTTP.Request,Nothing} = nothing)
    rel = lstrip(path, '/')
    i = findfirst(((re, _),) -> occursin(re, rel), CODEBASE_ADDRESSES)
    i === nothing && return nothing
    re, what = CODEBASE_ADDRESSES[i]
    m = match(re, rel)
    rows = query(kb, "SELECT * FROM papers WHERE doc_id = ? AND $(kind_in(CODEBASE)) AND access = 'projects'", (m[:slug],))
    isempty(rows) && return nothing
    p = first(rows)
    document_visible(kb, caller, p.doc_id) || return not_found_page(kb.config)
    data(x) = (r = json_response(x); HTTP.setheader(r, "Cache-Control" => "no-store"); r)
    what == :page_data && return data(codebase_page_json(kb, p))
    what == :tree && return data(codebase_tree_json(p, code_tree(kb, p.doc_id)))
    if what in (:file_data, :cells)
        files = code_files_in(code_tree(kb, p.doc_id))
        j = findfirst(f -> f["page"] == m[:page], files)
        file, cells = j === nothing ? (nothing, nothing) : code_file_data(kb, p, files[j])
        x = what == :file_data ? file : cells
        return x === nothing ? not_found_page(kb.config) : data(x)
    end
    root = current_site(kb.config)
    root === nothing && return nothing
    template = Dict(TEMPLATED)[what in (:page, :page_script) ? "codebase" : "code"].template
    if what in (:page, :file_page)
        f = joinpath(root, template * ".html")
        return isfile(f) ? file_response(f; req) : nothing
    end
    page = what == :page_script ? "generated/kb/code/$(p.doc_id)/index" : "generated/kb/code/$(p.doc_id)/files/$(m[:page])"
    scripts = template_scripts(root, template)
    j = findfirst(((tail, _),) -> copy_tail(tail) == m[:tail], scripts)
    j === nothing && return nothing
    return HTTP.Response(200, ["Content-Type" => CONTENT_TYPES[".js"], "Cache-Control" => "no-cache"],
                         own_script(last(scripts[j]), template, page))
end
