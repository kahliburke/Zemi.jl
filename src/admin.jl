# What the site's account, administration, operations and configuration pages ask of the API:
# a person's own tokens; users, invitations, roles, everyone's tokens, dataset keys and the audit
# log; the service's health, metrics, agents and jobs, and the controls over them; and the settings
# the Configuration page changes, written to the settings file beside the config (see
# `settings_path`). A person's own account and tokens need only `read`, which everyone signed in has.

# ── Settings ──────────────────────────────────────────────────────────────────────────────────────

"""
The settings the Configuration page changes: a dotted key into the config's tables, what kind of
value it takes, its label, and a line of help shown with it.
"""
const EDITABLE_SETTINGS = [
    (key = "summarizer", kind = "summarizer", label = "Summarizer", help = "Writes paper and section summaries, and classifies papers."),
    (key = "code_summarizer", kind = "summarizer", label = "Code summarizer", help = "Summarizes codebases."),
    (key = "record_summarizer", kind = "summarizer?", label = "Record summarizer", help = "Summarizes records. Default: the summarizer."),
    (key = "judge", kind = "summarizer", label = "Evaluation judge", help = "Scores summaries when comparing summarizers."),
    (key = "tutor", kind = "summarizer?", label = "Tutor", help = "Default: the summarizer."),
    (key = "tutor_effort", kind = "effort", label = "Tutor effort", help = "Lower answers faster."),
    (key = "notebooker", kind = "summarizer?", label = "Notebooks", help = "Writes notebooks from papers. Default: the summarizer."),
    (key = "analyst", kind = "summarizer?", label = "Paper of the day", help = "Writes the analysis of the paper of the day. Default: the summarizer."),
    (key = "search.layers", kind = "layers", label = "Search layers", help = "Searched unless a search picks others."),
    (key = "search.keyword", kind = "bool", label = "Keyword search", help = "Include BM25 keyword ranking by default."),
    (key = "watch.categories", kind = "strings", label = "arXiv categories", help = "Watched for new papers, e.g. q-bio.PE."),
    (key = "watch.days", kind = "int", label = "Days kept", help = "Days of new papers the watch list shows."),
    (key = "watch.hours", kind = "float", label = "Check interval (h)", help = "Hours between arXiv checks."),
    (key = "watch.judge", kind = "summarizer?", label = "Watch judge", help = "Rates new papers and picks the paper of the day. Default: the summarizer."),
    (key = "watch.read_from", kind = "int", label = "Read in full from", help = "Lowest rating read in full: 3 central, 2 related, 1 peripheral, 4 none."),
    (key = "watch.record_from", kind = "int", label = "Record from", help = "Lowest rating recorded with title and abstract only. 4 = none."),
    (key = "group.name", kind = "string", label = "Group name", help = "The site's title."),
    (key = "group.field", kind = "string", label = "Field", help = "The group's research field, e.g. coral reef ecology. Agents act as experts in it."),
    (key = "group.description", kind = "text", label = "Description", help = "What the group works on. Agents use it to relate papers to the group."),
    (key = "group.focus_areas", kind = "areas", label = "Focus areas", help = "Topics the landscape and the arXiv watch score papers against."),
    (key = "group.questions", kind = "questions", label = "Tutoring profile", help = "Questions readers answer so the tutor can pitch to them. {field} becomes the field."),
    (key = "group.panels", kind = "panels", label = "Front page panels", help = "The panels under the front page's title: a title, a line, and a page to link to (/projects) or none."),
    (key = "contact", kind = "string", label = "Contact email", help = "Sent with arXiv and OpenAlex requests, as their policies ask."),
    (key = "dataset.role", kind = "dataset_role", label = "Dataset", help = "Publish and import, import only, or neither."),
    (key = "dataset.stream", kind = "string", label = "Stream", help = "Name this knowledge base publishes under. Default: your login name."),
    (key = "dataset.content", kind = "bool", label = "Share content", help = "Also sync pages, studies and notebooks."),
    (key = "dataset.store", kind = "string", label = "Store", help = "dir:<path> for a folder, or s3."),
    (key = "dataset.endpoint", kind = "string", label = "Endpoint (s3)", help = "e.g. https://<account>.r2.cloudflarestorage.com"),
    (key = "dataset.bucket", kind = "string", label = "Bucket (s3)", help = "Bucket name."),
    (key = "dataset.prefix", kind = "string", label = "Prefix (s3)", help = "Folder within the bucket."),
    (key = "dataset.credentials", kind = "string", label = "Credentials (s3)", help = "TOML file with access_key_id and secret_access_key."),
    (key = "dataset.check_hours", kind = "float", label = "Check interval (h, 0 = off)", help = "How often to look for newly published streams."),
    (key = "dataset.autosync_hours", kind = "float", label = "Autosync interval (h, 0 = off)", help = "How often a publisher syncs and publishes."),
    (key = "dataset.read_unread", kind = "bool", label = "Autosync reads unread papers", help = "Also read papers recorded but not read in full."),
    (key = "shared.sign_up", kind = "sign_up", label = "Sign-up", help = "Invitation only, or open to anyone who can sign in."),
    (key = "shared.default_role", kind = "role", label = "Default role", help = "Given on first sign-in when sign-up is open."),
    (key = "shared.session_days", kind = "int", label = "Session length (days)", help = "Days before a sign-in expires."),
    (key = "shared.nightly_ingest", kind = "string", label = "Nightly ingest", help = "HH:MM to re-read linked codebases that changed. Empty = off."),
    (key = "shared.timezone", kind = "string", label = "Time zone", help = "For the nightly ingest, e.g. America/Los_Angeles."),
]

"A setting's value in configuration `c`."
function current_setting(c::Config, key::AbstractString)
    key == "search.layers" && return c.search_layers
    key == "search.keyword" && return c.search_keyword
    startswith(key, "watch.") && return getfield(c, Symbol("watch_", key[7:end]))
    key == "group.focus_areas" && return focus_json(c.group)
    key == "group.questions" && return questions_json(c.group)
    key == "group.panels" && return panels_json(c.group)
    startswith(key, "group.") && return getfield(c.group, Symbol(key[7:end]))
    startswith(key, "dataset.") && (v = getfield(c.dataset, Symbol(key[9:end])); return v isa Symbol ? string(v) : v)
    startswith(key, "shared.") && (v = getfield(c.shared, Symbol(key[8:end])); return v isa Symbol ? string(v) : v)
    return getfield(c, Symbol(key))
end

"A value from the page, as the setting `key` takes it, or an error saying why it cannot be."
function coerce_setting(key::AbstractString, v)
    i = findfirst(s -> s.key == key, EDITABLE_SETTINGS)
    i === nothing && error("$key is not a setting that can be changed here")
    kind = EDITABLE_SETTINGS[i].kind
    kind in ("summarizer", "summarizer?", "string", "text", "role") && return strip(string(v))
    kind == "effort" && (string(v) in ("low", "medium", "high", "max") || error("$key: low, medium, high or max"); return string(v))
    kind == "sign_up" && (string(v) in ("invite", "open") || error("$key: invite or open"); return string(v))
    kind == "dataset_role" && (string(v) in ("none", "publish", "consume") || error("$key: none, publish or consume"); return string(v))
    kind == "areas" && return map(collect(v)) do a
        name = strip(string(get(a, "name", "")))
        isempty(name) && error("A focus area needs a name")
        Dict{String,Any}("name" => name, "description" => strip(string(get(a, "description", ""))))
    end
    kind == "panels" && return map(collect(v)) do p
        title = strip(string(get(p, "title", "")))
        isempty(title) && error("A panel needs a title")
        Dict{String,Any}("title" => title, "text" => strip(string(get(p, "text", ""))), "link" => strip(string(get(p, "link", ""))))
    end
    if kind == "questions"
        qs = map(collect(v)) do q
            id, text = strip(string(get(q, "id", ""))), strip(string(get(q, "text", "")))
            (isempty(id) || isempty(text)) && error("A question needs an id and its text")
            options = filter(!isempty, strip.(string.(get(q, "options", []))))
            isempty(options) && error("The question $id needs options to answer it with")
            Dict{String,Any}("id" => id, "text" => text, "options" => options, "many" => get(q, "many", false) === true)
        end
        allunique(q["id"] for q in qs) || error("Two questions have the same id")
        return qs
    end
    kind == "bool" && return v === true || v in ("true", "1")
    if kind in ("int", "float")
        T = kind == "int" ? Int : Float64
        x = v isa (T == Int ? Integer : Real) ? T(v) : tryparse(T, string(v))
        return x === nothing ? error("$key: $(T == Int ? "a whole number" : "a number")") : x
    end
    kind in ("strings", "layers") && return v isa AbstractVector ? String.(strip.(string.(v))) : split_list(string(v))
    error("$key: unknown kind $kind")
end

"""
The settings a dataset member takes from the dataset's profile (see [`follow_profile`](@ref)), so
that what every stream reads is made with the same models: none until a profile has been read.
"""
followed_settings(c::Config) =
    c.dataset.role != :none && isfile(profile_cache(c)) ? Set(["summarizer", "code_summarizer"]) : Set{String}()

"""
    save_settings!(kb, changes; path = config_path()) -> Config

Change settings (dotted keys, see [`EDITABLE_SETTINGS`](@ref)) in the settings file and the running
knowledge base. The changed configuration is checked as a whole first, and nothing is changed if it
does not hold.
"""
function save_settings!(kb::KB, changes::AbstractDict; path::AbstractString = config_path())
    held = intersect(keys(changes), followed_settings(kb.config))
    isempty(held) || error("$(join(sort!(collect(held)), ", ")) follow the dataset's profile, which its publishers set")
    over = Dict{String,Any}()
    for (key, v) in changes
        value = coerce_setting(key, v)
        table, parts = over, split(key, '.')
        for p in parts[1:end-1]
            table = get!(Dict{String,Any}, table, p)
        end
        table[parts[end]] = value
    end
    haskey(changes, "group.field") && pin_layers!(kb, over, over["group"]["field"])
    if haskey(changes, "shared.default_role")
        role = over["shared"]["default_role"]
        any(r -> r.name == role, roles(kb)) || not_found("No role named $role")
    end
    return save_overlay!(kb, over; path)
end

"""
    pin_layers!(kb, over, field)

The default layers instruct their queries for the group's field (see `qwen_query_prefix`), and vectors
are only comparable to queries embedded the same way: when the field becomes `field` once anything is
embedded, the settings `over` keep the layers as they are.
"""
function pin_layers!(kb::KB, over::AbstractDict, field::AbstractString)
    c = kb.config
    (field == c.group.field || haskey(over, "layers") || scalar(kb, "SELECT count(*) FROM embeddings") == 0) && return
    over["layers"] = [Dict{String,Any}("name" => l.name, "model" => l.model, "unit" => string(l.unit), "url" => l.url,
                                       "key" => l.key, "query_prefix" => l.query_prefix, "doc_prefix" => l.doc_prefix,
                                       "max_chars" => l.max_chars, "source" => l.source == c.summarizer ? "default" : l.source,
                                       "trial" => l.trial) for l in c.layers]
end

"""
    write_settings!(over; path = config_path()) -> Config

Merge `over` into the settings file beside the config `path` (see [`settings_path`](@ref)) and return
the configuration it makes, if that holds as a whole; otherwise leave the file as it was and throw.
"""
function write_settings!(over::AbstractDict; path::AbstractString = config_path())
    file = settings_path(path)
    old = isfile(file) ? read(file, String) : nothing
    over = merge_settings(old === nothing ? Dict{String,Any}() : TOML.parse(old), over)
    mkpath(dirname(file))
    tmp = file * ".tmp"
    open(io -> (println(io, "# Written by the knowledge base (Setup, the Configuration page, zemi token add); overrides ", basename(path), ".");
                TOML.print(io, over)), tmp, "w")
    mv(tmp, file; force = true)
    return try
        validate(load_config(path))
    catch e
        old === nothing ? rm(file; force = true) : write(file, old)
        rethrow()
    end
end

"""
    save_overlay!(kb, over; path = config_path()) -> Config

Merge `over` into the settings file (see [`write_settings!`](@ref)) and apply the result to the running
knowledge base, if it holds as a whole configuration and keeps its data where it is; otherwise leave
the file and the knowledge base as they were.
"""
function save_overlay!(kb::KB, over::AbstractDict; path::AbstractString = config_path())
    file = settings_path(path)
    old = isfile(file) ? read(file, String) : nothing
    c = write_settings!(over; path)
    # What a running knowledge base cannot take on: where its data and vectors are.
    if !(c.data_dir == kb.config.data_dir && c.collection_prefix == kb.config.collection_prefix)
        old === nothing ? rm(file; force = true) : write(file, old)
        error("The data directory and collections cannot change while the knowledge base runs")
    end
    kb.config = c
    return c
end

"The settings, their values now, and what each can be set to, for the Configuration page."
function settings_json(kb::KB)
    c = kb.config
    followed = followed_settings(c)
    Dict("settings" => [Dict("key" => s.key, "kind" => s.kind, "label" => s.label, "help" => s.help, "value" => current_setting(c, s.key),
                             "follows" => s.key in followed)
                        for s in EDITABLE_SETTINGS],
         "summarizers" => [Dict("name" => s.name, "kind" => string(s.kind), "model" => s.model) for s in c.summarizers],
         "layers" => [l.name for l in c.layers if !l.trial],
         "roles" => [r.name for r in roles(kb)],
         "file" => settings_path(), "config" => config_path())
end

# ── Embedding layers ──────────────────────────────────────────────────────────────────────────────
# A layer is an embedding model applied to one kind of text: chunks, sections or whole papers, or the
# summaries of sections or papers by a summarizer. The Configuration page shows them as models, each
# building some kinds, and saves them as the layer list (`[[layers]]` in the settings file).

"The kinds of text a layer embeds: its unit, and whether it embeds summaries rather than the text."
const LAYER_KINDS = [(kind = "chunk", unit = :chunk, summary = false, label = "Chunks"),
                     (kind = "section", unit = :section, summary = false, label = "Sections"),
                     (kind = "paper", unit = :paper, summary = false, label = "Papers"),
                     (kind = "section-summary", unit = :section, summary = true, label = "Section summaries"),
                     (kind = "paper-summary", unit = :paper, summary = true, label = "Paper summaries")]

layer_kind(l::Layer) = isempty(l.source) ? string(l.unit) : "$(l.unit)-summary"

"Embedding models the page offers to add, as layers' settings, the Qwen ones instructed for the group's field."
model_presets(c::Config) = [
    (model = "qwen3-embedding:4b", url = "", key = "", query_prefix = qwen_query_prefix(c.group.field), doc_prefix = "", max_chars = 8000),
    (model = "qwen3-embedding:0.6b", url = "", key = "", query_prefix = qwen_query_prefix(c.group.field), doc_prefix = "", max_chars = 8000),
    (model = "nomic-embed-text", url = "", key = "", query_prefix = "search_query: ", doc_prefix = "search_document: ", max_chars = 6000),
    (model = "text-embedding-3-large", url = OPENAI_URL, key = OPENAI_KEY, query_prefix = "", doc_prefix = "", max_chars = 8000)]

"A model's part of a layer name: `qwen3-embedding:4b` → `qwen3-4b`, `text-embedding-3-large` → `3-large`."
model_slug(m::AbstractString) = slugify(replace(lowercase(m), r"(text-)?embed(ding)?(-text)?" => ""); keep = ".")

"""
    layer_name(kind, model, source, summarizer, taken) -> String

The name a new layer gets: its unit, then `summary` (summaries by the configured summarizer) or the
summarizer's name, then the model; made unique against `taken`. Layers already there keep theirs.
"""
function layer_name(kind::AbstractString, model::AbstractString, source::AbstractString, summarizer::AbstractString, taken)
    unit = first(split(kind, '-'))
    by = isempty(source) ? "" : source in ("default", summarizer) ? "summary-" : model_slug(source) * "-"
    base = "$unit-$by$(model_slug(model))"
    name, i = base, 2
    while name in taken
        name, i = "$base-$i", i + 1
    end
    return name
end

"The layers as the page shows them: models, the kinds each builds, and how full each layer is."
function layers_json(kb::KB)
    c = kb.config
    counts = Dict(r.layer => (; r.n, r.papers) for r in query(kb,
        "SELECT layer, count(*) AS n, count(DISTINCT paper_id) AS papers FROM embeddings GROUP BY layer"))
    stored = Set(String(r.name) for r in query(kb, "SELECT name FROM layers"))
    groups = Dict{Tuple,Vector{Layer}}()
    order = Tuple[]
    for l in c.layers
        k = (l.model, l.url, l.key, l.query_prefix, l.doc_prefix, l.max_chars)
        haskey(groups, k) || push!(order, k)
        push!(get!(Vector{Layer}, groups, k), l)
    end
    models = [Dict("model" => k[1], "url" => k[2], "key" => k[3], "query_prefix" => k[4], "doc_prefix" => k[5], "max_chars" => k[6],
                   "layers" => [Dict("name" => l.name, "kind" => layer_kind(l), "source" => l.source == c.summarizer ? "default" : l.source,
                                     "trial" => l.trial, "vectors" => get(counts, l.name, (; n = 0)).n,
                                     "papers" => get(counts, l.name, (; papers = 0)).papers) for l in groups[k]])
              for k in order]
    configured = Set(l.name for l in c.layers)
    Dict("models" => models,
         "kinds" => [Dict("kind" => k.kind, "label" => k.label, "summary" => k.summary) for k in LAYER_KINDS],
         "summarizers" => [s.name for s in c.summarizers], "summarizer" => c.summarizer,
         "presets" => [Dict(pairs(p)) for p in model_presets(c)],
         "papers" => scalar(kb, "SELECT count(*) FROM parses"),
         # Layers no longer configured whose vectors are still stored, to drop.
         "orphans" => [Dict("name" => n, "vectors" => get(counts, n, (; n = 0)).n) for n in sort!(collect(setdiff(stored, configured)))])
end

"""
    save_layers!(kb, models; path = config_path()) -> Config

Make the layers what the page sent: for each model, the kinds it builds (each with a summary source
and whether it is a trial). A layer already configured for the same model, kind and source keeps its
name, and so its vectors. The layer list goes to the settings file; the default search layers keep
only those still configured.
"""
function save_layers!(kb::KB, models::AbstractVector; path::AbstractString = config_path())
    c = kb.config
    existing = Dict((l.model, l.url, layer_kind(l), l.source == c.summarizer ? "default" : l.source) => l.name for l in c.layers)
    taken = Set(r.name for r in query(kb, "SELECT name FROM layers"))
    union!(taken, values(existing))
    out = Dict{String,Any}[]
    for m in models
        model = strip(String(m["model"]))
        isempty(model) && error("A model needs a name")
        url = strip(String(get(m, "url", "")))
        key = String(get(m, "key", ""))
        # A key read from this machine (a file, a variable, a login) is sent to the layer's address:
        # only those the config already names, as whoever runs the service set them.
        occursin(r"^(env:|file:|opencode$)", key) && !any(l -> l.key == key, c.layers) &&
            not_permitted("Not permitted: a key read from this machine ($key) is named in the config file, not here")
        for l in get(m, "layers", [])
            kind = String(l["kind"])
            k = findfirst(x -> x.kind == kind, LAYER_KINDS)
            k === nothing && error("Unknown layer kind $kind")
            source = LAYER_KINDS[k].summary ? String(something(get(l, "source", nothing), "default")) : ""
            LAYER_KINDS[k].summary && isempty(source) && (source = "default")
            name = get(existing, (model, url, kind, source), nothing)
            if name === nothing
                name = layer_name(kind, model, source, c.summarizer, taken)
                push!(taken, name)
            end
            any(d -> d["name"] == name, out) && error("Two layers would be named $name")
            push!(out, Dict{String,Any}("name" => name, "model" => model, "unit" => string(LAYER_KINDS[k].unit), "url" => url,
                "key" => key, "query_prefix" => String(get(m, "query_prefix", "")),
                "doc_prefix" => String(get(m, "doc_prefix", "")), "max_chars" => Int(get(m, "max_chars", 8000)),
                "source" => source, "trial" => get(l, "trial", false) === true))
        end
    end
    isempty(out) && error("Keep at least one layer")
    names = Set(d["name"] for d in out)
    search = [n for n in c.search_layers if n in names]
    return save_overlay!(kb, Dict{String,Any}("layers" => out, "search" => Dict{String,Any}("layers" => search)); path)
end

# ── Operations ────────────────────────────────────────────────────────────────────────────────────

"How the service is: its uptime and memory, disk, database, the services it needs, the site's builds."
function health_json(kb::KB)
    c = kb.config
    kv(k) = (v = scalar(kb, "SELECT value FROM kv WHERE key = ?", (k,)); ismissing(v) ? nothing : v)
    disk = try Base.Filesystem.diskstat(c.data_dir) catch; nothing end
    site = lock(() -> (; SITE.building, SITE.again, SITE.started, SITE.finished, SITE.error, SITE.id), SITE_LOCK)
    Dict("started" => string(STARTED[]), "uptime_seconds" => round(Int, (now() - STARTED[]).value / 1000),
         "memory" => Dict("process_bytes" => Sys.maxrss(), "free_bytes" => Sys.free_memory(), "total_bytes" => Sys.total_memory()),
         "threads" => Threads.nthreads(),
         "disk" => disk === nothing ? nothing : Dict("free_bytes" => disk.available, "total_bytes" => disk.total),
         "database_bytes" => isfile(db_path(c)) ? filesize(db_path(c)) : 0,
         "papers" => scalar(kb, "SELECT count(*) FROM papers"),
         "missing" => Dict(string(k) => v for (k, v) in unavailable(kb)),
         "agents_available" => try AGENTS_AVAILABLE[]() catch; false end,
         "mcp" => (e = EMBEDDED[]; e === nothing ? nothing : Dict("port" => e.port, "up" => embedded_ready(e))),
         "site" => Dict("building" => site.building, "queued" => site.again, "error" => site.error, "build" => site.id,
                        "started" => site.started === nothing ? nothing : string(site.started),
                        "finished" => site.finished === nothing ? nothing : string(site.finished)),
         "last" => Dict("watch" => kv("watch_checked_at"), "publish" => kv("dataset_published_at"), "pull" => kv("dataset_pulled")))
end

"Requests answered since the service started, by route: how many, how many failed, their time."
metrics_json() = lock(METRICS_LOCK) do
    sort!([Dict("route" => r, "count" => Int(m[1]), "errors" => Int(m[2]), "mean_ms" => round(1000m[3] / max(m[1], 1); digits = 1),
                "max_ms" => round(1000m[4]; digits = 1)) for (r, m) in METRICS]; by = d -> -d["count"])
end

"Whose request an agent serves, from its id: a conversation's owner, or the work it does."
function agent_purpose(kb::KB, id::AbstractString)
    m = match(r"^zemi-chat-(.+)$", id)
    if m !== nothing
        r = query(kb, "SELECT c.doc_id, u.email FROM chats c LEFT JOIN users u ON u.id = c.user_id WHERE c.id = ?", (m[1],))
        return isempty(r) ? "tutor" : "tutor: $(first(r).doc_id)" * (ismissing(first(r).email) ? "" : " ($(first(r).email))")
    end
    startswith(id, "zemi-") && return "summaries, notebooks"
    return ""
end

"The agents Kaimon runs, with what each is doing and has used."
function agents_json(kb::KB)
    list = try kaimon_tool(:agent_list, Dict{String,Any}()) catch e; return Dict("error" => sprint(showerror, e), "agents" => []) end
    agents = map(get(list, "agents", [])) do a
        id = String(a["id"])
        steps = [s for s in (agent_step(e) for e in last(agent_events(id), 40)) if s !== nothing]
        Dict("id" => id, "status" => a["status"], "model" => get(a, "model", ""), "turn" => get(a, "turn", 0),
             "usage" => get(a, "usage", Dict()), "last_activity" => get(a, "last_activity", nothing),
             "doing" => isempty(steps) ? nothing : last(steps).says, "purpose" => agent_purpose(kb, id),
             "mine" => startswith(id, "zemi"))
    end
    return Dict("agents" => agents)
end

# ── The routes ────────────────────────────────────────────────────────────────────────────────────

"Have the site built anew, as the service watching it does when its build stamp moves (see `watch_site!`)."
rebuild_site!(kb::KB) = (mkpath(kb.config.data_dir); touch(build_stamp(kb.config)))

user_json(u) = Dict("id" => u.id, "email" => u.email, "name" => u.name, "created_at" => u.created_at, "last_seen" => u.last_seen,
                    "disabled" => u.disabled, "roles" => u.roles, "sign_ins" => u.sign_ins)
token_json(t) = Dict("id" => t.id, "email" => t.email, "name" => t.name, "prefix" => t.prefix, "permissions" => t.permissions,
                     "projects" => t.projects,
                     "created_at" => t.created_at, "expires_at" => t.expires_at, "last_used" => t.last_used, "revoked" => t.revoked)

ok_json() = Dict("ok" => true)

# ── A person's own account ────────────────────────────────────────────────────────────────────────

route!("GET", "/api/me") do c
    kb, account = c.kb, c.caller.user_id
    merge(me_json(kb, c.caller), Dict("accounts" => account !== nothing,
                                      "roles" => account === nothing ? String[] : user_roles(kb, account),
                                      "tokens" => account === nothing ? [] : [token_json(t) for t in tokens(kb; uid = account)],
                                      "permission_groups" => permission_groups_json()))
end

# Viewing as someone, and going back, which is never refused for a permission they lack.
route!("POST", "/api/me/view-as"; viewing_as = true) do c
    who = get(json_body(c), "user_id", nothing)
    view_as!(c.kb, cookie(c.req, SESSION_COOKIE), who === nothing ? nothing : Int(who); c.caller)
    ok_json()
end

"Refuse changing tokens while viewing as someone: it shows what they see, and does not make or take back their tokens."
own_tokens!(c::APICall) =
    c.caller.admin === nothing || not_permitted("Not permitted while viewing as someone: their tokens are theirs to make and revoke")

route!("POST", "/api/me/tokens") do c
    own_tokens!(c)
    account = c.caller.user_id
    account === nothing && error("Tokens belong to accounts; run for one person, the knowledge base has none")
    # Made signed in, so a token never makes another wider than itself.
    c.caller.via == :token && not_permitted("Not permitted: tokens are made signed in to the site, not with a token")
    b = json_body(c)
    t = create_token!(c.kb, account; name = String(get(b, "name", "")),
                      permissions = get(b, "permissions", nothing) === nothing ? nothing : String.(b["permissions"]),
                      projects = get(b, "projects", nothing) === nothing ? nothing : String.(b["projects"]),
                      days = Int(get(b, "days", 90)))
    Dict("id" => t.id, "token" => t.token)
end

route!("POST", "/api/me/tokens/:id/revoke") do c
    own_tokens!(c)
    revoke_token!(c.kb, parse(Int, c[:id]); uid = c.caller.user_id)
    ok_json()
end

# ── People, roles, tokens and keys ────────────────────────────────────────────────────────────────

route!("GET", "/api/admin/users"; need = "users.manage") do c
    kb = c.kb
    Dict("users" => [user_json(u) for u in users(kb)],
         "invitations" => [Dict("email" => i.email, "roles" => i.roles, "created_at" => i.created_at,
                                "accepted_at" => i.accepted_at, "projects" => i.projects) for i in invitations(kb)],
         "roles" => [r.name for r in roles(kb)],
         # So the page can show which roles include which.
         "role_permissions" => Dict(r.name => r.permissions for r in roles(kb)))
end

route!("POST", "/api/admin/users/test"; need = "users.manage") do c
    b = json_body(c)
    Dict("id" => add_test_account!(c.kb, String(get(b, "name", "")); roles = String.(get(b, "roles", ["Reader"]))))
end

route!("POST", "/api/admin/users/:id"; need = "users.manage") do c
    uid, b = parse(Int, c[:id]), json_body(c)
    uid == c.caller.user_id && get(b, "disabled", false) === true && error("Can't disable your own account.")
    haskey(b, "roles") && set_roles!(c.kb, uid, String.(b["roles"]); by = c.caller.user_id)
    haskey(b, "disabled") && set_disabled!(c.kb, uid, b["disabled"] === true)
    ok_json()
end

route!("POST", "/api/admin/invite"; need = "users.manage") do c
    b = json_body(c)
    invite!(c.kb, String(b["email"]); roles = String.(get(b, "roles", [c.kb.config.shared.default_role])),
            projects = Dict{String,String}(get(b, "projects", Dict())), by = c.caller.user_id)
    ok_json()
end

route!(c -> (uninvite!(c.kb, String(json_body(c)["email"])); ok_json()), "POST", "/api/admin/uninvite"; need = "users.manage")

route!("GET", "/api/admin/roles"; need = "users.manage") do c
    Dict("roles" => [Dict("name" => x.name, "description" => x.description, "permissions" => x.permissions, "quotas" => x.quotas)
                     for x in roles(c.kb)],
         "permissions" => [Dict("name" => p, "description" => d) for (p, d) in PERMISSIONS],
         "permission_groups" => permission_groups_json())
end

route!("POST", "/api/admin/roles"; need = "users.manage") do c
    b = json_body(c)
    if get(b, "delete", false) === true
        delete_role!(c.kb, String(b["name"]); by = c.caller.user_id)
    else
        save_role!(c.kb, String(b["name"]); description = String(get(b, "description", "")), permissions = String.(get(b, "permissions", [])),
                   quotas = Dict{String,Int}(String(k) => Int(v) for (k, v) in get(b, "quotas", Dict())), by = c.caller.user_id)
    end
    ok_json()
end

route!(c -> Dict("tokens" => [token_json(t) for t in tokens(c.kb)]), "GET", "/api/admin/tokens"; need = "tokens.manage")
route!(c -> (revoke_token!(c.kb, parse(Int, c[:id])); ok_json()), "POST", "/api/admin/tokens/:id/revoke"; need = "tokens.manage")

# Keys are issued through Cloudflare's API: they need the dataset's R2 endpoint and bucket, and a
# Cloudflare token that may create API tokens. Not the publisher role: issuing is not publishing.
route!("GET", "/api/admin/keys"; need = "tokens.manage") do c
    d = c.kb.config.dataset
    why = isempty(d.endpoint) || isempty(d.bucket) ? "no R2 dataset configured" :
          (try r2_account(c.kb.config); "" catch e; sprint(showerror, e) end)
    isempty(why) && !isfile(d.admin_credentials) && (why = "no Cloudflare admin token")
    isempty(why) || return Dict("available" => false, "why" => why, "keys" => [])
    Dict("available" => true, "keys" => [Dict("name" => k.name, "status" => k.status) for k in list_keys(c.kb.config)])
end

route!("POST", "/api/admin/keys"; need = "tokens.manage") do c
    b = json_body(c)
    who = String(b["who"])
    get(b, "revoke", false) === true && (revoke_key(c.kb.config, who); return ok_json())
    write = get(b, "write", false) === true
    k = issue_key(c.kb.config, who; write)
    Dict("name" => k.name, "file" => key_file(c.kb.config, k; write, who), "file_name" => "$(member_stream(who)).toml")
end

route!("GET", "/api/admin/audit"; need = "audit.view") do c
    Dict("entries" => [Dict("id" => e.id, "at" => e.at, "who" => e.who, "action" => e.action, "target" => e.target, "detail" => e.detail)
                       for e in audit_log(c.kb; before = tryparse(Int, get(c.params, "before", "")))])
end

# ── Operations ────────────────────────────────────────────────────────────────────────────────────

route!("GET", "/api/ops"; need = "server.view") do c
    a = activity()
    Dict("health" => health_json(c.kb), "metrics" => metrics_json(), "jobs" => [job_json(j) for j in list_jobs()],
         "activity" => Dict("people" => Any[Dict(pairs(p)) for p in a.people], "running" => a.running,
                            "quiet" => a.quiet, "active_minutes" => a.active_minutes))
end

route!(c -> agents_json(c.kb), "GET", "/api/ops/agents"; need = "agents.view")
for act in ("interrupt", "close")
    route!(c -> (kaimon_tool(Symbol("agent_", act), Dict{String,Any}("agent_id" => c[:id])); ok_json()),
           "POST", "/api/ops/agents/:id/$act"; need = "agents.control")
end

route!(c -> (rebuild_site!(c.kb); ok_json()), "POST", "/api/ops/rebuild"; need = "server.control")

route!("POST", "/api/ops/reload"; need = "server.control") do c
    config = validate(load_config())
    config.data_dir == c.kb.config.data_dir || error("The data directory cannot change while the knowledge base runs")
    c.kb.config = config
    ok_json()
end

route!("POST", "/api/jobs/:id/cancel"; need = "jobs.control") do c
    j = get_job(c[:id])
    j === nothing && not_found("No job $(c[:id])")
    cancel!(j)
    ok_json()
end

# ── Configuration ─────────────────────────────────────────────────────────────────────────────────

route!(c -> settings_json(c.kb), "GET", "/api/config"; need = "config.view")
route!("POST", "/api/config"; need = "config.edit") do c
    changes = Dict{String,Any}(get(json_body(c), "changes", Dict()))
    save_settings!(c.kb, changes)
    any(startswith("group."), keys(changes)) && rebuild_site!(c.kb)      # the site's title, front page and questions
    settings_json(c.kb)
end

route!(c -> layers_json(c.kb), "GET", "/api/config/layers"; need = "config.view")
route!(c -> (save_layers!(c.kb, get(json_body(c), "models", [])); layers_json(c.kb)), "POST", "/api/config/layers"; need = "config.edit")

route!("POST", "/api/config/layers/:name/build"; need = "config.edit") do c
    kb, name = c.kb, c[:name]
    any(l -> l.name == name, kb.config.layers) || not_found("No layer $name")
    job = start_job("build layer $name"; changes = changes_stamp(kb.config)) do job
        n = build_layer!(kb, name; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        "$n vectors in $name."
    end
    Dict("job" => job.id)
end

route!("POST", "/api/config/layers/:name/drop"; need = "config.edit") do c
    any(l -> l.name == c[:name], c.kb.config.layers) && error("$(c[:name]) is configured: remove it from the layers first")
    drop_layer!(c.kb, c[:name])
    layers_json(c.kb)
end

# `?needed`: only whether it is, for the front page, without the checks of what is available.
route!(c -> haskey(c.params, "needed") ? Dict("needed" => setup_needed(c.kb)) : setup_json(c.kb), "GET", "/api/config/setup";
       need = "config.view")
route!(c -> apply_setup!(c.kb, json_body(c)), "POST", "/api/config/setup"; need = "config.edit")

route!(c -> brand_json(c.kb), "GET", "/api/config/brand"; need = "config.view")
route!("GET", "/api/config/brand/:image"; need = "config.view") do c
    haskey(BRAND_IMAGES, c[:image]) || not_found("No image $(c[:image])")
    file_response(brand_file(c.kb.config, c[:image]); c.req)
end
route!("POST", "/api/config/brand/:image"; need = "config.edit") do c
    which = c[:image]
    if get(c.params, "reset", "") == "1"
        reset_brand!(c.kb, which)
    elseif which == "logo"
        set_logo!(c.kb, body_bytes(c))
    else
        set_hero!(c.kb, which, body_bytes(c))
    end
    rebuild_site!(c.kb)
    brand_json(c.kb)
end

route!(c -> Dict("conflicts" => [Dict(pairs(x)) for x in content_conflicts(c.kb)]), "GET", "/api/config/conflicts"; need = "config.view")
route!("POST", "/api/config/conflicts"; need = "config.edit") do c
    b = json_body(c)
    Dict("done" => resolve_conflict!(c.kb, String(b["path"]); take = get(b, "take", false) === true,
                                     stream = String(get(b, "stream", "")), hash = String(get(b, "hash", ""))))
end
