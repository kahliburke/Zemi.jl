# A stand-in S3 on a free port (or `port`), objects kept in memory or, with `dir`, as files under it
# (`<dir>/<bucket>/<key>`, kept from one run to the next): what the dataset stores use of S3 (putting,
# getting, heading and deleting objects, listing them, multipart uploads, and writing an object only
# if none is there), with every request's AWS Signature Version 4 checked against `secrets`, a Dict of
# access key id => secret. A request signed wrongly, or by an unknown key, is refused with 403, as S3
# refuses it. `allow(key_id, method, object_key)` says whether a key may do that, for keys limited to
# part of a bucket, and `page` how many keys a listing returns at a time. Returns `(; server, objects, uploads, stamps, port, endpoint, requests)`; `requests` counts them by method.

"Objects kept as files under a folder, by \"bucket/key\", as far as the stand-in S3 asks of a Dict."
struct FolderObjects <: AbstractDict{String,Vector{UInt8}}
    dir::String
end
Base.haskey(o::FolderObjects, k::String) = isfile(joinpath(o.dir, k))
Base.getindex(o::FolderObjects, k::String) = read(joinpath(o.dir, k))
function Base.setindex!(o::FolderObjects, v::Vector{UInt8}, k::String)
    f = joinpath(o.dir, k)
    mkpath(dirname(f)); write(f * ".part", v); mv(f * ".part", f; force = true)
end
Base.delete!(o::FolderObjects, k::String) = (rm(joinpath(o.dir, k); force = true); o)
Base.keys(o::FolderObjects) = [join(splitpath(relpath(joinpath(d, f), o.dir)), '/') for (d, _, fs) in walkdir(o.dir) for f in fs
                                if !endswith(f, ".part")]
Base.length(o::FolderObjects) = length(keys(o))
Base.iterate(o::FolderObjects, s...) = iterate([k => o[k] for k in keys(o)], s...)

function standin_s3(secrets::AbstractDict; region = "auto", allow = (id, method, key) -> true, page::Integer = 1000,
                    port::Integer = 19000 + rand(0:999), dir = nothing)
    HTTP, SHA, Dates = K.HTTP, K.SHA, K.Dates
    objects = dir === nothing ? Dict{String,Vector{UInt8}}() : FolderObjects(mkpath(dir))   # "bucket/key" => bytes
    uploads = Dict{String,Dict{Int,Vector{UInt8}}}()   # upload id => part number => bytes
    stamps = Dict{String,Dates.DateTime}()             # "bucket/key" => when it was written
    requests = Dict{String,Int}()
    lock = ReentrantLock()
    xml(status, body) = HTTP.Response(status, ["Content-Type" => "application/xml"], body)
    s3_error(status, code) = xml(status, "<Error><Code>$code</Code></Error>")

    function authorized(req, path, query)
        auth = HTTP.header(req, "Authorization", "")
        m = match(r"^AWS4-HMAC-SHA256 Credential=([^/]+)/[^,]+, SignedHeaders=([^,]+), Signature=([0-9a-f]+)$", auth)
        m === nothing && return nothing
        id, signed, signature = m[1], split(m[2], ';'), m[3]
        haskey(secrets, id) || return nothing
        body = Vector{UInt8}(req.body)
        payload = HTTP.header(req, "x-amz-content-sha256", "")
        bytes2hex(SHA.sha256(body)) == payload || return nothing
        headers = Dict(h => (h == "host" ? HTTP.header(req, "Host", "") : HTTP.header(req, h, "")) for h in signed)
        want = K.sigv4_authorization(; method = req.method, path, query, headers, payload_hash = payload,
                                     access_key_id = id, secret_access_key = secrets[id], region,
                                     amzdate = HTTP.header(req, "x-amz-date", ""))
        return endswith(want, "Signature=" * signature) ? id : nothing
    end

    server = HTTP.serve!("127.0.0.1", port) do req
        uri = HTTP.URI(req.target)
        path = HTTP.unescapeuri(uri.path)
        query = uri.query
        params = Dict{String,String}(k => v for (k, v) in HTTP.queryparams(query))
        Base.@lock lock (requests[req.method] = get(requests, req.method, 0) + 1)
        id = authorized(req, path, query)
        id === nothing && return s3_error(403, "SignatureDoesNotMatch")
        parts = split(strip(path, '/'), '/'; limit = 2)
        bucket, key = parts[1], length(parts) == 2 ? parts[2] : nothing
        Base.@lock lock begin
            if key === nothing && req.method == "GET" && get(params, "list-type", "") == "2"
                prefix = bucket * "/" * get(params, "prefix", "")
                found = sort!([k[ncodeunits(bucket)+2:end] for k in keys(objects) if startswith(k, prefix)])
                start = parse(Int, get(params, "continuation-token", "0"))
                listed = found[start+1:min(start + page, end)]
                more = start + page < length(found)
                modified(k) = Dates.format(get(stamps, bucket * "/" * k, Dates.now(Dates.UTC)), "yyyy-mm-ddTHH:MM:SS") * ".000Z"
                return xml(200, "<ListBucketResult>" * join("<Contents><Key>$(K.html_escape(k))</Key><LastModified>$(modified(k))</LastModified></Contents>"
                                                            for k in listed) *
                                "<IsTruncated>$more</IsTruncated>" *
                                (more ? "<NextContinuationToken>$(start + page)</NextContinuationToken>" : "") * "</ListBucketResult>")
            end
            key === nothing && return s3_error(400, "InvalidRequest")
            allow(id, req.method, key) || return s3_error(403, "AccessDenied")
            full = bucket * "/" * key
            if req.method == "POST" && haskey(params, "uploads")
                upload = string(rand(UInt64); base = 16)
                uploads[upload] = Dict{Int,Vector{UInt8}}()
                return xml(200, "<InitiateMultipartUploadResult><UploadId>$upload</UploadId></InitiateMultipartUploadResult>")
            elseif req.method == "PUT" && haskey(params, "uploadId")
                haskey(uploads, params["uploadId"]) || return s3_error(404, "NoSuchUpload")
                body = Vector{UInt8}(req.body)
                uploads[params["uploadId"]][parse(Int, params["partNumber"])] = body
                return HTTP.Response(200, ["ETag" => "\"$(bytes2hex(SHA.sha256(body)))\""], "")
            elseif req.method == "POST" && haskey(params, "uploadId")
                got = pop!(uploads, params["uploadId"], nothing)
                got === nothing && return s3_error(404, "NoSuchUpload")
                named = [parse(Int, m[1]) for m in eachmatch(r"<PartNumber>(\d+)</PartNumber>", String(Vector{UInt8}(req.body)))]
                named == sort!(collect(keys(got))) || return s3_error(400, "InvalidPart")
                objects[full] = reduce(vcat, (got[n] for n in sort!(collect(keys(got)))); init = UInt8[])
                stamps[full] = Dates.now(Dates.UTC)
                return xml(200, "<CompleteMultipartUploadResult></CompleteMultipartUploadResult>")
            elseif req.method == "DELETE" && haskey(params, "uploadId")
                delete!(uploads, params["uploadId"])
                return HTTP.Response(204)
            elseif req.method == "PUT"
                body = Vector{UInt8}(req.body)
                sum = HTTP.header(req, "x-amz-checksum-sha256", "")
                isempty(sum) || sum == K.base64encode(SHA.sha256(body)) || return s3_error(400, "BadDigest")
                HTTP.header(req, "If-None-Match", "") == "*" && haskey(objects, full) && return s3_error(412, "PreconditionFailed")
                objects[full] = body
                stamps[full] = Dates.now(Dates.UTC)
                return HTTP.Response(200, ["ETag" => "\"$(bytes2hex(SHA.sha256(body)))\""], "")
            elseif req.method == "GET"
                haskey(objects, full) || return s3_error(404, "NoSuchKey")
                return HTTP.Response(200, objects[full])
            elseif req.method == "HEAD"
                return HTTP.Response(haskey(objects, full) ? 200 : 404)
            elseif req.method == "DELETE"
                delete!(objects, full)
                return HTTP.Response(204)
            end
        end
        return s3_error(405, "MethodNotAllowed")
    end
    return (; server, objects, uploads, stamps, port, endpoint = "http://127.0.0.1:$port", requests)
end
