using Test
using Zemi
# Kaimon, so its extension loads: agents and tools are tested with it, through stand-ins.
import Kaimon
using Zemi: Span, TextLine, RawBlock, parse_blocks, keyword_query, point_id,
    parse_arxiv_feed, split_long, CHUNK_MAX, query, scalar, compose_accents

const K = Zemi
# Uploads are not looked up in OpenAlex here; the look-up is tested with a stand-in.
K.UPLOAD_LOOKUP[] = (p; contact = "") -> nothing
K.DOI_COPIES[] = (doi; contact = "") -> (; arxiv = nothing, pdf = nothing)
K.ARXIV_TITLE_SEARCH[] = (title, c) -> K.PaperMeta[]
include("s3_standin.jl")

# A span of body text at the given position; widths are rough, which is all layout needs.
span(x, y, text; size = 10.0, font = "CMR10", bold = false, italic = false) =
    Span(x, y, x + 0.5 * size * length(text), y + size, font, size, bold, italic, text)
line(spans...) = TextLine(collect(spans))
block(page, lines...) = RawBlock(page, collect(lines))

temp_config(; kw...) = Config(; data_dir = mktempdir(), collection_prefix = "zemi_test", kw...)

# The suite's testsets: all of them, or with names given as arguments (`run_tests(pattern = "dataset")`
# passes its pattern so) those whose names contain one, each timed for the report at the end. One left
# out is left out as the file is read, so it is not even compiled.
const ONLY = lowercase.(ARGS)
const TIMES = Pair{String,Float64}[]
# The testsets by time, slowest first, when the run ends (pass or fail): zemi-test-times.txt in the temp folder.
atexit() do
    report = join(("$(rpad(n, 56)) $(round(t; digits = 1)) s" for (n, t) in sort(TIMES; by = last, rev = true)), "\n")
    write(joinpath(tempdir(), "zemi-test-times.txt"), report)
end
macro zset(name::String, body)
    isempty(ONLY) || any(o -> occursin(o, lowercase(name)), ONLY) || return nothing
    run = esc(Expr(:macrocall, Symbol("@testset"), __source__, name, body))
    return quote
        let t0 = time()
            $run
            push!(TIMES, $name => time() - t0)
        end
    end
end
# Publishing and importing take the site's parts only where a test asks for them (see site_publish.jl).
Zemi.SITE_PARTS[] = false
# The tests' repositories are on this disk, in shared mode too (see `check_remote`).
Zemi.LOCAL_REPOSITORIES[] = true

"A stand-in Qdrant on a free port: collections of points kept in memory. Returns (server, collections, port)."
# Which Qdrant the client uses, to put back after a test points it elsewhere.
qdrant_state() = (K.Qdrant.ENDPOINT[], K.Qdrant.URL[], K.Qdrant.KEY[])
restore_qdrant!(s) = ((K.Qdrant.ENDPOINT[], K.Qdrant.URL[], K.Qdrant.KEY[]) = s; K.Qdrant.RESOLVED_AT[] = 0.0; nothing)

function standin_qdrant()
    HTTP, JSON = K.HTTP, K.JSON
    colls = Dict{String,Dict{String,Any}}()
    qport = 18000 + rand(0:999)
    ok(result) = HTTP.Response(200, JSON.json(Dict("status" => "ok", "result" => result)))
    qdrant = HTTP.serve!("127.0.0.1", qport) do req
        parts = split(strip(HTTP.URI(req.target).path, '/'), '/')
        raw = req.method == "GET" ? UInt8[] : Vector{UInt8}(req.body)     # (a GET's empty body is not bytes)
        body = isempty(raw) ? Dict() : JSON.parse(String(raw))
        if req.method == "GET" && parts == ["healthz"]
            HTTP.Response(200, "healthz check passed")
        elseif req.method == "GET" && parts == ["collections"]
            ok(Dict("collections" => [Dict("name" => c) for c in keys(colls)]))
        elseif req.method == "PUT" && length(parts) == 2
            get!(colls, parts[2], Dict{String,Any}()); ok(true)
        elseif req.method == "PUT" && length(parts) == 3
            for p in body["points"]; colls[parts[2]][string(p["id"])] = (p["vector"], p["payload"]); end
            ok(Dict("status" => "completed"))
        elseif req.method == "POST" && length(parts) == 4 && parts[4] == "search"
            haskey(colls, parts[2]) || return HTTP.Response(404, "{}")          # as Qdrant answers for one not made
            q = Float64.(body["vector"])
            cosine(v) = sum(q .* v) / max(sqrt(sum(abs2, q) * sum(abs2, v)), eps())
            hits = sort([(id, cosine(Float64.(v)), p) for (id, (v, p)) in colls[parts[2]]]; by = h -> -h[2])
            ok([Dict("id" => id, "score" => s, "payload" => p) for (id, s, p) in first(hits, body["limit"])])
        elseif req.method == "POST" && length(parts) == 4 && parts[4] == "delete"
            for id in body["points"]; delete!(colls[parts[2]], string(id)); end
            ok(Dict("status" => "completed"))
        elseif req.method == "POST" && length(parts) == 3
            ok([Dict("id" => id, "vector" => colls[parts[2]][id][1], "payload" => colls[parts[2]][id][2])
                for id in body["ids"] if haskey(colls[parts[2]], id)])
        else
            HTTP.Response(404, "{}")
        end
    end
    return qdrant, colls, qport
end

# The suite, in files included in its testset: each testset in them is a statement of its own, compiled
# when it runs. As one block, the whole suite would be compiled as a single function before its first
# test ran, which takes many minutes.
@testset "Zemi" begin
    include("suite.jl")
    include("shared_tests.jl")
end
