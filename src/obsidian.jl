# Obsidian vaults in people's libraries (see library_store.jl): a folder of a person's space that holds
# `.obsidian`, synced there from their machine (see `zemi connect`). Each note comes in as a record of
# the `obsidian` source, the person's alone (see document_access.jl), keyed by its place in their
# space, and is read and embedded for their searches and agents without being summarized. A note
# naming a paper by its arXiv id or DOI brings the paper in, private to them unless the group has it,
# and is given references back: the properties Zemi owns (`zemi`, the paper's id, and `zemi-page`, its
# page here), and the paper's title, authors, arXiv id and DOI where the note has those properties
# empty, as a template leaves them. Nothing else is written into the vault.
#
# The vault's own settings say where its templates and daily notes are (`.obsidian/templates.json`,
# `.obsidian/daily-notes.json`): its templates are not read, and a daily note is dated by its path.
# The person's settings for Zemi are in `.zemi.toml` at the vault's root, every one optional:
#
#     skip = ["Drafts"]                          # folders not read, besides hidden ones and the templates folder
#     write = true                               # give paper notes their references (false: only read the vault)
#     dates = ["date", "created", "timestamp"]   # the properties a note's date is taken from, the first set
#     arxiv = ["arxiv"]                          # the properties naming a paper by its arXiv id
#     doi = ["doi"]                              # and by its DOI

"""
    VaultConfig

A vault: the library space it is in and its folder there (`root`, empty for the space itself), with
the person's settings (see obsidian.jl) and what the vault's own say: the folder of its templates
and of its daily notes, and the daily notes' format of name.
"""
Base.@kwdef struct VaultConfig
    space::String
    root::String = ""
    skip::Vector{String} = String[]
    write::Bool = true
    dates::Vector{String} = ["date", "created", "timestamp"]
    arxiv::Vector{String} = ["arxiv"]
    doi::Vector{String} = ["doi"]
    templates::String = ""
    daily_folder::String = ""
    daily_format::String = "YYYY-MM-DD"
end

"A path in the vault as notes are keyed and folders compared: with `/`, in Unicode's composed form."
vault_path(p::AbstractString) = Base.Unicode.normalize(join(filter(!isempty, split(replace(String(p), '\\' => '/'), '/')), '/'), :NFC)

"Where vault `v`'s file `key` is in its space."
in_space(v::VaultConfig, key::AbstractString) = isempty(v.root) ? String(key) : v.root * "/" * key

"""
    vault_config(kb, space, root) -> VaultConfig

The vault at `root` in library `space`, with the person's settings (`.zemi.toml`) and the vault's own
(see [`VaultConfig`](@ref)). Settings that cannot be read are left at their defaults.
"""
function vault_config(kb::KB, space::AbstractString, root::AbstractString)
    file(rel) = read_library_file(kb, space, isempty(root) ? rel : root * "/" * rel)
    parsed(rel, parse) = (b = file(rel); b === nothing ? Dict() : try parse(String(b)) catch; Dict() end)
    s = parsed(".zemi.toml", TOML.parse)
    names(k, default) = (v = get(s, k, default); String[string(x) for x in (v isa AbstractVector ? v : [v]) if !isempty(strip(string(x)))])
    own(name) = parsed(".obsidian/" * name, JSON.parse)
    daily = own("daily-notes.json")
    format = strip(string(something(get(daily, "format", nothing), "")))
    return VaultConfig(; space = String(space), root = String(root), skip = vault_path.(names("skip", String[])),
                       write = get(s, "write", true) !== false,
                       dates = names("dates", ["date", "created", "timestamp"]), arxiv = names("arxiv", ["arxiv"]),
                       doi = names("doi", ["doi"]),
                       templates = vault_path(string(something(get(own("templates.json"), "folder", nothing), ""))),
                       daily_folder = vault_path(string(something(get(daily, "folder", nothing), ""))),
                       daily_format = isempty(format) ? "YYYY-MM-DD" : format)
end

"Whether vault path `p` is folder `dir` or within it."
in_folder(p::AbstractString, dir::AbstractString) = !isempty(dir) && (p == dir || startswith(p, dir * "/"))

"""
    vault_files(kb, v) -> (; notes, files)

The vault's notes, as `key => file`: each Markdown file's path in the vault and its row of the library
(see [`library_files`](@ref)), sorted by key; and every other file (attachments), likewise. Hidden
files and folders, the templates folder, the folders `skip` names and vaults within it are left out.
"""
function vault_files(kb::KB, v::VaultConfig)
    notes, files = Pair{String,Any}[], Pair{String,Any}[]
    left_out(p) = any(d -> in_folder(p, d), [v.templates; v.skip])
    all = library_files(kb, v.space)
    prefix = isempty(v.root) ? "" : v.root * "/"
    inner = [r for r in vault_roots(all) if r != v.root && (isempty(v.root) || in_folder(r, v.root))]
    for f in all
        startswith(f.path, prefix) || continue
        p = f.path[ncodeunits(prefix)+1:end]
        any(startswith("."), split(p, '/')) && continue
        (left_out(p) || any(r -> in_folder(f.path, r), inner)) && continue
        push!(lowercase(splitext(p)[2]) == ".md" ? notes : files, p => f)
    end
    return (; notes = sort!(notes; by = first), files = sort!(files; by = first))
end

"The vaults among a space's files (see [`library_files`](@ref)): the folders holding `.obsidian`, by their place in it."
function vault_roots(files)
    roots = Set{String}()
    for f in files
        m = match(r"^(?:(.*)/)?\.obsidian/", f.path)
        m === nothing || push!(roots, something(m[1], ""))
    end
    return sort!(collect(roots))
end

# ── A note's text ─────────────────────────────────────────────────────────────────────────────────

"""
    split_frontmatter(text) -> (; yaml, body)

A note's properties, as the YAML between its opening `---` and the next `---` (empty without), and
the rest of it.
"""
function split_frontmatter(text::AbstractString)
    t = startswith(text, '﻿') ? text[nextind(text, 1):end] : text
    lines = split(t, '\n')
    (isempty(lines) || rstrip(lines[1], '\r') != "---") && return (; yaml = "", body = String(t))
    for i in 2:length(lines)
        rstrip(lines[i], '\r') in ("---", "...") || continue
        return (; yaml = join(lines[2:i-1], '\n'), body = join(lines[i+1:end], '\n'))
    end
    return (; yaml = "", body = String(t))
end

"A note's properties, read from its YAML (see [`split_frontmatter`](@ref)): none where it is not a mapping YAML can read."
function note_properties(yaml::AbstractString)
    isempty(strip(yaml)) && return Dict{String,Any}()
    d = try
        YAML.load(yaml)
    catch
        nothing
    end
    return d isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in d) : Dict{String,Any}()
end

"Whether a property's value is empty: nothing, blank text, or a list of nothing else."
empty_property(v) = v === nothing || (v isa AbstractString && isempty(strip(v))) || (v isa AbstractVector && all(empty_property, v))

"""
    property_text(props, yaml, key) -> String

Property `key` as text: its value, its first item for a list, and for a number the text written in
the YAML, so an arXiv id written bare (`arxiv: 2401.10000`) keeps its digits.
"""
function property_text(props::AbstractDict, yaml::AbstractString, key::AbstractString)
    v = get(props, key, nothing)
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v === nothing && return ""
    if v isa Number
        m = match(Regex("^" * escape_regex(key) * "\\s*:\\s*(.+?)\\s*\$", "m"), yaml)
        m === nothing || return String(strip(m[1], ['"', '\'']))
    end
    return String(strip(string(v)))
end
escape_regex(s) = replace(s, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")

# A wikilink, `[[target#heading|label]]`, or an embed, `![[target]]`.
const WIKILINK = r"(!?)\[\[([^\[\]\n]+?)\]\]"

"A wikilink's parts: its target (a note's name or path, a file's name), the heading or block after `#`, and its label."
function wikilink_parts(inner::AbstractString)
    target, label = occursin('|', inner) ? split(inner, '|'; limit = 2) : (inner, "")
    target, heading = occursin('#', target) ? split(target, '#'; limit = 2) : (target, "")
    return (; target = String(strip(target)), heading = String(strip(heading)), label = String(strip(label)))
end

"""
    VaultIndex

What a vault's links resolve to: its notes and other files by name and path, the record of each note,
and the paper each paper note names; and how a file of it is read (`read(path)`, its bytes or `nothing`).
"""
struct VaultIndex
    notes::Dict{String,Vector{String}}     # a note's name (its file's, lower case) => the keys of the notes so named
    files::Dict{String,Vector{String}}     # a file's name (lower case) => the paths of the files so named
    read::Function                         # a file's path in the vault => its bytes, or `nothing`
    records::Dict{String,String}           # a note's key => its record's id
    papers::Dict{String,String}            # a paper note's key => the paper's id
end

function VaultIndex(notes, files, records::AbstractDict, papers::AbstractDict; read::Function = p -> nothing)
    by_name(ps) = (d = Dict{String,Vector{String}}(); foreach(p -> push!(get!(d, lowercase(splitext(basename(p))[1]), String[]), p), ps); d)
    names = by_name(first.(notes))
    fnames = Dict{String,Vector{String}}()
    foreach(p -> push!(get!(fnames, lowercase(basename(p)), String[]), p), first.(files))
    return VaultIndex(names, fnames, read, Dict{String,String}(records), Dict{String,String}(papers))
end

"""
    resolve_note(index, target) -> Union{String,Nothing}

The key of the note a wikilink's target names, as Obsidian resolves it: by name, or by a path ending
in it, the note with the shortest path where several match. `nothing` for none.
"""
function resolve_note(ix::VaultIndex, target::AbstractString)
    t = vault_path(target)
    endswith(lowercase(t), ".md") && (t = t[1:end-3])
    isempty(t) && return nothing
    found = filter(k -> lowercase(k[1:end-3]) == lowercase(t) || endswith(lowercase(k[1:end-3]), "/" * lowercase(t)),
                   get(ix.notes, lowercase(basename(t)), String[]))
    return isempty(found) ? nothing : first(sort(found; by = k -> (length(k), k)))
end

"The path in the vault of the file (an attachment) a wikilink's target names, or `nothing`."
function resolve_file(ix::VaultIndex, target::AbstractString)
    t = vault_path(target)
    found = filter(p -> lowercase(p) == lowercase(t) || endswith(lowercase(p), "/" * lowercase(t)), get(ix.files, lowercase(basename(t)), String[]))
    return isempty(found) ? nothing : first(sort(found; by = p -> (length(p), p)))
end

"A wikilink's text in a record: a reference to the paper or record its note is, else its label."
function link_text(ix::VaultIndex, l)
    shown = !isempty(l.label) ? l.label : isempty(l.heading) ? l.target : "$(l.target) > $(l.heading)"
    key = resolve_note(ix, l.target)
    key === nothing && return (; text = shown, key)
    label = replace(shown, ']' => ')', '[' => '(')
    haskey(ix.papers, key) && return (; text = "@[$label](paper:$(ix.papers[key]))", key)
    haskey(ix.records, key) && return (; text = "@[$label](record:$(ix.records[key]))", key)
    return (; text = shown, key)
end

# A code block of a plugin that computes a view of the vault, which is no text of the note's.
const VIEW_BLOCKS = ("dataview", "dataviewjs", "base", "query", "tasks")

"An image file a record can hold as a figure."
const FIGURE_FILES = (".png", ".jpg", ".jpeg", ".webp")

"""
    note_text(index, text) -> (; text, figures, links)

A note's text as a record holds it: wikilinks become references to the papers and records their notes
are (see [`link_text`](@ref)), an embedded image a figure placed in the text, Obsidian's comments
(`%% … %%`) and the blocks of plugins computing views of the vault (Dataview, Bases) are left out.
Code is left as it is. Returns the figures, and the keys of the notes it links to.
"""
function note_text(ix::VaultIndex, text::AbstractString)
    figures, links = NamedTuple[], String[]
    out = IOBuffer()
    for (piece, prose) in prose_pieces(text)
        if !prose
            m = match(r"^```\s*([\w-]*)", piece)
            m !== nothing && lowercase(m[1]) in VIEW_BLOCKS || print(out, piece)
            continue
        end
        piece = replace(piece, r"%%[\s\S]*?%%" => "")
        print(out, replace(piece, WIKILINK => function (s)
            m = match(WIKILINK, s)
            l = wikilink_parts(m[2])
            if m[1] == "!" && lowercase(splitext(l.target)[2]) in FIGURE_FILES
                p = resolve_file(ix, l.target)
                p === nothing && return ""
                bytes = ix.read(p)
                (bytes === nothing || image_kind(bytes) === nothing || length(bytes) > RECORD_LIMITS.image || length(figures) >= RECORD_LIMITS.figures) && return ""
                name = "img-$(length(figures) + 1)"
                caption = occursin(r"^\d+(x\d+)?$", l.label) ? "" : l.label
                push!(figures, (; name, caption, image = bytes))
                return "![$(caption)]($name)"
            end
            r = link_text(ix, l)
            r.key === nothing || push!(links, r.key)
            return r.text
        end))
    end
    return (; text = String(take!(out)), figures, links = unique(links))
end

"A property's value as a line of the record's text: lists joined, wikilinks made references."
function property_value(ix::VaultIndex, v)
    v isa AbstractVector && return join(filter(!isempty, [property_value(ix, x) for x in v]), ", ")
    v isa AbstractDict && return ""
    v === nothing && return ""
    return note_text(ix, string(v)).text
end

# ── Dates ─────────────────────────────────────────────────────────────────────────────────────────

"""
    daily_date(v, key) -> Union{Date,Nothing}

The day a daily note is of, read from its path by the vault's daily notes' folder and format (Moment's
tokens: `YYYY`, `MM`, `M`, `DD`, `D`); `nothing` for a note that is not one.
"""
function daily_date(v::VaultConfig, key::AbstractString)
    rel = key[1:end-3]
    if !isempty(v.daily_folder)
        in_folder(rel, v.daily_folder) || return nothing
        rel = rel[length(v.daily_folder)+2:end]
    end
    pattern, groups = IOBuffer(), Symbol[]
    f = v.daily_format
    i = 1
    while i <= ncodeunits(f)
        rest = f[i:end]
        tok = findfirst(t -> startswith(rest, t), ("YYYY", "MM", "DD", "M", "D"))
        if tok !== nothing
            t = ("YYYY", "MM", "DD", "M", "D")[tok]
            g = t[1] == 'Y' ? :y : t[1] == 'M' ? :m : :d
            print(pattern, g in groups ? "" : "(", t == "YYYY" ? "\\d{4}" : length(t) == 2 ? "\\d{2}" : "\\d{1,2}", g in groups ? "" : ")")
            g in groups || push!(groups, g)
            i += length(t)
        elseif isletter(f[i])
            j = i
            while j <= ncodeunits(f) && isletter(f[j]); j = nextind(f, j); end
            print(pattern, "[^/]+?")
            i = j
        else
            print(pattern, escape_regex(string(f[i])))
            i = nextind(f, i)
        end
    end
    m = match(Regex("^" * String(take!(pattern)) * "\$"), rel)
    (m === nothing || !all(in(groups), (:y, :m, :d))) && return nothing
    n(g) = parse(Int, m.captures[findfirst(==(g), groups)])
    return tryparse(Date, "$(n(:y))-$(lpad(n(:m), 2, '0'))-$(lpad(n(:d), 2, '0'))")
end

"A note's date: the first of its date properties that is a date, else a daily note's day, else the day its file last changed."
function note_date(v::VaultConfig, key::AbstractString, props::AbstractDict, mtime::Real)
    for k in v.dates
        x = get(props, k, nothing)
        x isa AbstractVector && (x = isempty(x) ? nothing : first(x))
        (x isa Date || x isa DateTime) && return x
        if x isa AbstractString
            d = try record_date(x) catch; nothing end
            d === nothing || return d
        end
    end
    d = daily_date(v, key)
    d === nothing || return d
    return Date(unix2datetime(mtime))
end

# ── A note as a record ────────────────────────────────────────────────────────────────────────────

"The properties Zemi writes into a paper note, and never shows as the note's own."
const ZEMI_PROPERTIES = ("zemi", "zemi-page")

"A record's key for a note: its path in the vault, or for one too long, its start and a hash of it."
note_key(p::AbstractString) = length(p) <= RECORD_LIMITS.key ? String(p) : first(p, RECORD_LIMITS.key - 10) * "#" * bytes2hex(sha256(p))[1:8]

"""
    note_record(v, index, key, text, mtime; paper = nothing) -> Union{NamedTuple,Nothing}

Note `key` (its `text`, its file last changed at `mtime`) as a record to hand in, with the keys of the
notes it links to: its title the `title` property, else its first heading, else its file's name; its
date as [`note_date`](@ref) says; its text in sections by its headings (see [`note_text`](@ref)), then
its properties, a paper note's opening with a reference to its `paper`. `nothing` for a note with no
text and no properties.
"""
function note_record(v::VaultConfig, ix::VaultIndex, key::AbstractString, text::AbstractString, mtime::Real; paper = nothing)
    fm = split_frontmatter(text)
    props = note_properties(fm.yaml)
    stem = splitext(basename(key))[1]
    named = property_text(props, fm.yaml, "title")
    body = note_text(ix, fm.body)
    t = lstrip(body.text)
    heading = match(r"^#{1,6}\s", t) !== nothing
    md = markdown_record(heading ? t : "# $(isempty(named) ? stem : named)\n\n$t")
    title = first(!isempty(named) ? named : something(md.title, stem), RECORD_LIMITS.title)
    sections = [(heading = first(s.heading, RECORD_LIMITS.title), text = s.text) for s in md.sections if !isempty(strip(s.text))]
    lines = String[]
    paper === nothing || push!(lines, "A note on @[$(replace(title, ']' => ')', '[' => '('))](paper:$paper).")
    links = copy(body.links)
    for (k, x) in sort!(collect(props); by = first)
        (k == "title" || k in ZEMI_PROPERTIES || empty_property(x)) && continue
        s = property_value(ix, x)
        isempty(strip(s)) || push!(lines, "- $k: $s")
        x isa AbstractVector || (x = [x])
        for y in x
            y isa AbstractString && append!(links, note_text(ix, y).links)
        end
    end
    isempty(lines) || push!(sections, (heading = "Properties", text = join(lines, "\n")))
    isempty(sections) && return nothing
    return (; record = (; key = note_key(key), title, date = note_date(v, key, props, mtime), sections, figures = body.figures),
              links = unique(links))
end

# ── Paper notes ───────────────────────────────────────────────────────────────────────────────────

"What a paper note names its paper by: `arxiv:<id>` or `doi:<doi>`, from the first of those properties set, or `\"\"`."
function paper_reference(v::VaultConfig, props::AbstractDict, yaml::AbstractString)
    for k in v.arxiv
        a = parse_arxiv_id(property_text(props, yaml, k))
        a === nothing || return "arxiv:" * a.id
    end
    for k in v.doi
        d = property_text(props, yaml, k)
        isempty(d) && continue
        a = parse_arxiv_id(d)                                # arXiv's own DOI names its paper
        a === nothing || return "arxiv:" * a.id
        return "doi:" * normalize_doi(d)
    end
    return ""
end

"""
    note_paper!(kb, ref; holder = nothing) -> Union{String,Nothing}

The paper a note names (see [`paper_reference`](@ref)), brought in as the `obsidian` source's for the
note's person (`holder`, see [`bring_in!`](@ref)) and queued to be read where it is new: its id, or
`nothing` for one there is no copy of to read, one dropped here, or one that could not be found.
"""
function note_paper!(kb::KB, ref::AbstractString; holder::Union{Integer,Nothing} = nothing)
    isempty(ref) && return nothing
    id = try
        if startswith(ref, "arxiv:")
            ids = add_papers!(kb, [ref[7:end]]; source = "obsidian", holder)      # none for one dropped here
            isempty(ids) ? nothing : only(ids)
        else
            add_doi!(kb, ref[5:end]; source = "obsidian", holder)
        end
    catch e
        e isa InterruptException && rethrow()
        e isa DroppedError && return nothing
        @warn "The paper an Obsidian note names could not be brought in; it is tried again when the note changes" ref exception = e
        return nothing
    end
    id === nothing && return nothing
    read = !ismissing(scalar(kb, "SELECT 1 FROM parses x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)))
    read || !READ_PUT[] || queue_reading!(kb, [id])
    return id
end

"""
    note_references(kb, v, paper, props) -> Vector{Pair{String,Any}}

The properties to set on a paper note so it refers to `paper`: those Zemi owns (`zemi`, and `zemi-page`
where this knowledge base is served), where they differ from `props`, and the paper's title,
authors, arXiv id and DOI where the note has the property but leaves it empty (as a template makes
it) and the paper's record has them. A property the note does not use is not added.
"""
function note_references(kb::KB, v::VaultConfig, paper::AbstractString, props::AbstractDict)
    out = Pair{String,Any}[]
    ismissing(paper_id(kb, paper)) && return out                 # removed here since: no references to it
    p = paper_row(kb, paper)
    page = document_link(kb.config, paper)
    string(something(get(props, "zemi", nothing), "")) == paper || push!(out, "zemi" => paper)
    isempty(page) || string(something(get(props, "zemi-page", nothing), "")) == page || push!(out, "zemi-page" => page)
    fill(k, x) = haskey(props, k) && empty_property(props[k]) && !empty_property(x) && push!(out, k => x)
    fill("title", coalesce(p.title, ""))
    fill("authors", json_list(p.authors))
    is_arxiv_id(paper) && fill(first(v.arxiv), paper)
    fill(first(v.doi), coalesce(p.doi, ""))
    return out
end

# ── Writing properties ────────────────────────────────────────────────────────────────────────────

"The key a line of YAML begins, at its start (`key:`), or `nothing`."
function yaml_key(line::AbstractString)
    m = match(r"^(\"[^\"]+\"|'[^']+'|[^\s#\-\"'][^:]*?)\s*:(\s|$)", line)
    return m === nothing ? nothing : String(strip(m[1], ['"', '\'']))
end

"A YAML scalar written as Obsidian reads it back as text."
yaml_text(s) = "\"" * replace(string(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => " ") * "\""

"The lines of property `key` set to `x`: a list as items, else one line."
function yaml_lines(key::AbstractString, x)
    k = occursin(r"^[\w][\w -]*$", key) ? key : yaml_text(key)
    x isa AbstractVector && return ["$k:"; ["  - " * yaml_text(y) for y in x]]
    return ["$k: " * yaml_text(x)]
end

"""
    set_properties(text, changes) -> String

`text` with each property of `changes` (`key => value`) set: its lines in the note's properties
replaced (a list's items with it), or added after them; the properties made where the note has none.
Every other line is left as it was, byte for byte.
"""
function set_properties(text::AbstractString, changes)
    isempty(changes) && return String(text)
    nl = occursin("\r\n", text) ? "\r\n" : "\n"
    bom = startswith(text, '﻿') ? "﻿" : ""
    t = isempty(bom) ? String(text) : text[nextind(text, 1):end]
    lines = split(t, nl)
    close = rstrip(first(lines)) == "---" ? findnext(l -> rstrip(l) in ("---", "..."), lines, 2) : nothing
    if close === nothing
        props = String[]
        foreach(((k, x),) -> append!(props, yaml_lines(k, x)), changes)
        return bom * join(["---"; props; "---"], nl) * nl * t
    end
    fm = String.(lines[2:close-1])
    for (k, x) in changes
        i = findfirst(l -> yaml_key(l) == k, fm)
        if i === nothing
            append!(fm, yaml_lines(k, x))
        else
            j = i + 1
            while j <= length(fm) && (startswith(fm[j], " ") || startswith(fm[j], "\t") || startswith(fm[j], "-"))
                j += 1
            end
            fm = [fm[1:i-1]; yaml_lines(k, x); fm[j:end]]
        end
    end
    return bom * join([String(lines[1]); fm; String.(lines[close:end])], nl)
end

# ── Reading a vault ───────────────────────────────────────────────────────────────────────────────

"A note's record key: its place in its person's space (see [`note_key`](@ref)), so that people's notes are kept apart."
vault_key(v::VaultConfig, k::AbstractString) = note_key(v.space * "/" * in_space(v, k))

"Where what is known of each note of vault `v` is kept (see [`read_vault!`](@ref)), apart from the source's small state."
vault_index_key(v::VaultConfig) = source_state_key("obsidian") * ":" * v.space * ":" * v.root

load_vault_index(kb::KB, v::VaultConfig) =
    Dict{String,Any}(JSON.parse(coalesce(scalar(kb, "SELECT value FROM kv WHERE key = ?", (vault_index_key(v),)), "{}")))
save_vault_index!(kb::KB, v::VaultConfig, d) = execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (vault_index_key(v), JSON.json(d)))

"When a file of a library last changed, in Unix seconds."
file_time(f) = datetime2unix(parse_iso(f.modified))

"Note `k` of vault `v` as its space holds it now (empty for one gone since)."
read_note(kb::KB, v::VaultConfig, k::AbstractString) = String(something(read_library_file(kb, v.space, in_space(v, k)), UInt8[]))

"""
    read_vault!(run, v)

Bring vault `v` in step (see obsidian.jl) as `run`, for the person whose space it is in (its
`holder`). Each note is known by its file's hash, the paper it names and the notes it links to, so a
run reads only the notes that changed:

- a note new or changed is handed in as a record (see [`note_record`](@ref)); one with no text has none
- a note gone is removed, unless a new one has its content, which is the note moved: its record keeps
  its id under the new key
- a note naming a paper brings it in (see [`note_paper!`](@ref)); when the paper a note names changes,
  the notes linking to it are handed in again, so their references follow
- a note whose record is gone though it has not changed (its source forgotten) is handed in again;
  one a person dropped is left out until it changes
- with `write`, a paper note is given its references (see [`note_references`](@ref)), its file
  rewritten only where they change, and what Zemi wrote is known as the note, not read as an edit
"""
function read_vault!(run::SourceRun, v::VaultConfig)
    kb = run.kb
    seen = load_vault_index(kb, v)
    prefix = v.space * "/" * (isempty(v.root) ? "" : v.root * "/")
    records = Dict(String(r.key) => String(r.doc_id) for r in query(kb, """
        SELECT x.key, p.doc_id FROM records x JOIN papers p ON p.id = x.paper_id
        WHERE x.source = 'obsidian' AND substr(x.key, 1, ?) = ?""", (length(prefix), prefix)))
    vf = vault_files(kb, v)
    files = Dict(vf.notes)
    try
        # What changed, by content.
        texts = Dict{String,String}()
        changed = String[]
        for (k, f) in vf.notes
            e = get(seen, k, nothing)
            gone = e !== nothing && e["id"] !== nothing && !haskey(records, vault_key(v, k))
            e !== nothing && !gone && e["sha"] == f.sha256 && continue
            texts[k] = read_note(kb, v, k)
            push!(changed, k)
        end
        # Moved: a note gone whose content a new one has.
        lost = Dict(e["sha"] => k for (k, e) in seen if !haskey(files, k) && e["id"] !== nothing)
        for k in changed
            haskey(seen, k) && continue
            from = get(lost, bytes2hex(sha256(texts[k])), nothing)
            from === nothing && continue
            haskey(records, vault_key(v, from)) && !haskey(records, vault_key(v, k)) || continue
            rekey!(run, vault_key(v, from), vault_key(v, k))
            records[vault_key(v, k)] = pop!(records, vault_key(v, from))
            seen[k] = pop!(seen, from)
            delete!(lost, seen[k]["sha"])
        end
        for k in collect(keys(seen))
            haskey(files, k) && continue
            remove!(run, vault_key(v, k))
            delete!(records, vault_key(v, k))
            delete!(seen, k)
        end
        # The papers the changed notes name; the notes linking to one whose paper changed are handed in again.
        papers = Dict{String,String}(k => e["paper"] for (k, e) in seen if e["paper"] !== nothing)
        refs = Dict{String,String}()
        moved = String[]
        for k in changed
            fm = split_frontmatter(texts[k])
            ref = paper_reference(v, note_properties(fm.yaml), fm.yaml)
            e = get(seen, k, nothing)
            was = e === nothing ? nothing : e["paper"]
            paper = e !== nothing && e["ref"] == ref ? was : note_paper!(kb, ref; holder = run.holder)
            refs[k] = ref
            paper === nothing ? delete!(papers, k) : (papers[k] = paper)
            paper == was || push!(moved, k)
        end
        for (k, e) in seen
            (k in changed || isempty(intersect(e["links"], moved))) && continue
            texts[k] = read_note(kb, v, k)
            refs[k] = e["ref"]
            push!(changed, k)
        end
        ix = VaultIndex(vf.notes, vf.files, Dict(k => get(records, vault_key(v, k), record_id("obsidian", vault_key(v, k))) for (k, _) in vf.notes),
                        papers; read = p -> read_library_file(kb, v.space, in_space(v, p)))
        for (i, k) in enumerate(changed)
            i % 50 == 0 && progress(run, "$i of $(length(changed)) notes read")
            entry = Dict{String,Any}("sha" => bytes2hex(sha256(texts[k])), "modified" => files[k].modified, "ref" => refs[k],
                                     "paper" => get(papers, k, nothing), "links" => String[], "id" => nothing)
            haskey(papers, k) && (entry["props"] = reference_properties(v, texts[k]))
            r = try
                note_record(v, ix, k, texts[k], file_time(files[k]); paper = get(papers, k, nothing))
            catch e
                e isa InterruptException && rethrow()
                @warn "An Obsidian note could not be read as a record; it is tried again when it changes" note = k exception = e
                seen[k] = entry
                continue
            end
            if r === nothing
                remove!(run, vault_key(v, k))
            else
                entry["links"] = r.links
                entry["id"] = try
                    put!(run, (; r.record..., key = vault_key(v, k)))
                catch e
                    e isa SourceStopped && rethrow()
                    @warn "An Obsidian note could not be handed in; it is tried again when it changes" note = k exception = e
                    nothing
                end
            end
            seen[k] = entry
        end
        v.write && write_references!(run, v, ix, files, seen)
    finally
        save_vault_index!(kb, v, seen)
    end
    return nothing
end

"""
    forget_vault!(run, v)

Vault `v` is gone from its space: remove the records of its notes, and what was known of them.
"""
function forget_vault!(run::SourceRun, v::VaultConfig)
    for k in keys(load_vault_index(run.kb, v))
        remove!(run, vault_key(v, k))
    end
    execute!(run.kb, "DELETE FROM kv WHERE key = ?", (vault_index_key(v),))
    return nothing
end

"The properties of a paper note its references are worked out from (see [`note_references`](@ref)), as they are in `text`."
function reference_properties(v::VaultConfig, text::AbstractString)
    props = note_properties(split_frontmatter(text).yaml)
    return Dict{String,Any}(k => props[k] for k in ["zemi", "zemi-page", "title", "authors", first(v.arxiv), first(v.doi)] if haskey(props, k))
end

"""
Give each paper note its references (see [`note_references`](@ref)), worked out from the properties it
had when last read: written into the space's copy (which reaches the person's own as it syncs), only
where they change, and only over the version last read, dated as that was. The note's record is then
handed in again as the note now is.
"""
function write_references!(run::SourceRun, v::VaultConfig, ix::VaultIndex, files, seen)
    for (k, e) in seen
        paper = e["paper"]
        (paper === nothing || !haskey(files, k)) && continue
        isempty(note_references(run.kb, v, paper, get(e, "props", Dict{String,Any}()))) && continue
        cancelled(run) && return
        text = read_note(run.kb, v, k)
        bytes2hex(sha256(text)) == e["sha"] || continue          # changed since: read again in the next run
        new = set_properties(text, note_references(run.kb, v, paper, reference_properties(v, text)))
        e["props"] = reference_properties(v, new)
        new == text && continue                                  # (properties it cannot read: nothing to change)
        # Dated as before: Zemi's writing is not when the note changed.
        f = try
            put_library_file!(run.kb, v.space, in_space(v, k), Vector{UInt8}(new); base = e["sha"], modified = parse_iso(e["modified"]))
        catch ex
            ex isa Refusal && ex.status in (409, 413) && continue   # changed meanwhile, or the space is full: next time
            rethrow()
        end
        e["sha"] = f.sha256
        r = note_record(v, ix, k, new, file_time(f); paper)
        r === nothing || (e["id"] = put!(run, (; r.record..., key = vault_key(v, k))))
    end
end

# Its records are handed in by Zemi as it reads people's libraries (see library_reading.jl): it neither
# polls nor reads uploads, and a library holds many notes, so a run may write many.
record_source!("obsidian"; label = "From an Obsidian vault", summarized = false, about = "a person's own note",
               budget = (; records = 100_000, figure_bytes = 10_000_000_000, seconds = 86_400.0), api = PLUGIN_API)
