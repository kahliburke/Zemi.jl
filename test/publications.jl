@zset "internal research publications" begin
    kb = open_kb(temp_config())
    localuser = K.local_caller()
    me = K.person("Ada")
    K.create_project!(kb, "Field work"; key = "FW", by = me)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    K.ensure_roles!(kb)
    function account(name)
        uid = K.sign_in!(kb, sh, "Campus", name; email = name * "@example.org", verified = true)
        return K.Caller(uid, name, name * "@example.org", Set(["read","tasks.edit","tasks.view"]), :session, nothing)
    end
    contributor, viewer, elsewhere = account("Bea"), account("Rowan"), account("Finn")
    keeper = account("Ada")
    K.set_member!(kb, "FW", keeper.user_id, "maintainer")
    K.set_member!(kb, "FW", contributor.user_id, "contributor")
    K.set_member!(kb, "FW", viewer.user_id, "viewer")
    request(caller, method, path, d = Dict()) = K.handle(kb,
        K.HTTP.Request(method, path, ["Content-Type" => "application/json"], K.JSON.json(d)), caller)
    payload(r) = K.JSON.parse(String(r.body))
    api = "/api/publications"
    searchfor(c, word) = payload(request(c, "GET", "/api/search?kinds=publication&q=$word"))["publications"]
    finding = K.create_finding!(kb, "FW", "Higher spring tides"; body = "A longer transect.", by = me)
    unrelated = K.create_finding!(kb, "FW", "Wind speed"; by = me)
    source = K.add_media!(kb, codeunits("---\ntitle: Crest\ndate: 2026-04-12\n---\nOriginal manuscript"),
                          "work.md"; by = me.name, project = "FW")
    draft = K.draft_publication!(kb, contributor, K.agent("Research assistant"), "FW"; authors = "Ada and Research assistant",
        abstract = "Measured in spring", source = source.address, finding)
    id = draft.id
    @test (draft.title, draft.date, draft.body) == ("Crest", "2026-04-12", "Original manuscript")
    @test only(payload(request(contributor, "GET", "$api?project=FW"))["drafts"])["id"] == id
    @test isempty(payload(request(viewer, "GET", "$api?project=FW"))["drafts"])
    @test request(viewer, "GET", "$api/$id?draft=1").status == 403
    @test request(viewer, "GET", "$api/$id").status == 404
    @test isempty(searchfor(contributor, "Crest"))
    byfinding(ref) = "$api?project=FW&finding=$ref"
    @test draft.finding == finding
    @test only(payload(request(contributor, "GET", byfinding(finding)))["drafts"])["id"] == id
    @test isempty(payload(request(contributor, "GET", byfinding(unrelated)))["drafts"])
    @test request(elsewhere, "GET", byfinding(finding)).status == 404
    @test request(contributor, "POST", "/api/projects/FW/publications", Dict("finding" => "XX-F1")).status == 404
    publish(c, rev; audience = "project") = request(c, "POST", "$api/$id/publish", Dict("revision" => rev, "audience" => audience))
    @test publish(contributor, draft.revision; audience = "instance").status == 403
    @test publish(viewer, draft.revision).status == 403
    v1 = payload(publish(contributor, draft.revision))
    @test v1["finding"] == finding && only(payload(request(viewer, "GET", byfinding(finding)))["works"])["id"] == id
    @test v1["published_by"] == "Bea" && v1["prepared_by"] == "Research assistant"
    @test v1["url"] == "/publications/$id/v1/" && payload(publish(contributor, draft.revision))["version"] == 1
    @test only(searchfor(viewer, "spring"))["id"] == id
    @test isempty(searchfor(elsewhere, "spring")) && request(elsewhere, "GET", "$api/$id?version=1").status == 404
    @test request(contributor, "POST", "/api/projects/FW/publications", Dict("id" => id, "title" => "stale")).status == 409
    edit = Dict("id" => id, "revision" => draft.revision, "title" => "Summer", "body" => "Second text",
                "authors" => "Ada", "abstract" => "Measured again", "changes" => "Added sample")
    pending = payload(request(contributor, "POST", "/api/projects/FW/publications", edit))
    @test request(viewer, "GET", "$api/$id?version=2").status == 404
    edit["revision"] = pending["revision"]
    edit["body"] = "Second text, corrected"
    corrected = payload(request(contributor, "POST", "/api/projects/FW/publications", edit))
    @test publish(contributor, pending["revision"]).status == 409
    @test isempty(searchfor(viewer, "Summer"))
    v2 = payload(publish(contributor, corrected["revision"]))
    @test v2["version"] == 2 && payload(request(viewer, "GET", "$api/$id"))["body"] == edit["body"]
    @test payload(request(viewer, "GET", "$api/$id?version=1"))["body"] == draft.body
    @test isempty(searchfor(viewer, "Crest")) && only(searchfor(viewer, "Summer"))["version"] == 2
    # The external history belongs to the work. Each milestone names the internal edition used.
    event = Dict("version" => 1, "stage" => "preprint", "venue" => "Example repository",
                 "date" => "2026-04-15", "reference" => "2401.12345v2")
    record(c, data) = request(c, "POST", "$api/$id/history", data)
    @test record(contributor, event).status == 403
    @test record(elsewhere, event).status == 404
    @test record(keeper, merge(event, Dict("version" => 3))).status == 400
    @test record(keeper, merge(event, Dict("reference" => ""))).status == 400
    @test record(keeper, merge(event, Dict("reference" => "no-link"))).status == 400
    @test record(keeper, merge(event, Dict("date" => "2026-02-31"))).status == 400
    @test only(payload(record(keeper, event)))["url"] == "https://arxiv.org/abs/2401.12345v2"
    @test length(payload(record(keeper, event))) == 1
    final = merge(event, Dict("version" => 2, "stage" => "published", "date" => "2026-05-28",
                              "venue" => "Example Journal", "reference" => "doi:10.1234/example"))
    @test last(payload(record(keeper, final)))["url"] == "https://doi.org/10.1234/example"
    submission = merge(final, Dict("stage" => "submitted", "date" => "2026-05-06", "reference" => ""))
    history = payload(record(keeper, submission))
    @test [h["stage"] for h in history] == ["preprint", "submitted", "published"]
    @test [h["version"] for h in history] == [1, 2, 2]
    old_edition = payload(request(viewer, "GET", "$api/$id?version=1"))
    @test old_edition["history"] == history && old_edition["body"] == draft.body
    @test String(request(viewer, "GET", "$api/$id/1/markdown").body) == draft.body
    @test request(elsewhere, "GET", "$api/$id/1/markdown").status == 404
    pdf = K.add_media!(kb, codeunits("%PDF-1.5\nfixture"), "work.pdf"; by = me.name, project = "FW")
    separate = K.draft_publication!(kb, localuser, me, "FW"; title = "Survey", authors = "Ada", abstract = "Survey results", source = pdf.address, finding)
    @test request(elsewhere, "GET", "$api/$(separate.id)/1/pdf").status == 404
    K.publish_publication!(kb, localuser, me, separate.id, separate.revision; audience = "instance")
    @test String(request(elsewhere, "GET", "$api/$(separate.id)/1/pdf").body) == "%PDF-1.5\nfixture"
    @test payload(request(elsewhere, "GET", "$api/$(separate.id)"))["finding"] == ""
    scoped = K.Caller(elsewhere.user_id, "Finn", "", elsewhere.permissions, :token, nothing, Set(["OT"]))
    @test isempty(searchfor(scoped, "Survey"))
    @test request(scoped, "GET", "$api/$(separate.id)/1/pdf").status == 404
    K.sweep_media!(kb; grace = K.Day(0), now = K.Dates.now() + K.Day(1))
    @test pdf.hash in K.media_in_use(kb) && isfile(K.media_path(kb.config, pdf.hash))
    # An authenticated MCP client prepares a draft that a person publishes; either may publish.
    old = K._KB[]
    K._KB[] = kb
    session = "publication-test-session"
    K.MCP_CALLERS[session] = (contributor, K.Dates.now())
    as_agent(f) = task_local_storage(f, :gate_caller, session)
    try
        tools = Dict(t.name => t.f for t in K.TOOLS[])
        m = K.JSON.parse(as_agent(() -> tools["publication_draft"]("FW"; source = pdf.address,
            title = "Estuary", authors = "Survey agent", abstract = "Field results")))
        @test occursin(K.publication_url(id, 2), as_agent(() -> tools["finding"](finding)))
        mid = m["id"]
        @test m["prepared_by"] == "Agent for Bea"
        as_agent(() -> tools["publication_publish"](mid, m["revision"]))
        @test K.JSON.parse(as_agent(() -> tools["publication"](mid; version = 1)))["published_by"] == "Agent for Bea"
        K.MCP_CALLERS[session] = (keeper, K.Dates.now())
        direct = K.JSON.parse(as_agent(() -> tools["publication_event"](mid, 1, "published", "Sample proceedings",
            "2026-05-01"; reference = "https://example.org/proceedings/paper")))
        @test only(direct)["stage"] == "published"
        @test only(K.JSON.parse(as_agent(() -> tools["publication"](mid)))["history"])["version"] == 1
        @test occursin("/publications/$mid/v1/", as_agent(() -> tools["search"]("Estuary"; kind = "publication", project = "FW")))
        @test any(w -> w["id"] == mid, payload(request(viewer, "GET", "/api/recent?kind=publication")))
    finally
        delete!(K.MCP_CALLERS, session)
        K._KB[] = old
    end
    derived = K.draft_publication!(kb, contributor, me, "FW"; finding)
    @test (derived.title, derived.body) == ("Higher spring tides", "A longer transect.")
    K.delete_finding!(kb, finding; by = me)
    edition = K.publication_edition(kb, viewer, id; version = 1)
    @test isempty(edition.finding) && edition.body == "Original manuscript"
    close(kb)
end
