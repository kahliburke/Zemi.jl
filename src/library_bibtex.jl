# The bibliographies in people's libraries: a `.bib` file (JabRef's, say) synced by `zemi connect`
# with the PDFs it links. Each entry comes in as the document it is, for the space's person (see
# library_reading.jl): the PDF it links, read in full under the entry's title, authors and date; else
# its arXiv paper; else the paper its DOI has an open copy of; else a resource, made of what the entry
# says. The entry's key cites that document for its person (see `cite_aliases`). The file is the
# person's record and is only read: an entry edited is read again, and one removed lets its document
# go. Entries are told apart by their keys, from one read of a file to the next.

record_source!("bibtex"; label = "From a person's BibTeX bibliography", summarized = false,
               about = "a work in a person's bibliography",
               arrives = "As people's libraries are read: the entries of their .bib files", api = PLUGIN_API)

"A space's bibliographies: its `.bib` files, outside hidden folders."
bib_files_of(files) = [f for f in files if lowercase(splitext(f.path)[2]) == ".bib" && !any(startswith("."), split(f.path, '/'))]

"The type a resource made of an entry of each BibTeX type is (see `RESOURCE_TYPES`); any other is a document."
const BIB_RESOURCE_TYPES = Dict(
    "article" => "article", "book" => "book", "mvbook" => "book", "booklet" => "book", "inbook" => "book section",
    "incollection" => "book section", "bookinbook" => "book section", "inproceedings" => "conference paper",
    "conference" => "conference paper", "techreport" => "report", "report" => "report", "phdthesis" => "thesis",
    "mastersthesis" => "thesis", "thesis" => "thesis", "dataset" => "dataset", "software" => "software",
    "online" => "web page", "electronic" => "web page", "www" => "web page", "patent" => "patent",
    "legislation" => "law", "legal" => "law", "jurisdiction" => "law", "periodical" => "article",
    "presentation" => "presentation", "map" => "map")

"""
    bib_work(e) -> NamedTuple

What BibTeX entry `e` says of its work, as plain text: its `title` (with a BibLaTeX `subtitle`), its
`authors` (else its editors, see [`bib_names`](@ref)) and which are `organizations`, its `date`, `doi`
and `arxiv` id, the `container` it appeared in, its `publisher`, `url` and the date it was `accessed`
there, a `note` (its abstract and note), and the `type` a resource made of it is.
"""
function bib_work(e::BibEntry)
    f(k) = bib_plain(get(e.fields, k, ""))
    sub = f("subtitle")
    title = isempty(sub) ? f("title") : f("title") * ": " * sub
    names = bib_names(get(e.fields, haskey(e.fields, "author") ? "author" : "editor", ""))
    pick(ks...) = (i = findfirst(k -> !isempty(f(k)), ks); i === nothing ? "" : f(ks[i]))
    container = e.type in ("inbook", "incollection", "inproceedings", "conference", "bookinbook") ? pick("booktitle", "maintitle") :
                pick("journaltitle", "journal", "howpublished", "booktitle")
    accessed = match(r"^\d{4}(?:-\d{2}(?:-\d{2})?)?", f("urldate"))
    return (; title, authors = [n.name for n in names], organizations = [n.name for n in names if n.organization],
            date = bib_date(e.fields), doi = bib_doi(e.fields), arxiv = bib_arxiv(e.fields), container,
            publisher = pick("publisher", "institution", "school", "organization"), url = f("url"),
            accessed = accessed === nothing ? "" : String(accessed.match),
            note = join(filter(!isempty, [f("abstract"), f("note")]), "\n\n"), type = get(BIB_RESOURCE_TYPES, e.type, "document"))
end

"""
    bib_pdf(files, bib, written; meta) -> Union{NamedTuple,Nothing}

The file of the space (among `files`) that a `file` field's path `written` names, in `.bib` file `bib`:
the path taken from the `.bib`'s folder, or from the file directory JabRef keeps for it
(`fileDirectory`, in `meta`); else, for a path from another machine (absolute, as JabRef writes one
outside its file directory), the one file under the `.bib`'s folder whose path ends as it does.
`nothing` where none is.
"""
function bib_pdf(files, bib::AbstractString, written::AbstractString; meta = Dict{String,String}(),
                 by_path = Dict(f.path => f for f in files))
    parts(p) = filter(s -> !isempty(s) && s != ".", split(replace(p, '\\' => '/'), '/'))
    function under(base, rel)
        out = String[]
        for s in [parts(base); parts(rel)]
            s == ".." ? (isempty(out) || pop!(out)) : push!(out, s)
        end
        return join(out, '/')
    end
    folder = dirname(bib)
    absolute = startswith(written, '/') || occursin(r"^[A-Za-z]:[\\/]", written)
    if !absolute
        for d in unique(filter(!isempty, [get(meta, "fileDirectory", ""); [v for (k, v) in meta if startswith(k, "fileDirectory-")]]))
            startswith(d, '/') || occursin(r"^[A-Za-z]:[\\/]", d) || (f = get(by_path, under(under(folder, d), written), nothing); f === nothing || return f)
        end
        f = get(by_path, under(folder, written), nothing)
        f === nothing || return f
    end
    # Matched by the end of its path, the longest that names one file under the folder.
    tail = parts(written)
    inside = [f for f in files if isempty(folder) || startswith(f.path, folder * "/")]
    for n in length(tail):-1:1
        suffix = join(tail[end-n+1:end], '/')
        hits = [f for f in inside if f.path == suffix || endswith(f.path, "/" * suffix)]
        length(hits) == 1 && return only(hits)
        length(hits) > 1 && return nothing
    end
    return nothing
end

# The key of the resource an entry is made into: the person's space, the file, and the entry's key, so
# that two people's, or two files', are two.
bib_resource_key(space, bib, key) = "$space/$bib#$key"

"""
    bib_document!(kb, space, bib, e, pdf; holder = nothing, was = nothing) -> Union{String,Nothing}

Bring entry `e` of library `space`'s bibliography `bib` in as the document it is, for the space's
person (`holder`): the PDF it links (`pdf`, a file of the space, or `nothing`) under the entry's
title, authors, year and DOI; else its arXiv paper; else the paper its DOI has an open copy of (see
[`add_doi!`](@ref)); else the resource it is kept as here by its DOI; else a resource made of the
entry. A paper found for an entry that was a resource (`was`) takes the resource's place (see
[`move_document!`](@ref)). Each new paper is queued to be read. `nothing` for an entry with nothing to
bring in (no title, no PDF, no identifier) or one a person dropped.
"""
function bib_document!(kb::KB, space::AbstractString, bib::AbstractString, e::BibEntry, pdf; holder = nothing, was = nothing)
    w = bib_work(e)
    year = isempty(w.date) ? nothing : first(w.date, 4)
    title = isempty(w.title) ? nothing : w.title
    id = try
        if pdf !== nothing
            bytes = read_library_file(kb, space, pdf.path)
            bytes === nothing ? nothing : mktempdir() do dir
                path = joinpath(dir, basename(pdf.path))
                write(path, bytes)
                d = add_pdf!(kb, path; title, authors = w.authors, published = year, source = "bibtex", holder)
                w.doi === nothing || execute!(kb, "UPDATE papers SET doi = ? WHERE doc_id = ? AND doi IS NULL", (w.doi, d))
                d
            end
        elseif w.arxiv !== nothing
            ids = add_papers!(kb, [w.arxiv]; source = "bibtex", holder)
            isempty(ids) ? nothing : only(ids)
        elseif w.doi !== nothing
            add_doi!(kb, w.doi; title, authors = w.authors, published = year, source = "bibtex", holder)
        end
    catch err
        err isa DroppedError && return nothing
        rethrow()
    end
    if id !== nothing
        unread = ismissing(scalar(kb, "SELECT 1 FROM parses x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)))
        unread && READ_PUT[] && queue_reading!(kb, [id])
        was !== nothing && was != id && resource_row(kb, was) !== nothing && resource_row(kb, was).source == "bibtex" &&
            move_document!(kb, was, id)
        return id
    end
    if w.doi !== nothing
        kept = document_with_doi(kb, w.doi)
        ismissing(kept) || (bring_in!(kb, kept, holder; new = false); return kept)
    end
    title === nothing && return nothing
    key = bib_resource_key(space, bib, e.key)
    new = ismissing(scalar(kb, "SELECT 1 FROM resources WHERE source = 'bibtex' AND key = ?", (key,)))
    r = Resource(; key, title, type = w.type, w.authors, w.organizations, w.date, w.url, doi = something(w.doi, ""), w.note,
                 w.container, w.publisher, w.accessed)
    rid = try
        first(put_resource!(kb, "bibtex", r; read = READ_PUT[]))
    catch err
        err isa DroppedError && return nothing
        rethrow()
    end
    bring_in!(kb, rid, holder; new)
    return rid
end

"""
    read_bibliographies!(kb, space, files, state; holder = nothing, run = nothing) -> Set{String}

Bring the knowledge base in step with the bibliographies among library `space`'s `files` (see
[`bib_document!`](@ref)), keeping in `state["bibs"]` what each entry was last read as: a hash of it and
of the PDF it links, its document, that PDF, and the files it links that are not here. An entry
unchanged is not read again. One that cannot be read now keeps its document and is tried again at
the next reading. The space's citation keys are then those of its entries (see
[`set_cite_aliases!`](@ref)), the first file's where two give one key. Returns the PDFs the entries
link, which are theirs to read.
"""
function read_bibliographies!(kb::KB, space::AbstractString, files, state; holder = nothing, run = nothing)
    before = Dict{String,Any}(get(state, "bibs", Dict{String,Any}()))
    bibs = Dict{String,Any}()
    linked = Set{String}()
    sha = Dict(f.path => f.sha256 for f in files)
    by_path = Dict(f.path => f for f in files)
    for f in sort(bib_files_of(files); by = f -> f.path)
        bytes = read_library_file(kb, space, f.path)
        bytes === nothing && continue
        b = parse_bibtex(String(bytes))
        old = Dict{String,Any}(get(get(before, f.path, Dict{String,Any}()), "entries", Dict{String,Any}()))
        entries = Dict{String,Any}()
        problems = copy(b.problems)
        for e in b.entries
            if haskey(entries, e.key)
                push!(problems, "Line $(e.line): the key $(e.key) is another entry's too; the first is read")
                continue
            end
            if run !== nothing && cancelled(run)
                haskey(old, e.key) && (entries[e.key] = old[e.key])            # read next time
                continue
            end
            written = bib_files(get(e.fields, "file", ""))
            found = [bib_pdf(files, f.path, p; meta = b.meta, by_path) for p in written]
            at = findfirst(!isnothing, found)
            pdf = at === nothing ? nothing : found[at]
            pdf === nothing || push!(linked, pdf.path)
            sig = bytes2hex(sha256(JSON.json([e.type, sort!(collect(e.fields); by = first), pdf === nothing ? "" : sha[pdf.path]])))
            prev = get(old, e.key, nothing)
            prev !== nothing && prev["sig"] == sig && (entries[e.key] = prev; continue)
            was = prev === nothing ? nothing : prev["id"]
            id = try
                bib_document!(kb, space, f.path, e, pdf; holder, was)
            catch err
                err isa InterruptException && rethrow()
                @warn "An entry of a bibliography in a library could not be brought in; it is tried again at the next reading" file = f.path key = e.key exception = err
                prev === nothing || (entries[e.key] = merge(prev, Dict("sig" => "")))
                continue
            end
            entries[e.key] = Dict{String,Any}("sig" => sig, "id" => id, "pdf" => pdf === nothing ? "" : pdf.path,
                                              "missing" => [p for (p, x) in zip(written, found) if x === nothing])
        end
        bibs[f.path] = Dict{String,Any}("sha" => f.sha256, "entries" => entries, "problems" => problems)
    end
    state["bibs"] = bibs
    aliases = Dict{String,Tuple{String,String}}()
    for path in sort!(collect(keys(bibs))), (key, x) in bibs[path]["entries"]
        x["id"] === nothing || haskey(aliases, key) || (aliases[key] = (current_document(kb, x["id"]), path))
    end
    set_cite_aliases!(kb, space, aliases)
    return linked
end

"The documents (their ids) the bibliographies of a space's reading `state` bring in."
bib_documents(state) = Set{String}(String(x["id"]) for b in values(get(state, "bibs", Dict())) for x in values(b["entries"]) if x["id"] !== nothing)

"""
    bib_overview(state, folder) -> Vector{Dict}

The bibliographies of a space's folder `folder`, as one's library shows them: each `.bib` file, how
many entries it has and how many came in as documents, the entries whose linked files are not in the
library (their key, and the files as written), and what in the file could not be read.
"""
function bib_overview(state, folder::AbstractString)
    out = Dict{String,Any}[]
    for (path, b) in sort!(collect(get(state, "bibs", Dict())); by = first)
        library_folder(path) == folder || continue
        es = b["entries"]
        push!(out, Dict{String,Any}("path" => path, "entries" => length(es), "documents" => count(x -> x["id"] !== nothing, values(es)),
                                    "missing" => [Dict("key" => k, "files" => x["missing"]) for (k, x) in sort!(collect(es); by = first)
                                                  if !isempty(x["missing"]) && isempty(x["pdf"])],
                                    "problems" => b["problems"]))
    end
    return out
end
