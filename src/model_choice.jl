# The model that reads papers, as setup and the Configuration page offer it: the choices, grouped by
# where the model runs; what each needs and what this machine has of it; trying one on a short passage
# before choosing it; pulling a local model into Ollama; and noticing when summaries keep failing.

"Where a model runs, as the choices are grouped: its heading and what it means for the person choosing."
const MODEL_PLACES = [
    (id = "service", label = "Through a service",
     detail = "Paid by the paper, with the service's API key. The papers' text is sent to the service."),
    (id = "claude", label = "Claude, on your subscription",
     detail = "An agent run through Kaimon, signed in to Claude Code on this machine. Nothing is paid by the paper; it counts against your plan's usage."),
    (id = "local", label = "On this machine",
     detail = "Free, and nothing leaves the machine. Runs through Ollama; summarizes well only with a large model, which needs the memory and disk for it."),
]

"""
The summarizers setup offers, as `(; id, place, label, detail, speed, papers, code, needs)`: `place`
one of [`MODEL_PLACES`](@ref), `papers` the summarizer that reads papers and `code` the one for
codebases, and `needs` what it needs here (`opencode`, `openai`, `agents`, `ollama` or `custom`).
`ollama` and `custom` are made from what is chosen with them (see [`model_choice`](@ref)).
"""
const MODEL_CHOICES = [
    (id = "deepseek-v4.1-flash", place = "service", label = "DeepSeek V4.1 Flash, through OpenCode Zen",
     detail = "Reads each section's text and summarizes it. A good default.", speed = "fast",
     papers = "deepseek-v4.1-flash", code = "deepseek-v4.1-flash", needs = "opencode"),
    (id = "deepseek-flash", place = "service", label = "DeepSeek V4 Flash, through OpenCode Zen",
     detail = "The least expensive; summaries a little plainer.", speed = "fast",
     papers = "deepseek-flash", code = "deepseek-flash", needs = "opencode"),
    (id = "gpt-5.4-mini", place = "service", label = "GPT-5.4 mini, through OpenAI", detail = "Reads each section's text.",
     speed = "fast", papers = "gpt-5.4-mini", code = "gpt-5.4-mini", needs = "openai"),
    (id = "custom", place = "service", label = "Another OpenAI-compatible API",
     detail = "Any endpoint that speaks OpenAI's chat completions: its address, model and key.", speed = "",
     papers = "", code = "", needs = "custom"),
    (id = "opus-agent-pdf", place = "claude", label = "Claude Opus, reading the PDF",
     detail = "The most thorough: reads the whole paper, figures and equations included, before it summarizes.",
     speed = "minutes a paper", papers = "opus-agent-pdf", code = "opus-agent-code", needs = "agents"),
    (id = "sonnet-agent-pdf", place = "claude", label = "Claude Sonnet, reading the PDF",
     detail = "Reads the whole paper like Opus.", speed = "faster than Opus",
     papers = "sonnet-agent-pdf", code = "sonnet-agent-code", needs = "agents"),
    (id = "opus-agent-text", place = "claude", label = "Claude Opus, reading the text",
     detail = "Reads the paper's extracted text rather than its PDF, without the figures.", speed = "faster than from the PDF",
     papers = "opus-agent-text", code = "opus-agent-code", needs = "agents"),
    (id = "ollama", place = "local", label = "A model in Ollama",
     detail = "Quality depends on the model: one of 14B or more summarizes usefully, 30B or more well.",
     speed = "depends on the machine", papers = "", code = "", needs = "ollama"),
]

"""
Local models worth summarizing with, the largest first: each with its download in GB and the memory
in GB it needs to run beside everything else. The one recommended is the largest that fits.
"""
const LOCAL_MODELS = [
    (model = "qwen3:30b-a3b", gb = 19.0, memory = 32, note = "summarizes well, and fast for its size"),
    (model = "qwen3:14b", gb = 9.3, memory = 16, note = "useful summaries"),
    (model = "qwen3:8b", gb = 5.2, memory = 12, note = "plain summaries; the smallest worth using"),
]

"Room kept free on the disk after a pull, in bytes: the knowledge base and the machine need some too."
const PULL_MARGIN = 5 * 1024^3

"The summarizer named `name` in `c`, or `nothing`."
maybe_summarizer(c::Config, name::AbstractString) = (i = findfirst(s -> s.name == name, c.summarizers); i === nothing ? nothing : c.summarizers[i])

"A rough cost of reading one paper with summarizer `s`, in dollars, from its prices: 40k tokens in, 8k out."
paper_cost(s::Summarizer) = (40_000 * s.price_in + 8_000 * s.price_out) / 1e6

"The models Ollama has, with their sizes in bytes, or `nothing` when it does not answer."
function ollama_tags(c::Config)
    try
        r = HTTP.get("$(c.ollama_url)/api/tags"; connect_timeout = 2, request_timeout = 3, retry = false)
        return [(name = String(m["name"]), size = Int(get(m, "size", 0))) for m in JSON.parse(String(r.body))["models"]]
    catch
        return nothing
    end
end

"The chat models Ollama has here, its embedding models left out."
ollama_chat_models(c::Config) = sort!([m.name for m in something(ollama_tags(c), []) if !occursin("embed", m.name)])

"Whether the config's Ollama runs on this machine, whose disk a pull fills."
ollama_here(c::Config) = occursin(r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/?$", c.ollama_url)

"Where Ollama keeps its models here."
ollama_store() = expanduser(get(ENV, "OLLAMA_MODELS", joinpath("~", ".ollama", "models")))

"The bytes free on the disk at `path`, or on the nearest folder above it that exists."
function disk_free(path::AbstractString)
    p = path
    while !ispath(p) && dirname(p) != p
        p = dirname(p)
    end
    return Int(diskstat(p).available)
end

"The key file an OpenCode key typed on the setup page is saved to, beside the config."
opencode_key_file(path::AbstractString = config_path()) = joinpath(dirname(path), "opencode_key")

"Where the OpenCode key comes from here (see [`resolve_key`](@ref)): `saved`, `login`, `environment` or `\"\"`."
function opencode_source(path::AbstractString = config_path())
    isfile(opencode_key_file(path)) && return "saved"
    isfile(joinpath(xdg_home("XDG_DATA_HOME", ".local/share"), "opencode", "auth.json")) && return "login"
    isempty(get(ENV, "OPENCODE_API_KEY", "")) || return "environment"
    return ""
end

"""
    model_machine(c; path = config_path()) -> Dict

What this machine has for each choice: where the OpenCode key comes from, whether there is an
OpenAI key, whether Kaimon's agents answer, Ollama (installed, running, its chat models with their
sizes, and whether it runs here), the memory and the disk free where Ollama keeps models, and the
[`LOCAL_MODELS`](@ref) with whether each fits in memory and has room on the disk, the largest that
does both recommended.
"""
function model_machine(c::Config; path::AbstractString = config_path())
    tags = ollama_tags(c)
    memory = Sys.total_memory() / 1024^3
    here = ollama_here(c)
    free = here ? disk_free(ollama_store()) : nothing
    have = Set(t.name for t in something(tags, []))
    fits(m) = memory >= m.memory
    room(m) = free === nothing || free - m.gb * 1024^3 >= PULL_MARGIN
    best = findfirst(m -> fits(m) && room(m), LOCAL_MODELS)
    openai = maybe_summarizer(c, "gpt-5.4-mini")
    Dict{String,Any}(
        "opencode" => opencode_source(path),
        "openai" => openai !== nothing && key_problem(openai.key, "OpenAI") === nothing,
        "agents" => AGENTS_AVAILABLE[](),
        "ollama" => Dict{String,Any}("installed" => Sys.which("ollama") !== nothing || tags !== nothing, "running" => tags !== nothing,
                                     "url" => c.ollama_url, "here" => here,
                                     "models" => [Dict("name" => t.name, "gb" => round(t.size / 1024^3; digits = 1))
                                                  for t in something(tags, []) if !occursin("embed", t.name)]),
        "memory_gb" => round(Int, memory),
        "disk_free_gb" => free === nothing ? nothing : round(free / 1024^3; digits = 1),
        "local_models" => [Dict("model" => m.model, "gb" => m.gb, "memory_gb" => m.memory, "note" => m.note, "fits" => fits(m),
                                "room" => room(m),
                                "pulled" => m.model in have, "recommended" => i == best)
                           for (i, m) in enumerate(LOCAL_MODELS)])
end

"The choices of model offered, each with what it needs here, what stops it, and its cost (see `MODEL_CHOICES`)."
function model_choices_json(c::Config)
    known = Set(s.name for s in c.summarizers)
    map(filter(m -> isempty(m.papers) || m.papers in known, MODEL_CHOICES)) do m
        s = isempty(m.papers) ? nothing : maybe_summarizer(c, m.papers)
        problem = m.id == "ollama" ? (isempty(ollama_chat_models(c)) ? "Ollama has no chat model here" : "") :
                  m.needs == "opencode" ? (isempty(opencode_source()) ? "no OpenCode key here" : "") :
                  s === nothing ? "" : something(summarizer_problem(s), "")
        Dict("id" => m.id, "place" => m.place, "label" => m.label, "detail" => m.detail, "speed" => m.speed,
             "needs" => m.needs, "problem" => problem, "agent" => s !== nothing && s.kind == :agent,
             "cost" => s === nothing || s.kind == :agent ? nothing : round(paper_cost(s); digits = 3))
    end
end

"""
    model_json(kb) -> Dict

What the model choice starts from: the places and choices, what this machine has (see
[`model_machine`](@ref)), the choice made now, and whether summaries keep failing.
"""
model_json(kb::KB) = Dict{String,Any}("places" => [Dict(pairs(p)) for p in MODEL_PLACES], "models" => model_choices_json(kb.config),
                                      "machine" => model_machine(kb.config), "model" => current_choice(kb.config),
                                      "failing" => summaries_failing(kb.config))

"""
    choice_summarizer(c, m) -> (summarizer, key)

The summarizer the choice `m` makes, and the API key a key typed with it gives (empty for none), for
trying it before anything is saved.
"""
function choice_summarizer(c::Config, m::AbstractDict)
    id = String(get(m, "id", ""))
    typed = strip(String(get(m, "key", "")))
    if id == "ollama"
        model = strip(String(get(m, "model", "")))
        isempty(model) && error("Choose one of Ollama's models")
        return Summarizer(; name = "ollama-" * replace(model, r"[^A-Za-z0-9.]+" => "-"), url = rstrip(c.ollama_url, '/') * "/v1",
                          model, max_input_chars = 24000, timeout = 3600.0), ""
    elseif id == "custom"
        url, model = (strip(String(get(m, k, ""))) for k in ("url", "model"))
        (isempty(url) || isempty(model)) && error("Another API needs its address and model")
        return Summarizer(; name = replace(lowercase(model), r"[^a-z0-9.]+" => "-"), url, model), typed
    end
    i = findfirst(x -> x.id == id, MODEL_CHOICES)
    i === nothing && error("Unknown model choice $id")
    s = maybe_summarizer(c, MODEL_CHOICES[i].papers)
    s === nothing && error("This knowledge base has no summarizer $(MODEL_CHOICES[i].papers)")
    return s, typed
end

"""
    model_choice(c, m; config_dir) -> (; summarizer, code, summarizers)

What the model choice `m` sets: the summarizer for papers and for codebases, by name, and the
`[[summarizers]]` to add for one made here (a local model, another API). A key typed with it is saved
beside the config, readable only by its owner: an OpenCode key where every OpenCode summarizer finds
it (see [`resolve_key`](@ref)), another with its summarizer.
"""
function model_choice(c::Config, m::AbstractDict; config_dir::AbstractString)
    id = String(get(m, "id", ""))
    save_key_file(name, key) = (f = joinpath(config_dir, "$(name)_key"); write_private(f, strip(key) * "\n"); "file:" * f)
    s, key = choice_summarizer(c, m)
    if id == "ollama"
        t = Dict{String,Any}("name" => s.name, "url" => s.url, "model" => s.model, "key" => "",
                             "max_input_chars" => s.max_input_chars, "timeout" => s.timeout)
        return (; summarizer = s.name, code = s.name, summarizers = [t])
    elseif id == "custom"
        t = Dict{String,Any}("name" => s.name, "url" => s.url, "model" => s.model, "key" => isempty(key) ? "" : save_key_file(s.name, key))
        return (; summarizer = s.name, code = s.name, summarizers = [t])
    end
    choice = MODEL_CHOICES[findfirst(x -> x.id == id, MODEL_CHOICES)]
    isempty(key) && return (; summarizer = choice.papers, code = choice.code, summarizers = Dict{String,Any}[])
    if s.key == "opencode"
        write_private(joinpath(config_dir, "opencode_key"), key * "\n")
        return (; summarizer = choice.papers, code = choice.code, summarizers = Dict{String,Any}[])
    end
    t = Dict{String,Any}("name" => s.name, "url" => s.url, "model" => s.model, "key" => save_key_file(s.name, key),
                         "request" => s.request, "price_in" => s.price_in, "price_out" => s.price_out)
    return (; summarizer = choice.papers, code = choice.code, summarizers = [t])
end

"""
    model_overlay(kb, m; path = config_path()) -> Dict

The settings the model choice `m` writes: the summarizer, the judge and the code summarizer, and the
summarizers it adds to those the settings file has (a list there replaces the config's).
"""
function model_overlay(kb::KB, m::AbstractDict; path::AbstractString = config_path())
    x = model_choice(kb.config, m; config_dir = dirname(path))
    over = Dict{String,Any}("summarizer" => x.summarizer, "judge" => x.summarizer, "code_summarizer" => x.code)
    if !isempty(x.summarizers)
        file = settings_path(path)
        saved = isfile(file) ? get(TOML.parsefile(file), "summarizers", []) : []
        over["summarizers"] = [[s for s in saved if !any(t -> t["name"] == s["name"], x.summarizers)]; x.summarizers]
    end
    return over
end

"""
    choose_model!(kb, m; path = config_path()) -> Dict

The Configuration page's choice of model: write it (see [`model_overlay`](@ref)) and apply it, its
failures forgotten, and say what the choice is now.
"""
function choose_model!(kb::KB, m::AbstractDict; path::AbstractString = config_path())
    save_overlay!(kb, model_overlay(kb, m; path); path)
    lock(() -> empty!(SUMMARY_FAILURES), SUMMARY_LOCK)
    UNAVAILABLE[] = (; at = 0.0, out = Dict{Symbol,String}(), starting = false)    # checked again with it
    return model_json(kb)
end

"""
    current_choice(c) -> Dict

The summarizer `c` has, as a choice of model (see `MODEL_CHOICES`): one of those offered, or a local
or other model, with its `model` and `url`.
"""
function current_choice(c::Config)
    s = maybe_summarizer(c, c.summarizer)
    s === nothing && return Dict("id" => "", "model" => "", "url" => "")
    i = findfirst(m -> m.papers == s.name, MODEL_CHOICES)
    i === nothing || return Dict("id" => MODEL_CHOICES[i].id, "model" => "", "url" => "")
    s.kind == :api && startswith(s.url, rstrip(c.ollama_url, '/')) && return Dict("id" => "ollama", "model" => s.model, "url" => "")
    return Dict("id" => "custom", "model" => s.model, "url" => s.url)
end

# ── Trying a choice ───────────────────────────────────────────────────────────────────────────────

const TRY_PASSAGE = """
Plots were laid out along a slope at five elevations, and soil moisture was measured weekly over one
growing season. Moisture fell with elevation at every visit, but the difference between the lowest
and highest plots narrowed after heavy rain and widened in dry weeks. Plant cover followed moisture
closely at the upper plots and hardly at all at the lower ones, where it stayed high throughout. The
authors read this as water limiting growth only above a threshold elevation, and note that one
season cannot separate this from differences in soil depth along the same slope."""

"How long trying a model may take, in seconds: an agent starts first, and a local model loads."
const TRY_SECONDS = 300

"""
    plain_failure(e, s) -> String

What went wrong asking summarizer `s`, said for the person choosing it: a key refused or expired, a
model the service or Ollama does not have, nothing answering, no answer in time; else the failure.
"""
function plain_failure(e, s::Summarizer)
    msg = failure_message(e)
    low = lowercase(msg)
    where = isempty(s.url) ? "" : " at $(s.url)"
    occursin("expired", low) && occursin(r"\b401\b", msg) && return "The service refused the key: it has expired. Make a new one and enter it here."
    occursin(r"\b40[13]\b", msg) && return "The service refused the key. Check it, or enter another."
    occursin(r"\b404\b", msg) && occursin("model", low) && return "There is no model $(s.model)$where."
    occursin(r"connection refused|could not connect|econnrefused|connecterror|dns"i, msg) && return "Nothing answers$where."
    occursin(r"timed? ?out|timeout"i, msg) && return "No answer within $(TRY_SECONDS ÷ 60) minutes."
    return first(msg, 400)
end

"""
    try_model(kb, m) -> Dict

Have the choice `m` summarize a short passage, as it would a section, before it is chosen: `ok`,
the `text` it wrote and the `seconds` it took, or the `error` in plain words (see [`plain_failure`](@ref)).
"""
function try_model(kb::KB, m::AbstractDict)
    s, key = try choice_summarizer(kb.config, m) catch e; return Dict("ok" => false, "error" => failure_message(e)) end
    s.kind == :agent && !AGENTS_AVAILABLE[]() &&
        return Dict("ok" => false, "error" => "Kaimon's agents are not running here: start Kaimon, signed in to Claude Code.")
    prompt = "Summarize this passage from a paper in two sentences, for a researcher deciding whether to read it.\n\n" * TRY_PASSAGE
    t = time()
    task = Threads.@spawn s.kind == :api ?
        first(complete(s, summary_system(kb.config), prompt; key = isempty(key) ? api_key(s) : key)) :
        ask(Summarizer(; (f => getfield(s, f) for f in fieldnames(Summarizer))..., timeout = Float64(TRY_SECONDS)),
            summary_system(kb.config), prompt)
    timedwait(() -> istaskdone(task), TRY_SECONDS) == :ok || return Dict("ok" => false, "error" => "No answer within $(TRY_SECONDS ÷ 60) minutes.")
    return try
        Dict("ok" => true, "text" => strip(fetch(task)), "seconds" => round(time() - t; digits = 1))
    catch e
        Dict("ok" => false, "error" => plain_failure(e isa TaskFailedException ? e.task.exception : e, s))
    end
end

# ── Pulling a local model ─────────────────────────────────────────────────────────────────────────

"""
    ollama_download_size(model) -> Union{Int,Nothing}

The bytes Ollama's registry says `model` takes to download, or `nothing` when it does not say.
"""
function ollama_download_size(model::AbstractString)
    name, tag = occursin(':', model) ? split(model, ':'; limit = 2) : (model, "latest")
    repo = occursin('/', name) ? name : "library/$name"
    try
        r = HTTP.get("https://registry.ollama.ai/v2/$repo/manifests/$tag",
                     ["Accept" => "application/vnd.docker.distribution.manifest.v2+json"]; connect_timeout = 5, request_timeout = 15, retry = false)
        m = JSON.parse(String(r.body))
        return sum(Int(l["size"]) for l in m["layers"]; init = 0) + Int(get(get(m, "config", Dict()), "size", 0))
    catch
        return nothing
    end
end

"""
    pull_model!(kb, model) -> Job

Pull `model` into the Ollama on this machine, reporting how much has come. It is refused before
anything is downloaded when the disk would keep less than [`PULL_MARGIN`](@ref) free.
"""
function pull_model!(kb::KB, model::AbstractString)
    c = kb.config
    model = strip(model)
    occursin(r"^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$", model) || error("Not a model's name: $model")
    ollama_here(c) || error("Ollama runs at $(c.ollama_url), not on this machine: pull the model there")
    ollama_tags(c) === nothing && error("Ollama is not running at $(c.ollama_url)")
    size = ollama_download_size(model)
    size === nothing && error("Ollama's registry has no model $model")
    free = disk_free(ollama_store())
    gb(x) = round(x / 1024^3; digits = 1)
    free - size < PULL_MARGIN &&
        error("$model is $(gb(size)) GB, and the disk has $(gb(free)) GB free: pulling it would leave less than $(gb(PULL_MARGIN)) GB")
    return start_job("pull $model") do job
        report!(job, "pulling $model ($(gb(size)) GB)")
        done = Dict{String,Int}()
        HTTP.open("POST", "$(c.ollama_url)/api/pull", ["Content-Type" => "application/json"]; read_idle_timeout = 600) do io
            write(io, JSON.json(Dict("model" => model, "stream" => true)))
            HTTP.closewrite(io)
            HTTP.startread(io)
            # One JSON object a line, as Ollama reports each layer's progress.
            buf = IOBuffer()
            while !eof(io) && !cancelled(job)
                write(buf, readavailable(io))
                text = String(take!(buf))
                lines = split(text, '\n')
                write(buf, pop!(lines))                     # the line still coming
                for line in lines
                    isempty(strip(line)) && continue
                    x = JSON.parse(line)
                    haskey(x, "error") && error("Ollama: $(x["error"])")
                    haskey(x, "digest") && haskey(x, "completed") && (done[x["digest"]] = Int(x["completed"]))
                    report!(job, isempty(done) ? String(get(x, "status", "")) : "pulling $model: $(gb(sum(values(done)))) of $(gb(size)) GB")
                end
            end
        end
        cancelled(job) && return "Stopped pulling $model"
        UNAVAILABLE[] = (; at = 0.0, out = Dict{Symbol,String}(), starting = false)
        return "Pulled $model"
    end
end

# ── Summaries that keep failing ───────────────────────────────────────────────────────────────────

"Each summarizer's failures since it last summarized: how many in a row, the last one, and when."
const SUMMARY_FAILURES = Dict{String,NamedTuple{(:count, :error, :at),Tuple{Int,String,DateTime}}}()
const SUMMARY_LOCK = ReentrantLock()

"How many failures in a row say a summarizer keeps failing; a refused key says it at once."
const FAILING_AFTER = 3

"Note that summarizer `name` failed with `e`, or with `nothing`, that it summarized."
function note_summary!(name::AbstractString, e = nothing)
    lock(SUMMARY_LOCK) do
        if e === nothing
            delete!(SUMMARY_FAILURES, name)
        else
            n = haskey(SUMMARY_FAILURES, name) ? SUMMARY_FAILURES[name].count : 0
            SUMMARY_FAILURES[name] = (; count = n + 1, error = first(failure_message(e), 600), at = now(UTC))
        end
    end
    return
end

"""
    summaries_failing(c) -> Union{Dict,Nothing}

The summarizer the config chose for papers or codebases that keeps failing: its name, how many times
in a row, why in plain words, and the last failure as it came; or `nothing`.
"""
function summaries_failing(c::Config)
    lock(SUMMARY_LOCK) do
        for name in unique([c.summarizer, c.code_summarizer])
            f = get(SUMMARY_FAILURES, name, nothing)
            f === nothing && continue
            s = maybe_summarizer(c, name)
            refused = occursin(r"\b40[13]\b", f.error)
            (refused || f.count >= FAILING_AFTER) || continue
            return Dict("summarizer" => name, "count" => f.count, "at" => string(f.at),
                        "why" => s === nothing ? f.error : plain_failure(ErrorException(f.error), s), "error" => f.error)
        end
        return nothing
    end
end
