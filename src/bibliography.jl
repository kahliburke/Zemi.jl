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


# ── A citation in prose ───────────────────────────────────────────────────────────────────────────

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                "November", "December"]

# A person as APA names them, "Hale, R. A."; an organization, a team, or a name of one word whole, and
# "others" (the end of an author list) as "et al.".
function apa_name(n::AbstractString, organizations = Set{String}())
    n = strip(n)
    n == "others" && return "et al."
    (n in organizations || occursin(r"(?i)\b(team|collaboration|group|consortium)\b", n)) && return String(n)
    last, given = occursin(',', n) ? strip.(split(n, ','; limit = 2)) : (p = split(n); length(p) < 2 ? (n, "") : (p[end], join(p[1:end-1], " ")))
    initials = join([uppercase(first(g)) * "." for g in split(given, r"[\s.]+") if !isempty(g)], " ")
    return isempty(initials) ? String(last) : "$last, $initials"
end

# Authors as APA lists them: all of them up to 20, joined with "&"; more, the first 19, "…" and the last.
function apa_authors(names::AbstractVector)
    n = filter(!=("et al."), names)
    tail = length(n) < length(names) ? ", et al." : ""
    isempty(n) && return ""
    length(n) == 1 && return n[1] * tail
    length(n) > 20 && return join(n[1:19], ", ") * ", … " * n[end]
    return isempty(tail) ? join(n[1:end-1], ", ") * ", & " * n[end] : join(n, ", ") * tail
end

# A date as APA gives it: the year, or the year and the day for what is dated to the day ("2025, September 12").
function apa_date(date::AbstractString; day::Bool = false)
    m = match(r"^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?", date)
    m === nothing && return "n.d."
    (day && m[3] !== nothing) || return m[1]
    return "$(m[1]), $(MONTHS[parse(Int, m[2])]) $(parse(Int, m[3]))"
end

# A day written out, "November 5, 2026"; a date not to the day as it is.
function spelled_date(date::AbstractString)
    m = match(r"^(\d{4})-(\d{2})-(\d{2})", date)
    return m === nothing ? String(date) : "$(MONTHS[parse(Int, m[2])]) $(parse(Int, m[3])), $(m[1])"
end

ends(s) = isempty(s) || endswith(s, r"[.?!]") ? s : s * "."

# The parts of a reference in APA's order: who, when, what, where, address. With no authors the
# title takes their place.
function apa_reference(authors::AbstractString, date::AbstractString, title::AbstractString, where::AbstractString, address::AbstractString)
    head = isempty(authors) ? [ends(title), "($date)."] : [ends(authors), "($date).", ends(title)]
    return join(filter(!isempty, [head; ends(where); address]), " ")
end

"The bracketed description APA gives a work of each type that is not a text (a data set, software, a web page)."
const APA_DESCRIPTIONS = Dict("dataset" => "Data set", "data portal" => "Data portal", "software" => "Computer software",
                              "web page" => "Web page", "map" => "Map", "video" => "Video", "podcast" => "Podcast",
                              "presentation" => "Presentation", "law" => "Law", "standard" => "Standard", "patent" => "Patent")

"""
    citation(kb, id) -> String

Document `id` as a reference in APA style, plain text for a document or an email: its authors, date,
title, where it appeared and its address (its DOI, else its address, with when it was accessed for a
work that changes, else its page here). A paper's journal is its journal reference, else its arXiv
record; a resource names where it appeared or who published it, and what it is when it is not a text;
a record is described by how it was made.
"""
function citation(kb::KB, id::AbstractString)
    p = paper_row(kb, id)
    doi_link(d) = ismissing(d) || isempty(d) ? "" : "https://doi.org/" * d
    if is_resource(id)
        r = resource_row(kb, id)
        orgs = Set(json_list(r.organizations))
        date = coalesce(r.published, "")
        kind = get(RESOURCE_ENTRIES, r.type, "misc")
        what = haskey(APA_DESCRIPTIONS, r.type) ? "$(r.title) [$(APA_DESCRIPTIONS[r.type])]" : r.title
        # A publisher that is also its author is named once, as the author.
        publisher = r.publisher in json_list(r.authors) ? "" : r.publisher
        where = kind == "article" || isempty(publisher) ? r.container :
                isempty(r.container) || r.container == publisher ? publisher : "$(r.container). $(publisher)"
        address = !isempty(doi_link(r.doi)) ? doi_link(r.doi) :
                  isempty(r.url) ? "" : kind == "misc" && !isempty(r.accessed) ? "Retrieved $(spelled_date(r.accessed)), from $(r.url)" : r.url
        return apa_reference(apa_authors([apa_name(a, orgs) for a in json_list(r.authors)]), isempty(date) ? "n.d." : apa_date(date; day = kind == "article" && r.type != "article"),
                             what, where, address)
    end
    authors = apa_authors(apa_name.(json_list(p.authors)))
    r = record_row(kb, id)
    if r !== nothing
        return apa_reference(authors, apa_date(r.happened; day = true), "$(coalesce(p.title, id)) [$(r.label)]", site_title(kb.config),
                             document_link(kb.config, id))
    end
    where = !ismissing(p.journal_ref) ? p.journal_ref : is_arxiv_id(id) ? "arXiv preprint arXiv:$id" : ""
    address = !isempty(doi_link(p.doi)) ? doi_link(p.doi) : is_arxiv_id(id) ? "https://arxiv.org/abs/$id" : document_link(kb.config, id)
    return apa_reference(authors, apa_date(coalesce(p.published, "")), coalesce(p.title, id), where, address)
end

"""
    cite_json(kb, id) -> Dict

How document `id` is cited, for its page's Cite panel: its `@` reference, its citation in prose
([`citation`](@ref)) and its BibTeX entry ([`bib_entry`](@ref)).
"""
cite_json(kb::KB, id::AbstractString) =
    Dict("reference" => "@" * cited_as(id), "citation" => citation(kb, id), "bibtex" => bib_entry(kb, id; docpage = false))
