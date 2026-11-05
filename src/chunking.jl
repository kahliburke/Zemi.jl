"""
    Chunk

A passage for retrieval: consecutive body pieces within one section, about a paragraph or two.
"""
struct Chunk
    ord::Int
    section::Int
    page_start::Int
    page_end::Int
    text::String
end

const CHUNK_TARGET = 1400
const CHUNK_MAX = 2200

const CHUNKED_KINDS = (:paragraph, :equation, :caption, :footnote)

"""
    chunk_paper(parsed, abstract) -> Vector{Chunk}

Split a parsed paper into chunks that never cross a section boundary. Pieces accumulate until a
chunk reaches `CHUNK_TARGET` characters. A display equation, or a paragraph that continues one
(starting with "where", "with", …), stays with the text before it as long as the chunk stays
under `CHUNK_MAX`. Paragraphs longer than `CHUNK_MAX` are split at sentence boundaries. The
abstract (from the paper's metadata, which is cleaner than the parsed front matter) is chunk 0.
"""
function chunk_paper(p::ParsedPaper, abstract::AbstractString = "")
    chunks = Chunk[]
    add!(section, pages, text) = push!(chunks, Chunk(length(chunks), section, pages[1], pages[2], text))
    isempty(strip(abstract)) || add!(0, (1, 1), strip(abstract))

    buf = String[]
    section, pages = -1, (0, 0)
    buflen() = sum(length, buf; init = 0) + 2 * max(length(buf) - 1, 0)
    function flush!()
        isempty(buf) || add!(section, pages, join(buf, "\n\n"))
        empty!(buf)
    end
    for piece in p.pieces
        piece.kind in CHUNKED_KINDS || continue
        # Front matter (journal lines, affiliations, the parsed abstract) is replaced by the
        # metadata abstract above, unless the paper has no headings to separate it from the body.
        piece.section == 0 && !isempty(p.sections) && continue
        if piece.section != section
            flush!()
            section, pages = piece.section, (piece.page, piece.page)
        end
        for text in split_long(piece.text)
            attached = piece.kind == :equation ||
                       occursin(r"^(where|with|and|in which|here|for|so that|such that)\b"i, text)
            fits = buflen() + length(text) <= (attached ? CHUNK_MAX : CHUNK_TARGET)
            if !isempty(buf) && !fits
                flush!()
                pages = (piece.page, piece.page)
            end
            push!(buf, text)
            pages = (pages[1], piece.page)
        end
    end
    flush!()
    # Drop passages that are mostly symbol soup (matrices and tableaux come out of the PDF as runs of
    # single letters and indices): they match queries at random and read as noise. The text stays
    # in the parsed blocks.
    kept = [c for c in chunks if c.section == 0 || prose_fraction(c.text) >= MIN_PROSE]
    return [Chunk(i - 1, c.section, c.page_start, c.page_end, c.text) for (i, c) in enumerate(kept)]
end

const MIN_PROSE = 0.40

"""
    prose_fraction(text) -> Float64

The share of non-space characters that belong to words of three or more letters. Around 0.8 for
ordinary prose, 0.5 for prose dense with inline math, under 0.4 for extracted matrices.
"""
function prose_fraction(text::AbstractString)
    n = count(!isspace, text)
    n == 0 && return 0.0
    return sum(m -> length(m.match), eachmatch(r"\p{L}{3,}", text); init = 0) / n
end

"Split text longer than `CHUNK_MAX` at sentence ends into pieces near `CHUNK_TARGET`."
function split_long(text::AbstractString)
    length(text) <= CHUNK_MAX && return [String(text)]
    sentences = split(text, r"(?<=[.!?])\s+(?=[\p{Lu}(\[])")
    out = String[]
    cur = IOBuffer()
    for s in sentences
        if position(cur) > 0 && position(cur) + length(s) > CHUNK_TARGET
            push!(out, String(take!(cur)))
        end
        position(cur) > 0 && write(cur, ' ')
        write(cur, s)
    end
    position(cur) > 0 && push!(out, String(take!(cur)))
    return out
end
