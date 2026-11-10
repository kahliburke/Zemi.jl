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
`opencode`, `ollama` and `custom` are made from the model chosen with them (see [`model_choice`](@ref)).
"""
const MODEL_CHOICES = [
    (id = "opencode", place = "service", label = "A model through OpenCode Zen",
     detail = "Zen's models (DeepSeek, GLM, Kimi, Qwen, Claude, GPT and others), paid from its credit. DeepSeek V4.1 Flash summarizes well for little.",
     speed = "fast", papers = "", code = "", needs = "opencode"),
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

"""
    zen_models(c) -> Union{Vector,Nothing}

The chat models OpenCode Zen offers to the OpenCode key here, as `(; id, name, description, url,
price_in, price_out)` (dollars per million tokens), the least costly first; `nothing` without a key
or an answer. Asked again after an hour.
"""
function zen_models(c::Config)
    cached = ZEN_MODELS[]
    cached !== nothing && time() - cached.at < 3600 && return cached.models
    key = try resolve_key("opencode", "OpenCode Zen") catch; return nothing end
    models = try
        r = HTTP.get("$ZEN_URL/models", ["Authorization" => "Bearer $key"]; connect_timeout = 5, request_timeout = 15, retry = false)
        price(m, way) = Float64(something(get(get(get(get(m, "cost", Dict()), "text", Dict()), way, Dict()), "price", nothing), 0.0))
        chat(m) = get(get(m, "api", Dict()), "chat-completions", nothing)
        sort!([(; id = String(m["id"]), name = String(something(get(m, "name", nothing), m["id"])),
                description = String(something(get(m, "description", nothing), "")),
                url = String(something(get(chat(m), "base_url", nothing), ZEN_URL)), price_in = price(m, "input"), price_out = price(m, "output"))
               for m in get(JSON.parse(String(r.body)), "data", []) if get(m, "type", "chat") == "chat" && chat(m) !== nothing];
              by = m -> (40_000 * m.price_in + 8_000 * m.price_out, m.id))
    catch e
        @debug "OpenCode Zen's models did not come" exception = e
        return nothing
    end
    ZEN_MODELS[] = (; at = time(), models)
    return models
end
const ZEN_MODELS = Ref{Any}(nothing)

"The summarizer the config has for Zen's model `model`, if any: the one named for it keeps its summaries."
zen_summarizer(c::Config, model::AbstractString) =
    (i = findfirst(s -> s.kind == :api && s.key == "opencode" && s.model == model, c.summarizers); i === nothing ? nothing : c.summarizers[i])

"The Zen model chosen when none is: one that summarizes well for little."
const ZEN_DEFAULT = "deepseek-v4.1-flash"

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
[`model_machine`](@ref)), OpenCode Zen's models with their cost per paper, the choice made now,
whether summaries keep failing, and the sections a choice can be tried on (see [`try_sections`](@ref)).
"""
model_json(kb::KB) = Dict{String,Any}(
    "places" => [Dict(pairs(p)) for p in MODEL_PLACES], "models" => model_choices_json(kb.config),
    "opencode_models" => [Dict("id" => m.id, "name" => m.name, "description" => m.description,
                               "cost" => round((40_000 * m.price_in + 8_000 * m.price_out) / 1e6; digits = 3))
                          for m in something(zen_models(kb.config), [])],
    "opencode_default" => ZEN_DEFAULT,
    "machine" => model_machine(kb.config), "model" => current_choice(kb.config), "failing" => summaries_failing(kb.config),
    "sections" => try_sections(kb))

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
    elseif id == "opencode"
        model = strip(String(get(m, "model", "")))
        isempty(model) && (model = ZEN_DEFAULT)
        have = zen_summarizer(c, model)
        have === nothing || return have, typed
        z = something(zen_models(c), [])
        i = findfirst(x -> x.id == model, z)
        i === nothing && !isempty(z) && error("OpenCode Zen has no model $model")
        url, price_in, price_out = i === nothing ? (ZEN_URL, 0.0, 0.0) : (z[i].url, z[i].price_in, z[i].price_out)
        return Summarizer(; name = "zen-" * replace(model, r"[^A-Za-z0-9.]+" => "-"), url, model, key = "opencode", price_in, price_out), typed
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
    if id == "opencode"
        isempty(key) || write_private(joinpath(config_dir, "opencode_key"), key * "\n")
        added = maybe_summarizer(c, s.name) === nothing ?
            [Dict{String,Any}("name" => s.name, "url" => s.url, "model" => s.model, "key" => "opencode",
                              "price_in" => s.price_in, "price_out" => s.price_out)] : Dict{String,Any}[]
        return (; summarizer = s.name, code = s.name, summarizers = added)
    end
    choice = MODEL_CHOICES[findfirst(x -> x.id == id, MODEL_CHOICES)]
    isempty(key) && return (; summarizer = choice.papers, code = choice.code, summarizers = Dict{String,Any}[])
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
    s.kind == :api && s.key == "opencode" && return Dict("id" => "opencode", "model" => s.model, "url" => "")
    s.kind == :api && startswith(s.url, rstrip(c.ollama_url, '/')) && return Dict("id" => "ollama", "model" => s.model, "url" => "")
    return Dict("id" => "custom", "model" => s.model, "url" => s.url)
end

# ── Trying a choice ───────────────────────────────────────────────────────────────────────────────

"""
A section to try a model on before the knowledge base has papers of its own: a results section, of a
paper made up for it, as the reading would extract it from a PDF.
"""
const SAMPLE_SECTION = (title = "Soil moisture thresholds for plant cover along a hillslope gradient",
                        path = "4 Results › 4.2 Moisture and cover along the slope", text = """
Across the 22 weekly visits, volumetric soil moisture at 10 cm declined with elevation at all five plot
levels (Table 2). Mean moisture was 31.4% at the lowest plots (E1) and 17.9% at the highest (E5), a
difference that was significant in a mixed model with visit as a random effect (F(4, 85) = 46.2,
p < 0.001). The decline was not linear: moisture fell by less than 2 percentage points between E1 and
E3, and by 9.6 points between E3 and E5.

The difference between E1 and E5 changed with rainfall. In the 6 visits that followed more than 20 mm
of rain in the preceding three days, it averaged 7.2 points; in the 9 visits after dry spells of a week
or more, it averaged 18.3 points. Figure 4 shows the moisture at each level against the rain of the
preceding days. Upper plots dried within four to five days of rain, while E1 and E2 stayed above 28%
for the whole season.

Plant cover followed a different pattern. At E4 and E5, cover tracked moisture closely: the correlation
between a plot's moisture and its cover a week later was r = 0.71 at E5 and r = 0.58 at E4. At E1 to E3
the correlation was weak (r between 0.09 and 0.17), and cover stayed between 78% and 91% throughout the
season. Fitting a segmented regression of cover on moisture across all plots placed a breakpoint at
24.6% moisture (95% CI 22.8 to 26.1%); below it cover rose by 3.1 points per point of moisture, above
it by 0.2.

C = β0 + β1 θ + β2 (θ − θ*) I(θ > θ*) + ε (3)

where C is cover, θ is moisture and θ* the breakpoint. Species composition shifted along the same
gradient: the share of cover from drought-tolerant grasses rose from 12% at E1 to 47% at E5, while
broad-leaved herbs fell from 38% to 9%.

Soil depth also declined with elevation, from 64 cm on average at E1 to 23 cm at E5 (Table 3), and
was correlated with mean moisture across plots (r = 0.82). Adding soil depth to the segmented model
reduced the breakpoint's estimated effect by about a third but did not remove it (likelihood ratio
test, p = 0.03). With one season of data, the two cannot be separated further: the lower plots are
both wetter and deeper, and the threshold may reflect either, or water held in deeper soil.
""")

"""
    try_sections(kb) -> Vector{Dict}

The sections a model can be tried on, as their `key`, the paper's `title`, the section's `path` and
its length in `chars`: one from each of the most recently added papers here, the one closest to a
typical section's length, then [`SAMPLE_SECTION`](@ref).
"""
function try_sections(kb::KB; papers::Integer = 8)
    out = Dict{String,Any}[]
    for r in query(kb, """SELECT p.doc_id, p.title FROM papers p JOIN parses x ON x.paper_id = p.id
                          WHERE p.kind = 'paper' ORDER BY p.added_at DESC LIMIT ?""", (papers,))
        secs = filter(t -> !occursin(r"abstract|introduction|acknowledg|conclusion"i, t.path), section_texts(kb, r.doc_id))
        isempty(secs) && continue
        t = argmin(t -> abs(length(t.text) - 4000), secs)
        push!(out, Dict{String,Any}("key" => "$(r.doc_id)#$(t.ord)", "title" => coalesce(r.title, r.doc_id), "path" => t.path,
                                    "chars" => length(t.text)))
    end
    push!(out, Dict{String,Any}("key" => "sample", "title" => SAMPLE_SECTION.title, "path" => SAMPLE_SECTION.path,
                                "chars" => length(SAMPLE_SECTION.text)))
    return out
end

"""
    try_section(kb, key) -> (; title, path, text)

The section `key` names (see [`try_sections`](@ref)): a paper's here, or the sample.
"""
function try_section(kb::KB, key::AbstractString)
    key == "sample" && return SAMPLE_SECTION
    m = match(r"^(.+)#(\d+)$", key)
    m === nothing && error("No section $key")
    id, ord = m[1], parse(Int, m[2])
    ismissing(paper_id(kb, id)) && not_found("No paper $id.")
    i = findfirst(t -> t.ord == ord, section_texts(kb, id))
    i === nothing && not_found("$id has no section $ord to summarize")
    t = section_texts(kb, id)[i]
    return (; title = coalesce(paper_row(kb, id).title, id), t.path, t.text)
end

"The most of a pasted passage sent when trying a model, in characters."
const TRY_CHARS = 24_000

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

Have the choice `m` summarize a section as it would one of a paper's (see [`section_prompt`](@ref)),
before it is chosen: the section `m["section"]` names (see [`try_sections`](@ref)), or the `passage`
pasted. Returns `ok`, the `text` it wrote, the `seconds` it took and the words in and out, or the
`error` in plain words (see [`plain_failure`](@ref)).
"""
function try_model(kb::KB, m::AbstractDict)
    s, key = try choice_summarizer(kb.config, m) catch e; return Dict("ok" => false, "error" => failure_message(e)) end
    s.kind == :agent && !AGENTS_AVAILABLE[]() &&
        return Dict("ok" => false, "error" => "Kaimon's agents are not running here: start Kaimon, signed in to Claude Code.")
    pasted = strip(String(get(m, "passage", "")))
    sec = isempty(pasted) ? try_section(kb, String(get(m, "section", "sample"))) : (; title = "A pasted passage", path = "", text = first(pasted, TRY_CHARS))
    prompt = section_prompt(sec.title, isempty(sec.path) ? "(not given)" : sec.path, first(sec.text, s.max_input_chars))
    t = time()
    task = Threads.@spawn s.kind == :api ?
        first(complete(s, summary_system(kb.config), prompt; key = isempty(key) ? api_key(s) : key)) :
        ask(Summarizer(; (f => getfield(s, f) for f in fieldnames(Summarizer))..., timeout = Float64(TRY_SECONDS)),
            summary_system(kb.config), prompt)
    timedwait(() -> istaskdone(task), TRY_SECONDS) == :ok || return Dict("ok" => false, "error" => "No answer within $(TRY_SECONDS ÷ 60) minutes.")
    words(x) = count(r"\S+", x)
    return try
        text = strip(fetch(task))
        Dict("ok" => true, "text" => text, "seconds" => round(time() - t; digits = 1), "words" => words(text), "words_in" => words(sec.text))
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
