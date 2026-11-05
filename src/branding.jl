# The knowledge base's look: its logo, from which the site's icons are made (the top bar's logo, the
# browser's icon and favicon, the large icons phones ask for), and the front page's image, for light
# and dark. Kept in the content's assets (see `content_path`), where they take the place of Zemi's,
# and so travel with the content through the dataset.

"The images that can be replaced, as the Configuration page names them, with the files each is kept as."
const BRAND_IMAGES = Dict("logo" => ["logo.png", "icon.png", "favicon.ico"],
                          "hero-light" => ["hero-light.svg", "hero-light.png"], "hero-dark" => ["hero-dark.svg", "hero-dark.png"])

"Image `img` (a matrix of colours) as a square, centred on a transparent ground."
function square_image(img::AbstractMatrix)
    h, w = size(img)
    n = max(h, w)
    out = fill(RGBA{N0f8}(0, 0, 0, 0), n, n)
    top, left = (n - h) ÷ 2, (n - w) ÷ 2
    out[top+1:top+h, left+1:left+w] .= RGBA{N0f8}.(img)
    return out
end

"""
    resize_square(img, n) -> Matrix

Square image `img` at `n` by `n` pixels: each pixel the average of those it covers, weighted by how
much of each it covers, with colour weighted by opacity so transparent edges do not darken.
"""
function resize_square(img::AbstractMatrix, n::Integer)
    m = size(img, 1)
    px = [(Float64(red(c)) * alpha(c), Float64(green(c)) * alpha(c), Float64(blue(c)) * alpha(c), Float64(alpha(c))) for c in img]
    scale = m / n
    # How much of source row/column k the output's i covers.
    function weights(i)
        lo, hi = (i - 1) * scale, i * scale
        [(k, min(hi, k) - max(lo, k - 1)) for k in max(1, floor(Int, lo) + 1):min(m, ceil(Int, hi))]
    end
    out = Matrix{RGBA{N0f8}}(undef, n, n)
    for i in 1:n, j in 1:n
        r = g = b = a = 0.0; total = 0.0
        for (y, wy) in weights(i), (x, wx) in weights(j)
            w = wy * wx
            p = px[y, x]
            r += w * p[1]; g += w * p[2]; b += w * p[3]; a += w * p[4]; total += w
        end
        a /= total
        out[i, j] = a == 0 ? RGBA{N0f8}(0, 0, 0, 0) :
            RGBA{N0f8}(clamp(r / total / a, 0, 1), clamp(g / total / a, 0, 1), clamp(b / total / a, 0, 1), clamp(a, 0, 1))
    end
    return out
end

png_bytes(img) = (io = IOBuffer(); PNGFiles.save(io, img); take!(io))

"""
    ico_file(pngs) -> Vector{UInt8}

An icon file (`.ico`) holding PNG images, as `size => bytes` pairs: what browsers read as a favicon.
"""
function ico_file(pngs::AbstractVector)
    io = IOBuffer()
    write(io, UInt16(0), UInt16(1), UInt16(length(pngs)))
    offset = 6 + 16 * length(pngs)
    for (n, bytes) in pngs
        write(io, UInt8(n >= 256 ? 0 : n), UInt8(n >= 256 ? 0 : n), UInt8(0), UInt8(0), UInt16(1), UInt16(32),
              UInt32(length(bytes)), UInt32(offset))
        offset += length(bytes)
    end
    foreach(p -> write(io, p[2]), pngs)
    return take!(io)
end

"""
    set_logo!(kb, png) -> Vector{String}

Make the knowledge base's logo the PNG image `png` (at least 64 pixels across; one not square is
centred on a transparent square): `logo.png` at 256 pixels, `icon.png` at 64 and `favicon.ico` at 16,
32 and 48, in the content's assets. Returns the files written.
"""
function set_logo!(kb::KB, png::AbstractVector{UInt8})
    img = try PNGFiles.load(IOBuffer(png)) catch; error("The logo must be a PNG image") end
    maximum(size(img)) >= 64 || error("The logo must be at least 64 pixels across; this one is $(size(img, 2))×$(size(img, 1))")
    sq = square_image(img)
    dir = mkpath(content_path(kb.config, "assets"))
    write(joinpath(dir, "logo.png"), png_bytes(resize_square(sq, 256)))
    write(joinpath(dir, "icon.png"), png_bytes(resize_square(sq, 64)))
    write(joinpath(dir, "favicon.ico"), ico_file([n => png_bytes(resize_square(sq, n)) for n in (16, 32, 48)]))
    return BRAND_IMAGES["logo"]
end

"""
Whether SVG text `svg` is an image only: no scripts, event handlers, embedded documents, entities or
links to elsewhere. (Served on its own, an SVG also runs sandboxed: see `file_response`.)
"""
function safe_svg(svg::AbstractString)
    occursin(r"<svg[\s>/]"i, svg) || return false
    # (A prefixed element, `<s:script>`, is a script too; so is a handler after a slash, `<svg/onload=`.)
    return !occursin(r"<!DOCTYPE|<!ENTITY|<([\w-]+:)?(script|foreignObject|iframe|embed|object)\b|[\s/\"']on[a-z]+\s*=|javascript:|(href|src)\s*=\s*[\"'](?!#|data:image/)"i, svg)
end

"""
    set_hero!(kb, which, bytes) -> String

Make the front page's image for `which` (`"hero-light"` or `"hero-dark"`) the SVG or PNG `bytes`,
replacing the other kind. An SVG may hold no scripts or links: it is served from the site itself.
Returns the file written.
"""
function set_hero!(kb::KB, which::AbstractString, bytes::AbstractVector{UInt8})
    which in ("hero-light", "hero-dark") || not_found("No image $which")
    png = length(bytes) > 8 && bytes[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    png || safe_svg(String(copy(bytes))) || error("The image must be a PNG, or an SVG without scripts or links")
    dir = mkpath(content_path(kb.config, "assets"))
    foreach(f -> rm(joinpath(dir, f); force = true), BRAND_IMAGES[which])
    file = "$which.$(png ? "png" : "svg")"
    write(joinpath(dir, file), bytes)
    return file
end

"Put back Zemi's own image for `which` (see `BRAND_IMAGES`), removing the content's."
function reset_brand!(kb::KB, which::AbstractString)
    haskey(BRAND_IMAGES, which) || not_found("No image $which")
    foreach(f -> rm(content_path(kb.config, "assets", f); force = true), BRAND_IMAGES[which])
end

"""
    hero_files(c) -> Vector{Pair{String,String}}

The front page's images, as `name => path`: the content's light and dark ones (either standing in
for the other), else its logo, else Zemi's.
"""
function hero_files(c::Config)
    own(which) = (fs = filter(f -> isfile(content_path(c, "assets", f)), BRAND_IMAGES[which]); isempty(fs) ? nothing : first(fs))
    light, dark = own("hero-light"), own("hero-dark")
    if light !== nothing || dark !== nothing
        return unique([f => content_path(c, "assets", f) for f in (something(light, dark), something(dark, light))])
    end
    isfile(content_path(c, "assets", "logo.png")) && return ["logo.png" => content_path(c, "assets", "logo.png")]
    return [f => site_icon(c, f) for f in ("hero-light.svg", "hero-dark.svg")]
end

"""
    brand_file(c, which) -> String

The file the site shows for `which`: the logo, or the front page's light or dark image (see
[`hero_files`](@ref)).
"""
function brand_file(c::Config, which::AbstractString)
    which == "logo" && return site_icon(c, "logo.png")
    heroes = hero_files(c)
    return last(which == "hero-light" ? first(heroes) : last(heroes))
end

"The images, whether each is the knowledge base's own, and a version mark for each, for the Configuration page."
brand_json(kb::KB) = Dict(which => Dict("own" => any(f -> isfile(content_path(kb.config, "assets", f)), files),
                                         "version" => string(round(Int, mtime(brand_file(kb.config, which)))))
                          for (which, files) in BRAND_IMAGES)
