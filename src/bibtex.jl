# Reading BibTeX and BibLaTeX files as a reference manager writes them (JabRef, say): their entries,
# with `@string` abbreviations expanded and `#` joins made; their LaTeX as plain text; names, dates
# and identifiers read from the fields; and the files an entry links (JabRef's `file` field). A
# person's library reads them (see library_bibtex.jl). What Zemi writes as BibTeX is in bibliography.jl.

"""
An entry of a BibTeX file: its type in lower case (`article`, `book`), its key as written, its fields
by lower-case name, each as written with abbreviations expanded and joins made (braces and LaTeX
kept), and the line it starts on.
"""
struct BibEntry
    type::String
    key::String
    fields::Dict{String,String}
    line::Int
end

"""
A BibTeX file as read: its entries in order, what JabRef keeps in its comments (`jabref-meta`, by
name: `fileDirectory`, `databaseType`), and what could not be read, each naming its line.
"""
struct BibFile
    entries::Vector{BibEntry}
    meta::Dict{String,String}
    problems::Vector{String}
end

"The month abbreviations BibTeX defines, as numbers."
const BIB_MONTHS = Dict("jan" => "1", "feb" => "2", "mar" => "3", "apr" => "4", "may" => "5", "jun" => "6",
                        "jul" => "7", "aug" => "8", "sep" => "9", "oct" => "10", "nov" => "11", "dec" => "12")

# Where a reading is in a file: its characters, the position, the line of each position, and the
# abbreviations defined so far.
mutable struct BibReader
    c::Vector{Char}
    i::Int
    lines::Vector{Int}
    strings::Dict{String,String}
end

bib_at(r::BibReader) = r.i <= length(r.c) ? r.c[r.i] : '\0'
bib_line(r::BibReader) = r.lines[min(r.i, length(r.lines))]
bib_skip_space!(r::BibReader) = (while r.i <= length(r.c) && isspace(r.c[r.i]); r.i += 1; end)

# A name: an entry's type, a field's, an abbreviation's. BibTeX allows more than letters and digits;
# what a name cannot hold is what ends it.
function bib_name!(r::BibReader)
    start = r.i
    while r.i <= length(r.c) && !(isspace(r.c[r.i]) || r.c[r.i] in ('=', ',', '{', '}', '(', ')', '"', '#', '@'))
        r.i += 1
    end
    return String(r.c[start:r.i-1])
end

# What is within the brace at the position, to its matching brace, which is passed. BibTeX counts
# every brace, a backslash before one or not.
function bib_braced!(r::BibReader)
    r.i += 1
    start, depth = r.i, 1
    while r.i <= length(r.c)
        ch = r.c[r.i]
        depth += ch == '{' ? 1 : ch == '}' ? -1 : 0
        depth == 0 && (r.i += 1; return String(r.c[start:r.i-2]))
        r.i += 1
    end
    error("a brace is not closed")
end

# What is within the quote at the position, to the next quote outside braces, which is passed.
function bib_quoted!(r::BibReader)
    r.i += 1
    start, depth = r.i, 0
    while r.i <= length(r.c)
        ch = r.c[r.i]
        depth += ch == '{' ? 1 : ch == '}' ? -1 : 0
        ch == '"' && depth == 0 && (r.i += 1; return String(r.c[start:r.i-2]))
        r.i += 1
    end
    error("a quote is not closed")
end

# What is within the parenthesis at the position, to the next closing one, which is passed.
function bib_parenthesized!(r::BibReader)
    start = r.i + 1
    r.i = something(findnext(==(')'), r.c, start), length(r.c)) + 1
    return String(r.c[start:r.i-2])
end

# A field's value: braced, quoted, a number or an abbreviation, or several joined by `#`.
function bib_value!(r::BibReader)
    io = IOBuffer()
    while true
        bib_skip_space!(r)
        ch = bib_at(r)
        if ch == '{'
            print(io, bib_braced!(r))
        elseif ch == '"'
            print(io, bib_quoted!(r))
        elseif isdigit(ch)
            start = r.i
            while isdigit(bib_at(r)); r.i += 1; end
            print(io, String(r.c[start:r.i-1]))
        else
            name = bib_name!(r)
            isempty(name) && error("a field has no value")
            n = lowercase(name)
            print(io, get(r.strings, n, get(BIB_MONTHS, n, name)))
        end
        bib_skip_space!(r)
        bib_at(r) == '#' || return String(take!(io))
        r.i += 1
    end
end

# What JabRef keeps in a comment (`@Comment{jabref-meta: fileDirectory:papers;}`), by name, its
# value unescaped.
function bib_meta!(meta::Dict{String,String}, body::AbstractString)
    m = match(r"^\s*jabref-meta:\s*([^:\s]+)\s*:(.*?);?\s*$"s, body)
    m === nothing || (meta[String(m[1])] = replace(String(m[2]), r"\\(.)" => s"\1"))
    return meta
end

"""
    parse_bibtex(text) -> BibFile

Read BibTeX or BibLaTeX `text` (see [`BibFile`](@ref)): each entry, `@string` abbreviations and
BibTeX's month names expanded, values joined by `#`, and either kind of delimiter (`{…}` or `(…)`).
Text between entries is comment, as BibTeX takes it; `@preamble` is passed over. An entry that cannot
be read is left out and named among the problems, and reading goes on at the next.
"""
function parse_bibtex(text::AbstractString)
    c = collect(chopprefix(String(text), "﻿"))
    nl = c .== '\n'
    lines = isempty(c) ? [1] : 1 .+ cumsum(nl) .- nl
    r = BibReader(c, 1, lines, Dict{String,String}())
    entries, meta, problems = BibEntry[], Dict{String,String}(), String[]
    while true
        at = findnext(==('@'), r.c, r.i)
        at === nothing && break
        r.i = at + 1
        line = bib_line(r)
        type = lowercase(bib_name!(r))
        isempty(type) && continue
        bib_skip_space!(r)
        open = bib_at(r)
        open in ('{', '(') || continue                       # an `@` in a comment, say
        close = open == '{' ? '}' : ')'
        try
            if type == "comment"
                bib_meta!(meta, open == '{' ? bib_braced!(r) : bib_parenthesized!(r))
                continue
            end
            r.i += 1
            if type == "preamble"
                bib_value!(r)
            elseif type == "string"
                bib_skip_space!(r)
                name = lowercase(bib_name!(r))
                bib_skip_space!(r)
                bib_at(r) == '=' || error("an abbreviation has no `=`")
                r.i += 1
                r.strings[name] = bib_value!(r)
            else
                bib_skip_space!(r)
                start = r.i
                while r.i <= length(r.c) && !(r.c[r.i] in (',', close)) && !isspace(r.c[r.i]); r.i += 1; end
                key = String(r.c[start:r.i-1])
                isempty(key) && error("an entry has no key")
                fields = Dict{String,String}()
                while true
                    bib_skip_space!(r)
                    ch = bib_at(r)
                    ch == ',' && (r.i += 1; continue)
                    ch == close && break
                    ch == '\0' && error("entry $key is not closed")
                    name = lowercase(bib_name!(r))
                    isempty(name) && error("entry $key has a field with no name")
                    bib_skip_space!(r)
                    bib_at(r) == '=' || error("field $name of entry $key has no `=`")
                    r.i += 1
                    fields[name] = bib_value!(r)
                end
                push!(entries, BibEntry(type, key, fields, line))
            end
            bib_skip_space!(r)
            bib_at(r) == close && (r.i += 1)
        catch e
            e isa ErrorException || rethrow()
            push!(problems, "Line $line: $(e.msg)")
            r.i = at + 1                                     # read on from the next `@`
        end
    end
    return BibFile(entries, meta, problems)
end

# ── LaTeX as plain text ───────────────────────────────────────────────────────────────────────────

"The accents LaTeX writes with a command, as the combining characters they are."
const LATEX_ACCENTS = Dict('\'' => '́', '`' => '̀', '^' => '̂', '"' => '̈', '~' => '̃',
                           '=' => '̄', '.' => '̇', 'u' => '̆', 'v' => '̌', 'H' => '̋',
                           'c' => '̧', 'k' => '̨', 'r' => '̊', 'd' => '̣', 'b' => '̱')

"The LaTeX commands that are a character or a word, as it."
const LATEX_SYMBOLS = Dict(
    "ss" => "ß", "o" => "ø", "O" => "Ø", "ae" => "æ", "AE" => "Æ", "oe" => "œ", "OE" => "Œ", "aa" => "å", "AA" => "Å",
    "l" => "ł", "L" => "Ł", "i" => "ı", "j" => "ȷ", "dh" => "ð", "DH" => "Ð", "th" => "þ", "TH" => "Þ", "ng" => "ŋ", "NG" => "Ŋ",
    "textendash" => "–", "textemdash" => "—", "textquoteleft" => "‘", "textquoteright" => "’", "textquotedblleft" => "“",
    "textquotedblright" => "”", "ldots" => "…", "dots" => "…", "textellipsis" => "…", "S" => "§", "P" => "¶",
    "copyright" => "©", "textregistered" => "®", "texttrademark" => "™", "textdegree" => "°", "pounds" => "£", "euro" => "€",
    "textbackslash" => "\\", "textasciitilde" => "~", "textunderscore" => "_", "textbar" => "|", "textless" => "<",
    "textgreater" => ">", "LaTeX" => "LaTeX", "TeX" => "TeX", "BibTeX" => "BibTeX", "textperiodcentered" => "·",
    "times" => "×", "pm" => "±", "mp" => "∓", "deg" => "°", "infty" => "∞", "sim" => "∼", "approx" => "≈", "propto" => "∝",
    "leq" => "≤", "geq" => "≥", "le" => "≤", "ge" => "≥", "neq" => "≠", "ne" => "≠", "to" => "→", "rightarrow" => "→",
    "leftarrow" => "←", "cdot" => "·", "partial" => "∂", "nabla" => "∇", "hbar" => "ħ", "ell" => "ℓ",
    "alpha" => "α", "beta" => "β", "gamma" => "γ", "delta" => "δ", "epsilon" => "ϵ", "varepsilon" => "ε", "zeta" => "ζ",
    "eta" => "η", "theta" => "θ", "vartheta" => "ϑ", "iota" => "ι", "kappa" => "κ", "lambda" => "λ", "mu" => "μ", "nu" => "ν",
    "xi" => "ξ", "pi" => "π", "varpi" => "ϖ", "rho" => "ρ", "varrho" => "ϱ", "sigma" => "σ", "varsigma" => "ς", "tau" => "τ",
    "upsilon" => "υ", "phi" => "ϕ", "varphi" => "φ", "chi" => "χ", "psi" => "ψ", "omega" => "ω", "Gamma" => "Γ",
    "Delta" => "Δ", "Theta" => "Θ", "Lambda" => "Λ", "Xi" => "Ξ", "Pi" => "Π", "Sigma" => "Σ", "Upsilon" => "Υ",
    "Phi" => "Φ", "Psi" => "Ψ", "Omega" => "Ω", "quad" => " ", "qquad" => " ", "enspace" => " ", "thinspace" => " ")

# A command's argument from position `j`: a braced group's content, another command, or one
# character; with the position after it.
function latex_arg(c::Vector{Char}, j::Int)
    while j <= length(c) && c[j] == ' '; j += 1; end
    j > length(c) && return ("", j)
    if c[j] == '{'
        depth, k = 0, j
        while k <= length(c)
            depth += c[k] == '{' ? 1 : c[k] == '}' ? -1 : 0
            depth == 0 && return (String(c[j+1:k-1]), k + 1)
            k += 1
        end
        return (String(c[j+1:end]), length(c) + 1)
    elseif c[j] == '\\' && j < length(c) && isletter(c[j+1])
        k = j + 1
        while k <= length(c) && isletter(c[k]); k += 1; end
        return (String(c[j:k-1]), k)
    end
    return (string(c[j]), j + 1)
end

# A letter with an accent: the dotless i and j take one as i and j.
function latex_accent(io::IO, base::AbstractString, mark::Char)
    b = latex_plain(base)
    isempty(b) && return print(io, mark)
    f = first(b)
    print(io, f == 'ı' ? 'i' : f == 'ȷ' ? 'j' : f, mark, chop(b; head = 1, tail = 0))
end

function latex_plain(s::AbstractString)
    c = collect(s)
    io = IOBuffer()
    i = 1
    while i <= length(c)
        ch = c[i]
        nxt = i < length(c) ? c[i+1] : '\0'
        if ch == '{' || ch == '}' || ch == '$'
            i += 1
        elseif ch == '~'
            print(io, ' '); i += 1
        elseif ch == '-' && nxt == '-'
            dashes = i + 2 <= length(c) && c[i+2] == '-'
            print(io, dashes ? '—' : '–'); i += dashes ? 3 : 2
        elseif ch == '`'
            print(io, nxt == '`' ? '“' : '‘'); i += nxt == '`' ? 2 : 1
        elseif ch == '\'' && nxt == '\''
            print(io, '”'); i += 2
        elseif ch == '\\' && isletter(nxt)
            j = i + 1
            while j <= length(c) && isletter(c[j]); j += 1; end
            name = String(c[i+1:j-1])
            if length(name) == 1 && haskey(LATEX_ACCENTS, name[1]) && !haskey(LATEX_SYMBOLS, name)
                arg, i = latex_arg(c, j)
                latex_accent(io, arg, LATEX_ACCENTS[name[1]])
            elseif haskey(LATEX_SYMBOLS, name)
                print(io, LATEX_SYMBOLS[name])
                while j <= length(c) && c[j] == ' '; j += 1; end          # TeX takes the spaces after a command word
                j + 1 <= length(c) && c[j] == '{' && c[j+1] == '}' && (j += 2)
                i = j
            elseif name == "href"
                _, k = latex_arg(c, j)
                text, i = latex_arg(c, k)
                print(io, latex_plain(text))
            else
                # Any other command: its argument's text where it has one (`\emph{…}`, `\textsc{…}`), else nothing.
                k = j
                while k <= length(c) && c[k] == ' '; k += 1; end
                if k <= length(c) && c[k] == '{'
                    arg, i = latex_arg(c, k)
                    print(io, latex_plain(arg))
                else
                    i = k
                end
            end
        elseif ch == '\\' && haskey(LATEX_ACCENTS, nxt)
            arg, i = latex_arg(c, i + 2)
            latex_accent(io, arg, LATEX_ACCENTS[nxt])
        elseif ch == '\\'
            nxt in ('\\', ',', ';', ':', '!', ' ', '>') ? print(io, ' ') : nxt == '-' || nxt == '/' ? nothing : print(io, nxt)
            i += 2
        else
            print(io, ch); i += 1
        end
    end
    return String(take!(io))
end

"""
    bib_plain(s) -> String

A field's value as plain text: LaTeX's accents as accented letters (`{\\"o}`, `\\'{e}`), its commands for
characters as them (`\\ss`, `\\&`, `\\alpha`), a command's argument as its text (`\\emph{…}`), braces
and math dollars dropped, `~` a space, `--` and `---` dashes, and runs of white space one space.
"""
bib_plain(s::AbstractString) = String(strip(replace(Base.Unicode.normalize(latex_plain(s), :NFC), r"\s+" => " ")))

# ── Names, dates, identifiers ─────────────────────────────────────────────────────────────────────

# `s` split where `sep` is found outside braces.
function bib_split(s::AbstractString, sep::Regex)
    out, depth, start = String[], 0, 1
    i = firstindex(s)
    while i <= ncodeunits(s)
        ch = s[i]
        depth += ch == '{' ? 1 : ch == '}' ? -1 : 0
        if depth == 0
            m = match(sep, s, i)
            if m !== nothing && m.offset == i
                push!(out, s[start:prevind(s, i)])
                start = i + ncodeunits(m.match)
                i = start
                continue
            end
        end
        i = nextind(s, i)
    end
    push!(out, s[start:end])
    return out
end

# Whether `s` is one braced group, `{World Health Organization}`.
function bib_one_group(s::AbstractString)
    (startswith(s, '{') && endswith(s, '}')) || return false
    depth = 0
    for (k, ch) in enumerate(s)
        depth += ch == '{' ? 1 : ch == '}' ? -1 : 0
        depth == 0 && k < length(s) && return false
    end
    return true
end

"""
    bib_names(value) -> Vector{@NamedTuple{name::String, organization::Bool}}

The people of an `author` or `editor` field, in order, each as Zemi keeps a name (`Ada Lovelace`):
names joined by `and`, each written `First Last`, `Last, First` or `Last, Jr, First`; a name that is
one braced group (`{World Health Organization}`) an organization; `others` kept, as it ends the list.
"""
function bib_names(value::AbstractString)
    out = @NamedTuple{name::String, organization::Bool}[]
    for part in bib_split(strip(value), r"\s+and\s+"i)
        p = strip(part)
        isempty(p) && continue
        if bib_one_group(p)
            push!(out, (; name = bib_plain(p), organization = true))
            continue
        end
        pieces = strip.(bib_split(p, r","))
        name = length(pieces) == 1 ? bib_plain(p) :
               length(pieces) == 2 ? bib_plain(pieces[2] * " " * pieces[1]) :
               bib_plain(pieces[3] * " " * pieces[1] * " " * pieces[2])
        isempty(name) || push!(out, (; name, organization = false))
    end
    return out
end

"The months by the first three letters of their names, as numbers."
const MONTH_ABBREVIATIONS = Dict(lowercase(first(m, 3)) => i for (i, m) in enumerate(MONTHS))

"""
    bib_date(fields) -> String

An entry's date, as precisely as it gives it (`2021`, `2021-10`, `2021-10-29`): BibLaTeX's `date`
(the start of a range), else `year` with `month` (a number or a name) and `day`. `""` for none.
"""
function bib_date(fields::AbstractDict)
    d = bib_plain(get(fields, "date", ""))
    m = match(r"^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?", d)
    m === nothing || return join(filter(!isnothing, collect(m.captures)), "-")
    y = match(r"\d{4}", bib_plain(get(fields, "year", "")))
    y === nothing && return ""
    month = lowercase(bib_plain(get(fields, "month", "")))
    n = something(tryparse(Int, month), get(MONTH_ABBREVIATIONS, first(month, 3), 0))
    1 <= n <= 12 || return String(y.match)
    day = tryparse(Int, bib_plain(get(fields, "day", "")))
    return day === nothing || !(1 <= day <= 31) ? string(y.match, "-", lpad(n, 2, '0')) :
           string(y.match, "-", lpad(n, 2, '0'), "-", lpad(day, 2, '0'))
end

"""
    bib_arxiv(fields) -> Union{String,Nothing}

The arXiv paper an entry is, without its version: its `eprint` where `archivePrefix` (or BibLaTeX's
`eprinttype`) is arXiv, or names none and it is an arXiv id; else an arXiv address, an `arXiv:` reference
or arXiv's DOI in its `url`, `doi`, `journal`, `note` or `howpublished`. `nothing` for none.
"""
function bib_arxiv(fields::AbstractDict)
    f(k) = bib_plain(get(fields, k, ""))
    prefix = lowercase(isempty(f("archiveprefix")) ? f("eprinttype") : f("archiveprefix"))
    eprint = f("eprint")
    if !isempty(eprint) && (prefix == "arxiv" || isempty(prefix))
        a = parse_arxiv_id(eprint)
        a === nothing || return a.id
    end
    for k in ("url", "doi", "journal", "journaltitle", "note", "howpublished", "eprint")
        v = f(k)
        isempty(v) && continue
        a = parse_arxiv_id(v)
        a === nothing || return a.id
        m = match(Regex("arxiv:\\s*$ARXIV_ID", "i"), v)
        m === nothing || return String(m[1])
    end
    return nothing
end

"An entry's DOI, normalized (see [`normalize_doi`](@ref)): its `doi` field, else a `doi.org` address in its `url`. `nothing` for none."
function bib_doi(fields::AbstractDict)
    d = parse_doi(bib_plain(get(fields, "doi", "")))
    d === nothing || return d
    u = bib_plain(get(fields, "url", ""))
    return occursin(r"^https?://(?:dx\.)?doi\.org/"i, u) ? parse_doi(u) : nothing
end

# `s` split where `sep` is not escaped with a backslash.
function bib_split_unescaped(s::AbstractString, sep::Char)
    out, io, esc = String[], IOBuffer(), false
    for ch in s
        if esc
            print(io, '\\', ch); esc = false
        elseif ch == '\\'
            esc = true
        elseif ch == sep
            push!(out, String(take!(io)))
        else
            print(io, ch)
        end
    end
    esc && print(io, '\\')
    push!(out, String(take!(io)))
    return out
end

bib_unescape(s::AbstractString) = replace(s, r"\\(.)" => s"\1")

"""
    bib_files(value) -> Vector{String}

The PDFs a `file` field links, as written: JabRef's form, `description:path:type` for each file,
separated by `;`, with `\\:`, `\\;` and `\\\\` escaped (`:papers/hale2024.pdf:PDF`); or paths alone,
separated by `;`, as other managers write it. Files of other types are left out.
"""
function bib_files(value::AbstractString)
    out = String[]
    for item in bib_split_unescaped(replace(value, raw"$\backslash$" => "\\\\"), ';')
        parts = bib_unescape.(bib_split_unescaped(item, ':'))
        path, type = length(parts) >= 3 ? (join(parts[2:end-1], ":"), parts[end]) :
                     length(parts) == 2 ? (endswith(lowercase(parts[2]), ".pdf") ? (parts[2], "") : (parts[1], parts[2])) :
                     (parts[1], "")
        path = strip(path)
        isempty(path) && continue
        (lowercase(strip(type)) == "pdf" || endswith(lowercase(path), ".pdf")) && push!(out, path)
    end
    return out
end
