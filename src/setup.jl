# Setting up a new knowledge base, on its first run, from the site: who it is for (the group, its
# field and focus areas), what it watches on arXiv, which model summarizes, and whether it reads alone,
# joins a group's dataset with a key someone issued, or starts one. Written to the settings file, as
# the Configuration page writes (see admin.jl).

"""
Whether this knowledge base is still to be set up: no config file, no settings but how it is served
(which Kaimon's panel sets before anything else), and never set up from the site.
"""
function setup_needed(kb::KB; path::AbstractString = config_path())
    isfile(path) && return false
    file = settings_path(path)
    isfile(file) && !isempty(setdiff(keys(TOML.parsefile(file)), ("service",))) && return false
    return ismissing(scalar(kb, "SELECT value FROM kv WHERE key = 'setup_done'"))
end

focus_json(g::Group) = [Dict("name" => a.name, "description" => a.description) for a in g.focus_areas]
panels_json(g::Group) = [Dict("title" => p.title, "text" => p.text, "link" => p.link) for p in g.panels]
questions_json(g::Group) = [Dict("id" => q.id, "text" => q.text, "options" => q.options, "many" => q.many) for q in g.questions]

"What the setup page starts from and offers: the settings now, the arXiv categories, the summarizers and what each needs here."
function setup_json(kb::KB)
    c = kb.config
    lacking = unavailable(kb; fresh = true)
    Dict("needed" => setup_needed(kb),
         "group" => Dict("name" => c.group.name, "field" => c.group.field, "description" => c.group.description,
                         "focus_areas" => focus_json(c.group)),
         "watch" => c.watch_categories, "contact" => c.contact,
         "categories" => [Dict("id" => k, "title" => v) for (k, v) in sort!(collect(ARXIV_CATEGORIES))],
         "choice" => model_json(kb),
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
    haskey(b, "model") && merge!(over, model_overlay(kb, b["model"]; path))
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
    haskey(b, "model") && lock(() -> empty!(SUMMARY_FAILURES), SUMMARY_LOCK)
    execute!(kb, "INSERT OR REPLACE INTO kv VALUES ('setup_done', ?)", (now_iso(),))
    rebuild_site!(kb)                                              # its title, front page and questions
    job = mode == "join" ? start_import(kb).id : nothing
    return Dict("ok" => true, "job" => job)
end
