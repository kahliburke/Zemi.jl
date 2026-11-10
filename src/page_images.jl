# A paper's pages as images, for reading a section where it is printed (KBSectionText.vue). mutool
# draws each page at one of a few widths; the dark theme's copy is recolored as a figure's is (see
# `recolor`). Both are kept under `~/.cache/zemi/pages`, named by the PDF they were drawn from.

"The widths a page is drawn at, in pixels: one asked for at another is drawn at the next one up."
const PAGE_WIDTHS = (800, 1200, 1600, 2000)

"The width of [`PAGE_WIDTHS`](@ref) a page asked for `w` pixels wide is drawn at."
page_step(w::Integer) = (i = findfirst(>=(w), PAGE_WIDTHS); i === nothing ? last(PAGE_WIDTHS) : PAGE_WIDTHS[i])

pages_dir() = mkpath(joinpath(xdg_home("XDG_CACHE_HOME", ".cache"), "zemi", "pages"))

"A name for the PDF at `pdf` as it is now: a page drawn from it is drawn again once it changes."
pdf_key(pdf::AbstractString) = first(text_sha("$(abspath(pdf)) $(mtime(pdf)) $(filesize(pdf))"), 16)

"""
    page_bounds(pages_output) -> Vector{NamedTuple}

Each page's `(; page, width, height)` in PDF points, from `mutool pages`: its crop box (what mutool
draws), else its media box, turned with the page.
"""
function page_bounds(pages_output::AbstractString)
    map(eachmatch(r"<page pagenum=\"(\d+)\">(.*?)</page>"s, pages_output)) do m
        function box(name)
            b = match(Regex("<$name l=\"([-\\d.]+)\" b=\"([-\\d.]+)\" r=\"([-\\d.]+)\" t=\"([-\\d.]+)\""), m[2])
            b === nothing ? nothing : parse.(Float64, b.captures)
        end
        l, b, r, t = something(box("CropBox"), box("MediaBox"))
        turn = match(r"<Rotate v=\"(-?\d+)\"", m[2])
        sideways = turn !== nothing && isodd(mod(parse(Int, turn[1]), 360) ÷ 90)
        (; page = parse(Int, m[1]), width = sideways ? t - b : r - l, height = sideways ? r - l : t - b)
    end
end

"""
    paper_pages(kb, id, first, last) -> Vector{NamedTuple}

The size of pages `first` to `last` of paper `id`, as [`page_bounds`](@ref) gives them; its PDF
fetched first where it is not here (see [`paper_pdf`](@ref)).
"""
function paper_pages(kb::KB, id::AbstractString, a::Integer, b::Integer)
    1 <= a <= b || error("No pages $a-$b.")
    pdf = paper_pdf(kb, id)
    return page_bounds(read(pipeline(ignorestatus(`$(kb.config.mutool) pages $pdf $a-$b`); stderr = devnull), String))
end

# Pages being drawn, each by one request: another asking for it waits for that one.
const PAGE_LOCKS = LockedDict{String,ReentrantLock}()

"""
    page_file(kb, id, page; width = 1200, theme = "") -> String

Page `page` of paper `id` as an image (see [`draw_page`](@ref)), its PDF fetched first where it is not
here (see [`paper_pdf`](@ref)).
"""
page_file(kb::KB, id::AbstractString, page::Integer; kw...) = draw_page(kb.config, paper_pdf(kb, id), page; kw...)

"""
    draw_page(c, pdf, page; width = 1200, theme = "") -> String

Page `page` of the PDF at `pdf` as a WebP image at the step of [`PAGE_WIDTHS`](@ref) for `width`: as
printed, or with `theme` `"dark"` recolored for the dark theme. Drawn the first time it is asked for,
and kept.
"""
function draw_page(c::Config, pdf::AbstractString, page::Integer; width::Integer = 1200, theme::AbstractString = "")
    w = page_step(width)
    stem = joinpath(pages_dir(), "$(pdf_key(pdf))-p$page-w$w")
    printed, dark = stem * ".webp", stem * "-dark.webp"
    file = theme == "dark" ? dark : printed
    isfile(file) && return file
    lock(get!(ReentrantLock, PAGE_LOCKS, stem)) do
        if !isfile(printed)
            png = tempname() * ".png"
            try
                # (mutool takes a page past the last as the last.)
                any(b -> b.page == page, page_bounds(read(pipeline(ignorestatus(`$(c.mutool) pages $pdf $page`); stderr = devnull), String))) ||
                    not_found("No page $page in $(basename(pdf)).")
                mutool!(`$(c.mutool) draw -q -w $w -o $png $pdf $page`)
                encode_webp(png, printed)
            finally
                rm(png; force = true)
            end
        end
        theme == "dark" && !isfile(dark) && save_image(dark, recolor(convert.(Oklab, opaque.(load_image(printed))), :dark))
    end
    return file
end
