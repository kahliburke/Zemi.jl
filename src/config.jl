"""
    Layer

One embedding layer: a model applied to one kind of unit. `unit` is `:paper` (title and abstract),
`:section` (a section's text under its heading path) or `:chunk` (a passage of about a paragraph
or two). Each layer has its own Qdrant collection, because models differ in vector size.

`query_prefix` and `doc_prefix` are the instruction strings a model expects in front of queries and
documents. `max_chars` caps the text sent to the model.

`source` is empty for a layer over the paper's own text, or names a [`Summarizer`](@ref) whose
summaries the layer embeds instead (sections and papers only).

A `trial` layer is kept for comparing models: ingesting and syncing leave it alone, and search uses
it only when asked. [`build_layer!`](@ref) embeds papers in it.

`url` is empty for a model served by the config's Ollama, or the base URL of an OpenAI-compatible
embeddings API (such as `https://api.openai.com/v1`), with `key` saying where its API key comes
from (see [`resolve_key`](@ref)).
"""
Base.@kwdef struct Layer
    name::String
    model::String
    unit::Symbol
    query_prefix::String = ""
    doc_prefix::String = ""
    max_chars::Int = 8000
    source::String = ""
    trial::Bool = false
    url::String = ""
    key::String = ""
end

"""
    Summarizer

What writes summaries, classifies documents, writes probe questions and judges summaries. Two
kinds:

- `kind = :api`: an LLM behind an OpenAI-compatible chat completions API at `url` (OpenCode Zen,
  OpenAI and Ollama's `/v1` all speak it), called once per section and once per paper. `key` says
  where the API key comes from (see [`resolve_key`](@ref)); `request` holds extra fields for each
  request, such as a temperature or a reasoning effort, since models differ in which they accept.
  Section text longer than `max_input_chars` is cut.
- `kind = :agent`: an agent run through Kaimon's agent system (which needs the code to run in a
  Kaimon session: the `zemi` extension, a Slate notebook, or the `zemi` command). `model` is any model
  Kaimon's agents take: `"opus"` or `"sonnet"` for Claude through a Claude subscription,
  `"ollama:<tag>"` for a local model, `"acp:opencode:<model>"` for OpenCode. The agent reads the
  whole paper first, from its PDF (`reads = :pdf`) or its extracted text (`reads = :text`), then
  writes every summary; for a codebase, agents read its files in batches, then one writes the
  directory and codebase summaries. `timeout` bounds one agent's turn, in seconds.

`price_in` and `price_out` are dollars per million input and output tokens, for costing (an agent
on a subscription costs nothing per token).
"""
Base.@kwdef struct Summarizer
    name::String
    model::String
    kind::Symbol = :api
    url::String = ""
    key::String = ""
    request::Dict{String,Any} = Dict{String,Any}("temperature" => 0.2)
    max_input_chars::Int = 24000
    reads::Symbol = :pdf
    timeout::Float64 = 1800.0
    price_in::Float64 = 0.0
    price_out::Float64 = 0.0
end

const OPENAI_URL = "https://api.openai.com/v1"
const OPENAI_KEY = "file:~/.config/zemi/openai_key"
const ZEN_URL = "https://opencode.ai/zen/v1"

default_summarizers() = [
    Summarizer(; name = "deepseek-v4.1-flash", url = ZEN_URL, model = "deepseek-v4.1-flash", key = "opencode",
        price_in = 0.30, price_out = 1.20),
    Summarizer(; name = "deepseek-flash", url = ZEN_URL, model = "deepseek-v4-flash", key = "opencode",
        price_in = 0.14, price_out = 0.28),
    # GPT-5 models take only the default temperature, and bill their reasoning as output.
    Summarizer(; name = "gpt-5.4-mini", url = OPENAI_URL, model = "gpt-5.4-mini", key = OPENAI_KEY,
        request = Dict{String,Any}("reasoning_effort" => "low"), price_in = 0.75, price_out = 4.50),
    Summarizer(; name = "opus-agent-pdf", kind = :agent, model = "opus", reads = :pdf),
    Summarizer(; name = "opus-agent-text", kind = :agent, model = "opus", reads = :text),
    Summarizer(; name = "opus-agent-code", kind = :agent, model = "opus"),
    Summarizer(; name = "sonnet-agent-pdf", kind = :agent, model = "sonnet", reads = :pdf),
    Summarizer(; name = "sonnet-agent-code", kind = :agent, model = "sonnet"),
]

"""
    resolve_key(spec, who) -> String

An API key from where `spec` says it is: `""` for none, `"env:NAME"` for an environment variable,
`"file:PATH"` for the first line of a file that is neither blank nor a `#` comment, or `"opencode"` for the key typed on the
setup page (`opencode_key` beside the config), else the one the OpenCode CLI stored when you logged in, else the `OPENCODE_API_KEY` environment variable (a container's, say, where no one logs
in). `who` names the layer or summarizer, for errors.
"""
function resolve_key(spec::AbstractString, who::AbstractString)
    isempty(spec) && return ""
    if startswith(spec, "env:")
        k = get(ENV, spec[5:end], "")
        isempty(k) && error("$who: environment variable $(spec[5:end]) is not set")
        return k
    elseif startswith(spec, "file:")
        path = expanduser(spec[6:end])
        isfile(path) || error("$who: no key file at $path")
        lines = [strip(l) for l in eachline(path) if !isempty(strip(l)) && !startswith(strip(l), '#')]
        isempty(lines) && error("$who: no key in $path")
        return String(first(lines))
    elseif spec == "opencode"
        saved = joinpath(dirname(config_path()), "opencode_key")       # typed on the setup page
        isfile(saved) && return resolve_key("file:" * saved, who)
        path = joinpath(xdg_home("XDG_DATA_HOME", ".local/share"), "opencode", "auth.json")
        isfile(path) && return String(JSON.parsefile(path)["opencode"]["key"])
        k = get(ENV, "OPENCODE_API_KEY", "")
        isempty(k) && error("$who: no OpenCode login at $path (run `opencode auth login`) and no OPENCODE_API_KEY set")
        return k
    end
    error("$who: key must be \"\", \"env:NAME\", \"file:PATH\" or \"opencode\", got \"$spec\"")
end

const UNITS = (:paper, :section, :chunk)

"""
    qwen_query_prefix(field = "") -> String

The instruction Qwen3 embedding models expect in front of a query: retrieval of passages answering a
question, about the group's `field` when it is given. Vectors are only comparable to queries
embedded with the same instruction, so changing the field of a knowledge base that has been
embedded calls for the layers' `query_prefix` to be kept in its config.
"""
function qwen_query_prefix(field::AbstractString = "")
    about = isempty(field) ? "a research question" : "a question about $field"
    return "Instruct: Given $about, retrieve passages from scientific papers that answer it\nQuery: "
end

"""
The default layers; the summary layers embed the summaries written by the summarizer named
`summarizer`, and queries are embedded with the instruction for `field` (see [`qwen_query_prefix`](@ref)).
"""
function default_layers(summarizer::AbstractString = "deepseek-v4.1-flash"; field::AbstractString = "")
    prefix = qwen_query_prefix(field)
    qwen(size, unit) = Layer(; name = "$unit-qwen3-$size", model = "qwen3-embedding:$size",
        unit, query_prefix = prefix)
    return [
        qwen("4b", :paper),
        qwen("4b", :section),
        qwen("4b", :chunk),
        Layer(; name = "section-summary-qwen3-4b", model = "qwen3-embedding:4b", unit = :section,
            query_prefix = prefix, source = summarizer),
        Layer(; name = "paper-summary-qwen3-4b", model = "qwen3-embedding:4b", unit = :paper,
            query_prefix = prefix, source = summarizer),
    ]
end

"""
    DatasetConfig

Sharing the knowledge base as a dataset (see dataset.jl). `role` is `:publish` (this machine reads
papers, publishes what it read to its stream, `stream`, by default the user's login name, and imports
the other members' streams), `:consume` (it imports the dataset instead of reading papers itself) or
`:none`. With `content`, the content (see [`content_path`](@ref)) is shared with the documents.
`store` says where the dataset lives: `"dir:<path>"` for a directory, or `"s3"` for an S3-compatible
bucket (Cloudflare R2, AWS S3, Backblaze B2, MinIO) at `endpoint`, in `bucket` under `prefix`, with
the access key in `credentials` (a TOML file holding `access_key_id` and `secret_access_key`). A publisher with
`autosync_hours > 0` syncs and publishes that often wherever the tools are served (`zemi`, `zemi
--shared`, the Kaimon extension), reading
every recorded paper when `read_unread`. A consumer's `zemi` checks for a newer publish every
`check_hours` (0 for never) and imports it. A publisher on Cloudflare R2 issues people keys (see
access.jl) with the Cloudflare API token saved in `admin_credentials`.
"""
Base.@kwdef struct DatasetConfig
    role::Symbol = :none
    stream::String = ""
    content::Bool = true
    store::String = ""
    endpoint::String = ""
    bucket::String = ""
    prefix::String = "kb"
    region::String = "auto"
    credentials::String = ""
    autosync_hours::Float64 = 0.0
    read_unread::Bool = true
    check_hours::Float64 = 1.0
    admin_credentials::String = joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "zemi", "cloudflare_admin")
end

"""
    StoreConfig

Where a copy of something is kept, in the form `[dataset]` names its store (see
[`DatasetConfig`](@ref)): `store` `"dir:<path>"` or `"s3"`, then `endpoint`, `bucket`, `prefix`,
`region` and `credentials` for a bucket. `store` empty: kept nowhere.
"""
Base.@kwdef struct StoreConfig
    store::String = ""
    endpoint::String = ""
    bucket::String = ""
    prefix::String = ""
    region::String = "auto"
    credentials::String = ""
end

"A store as configured, `dir:<path>` with its path resolved by `path`."
store_path(store::AbstractString, path) = startswith(store, "dir:") && length(store) > 4 ? "dir:" * path(store[5:end]) : store

store_config(t::AbstractDict; path = expanduser) = StoreConfig(; store = store_path(get(t, "store", ""), path), endpoint = get(t, "endpoint", ""),
    bucket = get(t, "bucket", ""), prefix = get(t, "prefix", ""), region = get(t, "region", "auto"),
    credentials = (c = get(t, "credentials", ""); isempty(c) ? c : path(c)))

"""
    BackupConfig

Snapshots of the knowledge base (see backup.jl), `[backup]` in the config: `enabled` (on by default),
taken every `every_hours` into `dir`, by default `backups` beside the data folder (the data folder's
path with `.backups` added), outside it so that losing the data leaves them. A snapshot is the
database, the config folder, the content and the records; with `files`, also a copy of the PDFs,
figures and uploads, hard-linked to the last snapshot's where unchanged. Kept: every snapshot for
`keep_all_hours`, one per 12 hours for `keep_half_daily_days`, one a day for `keep_daily_days`. None is
taken when the disk has less than `min_free_gb` free, and past `max_gb` (0 for no limit) the oldest go
first.
"""
Base.@kwdef struct BackupConfig
    enabled::Bool = true
    dir::String = ""
    every_hours::Float64 = 1.0
    keep_all_hours::Float64 = 24.0
    keep_half_daily_days::Float64 = 3.0
    keep_daily_days::Float64 = 14.0
    files::Bool = true
    min_free_gb::Float64 = 5.0
    max_gb::Float64 = 0.0
end

function backup_config(t::AbstractDict; path = expanduser)
    d = BackupConfig()
    num(k) = Float64(get(t, k, getfield(d, Symbol(k))))
    dir = String(get(t, "dir", ""))
    return BackupConfig(; enabled = Bool(get(t, "enabled", d.enabled)), dir = isempty(dir) ? dir : path(dir),
        every_hours = num("every_hours"), keep_all_hours = num("keep_all_hours"), keep_half_daily_days = num("keep_half_daily_days"),
        keep_daily_days = num("keep_daily_days"), files = Bool(get(t, "files", d.files)), min_free_gb = num("min_free_gb"),
        max_gb = num("max_gb"))
end

"""
A way to sign in to the shared service (see [`SharedConfig`](@ref)): `kind` `:oidc`, an OpenID
Connect provider whose endpoints come from `issuer`'s discovery document, or `:github`, which signs
in with OAuth 2 and gives the account through GitHub's API. `client_secret` is a key as layers'
keys are: the value, `"env:NAME"` or `"file:PATH"`. `scopes` default to what the kind needs. An
OIDC provider's email is taken as verified only when its ID token says so, or, with `email_verified`,
when it says nothing: for a provider whose emails are its own records of people, such as an
institution's (an unverified email could otherwise sign in to the account that has it).
"""
Base.@kwdef struct Provider
    name::String
    kind::Symbol = :oidc
    issuer::String = ""
    client_id::String = ""
    client_secret::String = ""
    scopes::String = kind == :github ? "read:user user:email" : "openid email profile"
    email_verified::Bool = false
end

"""
A GitHub App the shared service reads repositories as, where it is installed on them (see
repos.jl): its `client_id`, and `private_key`, the path of a private key GitHub generated for it.
"""
Base.@kwdef struct GitHubApp
    client_id::String = ""
    private_key::String = ""
end

"""
How Kaimon runs the knowledge base when it hosts it as its extension (`[service]`, see hosted.jl):
for one person (`mode = "solo"`, on `port`) or for the people signed in to it (`"shared"`, on
`[shared] port`), the site built (`dev = false`) or from VitePress's development server on
`dev_port`, its components updated as they are edited.
"""
Base.@kwdef struct ServiceConfig
    mode::Symbol = :solo
    dev::Bool = false
    port::Int = 8000
    dev_port::Int = 5173
end

function service_config(t::AbstractDict)
    d = ServiceConfig()
    mode = Symbol(get(t, "mode", "solo"))
    mode in (:solo, :shared) || error("[service] mode is solo or shared, not $mode")
    return ServiceConfig(; mode, dev = Bool(get(t, "dev", d.dev)), port = Int(get(t, "port", d.port)),
                         dev_port = Int(get(t, "dev_port", d.dev_port)))
end

"""
The shared service, `zemi --shared` (read only in that mode): where people reach it (`base_url`), the
address and port it listens on (localhost behind a proxy; all addresses, `0.0.0.0`, in a container)
and which Kaimon serves its tools and hosts its agents (`kaimon`: `:embedded`, one of its own on
`kaimon_port`, restricted per caller and behind `/mcp`; or `:external`, the Kaimon already running
on this machine, which gives its tools to every session connected to it, with `/mcp` off), who may sign in (`sign_up`: `:invite`, only invited
emails, or `:open`, anyone, as `default_role`), the emails made admins on their first sign-in, how
long a session lasts, the proxies whose `X-Forwarded-*` headers are believed, and the `providers`
people sign in with, and the `github_app` it reads private repositories as. `nightly_ingest` is the
time of night (`"HH:MM"`, in `timezone`) the linked codebases whose files changed are ingested (see
[`nightly_ingest!`](@ref)); empty turns it off. `confine_agents` confines the processes of the
agents the service's Kaimon starts, and of notebooks' workers, to their own folders (on Linux; see
confine.jl).
"""
Base.@kwdef struct SharedConfig
    base_url::String = ""
    host::String = "127.0.0.1"
    port::Int = 8800
    kaimon::Symbol = :embedded
    kaimon_port::Int = 2829
    admins::Vector{String} = String[]
    sign_up::Symbol = :invite
    default_role::String = "Reader"
    session_days::Int = 14
    trusted_proxies::Vector{String} = ["127.0.0.1", "::1"]
    providers::Vector{Provider} = Provider[]
    github_app::GitHubApp = GitHubApp()
    nightly_ingest::String = "02:00"
    timezone::String = "UTC"
    confine_agents::Bool = true
end

function shared_config(t::AbstractDict; path = expanduser)
    d = SharedConfig()
    app = get(t, "github_app", Dict())
    providers = map(get(t, "providers", [])) do p
        kind = Symbol(get(p, "kind", "oidc"))
        kw = Dict{Symbol,Any}(:name => String(p["name"]), :kind => kind, :issuer => rstrip(String(get(p, "issuer", "")), '/'),
                                    :client_id => String(get(p, "client_id", "")), :client_secret => String(get(p, "client_secret", "")))
        haskey(p, "scopes") && (kw[:scopes] = String(p["scopes"]))
        haskey(p, "email_verified") && (kw[:email_verified] = Bool(p["email_verified"]))
        Provider(; kw...)
    end
    port = Int(get(t, "port", d.port))
    # Tried on this machine with the local sign-in, the service is at localhost on its port unless the
    # config says otherwise, however often the config is read again (see `run_shared`).
    base_url = rstrip(String(get(t, "base_url", d.base_url)), '/')
    isempty(base_url) && LOCAL_SIGN_IN[] && (base_url = "http://localhost:$port")
    return SharedConfig(; base_url, host = String(get(t, "host", d.host)), port,
        kaimon = Symbol(get(t, "kaimon", string(d.kaimon))), kaimon_port = Int(get(t, "kaimon_port", d.kaimon_port)), admins = lowercase.(String.(get(t, "admins", d.admins))),
        sign_up = Symbol(get(t, "sign_up", string(d.sign_up))), default_role = String(get(t, "default_role", d.default_role)),
        session_days = Int(get(t, "session_days", d.session_days)),
        trusted_proxies = String.(get(t, "trusted_proxies", d.trusted_proxies)), providers,
        github_app = GitHubApp(; client_id = String(get(app, "client_id", "")),
                               private_key = (k = String(get(app, "private_key", "")); isempty(k) ? k : path(k))),
        nightly_ingest = strip(String(get(t, "nightly_ingest", d.nightly_ingest))), timezone = String(get(t, "timezone", d.timezone)),
        confine_agents = get(t, "confine_agents", d.confine_agents) === true)
end

"The time of night of `[shared] nightly_ingest`, or `nothing` when it is off."
function nightly_time(sh::SharedConfig)
    isempty(sh.nightly_ingest) && return nothing
    m = match(r"^(\d{1,2}):(\d\d)$", sh.nightly_ingest)
    m === nothing && error("[shared] nightly_ingest must be a time like \"02:00\", or empty, got \"$(sh.nightly_ingest)\"")
    h, mi = parse(Int, m[1]), parse(Int, m[2])
    (h < 24 && mi < 60) || error("[shared] nightly_ingest must be a time like \"02:00\", got \"$(sh.nightly_ingest)\"")
    return Time(h, mi)
end

"The time zone of `[shared] timezone`."
time_zone(sh::SharedConfig) =
    try
        TimeZones.TimeZone(sh.timezone)
    catch
        error("[shared] timezone must be a zone like \"America/Los_Angeles\", got \"$(sh.timezone)\"")
    end

"""
    FocusArea

One of the group's areas of work: a short `name` for the landscape's views, and a `description`
that is embedded as a search query, so each paper's closeness to the area is its similarity to it.
"""
Base.@kwdef struct FocusArea
    name::String
    description::String
end

"""
    Panel

One of the panels on the site's front page: a `title`, a line of `text`, and a `link` (a page of the
site, `/projects`, or an address) or none.
"""
Base.@kwdef struct Panel
    title::String
    text::String
    link::String = ""
end

"The front page's panels when the group names none."
const DEFAULT_PANELS = [
    Panel("Papers", "Read in full, summarized by section, searchable by keyword and by meaning.", "/generated/kb/"),
    Panel("Tutor", "Ask about a paper. The tutor has read it and its neighbours, and adjusts to your background.", ""),
    Panel("Findings", "The group's conclusions, each citing its papers, notebooks and results.", "/findings"),
    Panel("Projects", "Tasks that people and agents plan, take and report on.", "/projects"),
]

"""
    ProfileQuestion

A question of the tutoring profile, the optional survey a learner answers so the tutor can pitch
its explanations: an `id`, the `text` asked, the `options` offered, and whether `many` may be
chosen. `{field}` in the text or an option stands for the group's field.
"""
Base.@kwdef struct ProfileQuestion
    id::String
    text::String
    options::Vector{String}
    many::Bool = false
end

const DEFAULT_PROFILE = [
    ProfileQuestion(; id = "stage", text = "Where are you in your studies or work?",
        options = ["Undergraduate, early in the degree", "Undergraduate, later in the degree", "Master's student", "PhD student",
                   "Postdoctoral or research scientist", "Faculty", "Engineer or industry professional", "Exploring on my own"]),
    ProfileQuestion(; id = "field", text = "How familiar are you with {field}?",
        options = ["New to it", "Some reading or an introductory course", "Coursework in it",
                   "Research experience in a related field", "Working in it, newer to some topics", "Experienced in it"]),
    ProfileQuestion(; id = "maths", text = "How much mathematics do you bring?",
        options = ["Little beyond school", "Introductory calculus and statistics",
                   "Upper-level undergraduate (linear algebra, differential equations)", "Graduate coursework or more"]),
    ProfileQuestion(; id = "goals", text = "What brings you to these papers? Choose any that apply.", many = true,
        options = ["A course, reading group or seminar", "Getting up to speed for research in a group",
                   "Preparing to discuss work with an advisor", "Finding open questions or directions",
                   "Implementing or reproducing a result", "General curiosity"]),
    ProfileQuestion(; id = "computing", text = "How much scientific computing have you done?",
        options = ["Little or none", "Some scripting (Python, Julia, R, MATLAB)",
                   "Comfortable with numerical methods and scientific code", "Developing research software or using HPC"]),
    ProfileQuestion(; id = "pitch", text = "How would you like explanations pitched?",
        options = ["Build from fundamentals, defining terms as they come up",
                   "Assume an undergraduate background; explain what is specific to the field",
                   "Assume a graduate background; focus on what is new", "Brief and technical"]),
    ProfileQuestion(; id = "style", text = "What helps you understand? Choose any that apply.", many = true,
        options = ["Intuition and pictures first", "Equations and derivations", "Worked examples with numbers",
                   "Analogies to things I know", "Questions that check my understanding", "Pointers to further reading"]),
]

"""
    Group

Who the knowledge base is for, which its agents are told and its site shows: the group's `name`
(the site's title), its `field` (a phrase that reads after "in" or "about", such as "marine
ecology"), a `description` of what it works on, which classifying a document judges relevance
against, its `focus_areas` (see [`FocusArea`](@ref)), the `questions` of the tutoring profile
(see [`ProfileQuestion`](@ref)), and the `panels` of the site's front page (see [`Panel`](@ref)).
Empty, the agents speak of research in general. In the file it is a `[group]` table, with
`[[group.focus_areas]]`, `[[group.questions]]` and `[[group.panels]]`.
"""
Base.@kwdef struct Group
    name::String = ""
    field::String = ""
    description::String = ""
    focus_areas::Vector{FocusArea} = FocusArea[]
    questions::Vector{ProfileQuestion} = DEFAULT_PROFILE
    panels::Vector{Panel} = DEFAULT_PANELS
    restarting::String = ""
end

function group_config(t::AbstractDict)
    areas = [FocusArea(String(f["name"]), String(f["description"])) for f in get(t, "focus_areas", [])]
    questions = haskey(t, "questions") ?
        [ProfileQuestion(; id = String(q["id"]), text = String(q["text"]), options = String.(q["options"]),
                         many = Bool(get(q, "many", false))) for q in t["questions"]] : DEFAULT_PROFILE
    panels = haskey(t, "panels") ?
        [Panel(; title = String(p["title"]), text = String(get(p, "text", "")), link = String(get(p, "link", ""))) for p in t["panels"]] :
        DEFAULT_PANELS
    return Group(; name = strip(String(get(t, "name", ""))), field = strip(String(get(t, "field", ""))),
                 description = strip(String(get(t, "description", ""))), focus_areas = areas, questions, panels,
                 restarting = strip(String(get(t, "restarting", ""))))
end

"""
    in_field(group; prefix = " in ") -> String

The group's field as a phrase to follow a noun ("researchers in marine ecology"), or nothing when
the field is not set: `prefix * field`, else `""`.
"""
in_field(g::Group; prefix::AbstractString = " in ") = isempty(g.field) ? "" : prefix * g.field

"""
    group_brief(group) -> String

What agents are told of the group before they judge or write for it: its field, its description
and its focus areas, each only when set, ending in a blank line; empty when none is.
"""
function group_brief(g::Group)
    io = IOBuffer()
    isempty(g.field) || println(io, "The group works in ", g.field, ".")
    isempty(g.description) || println(io, "The group: ", g.description)
    if !isempty(g.focus_areas)
        println(io, "Its focus areas:")
        foreach(f -> println(io, "- ", f.name, ": ", f.description), g.focus_areas)
    end
    s = String(take!(io))
    return isempty(s) ? s : s * "\n"
end

"The tutoring profile's questions with the group's field in place of `{field}`."
function profile_questions(g::Group)
    f = isempty(g.field) ? "the field" : g.field
    sub(s) = replace(s, "{field}" => f)
    return [ProfileQuestion(; id = q.id, text = sub(q.text), options = sub.(q.options), many = q.many) for q in g.questions]
end

"""
    PluginConfig(; env = "", load = [])

The packages the serving processes load as plugins (`[plugins]`, see plugins.jl): `env`, a Julia
environment holding them, and `load`, the names of those to load.
"""
Base.@kwdef struct PluginConfig
    env::String = ""
    load::Vector{String} = String[]
end

"Where Qdrant is when neither the config nor Kaimon says."
const DEFAULT_QDRANT = "http://localhost:6333"

"""
    Config

Where the knowledge base keeps its data and which services and embedding layers it uses. Read
from `~/.config/zemi/config.toml` by [`load_config`](@ref); every field has a
default, so the file is optional.

`data_dir` holds what the knowledge base computes and keeps: its database, PDFs and built site.
`content_dir` holds what its people write (see [`content_path`](@ref)): pages, studies, notebooks and
the site's images, by default `content` in the data directory. Relative paths for either are taken
from the config file's folder, so an instance can be one folder: its config, content and data.

`qdrant_url` and `qdrant_key` name a Qdrant and its API key (a key as layers' keys are); with no
URL, the one Kaimon runs (see [`qdrant_endpoint`](@ref)).

`base_set` is a file a new, empty knowledge base is seeded from (see [`seed!`](@ref)), `""` for none.

`group` says who the knowledge base is for (see [`Group`](@ref)): its name, field, description,
focus areas and tutoring profile. The landscape (see [`landscape!`](@ref)) measures every paper
against the focus areas; `landscape_layer` names the paper layer it places papers by (by default the
first searched one that embeds titles and abstracts), and `landscape_clusters` how many clusters it
finds (0 for a number suited to the count of papers), in a `[landscape]` table with `layer` and
`clusters`.

`watch_categories` are the arXiv categories watched for new papers (see [`watch!`](@ref)), none by
default, each check looking back `watch_days`; `zemi` checks every `watch_hours` (0 for only when asked).
`watch_judge` names the summarizer that judges the new papers and picks the paper of the day (see
daily.jl); empty for `summarizer`. The papers it rates at least `watch_read_from` (0–3: unrelated,
peripheral, related, central) are taken in and read in full, and those it rates at least
`watch_record_from` only recorded (see [`take_watched!`](@ref)); above 3 takes none. In the file they
are a `[watch]` table with `categories`, `days`, `hours`, `judge`, `read_from` and `record_from`.

`search_layers` and `search_keyword` are what a search uses unless it says otherwise: by default
the layers built on the strongest embedding model, and the keyword index.

`rank_weights` and `rrf_k` set how search combines its rankings (see [`fuse`](@ref)); a ranking
without a weight weighs 1. In the file they are a `[ranking]` table: `k = 60` and a `weights`
table keyed by ranking name.

`dataset` configures sharing the knowledge base (see [`DatasetConfig`](@ref)); a consumer's layers
and summarizer names come from the dataset it imports.

`sources` holds each record source's own settings, its `[sources.<name>]` table, as the source reads
them (see [`settings`](@ref)); `plugins` the packages loaded as plugins (see [`PluginConfig`](@ref)).

`summarizer` names the [`Summarizer`](@ref) that writes the summaries the summary layers embed and
classifies documents; `code_summarizer` the one that summarizes codebases; `record_summarizer` the
one that summarizes records (empty: `summarizer`); `judge` the one that
judges summaries in an evaluation. In the file a layer's
`source = "default"` means `summarizer`.
"""
Base.@kwdef struct Config
    data_dir::String = joinpath(xdg_home("XDG_DATA_HOME", ".local/share"), "zemi")
    content_dir::String = joinpath(data_dir, "content")
    ollama_url::String = "http://localhost:11434"
    ollama_keep_alive::String = "24h"
    qdrant_url::String = ""
    qdrant_key::String = ""
    collection_prefix::String = "zemi"
    mutool::String = "mutool"
    contact::String = ""
    summarizers::Vector{Summarizer} = default_summarizers()
    summarizer::String = "deepseek-v4.1-flash"
    code_summarizer::String = "deepseek-v4.1-flash"
    record_summarizer::String = ""
    judge::String = "opus-agent-pdf"
    # Who does the other agent work, each by default the summarizer: the tutor (and how hard it
    # thinks), the notebook agent, and the analyst who writes about the paper of the day.
    tutor::String = ""
    tutor_effort::String = "medium"
    notebooker::String = ""
    analyst::String = ""
    group::Group = Group()
    layers::Vector{Layer} = default_layers(summarizer; field = group.field)
    rank_weights::Dict{String,Float64} = Dict{String,Float64}()
    rrf_k::Float64 = 60.0
    base_set::String = ""
    search_layers::Vector{String} = best_layers(layers)
    search_keyword::Bool = true
    landscape_layer::String = ""
    landscape_clusters::Int = 0
    watch_categories::Vector{String} = String[]
    watch_days::Int = 7
    watch_hours::Float64 = 24.0
    watch_judge::String = ""
    watch_read_from::Int = 2
    watch_record_from::Int = 1
    # The Slate hub the site's notebooks are rendered through, by its port: 0 for KaimonSlate's own
    # (see `slate_env`).
    slate_port::Int = 0
    # The largest file people and agents may attach to what they write (see media.jl), in MB.
    media_max_mb::Int = 200
    # A private copy of every attached file (`[media.backup]`, see media.jl).
    media_backup::StoreConfig = StoreConfig()
    backup::BackupConfig = BackupConfig()
    dataset::DatasetConfig = DatasetConfig()
    shared::SharedConfig = SharedConfig()
    service::ServiceConfig = ServiceConfig()
    sources::Dict{String,Any} = Dict{String,Any}()
    plugins::PluginConfig = PluginConfig()
end

"The layers built on the strongest embedding model, the default for searching; every layer but the trial ones when none are."
function best_layers(layers)
    kept = filter(l -> !l.trial, layers)
    best = [l.name for l in kept if l.model == "qwen3-embedding:4b"]
    return isempty(best) ? [l.name for l in kept] : best
end

group_brief(c::Config) = group_brief(c.group)
in_field(c::Config; kw...) = in_field(c.group; kw...)

"The layers ingesting and syncing keep up to date: all but the trial ones."
ingest_layers(c::Config) = filter(l -> !l.trial, c.layers)

"The layers that embed a paper by its title and abstract, which its record has before it is read."
record_layers(c::Config) = [l for l in ingest_layers(c) if l.unit == :paper && isempty(l.source)]

"The layer the landscape places papers by: the config's `landscape_layer`, or the first searched record layer."
function landscape_layer(c::Config)
    isempty(c.landscape_layer) || return layer(c, c.landscape_layer)
    candidates = record_layers(c)
    isempty(candidates) && error("No layer embeds papers by their title and abstract, so there is no landscape")
    i = findfirst(l -> l.name in c.search_layers, candidates)
    return candidates[something(i, 1)]
end

xdg_home(var, fallback) = get(ENV, var, joinpath(homedir(), fallback))

"The config file: `ZEMI_CONFIG` names one (a shared service's, say), else `~/.config/zemi/config.toml`."
config_path() = get(ENV, "ZEMI_CONFIG", joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "zemi", "config.toml"))

db_path(c::Config) = joinpath(c.data_dir, "kb.sqlite3")

"""
    content_path(config, parts...) -> String

A path in the content the knowledge base's people write (`content_dir`): `pages/` (Markdown pages of
the site, `index.md` its front page), `studies/<name>/` (see study.jl), `notebooks/` (Slate notebooks,
those made from a paper under `papers/<paper>/`, a day's under `daily/`) and `assets/` (the site's
logo and icons, in place of the package's).
"""
content_path(c::Config, parts::AbstractString...) = joinpath(c.content_dir, parts...)

"A file touched whenever a background job has changed the knowledge base, for a site preview to rebuild on."
changes_stamp(c::Config) = joinpath(c.data_dir, "changed")
"A file touched to have the site built anew: its title, front page or questions changed with the settings."
build_stamp(c::Config) = joinpath(c.data_dir, "rebuild")
pdf_dir(c::Config) = joinpath(c.data_dir, "pdfs")
"Where the knowledge base's snapshots go (see [`BackupConfig`](@ref)): `[backup] dir`, or the data folder's path with `.backups` added."
backup_dir(c::Config) = isempty(c.backup.dir) ? rstrip(normpath(abspath(c.data_dir)), ['/', '\\']) * ".backups" : c.backup.dir
"Whether `path` is `dir` or in it."
within_dir(path::AbstractString, dir::AbstractString) =
    (p = rstrip(normpath(abspath(path)), ['/', '\\']); d = rstrip(normpath(abspath(dir)), ['/', '\\']); p == d || startswith(p, d * Base.Filesystem.path_separator))

"""
    settings_path(path = config_path()) -> String

The settings changed from the site, beside the config file and named after it
(`config.settings.toml`): written by the service, they override the config file key by key, which
is itself never rewritten.
"""
settings_path(path::AbstractString = config_path()) = joinpath(dirname(path), splitext(basename(path))[1] * ".settings.toml")

"`base` with `over`'s settings in place of its own: tables merged key by key, anything else replaced."
function merge_settings(base::AbstractDict, over::AbstractDict)
    out = Dict{String,Any}(base)
    for (k, v) in over
        out[k] = v isa AbstractDict && get(out, k, nothing) isa AbstractDict ? merge_settings(out[k], v) : v
    end
    return out
end

"""
    purpose(c, which) -> Summarizer

Who does `which` agent work (`:tutor`, `:notebooker`, `:analyst`): the one configured for it, else
the summarizer.
"""
function purpose(c::Config, which::Symbol)
    name = getfield(c, which)
    return summarizer(c, isempty(name) ? c.summarizer : name)
end

"""
    load_config(path = config_path()) -> Config

Read the TOML config file, falling back to defaults for anything it doesn't set. Layers given as
`[[layers]]` tables replace the default layer list.
"""
function load_config(path::AbstractString = config_path())
    d = Config()
    isfile(path) || isfile(settings_path(path)) || return d
    t = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    isfile(settings_path(path)) && (t = merge_settings(t, TOML.parsefile(settings_path(path))))
    # Summarizers in the file add to the defaults, replacing any of the same name.
    extra = map(get(t, "summarizers", [])) do s
        Summarizer(; name = s["name"], model = s["model"], kind = Symbol(get(s, "kind", "api")), url = get(s, "url", ""),
            key = get(s, "key", ""), request = Dict{String,Any}(get(s, "request", Dict("temperature" => 0.2))),
            max_input_chars = get(s, "max_input_chars", 24000), reads = Symbol(get(s, "reads", "pdf")),
            timeout = Float64(get(s, "timeout", 1800.0)),
            price_in = Float64(get(s, "price_in", 0.0)), price_out = Float64(get(s, "price_out", 0.0)))
    end
    summarizers = [filter(s -> !any(e -> e.name == s.name, extra), d.summarizers); extra]
    summarizer = get(t, "summarizer", d.summarizer)
    group = group_config(get(t, "group", Dict()))
    layers = haskey(t, "layers") ? map(t["layers"]) do l
        source = get(l, "source", "")
        Layer(; name = l["name"], model = l["model"], unit = Symbol(l["unit"]),
            query_prefix = get(l, "query_prefix", ""), doc_prefix = get(l, "doc_prefix", ""),
            max_chars = get(l, "max_chars", 8000), source = source == "default" ? summarizer : source,
            trial = get(l, "trial", false), url = get(l, "url", ""), key = get(l, "key", ""))
    end : default_layers(summarizer; field = group.field)
    ranking = get(t, "ranking", Dict())
    # Folders and files named relative to the config file are its folder's.
    here(p) = abspath(joinpath(dirname(abspath(path)), expanduser(p)))
    data_dir = here(get(t, "data_dir", d.data_dir))
    c = Config(;
        data_dir, content_dir = here(get(t, "content_dir", joinpath(data_dir, "content"))),
        ollama_url = get(t, "ollama_url", d.ollama_url), ollama_keep_alive = string(get(t, "ollama_keep_alive", d.ollama_keep_alive)),
        qdrant_url = get(t, "qdrant_url", d.qdrant_url), qdrant_key = get(t, "qdrant_key", d.qdrant_key),
        collection_prefix = get(t, "collection_prefix", d.collection_prefix),
        mutool = get(t, "mutool", d.mutool),
        contact = get(t, "contact", d.contact),
        summarizers, summarizer,
        code_summarizer = get(t, "code_summarizer", d.code_summarizer),
        record_summarizer = get(t, "record_summarizer", d.record_summarizer),
        judge = get(t, "judge", d.judge),
        tutor = get(t, "tutor", d.tutor), tutor_effort = get(t, "tutor_effort", d.tutor_effort),
        notebooker = get(t, "notebooker", d.notebooker), analyst = get(t, "analyst", d.analyst),
        group, layers,
        rank_weights = Dict{String,Float64}(k => Float64(v) for (k, v) in get(ranking, "weights", Dict())),
        rrf_k = Float64(get(ranking, "k", d.rrf_k)),
        base_set = (b = get(t, "base_set", d.base_set); isempty(b) ? b : here(b)),
        search_layers = String.(get(get(t, "search", Dict()), "layers", best_layers(layers))),
        search_keyword = Bool(get(get(t, "search", Dict()), "keyword", true)),
        landscape_layer = get(get(t, "landscape", Dict()), "layer", ""),
        landscape_clusters = get(get(t, "landscape", Dict()), "clusters", 0),
        watch_categories = String.(get(get(t, "watch", Dict()), "categories", d.watch_categories)),
        watch_days = Int(get(get(t, "watch", Dict()), "days", d.watch_days)),
        watch_hours = Float64(get(get(t, "watch", Dict()), "hours", d.watch_hours)),
        watch_judge = String(get(get(t, "watch", Dict()), "judge", d.watch_judge)),
        watch_read_from = Int(get(get(t, "watch", Dict()), "read_from", d.watch_read_from)),
        watch_record_from = Int(get(get(t, "watch", Dict()), "record_from", d.watch_record_from)),
        slate_port = Int(get(get(t, "notebooks", Dict()), "slate_port", d.slate_port)),
        media_max_mb = Int(get(get(t, "media", Dict()), "max_mb", d.media_max_mb)),
        media_backup = store_config(get(get(t, "media", Dict()), "backup", Dict()); path = here),
        backup = backup_config(get(t, "backup", Dict()); path = here),
        dataset = dataset_config(get(t, "dataset", Dict()); path = here),
        shared = shared_config(get(t, "shared", Dict()); path = here),
        service = service_config(get(t, "service", Dict())),
        sources = Dict{String,Any}(String(k) => v for (k, v) in get(t, "sources", Dict()) if v isa AbstractDict),
        plugins = (p = get(t, "plugins", Dict());
                   PluginConfig(; env = (e = get(p, "env", ""); isempty(e) ? e : here(e)), load = String.(get(p, "load", String[])))))
    return c.dataset.role == :none ? c : follow_profile(c)
end

function dataset_config(t::AbstractDict; path = expanduser)
    d = DatasetConfig()
    file(k) = (f = get(t, k, getfield(d, Symbol(k))); isempty(f) ? f : path(f))
    return DatasetConfig(; role = Symbol(get(t, "role", "none")), stream = get(t, "stream", d.stream),
        content = Bool(get(t, "content", d.content)), store = store_path(get(t, "store", d.store), path),
        endpoint = get(t, "endpoint", d.endpoint), bucket = get(t, "bucket", d.bucket), prefix = get(t, "prefix", d.prefix),
        region = get(t, "region", d.region), credentials = file("credentials"),
        autosync_hours = Float64(get(t, "autosync_hours", d.autosync_hours)), read_unread = Bool(get(t, "read_unread", d.read_unread)),
        check_hours = Float64(get(t, "check_hours", d.check_hours)),
        admin_credentials = file("admin_credentials"))
end

"""
    write_private(path, text)

Write a secret to `path`, readable only by its owner from the moment it exists, its folder made if
need be.
"""
function write_private(path::AbstractString, text::AbstractString)
    mkpath(dirname(path))
    rm(path; force = true)
    touch(path)
    chmod(path, 0o600)
    write(path, text)
    return path
end

"A copy of the config with some fields changed."
with_config(c::Config; kw...) = Config(; (f => getfield(c, f) for f in fieldnames(Config))..., kw...)

"Where a member of a dataset keeps the dataset's profile, as last read (see dataset.jl)."
profile_cache(c::Config) = joinpath(c.data_dir, "dataset-profile.json")

"""
    follow_profile(config) -> Config

A dataset member's config with the layers and summarizer names of the dataset's profile, as last
read, so what it reads and searches is made with the models every stream's documents are made with;
its trial layers are kept.
"""
function follow_profile(c::Config)
    path = profile_cache(c)
    isfile(path) || return c
    m = JSON.parsefile(path)
    # Where this machine reaches a layer's model (its `url` and `key`) is its own.
    mine = Dict(l.name => l for l in c.layers)
    layers = map(m["layers"]) do d
        l = manifest_layer(d)
        here = get(mine, l.name, nothing)
        here === nothing || here.model != l.model ? l :
            Layer(; (f => getfield(l, f) for f in fieldnames(Layer) if !(f in (:url, :key)))..., here.url, here.key)
    end
    known = Set(s.name for s in c.summarizers)
    extra = [Summarizer(; name = s["name"], kind = Symbol(s["kind"]), model = s["model"], url = get(s, "url", ""),
                        reads = Symbol(get(s, "reads", "pdf"))) for s in m["summarizers"] if !(s["name"] in known)]
    all_layers = [layers; filter(l -> l.trial && !any(x -> x.name == l.name, layers), c.layers)]
    names = Set(l.name for l in all_layers)
    search = all(in(names), c.search_layers) && !isempty(c.search_layers) ? c.search_layers : best_layers(all_layers)
    return with_config(c; layers = all_layers, summarizers = [c.summarizers; extra], summarizer = m["summarizer"],
                       code_summarizer = m["code_summarizer"], search_layers = search)
end

manifest_layer(l) = Layer(; name = l["name"], model = l["model"], unit = Symbol(l["unit"]), query_prefix = l["query_prefix"],
                          doc_prefix = l["doc_prefix"], max_chars = l["max_chars"], source = l["source"])

function validate(c::Config)
    names = [l.name for l in c.layers]
    allunique(names) || error("Layer names must be unique: $names")
    for n in c.search_layers
        n in names || error("[search] layers: no layer named $n (the layers are $(join(names, ", ")))")
    end
    for l in c.layers
        l.unit in UNITS || error("Layer $(l.name): unit must be one of $UNITS, got :$(l.unit)")
        isempty(l.source) && continue
        l.unit == :chunk && error("Layer $(l.name): summaries exist for sections and papers, not chunks")
        any(s -> s.name == l.source, c.summarizers) || error("Layer $(l.name): no summarizer named $(l.source)")
    end
    for (role, name) in ("summarizer" => c.summarizer, "code_summarizer" => c.code_summarizer,
                         "record_summarizer" => kind_summarizer(c, RECORD), "judge" => c.judge,
                         "tutor" => purpose(c, :tutor).name, "notebooker" => purpose(c, :notebooker).name,
                         "analyst" => purpose(c, :analyst).name)
        i = findfirst(s -> s.name == name, c.summarizers)
        i === nothing && error("$role: no summarizer named $name")
    end
    b = c.backup
    b.every_hours > 0 || error("[backup] every_hours must be more than 0, got $(b.every_hours)")
    for (k, v) in ("keep_all_hours" => b.keep_all_hours, "keep_half_daily_days" => b.keep_half_daily_days,
                   "keep_daily_days" => b.keep_daily_days, "min_free_gb" => b.min_free_gb, "max_gb" => b.max_gb)
        v >= 0 || error("[backup] $k can't be negative, got $v")
    end
    within_dir(backup_dir(c), c.data_dir) && error("[backup] dir $(backup_dir(c)) is in the data folder, so losing the data would lose the backups")
    sh = c.shared
    sh.sign_up in (:invite, :open) || error("[shared] sign_up must be \"invite\" or \"open\", got \"$(sh.sign_up)\"")
    sh.kaimon in (:embedded, :external) || error("[shared] kaimon must be \"embedded\" or \"external\", got \"$(sh.kaimon)\"")
    allunique(p.name for p in sh.providers) || error("[shared] provider names must be unique")
    nightly_time(sh); time_zone(sh)
    for p in sh.providers
        p.kind in (:oidc, :github) || error("[shared] provider $(p.name): kind must be oidc or github, got $(p.kind)")
        p.kind == :oidc && isempty(p.issuer) && error("[shared] provider $(p.name): an oidc provider needs an issuer")
        isempty(p.client_id) && error("[shared] provider $(p.name): no client_id")
    end
    for s in c.summarizers
        s.kind in (:api, :agent) || error("Summarizer $(s.name): kind must be api or agent, got $(s.kind)")
        s.kind == :api && isempty(s.url) && error("Summarizer $(s.name): an api summarizer needs a url")
        s.kind == :agent && !(s.reads in (:pdf, :text)) && error("Summarizer $(s.name): reads must be pdf or text")
    end
    return c
end

"""
    summarizer_for(config, layer, doc_id) -> Summarizer
    summarizer_for(config, layer, kind) -> Summarizer

The summarizer whose summaries a summary layer embeds for this document (or for any of its
[`DocumentKind`](@ref)): the layer's own, except that where the layer uses the configured
`summarizer`, the one the kind names (`code_summarizer` for a codebase, see [`kind_summarizer`](@ref)).
"""
summarizer_for(c::Config, l::Layer, doc_id::AbstractString) = summarizer_for(c, l, something(document_kind(doc_id), PAPER))
summarizer_for(c::Config, l::Layer, k::DocumentKind) =
    summarizer(c, l.source == c.summarizer ? kind_summarizer(c, k) : l.source)

function layer(c::Config, name::AbstractString)
    i = findfirst(l -> l.name == name, c.layers)
    i === nothing && error("No layer named \"$name\". Layers: $(join((l.name for l in c.layers), ", "))")
    return c.layers[i]
end

function summarizer(c::Config, name::AbstractString)
    i = findfirst(s -> s.name == name, c.summarizers)
    i === nothing && error("No summarizer named \"$name\". Summarizers: $(join((s.name for s in c.summarizers), ", "))")
    return c.summarizers[i]
end
