# A paper's references: its reference list split into entries, the identifiers each names (arXiv
# id, DOI), and the papers of the knowledge base each cites. PDF text gives the list as blocks that
# may hold many entries or a part of one, so the entries are found by their numbering, or, for an
# author–year list, by where an entry starts.

"""
    Reference

One entry of a reference list: its `label` (`"12"` for `[12]`, empty in an author–year list), its
`text`, and the `arxiv` id and `doi` it names, if any. `cites` is the id of the paper of the
knowledge base it refers to, `cites_title` that paper's title, and `how` what matched (`:arxiv`,
`:doi`, `:title` or `:journal`).
"""
Base.@kwdef struct Reference
    label::String = ""
    text::String
    arxiv::Union{String,Nothing} = nothing
    doi::Union{String,Nothing} = nothing
    cites::Union{String,Nothing} = nothing
    cites_title::String = ""
    how::Union{Symbol,Nothing} = nothing
end

"""
    split_references(blocks) -> Vector{Reference}

The entries of a reference list given as the text of its blocks. A list numbered `[1]`, `[2]`, …
or `1.`, `2.`, … is split at its numbers, taking a number only where it continues the sequence (so a
`[12]` cited inside an entry does not split it). Otherwise it is an author–year list: an entry
starts where a block starts with an author (`Surname, I.`, `I. Surname`, or a dash for the same
authors), other blocks continue it, and a block holding several entries is split where a sentence
ending an entry (one with a year) is followed by an author.
"""
function split_references(blocks::AbstractVector{<:AbstractString})
    isempty(blocks) && return Reference[]
    text = join_lines(blocks)
    for marker in NUMBERING
        refs = numbered(text, marker)
        refs === nothing || return refs
    end
    entries = String[]
    for b in blocks
        if isempty(entries) || starts_entry(b)
            push!(entries, strip(b))
        else
            entries[end] = join_lines([entries[end], b])
        end
    end
    return [reference("", e) for entry in entries for e in split_entries(entry)]
end

# `[12]` anywhere; `12.` at the start of a line; `12.` after the end of a sentence.
const NUMBERING = (r"\[(\d{1,3})\]", r"(?:^|\n)[ \t]*(\d{1,3})[.)]?[ \t]+(?=\S)",
                   r"(?:^|(?<=[.)\]])\s+)(\d{1,3})\.\s+(?=\p{Lu})")

# Blocks joined into one text, a word hyphenated across a line break joined back.
function join_lines(blocks)
    out = ""
    for b in strip.(blocks)
        out = isempty(out) ? b :
              endswith(out, "-") && !isempty(b) && islowercase(first(b)) ? chop(out) * b : out * "\n" * b
    end
    return String(out)
end

function numbered(text::AbstractString, marker::Regex)
    found = collect(eachmatch(marker, text))
    picked = RegexMatch[]
    for m in found
        n = parse(Int, m.captures[1])
        n == (isempty(picked) ? 1 : parse(Int, last(picked).captures[1]) + 1) && push!(picked, m)
    end
    length(picked) >= 2 || return nothing
    ends = [[m.offset - 1 for m in picked[2:end]]; ncodeunits(text)]
    return [reference(m.captures[1], text[nextind(text, m.offset + ncodeunits(m.match) - 1):prevind(text, e + 1)])
            for (m, e) in zip(picked, ends)]
end

const NAME_PARTICLE = raw"(?:(?:van|von|de|der|del|da|di|le|la|du)\s+)*"
# Words of journal names that look like a surname after an initial ("J. Comp. Phys.").
const JOURNAL_WORDS = Set(split("""Phys Physics Plas Comp Comput Math Mech Fluid Fluids Plasma Plasmas Nucl Rev Lett Sci Res
    Appl Astron Astrophys Proc Soc Fusion Chem Theor Stat Eng Acad Nat Mod Opt Geophys Space Sol Mon Not Ann Inst Int
    Commun Control Technol Energy Comput Numer Anal Struct Mat Mater Ser Conf Bull Am Eur Jpn Chin Can Lond Roy""", r"\s+"))
const ENTRY_START = Regex("^\\s*(?:[—–]|-{2,}|$(NAME_PARTICLE)\\p{Lu}[\\p{L}'’`\\-]+,\\s*\\p{Lu}|\\p{Lu}\\.\\s*(?:\\p{Lu}\\.\\s*)*\\p{Lu}[\\p{L}'’\\-]+(?:,|\\s+et\\s+al|\\s+and\\s|\\s*&))")
starts_entry(b) = occursin(ENTRY_START, b)

# Where, within a block, a sentence ends and an author begins.
const AUTHOR_NEXT = Regex("(?<=[.)])\\s+(?=$(NAME_PARTICLE)(\\p{Lu}[\\p{L}'’\\-]+,\\s*\\p{Lu}|" *
                          "\\p{Lu}\\.(?:\\s?-?\\p{Lu}\\.)*\\s?\\p{Lu}[\\p{L}'’\\-]+(?:[.,]|\\s+and\\s|\\s+et\\s+al|\\s*&)))")
const YEAR = r"\b(?:1[89]|20)\d\d[a-z]?\b"

"An author–year entry split where it holds several: at each author following an entry with a year."
function split_entries(entry::AbstractString)
    parts, start = String[], 1
    for m in eachmatch(AUTHOR_NEXT, entry)
        surname = match(r"(\p{Lu}[\p{L}'’\-]+)(?:,|\.|\s+and|\s+et|\s*&)", m.captures[1])
        (surname === nothing || surname.captures[1] in JOURNAL_WORDS) && continue
        head = entry[start:prevind(entry, m.offset)]
        occursin(YEAR, head) || continue
        push!(parts, strip(head))
        start = m.offset + ncodeunits(m.match)
    end
    push!(parts, strip(entry[start:end]))
    return filter(!isempty, parts)
end

const ARXIV_IN_REF = Regex("(?:arxiv[:\\s]*|arxiv\\.org/(?:abs|pdf)/)$ARXIV_ID(?:v\\d+)?", "i")
const DOI_IN_REF = r"\b(10\.\d{4,9}/\s?[^\s,;\"<>]+)"

function reference(label, text)
    text = strip(replace(text, r"\s+" => " "))
    a = match(ARXIV_IN_REF, text)
    return Reference(; label = String(label), text = String(text), arxiv = a === nothing ? nothing : String(a.captures[1]),
                     doi = reference_doi(text))
end

# A DOI the PDF broke across lines reaches here with a space at the break. No DOI ends in a
# separator, so while it does and the next word goes on with a digit or a lower-case letter, that
# word is the rest of it.
function reference_doi(text::AbstractString)
    d = match(DOI_IN_REF, text)
    d === nothing && return nothing
    doi = replace(d.captures[1], " " => "")
    rest = SubString(text, d.offset + ncodeunits(d.match))
    while occursin(r"[/.\-_]$", doi) && (m = match(r"^\s+([\p{Ll}\d][^\s,;\"<>]*)", rest)) !== nothing
        doi *= m[1]
        rest = SubString(rest, ncodeunits(m.match) + 1)
    end
    doi = rstrip(doi, [')', ']'])
    endswith(doi, ".") && (doi = chop(doi))                    # a sentence's full stop
    # Still ending in a separator, or with only a character or two after the prefix, the rest of it
    # is not in the text (a line the PDF's text lost): half a DOI would match other halves.
    (occursin(r"[/.\-_]$", doi) || length(split(doi, '/'; limit = 2)[2]) <= 2) && return nothing
    return String(doi)
end

# ── Matching references to the knowledge base ────────────────────────────────────────────────────

"""
    ReferenceIndex

The knowledge base's papers as references find them: by arXiv id, by DOI, by title (each title
under its least common word, to look up few), and by journal reference (its numbers and the first
author's surname).
"""
struct ReferenceIndex
    title::Dict{String,String}                            # id => title
    arxiv::Dict{String,String}
    doi::Dict{String,String}
    titles::Dict{String,Vector{Tuple{String,String}}}     # rare word => (title, id)
    journals::Vector{Tuple{Set{Int},String,String}}       # (numbers, first author's surname, id)
end

function ReferenceIndex(kb::KB)
    rows = query(kb, "SELECT doc_id, title, doi, journal_ref, authors FROM papers WHERE $(literature_sql())")
    arxiv = Dict(lowercase(r.doc_id) => r.doc_id for r in rows if is_arxiv_id(r.doc_id))
    doi = Dict(normalize_doi(r.doi) => r.doc_id for r in rows if !ismissing(r.doi) && !isempty(r.doi))
    titled = [(normalize_title(r.title), r.doc_id) for r in rows if !ismissing(r.title)]
    titled = [t for t in titled if length(split(t[1])) >= 5 || length(t[1]) >= 30]   # short titles match too much
    counts = Dict{String,Int}()
    for (t, _) in titled, w in unique(split(t))
        counts[w] = get(counts, w, 0) + 1
    end
    titles = Dict{String,Vector{Tuple{String,String}}}()
    for (t, id) in titled
        long = [w for w in split(t) if length(w) > 3]
        w = argmin(w -> (counts[w], -length(w)), isempty(long) ? split(t) : long)
        push!(get!(Vector{Tuple{String,String}}, titles, w), (t, id))
    end
    journals = Tuple{Set{Int},String,String}[]
    for r in rows
        (ismissing(r.journal_ref) || isempty(json_list(r.authors))) && continue
        numbers = Set(parse(Int, m.match) for m in eachmatch(r"\d+", r.journal_ref))
        surname = last(split(normalize_title(first(json_list(r.authors)))))
        # A volume, a page and a year at least, or the match would be too loose.
        length(numbers) >= 3 && any(n -> 1900 <= n <= 2100, numbers) && push!(journals, (numbers, surname, r.doc_id))
    end
    title = Dict(r.doc_id => coalesce(r.title, r.doc_id) for r in rows)
    return ReferenceIndex(title, arxiv, doi, titles, journals)
end

"""
    cited_paper(index, ref; citing) -> Union{Nothing,Tuple{String,Symbol}}

The knowledge base's paper `ref` refers to and what matched, trying its arXiv id, its DOI, a title
of the knowledge base within its text, then a journal reference's numbers with its first author.
The citing paper itself is never the answer.
"""
function cited_paper(ix::ReferenceIndex, ref::Reference; citing::AbstractString = "")
    found(id, how) = id === nothing || id == citing ? nothing : (id, how)
    if ref.arxiv !== nothing
        r = found(get(ix.arxiv, lowercase(ref.arxiv), nothing), :arxiv)
        r === nothing || return r
    end
    if ref.doi !== nothing
        r = found(get(ix.doi, normalize_doi(ref.doi), nothing), :doi)
        r === nothing || return r
    end
    text = " " * normalize_title(ref.text) * " "
    words = Set(split(text))
    for w in words, (t, id) in get(ix.titles, w, ())
        id == citing && continue
        for r in findall(" $t ", text)
            # A title followed by a volume, page or article number is a journal's name: the venue, not
            # the paper cited.
            occursin(r"^\s*(vol|volume|v|no|p|pp|art|article)?\s*\d", text[last(r):end]) || return (id, :title)
        end
    end
    numbers = Set(parse(Int, m.match) for m in eachmatch(r"\d+", ref.text))
    for (ns, surname, id) in ix.journals
        id != citing && surname in words && issubset(ns, numbers) && return (id, :journal)
    end
    return nothing
end

"""
    paper_references(kb, doc_id; index = ReferenceIndex(kb)) -> Vector{Reference}

A paper's reference list, each entry with the paper of the knowledge base it cites, if any.
"""
function paper_references(kb::KB, doc_id::AbstractString; index::ReferenceIndex = ReferenceIndex(kb))
    blocks = String[coalesce(r.text, "") for r in query(kb, """SELECT text FROM blocks WHERE paper_id = ? AND kind = 'reference' ORDER BY ord""",
                                   (paper_id(kb, doc_id),))]
    return map(split_references(blocks)) do r
        hit = cited_paper(index, r; citing = doc_id)
        hit === nothing ? r : Reference(; r.label, r.text, r.arxiv, r.doi, cites = hit[1], cites_title = index.title[hit[1]], how = hit[2])
    end
end

"""
    citing_papers(kb, doc_id; index = ReferenceIndex(kb)) -> Vector{NamedTuple}

The knowledge base's papers whose references cite `doc_id` (see [`paper_references`](@ref)), each
`(; doc_id, title, label)` with the label it is cited under. Only papers with a reference naming its
arXiv id, DOI or first author's surname are checked.
"""
function citing_papers(kb::KB, doc_id::AbstractString; index::ReferenceIndex = ReferenceIndex(kb))
    p = paper_row(kb, doc_id)
    terms = String[]
    is_arxiv_id(doc_id) && push!(terms, doc_id)
    ismissing(p.doi) || push!(terms, lowercase(p.doi))
    authors = json_list(p.authors)
    isempty(authors) || push!(terms, lowercase(last(split(first(authors)))))
    isempty(terms) && return NamedTuple[]
    like = join(("lower(b.text) LIKE ?" for _ in terms), " OR ")
    candidates = [String(r.id) for r in query(kb, """SELECT DISTINCT p.doc_id AS id FROM blocks b JOIN papers p ON p.id = b.paper_id
                                                  WHERE b.kind = 'reference' AND p.doc_id != ? AND ($like) ORDER BY p.doc_id""",
                                              (doc_id, ("%" * lowercase(t) * "%" for t in terms)...))]
    out = NamedTuple[]
    for c in candidates
        refs = paper_references(kb, c; index)
        i = findfirst(r -> r.cites == doc_id, refs)
        i === nothing || push!(out, (; doc_id = c, title = coalesce(paper_row(kb, c).title, c), label = refs[i].label))
    end
    return out
end
