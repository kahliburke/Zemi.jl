# A small HTTP JSON API over the knowledge base, for the docs site's components in their live mode.
# The site and the API are served from one origin (under `zemi dev` too, through the development
# server's proxy), so no other site is invited to read the answers (there are no CORS headers), and a
# request naming another host is refused (see `local_host`). Writes (adding, reindexing, removing
# documents) are accepted only from pages served on this machine and only with an `X-Zemi` header,
# which a plain form post cannot send, so another web page open in the browser cannot change the
# knowledge base. Each endpoint is a route (see routes.jl), declared below with what it answers.

"""
Who added something through the site: in the shared service the person signed in; otherwise the
name given with it, else whoever runs the knowledge base.
"""
function adder(by, caller::Caller = local_caller())
    caller.via == :local || return caller_name(caller)
    name = strip(string(something(by, "")))
    return isempty(name) ? local_user() : String(name)
end

"""
Whether `caller` may see conversation `chat`: their own, in the shared service; any, run for one person.
"""
chat_access(kb::KB, caller::Caller, chat::AbstractString) = caller.via == :local || chat_owner(kb, chat) == caller.user_id

"Who the caller is and what they may do, for the site to show what they can use."
function me_json(kb::KB, c::Caller)
    Dict("name" => caller_name(c), "id" => person_id(c), "email" => c.email, "via" => string(c.via), "permissions" => sort!(collect(c.permissions)),
         "quotas" => Dict(k => quota_left(kb, c, k) for k in ("tutor", "notebook")),
         # An admin viewing as this person: the admin, to go back to.
         "admin" => c.admin === nothing ? nothing : coalesce(scalar(kb, "SELECT email FROM users WHERE id = ?", (c.admin,)), ""))
end

# What of a change is kept in the audit log: what it was done to, never what someone wrote (a
# message to the tutor, a tutoring profile).
const AUDITED_FIELDS = ("paper", "id", "ids", "action", "anyway", "arxiv", "day", "source", "chat", "another", "again", "unread",
                        "project", "status", "key",
                        "email", "roles", "disabled", "who", "write", "revoke", "delete", "permissions", "quotas", "changes", "days")

const LOCAL_ORIGIN = r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$"

"""
Whether a request to the knowledge base run for one person names this machine as its host: one that
names another (a site rebinding its own name to 127.0.0.1) is refused, as another site's page.
"""
local_host(req::HTTP.Request) = (h = HTTP.header(req, "Host", ""); isempty(h) || occursin(r"^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$", h))

"Whether a request may change the knowledge base: from a page on this machine, with the API's header."
function write_allowed(req::HTTP.Request)
    origin = HTTP.header(req, "Origin", "")
    return (isempty(origin) || occursin(LOCAL_ORIGIN, origin)) && HTTP.header(req, "X-Zemi", "") == "1"
end

"""
A file the tutor made, as served to the drawer. Pages and SVG run sandboxed, in an origin of their
own, so their scripts cannot reach this API (whose writes need a local origin; see `write_allowed`).
"""
function chat_file_response(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    type = get(Dict(".svg" => "image/svg+xml", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
                    ".gif" => "image/gif", ".html" => "text/html; charset=utf-8", ".json" => "application/json"),
               ext, "text/plain; charset=utf-8")
    headers = ["Content-Type" => type, "X-Content-Type-Options" => "nosniff"]
    ext in (".html", ".svg") && push!(headers, "Content-Security-Policy" => "sandbox allow-scripts")
    return HTTP.Response(200, headers, read(path))
end

evidence_json(c::Config, es) = [Dict("ranking" => e.ranking, "ranking_label" => ranking_label(c, e.ranking),
    "rank" => e.rank, "matched" => e.label, "contribution" => e.contribution) for e in es]

# Where a hit and its passages are on the site, relative to the knowledge base's pages: its kind's
# page (see `DocumentKind`), and each passage on its section's page for a kind whose sections have them;
# and what a reader is told of where it came from (a record's label and date).
function hit_json(kb::KB, h::PaperHit)
    c = kb.config
    kind = something(document_kind(h.doc_id), PAPER)
    slug = page_slug(h.doc_id)
    r = record_row(kb, h.doc_id)
    Dict("id" => h.doc_id, "slug" => slug, "kind" => kind.name, "note" => document_note(kb, h.doc_id),
         "record" => r === nothing ? nothing : Dict("label" => r.label, "day" => record_day(r.happened), "source" => r.source),
         "page" => kind.page(slug), "title" => h.title, "authors" => first(h.authors, 6),
         "published" => h.published, "category" => h.category, "score" => h.score, "max_score" => h.max_score,
         "evidence" => evidence_json(c, h.evidence),
         "passages" => [Dict("section" => p.section, "page_start" => p.page_start, "page_end" => p.page_end,
                             "page" => kind.section_page === nothing ? nothing : kind.section_page(slug, p.section),
                             "text" => p.text, "score" => p.score, "evidence" => evidence_json(c, p.evidence))
                        for p in h.passages])
end

function status_json(kb::KB)
    n(sql) = scalar(kb, sql)
    counts = Dict(r.layer => (; r.n, r.papers) for r in query(kb,
        "SELECT layer, count(*) AS n, count(DISTINCT paper_id) AS papers FROM embeddings GROUP BY layer"))
    dims = Dict(r.name => r.dim for r in query(kb, "SELECT name, dim FROM layers"))
    Dict("papers" => n("SELECT count(*) FROM papers"), "processed" => n("SELECT count(*) FROM parses"),
         "passages" => n("SELECT count(*) FROM chunks"),
         "keyword" => Dict("default" => kb.config.search_keyword,
                           "description" => ranking_description(kb.config, "keyword")),
         "layers" => [Dict("name" => l.name, "label" => ranking_label(kb.config, l.name),
                           "description" => ranking_description(kb.config, l.name),
                           "model" => model_name(l.model), "unit" => string(l.unit), "source" => l.source,
                           "dim" => get(dims, l.name, nothing),
                           "vectors" => get(counts, l.name, (; n = 0)).n,
                           "papers" => get(counts, l.name, (; papers = 0)).papers,
                           "default" => l.name in kb.config.search_layers, "trial" => l.trial)
                      for l in kb.config.layers if !l.trial || haskey(counts, l.name)],
         # The Manage actions this machine cannot run, with why, for each kind of document.
         "cannot" => Dict(a => Dict(k.name => cannot_run(kb, a, k; fresh = false) for k in DOCUMENT_KINDS)
                          for a in keys(ACTIONS)))
end

"Which of `ids` are read already, so adding them again adds nothing."
already_read(kb::KB, ids) = [id for id in ids if !ismissing(scalar(kb,
    "SELECT 1 FROM parses x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)))]

"""
The action names `POST /api/actions` takes, with what each runs on its documents. Each is given who
asked (`by`) and why (`why`), which dropping keeps.
"""
const ACTIONS = Dict(
    "ingest" => (kb, ids, job; _...) -> ingest!(kb, ids; progress = m -> report!(job, m), cancelled = () -> cancelled(job)),
    "reindex" => (kb, ids, job; _...) -> reindex!(kb, ids; progress = m -> report!(job, m), cancelled = () -> cancelled(job)),
    "resummarize" => (kb, ids, job; _...) -> resummarize!(kb, ids; progress = m -> report!(job, m), cancelled = () -> cancelled(job)),
    "classify" => (kb, ids, job; _...) -> join([begin
            report!(job, "[$i/$(length(ids))] classifying $id")
            "$id\n" * format_classification(classify!(kb, id))
        end for (i, id) in enumerate(ids) if !cancelled(job)], "\n\n"),
    "refresh" => function (kb, ids, job; _...)
        uploads = filter(is_upload, ids)
        for (i, id) in enumerate(uploads)
            report!(job, "[$i/$(length(uploads))] reading $id's title again")
            reread_upload!(kb, id)
        end
        papers = filter(is_arxiv_id, ids)
        isempty(papers) && return length(uploads)
        report!(job, "fetching arXiv metadata")
        return refresh_metadata!(kb, papers; force = true) + length(uploads)
    end,
    "share" => (kb, ids, job; _...) -> set_shared!(kb, ids, true),
    "unshare" => (kb, ids, job; _...) -> set_shared!(kb, ids, false),
    "drop" => (kb, ids, job; by = nothing, why = "") -> [begin
            report!(job, "dropping $id")
            drop!(kb, id; by = something(by, "someone"), why)
            id
        end for id in ids])

function start_action(kb::KB, action::AbstractString, ids::Vector{String}; by = nothing, why::AbstractString = "")
    haskey(ACTIONS, action) || error("No action \"$action\"; the actions are $(join(sort!(collect(keys(ACTIONS))), ", "))")
    isempty(ids) && error("No documents.")
    for id in ids
        ismissing(paper_id(kb, id)) && not_found("No document $id")
    end
    blocked = cannot_run(kb, action, ids)
    isempty(blocked) || error("Can't $action here: ", join(blocked, "; "))
    label = length(ids) == 1 ? "$action $(only(ids))" : "$action $(length(ids)) documents"
    return start_job(job -> ACTIONS[action](kb, ids, job; by, why), label; ids, changes = changes_stamp(kb.config))
end

"""
    start_record(kb, ids) -> Job

Fetch the arXiv records of papers just recorded and embed their titles and abstracts, as a job: they
are then found by search and placed in the landscape, without being read.
"""
function start_record(kb::KB, ids::Vector{String})
    return start_job("record $(length(ids)) paper(s)"; ids, changes = changes_stamp(kb.config)) do job
        report!(job, "fetching arXiv records")
        fetched = refresh_metadata!(kb, ids)
        blocked = cannot_run(kb, "embed", ids)
        isempty(blocked) || return "Recorded $(length(ids)) paper(s), $fetched record(s) fetched; not embedded: $(join(blocked, "; "))"
        embedded = embed_records!(kb, ids; progress = m -> report!(job, m), cancelled = () -> cancelled(job))
        "Recorded $(length(ids)) paper(s): $fetched arXiv record(s) fetched, $embedded abstract(s) embedded."
    end
end

"""
Paper `id`, for `caller` to have the tutor or an agent work from, which adds it when the knowledge
base does not have it: refused then unless they may add papers (`paper.add`), and refused as none
when it is a document they may not see (see [`document_visible`](@ref)).
"""
function addable_paper(kb::KB, caller::Caller, id::AbstractString)
    ismissing(paper_id(kb, id)) && !can(caller, "paper.add") &&
        not_permitted("Not permitted: $id is not in the knowledge base, and adding a paper needs paper.add")
    return seen_document(kb, caller, id)
end

# ── The routes ────────────────────────────────────────────────────────────────────────────────────

"""
`?k=` as an integer within `range`, else `default`.
"""
int_param(params, k, default::Integer, range = typemin(Int):typemax(Int)) =
    clamp(something(tryparse(Int, get(params, k, "")), default), first(range), last(range))

# Papers, layers and whether the services are up, with the caller, the site's build served and how
# long a new one has been building (seconds), for the top bar to offer a reload when it changes.
route!("GET", "/api/status") do c
    building = lock(() -> SITE.building && SITE.started !== nothing ? round(Int, Dates.value(now() - SITE.started) / 1000) : nothing, SITE_LOCK)
    merge(status_json(c.kb), Dict("me" => me_json(c.kb, c.caller), "build" => SITE.id, "building" => building))
end

# Hybrid search: papers with their best passages, and the findings of the projects the caller sees.
# `?layers=a,b`, `all` or `none` and `?keyword=0|1` default to the config's; `?kinds=paper,code,record`
# finds only those.
route!("GET", "/api/search") do c
    kb, params = c.kb, c.params
    q = strip(get(params, "q", ""))
    isempty(q) && error("No query.")
    limit = int_param(params, "limit", 10, 1:50)
    layers = let l = get(params, "layers", "")
        isempty(l) ? kb.config.search_layers : l == "all" ? nothing : l == "none" ? String[] : split_list(l)
    end
    keyword = get(params, "keyword", kb.config.search_keyword ? "1" : "0") in ("1", "true")
    kinds = let k = get(params, "kinds", "")
        isempty(k) ? nothing : split_list(k)
    end
    t = @elapsed hits = search(kb, q; limit, layers, keyword, kinds, except = hidden_documents(kb, c.caller))
    found = can(c.caller, "tasks.view") ? search_findings(kb, q; projects = visible_projects(kb, c.caller), limit = 5) : NamedTuple[]
    Dict("query" => q, "seconds" => t, "k" => kb.config.rrf_k, "hits" => [hit_json(kb, h) for h in hits],
         "findings" => Any[Dict(pairs(f)) for f in found])
end

# One paper, as on its page.
route!("GET", "/api/paper/*paper") do c
    sp = site_paper(c.kb, seen_document(c.kb, c.caller, normalize_id(c[:paper])))
    Dict("id" => sp.doc_id, "title" => sp.title, "authors" => sp.authors, "published" => sp.published, "category" => sp.category,
         "abstract" => sp.abstract, "summary" => sp.summary, "topics" => sp.topics, "sections" => sp.sections, "related" => sp.related)
end

"Paper `id`, refused as none unless the knowledge base has it."
known_paper(kb::KB, id::AbstractString) = (ismissing(paper_id(kb, id)) && not_found("No paper $id."); id)

# A section's text (`?id=…&section=…`).
route!("GET", "/api/paper-text") do c
    id = known_paper(c.kb, seen_document(c.kb, c.caller, normalize_id(get(c.params, "id", ""))))
    section_text_json(c.kb, id, int_param(c.params, "section", -1))
end

# Its PDF, for the browser's own viewer: an arXiv paper's fetched and kept when not here.
route!("GET", "/api/pdf/*paper") do c
    id = known_paper(c.kb, normalize_id(c[:paper]))
    r = file_response(paper_pdf(c.kb, id); c.req)
    HTTP.setheader(r, "Content-Disposition" => "inline; filename=\"$(page_slug(id)).pdf\"")
    r
end

# The papers nearest by their paper-level vectors.
route!(c -> related_papers(c.kb, seen_document(c.kb, c.caller, normalize_id(c[:paper])); limit = int_param(c.params, "limit", 8, 1:50),
                           except = hidden_documents(c.kb, c.caller)), "GET", "/api/similar/*paper")

# A paper's figures and tables (`?id=…`), and one of them, cut when it was read: sent as it is looked
# at, never built into the site. A document added here is named by its id (its slug), and its figures
# are sent only to those who may see it (a record's).
route!(c -> figures_json(c.kb, seen_document(c.kb, c.caller, normalize_id(get(c.params, "id", "")))), "GET", "/api/figures")
route!("GET", "/api/figures/:paper/:file") do c
    local_kind(c[:paper]) === nothing || seen_document(c.kb, c.caller, c[:paper])
    f = figure_file(c.kb, c[:paper], c[:file]; theme = get(c.params, "theme", ""))
    isfile(f) ? file_response(f; c.req) : not_found("No such figure.")
end

# Documents, for managing them (`?q=…&state=…&limit=…&offset=…`).
route!("GET", "/api/documents"; need = "paper.manage") do c
    list_documents(c.kb; q = get(c.params, "q", ""), state = get(c.params, "state", ""),
                   limit = int_param(c.params, "limit", 50, 1:500), offset = int_param(c.params, "offset", 0, 0:typemax(Int)))
end

# Add a document and start reading it: a PDF as the body (`?name=…&title=…&by=…`), or JSON with
# `arxiv` (ids or URLs) or `codebase` (a repository or folder). With `"read": false` papers are only
# recorded, to be read in full later; `source` is how they came (see ARRIVALS), `by` who added them.
# A resource's PDF, uploaded to read it in full (see `promote_resource!`): the paper it becomes, being read.
route!("POST", "/api/resources/:id/pdf"; need = "paper.add") do c
    kb = c.kb
    blocked = cannot_run(kb, "ingest", PAPER)
    isempty(blocked) || error("Can't read documents here: ", join(blocked, "; "))
    path = tempname() * ".pdf"
    write(path, body_bytes(c))
    id = try
        promote_resource!(kb, c[:id], path; by = adder(nothing, c.caller))
    finally
        rm(path; force = true)
    end
    Dict("id" => id, "page" => document_page(id), "job" => start_action(kb, "ingest", [id]).id)
end

route!("POST", "/api/documents"; need = "paper.add") do c
    kb, caller = c.kb, c.caller
    # Documents are added to be read, so nothing is added where they cannot be.
    blocked = cannot_run(kb, "ingest", PAPER)
    isempty(blocked) || error("Can't read documents here: ", join(blocked, "; "))
    if occursin("pdf", lowercase(HTTP.header(c.req, "Content-Type", "")))
        path = tempname() * ".pdf"
        write(path, body_bytes(c))
        title = get(c.params, "title", "")
        id = try
            add_pdf!(kb, path; title = isempty(title) ? nothing : title, added_by = adder(get(c.params, "by", nothing), caller),
                     anyway = get(c.params, "anyway", "") == "true")
        finally
            rm(path; force = true)
        end
        return Dict("ids" => [id], "already" => already_read(kb, [id]), "job" => start_action(kb, "ingest", [id]).id)
    end
    b = json_body(c)
    # A document dropped here is added only `anyway`, which restores it.
    anyway = get(b, "anyway", false) === true
    if !isempty(strip(String(get(b, "codebase", ""))))
        id = add_codebase_from!(kb, String(b["codebase"]); by = adder(get(b, "by", nothing), caller), anyway)
        job = start_job("ingest $id"; ids = [id], changes = changes_stamp(kb.config)) do job
            # One read from a clone of its repository is fetched first.
            if codebase_dir(kb, id) == clone_dir(kb.config, id)
                report!(job, "fetching $id from its repository")
                fetch_codebase!(kb, id) || error("$id cannot be fetched: $(codebase_problem(kb, id))")
            end
            format_ingest(ingest!(kb, [id]; progress = m -> report!(job, m), cancelled = () -> cancelled(job)))
        end
        return Dict("ids" => [id], "already" => already_read(kb, [id]), "job" => job.id)
    end
    ids = add_papers!(kb, split_list(String(get(b, "arxiv", ""))); source = String(get(b, "source", "added")),
                      by = adder(get(b, "by", nothing), caller), anyway)
    get(b, "read", true) === false && return Dict("ids" => ids, "job" => start_record(kb, ids).id)
    Dict("ids" => ids, "already" => already_read(kb, ids), "job" => start_action(kb, "ingest", ids).id)
end

# `{"action": …, "ids": […]}`: one of ACTIONS on documents, as a job.
route!("POST", "/api/actions"; need = "paper.manage") do c
    b = json_body(c)
    Dict("job" => start_action(c.kb, String(get(b, "action", "")), [normalize_id(String(x)) for x in get(b, "ids", [])];
                               by = adder(nothing, c.caller), why = String(get(b, "why", ""))).id)
end

# What was dropped and is kept out (see dropped.jl), latest first; restoring some (`{"ids": […]}`).
route!(c -> Dict("dropped" => [drop_json(d) for d in dropped_documents(c.kb)]), "GET", "/api/dropped"; need = "paper.manage")
route!("POST", "/api/dropped/restore"; need = "paper.manage") do c
    ids = [String(x) for x in get(json_body(c), "ids", [])]
    isempty(ids) && error("No documents.")
    foreach(id -> restore!(c.kb, id; by = adder(nothing, c.caller)), ids)
    Dict("restored" => ids)
end

# Background jobs and their progress: the list, and one (its starter's, see `job_visible`).
route!(c -> [job_json(j) for j in list_jobs()], "GET", "/api/jobs"; need = "jobs.view")
route!("GET", "/api/jobs/:id") do c
    j = get_job(c[:id])
    j === nothing || !job_visible(j, c.caller) ? not_found("No job $(c[:id])") : job_json(j)
end

# New arXiv papers in the watched categories, best placed first; checking arXiv now, as a job.
route!("GET", "/api/watch") do c
    kb = c.kb
    last = scalar(kb, "SELECT value FROM kv WHERE key = 'watch_checked_at'")
    Dict("checked" => coalesce(last, nothing), "categories" => kb.config.watch_categories, "days" => kb.config.watch_days,
         "papers" => watch_json(kb), "taken" => watch_taken_json(kb))
end
route!(c -> Dict("job" => start_watch(c.kb).id), "POST", "/api/watch/check"; need = "watch")

# The papers of the day, latest first.
route!("GET", "/api/daily") do c
    [Dict("day" => d.day, "id" => d.id, "title" => d.title, "status" => d.status, "error" => d.error,
          "computable" => get(d.computable, "tractable", false) === true, "notebook" => d.notebook_status) for d in dailies(c.kb)]
end

# A figure cut from a day's paper, at an address that stays: the site's copy is renamed with each build.
route!("GET", "/api/daily/:day/:file") do c
    occursin(r"^\d{4}-\d{2}-\d{2}$", c[:day]) && occursin(r"^[A-Za-z0-9._-]+\.(webp|png)$", c[:file]) || not_found("No such figure.")
    id = scalar(c.kb, "SELECT doc_id FROM daily WHERE day = ? ORDER BY picked_at DESC LIMIT 1", (c[:day],))
    f = ismissing(id) ? "" : joinpath(figures_dir(c.kb.config, id), c[:file])
    isfile(f) ? file_response(f; c.req) : not_found("No such figure.")
end

# Pick and analyse today's paper, as a job: `{"another": true}` for a new one, `{"again": true}` to
# analyse today's again.
route!("POST", "/api/daily"; need = "daily") do c
    b = json_body(c)
    Dict("job" => start_daily(c.kb; another = get(b, "another", false) === true, again = get(b, "again", false) === true,
                              day = string(get(b, "day", ""))).id)
end

# Make a notebook from a day's paper (`{"day": "yyyy-mm-dd"}`), as a job.
route!("POST", "/api/daily/notebook"; need = "notebook.create") do c
    day = String(get(json_body(c), "day", utc_today()))
    d = findfirst(r -> r.day == day, dailies(c.kb))
    d === nothing && not_found("No paper of the day for $day")
    spend!(c.kb, c.caller, "notebook")
    Dict("job" => start_notebook(c.kb, dailies(c.kb)[d].id).id)
end

# The conversations with the tutor about a paper: the caller's own, in the shared service (see `chat_access`).
route!("GET", "/api/chats/*paper"; need = "tutor") do c
    [Dict("id" => x.id, "title" => x.title, "updated_at" => x.updated_at, "messages" => x.messages)
     for x in chats(c.kb, normalize_id(c[:paper]); user = c.caller.via == :local ? nothing : c.caller.user_id)]
end

"Conversation `c[:chat]`, refused as none unless the caller may see it."
seen_chat(c::APICall) = (chat_access(c.kb, c.caller, c[:chat]) || not_found("Not found."); c[:chat])

# A conversation's messages, the tutor's latest as written so far.
route!("GET", "/api/chat/:chat"; need = "tutor") do c
    x = chat_messages(c.kb, seen_chat(c))
    Dict("id" => x.id, "paper" => x.paper, "title" => x.title, "doing" => x.doing, "notebook" => x.notebook,
         "messages" => [Dict("role" => m.role, "text" => m.text, "status" => m.status) for m in x.messages])
end

# A figure, page or file the tutor made in the conversation.
route!("GET", "/api/chat/:chat/files/:file"; need = "tutor") do c
    path = chat_file(c.kb, seen_chat(c), HTTP.unescapeuri(c[:file]))
    path === nothing ? not_found("Not found.") : chat_file_response(path)
end

# Ask the tutor about a paper: `{"paper": …, "message": …, "chat": … to go on, "profile": the
# student's tutoring profile}`. The profile comes from the student's browser with each message, and
# is not stored.
route!("POST", "/api/chat"; need = "tutor") do c
    b = json_body(c)
    chat = get(b, "chat", nothing)
    profile = first(String(something(get(b, "profile", nothing), "")), 4000)
    chat === nothing || chat_access(c.kb, c.caller, String(chat)) || not_found("Not found.")
    id = addable_paper(c.kb, c.caller, normalize_id(String(b["paper"])))
    spend!(c.kb, c.caller, "tutor")
    Dict("chat" => ask_chat!(c.kb, id, String(b["message"]); chat = chat === nothing ? nothing : String(chat),
                             profile, user = c.caller.user_id, c.caller))
end

# A paper's notebooks, with how each stands.
route!("GET", "/api/notebooks/*paper") do c
    [Dict("path" => n.path, "title" => n.title, "kind" => n.kind, "status" => n.status, "idea" => n.idea, "summary" => n.summary,
          "added_by" => n.added_by, "live" => get(NOTEBOOK_LIVE, n.path, nothing))
     for n in notebook_states(c.kb, normalize_id(c[:paper]))]
end

# Make a notebook from a paper (`{"id": …, "idea": "what to compute"}`), as a job.
route!("POST", "/api/notebook"; need = "notebook.create") do c
    b = json_body(c)
    id = addable_paper(c.kb, c.caller, normalize_id(String(b["id"])))
    spend!(c.kb, c.caller, "notebook")
    Dict("job" => start_notebook(c.kb, id; idea = String(get(b, "idea", ""))).id)
end

# Attach a notebook to a paper: its .jl source as the body (`?id=…&name=…&title=…&by=…`).
route!("POST", "/api/notebooks/upload"; need = "notebook.upload") do c
    p = c.params
    Dict("path" => add_notebook!(c.kb, normalize_id(get(p, "id", "")), String(body_bytes(c)); name = get(p, "name", "notebook.jl"),
                                 title = get(p, "title", ""), added_by = something(adder(get(p, "by", nothing), c.caller), "")))
end

# Works the papers cite and the knowledge base lacks; looking up on arXiv those cited only by DOI, as
# a job. The list takes the answers as they are stored, so the site is not rebuilt.
route!(c -> works_json(c.kb, missing_works(c.kb)), "GET", "/api/missing")
route!("POST", "/api/missing/find"; need = "paper.add") do c
    kb = c.kb
    job = start_job("find missing works on arXiv") do job
        report!(job, "gathering the works cited and missing")
        dois = [w.doi for w in missing_works(kb) if w.arxiv === nothing && w.doi !== nothing]
        n = find_on_arxiv!(kb, dois; progress = m -> report!(job, m))
        "Of $(length(dois)) works cited by DOI, $n newly found on arXiv."
    end
    Dict("job" => job.id)
end

# What a sync would do, the dataset's state, and the sync running; syncing and publishing, as jobs.
route!("GET", "/api/sync"; need = "sync") do c
    kb = c.kb
    plan = sync_plan(kb; unread = true)
    tasks = [Dict("id" => t.id, "title" => t.title, "action" => string(t.action), "reason" => t.reason,
                  "page" => document_page(t.id))
             for t in plan if t.reason != UNREAD]
    running = running_sync()
    kv(k) = (v = scalar(kb, "SELECT value FROM kv WHERE key = ?", (k,)); ismissing(v) ? nothing : v)
    dataset = Dict("role" => string(kb.config.dataset.role), "published_at" => kv("dataset_published_at"),
                   "stream" => kb.config.dataset.role == :publish ? stream_name(kb.config) : nothing,
                   "pulled" => kv("dataset_pulled"), "checked" => kv("dataset_checked"))
    Dict("tasks" => tasks, "unread" => count(t -> t.reason == UNREAD, plan), "dataset" => dataset,
         "job" => running === nothing ? nothing : running.id)
end
# The bibliography the caller may see, as BibTeX: `?keys=k1,k2` for only the documents cited by those
# keys (any not here are left out). Its ETag is its content's, so a client asks again cheaply.
route!("GET", "/api/bib") do c
    keys = isempty(get(c.params, "keys", "")) ? nothing : [String(strip(k)) for k in split(c.params["keys"], ',') if !isempty(strip(k))]
    text = bibliography(c.kb; caller = c.caller, keys)
    tag = "\"" * bytes2hex(sha256(text))[1:32] * "\""
    headers = ["Content-Type" => "text/plain; charset=utf-8", "ETag" => tag, "Cache-Control" => "private, no-cache"]
    tag in strip.(split(HTTP.header(c.req, "If-None-Match", ""), ',')) && return HTTP.Response(304, headers)
    return HTTP.Response(200, headers, text)
end

route!("POST", "/api/sync"; need = "sync") do c
    b = json_body(c)
    Dict("job" => start_sync(c.kb; unread = get(b, "unread", false) === true, resummarize = get(b, "resummarize", false) === true).id)
end
route!(c -> Dict("job" => start_publish(c.kb).id), "POST", "/api/publish"; need = "sync")

function job_json(j::Job)
    result = j.result === nothing ? nothing :
             j.result isa AbstractVector && !isempty(j.result) && first(j.result) isa NamedTuple && haskey(first(j.result), :ok) ?
                 format_ingest(j.result) : string(j.result)
    Dict("id" => j.id, "name" => j.name, "status" => string(j.status), "message" => j.message,
         "elapsed" => elapsed(j), "ids" => j.ids, "result" => result, "error" => j.error === nothing ? nothing : first(j.error, 1500))
end

"""
Apply changes to the package's code, and any migration they add to the open knowledge base, where
Revise is loaded (`zemi`, and `zemi --shared` unless `ZEMI_REVISE=0`), so the next request and
the jobs it starts run them. A change Revise cannot apply in place is reported once; it needs a
restart.
"""
function revise_code()
    isdefined(Main, :Revise) || return
    R = Main.Revise
    isempty(R.revision_queue) && return
    try
        # Revise runs its own code in the world it pinned when it loaded. Loaded after the packages it
        # tracks, as the zemi app loads it, its `revise` in that world leaves the queued changes
        # unapplied, so the pin is moved to the current world first.
        Base.invokelatest(R.advance_world!)
        Base.invokelatest(R.revise)
        # A change that adds a migration arrives with the code that needs it.
        Base.invokelatest(migrate_open!)
    catch e
        @warn "Revise could not apply a code change; restart to pick it up" exception = e maxlog = 1
    end
end

"""
    respond_local(kb, req) -> HTTP.Response

Answer a request to the knowledge base run for one person: from whoever runs it, with every
permission, and changes only from this machine's pages (see [`write_allowed`](@ref)).
"""
function respond_local(kb::KB, req::HTTP.Request)
    req.method == "POST" && !write_allowed(req) &&
        return json_response(Dict("error" => "Only from this machine's pages."); status = 403)
    return handle(kb, req, local_caller())
end

