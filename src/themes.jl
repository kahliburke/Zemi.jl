# ── Figures for both themes ──────────────────────────────────────────────────────────────────────
# A figure cut from a paper is drawn for one background, nearly always white paper. The site shows
# it in either theme, so it gets a recolored copy for the other: its grays (the background, text,
# axes and black lines) have their lightness turned over onto that theme's background and text, in
# Oklab so their hue is kept, while colorful pixels (colormaps, filled data, colored lines) keep
# their colors, moved only as far in lightness as they need to read on the new background.

"The site's backgrounds and text, as VitePress's themes draw them."
const THEME_COLORS = (light = (bg = Oklab(RGB(1.0, 1.0, 1.0)), fg = Oklab(RGB(0x3c / 255, 0x3c / 255, 0x43 / 255))),
                      dark = (bg = Oklab(RGB(0x1b / 255, 0x1b / 255, 0x1f / 255)), fg = Oklab(RGB(0xdf / 255, 0xdf / 255, 0xd6 / 255))))

# How colorful (Oklab chroma) a pixel is before it starts keeping its color, and from where it keeps
# all of it.
const GRAY_CHROMA, COLOR_CHROMA = 0.03, 0.12
# The lightness a colorful pixel is kept to on each background: at least this on the dark one, at
# most this on the light one.
const DARK_MIN_L, LIGHT_MAX_L = 0.5, 0.72

# A gray among colors with little background between them (a panel's label drawn on a colormap,
# say) is part of the colored drawing and keeps its color; a black line among colored ones, with
# background around them, does not. Both are judged over a pixel's neighborhood, this many pixels
# each way.
const NEIGHBORHOOD = 6

smoothstep(x, a, b) = (t = clamp((x - a) / (b - a), 0, 1); t * t * (3 - 2t))
chroma(o::Oklab) = hypot(o.a, o.b)

"The mean of `x` over the square `r` pixels each way around each pixel (cut off at the edges)."
function box_mean(x::AbstractMatrix{Float64}, r::Integer)
    h, w = size(x)
    s = zeros(h + 1, w + 1)
    for j in 1:w, i in 1:h
        s[i+1, j+1] = x[i, j] + s[i, j+1] + s[i+1, j] - s[i, j]
    end
    return [(i0 = max(i - r, 1); i1 = min(i + r, h); j0 = max(j - r, 1); j1 = min(j + r, w);
             (s[i1+1, j1+1] - s[i0, j1+1] - s[i1+1, j0] + s[i0, j0]) / ((i1 - i0 + 1) * (j1 - j0 + 1))) for i in 1:h, j in 1:w]
end

"A pixel as it shows on white: transparency composited away."
opaque(c::TransparentColor) = (a = Float64(Colors.alpha(c)); x = RGB{Float64}(Colors.color(c)); RGB(a * x.r + 1 - a, a * x.g + 1 - a, a * x.b + 1 - a))
opaque(c::Color) = RGB{Float64}(c)

"""
    figure_background(img) -> Union{Symbol,Nothing}

The theme a figure was drawn for, from its background: `:light` or `:dark` when the pixels around
its edge are mostly one light or dark gray and that gray covers much of the figure; `nothing` for
any other figure (a photograph, a colored panel), which is shown as it is.
"""
function figure_background(img::AbstractMatrix{<:Oklab})
    h, w = size(img)
    (h < 8 || w < 8) && return nothing
    edge = [img[i, j] for i in 1:h, j in 1:w if min(i, j) <= 3 || i > h - 3 || j > w - 3]
    gray = filter(o -> chroma(o) < GRAY_CHROMA, edge)
    length(gray) >= 0.8 * length(edge) || return nothing
    l = sort!([o.l for o in gray])[(length(gray) + 1) ÷ 2]
    0.3 < l < 0.85 && return nothing
    covers = count(o -> abs(o.l - l) < 0.08 && chroma(o) < GRAY_CHROMA, img) / length(img)
    covers >= 0.4 || return nothing
    return l >= 0.85 ? :light : :dark
end

"""
    recolor(img, target) -> Matrix{RGB}

The figure `img` (in Oklab, drawn for the other theme) recolored for the `target` theme, `:light` or
`:dark`: its grays carried from their place between its background and the opposite extreme to the
same place between `target`'s background and text, and its colors (and grays drawn among them) kept, with their lightness held
to what reads on `target`'s background (`DARK_MIN_L`, `LIGHT_MAX_L`).
"""
function recolor(img::AbstractMatrix{<:Oklab}, target::Symbol)
    to = THEME_COLORS[target]
    edge = [img[i, j].l for i in axes(img, 1), j in axes(img, 2) if min(i, j) <= 3 || i > size(img, 1) - 3 || j > size(img, 2) - 3]
    bg = sort!(edge)[(length(edge) + 1) ÷ 2]
    far = target == :dark ? 0.0 : 1.0                  # where the original's text and lines go to
    span = max(abs(far - bg), 0.3)
    colorful = box_mean(map(o -> Float64(chroma(o) >= COLOR_CHROMA), img), NEIGHBORHOOD)
    background = box_mean(map(o -> Float64(abs(o.l - bg) < 0.08 && chroma(o) < GRAY_CHROMA), img), NEIGHBORHOOD)
    return map(img, colorful, background) do o, near, open
        # 1: a gray, recolored; 0: a color, or a gray drawn on colors, kept.
        c = smoothstep(chroma(o), GRAY_CHROMA, COLOR_CHROMA)
        drawn_on = smoothstep(near, 0.3, 0.6) * (1 - smoothstep(open, 0.1, 0.3))
        w = (1 - c) * (1 - drawn_on)
        t = clamp(abs(o.l - bg) / span, 0, 1)                      # 0: the background; 1: the text
        # What is kept keeps its lightness, except that a color is held to what reads on the target.
        l = o.l + c * ((target == :dark ? max(o.l, DARK_MIN_L) : min(o.l, LIGHT_MAX_L)) - o.l)
        x = Oklab(w * (to.bg.l + t * (to.fg.l - to.bg.l)) + (1 - w) * l,
                  o.a + w * (to.bg.a + t * (to.fg.a - to.bg.a)), o.b + w * (to.bg.b + t * (to.fg.b - to.bg.b)))
        c = convert(RGB{Float64}, x)
        RGB{N0f8}(clamp(c.r, 0, 1), clamp(c.g, 0, 1), clamp(c.b, 0, 1))
    end
end

"""
    theme_figures(src) -> Union{NamedTuple,Nothing}

The figure at `src` (WebP or PNG) for each theme, `(; light, dark)`: the original for the theme it
was drawn for, and beside it, as `<name>-dark` or `<name>-light` in its format, its copy recolored
for the other (see [`recolor`](@ref)). `nothing` for a figure drawn for neither (see
[`figure_background`](@ref)). What was decided is kept in `<name>.theme`, and the figure is looked
at again when it changes.
"""
function theme_figures(src::AbstractString)
    stem, ext = splitext(src)
    note = stem * ".theme"
    if !(isfile(note) && mtime(note) >= mtime(src))
        img = convert.(Oklab, opaque.(load_image(src)))
        drawn = figure_background(img)
        if drawn !== nothing
            other = drawn == :light ? :dark : :light
            save_image("$stem-$other$ext", recolor(img, other))
        end
        write(note, string(something(drawn, "none")))
    end
    drawn = strip(read(note, String))
    return drawn == "light" ? (; light = src, dark = "$stem-dark$ext") :
           drawn == "dark" ? (; light = "$stem-light$ext", dark = src) : nothing
end

"[`theme_figures`](@ref) of `src`, or `nothing` when it cannot be recolored, with a warning naming it `what`."
function try_theme(src::AbstractString, what::AbstractString)
    try
        return theme_figures(src)
    catch e
        @warn "Could not recolor $what for the other theme" exception = e
        return nothing
    end
end
