# Figures and tables cut from papers' PDFs. A paper's captions name its figures ("Figure 3:", "FIG.
# 2.") and tables ("Table 1.", "TABLE II."); when its PDF is read, each is cut from its page as an
# image into the paper's folder of figures, and recorded. Pages link to them and the service sends
# them (see api.jl), so a build of the site carries none but those a day's analysis discusses.
# Figures are WebP images; those cut or imported as PNG before are converted (see `webp_figures!`).

"""
The papers whose PDF is read here and whose figures were not cut from this reading of it, newest first,
as SQL: a paper read again, by a newer parser say, has its figures cut again, as where they are is found anew.
"""
uncut_sql() = """
    SELECT p.doc_id AS id FROM papers p JOIN parses x ON x.paper_id = p.id
    WHERE $(kind_in(k -> k.pdf; on = "p")) AND EXISTS (SELECT 1 FROM files f WHERE f.paper_id = p.id)
      AND NOT EXISTS (SELECT 1 FROM figure_cuts c WHERE c.paper_id = p.id AND c.file_sha = x.file_sha AND c.at >= x.parsed_at)
    ORDER BY p.id DESC"""

"Whether paper `id`'s figures are cut from its reading (see [`cut_paper_figures!`](@ref))."
figures_cut(kb::KB, id::AbstractString) =
    !ismissing(scalar(kb, """SELECT 1 FROM figure_cuts c JOIN parses x ON x.paper_id = c.paper_id AND x.file_sha = c.file_sha
                             WHERE c.paper_id = ? AND c.at >= x.parsed_at""", (paper_id(kb, id),)))

"The folder of paper `id`'s figures (see [`cut_paper_figures!`](@ref))."
figures_dir(c::Config, id::AbstractString) = joinpath(c.data_dir, "figures", page_slug(id))

const CLIP_JS = """
    var a = scriptArgs, doc = Document.openDocument(a[0]), page = doc.loadPage(parseInt(a[1]) - 1)
    var s = parseFloat(a[6]) / 72
    var r = [a[2], a[3], a[4], a[5]].map(function (v) { return Math.round(parseFloat(v) * s) })
    var pix = new Pixmap(ColorSpace.DeviceRGB, r, false)
    pix.clear(255)
    var dev = new DrawDevice([s, 0, 0, s, 0, 0], pix)
    page.run(dev, Matrix.identity)
    dev.close()
    pix.saveAsPNG(a[7])
    """

"The kinds of block a page's running text is read as."
const BODY_KINDS = ("paragraph", "code", "reference", "front")

"""
The resolution figures are cut at: twice the pixels they are shown with (see [`site_figures!`](@ref)),
so screens of twice the density draw their text and lines sharp.
"""
const FIGURE_DPI = 300

"""
The quality a figure is encoded at when lossy (see [`encode_webp`](@ref)): high enough that text and
thin lines keep sharp edges without ringing, at a fraction of the size of a lossless image of a figure
with gradients (a photograph, a colormap).
"""
const FIGURE_QUALITY = 90

"Run cwebp with `args`; when it fails, what it says is the error."
function cwebp!(args::Cmd)
    err = IOBuffer()
    success(pipeline(`$(libwebp_jll.cwebp()) -quiet $args`; stdout = devnull, stderr = err)) ||
        error("cwebp failed: " * last(strip(String(take!(err))), 500))
    return nothing
end

"""
    encode_webp(png, file)

Write the PNG image `png` as the WebP image `file`: lossless or lossy at [`FIGURE_QUALITY`](@ref),
whichever is smaller. Line art and tables, in a few flat colors, are smaller lossless and kept exact;
figures with gradients are much smaller lossy. Lossy keeps full-resolution color at edges
(`-sharp_yuv`), so thin colored lines do not bleed.
"""
function encode_webp(png::AbstractString, file::AbstractString)
    lossy, lossless = "$file.q.tmp", "$file.z.tmp"
    mkpath(dirname(file))
    try
        cwebp!(`-q $FIGURE_QUALITY -sharp_yuv -m 6 $png -o $lossy`)
        cwebp!(`-lossless -z 6 $png -o $lossless`)
        mv(filesize(lossless) <= filesize(lossy) ? lossless : lossy, file; force = true)
    finally
        rm(lossy; force = true)
        rm(lossless; force = true)
    end
    return file
end

"The image at `file`, a PNG or WebP image, as a matrix of colors."
function load_image(file::AbstractString)
    endswith(file, ".webp") || return PNGFiles.load(file)
    png = tempname() * ".png"
    try
        err = IOBuffer()
        success(pipeline(`$(libwebp_jll.dwebp()) -quiet $file -o $png`; stdout = devnull, stderr = err)) ||
            error("dwebp failed: " * last(strip(String(take!(err))), 500))
        return PNGFiles.load(png)
    finally
        rm(png; force = true)
    end
end

"Save `img` to `file`, as a WebP image (see [`encode_webp`](@ref)) or a PNG one, as its name says."
function save_image(file::AbstractString, img)
    endswith(file, ".webp") || return PNGFiles.save(file, img)
    png = tempname() * ".png"
    try
        PNGFiles.save(png, img)
        encode_webp(png, file)
    finally
        rm(png; force = true)
    end
end

"""
    image_size(file) -> (width, height)

The width and height of the PNG or WebP image `file`, from its header.
"""
function image_size(file::AbstractString)
    b = open(io -> read(io, 30), file)
    le(r) = sum(Int(b[i]) << (8 * (i - first(r))) for i in r)
    if length(b) >= 24 && b[1:4] == b"\x89PNG"
        return Int(ntoh(reinterpret(UInt32, b[17:20])[1])), Int(ntoh(reinterpret(UInt32, b[21:24])[1]))
    elseif length(b) >= 30 && b[1:4] == b"RIFF" && b[9:12] == b"WEBP"
        chunk = String(b[13:16])
        chunk == "VP8 " && return le(27:28) & 0x3fff, le(29:30) & 0x3fff               # lossy
        chunk == "VP8L" && (bits = le(22:25); return (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)   # lossless
        chunk == "VP8X" && return le(25:27) + 1, le(28:30) + 1                        # extended
    end
    error("$file is not a PNG or WebP image")
end

"The type a figure's image is sent as, by its name."
image_type(file::AbstractString) = get(CONTENT_TYPES, lowercase(splitext(file)[2]), "application/octet-stream")

"""
A caption that names its figure or table and then says what it shows ("Figure 3:", "FIG. 3.",
"TABLE II."), which a paragraph that mentions one ("Figure 3 follows …") does not.
"""
const NAMING_CAPTION = r"^(fig(?:ure)?|tab(?:le)?)\.?\s*(\d+|[IVXLC]+)\s*[:.|]"i

"A figure or table's number, from its digits or Roman numerals; `nothing` for neither."
function caption_number(s::AbstractString)
    all(isdigit, s) && return parse(Int, s)
    values = Dict('I' => 1, 'V' => 5, 'X' => 10, 'L' => 50, 'C' => 100)
    all(c -> haskey(values, c), uppercase(s)) || return nothing
    v = [values[c] for c in uppercase(s)]
    return sum(i < length(v) && v[i] < v[i+1] ? -v[i] : v[i] for i in eachindex(v))
end

const FIGURE_LABEL = r"^(?:(fig|tab)[a-z]*\.?\s*)?(\d+|[IVXLC]+)[a-z]?\b"i

"""
    parse_figure_label(s) -> Union{Nothing,Tuple{String,Int}}

The kind (`"figure"` or `"table"`) and number a label names: "Figure 3", "Fig. 2b" (a panel names its
figure), "Table II", or a bare number, a figure's. `nothing` for anything else.
"""
function parse_figure_label(s::AbstractString)
    m = match(FIGURE_LABEL, strip(s))
    n = m === nothing ? nothing : caption_number(m[2])
    n === nothing && return nothing
    return (m[1] !== nothing && lowercase(m[1]) == "tab" ? "table" : "figure", n)
end

"""
    captions(blocks) -> Vector{NamedTuple}

The figures and tables a paper's blocks name in their captions, figures first, each kind in order
and each one once: `(; kind, number, label, block)`, `kind` `"figure"` or `"table"`. A table's
caption read as a paragraph, a reference or a footnote counts too, as readings before parser version 4
took one numbered in Roman numerals ("TABLE II.") for one.
"""
function captions(blocks)
    seen = Dict{Tuple{String,Int},Any}()
    for b in blocks
        b.kind in ("caption", "paragraph", "reference", "footnote") || continue
        m = match(NAMING_CAPTION, strip(b.text))
        m === nothing && continue
        kind = lowercase(m[1])[1] == 'f' ? "figure" : "table"
        b.kind == "caption" || kind == "table" || continue
        n = caption_number(m[2])
        n === nothing && continue
        get!(seen, (kind, n), (; kind, number = n, label = (kind == "figure" ? "Figure " : "Table ") * m[2], block = b))
    end
    return sort!(collect(values(seen)); by = c -> (c.kind != "figure", c.number))
end

"""
A mention of figures or tables in running text: "Fig. 3", "Figure 3b", "FIG. 3", "Figs. 2 and 4",
"Table II", "Tabs. 1–3". The numbers it names are in its second group (see [`figure_mentions`](@ref)).
"""
const FIGURE_MENTION = r"\b([Ff]ig(?:ure)?s?|FIG(?:URE)?S?|[Tt]ab(?:le)?s?|TABLES?)\.?\s*((?:\d+[a-z]?|[IVXLC]+)\b(?:\s*(?:,|and|&|or)\s*(?:\d+[a-z]?|[IVXLC]+)\b)*)"

"""
    figure_mentions(text) -> Vector{Tuple{String,Int}}

The figures and tables `text` mentions, in order, each once, as `(kind, number)`: "Figs. 2 and 4"
is figures 2 and 4, a panel ("Fig. 3b") its figure.
"""
function figure_mentions(text::AbstractString)
    out = Tuple{String,Int}[]
    for m in eachmatch(FIGURE_MENTION, text)
        kind = lowercase(m[1])[1] == 'f' ? "figure" : "table"
        for n in eachmatch(r"\d+|[IVXLC]+", m[2])
            # Roman numerals name tables; a figure's number is in digits.
            kind == "figure" && !all(isdigit, n.match) && continue
            v = caption_number(n.match)
            v === nothing || (kind, v) in out || push!(out, (kind, v))
        end
    end
    return out
end

"""
    figure_region(blocks, label) -> Union{NamedTuple,Nothing}

Where the figure or table `label` ("Figure 3", "Fig. 2", "Table 1") is, among a paper's blocks
(`kind`, `page`, `x0`, `y0`, `x1`, `y1`, `text`): `(; page, x0, y0, x1, y1, caption)`. A figure is
the region above its caption, a table the side of its caption that holds it (see
[`table_region`](@ref)), as wide as the caption's column or the text across the page.
"""
function figure_region(blocks, label::AbstractString)
    parsed = parse_figure_label(label)
    parsed === nothing && return nothing
    kind, n = parsed
    named = [c for c in captions(blocks) if c.kind == kind && c.number == n]
    if isempty(named) && kind == "figure"
        # A caption that only names its figure, for want of one that also says what it shows.
        loose = [b for b in blocks if b.kind == "caption" && occursin(Regex("^fig(ure)?\\.?\\s*$n\\b", "i"), strip(b.text))]
        isempty(loose) && return nothing
        return region_above(blocks, first(loose))
    end
    isempty(named) && return nothing
    cap = only(named).block
    return kind == "figure" ? region_above(blocks, cap) : table_region(blocks, cap)
end

# The columns a caption's figure spans: the caption's own, or the text across the page when it is wide,
# at least as far as the paper's text usually runs (a page of figures has little text of its own).
function caption_columns(blocks, page, cap)
    left, right = min(minimum(b.x0 for b in page), text_left(blocks)), max(maximum(b.x1 for b in page), text_right(blocks))
    wide = (cap.x1 - cap.x0) > 0.6 * (right - left)
    return wide ? (left, right) : (cap.x0 - 6, cap.x1 + 6)
end

# A heading read as a paragraph: numbered as sections are ("VI. Verification setup", "A. Setup").
const SECTION_LINE = r"^([IVXL]+|[A-Z]|\d+(\.\d+)*)\.?\s+\p{Lu}"

# A block that bounds a figure across `x0`–`x1`: a heading or caption, or running text, which is long
# and spans most of that width, where the labels and legends inside a figure are short or narrow.
# A table's rows read as text too, so for one only text that reads as sentences bounds it.
function bounds_figure(b, x0, x1; table::Bool = false)
    b.kind in ("heading", "caption", "title") && return true
    b.kind in BODY_KINDS || return false
    length(b.text) < 120 && occursin(SECTION_LINE, b.text) && (b.x1 - b.x0) >= 0.4 * (x1 - x0) && return true
    length(b.text) >= 60 && (b.x1 - b.x0) >= 0.6 * (x1 - x0) || return false
    table || return true
    return count(isletter, b.text) >= 0.7 * length(b.text) && length(split(b.text)) >= 10
end

# The figure above caption `cap`: up to the nearest block above it that overlaps it across the page;
# with nothing above, from where the text of a page usually starts (below the running head, which
# reading the PDF leaves out).
function region_above(blocks, cap; table::Bool = false)
    page = [b for b in blocks if b.page == cap.page && !ismissing(b.x0)]
    x0, x1 = caption_columns(blocks, page, cap)
    above = [b.y1 for b in page if b.y1 <= cap.y0 + 1 && b !== cap && b.x1 > x0 && b.x0 < x1 && bounds_figure(b, x0, x1; table)]
    y0 = isempty(above) ? text_top(blocks) - 8 : maximum(above)
    (cap.y0 - y0) < (table ? 20 : 30) && return nothing
    table && ((x0, x1) = rows_width(page, cap, y0, cap.y0, x0, x1))
    return (; page = cap.page, x0, y0 = y0 + 2, x1, y1 = cap.y0 - 2, caption = cap.text)
end

# A table is often wider than its caption: as wide as its own rows, between `y0` and `y1`.
function rows_width(page, cap, y0, y1, x0, x1)
    rows = [b for b in page if b.y0 >= y0 - 1 && b.y1 <= y1 + 1 && b !== cap]
    isempty(rows) && return (x0, x1)
    return (min(x0, minimum(b.x0 for b in rows) - 4), max(x1, maximum(b.x1 for b in rows) + 4))
end

"""
    table_region(blocks, cap) -> Union{NamedTuple,Nothing}

The table caption `cap` names: below it, as most journals set a table, or above it, as some do, on
the side whose region holds more of the table's own text (its rows, which are not running text).
"""
function table_region(blocks, cap)
    sides = filter(!isnothing, [region_below(blocks, cap), region_above(blocks, cap; table = true)])
    isempty(sides) && return nothing
    held(r) = count(b -> b.page == cap.page && b !== cap && !ismissing(b.x0) && b.x1 > r.x0 && b.x0 < r.x1 &&
                         r.y0 <= (b.y0 + b.y1) / 2 <= r.y1, blocks)
    return sides[argmax(map(held, sides))]
end

# The table below caption `cap`: down to the nearest block below it that overlaps it across the page,
# or to where the text of a page usually ends, and across as wide as its rows.
function region_below(blocks, cap)
    page = [b for b in blocks if b.page == cap.page && !ismissing(b.x0)]
    x0, x1 = caption_columns(blocks, page, cap)
    below = [b.y0 for b in page if b.y0 >= cap.y1 - 1 && b !== cap && b.x1 > x0 && b.x0 < x1 && bounds_figure(b, x0, x1; table = true)]
    y1 = isempty(below) ? text_bottom(blocks) + 8 : minimum(below)
    (y1 - cap.y1) < 20 && return nothing
    (x0, x1) = rows_width(page, cap, cap.y1, y1, x0, x1)
    return (; page = cap.page, x0, y0 = cap.y1 + 2, x1, y1 = y1 - 2, caption = cap.text)
end

"The median, over the pages, of `pick` (`min` or `max`) of `field` over each page's blocks."
function page_median(blocks, field::Symbol, pick)
    per = Dict{Int,Float64}()
    for b in blocks
        v = getproperty(b, field)
        ismissing(v) || (per[b.page] = haskey(per, b.page) ? pick(per[b.page], v) : v)
    end
    t = sort!(collect(values(per)))
    return t[(length(t) + 1) ÷ 2]
end

"Where a page's text usually starts: the median, over the pages, of the top of each one's first block."
text_top(blocks) = page_median(blocks, :y0, min)
"Where a page's text usually ends: the median, over the pages, of the bottom of each one's last block."
text_bottom(blocks) = page_median(blocks, :y1, max)
"Where a page's text usually starts across: the median, over the pages, of each one's leftmost edge."
text_left(blocks) = page_median(blocks, :x0, min)
"Where a page's text usually ends across: the median, over the pages, of each one's rightmost edge."
text_right(blocks) = page_median(blocks, :x1, max)

"""
    cut_figure(kb, id, label, file; dpi = FIGURE_DPI) -> Union{NamedTuple,Nothing}

Render figure or table `label` of paper `id` from its PDF to the image `file`, WebP or PNG as its name says (see
[`figure_region`](@ref)). Returns the region and caption, or nothing when it is not found.
"""
function cut_figure(kb::KB, id::AbstractString, label::AbstractString, file::AbstractString; dpi::Integer = FIGURE_DPI)
    pid = paper_id(kb, id)
    blocks = query(kb, "SELECT kind, page, x0, y0, x1, y1, text FROM blocks WHERE paper_id = ? ORDER BY ord", (pid,))
    r = figure_region(blocks, label)
    r === nothing && return nothing
    render_region(kb.config, first(query(kb, "SELECT path FROM files WHERE paper_id = ?", (pid,))).path, r, file; dpi)
    return r
end

"""
Run mutool command `cmd`, keeping out of the log what it says of a PDF's faults it works around
(a broken structure tree, a missing resource, odd font metrics); when it fails, that is the error.
"""
function mutool!(cmd::Cmd)
    err = IOBuffer()
    success(pipeline(cmd; stdout = devnull, stderr = err)) || error("mutool failed: " * last(strip(String(take!(err))), 500))
    return nothing
end

"""
Render region `r` (`page`, `x0`, `y0`, `x1`, `y1`) of the PDF `pdf` to the image `file`: mutool draws
a PNG, which a `.webp` name has encoded as WebP (see [`encode_webp`](@ref)).
"""
function render_region(c::Config, pdf::AbstractString, r, file::AbstractString; dpi::Integer = FIGURE_DPI)
    script = tempname() * ".js"
    write(script, CLIP_JS)
    mkpath(dirname(file))
    png = endswith(file, ".webp") ? tempname() * ".png" : file
    try
        mutool!(`$(c.mutool) run $script $pdf $(r.page) $(r.x0) $(r.y0) $(r.x1) $(r.y1) $dpi $png`)
        png == file || encode_webp(png, file)
    finally
        rm(script; force = true)
        png == file || rm(png; force = true)
    end
    return file
end

"""
    cut_paper_figures!(kb, id) -> Vector{NamedTuple}

Cut every figure and table paper `id`'s captions name (see [`captions`](@ref)) from its PDF into its
folder of figures, as `fig-<n>.webp` and `table-<n>.webp`, and record them, replacing what was cut
before; one whose region is not found is left out. Returns `(; kind, number, label, caption, file)`
for each, figures first. A paper without its PDF here keeps what it has.
"""
function cut_paper_figures!(kb::KB, id::AbstractString)
    pid = paper_id(kb, id)
    files = query(kb, "SELECT path FROM files WHERE paper_id = ?", (pid,))
    (isempty(files) || !isfile(first(files).path)) && return paper_figures(kb, id)
    blocks = query(kb, "SELECT kind, page, x0, y0, x1, y1, text FROM blocks WHERE paper_id = ? ORDER BY ord", (pid,))
    dir = figures_dir(kb.config, id)
    cut = NamedTuple[]
    for c in captions(blocks)
        r = c.kind == "figure" ? region_above(blocks, c.block) : table_region(blocks, c.block)
        r === nothing && continue
        file = joinpath(dir, (c.kind == "figure" ? "fig" : "table") * "-$(c.number).webp")
        try
            render_region(kb.config, first(files).path, r, file)
            push!(cut, (; c.kind, c.number, c.label, caption = r.caption, file = basename(file)))
        catch e
            @warn "Could not cut $(c.label) from $id" exception = e
        end
    end
    transaction(kb) do
        execute!(kb, "DELETE FROM figures WHERE paper_id = ?", (pid,))
        for f in cut
            execute!(kb, "INSERT INTO figures VALUES (?, ?, ?, ?, ?, ?)", (pid, f.kind, f.number, f.label, f.caption, f.file))
        end
        execute!(kb, """INSERT OR REPLACE INTO figure_cuts (paper_id, file_sha, at)
                        SELECT paper_id, file_sha, ? FROM parses WHERE paper_id = ?""", (now_iso(), pid))
    end
    # What is no longer cut goes, with its copy for the other theme, and so does a cut in another format.
    clear_figures!(dir, Set(f.file for f in cut))
    return cut
end

"""
Remove from the folder of figures `dir` every file but the figures named in `keep`, their copies for
the other theme, and their notes of it (see [`theme_figures`](@ref)).
"""
function clear_figures!(dir::AbstractString, keep)
    isdir(dir) || return nothing
    stems = Set(splitext(f)[1] for f in keep)
    for f in readdir(dir)
        stem, ext = splitext(f)
        (ext == ".theme" ? stem in stems : replace(stem, r"-(dark|light)$" => "") * ext in keep) || rm(joinpath(dir, f); force = true)
    end
    return nothing
end

"""
    paper_figures(kb, id) -> Vector{NamedTuple}

The figures and tables cut from paper `id` (see [`cut_paper_figures!`](@ref)), figures first, each
in order: `(; kind, number, label, caption, file)`.
"""
paper_figures(kb::KB, id::AbstractString) =
    [(; kind = String(r.kind), number = Int(r.number), label = String(r.label), caption = String(r.caption), file = String(r.file))
     for r in query(kb, "SELECT kind, number, label, caption, file FROM figures WHERE paper_id = ? ORDER BY kind = 'table', number",
                    (paper_id(kb, id),))]

"""
    figures_json(kb, id) -> Vector{Dict}

A paper's figures and tables for its page (KBFigures.vue): each one's `kind`, `label`, `caption`,
`file`, and `src`, where the service sends it (see [`figure_file`](@ref)).
"""
figures_json(kb::KB, id::AbstractString) =
    [Dict("kind" => f.kind, "label" => f.label, "caption" => f.caption, "file" => f.file,
          "src" => "/api/figures/$(page_slug(id))/$(f.file)") for f in paper_figures(kb, id)]

"""
    figure_file(kb, slug, file; theme = "") -> String

The image to send for `file` of the paper whose page is `slug`: the cut, or with `theme` `"light"`
or `"dark"` its copy for that theme where it was drawn for the other (see [`theme_figures`](@ref)),
made the first time it is asked for. `""` when there is no such figure.
"""
function figure_file(kb::KB, slug::AbstractString, file::AbstractString; theme::AbstractString = "")
    occursin(r"^[A-Za-z0-9._-]+$", slug) && occursin(r"^(fig|table)-\d+\.(webp|png)$", file) || return ""
    from = joinpath(kb.config.data_dir, "figures", slug, file)
    isfile(from) || return ""
    theme in ("light", "dark") || return from
    themed = try_theme(from, "$file of $slug")
    return themed === nothing ? from : theme == "dark" ? themed.dark : themed.light
end

"""
    cut_papers_figures!(kb; progress, cancelled) -> Int

Cut the figures and tables of every paper whose PDF is read here and whose reading has had none cut
(see [`cut_paper_figures!`](@ref)): what a library read before figures were cut needs once.
Returns how many papers were cut.
"""
function cut_papers_figures!(kb::KB; progress = msg -> nothing, cancelled = () -> false)
    ids = [String(r.id) for r in query(kb, uncut_sql())]
    n = 0
    for (i, id) in enumerate(ids)
        cancelled() && break
        progress("[$i/$(length(ids))] cutting the figures of $id")
        try
            lock(() -> cut_paper_figures!(kb, id), paper_lock(id))
            n += 1
        catch e
            e isa InterruptException && rethrow()
            @warn "Could not cut the figures of $id" exception = e
        end
    end
    return n
end

"The papers with figures named as PNG images, in their records or in the picks of the papers of the day."
function png_figure_papers(kb::KB)
    ids = Set(String(r.doc_id) for r in query(kb, "SELECT DISTINCT p.doc_id FROM figures f JOIN papers p ON p.id = f.paper_id WHERE f.file LIKE '%.png'"))
    for r in query(kb, "SELECT doc_id, figures FROM daily WHERE figures LIKE '%.png%'")
        any(f -> endswith(string(get(f, "file", "")), ".png"), JSON.parse(r.figures)) && push!(ids, String(r.doc_id))
    end
    return sort!(collect(ids))
end

"""
    webp_paper_figures!(kb, id) -> Int

Convert paper `id`'s figures named as PNG images (cut, or imported from a dataset, before figures were
WebP) to WebP (see [`encode_webp`](@ref)), and name the WebP images in its records of figures and in
the picks of its papers of the day. The PNG images go, with their copies for the other theme. A name
whose image is missing is renamed all the same; one that does not convert keeps its PNG image.
Returns how many images were converted.

Converting changes what the paper's data names, so where its figures were cut here (see
[`fingerprints`](@ref)) the cut's time moves and a publisher publishes the paper again. A paper
imported from another stream and not read here stays that stream's (see [`own_documents`](@ref)).
"""
function webp_paper_figures!(kb::KB, id::AbstractString)
    dir = figures_dir(kb.config, id)
    pid = paper_id(kb, id)
    rows = ismissing(pid) ? String[] : [String(r.file) for r in query(kb, "SELECT file FROM figures WHERE paper_id = ? AND file LIKE '%.png'", (pid,))]
    days = [(day = String(r.day), figures = Dict{String,Any}.(JSON.parse(r.figures)))
            for r in query(kb, "SELECT day, figures FROM daily WHERE doc_id = ? AND figures LIKE '%.png%'", (id,))]
    names = unique([rows; [string(f["file"]) for d in days for f in d.figures if endswith(string(get(f, "file", "")), ".png")]])
    renamed = Dict{String,String}()
    converted = 0
    for name in names
        png, webp = joinpath(dir, name), splitext(name)[1] * ".webp"
        if isfile(png)
            try
                encode_webp(png, joinpath(dir, webp))
                converted += 1
            catch e
                @warn "Could not convert $name of $id to WebP" exception = e
                continue
            end
        end
        renamed[name] = webp
    end
    isempty(renamed) && return 0
    # Imported from another stream and left as it came: so it stays.
    imported = query(kb, "SELECT stream, fingerprint FROM dataset_docs WHERE doc_id = ?", (id,))
    others = !isempty(imported) && only(imported).stream != stream_name(kb.config) &&
             fingerprints(kb, [id]; record = false)[id] == only(imported).fingerprint
    transaction(kb) do
        for (from, to) in renamed
            ismissing(pid) || execute!(kb, "UPDATE figures SET file = ? WHERE paper_id = ? AND file = ?", (to, pid, from))
        end
        for d in days
            foreach(f -> haskey(f, "file") && haskey(renamed, f["file"]) && (f["file"] = renamed[f["file"]]), d.figures)
            execute!(kb, "UPDATE daily SET figures = ? WHERE day = ? AND doc_id = ?", (JSON.json(d.figures), d.day, id))
        end
        ismissing(pid) || execute!(kb, "UPDATE figure_cuts SET at = ? WHERE paper_id = ?", (now_iso(), pid))
        others && execute!(kb, "UPDATE dataset_docs SET fingerprint = ? WHERE doc_id = ?", (fingerprints(kb, [id]; record = false)[id], id))
    end
    for from in keys(renamed)
        stem = splitext(from)[1]
        foreach(f -> rm(joinpath(dir, f); force = true), (from, "$stem-dark.png", "$stem-light.png", "$stem.theme"))
    end
    return converted
end

"""
    webp_figures!(kb; progress, cancelled) -> Int

Convert every paper's figures named as PNG images to WebP (see [`webp_paper_figures!`](@ref)), so a
knowledge base cut or imported before figures were WebP comes to hold WebP images only, without
cutting them again. Returns how many images were converted.
"""
function webp_figures!(kb::KB; progress = msg -> nothing, cancelled = () -> false)
    ids = png_figure_papers(kb)
    n = 0
    for (i, id) in enumerate(ids)
        cancelled() && break
        progress("[$i/$(length(ids))] converting the figures of $id to WebP")
        try
            n += lock(() -> webp_paper_figures!(kb, id), paper_lock(id))
        catch e
            e isa InterruptException && rethrow()
            @warn "Could not convert the figures of $id to WebP" exception = e
        end
    end
    return n
end

"""
    figure_mentions_in(kb, id) -> Dict{Tuple{String,Int},Vector{NamedTuple}}

Where paper `id`'s running text mentions each of its figures and tables, keyed `(kind, number)` (see
[`figure_mentions`](@ref)): each mention's `section`, `page` and the `sentence` it is in, in order.
"""
function figure_mentions_in(kb::KB, id::AbstractString)
    pid = paper_id(kb, id)
    titles = Dict(Int(r.ord) => String(r.title) for r in query(kb, "SELECT ord, title FROM sections WHERE paper_id = ?", (pid,)))
    out = Dict{Tuple{String,Int},Vector{NamedTuple}}()
    for b in query(kb, "SELECT section, page, text FROM blocks WHERE paper_id = ? AND kind = 'paragraph' ORDER BY ord", (pid,))
        for sentence in split(b.text, r"(?<=[.!?])\s+(?=[A-Z(])")
            for key in figure_mentions(sentence)
                push!(get!(out, key, NamedTuple[]), (; section = get(titles, Int(b.section), ""), page = Int(b.page),
                                                       sentence = String(strip(sentence))))
            end
        end
    end
    return out
end

"""
    pick_figures(figures, which) -> Vector

The figures and tables of `figures` (see [`paper_figures`](@ref)) that `which` names, a comma list of
"3", "Fig. 3", "Figure 3b" or "Table II" (a bare number is a figure), or a label as it is (a record's
figure's name). Errors naming any not there.
"""
function pick_figures(figures, which::AbstractString)
    out, missing = eltype(figures)[], String[]
    for w in split(which, ',')
        w = strip(w)
        isempty(w) && continue
        named = parse_figure_label(w)
        i = findfirst(f -> f.label == w, figures)              # a record's figure, by its name
        i === nothing && named !== nothing && (i = findfirst(f -> (f.kind, f.number) == named, figures))
        i === nothing ? push!(missing, w) : (figures[i] in out || push!(out, figures[i]))
    end
    isempty(missing) || error("No $(join(missing, ", ")) among the figures and tables cut from this paper: see `figures`")
    return out
end

"""
    page_image(kb, id, page; dpi = 110) -> Vector{UInt8}

Page `page` of paper `id`'s PDF as a PNG, at `dpi`.
"""
function page_image(kb::KB, id::AbstractString, page::Integer; dpi::Integer = 110)
    files = query(kb, "SELECT path FROM files WHERE paper_id = ?", (paper_id(kb, id),))
    (isempty(files) || !isfile(first(files).path)) && error("$id's PDF is not on this machine")
    pdf = first(files).path
    pages = tryparse(Int, strip(read(pipeline(`$(kb.config.mutool) show $pdf trailer/Root/Pages/Count`; stderr = devnull), String)))
    pages === nothing || 1 <= page <= pages || error("$id has no page $page: it has $pages")
    out = tempname() * ".png"
    try
        err = IOBuffer()
        ok = success(pipeline(`$(kb.config.mutool) draw -q -r $dpi -o $out $pdf $page`; stdout = devnull, stderr = err))
        (ok && isfile(out)) || error("$id has no page $page")
        return read(out)
    finally
        rm(out; force = true)
    end
end
