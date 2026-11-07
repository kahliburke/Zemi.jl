# HTTP plumbing the clients and the server share: requests tried again as the service answering
# asks, and the bodies of requests and responses read without emptying them.

"Whether `e`, or the error it wraps, is a request timing out."
timed_out(e) = e isa HTTP.TimeoutError || (hasproperty(e, :error) && getproperty(e, :error) isa Exception && timed_out(e.error))

"The HTTP status `e`, or the error it wraps, answered with; `nothing` for an error without one."
function http_status_error(e)
    e isa HTTP.StatusError && return e
    hasproperty(e, :error) && getproperty(e, :error) isa Exception && return http_status_error(e.error)
    return nothing
end

"A response's body as text, leaving bytes as they are (`String` of a byte vector takes it)."
body_text(b::AbstractVector{UInt8}) = String(copy(b))
body_text(b) = string(b)

"Fail with what a service answered: `what`, the response's status and the start of its body."
http_failure(what::AbstractString, r::HTTP.Response) =
    upstream_failed("$what: HTTP $(r.status): $(first(body_text(r.body), 300))")

# The longest a busy service is waited for between tries, when it does not say.
const MAX_PAUSE = 900.0

"""
    with_retry(f, what; tries = 3, patience = 60, pause = 1.0, before = () -> nothing)

`f()`, tried again when it fails. `before()` runs ahead of each try, for a service that wants its
requests spaced. A rate limit (429) or a service unavailable (503) is waited out, as long as its
Retry-After asks or else `pause` seconds doubling, for up to `patience` seconds in all; another
request refused (any other 4xx) fails at once; other errors are tried `tries` times. A failure the
service answered with is an [`upstream_failed`](@ref).
"""
function with_retry(f, what; tries::Integer = 3, patience::Real = 60, pause::Real = 1.0, before = () -> nothing)
    attempt, busy, waited = 0, 0, 0.0
    while true
        attempt += 1
        before()
        try
            return f()
        catch e
            e isa InterruptException && rethrow()
            se = http_status_error(e)
            status = se === nothing ? 0 : Int(se.status)
            why = se === nothing ? failure_message(e) : "HTTP $status: $(first(body_text(se.response.body), 300))"
            if status in (429, 503)
                busy += 1
                wait = something(tryparse(Float64, HTTP.header(se.response, "Retry-After", "")), min(pause * 2.0^(busy - 1), MAX_PAUSE))
                if waited + wait > patience
                    upstream_failed(status == 429 ? "$what is limiting requests (HTTP 429); try again in a few minutes" :
                                                    "$what is too busy to answer (HTTP 503); try again in a few minutes")
                end
                @info "$what is busy (HTTP $status); asking again in $(round(Int, wait)) s"
                sleep(wait)
                waited += wait
            elseif 400 <= status < 500
                upstream_failed("$what answered $why")
            else
                if attempt >= tries
                    failed = "$what failed" * (attempt > 1 ? " after $attempt attempts" : "") * ": $why"
                    se === nothing ? error(failed) : upstream_failed(failed)
                end
                sleep(0.5 * attempt)
            end
        end
    end
end

"""
    openai_post(url, path, key, body; what) -> Dict

POST `body` (as JSON) to `path` of the OpenAI-compatible API at `url` with API key `key` (none when
empty), tried again as [`with_retry`](@ref) does, and its parsed answer. `what` names it in failures.
"""
function openai_post(url::AbstractString, path::AbstractString, key::AbstractString, body; what::AbstractString)
    headers = ["Content-Type" => "application/json"]
    isempty(key) || push!(headers, "Authorization" => "Bearer $key")
    json = JSON.json(body)
    return with_retry(what) do
        JSON.parse(body_text(HTTP.post(url * path, headers, json; read_idle_timeout = 300).body))
    end
end

# ── Requests ──────────────────────────────────────────────────────────────────────────────────────

"A request's body, as bytes: a copy, so what reads it leaves it for the next."
body_bytes(req::HTTP.Request) = req.body isa HTTP.EmptyBody ? UInt8[] : Vector{UInt8}(req.body)

"A request's JSON body, `{}` when it has none."
json_body(req::HTTP.Request) = (b = String(body_bytes(req)); isempty(strip(b)) ? Dict{String,Any}() : JSON.parse(b))

"A request's form body (`application/x-www-form-urlencoded`), as its fields."
form_body(req::HTTP.Request) = Dict{String,String}(String(k) => String(v) for (k, v) in HTTP.queryparams(String(body_bytes(req))))

# The API's JSON. An empty comprehension's vector has element type `Union{}`, which JSON.jl writes as
# an object; it is written as the empty list it is.
struct APIStyle <: JSON.JSONStyle end
JSON.lower(::APIStyle, ::AbstractVector{Union{}}) = Any[]

"A JSON response of `x`."
json_response(x; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(x; style = APIStyle()))
