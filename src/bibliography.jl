# BibTeX for the knowledge base's documents: a study's references (see study.jl), and the whole
# knowledge base as one file, for a reference manager or a LaTeX document.

"""
    cite_key(id) -> String

The bibliography key of a document: `arXiv:` and its id for a paper (an old-style id's `/` as `_`),
readable in a draft and valid in BibTeX, Slate's `[@key]` and Typst; an upload's or a record's own id
otherwise.
"""
cite_key(id::AbstractString) = is_arxiv_id(id) ? "arXiv:" * replace(id, '/' => '_') : String(id)

bib_escape(s) = replace(string(s), r"([&%#_])" => s"\\\1")
# "First Last" → "Last, First" for BibTeX; a name already with a comma is kept, and a team or
# collaboration is braced so it stays whole.
function bib_name(n)
    n = strip(n)
    occursin(r"(?i)\b(team|collaboration|group|consortium)\b", n) && return "{" * n * "}"
    occursin(',', n) && return n
    p = split(n)
    return length(p) < 2 ? n : string(p[end], ", ", join(p[1:end-1], " "))
end

"""
    bib_entry(kb, id; pages = "generated/kb/", docpage = true) -> String

A document's BibTeX entry, keyed by [`cite_key`](@ref). A paper is an article: its authors, title,
year, arXiv record, DOI, journal (its journal reference, else its arXiv record) and `url` (the arXiv
page). An upload is an article when it has a journal reference, else a `misc`. A record is a `misc`:
its people, title, date, how it was made and `url`, its page on the site. A resource is the entry its
type calls for (see [`resource_bib`](@ref)). With `docpage`, the entry
also names the knowledge base's page for it under the docs source, which the docs site links a
citation to.
"""
function bib_entry(kb::KB, id::AbstractString; pages::AbstractString = "generated/kb/", docpage::Bool = true)
    p = paper_row(kb, id)
    arxiv = is_arxiv_id(id)
    field(k, v) = (ismissing(v) || isempty(string(v))) ? "" : "  $k = {$(v)},\n"
    io = IOBuffer()
    r = record_row(kb, id)
    if r !== nothing
        print(io, "@misc{", cite_key(id), ",\n")
        print(io, field("author", join(bib_name.(json_list(p.authors)), " and ")))
        print(io, field("title", "{" * bib_escape(coalesce(p.title, id)) * "}"))
        print(io, field("year", first(r.happened, 4)), field("date", first(r.happened, 10)))
        print(io, field("howpublished", bib_escape(r.label)), field("url", document_link(kb.config, id)))
        print(io, "}\n")
        return String(take!(io))
    end
    is_resource(id) && return resource_bib(kb, id; pages, docpage)
    # An article, the usual form for a preprint: citation styles print an article's year, and its
    # journal is where it appeared or else its arXiv record.
    print(io, "@", arxiv || !ismissing(p.journal_ref) ? "article" : "misc", "{", cite_key(id), ",\n")
    print(io, field("author", join(bib_name.(json_list(p.authors)), " and ")))
    print(io, field("title", "{" * bib_escape(coalesce(p.title, id)) * "}"))
    print(io, field("year", first(coalesce(p.published, ""), 4)))
    if arxiv
        print(io, field("eprint", id), field("archivePrefix", "arXiv"), field("primaryClass", p.primary_category))
        print(io, field("url", "https://arxiv.org/abs/$id"))
    end
    journal = !ismissing(p.journal_ref) ? bib_escape(p.journal_ref) : arxiv ? "arXiv preprint arXiv:$id" : missing
    print(io, field("journal", journal), field("doi", p.doi))
    docpage && print(io, field("docpage", "$(pages)$(document_page(id)).md"))
    print(io, "}\n")
    return String(take!(io))
end

"The BibTeX entry type of each type of resource whose fields a style prints; any other is a `misc`."
const RESOURCE_ENTRIES = Dict("article" => "article", "news" => "article", "magazine article" => "article", "book" => "book",
                              "book section" => "incollection", "conference paper" => "inproceedings", "report" => "techreport")

"""
    resource_bib(kb, id; pages = "generated/kb/", docpage = true) -> String

Resource `id`'s BibTeX entry: an article (in its journal or newspaper), a book or a chapter of one,
a conference paper, or a report (of its institution), with what a style prints of each; anything
else (a data set, a portal, software, a law) a `misc`, published where it appeared or by whom, and
noting its type. Each with its authors, title, date, DOI, address and when it was accessed there.
"""
function resource_bib(kb::KB, id::AbstractString; pages::AbstractString = "generated/kb/", docpage::Bool = true)
    r = resource_row(kb, id)
    field(k, v; escape = true) = isempty(string(v)) ? "" : "  $k = {$(escape ? bib_escape(v) : v)},\n"
    entry = get(RESOURCE_ENTRIES, r.type, "misc")
    entry == "techreport" && isempty(r.publisher) && (entry = "misc")
    date = coalesce(r.published, "")
    io = IOBuffer()
    print(io, "@", entry, "{", cite_key(id), ",\n")
    # An organization is braced, so a style prints it whole ("others", in an author list, is "et al.").
    orgs = Set(json_list(r.organizations))
    name(a) = a in orgs && a != "others" ? "{" * a * "}" : bib_name(a)
    print(io, field("author", join(name.(json_list(r.authors)), " and ")))
    print(io, "  title = {{", bib_escape(r.title), "}},\n")
    print(io, field("year", first(date, 4)), length(date) > 4 ? field("date", date) : "")
    if entry == "article"
        print(io, field("journal", r.container))
    elseif entry in ("incollection", "inproceedings")
        print(io, field("booktitle", r.container), field("publisher", r.publisher))
    elseif entry == "book"
        print(io, field("publisher", r.publisher))
    elseif entry == "techreport"
        print(io, field("institution", r.publisher))
    else
        print(io, field("howpublished", isempty(r.container) ? r.publisher : r.container))
        r.type in ("", "document") || print(io, field("note", uppercasefirst(r.type)))
    end
    # An address is printed as it is (styles set it with \url), so it is not escaped.
    print(io, field("doi", coalesce(r.doi, ""); escape = false), field("url", r.url; escape = false),
          isempty(r.url) ? "" : field("urldate", r.accessed))
    docpage && print(io, field("docpage", "$(pages)$(document_page(id)).md"))
    print(io, "}\n")
    return String(take!(io))
end

"""
    bibliography(kb; ids = every document cited, caller = nothing, keys = nothing, docpage = false) -> String

The knowledge base as one BibTeX file: an entry for each of `ids` (see [`bib_entry`](@ref)), in key
order, by default every document of a kind that is cited (see [`DocumentKind`](@ref)): papers,
uploads and records, not codebases. With `caller`, only those they may see (see
[`document_visible`](@ref)); with `keys`, only those cited by those keys. `zemi bib` writes it, and
the service answers it at `/api/bib`.
"""
function bibliography(kb::KB; ids = nothing, caller::Union{Caller,Nothing} = nothing, keys = nothing,
                      docpage::Bool = false, pages::AbstractString = "generated/kb/")
    ids === nothing && (ids = [String(r.id) for r in query(kb, "SELECT doc_id AS id FROM papers WHERE $(kind_in(k -> k.cited))")])
    if caller !== nothing
        unseen = hidden_documents(kb, caller)
        ids = filter(!in(unseen), ids)
    end
    keys === nothing || (wanted = Set(keys); ids = filter(id -> cite_key(id) in wanted, ids))
    entries = [bib_entry(kb, id; pages, docpage) for id in sort(ids; by = cite_key)]
    return "% The documents of the knowledge base: $(length(entries)) entries.\n\n" * join(entries, "\n")
end

