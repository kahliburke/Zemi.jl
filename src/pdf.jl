# PDF → structured text. MuPDF's structured-text output gives every run of text with its font,
# size and position; from that we rebuild visual lines, split blocks into paragraphs and display
# equations, recognise headings, captions and references, and drop running headers, page
# numbers, the arXiv margin stamp and the text inside figures.

"""
Bump when parsing or chunking changes in a way that should re-parse (and so re-chunk and re-embed)
papers.
"""
const PARSER_VERSION = 4

struct Span
    x0::Float64
    y0::Float64
    x1::Float64
    y1::Float64
    font::String
    size::Float64
    bold::Bool
    italic::Bool
    text::String
end

struct TextLine
    spans::Vector{Span}
end

struct RawBlock
    page::Int
    lines::Vector{TextLine}
end

"""
    Piece

One unit of a parsed paper, in reading order. `kind` is one of `:title`, `:front` (authors,
affiliations and abstract, before the first heading), `:heading`, `:paragraph`, `:equation`,
`:caption`, `:reference` or `:footnote`. `section` indexes into the paper's sections (0 is the
front matter); `level` and `number` are set for headings, and `number` for numbered equations.
"""
struct Piece
    kind::Symbol
    page::Int
    bbox::NTuple{4,Float64}
    text::String
    section::Int
    level::Int
    number::String
end

"""
    Section

A heading and the pieces under it. `path` joins the titles of the enclosing headings, e.g.
`"2 Methods › 2.1 Coordinates"`.
"""
struct Section
    ord::Int
    level::Int
    number::String
    title::String
    path::String
    page_start::Int
    page_end::Int
end

struct ParsedPaper
    pages::Int
    pieces::Vector{Piece}
    sections::Vector{Section}
    info::Dict{String,String}   # the PDF's own metadata: its Title, Subject and Keywords, where it has them
end
ParsedPaper(pages, pieces, sections) = ParsedPaper(pages, pieces, sections, Dict{String,String}())

# ── Reading MuPDF output ─────────────────────────────────────────────────────

"""
    read_stext(pdf, config) -> (blocks, page_sizes)

Run `mutool` for structured text and page sizes. `mutool` exits with an error when it had to recover
from a fault in the PDF, though it still writes every page, so its output is used whenever there is
any; its messages only explain a failure.
"""
function read_stext(pdf::AbstractString, c::Config)
    out = tempname() * ".json"
    try
        messages = IOBuffer()
        p = run(pipeline(ignorestatus(`$(c.mutool) draw -q -F stext.json -O dehyphenate -o $out $pdf`); stderr = messages))
        data = filesize(out) > 0 ? (try JSON.parsefile(out) catch; nothing end) : nothing
        data isa AbstractDict && haskey(data, "pages") ||
            error("mutool could not read $(basename(pdf)) (exit $(p.exitcode)): ", strip(String(take!(messages))))
        sizes = page_sizes(read(pipeline(ignorestatus(`$(c.mutool) pages $pdf`); stderr = devnull), String))
        return stext_blocks(data), sizes
    finally
        rm(out; force = true)
    end
end

function page_sizes(pages_output::AbstractString)
    boxes = eachmatch(r"<MediaBox l=\"([-\d.]+)\" b=\"([-\d.]+)\" r=\"([-\d.]+)\" t=\"([-\d.]+)\"", pages_output)
    return [(parse(Float64, m[3]) - parse(Float64, m[1]), parse(Float64, m[4]) - parse(Float64, m[2])) for m in boxes]
end

function stext_blocks(data)
    blocks = RawBlock[]
    for (p, page) in enumerate(data["pages"]), b in page["blocks"]
        b["type"] == "text" || continue
        spans = Span[]
        for l in b["lines"]
            get(l, "wmode", 0) == 0 || continue
            bb, f = l["bbox"], l["font"]
            isempty(strip(l["text"])) && continue
            push!(spans, Span(bb["x"], bb["y"], bb["x"] + bb["w"], bb["y"] + bb["h"],
                font_name(f["name"]), f["size"], f["weight"] == "bold", f["style"] == "italic",
                l["text"]))
        end
        isempty(spans) || push!(blocks, RawBlock(p, group_lines(spans)))
    end
    return blocks
end

font_name(name) = (i = findfirst('+', name); i === nothing ? name : name[i+1:end])

"""
Group spans into visual lines: a span continues the current line when it lies to the right of the
previous span and overlaps the line vertically by at least half the smaller height (which keeps
sub- and superscripts on their line).
"""
function group_lines(spans::Vector{Span})
    lines = TextLine[]
    for s in spans
        if !isempty(lines)
            cur = last(lines).spans
            ly0, ly1 = minimum(x -> x.y0, cur), maximum(x -> x.y1, cur)
            overlap = min(ly1, s.y1) - max(ly0, s.y0)
            if s.x0 >= last(cur).x0 - 1 && overlap >= 0.5 * min(ly1 - ly0, s.y1 - s.y0)
                push!(cur, s)
                continue
            end
        end
        push!(lines, TextLine([s]))
    end
    return lines
end

bbox(l::TextLine) = (minimum(s -> s.x0, l.spans), minimum(s -> s.y0, l.spans),
    maximum(s -> s.x1, l.spans), maximum(s -> s.y1, l.spans))
bbox(ls::AbstractVector{TextLine}) = (b = bbox.(ls);
    (minimum(first, b), minimum(x -> x[2], b), maximum(x -> x[3], b), maximum(last, b)))

const LIGATURES = ["ﬁ" => "fi", "ﬂ" => "fl", "ﬀ" => "ff", "ﬃ" => "ffi", "ﬄ" => "ffl", "ﬅ" => "ft", "ﬆ" => "st"]

function line_text(l::TextLine)
    io = IOBuffer()
    prev = nothing
    for s in l.spans
        if prev !== nothing
            gap = s.x0 - prev.x1
            needs_space = gap > 0.2 * min(s.size, prev.size) &&
                          !endswith(prev.text, ' ') && !startswith(s.text, ' ')
            needs_space && write(io, ' ')
        end
        write(io, s.text)
        prev = s
    end
    return compose_accents(replace(squash(String(take!(io))), LIGATURES...))
end

# LaTeX sets accents as separate spacing glyphs before the letter ("K¨ahler"); turn each pair into
# the composed character ("Kähler").
const SPACING_ACCENTS = Dict('¨' => '\u0308', '´' => '\u0301', 'ˆ' => '\u0302', '˜' => '\u0303',
    'ˇ' => '\u030C', '˘' => '\u0306', '˚' => '\u030A', '¸' => '\u0327')

compose_accents(s::AbstractString) =
    replace(s, r"([¨´ˆ˜ˇ˘˚¸])\s?(\p{L})" => m -> Base.Unicode.normalize(m[end:end] * SPACING_ACCENTS[m[1]], :NFC))

"""
Join the lines of a paragraph, rejoining words hyphenated across a line break.
"""
function join_lines(texts::AbstractVector{<:AbstractString})
    io = IOBuffer()
    for (i, t) in enumerate(texts)
        if i > 1
            prev = texts[i-1]
            if occursin(r"\p{L}-$", prev) && occursin(r"^\p{Ll}", t)
                seek(io, position(io) - 1)  # drop the hyphen
            else
                write(io, ' ')
            end
        end
        write(io, t)
    end
    return String(take!(io))
end

# ── Font and text features ──────────────────────────────────────────────────

const MATH_FONT = r"^(CMMI|CMSY|CMEX|CMBSY|CMMIB|MSAM|MSBM|EUFM|EUSM|EURM|RSFS|LMMath|txsy|txex|txmi|rtxmi|rtxsy|ntxmi|ntxsy|STIXMath|STIXGeneral-Italic|XITSMath|CambriaMath|Asana|MathematicalPi|Symbol|Mathematica|MTMI|MTSY|ESSTIX)"i

is_math(s::Span) = occursin(MATH_FONT, s.font)

const EQ_NUMBER = r"\(\s*([A-Z]?\d+(?:\.\d+)*[a-z]?)\s*\)\s*$"

# Letters in a line's non-math spans that form ordinary words, a rough measure of prose.
prose_words(l::TextLine) = sum(s -> is_math(s) ? 0 : count(_ -> true, eachmatch(r"\p{L}{4,}", s.text)), l.spans)

function math_fraction(l::TextLine)
    total = sum(s -> count(!isspace, s.text), l.spans)
    total == 0 ? 0.0 : sum(s -> is_math(s) ? count(!isspace, s.text) : 0, l.spans) / total
end

dominant_size(l::TextLine) = argmax_weight(s -> s.size, s -> length(s.text), l.spans)
dominant_size(b::RawBlock) = argmax_weight(s -> s.size, s -> length(s.text), (s for l in b.lines for s in l.spans))

function argmax_weight(key, weight, items)
    tally = Dict{Any,Int}()
    for x in items
        tally[key(x)] = get(tally, key(x), 0) + weight(x)
    end
    return first(argmax(last, collect(tally)))
end

styled(b::RawBlock, body) = any(l -> any(s -> s.bold || s.italic || occursin(r"CSC|SC\d|Caps|Bold|Italic|-Bd|-It"i, s.font) ||
                                                     s.size > 1.05 * body, l.spans), b.lines)

# ── Classification ──────────────────────────────────────────────────────────

"The stamp arXiv prints down the margin of a paper's first page (`arXiv:<id> [<category>] <day> <month> <year>`), a block of its own."
const MARGIN_STAMP = r"^arXiv:\S+\s+\[[^\]]+\]\s+\d{1,2}\s+\w{3}\s+\d{4}$"
"""
A caption: a figure or table's label ("Figure 3", "Fig. S2", "TABLE II") followed by a stop, colon, bar
or dash, or by nothing. A paragraph that opens by mentioning one ("Figure 3 shows …") is not one,
unless its label is set in bold, as some journals set a caption's (see [`CAPTION_LABEL`](@ref)).
"""
const CAPTION = r"^(?:fig(?:ure)?|tab(?:le)?)\.?\s*(?:[A-Z]?\d+(?:\.\d+)*|[IVXLC]+)\s*(?:[:.|–—](?!\d)|$)"i
"A figure or table's label opening a block, which makes it a caption when set in bold."
const CAPTION_LABEL = r"^(?:fig(?:ure)?|tab(?:le)?)\.?\s*[A-Z]?\d+"i
const NUMBERED_HEADING = r"^((?:\d+|[A-Z]|[IVX]+)(?:\.\d+)*)\.?\s+(\p{Lu}.*)$"
const NAMED_HEADING = r"^(abstract|introduction|references|bibliography|acknowledge?ments?|conclusions?|summary|discussion|appendix(?:\s+[A-Z])?(?:[.:]\s*.*)?|data availability.*|declaration of interests?|funding|author contributions?)\.?$"i
const REFERENCES = r"^(references|bibliography|literature cited)$"i

# A paragraph that reads as a list of references, wherever the reading put it (after the
# acknowledgements, in an appendix, under a heading taken from a running head): dense with citation
# marks and nearly without the small words of sentences. In-text citations, "(Okafor et al. 2014)",
# are left out of the count, as they belong to prose. Calibrated on parsed papers: it finds most
# reference lists, and of the paragraphs it takes from body sections nearly all are reference lists,
# acknowledgements or author lists the reading misplaced.
const CITATION_MARKS = [r"\b(19|20)\d{2}[a-z]?\b", r"\bet al\b", r"\[\d{1,3}\]", r"\b[A-Z]\.(\s?[A-Z]\.)*\s[A-Z][a-zà-ÿ]+",
    # Journals' abbreviated words, across fields.
    r"\b(Phys|Rev|Lett|Nucl|J|Proc|Comput|Sci|Math|Appl|Theor|Nat|Natl|Acad|Biol|Chem|Ecol|Evol|Mol|Med|Neurosci|Geophys|Astrophys|Environ|Mar|Trans|Conf|Int|Res|Soc|Am|Annu|Eng|Syst|Stat|Inf|Mech)\.",
    r"\b\d+\s*\(\d+\)",
    r"\bdoi\b|10\.\d{4,}/", Regex("arXiv:\\s?" * ARXIV_ID)]
const IN_TEXT_CITATION = r"\((?=[^()]*[A-Za-z]{3,})[^()]*\b(19|20)\d{2}[a-z]?\b[^()]*\)"
const SENTENCE_WORDS = Set(split("""is are was were be been being we our us this these those which that it its has have had can
    could may might will would should must thus then there here how where when while however since because also often such"""))
const MIN_CITATION_DENSITY, MAX_SENTENCE_WORDS = 0.08, 0.03

"""
    reads_as_references(text) -> Bool

Whether a paragraph is a list of references rather than prose: at least `MIN_CITATION_DENSITY`
citation marks per word, once in-text citations are removed, and at most `MAX_SENTENCE_WORDS` of
its words the small words of sentences.
"""
function reads_as_references(text::AbstractString)
    words = split(text)
    length(words) < 8 && return false
    marks = sum(length(collect(eachmatch(r, replace(text, IN_TEXT_CITATION => " ")))) for r in CITATION_MARKS)
    small = count(w -> lowercase(strip(w, ['.', ',', ';', ':', '(', ')'])) in SENTENCE_WORDS, words)
    return marks / length(words) >= MIN_CITATION_DENSITY && small / length(words) <= MAX_SENTENCE_WORDS
end

"""
    parse_pdf(path, config) -> ParsedPaper
"""
function parse_pdf(path::AbstractString, c::Config)
    p = parse_blocks(read_stext(path, c)...)
    return ParsedPaper(p.pages, p.pieces, p.sections, pdf_info(path, c))
end

const INFO_JS = """
    var d = Document.openDocument(scriptArgs[0]), out = {};
    ["Title", "Subject", "Keywords"].forEach(function (k) { var v = d.getMetaData("info:" + k); if (v) out[k] = v })
    print(JSON.stringify(out))
    """

"A PDF's own metadata: its Title, Subject and Keywords, where it has them (none where it can't be read)."
function pdf_info(path::AbstractString, c::Config)
    script = tempname() * ".js"
    write(script, INFO_JS)
    try
        d = JSON.parse(read(pipeline(`$(c.mutool) run $script $path`; stderr = devnull), String))
        return Dict{String,String}(String(k) => strip(String(v)) for (k, v) in d if v isa AbstractString && !isempty(strip(v)))
    catch
        return Dict{String,String}()
    finally
        rm(script; force = true)
    end
end

"""
    parse_blocks(blocks, page_sizes) -> ParsedPaper

The layout analysis, separate from running MuPDF so it can be tested on constructed input.
"""
function parse_blocks(blocks::Vector{RawBlock}, sizes::Vector{<:Tuple})
    npages = max(length(sizes), maximum((b.page for b in blocks); init = 0))
    blocks = filter(b -> !occursin(MARGIN_STAMP, block_text(b)), blocks)
    isempty(blocks) && return ParsedPaper(npages, Piece[], Section[])
    # Journal names from the first page and from the running headers, which are dropped here, and
    # not from the references, which cite other journals.
    kept = drop_running_text(blocks, sizes, npages)
    running = setdiff(Base.IdSet{eltype(blocks)}(blocks), Base.IdSet{eltype(kept)}(kept))
    heads = mastheads([b for b in blocks if b.page == 1 || b in running])
    blocks = kept
    body = argmax_weight(s -> s.size, s -> length(s.text), (s for b in blocks for l in b.lines for s in l.spans))

    pieces = Piece[]
    candidate(b) = b.page == 1 && !is_masthead(normalize_title(block_text(b)), heads)
    title_size = maximum((dominant_size(b) for b in blocks if candidate(b)); init = 0.0)
    for b in blocks
        text = block_text(b)
        if candidate(b) && title_size >= 1.25 * body && dominant_size(b) == title_size
            push!(pieces, Piece(:title, b.page, bbox(b.lines), text, 0, 0, ""))
        elseif (h = heading(b, text, body)) !== nothing
            push!(pieces, Piece(:heading, b.page, bbox(b.lines), h.title, 0, h.level, h.number))
        elseif occursin(CAPTION, text) || (occursin(CAPTION_LABEL, text) && first(first(b.lines).spans).bold)
            push!(pieces, Piece(:caption, b.page, bbox(b.lines), text, 0, 0, ""))
        elseif dominant_size(b) < 0.85 * body && !any(l -> math_fraction(l) > 0.3, b.lines)
            push!(pieces, Piece(:footnote, b.page, bbox(b.lines), text, 0, 0, ""))
        else
            append!(pieces, split_block(b, body))
        end
    end
    filter!(p -> count(isletter, p.text) >= 3 || p.kind == :equation, pieces)
    return assign_sections(drop_figure_text(merge_equations(merge_titles(pieces))), npages)
end

block_text(b::RawBlock) = join_lines(line_text.(b.lines))

# A journal's pages cite the paper in a header line, "Ecological Modelling 87 (2012)
# 1453–1456" or, by article number, "Journal of Computational Physics 517 (2024) 113368", and the
# front page prints the journal's name large in its masthead, larger than the paper's title.
const JOURNAL_CITATION = r"(\p{Lu}[^\d()]*?)\s+\d+\s*\((\d{4})\)\s*\d+(?:\s*[–—-]\s*\d+)?"

"The journal names `blocks` cite, as [`normalize_title`](@ref) has them."
mastheads(blocks) = Set(normalize_title(m[1]) for b in blocks for l in b.lines
                        for m in (match(JOURNAL_CITATION, line_text(l)),) if m !== nothing)

"""
Whether text `t` (normalized) is a journal's name from its masthead: one of the names cited, or a
few words of one ("PHYSICA" for "Elsevier Physica D"; a running header puts authors before it).
"""
is_masthead(t, heads) = t in heads || (length(split(t)) <= 5 && any(h -> occursin(" $t ", " $h "), heads))

function heading(b::RawBlock, text::AbstractString, body)
    (length(b.lines) <= 3 && length(text) <= 160) || return nothing
    styled(b, body) || return nothing
    endswith(text, r"[,;]") && return nothing
    if (m = match(NUMBERED_HEADING, text)) !== nothing
        count(isletter, m[2]) >= 3 || return nothing
        number = String(m[1])
        return (; number, title = text, level = count('.', number) + 1)
    elseif occursin(NAMED_HEADING, text)
        return (; number = "", title = rstrip(text, '.'), level = 1)
    end
    return nothing
end

"A page number at either end of a running head, arabic or roman, with what sets it off: \"12 Title\", \"Title | xiv\"."
const PAGE_NUMBER_ENDS = r"^[\s–—-]*(?:page\s+)?(?:\d{1,4}|[ivxl]{1,6})\b[\s|•·:,.–—-]*|[\s|•·:,.–—-]*\b(?:page\s+)?(?:\d{1,4}|[ivxl]{1,6})[\s–—-]*$"
"A block that is only a page number: \"12\", \"- xiv -\", \"Page 3 of 12\"."
const PAGE_NUMBER = r"^[\s–—-]*(?:page\s+)?(?:\d{1,4}|[ivxl]{1,6})(?:\s*(?:of|/)\s*\d{1,4})?[\s–—-]*$"

"""
A running head's wording, for comparing pages: lowercased, without the page number at either end (so
"12 Title" on an even page and "Title 13" on an odd one are the same), and other digits as `#`.
"""
running_key(text::AbstractString) = squash(replace(replace(lowercase(text), PAGE_NUMBER_ENDS => " "), r"\d+" => "#"))

"""
Remove page furniture: running heads and feet, and bare page numbers. Furniture is a block of one or
two rows of text at the top or bottom of its page: in the margin, or near it with no text beyond it.
A running head is one whose wording (see [`running_key`](@ref)) repeats on enough of the pages, or on
enough of the even or the odd pages alone, where a paper sets different heads on facing pages.
"""
function drop_running_text(blocks, sizes, npages)
    box = IdDict(b => bbox(b.lines) for b in blocks)
    on_page = Dict{Int,Vector{eltype(blocks)}}()
    foreach(b -> push!(get!(on_page, b.page, eltype(blocks)[]), b), blocks)
    rows(b) = (ys = sort!([bbox(l)[2] for l in b.lines]); 1 + count(>(2), diff(ys)))
    function edge(b)
        rows(b) <= 2 || return false
        h = b.page <= length(sizes) ? sizes[b.page][2] : maximum(o -> box[o][4], on_page[b.page])
        _, y0, _, y1 = box[b]
        (y1 < 0.09 * h || y0 > 0.91 * h) && return true
        others = (box[o] for o in on_page[b.page] if o !== b)
        return (y1 < 0.15 * h && all(o -> o[4] > y0 + 1, others)) || (y0 > 0.85 * h && all(o -> o[2] < y1 - 1, others))
    end
    furniture = filter(b -> edge(b) && !occursin(CAPTION, block_text(b)), blocks)
    wording = IdDict(b => running_key(block_text(b)) for b in furniture)
    counts = Dict{Tuple{String,Bool},Int}()
    for b in furniture
        k = (wording[b], iseven(b.page))
        counts[k] = get(counts, k, 0) + 1
    end
    repeated = max(3, ceil(Int, 0.3 * npages))
    facing(even) = max(2, ceil(Int, 0.5 * count(p -> iseven(p) == even, 1:npages)))
    function running(b)
        k = wording[b]
        occursin(PAGE_NUMBER, lowercase(block_text(b))) && return true
        isempty(k) && return false
        on_even, on_odd = get(counts, (k, true), 0), get(counts, (k, false), 0)
        return on_even + on_odd >= repeated || on_even >= facing(true) || on_odd >= facing(false)
    end
    dropped = Base.IdSet{eltype(blocks)}(b for b in furniture if running(b))
    return filter(b -> !(b in dropped), blocks)
end

"""
Split a block into paragraphs and display equations. A line is part of a display equation when
it is mostly set in math fonts, or carries an equation number, and has little prose. A new
paragraph starts at an indented line following one that ends a sentence.
"""
function split_block(b::RawBlock, body)
    left = minimum(l -> bbox(l)[1], b.lines)
    kinds = map(b.lines) do l
        f = math_fraction(l)
        numbered = occursin(EQ_NUMBER, line_text(l))
        (f >= 0.35 || (numbered && f >= 0.15)) && prose_words(l) <= 3 ? :equation : :paragraph
    end
    pieces = Piece[]
    run = TextLine[]
    kind = kinds[1]
    function flush!()
        isempty(run) && return
        text = join_lines(line_text.(run))
        number = kind == :equation && (m = match(EQ_NUMBER, text)) !== nothing ? String(m[1]) : ""
        push!(pieces, Piece(kind, b.page, bbox(run), text, 0, 0, number))
        empty!(run)
    end
    for (i, l) in enumerate(b.lines)
        if i > 1
            new_para = kinds[i] == :paragraph && kinds[i-1] == :paragraph &&
                       bbox(l)[1] > left + 0.8 * body && occursin(r"[.!?:]$", line_text(b.lines[i-1]))
            (kinds[i] != kind || new_para) && flush!()
        end
        kind = kinds[i]
        push!(run, l)
    end
    flush!()
    return pieces
end

"""
Drop the text the PDF holds inside its figures (panel letters, axis labels, legends): the paragraphs,
equations and footnotes within a figure's region, the space above its caption up to the text that
bounds it (see [`region_above`](@ref)). Nothing that bounds a figure is inside one, so headings,
captions and long running text stay. So do a numbered equation and a sentence in the body's type,
which labels are not, as where a paragraph's last line is a block of its own.
"""
function drop_figure_text(pieces::Vector{Piece})
    rows = [(; kind = String(p.kind), p.page, x0 = p.bbox[1], y0 = p.bbox[2], x1 = p.bbox[3], y1 = p.bbox[4], p.text)
            for p in pieces]
    regions = [r for b in rows if b.kind == "caption" && startswith(lowercase(b.text), "fig")
               for r in (region_above(rows, b),) if r !== nothing]
    inside(p, r) = p.page == r.page && r.x0 <= (p.bbox[1] + p.bbox[3]) / 2 <= r.x1 && r.y0 - 2 <= (p.bbox[2] + p.bbox[4]) / 2 <= r.y1 + 2
    sentence(t) = occursin(r"[.!?:]\)?$", t) && count(w -> count(isletter, w) >= 2, split(t)) >= 3
    label(p) = p.kind == :footnote || (p.kind == :equation && isempty(p.number)) || (p.kind == :paragraph && !sentence(p.text))
    return filter(p -> !(label(p) && any(r -> inside(p, r), regions)), pieces)
end

"A display equation set over several blocks becomes one piece, one line per block."
function merge_equations(pieces)
    out = Piece[]
    for p in pieces
        if p.kind == :equation && !isempty(out) && last(out).kind == :equation && last(out).page == p.page
            q = last(out)
            box = (min(q.bbox[1], p.bbox[1]), min(q.bbox[2], p.bbox[2]), max(q.bbox[3], p.bbox[3]), max(q.bbox[4], p.bbox[4]))
            out[end] = Piece(:equation, q.page, box, q.text * "\n" * p.text, 0, 0, isempty(p.number) ? q.number : p.number)
        else
            push!(out, p)
        end
    end
    return out
end

"Titles set over several blocks become one."
function merge_titles(pieces)
    out = Piece[]
    for p in pieces
        if p.kind == :title && !isempty(out) && last(out).kind == :title
            t = last(out)
            out[end] = Piece(:title, t.page, t.bbox, t.text * " " * p.text, 0, 0, "")
        else
            push!(out, p)
        end
    end
    return out
end

"""
Give every piece its section. Pieces before the first heading are front matter (section 0);
paragraphs under a references heading, or that read as references wherever they are (see
[`reads_as_references`](@ref)), become `:reference`. When a paper has no headings at all, its
text is kept as body paragraphs rather than front matter.
"""
function assign_sections(pieces::Vector{Piece}, npages)
    has_headings = any(p -> p.kind == :heading, pieces)
    sections = Section[]
    stack = Section[]
    current, in_refs = 0, false
    out = Piece[]
    for p in pieces
        if p.kind == :heading
            while !isempty(stack) && last(stack).level >= p.level
                pop!(stack)
            end
            path = join([[s.title for s in stack]; p.text], " › ")
            s = Section(length(sections) + 1, p.level, p.number, p.text, path, p.page, p.page)
            push!(sections, s)
            push!(stack, s)
            current = s.ord
            in_refs = occursin(REFERENCES, p.text)
            push!(out, Piece(p.kind, p.page, p.bbox, p.text, current, p.level, p.number))
            continue
        end
        kind = p.kind
        if current == 0 && has_headings && kind in (:paragraph, :equation)
            kind = :front
        elseif kind == :paragraph && (in_refs || reads_as_references(p.text))
            kind = :reference
        end
        push!(out, Piece(kind, p.page, p.bbox, p.text, current, p.level, p.number))
    end
    # A section runs to the page where the next one starts.
    for (i, s) in enumerate(sections)
        last_page = maximum((p.page for p in out if p.section == s.ord); init = s.page_start)
        sections[i] = Section(s.ord, s.level, s.number, s.title, s.path, s.page_start, last_page)
    end
    return ParsedPaper(npages, out, sections)
end
