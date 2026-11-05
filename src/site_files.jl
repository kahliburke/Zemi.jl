# The site's files as the service sends them: from the build served, with their content types,
# caching and ETags, and its icon.

const CONTENT_TYPES = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
    ".mjs" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8", ".json" => "application/json",
    ".svg" => "image/svg+xml", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
    ".webp" => "image/webp", ".ico" => "image/x-icon", ".woff" => "font/woff", ".woff2" => "font/woff2", ".txt" => "text/plain; charset=utf-8",
    ".bib" => "text/plain; charset=utf-8", ".jl" => "text/plain; charset=utf-8", ".pdf" => "application/pdf", ".xml" => "application/xml",
    ".map" => "application/json", ".wasm" => "application/wasm")

"""
    site_file(c, path) -> Union{String,Nothing}

The file of the site served for `path`: as given, with `.html` (clean addresses), or a folder's
`index.html`. An asset the build served has not got (a page opened before the last switch asking for
its chunks) is looked for in the earlier builds still kept.
"""
function site_file(c::Config, path::AbstractString)
    root = current_site(c)
    root === nothing && return nothing
    rel = normpath(lstrip(HTTP.unescapeuri(path), '/'))
    (rel == "." || isempty(rel)) && (rel = "index.html")
    (startswith(rel, "..") || isabspath(rel)) && return nothing
    for cand in (rel, rel * ".html", joinpath(rel, "index.html"))
        f = joinpath(root, cand)
        isfile(f) && return f
    end
    # A page made from a template whose copy is not written yet: its kind's template (see `TEMPLATED`).
    for (_, (; folder, template)) in TEMPLATED
        m = match(Regex("^" * join(("\\Q$part\\E" for part in split(folder, '*')), "[^/]+") * "/[^/]+?(\\.html)?\$"), rel)
        m === nothing || (f = joinpath(root, template * ".html"); isfile(f) && return f)
    end
    if startswith(rel, "assets/") && isdir(builds_dir(c))
        for b in sort!(readdir(builds_dir(c)); rev = true)
            f = joinpath(builds_dir(c), b, "1", rel)
            isfile(f) && return f
        end
    end
    return nothing
end

"""
    file_response(f; status = 200, req = nothing) -> HTTP.Response

File `f` of the site. Content-hashed assets are kept for good; images not hashed (the logos) for a
day; pages and data are asked about each time. Each carries an `ETag` of its content, so a browser
asking about a copy it has (`If-None-Match`, from `req`) is told it is current without the file.
"""
function file_response(f::AbstractString; status = 200, req::Union{HTTP.Request,Nothing} = nothing)
    ext = lowercase(splitext(f)[2])
    # Kept for good: a build's files named by their content's hash (`app.Cp4ouCgi.js`). Not the
    # knowledge base's own images, which keep their names when they change (the logo, say).
    hashed = occursin(r"/assets/[^/]*\.[A-Za-z0-9_-]{8}\.[a-z0-9]+$", f)
    cache = hashed ? "public, max-age=31536000, immutable" :
            ext in (".png", ".jpg", ".jpeg", ".svg", ".ico", ".webp", ".gif") ? "public, max-age=86400" : "no-cache"
    tag = file_etag(f)
    headers = ["Cache-Control" => cache, "ETag" => tag, "X-Content-Type-Options" => "nosniff"]
    # An SVG opened on its own runs no script on the site's origin, whoever put it there.
    ext == ".svg" && push!(headers, "Content-Security-Policy" => "sandbox")
    status == 200 && req !== nothing && tag in strip.(split(HTTP.header(req, "If-None-Match", ""), ',')) &&
        return HTTP.Response(304, headers)
    return HTTP.Response(status, ["Content-Type" => get(CONTENT_TYPES, ext, "application/octet-stream"); headers], read(f))
end

# The ETags of the site's files, by path, with the time each was written: a file is hashed once.
# Each build writes its files under a path of its own, so the tags of files gone (a build removed)
# are dropped as the table grows.
const ETAGS = Dict{String,Tuple{Float64,String}}()
const ETAGS_LOCK = ReentrantLock()
const ETAGS_MAX = 20_000

"An ETag for file `f`, from its content: builds write every file anew, and one unchanged keeps its tag."
function file_etag(f::AbstractString)
    t = mtime(f)
    got = lock(() -> get(ETAGS, f, nothing), ETAGS_LOCK)
    got !== nothing && got[1] == t && return got[2]
    tag = "\"" * bytes2hex(open(sha256, f))[1:32] * "\""
    lock(ETAGS_LOCK) do
        length(ETAGS) >= ETAGS_MAX && filter!(p -> isfile(first(p)), ETAGS)
        ETAGS[f] = (t, tag)
    end
    return tag
end

"""
Where browsers and other clients look for a site's icon, each answered with the logo: small (64
pixels, a few kilobytes) where a small icon is shown, and the full 256 where a large one is.
"""
const ICON_PATHS = Dict(path => "icon.png" for path in ("/favicon.png", "/favicon-16x16.png", "/favicon-32x32.png",
                                                        "/favicon-96x96.png", "/icon.png"))
ICON_PATHS["/favicon.ico"] = "favicon.ico"
foreach(path -> ICON_PATHS[path] = "logo.png",
        ("/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/android-chrome-192x192.png", "/android-chrome-512x512.png"))
"The site's image `name` (its icon, `icon.png`, or logo, `logo.png`): the content's own (see [`content_path`](@ref)), else the package's."
function site_icon(c::Config, name::AbstractString = "icon.png")
    own = content_path(c, "assets", name)
    return isfile(own) ? own : joinpath(pkgdir(@__MODULE__), "docs", "src", "assets", name)
end

"The head line naming the site's icon, for the service's own pages."
const ICON_LINK = """<link rel="icon" type="image/png" href="/favicon.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">"""
