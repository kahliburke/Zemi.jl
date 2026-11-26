# The browser and MCP both use the same publication operations and access checks.
route!("GET", "/api/publications") do c
    project = get(c.params, "project", "")
    access = isempty(project) ? NO_ACCESS : project_access(c.kb, c.caller, project)
    drafts = access < CONTRIBUTE ? [] : query(c.kb, """SELECT w.id, e.title, e.version FROM publications w
        JOIN projects p ON p.id = w.project_id JOIN publication_editions e ON e.work = w.id AND e.version > w.latest
        WHERE p.key = ? ORDER BY w.id DESC""", (uppercase(project),))
    (; works = publication_list(c.kb, c.caller; project), drafts, access = access_name(access))
end

route!("GET", "/api/publications/:id") do c
    editing = get(c.params, "draft", "") == "1"
    version = something(tryparse(Int, get(c.params, "version", "0")), -1)
    version >= 0 || error("Expected a version number")
    e = publication_edition(c.kb, c.caller, c[:id]; version, editing)
    access = project_access(c.kb, c.caller, e.project)
    has_draft = access >= CONTRIBUTE && !ismissing(scalar(c.kb,
        "SELECT 1 FROM publication_editions WHERE work = ? AND version > ?", (e.id, e.latest)))
    (; e..., access = access_name(access), has_draft)
end

route!("POST", "/api/projects/:key/publications"; need = "tasks.edit", project = CONTRIBUTE) do c
    d = json_body(c)
    draft_publication!(c.kb, c.caller, person_of(c), c[:key]; id = get(d, "id", 0),
        (Symbol(k) => String(get(d, k, "")) for k in
            ("revision", "title", "authors", "abstract", "body", "date", "source", "changes"))...)
end

route!("POST", "/api/publications/:id/publish"; need = "tasks.edit") do c
    d = json_body(c)
    publish_publication!(c.kb, c.caller, person_of(c), c[:id], get(d, "revision", ""); audience = get(d, "audience", "project"))
end

route!("GET", "/api/publications/:id/:version/pdf") do c
    version = something(tryparse(Int, c[:version]), 0)
    version > 0 || not_found("No such edition")
    e = publication_edition(c.kb, c.caller, c[:id]; version)
    ismissing(e.pdf_hash) && not_found("No PDF for this edition")
    media_response(c.kb, e.pdf_hash, "publication-$(e.id)-v$(e.version).pdf")
end

# The authenticated principal is known over MCP. The client need not be a specific model or vendor.
publication_agent(c) = agent("Agent for " * caller_name(c); id = person_id(c))

"""Prepare a project manuscript with Markdown in body or an uploaded .md or .pdf media address in source.
Authors names the people and agents and their contributions. A Markdown file can supply title and date.
Returns the draft and its revision. To edit or start the next version, supply id and the latest revision,
all manuscript fields and, for a PDF, its source. Later editions need a changes note. Saving does not publish."""
function publication_draft_tool(project::String; id::Int = 0, revision::String = "", title::String = "",
        authors::String = "", abstract::String = "", body::String = "", date::String = "", changes::String = "",
        source::String = "")::String
    refusing() do
        caller = tool_caller()
        JSON.json(draft_publication!(kb(), caller, publication_agent(caller), project;
            id, revision, title, authors, abstract, body, date, changes, source))
    end
end
tool!("publication_draft", publication_draft_tool; need = "tasks.edit")

"""Publish the exact saved draft identified by id and revision. Its audience defaults to project.
A maintainer may choose instance for all instance readers. Each later edition keeps the first audience.
Returns the immutable edition URL and the account that published it."""
function publication_publish_tool(id::Int, revision::String; audience::String = "project")::String
    refusing() do
        caller = tool_caller()
        e = publish_publication!(kb(), caller, publication_agent(caller), id, revision; audience)
        "Published $(e.title), v$(e.version), by $(e.published_by). " * site_base(kb().config) * e.url
    end
end
tool!("publication_publish", publication_publish_tool; need = "tasks.edit")

"""Read an internal publication, optionally at a specific numbered version. Contributors can read its pending draft
with draft=true. The revision returned is needed to edit the manuscript or publish that draft."""
function publication_tool(id::Int; version::Int = 0, draft::Bool = false)::String
    refusing() do
        JSON.json(publication_edition(kb(), tool_caller(), id; version, editing = draft))
    end
end
tool!("publication", publication_tool; need = "read")


# Each permalink uses the same VitePress reader. Only the API response contains manuscript data.
function publication_site_response(kb, caller, path; req = nothing)
    page = match(r"^/publications/([1-9][0-9]*)/(?:v([1-9][0-9]*)/)?$", path)
    if page !== nothing
        try
            w = publication_work(kb, caller, page[1])
            page[2] === nothing || something(tryparse(Int, page[2]), typemax(Int)) <= w.latest || not_found("No such edition")
        catch e
            e isa Refusal && e.status == 404 || rethrow()
            return not_found_page(kb.config)
        end
        f = site_file(kb.config, "/publications/index.html")
        return f === nothing ? nothing : file_response(f; req)
    end
    script = match(r"^/assets/publications_(?<id>[1-9][0-9]*)_(?:v(?<version>[1-9][0-9]*)_)?index\.md(?<tail>\..+\.js)$", path)
    script === nothing && return nothing
    target = "publications/" * script[:id] * "/" * (isnothing(script[:version]) ? "" : "v$(script[:version])/") * "index"
    return live_page_response(kb, "publications/index", target, :page_script, script; req)
end
