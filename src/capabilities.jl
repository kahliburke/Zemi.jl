# What this machine can run. Reading a paper needs a PDF parser, an embedding model and Qdrant, and
# writing summaries needs a summarizer; a knowledge base imported from the shared dataset may have
# none of them. The site greys out what cannot run here and says why, and the API refuses it.

"""
Whether the agent tools of the Kaimon running on this machine answer, within a few seconds (a stale
Kaimon socket would block for minutes).
"""
const AGENTS_AVAILABLE = Ref{Function}(function ()
    kaimon_running() || return false
    t = Threads.@spawn try
        any(t -> string(t.name) == "agent_open", KaimonGate.list_tools())
    catch
        false
    end
    # Looked at often, so a quick answer is taken at once: by default timedwait looks every 0.1 s.
    return timedwait(() -> istaskdone(t), 5; pollint = 0.005) == :ok && fetch(t)
end)


same_qdrant(a::AbstractString, b::AbstractString) =
    replace(rstrip(a, '/'), "//localhost:" => "//127.0.0.1:") == replace(rstrip(b, '/'), "//localhost:" => "//127.0.0.1:")

"""
    qdrant_endpoint(c) -> (url, key)

The Qdrant the knowledge base uses, and its API key. With no `qdrant_url`, the Qdrant Kaimon runs
when Kaimon is loaded, with the key it was started with, else `http://localhost:6333`. A configured
`qdrant_url` takes `qdrant_key`, or Kaimon's key when it is Kaimon's Qdrant.
"""
function qdrant_endpoint(c::Config)
    theirs = kaimon_qdrant()
    url = !isempty(c.qdrant_url) ? c.qdrant_url : theirs === nothing ? DEFAULT_QDRANT : theirs[1]
    key = !isempty(c.qdrant_key) ? resolve_key(c.qdrant_key, "Qdrant") :
          theirs !== nothing && same_qdrant(theirs[1], url) ? theirs[2] : ""
    return String(url), String(key)
end

"Whether the knowledge base uses the Qdrant Kaimon runs, which Kaimon can start."
uses_kaimons_qdrant(c::Config) = (t = kaimon_qdrant(); t !== nothing && same_qdrant(t[1], first(qdrant_endpoint(c))))

"""
    ensure_qdrant(c; patience = 0) -> Bool

Whether Qdrant answers, starting it first when it does not and it is the one Kaimon runs. A Qdrant of
its own is asked again for up to `patience` seconds: a service starting on a busy machine (compiling
as it starts, say) may get no answer to the first ask from a Qdrant that is up.
"""
function ensure_qdrant(c::Config; patience::Real = 0)
    Qdrant.ping() && return true
    if !uses_kaimons_qdrant(c)
        until = time() + patience
        while time() < until
            sleep(2)
            Qdrant.ping() && return true
        end
        return false
    end
    # Kaimon keeps its Qdrant running: started here when Kaimon is loaded in this process, else
    # waited for, as its record says where it is now (see `kaimon_qdrant`).
    started = KAIMON[] === nothing ? false : try
        Base.invokelatest(kaimon().ensure_qdrant!) === true
    catch e
        @warn "Kaimon could not start Qdrant" exception = e
        false
    end
    until = time() + patience
    while true
        Qdrant.use!(() -> qdrant_endpoint(c))         # its key and port may be new
        Qdrant.ping() && return true
        (started || time() >= until) && return false
        sleep(2)
    end
end

"The services' last check (see [`unavailable`](@ref)): when, what it found, and whether the service was starting."
const UNAVAILABLE = Ref((; at = 0.0, out = Dict{Symbol,String}(), starting = false))
const CHECKING_SERVICES = Threads.Atomic{Bool}(false)

"Set while the shared service is still starting Qdrant and its Kaimon, which are then said to be starting."
const STARTING = Ref(false)

"""
Whether the services' check `u` is too old to show: after half a minute, or a few seconds while the
service starts, and as soon as it has started if `u` was made before.
"""
services_stale(u) = time() - u.at > (u.starting || STARTING[] ? 5 : 30) || (u.starting && !STARTING[])

"""
    unavailable(kb; fresh = false) -> Dict{Symbol,String}

The services this machine lacks, each with a sentence saying what is missing: `:parser` (MuPDF's
mutool), `:embedder` (Ollama with the layers' models, or a hosted layer's key), `:qdrant`,
and each kind of document's summarizer, by the config's name for it (`:summarizer`,
`:code_summarizer`, see [`DocumentKind`](@ref)). A summarizer is only needed when a layer embeds summaries.

The answer is the last check's, unless `fresh` or there is none yet: a request never waits on
Ollama, Qdrant or Kaimon to answer. A check too old to show (see [`services_stale`](@ref)) is still
given, and one new check is started for the next.
"""
function unavailable(kb::KB; fresh::Bool = false)
    u = UNAVAILABLE[]
    (fresh || u.at == 0) && return check_services!(kb)
    if services_stale(u) && !Threads.atomic_xchg!(CHECKING_SERVICES, true)
        Threads.@spawn try
            check_services!(kb)
        catch e
            @warn "Checking the services failed" exception = e
        finally
            CHECKING_SERVICES[] = false
        end
    end
    return u.out
end

"Check the services [`unavailable`](@ref) names now, keeping the answer for it."
function check_services!(kb::KB)
    starting = STARTING[]
    c = kb.config
    out = Dict{Symbol,String}()
    Sys.which(c.mutool) === nothing && (out[:parser] = "MuPDF's `$(c.mutool)` is not installed")
    layers = ingest_layers(c)
    problems = String[]
    local_models = unique(l.model for l in layers if isempty(l.url))
    if !isempty(local_models)
        have = ollama_models(c)
        lacking = have === nothing ? String[] : [m for m in local_models if !(m in have || "$m:latest" in have)]
        have === nothing ? push!(problems, "Ollama is not running at $(c.ollama_url)") :
            isempty(lacking) || push!(problems, "Ollama does not have $(join(lacking, ", ")) (`ollama pull $(first(lacking))`)")
    end
    append!(problems, something(key_problem(l.key, "layer $(l.name)"), "") for l in layers if !isempty(l.url))
    filter!(!isempty, problems)
    isempty(problems) || (out[:embedder] = join(unique(problems), "; "))
    Qdrant.ping() ||
        (out[:qdrant] = STARTING[] ? "Qdrant is starting" : "Qdrant is not answering at $(Qdrant.url()), or refuses its key")
    if any(l -> !isempty(l.source), layers)
        for k in unique(k -> k.summarizer, DOCUMENT_KINDS)
            service = k.summarizer
            problems = unique(something(summarizer_problem(summarizer_for(c, l, k)), "")
                              for l in layers if !isempty(l.source))
            filter!(!isempty, problems)
            isempty(problems) || (out[service] = join(problems, "; "))
        end
    end
    UNAVAILABLE[] = (; at = time(), out, starting)
    return out
end

"The models Ollama has pulled, or `nothing` when it does not answer."
function ollama_models(c::Config)
    try
        r = HTTP.get("$(c.ollama_url)/api/tags"; connect_timeout = 2, request_timeout = 3, retry = false)
        return Set(String(m["name"]) for m in JSON.parse(String(r.body))["models"])
    catch
        return nothing
    end
end

key_problem(spec, who) = try
    resolve_key(spec, who); nothing
catch e
    failure_message(e)
end

function summarizer_problem(s::Summarizer)
    s.kind == :agent && return AGENTS_AVAILABLE[]() ? nothing :
        STARTING[] ? "the summarizer $(s.name) is a Kaimon agent, and the service's Kaimon is starting" :
        "the summarizer $(s.name) is a Kaimon agent, and no Kaimon server with agents is running"
    problem = key_problem(s.key, "the summarizer $(s.name)")
    problem === nothing || return problem
    # A summarizer without a key is a local one (Ollama's own API, say), which has to be running.
    isempty(s.key) && !service_up("$(rstrip(s.url, '/'))/models") &&
        return "the summarizer $(s.name) is not running at $(s.url)"
    return nothing
end

"""
    action_needs(c, action; kind = PAPER) -> Vector{Symbol}

The services (see [`unavailable`](@ref)) a Manage action needs for a document of `kind`: the PDF
reader for one read from a PDF, and the kind's summarizer.
"""
function action_needs(c::Config, action::AbstractString; kind::DocumentKind = PAPER)
    layers = ingest_layers(c)
    summary = any(l -> !isempty(l.source), layers) ? [kind.summarizer] : Symbol[]
    embed = isempty(layers) ? Symbol[] : [:embedder, :qdrant]
    action in ("ingest", "reindex") && return [kind.pdf ? [:parser] : Symbol[]; embed; summary]
    action == "resummarize" && return [summary; embed]
    action == "classify" && return [:summarizer]
    action in ("embed", "landscape") && return [:embedder, :qdrant]
    return Symbol[]
end

"""
    cannot_run(kb, action, ids; fresh = true) -> Vector{String}
    cannot_run(kb, action, kinds; fresh = true) -> Vector{String}

Why this machine cannot run `action` on these documents (or, with none, on papers), or on documents
of these kinds: empty when it can.
"""
cannot_run(kb::KB, action::AbstractString, ids; fresh::Bool = true) =
    cannot_run(kb, action, isempty(ids) ? [PAPER] : unique(DocumentKind[k for k in document_kind.(ids) if k !== nothing]); fresh)
cannot_run(kb::KB, action::AbstractString, kind::DocumentKind; fresh::Bool = true) = cannot_run(kb, action, [kind]; fresh)
function cannot_run(kb::KB, action::AbstractString, kinds::AbstractVector{DocumentKind}; fresh::Bool = true)
    needs = unique(s for kind in kinds for s in action_needs(kb.config, action; kind))
    isempty(needs) && return String[]
    missing_now = unavailable(kb; fresh)
    return unique(missing_now[s] for s in needs if haskey(missing_now, s))
end
