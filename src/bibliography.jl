# BibTeX for the knowledge base's documents: a study's references (see study.jl), and the whole
# knowledge base as one file, for a reference manager or a LaTeX document.

# A document's key in a bibliography, kept once given (see `cite_keys!`).
migration!(24, ["ALTER TABLE papers ADD COLUMN cite_key TEXT",
                "CREATE UNIQUE INDEX papers_cite_key ON papers (cite_key) WHERE cite_key IS NOT NULL"])

"A paper on arXiv's key: `arXiv:` and its id, an old-style id's `/` as `_`."
arxiv_key(id::AbstractString) = "arXiv:" * replace(id, '/' => '_')

"""
    cite_key(kb, id) -> String

The key document `id` is cited by, in BibTeX, Slate's `[@key]` and Typst: `arXiv:` and its id for a
paper on arXiv; for any other document a short one a person would write, given the first time it is
asked for and kept (see [`cite_keys!`](@ref)); the id of a document the knowledge base does not have.
"""
cite_key(kb::KB, id::AbstractString) = is_arxiv_id(id) ? arxiv_key(id) : cite_keys!(kb, [id])[id]

"""
    cite_keys!(kb, ids) -> Dict{String,String}

The keys of documents `ids` (see [`cite_key`](@ref)), giving one to each that has none yet: a record
its title, as a note is named (`heron-migration`); any other document the first author's surname, the
year and the first word of its title (`lovelace2024engines`), or its title where it names no author.
A key another document has takes the year, then `-2`, `-3`. A key is kept once given, so a title
edited later does not change it under the notebooks citing it.
"""
function cite_keys!(kb::KB, ids)
    out = Dict{String,String}()
    rest = String[]
    for id in ids
        is_arxiv_id(id) ? (out[String(id)] = arxiv_key(id)) : push!(rest, String(id))
    end
    isempty(rest) && return out
    stored = Dict{String,String}(String(r.doc_id) => String(r.cite_key)
                                 for r in query(kb, "SELECT doc_id, cite_key FROM papers WHERE cite_key IS NOT NULL"))
    known = Set{String}(String(r.doc_id) for r in query(kb, "SELECT doc_id FROM papers"))
    todo = [id for id in unique(rest) if !haskey(stored, id) && id in known]
    if !isempty(todo)
        transaction(kb) do
            taken = Set(values(stored))
            for id in todo
                base, year = key_base(kb, id)
                key = free_key(isempty(base) ? id : base, year, taken)
                execute!(kb, "UPDATE papers SET cite_key = ? WHERE doc_id = ?", (key, id))
                push!(taken, key)
                stored[id] = key
            end
        end
    end
    for id in rest
        out[id] = get(stored, id, id)
    end
    return out
end

"""
    cited_document(kb, key) -> Union{String,Nothing}

The document a citation key names (see [`cite_key`](@ref)): a paper by `arXiv:<id>`, else the
document given that key here; `nothing` for none.
"""
function cited_document(kb::KB, key::AbstractString)
    m = match(r"^arxiv:(.+)$"i, key)
    m === nothing || return ismissing(paper_id(kb, String(m[1]))) ? nothing : String(m[1])
    r = query(kb, "SELECT doc_id FROM papers WHERE cite_key = ?", (String(key),))
    return isempty(r) ? nothing : String(first(r).doc_id)
end

"""
    cite_label(kb, id) -> String

Document `id` as a citation in prose names it: its authors' surnames and its year (`Hale 2024`, `Hale
and Bea 2024`, `Hale et al. 2024`), or with no authors (a record, say) its title, cut short, and year.
"""
function cite_label(kb::KB, id::AbstractString)
    p = first(query(kb, "SELECT title, authors, published, kind FROM papers WHERE doc_id = ?", (id,)))
    year = key_base(kb, id)[2]
    authors = json_list(p.authors)
    surname(a) = (a = strip(a); occursin(',', a) ? strip(first(split(a, ','))) : last(split(a)))
    who = if p.kind == RECORD.name || isempty(authors)
        words = split(String(coalesce(p.title, id)))
        length(words) <= 5 ? join(words, " ") : join(first(words, 4), " ") * " …"
    else
        length(authors) == 1 ? surname(authors[1]) : length(authors) == 2 ? "$(surname(authors[1])) and $(surname(authors[2]))" :
                               "$(surname(authors[1])) et al."
    end
    return isempty(year) ? who : (p.kind == RECORD.name || isempty(authors) ? "$who, $year" : "$who $year")
end

"Words a key is not made from: those a title starts with that say nothing of it."
const KEY_SKIP_WORDS = Set(["a", "an", "the", "on", "of", "in", "for", "and", "to", "with", "from", "at", "by", "towards", "toward"])

# Text as a key's part: its letters and digits, accents dropped, words joined by `-`; `n` characters at most.
key_slug(s::AbstractString, n::Integer = typemax(Int)) =
    String(rstrip(first(slugify(Base.Unicode.normalize(String(s); stripmark = true)), n), '-'))

"""
    key_base(kb, id) -> (base, year)

What document `id`'s key is made from, before a clash is settled (see [`cite_keys!`](@ref)), and its
year.
"""
function key_base(kb::KB, id::AbstractString)
    p = first(query(kb, "SELECT title, authors, published, kind FROM papers WHERE doc_id = ?", (id,)))
    title = String(coalesce(p.title, ""))
    if p.kind == RECORD.name
        r = record_row(kb, id)
        return key_slug(title, 40), first(String(r === nothing ? coalesce(p.published, "") : coalesce(r.happened, "")), 4)
    end
    year = first(String(coalesce(p.published, "")), 4)
    authors = json_list(p.authors)
    words = filter(w -> !(w in KEY_SKIP_WORDS), split(key_slug(title), '-'; keepempty = false))
    isempty(authors) && return key_slug(join(first(words, 4), " "), 40), year
    a = strip(first(authors))
    surname = occursin(',', a) ? first(split(a, ',')) : last(split(a))
    return replace(key_slug(surname), "-" => "") * year * (isempty(words) ? "" : first(words)), year
end

"`base`, or where another document has it, `base-year` (unless the year is in it), then `base-2`, `base-3`…"
function free_key(base::AbstractString, year::AbstractString, taken)
    base in taken || return String(base)
    with_year = isempty(year) || occursin(year, base) ? "" : "$base-$year"
    isempty(with_year) || with_year in taken || return with_year
    for n in 2:10_000
        k = "$base-$n"
        k in taken || return k
    end
    error("No free key for $base")
end

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
    bib_entry(kb, id; pages = "generated/kb/", docpage = true, key = cite_key(kb, id)) -> String

A document's BibTeX entry, keyed by `key` (see [`cite_key`](@ref)). A paper is an article: its authors, title,
year, arXiv record, DOI, journal (its journal reference, else its arXiv record) and `url` (the arXiv
page). An upload is an article when it has a journal reference, else a `misc`. A record is a `misc`:
its people, title, date, how it was made and `url`, its page on the site. A resource is the entry its
type calls for (see [`resource_bib`](@ref)). With `docpage`, the entry
also names the knowledge base's page for it under the docs source, which the docs site links a
citation to.
"""
function bib_entry(kb::KB, id::AbstractString; pages::AbstractString = "generated/kb/", docpage::Bool = true,
                   key::AbstractString = cite_key(kb, id))
    p = paper_row(kb, id)
    arxiv = is_arxiv_id(id)
    field(k, v) = (ismissing(v) || isempty(string(v))) ? "" : "  $k = {$(v)},\n"
    io = IOBuffer()
    r = record_row(kb, id)
    if r !== nothing
        print(io, "@misc{", key, ",\n")
        print(io, field("author", join(bib_name.(json_list(p.authors)), " and ")))
        print(io, field("title", "{" * bib_escape(coalesce(p.title, id)) * "}"))
        print(io, field("year", first(r.happened, 4)), field("date", first(r.happened, 10)))
        print(io, field("howpublished", bib_escape(r.label)), field("url", document_link(kb.config, id)))
        print(io, "}\n")
        return String(take!(io))
    end
    is_resource(id) && return resource_bib(kb, id; pages, docpage, key)
    # An article, the usual form for a preprint: citation styles print an article's year, and its
    # journal is where it appeared or else its arXiv record.
    print(io, "@", arxiv || !ismissing(p.journal_ref) ? "article" : "misc", "{", key, ",\n")
    print(io, field("author", join(bib_name.(json_list(p.authors)), " and ")))
    print(io, field("title", "{" * bib_escape(coalesce(p.title, id)) * "}"))
    print(io, field("year", first(coalesce(p.published, ""), 4)))
    if arxiv
        print(io, field("eprint", id), field("archivePrefix", "arXiv"), field("primaryClass", p.primary_category))
        print(io, field("url", "https://arxiv.org/abs/$id"))
    end
    journal = !ismissing(p.journal_ref) ? bib_escape(p.journal_ref) : arxiv ? "arXiv preprint arXiv:$id" : missing
    print(io, field("journal", journal), field("doi", p.doi))
    docpage && print(io, docpage_field(kb, id, pages))
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
function resource_bib(kb::KB, id::AbstractString; pages::AbstractString = "generated/kb/", docpage::Bool = true,
                      key::AbstractString = cite_key(kb, id))
    r = resource_row(kb, id)
    field(k, v; escape = true) = isempty(string(v)) ? "" : "  $k = {$(escape ? bib_escape(v) : v)},\n"
    entry = get(RESOURCE_ENTRIES, r.type, "misc")
    entry == "techreport" && isempty(r.publisher) && (entry = "misc")
    date = coalesce(r.published, "")
    io = IOBuffer()
    print(io, "@", entry, "{", key, ",\n")
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
    docpage && print(io, docpage_field(kb, id, pages))
    print(io, "}\n")
    return String(take!(io))
end

"An entry's `docpage` field, or nothing for a document with no page on the site."
docpage_field(kb, id, pages) = (s = document_page_source(kb, id); s === nothing ? "" : "  docpage = {$(pages)$(s)},\n")

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
    named = cite_keys!(kb, ids)
    # Asked for by key: a document's key, or its id.
    keys === nothing || (wanted = Set(keys); ids = filter(id -> named[id] in wanted || id in wanted, ids))
    entries = [bib_entry(kb, id; pages, docpage, key = named[id]) for id in sort(ids; by = id -> named[id])]
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

How document `id` is cited, for its page's Cite panel: its `@` reference, its citation in a notebook
(`[@key]`, see [`cite_key`](@ref)), its citation in prose ([`citation`](@ref)) and its BibTeX entry
([`bib_entry`](@ref)).
"""
cite_json(kb::KB, id::AbstractString) =
    Dict("reference" => "@" * cited_as(id), "cite" => "[@" * cite_key(kb, id) * "]", "citation" => citation(kb, id),
         "bibtex" => bib_entry(kb, id; docpage = false))

"""
    cited_json(kb, caller, key) -> Union{Dict,Nothing}

The document citation key `key` names, as a note's citation links to it: its id, kind, title, authors,
year, label in prose ([`cite_label`](@ref)) and page. `nothing` for a key naming no document `caller`
may see.
"""
function cited_json(kb::KB, caller::Caller, key::AbstractString)
    id = cited_document(kb, key)
    (id === nothing || !document_visible(kb, caller, id)) && return nothing
    p = first(query(kb, "SELECT title, authors, kind FROM papers WHERE doc_id = ?", (id,)))
    return Dict("id" => id, "kind" => String(p.kind), "title" => coalesce(p.title, id),
                "authors" => json_list(p.authors), "year" => key_base(kb, id)[2], "label" => cite_label(kb, id),
                "page" => document_link(kb.config, id))
end
