# Only recognized provider names are public. A custom endpoint may carry a private
# hostname, account path or credentials, none of which describes a model to a reader.
function about_provider(c::Config, url)
    isempty(url) && return ""
    host = lowercase(something(tryparse_host(url), ""))
    host == "api.openai.com" && return "OpenAI"
    host == "opencode.ai" && return "OpenCode Zen"
    rstrip(url, '/') in (rstrip(c.ollama_url, '/'), rstrip(c.ollama_url, '/') * "/v1") && return "Ollama"
    return ""
end

function about_agent(model)
    startswith(model, "ollama:") && return (chop(model; head = 7, tail = 0), "Ollama")
    if acp_model(model)
        agent, id = acp_parts(model)
        runtime = get(Dict("codex" => "Codex", "gemini" => "Gemini", "claude" => "Claude", "opencode" => "OpenCode"), agent, "")
        isempty(id) && return (runtime, "")
        return (id, runtime)
    end
    return (model, model in ("opus", "sonnet", "haiku") || startswith(model, "claude-") ? "Claude" : "")
end

"Public model descriptions from the selected roles and embedding layers, plus the operator's entries."
function about_models(c::Config)
    models = String[]
    function add(id, provider)
        # Model IDs can be qualified (org/model, model:tag). Skip paths and URLs.
        occursin(r"\A[A-Za-z0-9][A-Za-z0-9._:+-]*(?:/[A-Za-z0-9][A-Za-z0-9._:+-]*)*\z", id) || return
        push!(models, isempty(provider) ? id : "$id ($provider)")
    end
    if c.about.infer_models
        selected = Set([c.summarizer, c.code_summarizer, c.record_summarizer, c.judge, c.watch_judge, c.tutor, c.notebooker, c.analyst])
        for l in c.layers
            l.trial && !(l.name in c.search_layers) && continue
            push!(selected, l.source)
            add(l.model, isempty(l.url) ? "Ollama" : about_provider(c, l.url))
        end
        for s in c.summarizers
            s.name in selected || continue
            id, provider = s.kind == :agent ? about_agent(s.model) : (s.model, about_provider(c, s.url))
            add(id, provider)
        end
    end
    append!(models, filter(!isempty, strip.(c.about.models)))
    return unique(models)
end

function about_page(c::Config)
    a = c.about
    contact = isempty(strip(a.contact)) ? c.contact : a.contact
    body = IOBuffer()
    print(body, """<h2>Software</h2>
        <p><a href="https://github.com/kahliburke/Zemi.jl">Zemi.jl</a> $(pkgversion(@__MODULE__)),
        developed by Kahli Burke and contributors.</p>""")
    for (label, value) in (("Instance operator", a.operator), ("Contact", contact), ("Hosting provider", a.hosting_provider),
                           ("Data location", a.data_region), ("Domain holder", a.domain_holder), ("Funding", a.funding))
        isempty(strip(value)) || print(body, "<h2>$label</h2><p class=\"detail\">", html_escape(strip(value)), "</p>")
    end
    models = about_models(c)
    if !isempty(models)
        print(body, "<h2 id=\"models\">Configured AI models and providers</h2><ul>")
        foreach(m -> print(body, "<li>", html_escape(m), "</li>"), models)
        print(body, "</ul>")
    end
    isempty(strip(a.note)) || print(body, "<h2>Notes</h2><p class=\"detail\">", html_escape(strip(a.note)), "</p>")
    return public_info_page(c, "About", String(take!(body)))
end
