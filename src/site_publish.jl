# A head start for a new knowledge base: the site as the publisher built it, published with the
# dataset (see dataset.jl). Two parts. Each site notebook's rendered bundle: running a notebook needs
# a Slate host and minutes, so a consumer whose notebook is the publisher's uses the publisher's
# render. And the built site itself: a consumer whose sources are the publisher's, and whose knowledge
# base is the dataset and nothing more, serves it rather than building it. Once either differs, the
# consumer builds as before, with the published renders for the notebooks it has not changed.

"Whether publishing and importing take the site's parts (the tests that do not need them turn it off)."
const SITE_PARTS = Ref(true)

"The rendered bundles' folder, the notebooks', and the mark a bundle installed from the dataset carries."
slate_dir(c::Config) = joinpath(site_root(c), "slate")
site_notebooks_dir(c::Config) = content_path(c, "notebooks")
const PUBLISHED_MARK = ".published"

"A notebook's digest as its rendered bundle records it: its content's SHA-256, line endings as LF."
notebook_sha(path::AbstractString) = bytes2hex(sha256(replace(read(path, String), "\r\n" => "\n")))

"""
The site's notebooks, as `name => file`: every `.jl` under the content's `notebooks`, at any depth
(a paper's and a day's have pages too), named as their rendered bundles are, by the file's name.
"""
function site_notebooks(c::Config)
    files = filter(f -> endswith(f, ".jl"), tree_files(site_notebooks_dir(c)))
    return sort!([splitext(basename(f))[1] => f for f in files])
end

"""
    tree_files(dir; skip = ()) -> Vector{String}

The files under `dir`, at any depth, as paths: hidden ones, and those in folders hidden, linked or
named in `skip`, left out. Not `walkdir`, which lists a folder from another task while its caller
prunes the folder's subfolders, so a walk pruned that way can take or miss folders at random.
"""
function tree_files(dir::AbstractString; skip = ())
    out = String[]
    isdir(dir) || return out
    # (A folder may go between being found and being read: a content sync replacing it, say.)
    for e in (try readdir(dir) catch; String[] end)
        startswith(e, ".") && continue
        p = joinpath(dir, e)
        if isdir(p)
            islink(p) || e in skip || append!(out, tree_files(p; skip))
        elseif isfile(p)
            push!(out, p)
        end
    end
    return out
end

"The folders of the package the site is built from, and the folders in them builds write."
const SITE_SOURCE_DIRS = ("src", "ext", joinpath("docs", "src"), joinpath("docs", "src", ".vitepress", "theme"))
const SITE_SOURCE_SKIP = ("generated", "node_modules", "build", "slate", "kb_public")

"""
    site_source_files(config; package = pkgdir(Zemi)) -> Vector{Pair{String,String}}

The files the site is built from (see [`site_source_digest`](@ref)), each as the name it has in the
digest `=>` its path: the package's (`zemi/…`), and the content's (`content/…`, see
[`content_path`](@ref)).
"""
function site_source_files(c::Config; package::AbstractString = pkgdir(@__MODULE__))
    files = String[]
    for top in SITE_SOURCE_DIRS
        append!(files, tree_files(joinpath(package, top); skip = SITE_SOURCE_SKIP))
    end
    for f in ("make.jl", "package.json")
        p = joinpath(package, "docs", f)
        isfile(p) && push!(files, p)
    end
    own = tree_files(c.content_dir)
    return [["zemi/" * relpath(f, package) => f for f in files if !env_manifest(f)];
            ["content/" * relpath(f, c.content_dir) => f for f in own if !env_manifest(f)]]
end

"""
    site_source_digest(config; package) -> String

A digest of what the site is built from, the same on every machine with the same files: the
package's code (`src`, `ext`), the pages and their theme (`docs/src`, less the pages builds write),
`docs/make.jl` and `docs/package.json`; and the content (its pages, notebooks, studies and images),
less the notebooks' environments' manifests, which each machine resolves.
"""
function site_source_digest(c::Config; package::AbstractString = pkgdir(@__MODULE__))
    entries = [name * " " * bytes2hex(sha256(read(p))) for (name, p) in site_source_files(c; package)]
    return bytes2hex(sha256(join(sort!(entries), "\n")))
end

"""
    site_packages!(dir) -> Bool

Write the site's npm packages, those `docs/package.json` names less the browser tests', as
`package.json` in `dir`, beside a build folder: DocumenterVitepress installs from there, and with
none, from its own template, which lacks the packages the components import. When they change, the
packages installed there are removed, to be installed afresh. Returns whether they changed.
"""
function site_packages!(dir::AbstractString)
    docs = joinpath(pkgdir(@__MODULE__), "docs")
    mkpath(dir)
    realpath(dir) == realpath(docs) && return false
    p = JSON.parsefile(joinpath(docs, "package.json"))
    p["devDependencies"] = filter(((k, _),) -> k != "playwright-core", get(p, "devDependencies", Dict()))
    text = JSON.json(p, 2)
    target = joinpath(dir, "package.json")
    changed = !isfile(target) || read(target, String) != text
    if changed
        # npm, installing over a lockfile written for other packages, can leave out a package's
        # binary for this platform (an optional dependency).
        rm(joinpath(dir, "node_modules"); recursive = true, force = true)
        rm(joinpath(dir, "package-lock.json"); force = true)
    end
    rm(target; force = true)                       # a copy of the template left read-only by an earlier build
    write(target, text)
    return changed
end

"Folder `dir` as a gzipped tarball."
function pack(dir::AbstractString)
    io = IOBuffer()
    Tar.create(dir, io)
    return gzip(take!(io))
end

"Unpack gzipped tarball `bytes` as folder `dir`, replacing what was there in one step."
function unpack!(bytes::AbstractVector{UInt8}, dir::AbstractString)
    tmp = dir * ".new"
    rm(tmp; recursive = true, force = true)
    mkpath(dirname(dir))
    Tar.extract(IOBuffer(gunzip(bytes)), tmp)
    rm(dir; recursive = true, force = true)
    mv(tmp, dir)
    return dir
end

"What a build of the site was made from, written beside it (see [`build_site!`](@ref)), or `nothing`."
function site_build_info(site::AbstractString)
    f = dirname(site) * ".json"            # a build serves `<builds>/<id>/1`; its record is `<builds>/<id>.json`
    return isfile(f) ? JSON.parsefile(f) : nothing
end

"""
Whether the site served is missing, or was built from other sources than those here now (see
[`site_source_digest`](@ref)): a newer package, or content changed while the service was down.
"""
function site_outdated(c::Config)
    served = current_site(c)
    served === nothing && return true
    info = site_build_info(served)
    return info === nothing || get(info, "sources", "") != site_source_digest(c)
end

"""
    documents_digest(kb) -> String

A digest of the fingerprint (see [`fingerprints`](@ref)) of every document of a kind the site is
built with: what a build's pages were written from. The site writes it as `DOCUMENTS_FILE`, and a publish pairs a site only with the
documents it was written from.
"""
function documents_digest(kb::KB)
    ids = sort!([String(r.id) for r in query(kb, "SELECT doc_id AS id FROM papers WHERE $(kind_in(k -> k.site))")])
    prints = fingerprints(kb, ids)
    return bytes2hex(sha256(join((id * " " * prints[id] for id in ids), "\n")))
end
const DOCUMENTS_FILE = "documents.sha256"

"Whether a build of the site is running: its process, named in the builds' pid file, is alive."
function site_building(c::Config)
    file = build_pid_file(builds_dir(c))
    pid = isfile(file) ? tryparse(Int, strip(read(file, String))) : nothing
    return pid !== nothing && ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
end

"""
How long a publish waits for the site to be written from the documents it publishes: for a build
to start (a change starts one within seconds), and for a running build to finish.
"""
const SITE_WAIT = Ref((start = 15.0, build = 3600.0))

"""
    site_for_documents(kb; progress) -> (site, current)

The site served, and whether it was written from the documents as they are now (see
[`documents_digest`](@ref)). While it was not, a publish waits for the build that brings it up to
date (see `SITE_WAIT`).
"""
function site_for_documents(kb::KB; progress = msg -> nothing)
    c = kb.config
    want = documents_digest(kb)
    t0, told = time(), -Inf
    while true
        served = current_site(c)
        served === nothing && return (nothing, false)
        f = joinpath(served, DOCUMENTS_FILE)
        isfile(f) && strip(read(f, String)) == want && return (served, true)
        waited = time() - t0
        waited < (site_building(c) ? SITE_WAIT[].build : SITE_WAIT[].start) || return (served, false)
        if waited - told >= 60
            progress("Waiting for the site to be rebuilt with the documents as they are now")
            told = waited
        end
        sleep(2)
    end
end

# ── Publishing ────────────────────────────────────────────────────────────────────────────────────

"""
    publish_site_parts!(kb, store, published; dataset, progress) -> (; notebooks, site)

The parts of the site a stream carries (see the top of this file), as its manifest names them:
`notebooks`, each site notebook whose bundle was rendered from it as it is now, `name => (; hash,
notebook)`; and `site`, the build served (see [`publish_site_packs!`](@ref)) with `dataset`, the
streams' publishes its documents are (`name => published_at`), or `nothing` when it is not
published: a shared service's (it has the accounts' pages), one with pages of documents not shared,
or one whose sources were not recorded. Each is uploaded unless `published`, the stream's manifest
before, already names it.
"""
function publish_site_parts!(kb::KB, store::DatasetStore, published::AbstractDict; dataset::AbstractDict = Dict(),
                             progress = msg -> nothing)
    notebooks = Dict{String,Any}()
    # (A manifest names a part that was not published as null.)
    before = something(get(published, "notebooks", nothing), Dict{String,Any}())
    for (name, file) in site_notebooks(kb.config)
        bundle = joinpath(slate_dir(kb.config), name)
        man = joinpath(bundle, "slate-bundle.json")
        isfile(man) || continue
        sha = notebook_sha(file)
        get(get(JSON.parsefile(man), "inputs", Dict()), "(notebook)", "") == sha || continue   # rendered from another version
        tarball = pack(bundle)
        hash = bytes2hex(sha256(tarball))
        if get(get(before, name, Dict()), "hash", "") != hash
            progress("Uploading the rendered notebook $name, $(round(length(tarball) / 1e6; digits = 1)) MB")
            write_object!(store, "notebooks/$hash.tar.gz", tarball)
        end
        notebooks[name] = Dict("hash" => hash, "notebook" => sha)
    end
    site = nothing
    # (A document only its projects' members see has no page on the site.)
    private = count(r -> !publishable(kb, r.id), query(kb, "SELECT doc_id AS id FROM papers WHERE $(open_sql())"))
    served = current_site(kb.config)
    info = served === nothing ? nothing : site_build_info(served)
    # (Waited for only when it would be published.)
    current = false
    if private == 0 && info !== nothing && get(info, "shared", false) != true
        served, current = site_for_documents(kb; progress)
        info = served === nothing ? nothing : site_build_info(served)
    end
    was = something(get(published, "site", nothing), Dict())
    if served === nothing || info === nothing
        progress("The site is not published: there is no build of it with its sources recorded")
    elseif get(info, "shared", false) == true
        progress("The site is not published: it is the shared service's, with the accounts' pages")
    elseif private > 0
        progress("The site is not published: it has pages of $private document(s) not shared")
    elseif !current
        progress("The site is not published: it was written before the latest changes to the documents; publish again once it is rebuilt")
    elseif get(was, "build", "") == info["build"] && haskey(was, "packs")
        site = was
    else
        site = publish_site_packs!(store, served, info, was; progress)
    end
    site === nothing || (site = merge(site, Dict("dataset" => dataset)))
    return (; notebooks, site)
end

"""
    publish_site_packs!(store, served, info, was; progress) -> Dict

Upload the built site `served` in packs (see site_packs.jl), those the site published before (`was`)
does not have, a few at a time; each compressed on a thread of its own. Returns the site as the
manifest names it: its `build` and `sources` (from its record, `info`), its `packs` (name =>
`hash`, the uncompressed tarball's, and `bytes`, compressed) and its pages' `refs`.
"""
function publish_site_packs!(store::DatasetStore, served::AbstractString, info::AbstractDict, was::AbstractDict;
                             progress = msg -> nothing)
    progress("Packing the built site")
    (; packs, refs) = site_packs(served)
    before = Dict(e["hash"] => e for e in values(something(get(was, "packs", nothing), Dict())))
    entries = Dict{String,Any}(name => Dict{String,Any}("hash" => bytes2hex(sha256(tar))) for (name, tar) in packs)
    new = sort!([name for (name, e) in entries if !haskey(before, e["hash"])])
    for (name, e) in entries
        haskey(before, e["hash"]) && (e["bytes"] = before[e["hash"]]["bytes"])
    end
    mb(n) = round(n / 1e6; digits = 1)
    progress("Uploading the built site: $(length(new)) of $(length(packs)) packs changed")
    done, sent = Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)
    asyncmap(new; ntasks = 6) do name
        e = entries[name]
        bytes = fetch(Threads.@spawn pack_compress(packs[name]))
        write_object!(store, "site/packs/$(e["hash"]).tar.zst", bytes)
        e["bytes"] = length(bytes)
        n, total = Threads.atomic_add!(done, 1) + 1, Threads.atomic_add!(sent, length(bytes)) + length(bytes)
        progress("Uploading the built site: $n of $(length(new)) changed packs, $(mb(total)) MB")
    end
    return Dict("build" => info["build"], "sources" => info["sources"], "packs" => entries, "refs" => refs)
end

"How long a site's pack or a notebook's bundle no manifest names is kept before a publish deletes it."
const PRUNE_GRACE = Ref{Period}(Day(1))

"""
    prune_site_parts!(store, manifests, before; progress) -> Int

Delete the site's packs and the notebooks' bundles that no stream's manifest (`manifests`) names,
nor the one `before` the stream's new one (an import that read it may still be fetching them), and
that are older than `PRUNE_GRACE`.
Returns how many.
"""
function prune_site_parts!(store::DatasetStore, manifests, before::AbstractDict; progress = msg -> nothing)
    keep = Set{String}()
    for m in [collect(manifests); before]
        s = get(m, "site", nothing)
        s isa AbstractDict && union!(keep, "site/packs/$(e["hash"]).tar.zst" for e in values(get(s, "packs", Dict())))
        union!(keep, "notebooks/$(e["hash"]).tar.gz" for e in values(something(get(m, "notebooks", nothing), Dict())))
    end
    # One no manifest names yet may be another member's, uploaded for the manifest they have still to write.
    old(t) = now(UTC) - t > PRUNE_GRACE[]
    gone = [k for prefix in ("site/", "notebooks/") for (k, t) in list_objects(store, prefix; modified = true) if !(k in keep) && old(t)]
    isempty(gone) && return 0
    progress("Deleting $(length(gone)) site and notebook objects no manifest names")
    asyncmap(k -> delete_object!(store, k), gone; ntasks = 8)
    return length(gone)
end

# ── Importing ─────────────────────────────────────────────────────────────────────────────────────

"""
    install_site_parts!(kb, store, manifest; progress)

Take the parts of the site the dataset carries (see [`publish_site_parts!`](@ref)): the rendered
bundle of each site notebook that is here as the publisher rendered it, unless one rendered here
from it is already in place; and the built site, served at once, when this machine's sources are
the publisher's (see [`site_source_digest`](@ref)) and it serves no site of its own build.
"""
function install_site_parts!(kb::KB, store::DatasetStore, m::AbstractDict; progress = msg -> nothing)
    c = kb.config
    fetch(key, hash) = (got = read_object(store, key);
                        got === nothing ? error("The dataset names $key, which is missing") :
                        bytes2hex(sha256(got)) == hash ? got : error("$key does not match its hash"))
    files = Dict(site_notebooks(c))
    for (name, e) in something(get(m, "notebooks", nothing), Dict{String,Any}())
        file = get(files, name, "")
        isfile(file) && notebook_sha(file) == e["notebook"] || continue      # not the notebook rendered
        dir = joinpath(slate_dir(c), name)
        mark = joinpath(dir, PUBLISHED_MARK)
        isfile(mark) && split(read(mark, String))[1] == e["hash"] && continue
        man = joinpath(dir, "slate-bundle.json")
        !isfile(mark) && isfile(man) && get(get(JSON.parsefile(man), "inputs", Dict()), "(notebook)", "") == e["notebook"] && continue
        progress("Downloading the rendered notebook $name")
        unpack!(fetch("notebooks/$(e["hash"]).tar.gz", e["hash"]), dir)
        write(mark, e["hash"] * " " * e["notebook"])
    end
    s = get(m, "site", nothing)
    s === nothing && return
    # A build is named by the time it started; any other name could point the site's folder elsewhere.
    occursin(r"^\d{8}T\d{6}$", string(s["build"])) || (@warn "The dataset's site names a build that is not one, left out" s["build"]; return)
    served = current_site(c)
    info = served === nothing ? nothing : site_build_info(served)
    own_build = served !== nothing && (info === nothing || !haskey(info, "published"))
    own_build && return
    record = Dict("build" => s["build"], "sources" => s["sources"], "published" => s["build"], "dataset" => s["dataset"])
    out = joinpath(builds_dir(c), s["build"])
    if info !== nothing && get(info, "published", "") == s["build"]
        write(out * ".json", JSON.json(record))      # the same build, now of the dataset as imported
        return
    end
    s["sources"] == site_source_digest(c) || return
    assemble_site!(joinpath(out, "1"), fetch_site_packs!(c, store, s["packs"]; progress), s["refs"])
    write(out * ".json", JSON.json(record))
    switch_site!(c, joinpath(out, "1"))
    lock(() -> SITE.id = s["build"], SITE_LOCK)
    @info "[site] Serving the site as published ($(s["build"]))"
end

"Where the packs of the site last taken from the dataset are kept, so the next takes only new ones."
site_packs_dir(c::Config) = joinpath(dirname(builds_dir(c)), "packs")

"""
    fetch_site_packs!(c, store, packs; progress) -> Vector

The tarballs of the site's `packs` (see [`publish_site_packs!`](@ref)): those not kept from the site
taken before are downloaded, a few at a time, and each checked against its hash. Packs no longer
named are removed.
"""
function fetch_site_packs!(c::Config, store::DatasetStore, packs::AbstractDict; progress = msg -> nothing)
    dir = site_packs_dir(c)
    mkpath(dir)
    file(e) = joinpath(dir, e["hash"] * ".tar.zst")
    new = [e for e in values(packs) if !isfile(file(e))]
    mb(n) = round(n / 1e6; digits = 1)
    total = sum(e -> e["bytes"], new; init = 0)
    progress("Downloading the built site: $(length(new)) of $(length(packs)) packs, $(mb(total)) MB")
    got = Threads.Atomic{Int}(0)
    asyncmap(new; ntasks = 8) do e
        key = "site/packs/$(e["hash"]).tar.zst"
        bytes = read_object(store, key)
        bytes === nothing && error("The dataset names $key, which is missing")
        bytes2hex(sha256(pack_decompress(bytes))) == e["hash"] || error("$key does not match its hash")
        write(file(e) * ".part", bytes)
        mv(file(e) * ".part", file(e); force = true)
        progress("Downloading the built site: $(mb(Threads.atomic_add!(got, length(bytes)) + length(bytes))) of $(mb(total)) MB")
    end
    keep = Set(basename(file(e)) for e in values(packs))
    for f in readdir(dir)
        f in keep || rm(joinpath(dir, f); force = true)
    end
    return [pack_decompress(read(file(e))) for e in values(packs)]
end

"""
    published_site_current(c; db = kb) -> Bool

Whether the site served is the publisher's and nothing here differs from what it was built from:
the same sources (see [`site_source_digest`](@ref)), the dataset it came with, and no documents but
the dataset's. A build then would only make it again. The knowledge base (`db()`) is opened only
for a site that came published. Why a published site is no longer current is logged.
"""
function published_site_current(c::Config; db = kb)
    stamp(streams) = isempty(streams) ? "none" : join(("$n $t" for (n, t) in sort!(collect(streams))), ", ")
    served = current_site(c)
    served === nothing && return false
    info = site_build_info(served)
    (info === nothing || !haskey(info, "published")) && return false
    k = db()
    imported = streams_imported(k)
    own = scalar(k, "SELECT count(*) FROM papers WHERE doc_id NOT IN (SELECT doc_id FROM dataset_docs)")
    why = imported != info["dataset"] ? "the streams imported ($(stamp(imported))) are not those it came with ($(stamp(info["dataset"])))" :
          own > 0 ? "$own document(s) here are not the dataset's" :
          info["sources"] != site_source_digest(c) ? "the sources here differ from those it was built from" : ""
    isempty(why) || @info "[site] Building here, not serving the published site: $why"
    return isempty(why)
end

"""
Whether every site notebook has the bundle published for it as it is now (see
[`install_site_parts!`](@ref)): a build then uses them as they are rather than running notebooks,
which a machine with a Slate host of its own would do because its environments differ.
"""
function published_renders_current(c::Config)
    nbs = site_notebooks(c)
    isempty(nbs) && return false
    return all(nbs) do (name, file)
        mark = joinpath(slate_dir(c), name, PUBLISHED_MARK)
        isfile(mark) && (parts = split(read(mark, String)); length(parts) == 2 && parts[2] == notebook_sha(file))
    end
end
