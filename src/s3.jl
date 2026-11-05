# A store in an S3-compatible bucket: requests signed with AWS Signature Version 4, uploads past a
# size sent in parts, and the bucket's XML answers read with EzXML.

"""
    S3Store

A dataset in an S3-compatible bucket (Cloudflare R2, AWS S3, Backblaze B2, MinIO), under `prefix`,
reached with an access key. Requests are signed with AWS Signature Version 4.
"""
struct S3Store <: DatasetStore
    endpoint::String
    bucket::String
    prefix::String
    region::String
    access_key_id::String
    secret_access_key::String
end

"RFC 3986 percent-encoding, as AWS signing requires; `/` is kept in a path."
function uri_encode(s::AbstractString; path::Bool = false)
    io = IOBuffer()
    for b in codeunits(s)
        c = Char(b)
        if isletter(c) && isascii(c) || isdigit(c) || c in ('-', '.', '_', '~') || (path && c == '/')
            write(io, c)
        else
            print(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

"""
    sigv4_authorization(; method, path, query = "", headers, payload_hash, access_key_id, secret_access_key,
                        region, service = "s3", amzdate) -> String

The `Authorization` header of an AWS Signature Version 4 request. `headers` are every header to sign,
`host`, `x-amz-date` and `x-amz-content-sha256` among them.
"""
function sigv4_authorization(; method::AbstractString, path::AbstractString, query::AbstractString = "",
                             headers::AbstractDict, payload_hash::AbstractString, access_key_id::AbstractString,
                             secret_access_key::AbstractString, region::AbstractString, service::AbstractString = "s3",
                             amzdate::AbstractString)
    hs = sort!([(lowercase(String(k)), strip(String(v))) for (k, v) in headers]; by = first)
    signed = join(first.(hs), ';')
    canonical = join([method, uri_encode(path; path = true), query, join(("$k:$v\n" for (k, v) in hs)), signed, payload_hash], '\n')
    scope = "$(amzdate[1:8])/$region/$service/aws4_request"
    to_sign = join(["AWS4-HMAC-SHA256", amzdate, scope, bytes2hex(sha256(canonical))], '\n')
    key = reduce((k, part) -> hmac_sha256(k, Vector{UInt8}(part)), [amzdate[1:8], region, service, "aws4_request"];
                 init = Vector{UInt8}("AWS4" * secret_access_key))
    return "AWS4-HMAC-SHA256 Credential=$access_key_id/$scope, SignedHeaders=$signed, " *
           "Signature=$(bytes2hex(hmac_sha256(key, Vector{UInt8}(to_sign))))"
end

# A request for object `key`, or for the bucket itself when `key` is `nothing` (a listing).
function s3_request(s::S3Store, method::AbstractString, key::Union{AbstractString,Nothing}; body::AbstractVector{UInt8} = UInt8[],
                    content_type::AbstractString = "", extra::AbstractDict = Dict{String,String}(), query::AbstractString = "")
    path = "/" * join(filter(!isempty, key === nothing ? [s.bucket] : [s.bucket, s.prefix, key]), '/')
    # The host as the request sends it, with a port other than the scheme's: servers sign that.
    uri = HTTP.URI(s.endpoint)
    host = isempty(uri.port) ? uri.host : "$(uri.host):$(uri.port)"
    amzdate = Dates.format(now(UTC), dateformat"yyyymmdd\THHMMSS\Z")
    payload = bytes2hex(sha256(body))
    headers = Dict("host" => host, "x-amz-date" => amzdate, "x-amz-content-sha256" => payload)
    isempty(content_type) || (headers["content-type"] = content_type)
    merge!(headers, extra)
    headers["authorization"] = sigv4_authorization(; method, path, query, headers, payload_hash = payload,
        s.access_key_id, s.secret_access_key, s.region, amzdate)
    delete!(headers, "host")
    # Every phase has a limit (HTTP.jl's read timeout starts only once a response has begun), so a
    # request the store never answers fails and is tried again. The wait for the response starts once
    # the headers are sent, while the body may still be going up, so it allows for the body: a second
    # for each 100 kB, on top of the minute it gives a store to answer.
    header_wait = 60 + length(body) / 100_000
    return with_retry("S3 $method $key"; tries = 5) do
        r = HTTP.request(method, rstrip(s.endpoint, '/') * uri_encode(path; path = true) * (isempty(query) ? "" : "?" * query),
                         collect(headers), body;
                         status_exception = false, connect_timeout = 30, response_header_timeout = header_wait,
                         read_idle_timeout = 60, write_idle_timeout = 60)
        (r.status >= 500 || r.status == 429) && throw(HTTP.StatusError(r))
        r
    end
end

"An S3 answer's XML document, its root element, or `nothing` for a body that is not XML."
s3_xml(r::HTTP.Response) = try EzXML.root(EzXML.parsexml(body_text(r.body))) catch; nothing end

# S3 answers in its own namespace, and stores like it in none, so elements are found by name alone.
s3_elements(node, name::AbstractString) = findall("*[local-name()='$name']", node)
s3_text(node, name::AbstractString) = (n = findfirst("*[local-name()='$name']", node); n === nothing ? nothing : EzXML.nodecontent(n))

function read_object(s::S3Store, key::AbstractString)
    r = s3_request(s, "GET", key)
    r.status == 404 && return nothing
    r.status == 200 || http_failure("S3 GET $key", r)
    return r.body
end
has_object(s::S3Store, key::AbstractString) = s3_request(s, "HEAD", key).status == 200

"The keys of the objects under `prefix`, a page of a thousand at a time (S3's ListObjectsV2)."
function list_objects(s::S3Store, prefix::AbstractString; modified::Bool = false)
    full = isempty(s.prefix) ? prefix : s.prefix * "/" * prefix
    keys, times, token = String[], DateTime[], nothing
    while true
        params = ["list-type" => "2", "prefix" => full]
        token === nothing || push!(params, "continuation-token" => token)
        r = s3_request(s, "GET", nothing; query = s3_query(params...))
        listing = r.status == 200 ? s3_xml(r) : nothing
        listing === nothing && http_failure("S3 list $prefix", r)
        for c in s3_elements(listing, "Contents")
            push!(keys, chopprefix(something(s3_text(c, "Key"), ""), isempty(s.prefix) ? "" : s.prefix * "/"))
            t = s3_text(c, "LastModified")
            push!(times, t === nothing ? now(UTC) : parse_iso(t))
        end
        token = s3_text(listing, "NextContinuationToken")
        (s3_text(listing, "IsTruncated") == "true" && token !== nothing) || return modified ? keys .=> times : keys
    end
end
function delete_object!(s::S3Store, key::AbstractString)
    r = s3_request(s, "DELETE", key)
    r.status in (200, 204, 404) || http_failure("S3 DELETE $key", r)
    return nothing
end
"""
    write_object!(store, key, bytes; content_type, progress = (sent, total) -> nothing)

Upload `bytes` as `key`. One past `MULTIPART_BYTES` goes up in parts of `PART_BYTES`, a few at a
time, each tried again on its own, with `progress` told the bytes sent as each part is.
"""
function write_object!(s::S3Store, key::AbstractString, bytes::AbstractVector{UInt8}; content_type = "application/octet-stream",
                       progress = (sent, total) -> nothing)
    length(bytes) > MULTIPART_BYTES && return write_parts!(s, key, bytes; content_type, progress)
    # The store checks the upload against its SHA-256 and refuses it if anything was lost on the way.
    r = s3_request(s, "PUT", key; body = bytes, content_type,
                   extra = Dict("x-amz-checksum-sha256" => base64encode(sha256(bytes))))
    r.status == 200 || http_failure("S3 PUT $key", r)
    progress(length(bytes), length(bytes))
    return nothing
end

"Above this, an object is uploaded in parts of `PART_BYTES` (S3's multipart upload)."
const MULTIPART_BYTES = 16 * 1024^2
const PART_BYTES = 8 * 1024^2

# The query of a multipart request, as signing wants it: its parameters sorted, their values encoded.
s3_query(params::Pair...) = join(sort!(["$k=$(uri_encode(String(v)))" for (k, v) in params]), '&')

# A multipart upload: begun, its parts sent four at a time, then put together; abandoned if a part
# cannot be sent, so the store keeps none of it. Parts carry no checksum of their own: an object
# here is named by its content's hash, which an import checks.
function write_parts!(s::S3Store, key::AbstractString, bytes::AbstractVector{UInt8}; content_type, progress)
    r = s3_request(s, "POST", key; query = "uploads=", content_type)
    begun = r.status == 200 ? s3_xml(r) : nothing
    id = begun === nothing ? nothing : s3_text(begun, "UploadId")
    (id === nothing || isempty(id)) && http_failure("S3 POST $key?uploads", r)
    ranges = [i:min(i + PART_BYTES - 1, length(bytes)) for i in 1:PART_BYTES:length(bytes)]
    etags = Vector{String}(undef, length(ranges))
    sent = Threads.Atomic{Int}(0)
    try
        asyncmap(eachindex(ranges); ntasks = 4) do n
            part = bytes[ranges[n]]
            r = s3_request(s, "PUT", key; body = part, query = s3_query("partNumber" => string(n), "uploadId" => id))
            r.status == 200 || http_failure("S3 PUT $key part $n", r)
            etags[n] = HTTP.header(r, "ETag")
            progress(Threads.atomic_add!(sent, length(part)) + length(part), length(bytes))
        end
        xml = "<CompleteMultipartUpload>" *
              join("<Part><PartNumber>$n</PartNumber><ETag>$(etags[n])</ETag></Part>" for n in eachindex(etags)) *
              "</CompleteMultipartUpload>"
        r = s3_request(s, "POST", key; body = Vector{UInt8}(xml), query = s3_query("uploadId" => id), content_type = "application/xml")
        # A store can answer 200 and still fail it, with an Error document.
        (r.status == 200 && (x = s3_xml(r); x === nothing || EzXML.nodename(x) != "Error")) ||
            http_failure("S3 POST $key?uploadId", r)
    catch
        try s3_request(s, "DELETE", key; query = s3_query("uploadId" => id)) catch end
        rethrow()
    end
    return nothing
end
