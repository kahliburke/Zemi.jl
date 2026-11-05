# Setting up a new knowledge base, on its first run, from the site: who it is for (the group, its
# field and focus areas), what it watches on arXiv, which model summarizes, and whether it reads alone,
# joins a group's dataset with a key someone issued, or starts one. Written to the settings file, as
# the Configuration page writes (see admin.jl).

"Whether this knowledge base is still to be set up: no config file, no settings, and never set up from the site."
setup_needed(kb::KB; path::AbstractString = config_path()) =
    !isfile(path) && !isfile(settings_path(path)) && ismissing(scalar(kb, "SELECT value FROM kv WHERE key = 'setup_done'"))

focus_json(g::Group) = [Dict("name" => a.name, "description" => a.description) for a in g.focus_areas]
panels_json(g::Group) = [Dict("title" => p.title, "text" => p.text, "link" => p.link) for p in g.panels]
questions_json(g::Group) = [Dict("id" => q.id, "text" => q.text, "options" => q.options, "many" => q.many) for q in g.questions]

# ── The model that reads ──────────────────────────────────────────────────────────────────────────

"""
The summarizers setup offers, as `(; id, label, detail, papers, code)`: `papers` the summarizer that
reads papers, `code` the one for codebases. `ollama` and `custom` are made from what is chosen with
them (see [`model_choice`](@ref)).
"""
const MODEL_CHOICES = [
    (id = "deepseek-v4.1-flash", label = "DeepSeek V4.1 Flash, through OpenCode Zen",
     detail = "Fast and inexpensive: reads each section's text and summarizes it. A good default.",
     papers = "deepseek-v4.1-flash", code = "deepseek-v4.1-flash"),
    (id = "deepseek-flash", label = "DeepSeek V4 Flash, through OpenCode Zen",
     detail = "The least expensive; summaries a little plainer.", papers = "deepseek-flash", code = "deepseek-flash"),
    (id = "gpt-5.4-mini", label = "GPT-5.4 mini, through OpenAI", detail = "Reads each section's text. Needs an OpenAI API key.",
     papers = "gpt-5.4-mini", code = "gpt-5.4-mini"),
    (id = "opus-agent-pdf", label = "Claude Opus, as an agent reading the PDF",
     detail = "The most thorough: reads the whole paper, figures and equations included, before it summarizes. " *
              "Slow; runs on your Claude subscription through Kaimon.", papers = "opus-agent-pdf", code = "opus-agent-code"),
    (id = "sonnet-agent-pdf", label = "Claude Sonnet, as an agent reading the PDF",
     detail = "Reads the whole paper like Opus, faster. Runs on your Claude subscription through Kaimon.",
     papers = "sonnet-agent-pdf", code = "sonnet-agent-code"),
    (id = "opus-agent-text", label = "Claude Opus, as an agent reading the text",
     detail = "Reads the paper's extracted text rather than its PDF: faster, without the figures.",
     papers = "opus-agent-text", code = "opus-agent-code"),
    (id = "ollama", label = "A local model, through Ollama", detail = "Free and private: nothing leaves this machine. " *
     "Quality depends on the model; a large one (30B or more) summarizes well.", papers = "", code = ""),
    (id = "custom", label = "Another OpenAI-compatible API", detail = "Any endpoint that speaks OpenAI's chat completions: its address, model and key.",
     papers = "", code = ""),
]

"A rough cost of reading one paper with summarizer `s`, in dollars, from its prices: 40k tokens in, 8k out."
paper_cost(s::Summarizer) = (40_000 * s.price_in + 8_000 * s.price_out) / 1e6

"The chat models Ollama has here, its embedding models left out."
ollama_chat_models(c::Config) = sort!([m for m in something(ollama_models(c), String[]) if !occursin("embed", m)])

"The choices of model setup offers, each with what it needs here and its cost (see `MODEL_CHOICES`)."
function model_choices_json(c::Config)
    known = Set(s.name for s in c.summarizers)
    map(filter(m -> isempty(m.papers) || m.papers in known, MODEL_CHOICES)) do m
        s = isempty(m.papers) ? nothing : summarizer(c, m.papers)
        problem = m.id == "ollama" ? (isempty(ollama_chat_models(c)) ? "Ollama has no chat model here (`ollama pull qwen3:32b`)" : "") :
                  s === nothing ? "" : something(summarizer_problem(s), "")
        Dict("id" => m.id, "label" => m.label, "detail" => m.detail, "problem" => problem,
             "agent" => s !== nothing && s.kind == :agent,
             "cost" => s === nothing || s.kind == :agent ? nothing : round(paper_cost(s); digits = 3),
             "needs_key" => m.id == "gpt-5.4-mini" && occursin("no key file", problem))
    end
end

"""
    model_choice(c, m; config_dir) -> (; summarizer, code, summarizers)

What the setup page's model choice `m` sets: the summarizer for papers and for codebases, by name,
and the `[[summarizers]]` to add for one made here (a local model, another API). A key given with it
is saved beside the config, readable only by its owner.
"""
function model_choice(c::Config, m::AbstractDict; config_dir::AbstractString)
    id = String(get(m, "id", ""))
    i = findfirst(x -> x.id == id, MODEL_CHOICES)
    i === nothing && error("Unknown model choice $id")
    choice = MODEL_CHOICES[i]
    save_key_file(name, key) = (f = joinpath(config_dir, "$(name)_key"); write_private(f, strip(key) * "\n"); "file:" * f)
    if id == "ollama"
        model = strip(String(get(m, "model", "")))
        isempty(model) && error("Choose one of Ollama's models")
        name = "ollama-" * replace(model, r"[^A-Za-z0-9.]+" => "-")
        t = Dict{String,Any}("name" => name, "url" => rstrip(c.ollama_url, '/') * "/v1", "model" => model, "key" => "",
                             "max_input_chars" => 24000, "timeout" => 3600.0)
        return (; summarizer = name, code = name, summarizers = [t])
    elseif id == "custom"
        url, model, key = (strip(String(get(m, k, ""))) for k in ("url", "model", "key"))
        (isempty(url) || isempty(model)) && error("Another API needs its address and model")
        name = replace(lowercase(model), r"[^a-z0-9.]+" => "-")
        t = Dict{String,Any}("name" => name, "url" => url, "model" => model, "key" => isempty(key) ? "" : save_key_file(name, key))
        return (; summarizer = name, code = name, summarizers = [t])
    end
    key = strip(String(get(m, "key", "")))
    if !isempty(key)
        s = summarizer(c, choice.papers)
        t = Dict{String,Any}("name" => s.name, "url" => s.url, "model" => s.model, "key" => save_key_file(s.name, key),
                             "request" => s.request, "price_in" => s.price_in, "price_out" => s.price_out)
        return (; summarizer = choice.papers, code = choice.code, summarizers = [t])
    end
    return (; summarizer = choice.papers, code = choice.code, summarizers = Dict{String,Any}[])
end

"""
    current_choice(c) -> Dict

The summarizer `c` has, as the setup page's choice of model (see `MODEL_CHOICES`): one of those it
offers, or a local or other model, with its `model` and `url`.
"""
function current_choice(c::Config)
    s = summarizer(c, c.summarizer)
    i = findfirst(m -> m.papers == s.name, MODEL_CHOICES)
    i === nothing || return Dict("id" => MODEL_CHOICES[i].id, "model" => "", "url" => "")
    s.kind == :api && startswith(s.url, rstrip(c.ollama_url, '/')) && return Dict("id" => "ollama", "model" => s.model, "url" => "")
    return Dict("id" => "custom", "model" => s.model, "url" => s.url)
end

"What the setup page starts from and offers: the settings now, the arXiv categories, the summarizers and what each needs here."
function setup_json(kb::KB)
    c = kb.config
    lacking = unavailable(kb; fresh = true)
    Dict("needed" => setup_needed(kb),
         "group" => Dict("name" => c.group.name, "field" => c.group.field, "description" => c.group.description,
                         "focus_areas" => focus_json(c.group)),
         "watch" => c.watch_categories, "contact" => c.contact,
         "categories" => [Dict("id" => k, "title" => v) for (k, v) in sort!(collect(ARXIV_CATEGORIES))],
         "summarizers" => [Dict("name" => s.name, "kind" => string(s.kind), "model" => s.model,
                                "problem" => something(summarizer_problem(s), "")) for s in c.summarizers],
         "summarizer" => c.summarizer,
         "models" => model_choices_json(c), "ollama_models" => ollama_chat_models(c),
         "model" => current_choice(c),
         "machine" => Dict(string(k) => v for (k, v) in lacking if k in (:parser, :embedder, :qdrant)),
         "stream" => stream_name(with_config(c; dataset = DatasetConfig())))
end

"""
    apply_setup!(kb, answers; path = config_path()) -> Dict

Set the knowledge base up from the setup page's `answers`: `group` (`name`, `field`, `description`,
`focus_areas`), `watch` (arXiv categories), `contact`, `model` (see [`model_choice`](@ref)), and
`dataset`, whose `mode` is
`"alone"`, `"join"` (with `key`, the text of a key file, see [`save_key`](@ref)) or `"start"` (with
`stream`, and `store`: `"dir:<path>"`, or `"s3"` with `endpoint`, `bucket`, `prefix`,
`access_key_id` and `secret_access_key`, saved beside the config). A member who joins imports the
dataset at once. Returns `(; ok, job)`, the import's job id or `nothing`.
"""
function apply_setup!(kb::KB, b::AbstractDict; path::AbstractString = config_path())
    g = get(b, "group", Dict())
    over = Dict{String,Any}(
        "group" => Dict{String,Any}("name" => strip(String(get(g, "name", ""))), "field" => strip(String(get(g, "field", ""))),
                                    "description" => strip(String(get(g, "description", ""))),
                                    "focus_areas" => coerce_setting("group.focus_areas", get(g, "focus_areas", []))),
        "watch" => Dict{String,Any}("categories" => coerce_setting("watch.categories", get(b, "watch", String[]))),
        "contact" => strip(String(get(b, "contact", ""))))
    unknown = setdiff(over["watch"]["categories"], keys(ARXIV_CATEGORIES))
    isempty(unknown) || error("Not arXiv categories: $(join(unknown, ", "))")
    pin_layers!(kb, over, over["group"]["field"])
    # The models as they are unless the page chose others (a rerun leaves a local or other model, and
    # a judge set apart, as they were).
    if haskey(b, "model")
        m = model_choice(kb.config, b["model"]; config_dir = dirname(path))
        over["summarizer"] = over["judge"] = m.summarizer
        over["code_summarizer"] = m.code
        if !isempty(m.summarizers)
            # Added to those the settings file has, which a list in it would otherwise replace.
            file = settings_path(path)
            saved = isfile(file) ? get(TOML.parsefile(file), "summarizers", []) : []
            over["summarizers"] = [[x for x in saved if !any(t -> t["name"] == x["name"], m.summarizers)]; m.summarizers]
        end
    end
    d = get(b, "dataset", Dict())
    mode = String(get(d, "mode", "alone"))
    if mode == "join"
        over["dataset"] = save_key(String(get(d, "key", "")); config_dir = dirname(path))
    elseif mode == "start"
        stream = strip(String(get(d, "stream", "")))
        store = strip(String(get(d, "store", "")))
        t = Dict{String,Any}("role" => "publish", "store" => store)
        isempty(stream) || (t["stream"] = stream)
        if store == "s3"
            for k in ("endpoint", "bucket", "prefix")
                t[k] = strip(String(get(d, k, k == "prefix" ? "kb" : "")))
            end
            key, secret = (strip(String(get(d, k, ""))) for k in ("access_key_id", "secret_access_key"))
            # Checked before anything is written: a dataset half set up is worse than none.
            (isempty(t["endpoint"]) || isempty(t["bucket"]) || isempty(key) || isempty(secret)) &&
                error("A bucket needs its endpoint, its name, and an access key with its secret")
            creds = joinpath(dirname(path), "dataset_credentials")
            write_private(creds, sprint(TOML.print, Dict("access_key_id" => key, "secret_access_key" => secret)))
            t["credentials"] = creds
        elseif !startswith(store, "dir:")
            error("A dataset is kept in a folder (dir:<path>) or an S3-compatible bucket (s3)")
        end
        over["dataset"] = t
    elseif mode == "alone"
        over["dataset"] = Dict{String,Any}("role" => "none")
    else
        error("Unknown way to share: $mode")
    end
    c = save_overlay!(kb, over; path)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('setup_done', ?)", (now_iso(),))
    rebuild_site!(kb)                                              # its title, front page and questions
    job = mode == "join" ? start_import(kb).id : nothing
    return Dict("ok" => true, "job" => job)
end
