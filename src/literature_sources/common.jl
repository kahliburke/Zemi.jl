"One entry of a fetched reference list."
const FetchedReference = @NamedTuple{arxiv::Union{String,Nothing}, doi::Union{String,Nothing}, title::String,
                                     authors::Vector{String}, year::Union{Int,Nothing}}

# A service that fails is left alone for a while, so that recording papers, or a long fetch, does not
# wait on it again for each request; the papers it was not asked about are asked the next time.
const RESTING = Dict{String,DateTime}()
const RESTING_LOCK = ReentrantLock()
"How long a service that failed is left alone."
const REST = Minute(10)
resting(service::AbstractString) = lock(() -> get(RESTING, service, DateTime(0)) > now(UTC), RESTING_LOCK)
rest!(service::AbstractString) = lock(() -> (RESTING[service] = now(UTC) + REST), RESTING_LOCK)

# Text from a service's answer, `nothing` for anything else.
answer_text(x) = x isa AbstractString && !isempty(x) ? String(x) : nothing
answer_year(x) = x isa Integer ? Int(x) : nothing

# What a service answered for each work asked about: its list (empty for none), or `nothing` for a work
# it does not know. A work it was not asked about, or did not answer for, is not there at all.
const Answers = Dict{String,Union{Vector{FetchedReference},Nothing}}

# Public links are kept verbatim except for the scheme, host, default port and fragment.
function watch_url(value)
    value isa AbstractString || return nothing
    s = strip(value)
    occursin(r"[\s\\\x00-\x1f]", s) && return nothing
    u = try HTTP.URI(s) catch; return nothing end
    scheme = lowercase(u.scheme)
    scheme in ("http", "https") && !isempty(u.host) && isempty(u.userinfo) || return nothing
    port = u.port == (scheme == "https" ? "443" : "80") ? nothing : u.port
    return try string(HTTP.URI(u; scheme, host = lowercase(u.host), port, fragment = nothing)) catch; nothing end
end

watch_resource_id(url) = resource_id("watch", bytes2hex(sha256(url))[1:32])

# Only strong identifiers match across sources. Opaque feed GUIDs are scoped to that feed.
function linked_candidate(; url, key, title, authors, abstract, published, category, origin, doi, arxiv)
    aliases = unique(filter(!isempty, [url, key]))
    id = arxiv === nothing ? something(doi, watch_resource_id(url)) : arxiv
    return (; doc_id = id, title, authors, abstract, published, primary_category = category,
            origins = [origin], doi, work_id = nothing, aliases, url)
end
