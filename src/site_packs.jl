# The built site in packs, as it is published with the dataset (see site_publish.jl). A site is
# thousands of files, most of them the same from one build to the next, so it is not sent as one
# tarball: its files are split among a fixed set of packs, and each pack is stored under its
# content's hash. Publishing uploads, and an import downloads, only the packs whose files changed.
#
# Files that change together share a pack (see `pack_names`), so a change touches few packs: a
# document's page, scripts and figures; the pages listing every document; and VitePress's scripts
# that change with any change to the site.
#
# A page names the scripts and styles it loads by their content hash (`assets/app.Co2i6kGo.js`),
# and those change with any change to the site's code. So a page is packed with each such
# reference written by name (`assets/app.#kb#.js`), and the manifest maps each name to this build's
# file (see `site_refs`): a page's pack changes only when the page does.

"How many packs the documents' files go into, the site's other pages, and VitePress's other scripts."
const DOC_PACKS = 32
const PAGE_PACKS = 8
const CHUNK_PACKS = 8

"""
VitePress's files that change with any change to a page or to the site's code: its entry script and
styles, the map of the pages' scripts, the theme and the search index.
"""
const HOT = r"^(assets/(app|style)\.|assets/chunks/(metadata|theme|VPLocalSearchBox|@localSearchIndex)|hashmap\.json$)"

"The pages that list every document, which change whenever one is added (see site.jl)."
const HUB_PAGES = Set(replace(p, "/" => "_") for p in
                      ("generated/kb/index", "generated/kb/timeline", "generated/kb/topics", "generated/kb/status", "generated/kb/authors"))

"The content hash VitePress writes into a file's name (`app.Co2i6kGo.js`, `index.md.Cp4ouCgi.lean.js`)."
const CONTENT_HASH = r"\.[A-Za-z0-9_-]{8}(?=(\.lean)?\.[A-Za-z0-9]+$)"

"What a packed page writes in place of a content hash, in a reference by name."
const REF_MARK = ".#kb#"

# A page's reference to a file of the site, and one written by name.
const ASSET_REF = r"assets/[A-Za-z0-9_@./-]+"
const NAMED_REF = r"assets/[A-Za-z0-9_@./-]*?\.#kb#(\.lean)?\.[A-Za-z0-9]+"

"""
How hard packs are compressed: zstd at this level keeps a window larger than any pack, so a pack's
pages share what they have in common.
"""
const PACK_LEVEL = 19

pack_compress(tar::AbstractVector{UInt8}) = transcode(ZstdCompressor(; level = PACK_LEVEL), tar)
pack_decompress(bytes::AbstractVector{UInt8}) = transcode(ZstdDecompressor, bytes)

"A file's path in the site (`/`-separated) without its content hash: the same from build to build."
stable_path(rel::AbstractString) = replace(rel, CONTENT_HASH => "")

"One of `n` packs named `group-NN`, the same for the same `key` on every machine."
function bucket(group::AbstractString, key::AbstractString, n::Integer)
    h = sha256(key)
    return group * "-" * lpad((UInt32(h[1]) << 24 | UInt32(h[2]) << 16 | UInt32(h[3]) << 8 | UInt32(h[4])) % n, 2, '0')
end

"""
The page a file of the site belongs to, as VitePress names a page's script
(`generated_kb_papers_2609-39376`): a page itself, its scripts, and a document's figures. `nothing`
for any other file.
"""
function page_of(rel::AbstractString)
    endswith(rel, ".html") && return replace(chopsuffix(rel, ".html"), "/" => "_")
    m = match(r"^assets/(.+?)\.md\.", rel)
    m === nothing || return String(m[1])
    m = match(r"^assets/(\d{4}-\d{4,5}|doc-[0-9a-f]+)-\d", rel)
    return m === nothing ? nothing : "generated_kb_papers_" * m[1]
end

"""
VitePress's scripts that change with any change to the site: those of `HOT`, and any of its shared
scripts importing one of those, directly or through another (an import names a script by its
content hash, so the importer is renamed with it).
"""
function hot_files(site::AbstractString, files)
    scripts = filter(f -> startswith(f, "assets/") && endswith(f, ".js"), files)
    imports = Dict(f => Set("assets/" * normpath(joinpath(dirname(f[8:end]), m[1]))
                            for m in eachmatch(r"[\"'](\.\.?/[A-Za-z0-9_@./-]+\.js)[\"']", read(joinpath(site, f), String)))
                   for f in scripts)
    hot = Set(filter(f -> occursin(HOT, f), files))
    while true
        more = [f for f in scripts if startswith(f, "assets/chunks/") && !(f in hot) && !isdisjoint(imports[f], hot)]
        isempty(more) && return hot
        union!(hot, more)
    end
end

"""
    pack_names(site, files) -> Dict

The pack each of the site's `files` goes into, files that change together in one:
- `runtime`: VitePress's scripts that change with any change to the site (see [`hot_files`](@ref));
- `hub`: the pages listing every document, with their scripts, and the site's data files (`papers.json`, the bibliography);
- `docs-NN`: a document's page, scripts and figures, together, by the document;
- `chunks-NN`: VitePress's other shared scripts;
- `pages-NN`: everything else, by page.
"""
function pack_names(site::AbstractString, files)
    hot = hot_files(site, files)
    return Dict(f => begin
        page = page_of(f)
        f in hot ? "runtime" :
        startswith(f, "assets/chunks/") ? bucket("chunks", stable_path(f), CHUNK_PACKS) :
        page !== nothing && startswith(page, "generated_kb_papers_") ? bucket("docs", page, DOC_PACKS) :
        page !== nothing && page in HUB_PAGES ? "hub" :
        page === nothing && occursin(r"^[^/]+\.(json|bib|inv)$", f) ? "hub" :
        bucket("pages", something(page, stable_path(f)), PAGE_PACKS)
    end for f in files)
end

"Every file in folder `dir`, hidden ones too, as `/`-separated paths in it."
function all_files(dir::AbstractString)
    out = String[]
    for (d, _, fs) in walkdir(dir), f in fs                 # nothing pruned, so walkdir's listing holds
        push!(out, join(splitpath(relpath(joinpath(d, f), dir)), '/'))
    end
    return sort!(out)
end

"""
    site_refs(files) -> Dict

The files a packed page refers to by name: each file with a content hash, by its path without it
(`assets/app.js` => `assets/app.Co2i6kGo.js`). Only names one file has: VitePress names many chunks
`index`, and references to those stay as they are.
"""
function site_refs(files)
    by = Dict{String,Vector{String}}()
    for f in files
        (endswith(f, ".html") || !occursin(CONTENT_HASH, f)) && continue
        push!(get!(by, stable_path(f), String[]), f)
    end
    return Dict(k => only(v) for (k, v) in by if length(v) == 1)
end

"Page `html` as packed: its references to the files of `refs` written by name."
function pack_page(html::AbstractString, named::AbstractDict)
    return replace(html, ASSET_REF => m -> get(named, m, m))
end

"A packed page as served: its references by name to the files `refs` maps them to."
function unpack_page(html::AbstractString, refs::AbstractDict)
    return replace(html, NAMED_REF => m -> refs[replace(m, REF_MARK => "")])
end

"""
    site_packs(site) -> (; packs, refs)

The built site in folder `site` in packs (see the top of this file): `packs`, each pack's name =>
its tarball, uncompressed and the same bytes for the same files; and `refs` (see [`site_refs`](@ref)).
"""
function site_packs(site::AbstractString)
    files = all_files(site)
    refs = site_refs(files)
    named = Dict(f => replace(f, CONTENT_HASH => REF_MARK) for f in values(refs))
    pack = pack_names(site, files)
    stage = mktempdir()
    try
        for f in files
            to = joinpath(stage, pack[f], split(f, '/')...)
            mkpath(dirname(to))
            endswith(f, ".html") ? write(to, pack_page(read(joinpath(site, f), String), named)) : cp(joinpath(site, f), to)
        end
        packs = Dict{String,Vector{UInt8}}()
        for p in readdir(stage)
            io = IOBuffer()
            Tar.create(joinpath(stage, p), io)
            packs[p] = take!(io)
        end
        return (; packs, refs)
    finally
        rm(stage; recursive = true, force = true)
    end
end

"Move what folder `from` holds into folder `to`, into its folders where both have one."
function merge_folder!(from::AbstractString, to::AbstractString)
    for e in readdir(from)
        src, dst = joinpath(from, e), joinpath(to, e)
        isdir(src) && isdir(dst) ? merge_folder!(src, dst) : mv(src, dst; force = true)
    end
end

"""
    assemble_site!(dir, tarballs, refs)

The site from its packs' `tarballs`, written as folder `dir`, which is replaced in one step: their
files, the pages' references restored (see [`unpack_page`](@ref)).
"""
function assemble_site!(dir::AbstractString, tarballs, refs::AbstractDict)
    tmp = dir * ".new"
    rm(tmp; recursive = true, force = true)
    mkpath(tmp)
    for tar in tarballs
        part = mktempdir(dirname(tmp))
        Tar.extract(IOBuffer(tar), part)
        merge_folder!(part, tmp)
        rm(part; recursive = true, force = true)
    end
    for f in all_files(tmp)
        endswith(f, ".html") || continue
        p = joinpath(tmp, f)
        write(p, unpack_page(read(p, String), refs))
    end
    rm(dir; recursive = true, force = true)
    mv(tmp, dir)
    return dir
end
