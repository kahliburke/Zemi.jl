# The suite's testsets, each a statement of the file (see runtests.jl).

@zset "arXiv ids" begin
    @test parse_arxiv_id("https://arxiv.org/abs/2602.25777") == (id = "2602.25777", version = "")
    @test parse_arxiv_id("https://arxiv.org/pdf/2401.01234v3") == (id = "2401.01234", version = "v3")
    @test parse_arxiv_id("https://arxiv.org/html/2401.01234v2#S3") == (id = "2401.01234", version = "v2")
    @test parse_arxiv_id("arXiv:2401.01234") == (id = "2401.01234", version = "")
    @test parse_arxiv_id("cond-mat/9703229") == (id = "cond-mat/9703229", version = "")
    @test parse_arxiv_id("https://arxiv.org/abs/math.DG/0501001v1") == (id = "math.DG/0501001", version = "v1")
    @test parse_arxiv_id("https://example.com/paper") === nothing
    @test parse_arxiv_id("not an id") === nothing
    @test parse_arxiv_id("https://doi.org/10.48550/arXiv.2401.01234") == (id = "2401.01234", version = "")
    # The patterns finding one in text are built from the one id pattern.
    @test match(K.ARXIV_IN_QUERY, "see hep-th/9901001v2 too")[1] == "hep-th/9901001"
    @test match(K.ARXIV_IN_REF, "Ada L. 2024, arXiv:2401.01234v1")[1] == "2401.01234"
end

@zset "identifiers" begin
    @test K.normalize_doi("https://doi.org/10.1016/J.Ecolmodel.2012.01.001.") == "10.1016/j.ecolmodel.2012.01.001"
    @test K.normalize_doi("doi: 10.1/ABC)") == "10.1/abc" && K.normalize_doi("10.1/x") == "10.1/x"
    @test K.normalize_title("Larval  Dispersal: on Récifs") == "larval dispersal on recifs"
    @test K.same_title("Énergie des récifs", "ENERGIE DES RECIFS")
    @test K.task_parts(" kb-12 ") == ("KB", 12) && K.task_parts("KB-F3") === nothing && K.task_parts("KB12") === nothing
    @test K.finding_parts("kb-f3") == ("KB", 3) && K.finding_parts("KB-3") === nothing
    @test K.is_task_ref("ED-1") && !K.is_task_ref("x86 64") && K.is_finding_ref("ED-F1") && !K.is_finding_ref("ED-1")
    @test K.ref_project("kb-12") == "KB" && K.ref_project("Kb-F3") == "KB" && K.ref_project("utf8") === nothing
    @test K.slugify("Campus Login!") == "campus-login" && K.slugify("Ada Lovelace.v2"; keep = "._-") == "ada-lovelace.v2"
    @test K.slugify("--Restoration & AI--") == "restoration-ai" && K.slugify("Ada") isa String
end

@zset "kinds of documents" begin
    for (id, kind) in (("2401.00001", K.PAPER), ("hep-th/9901001", K.PAPER), ("doc-0123456789", K.PAPER), ("code-reef", K.CODEBASE),
                       ("rec-notes-survey", K.RECORD))
        @test K.document_kind(id) === kind
    end
    @test K.is_arxiv_id("2401.00001") && !K.is_arxiv_id("doc-0123456789") && !K.is_arxiv_id("code-reef")
    @test K.is_upload("doc-0123456789") && !K.is_upload("2401.00001") && !K.is_upload("code-reef")
    @test K.is_literature("doc-0123456789") && !K.is_literature("code-reef") && !K.is_literature("rec-notes-survey")
    # A record is the group's own: seen by its projects' members, served live, never published or classified.
    @test K.RECORD.access && !K.RECORD.site && !K.RECORD.published && !K.RECORD.classified && !K.RECORD.landscape &&
          !K.RECORD.arxiv && !K.RECORD.pdf && !K.RECORD.tree && K.RECORD.unassigned == "paper.manage"
    @test K.document_page("rec-notes-survey") == "records/rec-notes-survey"
    # With no record summarizer set, records are the paper summarizer's.
    @test K.kind_summarizer(Config(), K.RECORD) == Config().summarizer
    @test K.kind_summarizer(Config(; record_summarizer = "opus-agent-pdf"), "rec-notes-survey") == "opus-agent-pdf"
    # An id of no kind is neither a paper nor on arXiv.
    @test K.document_kind("zzz-reef-survey") === nothing && !K.is_arxiv_id("zzz-reef-survey") && !K.is_literature("zzz-reef-survey")
    @test_throws ErrorException K.normalize_id("zzz-reef-survey")
    @test K.cited_as("2401.00001") == "arXiv:2401.00001" && K.cited_as("doc-0123456789") == "doc-0123456789"
    @test K.document_page("2401.00001") == "papers/2401-00001" && K.document_page("code-reef") == "code/code-reef/"
    @test K.kind_in(k -> k.literature) == "kind IN ('paper')" && K.kind_in(K.CODEBASE; on = "p") == "p.kind IN ('code')"
    @test K.kind_in(k -> k.access) == "kind IN ('code', 'record')"
    @test K.kind_in(k -> false) == "0"
    kb = open_kb(temp_config())
    @test_throws ErrorException add_papers!(kb, ["zzz-reef-survey"])
    # A record stays out of what lists the group's reading, and is not published.
    at = K.now_iso()
    K.execute!(kb, """INSERT INTO papers (doc_id, title, authors, published, metadata_at, added_at, kind, shared)
                      VALUES ('2609.00001', 'Reef patches', '["Ada Lovelace"]', '2026-09-01', ?, ?, 'paper', 0),
                             ('rec-reef-survey', 'Reef survey meeting', '["Ada Lovelace", "Rowan Hale"]', '2026-09-02', ?, ?, 'record', 1)""",
               (at, at, at, at))
    @test only(authors(kb)).papers == ["2609.00001"]
    @test [sp.doc_id for sp in K.site_papers(kb; related = false)] == ["2609.00001"]
    bib = bibliography(kb)                                                    # a record is cited, though not literature
    @test startswith(bib, "% The documents of the knowledge base: 2 entries.") && occursin("@misc{rec-reef-survey,", bib)
    @test [m.target for m in K.at_reference_matches(kb, "reef") if m.kind == "paper"] == ["2609.00001"]
    @test all(c -> c.id != "rec-reef-survey", K.daily_candidates(kb))
    @test [t.action for t in K.sync_plan(kb; unread = true) if t.id == "rec-reef-survey"] == [:ingest]   # read, not looked up
    @test K.publishable(kb, "2609.00001") && !K.publishable(kb, "rec-reef-survey")
    @test K.refresh_metadata!(kb, ["rec-reef-survey"]) == 0                       # not looked up on arXiv
    close(kb)
end

@zset "arXiv feed" begin
    xml = """<?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
      <entry>
        <id>http://arxiv.org/abs/2609.00001v2</id>
        <updated>2026-09-10T00:00:00Z</updated>
        <published>2026-09-01T00:00:00Z</published>
        <title>A Paper
          About Reefs</title>
        <summary>  We study
          things. </summary>
        <author><name>Ada Lovelace</name></author>
        <author><name>Alan Turing</name></author>
        <arxiv:doi>10.1000/xyz</arxiv:doi>
        <arxiv:primary_category term="physics.ao-ph"/>
        <category term="physics.ao-ph"/>
        <category term="math.DS"/>
      </entry>
    </feed>"""
    m = only(parse_arxiv_feed(xml))
    @test m.doc_id == "2609.00001" && m.version == "v2"
    @test m.title == "A Paper About Reefs"
    @test m.abstract == "We study things."
    @test m.authors == ["Ada Lovelace", "Alan Turing"]
    @test m.published == "2026-09-01" && m.updated == "2026-09-10"
    @test m.primary_category == "physics.ao-ph" && m.categories == ["physics.ao-ph", "math.DS"]
    @test m.doi == "10.1000/xyz" && m.journal_ref === nothing

    # When OAI-PMH does not answer, the records come from the search API, asked for by id.
    port = 19000 + rand(0:999)
    asked = String[]
    server = K.HTTP.serve!("127.0.0.1", port) do req
        push!(asked, req.target)
        startswith(req.target, "/oai") ? K.HTTP.Response(503, "busy") : K.HTTP.Response(200, xml)
    end
    saved = (K.OAI_URL[], K.ARXIV_API[])
    K.OAI_URL[], K.ARXIV_API[] = "http://127.0.0.1:$port/oai", "http://127.0.0.1:$port/api/query"
    try
        got = K.fetch_metadata(["2609.00001"], temp_config())
        @test got["2609.00001"].title == "A Paper About Reefs" && got["2609.00001"].version == "v2"
        @test startswith(first(asked), "/oai?") && occursin("id_list=2609.00001", last(asked))
        # A category's new papers too, page by page until one reaches back past the day asked from.
        empty!(asked)
        new = K.list_new_papers("physics.ao-ph", K.Date("2026-08-25"), temp_config())
        @test [m.doc_id for m in new] == ["2609.00001"] && occursin("search_query=cat%3Aphysics.ao-ph", last(asked))
        old = replace(xml, "2026-09-01T" => "2026-08-01T")
        pages = [replace(xml, "</entry>" => "</entry>" * replace(xml[findfirst("<entry>", xml)[1]:findlast("</entry>", xml)[end]], "00001" => "00002")), old]
        server2 = K.HTTP.serve!("127.0.0.1", port + 1) do req
            K.HTTP.Response(200, pages[occursin("start=0", req.target) ? 1 : 2])
        end
        K.ARXIV_API[] = "http://127.0.0.1:$(port + 1)/api/query"
        try
            @test [m.doc_id for m in K.list_new_papers_api("physics.ao-ph", K.Date("2026-08-25"), temp_config(); page_size = 2)] ==
                  ["2609.00001", "2609.00002"]
        finally
            close(server2)
        end
    finally
        K.OAI_URL[], K.ARXIV_API[] = saved
        close(server)
    end
end

@zset "arXiv over OAI-PMH" begin
    # A page of a listing: each paper's fields, names with their letters, and the token for the next page.
    page = """<?xml version="1.0" encoding="UTF-8"?>
    <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><ListRecords><record><metadata>
      <arXiv xmlns="http://arxiv.org/OAI/arXiv/"><id>2305.17583</id><created>2023-05-27</created><updated>2023-06-28</updated>
        <authors><author><keyname>Corvo</keyname><forenames>Tainá L.</forenames></author><author><keyname>H1 Collaboration</keyname></author>
                 <author><keyname>Smith</keyname><forenames>John</forenames><suffix>Jr</suffix></author></authors>
        <title>Reef crest
          erosion</title><categories>q-bio.PE physics.ao-ph</categories><doi>10.1016/x</doi><journal-ref>Coral Reefs 1 (2023)</journal-ref>
        <abstract>  Tidal flows
          wear it. </abstract></arXiv></metadata></record>
      <resumptionToken cursor="0" completeListSize="2">token|1001</resumptionToken></ListRecords></OAI-PMH>"""
    got = K.parse_oai_records(page)
    m = only(got.papers)
    @test got.token == "token|1001" && m.doc_id == "2305.17583" && m.title == "Reef crest erosion" && m.abstract == "Tidal flows wear it."
    @test m.authors == ["Tainá L. Corvo", "H1 Collaboration", "John Smith Jr"]
    @test (m.published, m.primary_category, m.categories, m.doi, m.journal_ref) ==
          ("2023-05-27", "q-bio.PE", ["q-bio.PE", "physics.ao-ph"], "10.1016/x", "Coral Reefs 1 (2023)")
    unknown = """<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><error code="idDoesNotExist">Nothing found</error></OAI-PMH>"""
    @test isempty(K.parse_oai_records(unknown).papers) && isempty(K.parse_oai_records(unknown).token)
    # Its versions, from the arXivRaw format.
    raw = """<OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/"><GetRecord><record><metadata><arXivRaw xmlns="http://arxiv.org/OAI/arXivRaw/">
      <id>2305.17583</id><version version="v1"><date>Sat, 27 May 2023 17:49:18 GMT</date></version>
      <version version="v2"><date>Wed, 28 Jun 2023 09:01:02 GMT</date></version></arXivRaw></metadata></record></GetRecord></OAI-PMH>"""
    @test K.parse_oai_versions(raw) == [(; version = "v1", date = "2023-05-27"), (; version = "v2", date = "2023-06-28")]
    # A category's set, from arXiv's list of them.
    c = temp_config()
    empty!(K.OAI_SETS)
    append!(K.OAI_SETS, ["physics", "physics:nlin", "physics:nlin:CD", "physics:physics:ao-ph", "math:math:DS", "physics:hep-th"])
    @test [K.oai_set(x, c) for x in ("nlin.CD", "physics.ao-ph", "math.DS", "hep-th")] ==
          ["physics:nlin:CD", "physics:physics:ao-ph", "math:math:DS", "physics:hep-th"]
    @test_throws "no OAI-PMH set" K.oai_set("q-bio.XX", c)
    empty!(K.OAI_SETS)
    # A busy answer is waited out with patience, as its Retry-After says, and fails at once without.
    port = 18000 + rand(0:999)
    asked = Ref(0)
    server = K.HTTP.serve!("127.0.0.1", port) do req
        asked[] += 1
        isodd(asked[]) ? K.HTTP.Response(429, ["Retry-After" => "1"], "busy") : K.HTTP.Response(200, "ok")
    end
    try
        @test String(K.arxiv_get("http://127.0.0.1:$port/x", c; patience = 30).body) == "ok" && asked[] == 2
        @test_throws "HTTP 429" K.arxiv_get("http://127.0.0.1:$port/x", c)
    finally
        close(server)
    end
    # The models' and stores' requests: a rate limit waited out, another refusal not tried again.
    tries = Ref(0)
    refused(status) = throw(K.HTTP.StatusError(K.HTTP.Response(status, ["Retry-After" => "0.1"], "no")))
    @test K.with_retry(() -> (tries[] += 1; tries[] == 1 ? refused(429) : :ok), "x") == :ok && tries[] == 2
    tries[] = 0
    @test_throws "x answered HTTP 401" K.with_retry(() -> (tries[] += 1; refused(401)), "x")
    @test tries[] == 1
    # A service that wants its requests spaced is waited for ahead of each try.
    spaced = Ref(0)
    tries[] = 0
    @test K.with_retry(() -> (tries[] += 1; tries[] == 1 ? refused(503) : :ok), "x"; before = () -> spaced[] += 1) == :ok
    @test spaced[] == 2
    @test_throws "x is limiting requests" K.with_retry(() -> refused(429), "x"; patience = 0)
end

@zset "layout" begin
    sizes = [(500.0, 700.0) for _ in 1:3]
    header(p) = block(p, line(span(60, 20, "Running head of the paper $p"; size = 8)))
    blocks = [
        block(1, line(span(20, 300, "arXiv:2609.00001v1 [physics.ao-ph] 1 Sep 2026"; size = 20))),
        block(1, line(span(60, 80, "A Title Set Large"; size = 17, bold = true))),
        block(1, line(span(60, 120, "Ada Lovelace and Alan Turing"))),
        block(1, line(span(60, 200, "1. Introduction"; bold = true))),
        block(1, line(span(60, 220, "Reefs are ancient. Larval recruit-")),
                 line(span(60, 232, "ment is how they persist.")),
                 line(span(75, 244, "A second paragraph starts indented here."))),
        block(1, line(span(200, 270, "B"; font = "CMMIB10"), span(210, 270, " = "), span(222, 270, "∇ψ × ∇θ"; font = "CMSY10"),
                      span(420, 270, "(1.1)"))),
        block(1, line(span(60, 300, "where the fields are as defined in the text above."))),
        header(1), header(2), header(3),
        block(2, line(span(60, 200, "1.1. Motivation"; italic = true, font = "CMTI10"))),
        block(2, line(span(60, 220, "The Cartan-K¨ahler theorem is relevant here."))),
        block(2, line(span(60, 400, "Figure 1. A caption describing the figure contents."))),
        block(3, line(span(60, 200, "References"; bold = true))),
        block(3, line(span(60, 220, "Marsh, B. 1981 Reef growth with rising and falling sea levels."))),
        block(3, line(span(240, 690, "3"))),
    ]
    p = parse_blocks(blocks, sizes)
    kinds = [x.kind for x in p.pieces]
    texts = [x.text for x in p.pieces]
    # arXiv's margin stamp goes; text citing an arXiv paper with its category stays.
    cited = parse_blocks([blocks[1], block(1, line(span(60, 300, "As in arXiv:1706.03762 [cs.CL], attention suffices for this.")))], sizes[1:1])
    @test any(x -> occursin("1706.03762", x.text), cited.pieces) && !any(x -> occursin("2609.00001", x.text), cited.pieces)
    @test !any(t -> occursin("arXiv:2609", t), texts)
    @test !any(t -> occursin("Running head", t), texts)
    @test p.pieces[1].kind == :title && p.pieces[1].text == "A Title Set Large"
    @test :front in kinds
    @test [s.title for s in p.sections] == ["1. Introduction", "1.1. Motivation", "References"]
    @test [s.level for s in p.sections] == [1, 2, 1]
    @test p.sections[2].path == "1. Introduction › 1.1. Motivation"
    paras = [x.text for x in p.pieces if x.kind == :paragraph]
    @test "Reefs are ancient. Larval recruitment is how they persist." in paras
    @test "A second paragraph starts indented here." in paras
    eq = only(x for x in p.pieces if x.kind == :equation)
    @test eq.number == "1.1" && occursin("∇ψ × ∇θ", eq.text)
    @test any(x -> x.kind == :caption && startswith(x.text, "Figure 1."), p.pieces)
    @test any(x -> x.kind == :reference && startswith(x.text, "Marsh"), p.pieces)
    @test any(t -> occursin("Cartan-Kähler", t), texts)
    @test !("3" in texts)

    # A journal's front page: its masthead names the journal larger than the title, and a header line
    # cites the paper. The title is the paper's, and the citation is where it appeared.
    front = [
        block(1, line(span(60, 40, "Reef Ecology and Management 87 (2012) 1453–1456"; size = 8))),
        block(1, line(span(60, 70, "Reef Ecology and Management"; size = 20))),
        block(1, line(span(60, 110, "Survey design for shallow reef transects"; size = 15, bold = true))),
        block(1, line(span(60, 150, "R. Hale and B. Marsh"))),
        block(1, line(span(60, 200, "The survey is built from transects, and this paragraph is the body."))),
    ]
    j = parse_blocks(front, sizes[1:1])
    @test K.parsed_title(j) == "Survey design for shallow reef transects"
    @test K.parsed_citation(j) == (; ref = "Reef Ecology and Management 87 (2012) 1453–1456", year = "2012")
    @test K.parsed_citation(p) === nothing
    # A masthead that is a few words of the cited name, and a citation by article number in the
    # running header of every page, which is dropped as page furniture.
    physica = [block(1, line(span(60, 40, "ELSEVIER Physica D 91 (1996) 1-23"; size = 8))),
               block(1, line(span(60, 70, "PHYSICA"; size = 24))),
               block(1, line(span(60, 110, "Larval dispersal on fringing reefs"; size = 15, bold = true))),
               block(1, line(span(60, 200, "Larvae released on the reef flat are carried along the fringe before they settle.")))]
    @test K.parsed_title(parse_blocks(physica, sizes[1:1])) == "Larval dispersal on fringing reefs"
    jcp_header(page) = block(page, line(span(60, 20, "A. Author Journal of Computational Physics 511 (2024) 113052"; size = 8)))
    jcp = [jcp_header(1), block(1, line(span(60, 70, "Journal of Computational Physics"; size = 20))),
           block(1, line(span(60, 110, "A semi-Lagrangian scheme for tidal transport"; size = 15, bold = true))),
           block(1, line(span(60, 200, "We extend a scheme for strongly sheared tidal transport in this paragraph."))),
           (b for page in 2:4 for b in (jcp_header(page), block(page, line(span(60, 200, "More of the body of the paper, on page $page.")))))...]
    @test K.parsed_title(parse_blocks(jcp, repeat(sizes[1:1], 4))) == "A semi-Lagrangian scheme for tidal transport"
end

@zset "layout: running heads, figure text and captions" begin
    size = (500.0, 700.0)
    body(page, y, text) = block(page, line(span(60, y, text)))
    prose = "Transects across the reef crest were surveyed in each season of the year."
    # Running heads that put the page number on the outer side, below the strict margin but with no
    # text above them, and a page number at the foot.
    head(p) = block(p, line(span(iseven(p) ? 60 : 280, 70, iseven(p) ? "$p A SURVEY OF REEF CRESTS" : "A SURVEY OF REEF CRESTS $p"; size = 8)))
    pages = [b for p in 1:6 for b in ((p == 1 ? () : (head(p),))..., body(p, 120, "$prose Page $p."), block(p, line(span(240, 625, "- $p -"))))]
    texts = [x.text for x in parse_blocks(pages, fill(size, 6)).pieces]
    @test !any(t -> occursin("SURVEY OF REEF CRESTS", t) || occursin(r"^- \d -$", t), texts) && length(texts) == 6
    @test K.running_key("12 A Survey of Reef Crests") == K.running_key("A Survey of Reef Crests | 13") ==
          K.running_key("xiv A Survey of Reef Crests") == "a survey of reef crests"
    # Different heads on facing pages, each on too few pages to count over all of them.
    facing(p) = block(p, line(span(60, 70, iseven(p) ? "Ada Lovelace and Rowan Hale" : "Reef crest transects"; size = 8)))
    short = [b for p in 1:5 for b in ((p == 1 ? () : (facing(p),))..., body(p, 120, "$prose Page $p."))]
    texts = [x.text for x in parse_blocks(short, fill(size, 5)).pieces]
    @test !any(t -> occursin("Rowan Hale", t) || occursin("Reef crest transects", t), texts) && length(texts) == 5
    # A line at the top of one page only is text.
    once = [body(1, 120, "$prose Page 1."), block(2, line(span(60, 70, "Reef crest transects"; size = 8))), body(2, 120, prose)]
    @test any(x -> x.text == "Reef crest transects", parse_blocks(once, fill(size, 2)).pieces)

    # A figure's labels, legend and math lie between the text above it and its caption, and go; the last
    # line of the paragraph above, a block of its own, and a numbered equation above a figure stay.
    fig = [block(1, line(span(60, 100, prose)), line(span(60, 112, prose)), line(span(60, 124, "and the cover of each was recorded"))),
           body(1, 138, "along every transect."),
           block(1, line(span(120, 180, "a b c d"))),
           block(1, line(span(200, 260, "Cover (%)"; size = 7))),
           block(1, line(span(120, 230, "∂C/∂t"; font = "CMMI10"))),
           body(1, 330, "Figure 2. Coral cover on the reef crest, by transect and season."),
           body(1, 360, "Figure 2 shows that the cover was highest where the crest was most exposed to waves."),
           block(2, line(span(60, 100, prose)), line(span(60, 112, prose))),
           block(2, line(span(150, 150, "C = rC(1 − C)"; font = "CMMI10"), span(400, 150, "(3)"))),
           block(2, line(span(120, 200, "e f g h"))),
           body(2, 300, "Fig. 3: Coral cover by depth, after the model of equation (3)."),
           body(2, 330, "TABLE II. Survey sites and their depths."),
           block(2, line(span(60, 360, "Fig. 4"; bold = true), span(95, 360, "Transect positions on the crest."))),
           body(2, 400, "Table 3 lists the sites, with their depths and the seasons they were surveyed in.")]
    p = parse_blocks(fig, fill(size, 2))
    texts = [x.text for x in p.pieces]
    @test !any(t -> t in ("a b c d", "Cover (%)", "∂C/∂t", "e f g h"), texts)
    @test "along every transect." in texts
    @test any(x -> x.kind == :equation && x.number == "3", p.pieces)
    kind(prefix) = only(x.kind for x in p.pieces if startswith(x.text, prefix))
    @test kind("Figure 2.") == kind("Fig. 3:") == kind("TABLE II.") == kind("Fig. 4") == :caption
    @test kind("Figure 2 shows") == kind("Table 3 lists") == :paragraph
end

@zset "an upload's published record" begin
    page(texts...) = K.ParsedPaper(1, [K.Piece(kind, 1, (0.0, 0.0, 0.0, 0.0), t, 0, 0, "") for (kind, t) in texts], K.Section[])
    work(title; doi = "https://doi.org/10.1234/x") = Dict{String,Any}("doi" => doi, "title" => title, "publication_year" => 1996,
        "authorships" => [Dict("author" => Dict("display_name" => "D. del-Monte-Hale")), Dict("author" => nothing)],
        "primary_location" => Dict("source" => Dict("display_name" => "Physica D")),
        "biblio" => Dict("volume" => "91", "first_page" => "1"),
        "abstract_inverted_index" => Dict("dispersal" => [1], "Larval" => [0]))
    asked = []
    find(; doi = nothing, title = nothing, contact = "") = (push!(asked, something(doi, title));
        doi == "10.1234/x" ? work("Larval dispersal on fringing reefs") : doi == "10.1234/other" ? work("Some other paper") :
        title == "Larval dispersal on fringing reefs" ? work("Larval Dispersal On Fringing Reefs") : nothing)
    # By the DOI on the first page, when the record's title is printed there too.
    r = K.lookup_upload(page((:title, "PHYSICA"), (:front, "Larval dispersal on fringing reefs"), (:footnote, "https://doi.org/10.1234/X.")); find)
    @test r == (; title = "Larval dispersal on fringing reefs", authors = ["D. del-Monte-Hale"], year = "1996", journal = "Physica D",
                journal_ref = "Physica D 91, 1 (1996)", doi = "10.1234/x", abstract = "Larval dispersal")
    @test first(asked) == "10.1234/x"
    # A DOI whose record's title is not on the page is not taken; an exact title is found instead.
    r = K.lookup_upload(page((:title, "PHYSICA"), (:front, "Larval dispersal on fringing reefs"), (:footnote, "doi:10.1234/other")); find)
    @test r.title == "Larval Dispersal On Fringing Reefs"
    @test K.lookup_upload(page((:title, "Nothing known about this one at all")); find) === nothing

    # A publisher's download sheet: the journal's name in large type, the title with a hyphen lost at
    # a line break, and the DOI only on the next page. The journal's own record is never the paper.
    sheet = K.ParsedPaper(2, [K.Piece(:front, 1, (0.0, 0.0, 0.0, 0.0), "Coral Reef Science", 0, 0, ""),
                              K.Piece(:title, 1, (0.0, 0.0, 0.0, 0.0), "REEFNET: a low-cost ISOcompliant reef monitoring network", 0, 0, ""),
                              K.Piece(:footnote, 2, (0.0, 0.0, 0.0, 0.0), "https://doi.org/10.1088/1748-9326/ad6708", 0, 0, "")], K.Section[])
    journal = Dict{String,Any}("doi" => "https://doi.org/10.1088/issn.1748-9326", "title" => "Coral Reef Science",
                               "type" => "paratext", "publication_year" => 2019, "authorships" => [], "biblio" => Dict(),
                               "abstract_inverted_index" => nothing,
                               "primary_location" => Dict("source" => Dict("display_name" => "Coral Reef Science")))
    reefnet = merge(work("REEFNET: a low-cost ISO-compliant reef monitoring network"; doi = "https://doi.org/10.1088/1748-9326/ad6708"),
                  Dict{String,Any}("type" => "article", "publication_year" => 2024))
    sheet_find(; doi = nothing, title = nothing, contact = "") =
        doi == "10.1088/1748-9326/ad6708" ? reefnet : title == "Coral Reef Science" ? journal : nothing
    r = K.lookup_upload(sheet; find = sheet_find)
    @test r.title == "REEFNET: a low-cost ISO-compliant reef monitoring network" && r.year == "2024" && r.doi == "10.1088/1748-9326/ad6708"
    titles_only(; doi = nothing, title = nothing, contact = "") = doi === nothing ? sheet_find(; title) : nothing
    @test K.lookup_upload(sheet; find = titles_only) === nothing                  # not the journal's record
    @test !K.is_paper(journal) && K.is_paper(reefnet) && K.same_title("ISOcompliant reef", "ISO-compliant reef")
    # The PDF's own metadata: a DOI in its Subject, its Title tried first where it reads as one.
    meta = K.ParsedPaper(1, K.Piece[], K.Section[], Dict("Subject" => "Coral Reef Sci. 66 (2024) 105006. doi:10.1088/1748-9326/ad6708",
                                                        "Title" => "REEFNET: a low-cost ISO-compliant reef monitoring network"))
    @test K.page_dois(meta) == ["10.1088/1748-9326/ad6708"] && first(K.title_candidates(meta)) == meta.info["Title"]
    @test isempty(K.title_candidates(K.ParsedPaper(1, K.Piece[], K.Section[], Dict("Title" => "Microsoft Word - draft7.docx"))))
    # A title that is the journal's name is no one's typed title, and is replaced.
    @test K.is_journal_name("PHYSICA", "Physica D: Nonlinear Phenomena") && K.is_journal_name("Journal of Computational Physics", "Journal of Computational Physics")
    @test !K.is_journal_name("Physics of coastal waves", "Physica D")
end

@zset "search defaults" begin
    c = Config()
    @test c.search_layers == [l.name for l in c.layers if l.model == "qwen3-embedding:4b" && !l.trial] && c.search_keyword
    # A trial layer is neither built by a sync nor searched unless chosen.
    t = Config(; layers = [K.default_layers(); Layer(; name = "chunk-trial", model = "nomic-embed-text", unit = :chunk, trial = true)])
    @test all(l -> !l.trial, K.ingest_layers(t)) && !("chunk-trial" in t.search_layers)
    small = [Layer(; name = "a", model = "nomic-embed-text", unit = :chunk)]
    @test Config(; layers = small).search_layers == ["a"]             # no strongest model: every layer
end

@zset "accents" begin
    @test compose_accents("K¨ahler") == "Kähler"
    @test compose_accents("Poincar´e") == "Poincaré"
    @test compose_accents("no accents") == "no accents"
end

@zset "chunking" begin
    para(n, s) = K.Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), repeat("Word. ", n), s, 0, "")
    eqn(s) = K.Piece(:equation, 1, (0.0, 0.0, 0.0, 0.0), "E = mc²", s, 0, "1")
    head(s) = K.Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), "$s. Heading", s, 1, "$s")
    p = K.ParsedPaper(1, [head(1), para(100, 1), para(100, 1), para(150, 1), eqn(1), head(2), para(20, 2)],
        [K.Section(1, 1, "1", "1. Heading", "1. Heading", 1, 1), K.Section(2, 1, "2", "2. Heading", "2. Heading", 1, 1)])
    cs = chunk_paper(p, "An abstract.")
    @test cs[1].section == 0 && cs[1].text == "An abstract."
    @test all(c.ord == i - 1 for (i, c) in enumerate(cs))
    @test [c.section for c in cs] == [0, 1, 1, 2]
    @test endswith(cs[3].text, "E = mc²")  # the equation stays with the paragraph before it
    @test all(c -> length(c.text) <= CHUNK_MAX + 10, cs)
    soup = K.Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), repeat("p̃1 π 3 ψ2 B + Ã1 − ", 20), 2, 0, "")
    p2 = K.ParsedPaper(1, [head(1), para(20, 1), head(2), soup], p.sections)
    @test [c.section for c in chunk_paper(p2, "")] == [1]  # the symbol soup is dropped
    @test K.prose_fraction("Ordinary words make ordinary prose.") > 0.8
    @test K.prose_fraction("p̃1 π 3 ψ2 B") < 0.2
    long = repeat("A sentence of moderate length goes here. ", 120)
    parts = split_long(long)
    @test length(parts) > 1 && all(x -> length(x) <= CHUNK_MAX, parts)
end

@zset "search helpers" begin
    @test keyword_query("What is the reef crest?") == "\"what\" OR \"is\" OR \"the\" OR \"reef\" OR \"crest\""
    @test keyword_query("?!") == ""
    id = point_id("chunk-x", "c:2609.00001:3")
    @test id == point_id("chunk-x", "c:2609.00001:3") != point_id("chunk-y", "c:2609.00001:3")
    @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", id)
end

@zset "markdown escaping" begin
    esc = Zemi.md_escape
    @test esc("E_k = mv^2 / 2\n  = lim f\n::: x") == "E&#95;k = mv^2 / 2\n  &#61; lim f\n&#58;:: x"
    @test esc("where \$a_1\$ is {{b}}") == "where ``a_1`` is &#123; &#123;b&#125; &#125;"
    # Code spans, in text about code: kept as code, and not broken by an underscore or a brace inside.
    @test esc("builds `edge_scan` and `f(x; a = {{1}})`, not *this*"; code = true) ==
          "builds `edge_scan` and `f(x; a = { {1} })`, not &#42;this&#42;"
    @test esc("as `quoted' here and `there'") == "as &#96;quoted' here and &#96;there'"      # prose: no code spans
    # A summary in Markdown keeps its lists, however bulleted, and its names as code.
    @test esc("Scans the reef.\n\n- `scan(x)` runs it\n* `Grid` holds it\n  + nested\n1. first"; code = true) ==
          "Scans the reef.\n\n- `scan(x)` runs it\n- `Grid` holds it\n  - nested\n1. first"
    # No text reaches the page as Vue's `{{`, once its references are decoded, however the pieces it
    # was escaped in fall: empty math between two braces, or braces on each side of a code span.
    decoded(s) = replace(s, "&#123;" => "{", "&#125;" => "}")
    for text in ("{\$ \${ \$nextTick.constructor('alert(1)')() }\$ \$}", "{\$\$ \$\${ x }\$\$ \$\$}", "{`a`{ x }`b`}")
        @test !occursin("{{", decoded(esc(text))) && !occursin("}}", decoded(esc(text)))
        @test !occursin("{{", decoded(esc(text; code = true)))
    end
    @test esc("cost \$ \$ here") == "cost &#36; &#36; here"                                  # empty math kept as text
    # A code block's fence outlasts any run of backticks in it, indented or not.
    io = IOBuffer()
    K.plain_code(io, "text", "a\n  ```\n<img src=x onerror=alert(1)>\n`````")
    @test String(take!(io)) == "``````text\na\n  ```\n<img src=x onerror=alert(1)>\n`````\n``````\n"
end

@zset "store" begin
    @test K.in_marks(3) == "?, ?, ?" && K.in_marks(1) == "?"
    kb = open_kb(temp_config())
    @test add_papers!(kb, ["https://arxiv.org/abs/2609.00001v2", "2609.00002", "2609.00001"]) == ["2609.00001", "2609.00002"]
    @test scalar(kb, "SELECT count(*) FROM papers") == 2
    K.migrate!(kb)  # idempotent
    @test scalar(kb, "SELECT value FROM kv WHERE key = 'schema_version'") == string(K.schema_version())
    @test_throws ErrorException add_papers!(kb, ["nonsense"])
    # A paper with no stored vector has no related papers, and Qdrant is not asked for one.
    @test K.related_papers(kb, "2609.00001") == []
    close(kb)
end

@zset "agent steps" begin
    ev(title, input) = Dict("kind" => "tool_use", "data" => Dict("call" => Dict("title" => title, "rawInput" => input)))
    step(title, input) = K.agent_step(ev(title, input)).says
    @test step("mcp__kaimon__slate_add_cell", Dict("id" => "setup", "kind" => "code")) == "adding a code cell `setup`"
    @test step("mcp__kaimon__slatembse_run", Dict("cell" => "fig")) == "running cell `fig`"
    @test step("mcp__kaimon__slate_run", Dict("cell" => "")) == "running the notebook"
    @test step("mcp__kaimon__slate_edit_cell", Dict("cell" => "b20")) == "changing cell `b20`"
    @test step("Read", Dict("file_path" => "/x/paper.pdf", "pages" => "1-20")) == "reading the paper (pages 1-20)"
    @test step("mcp__kaimon__slate_pkg", Dict("notebook" => "n")) == "checking the notebook's packages"
    @test step("mcp__kaimon__slate_pkg", Dict("packages" => ["CairoMakie"])) == "adding packages: CairoMakie"
    @test K.agent_step(Dict("kind" => "assistant_text", "data" => Dict())) === nothing
    # The notebook a Slate tool answered with an address for, from the agent's log of events.
    home = mktempdir()
    mkpath(joinpath(home, "kaimon", "agents"))
    write(joinpath(home, "kaimon", "agents", "a1.events.jsonl"),
          K.JSON.json(Dict("kind" => "tool_result", "data" => Dict("text" => "Serving /x/computed-1.jl at http://127.0.0.1:8765/n/computed_1"))) * "\n" *
          K.JSON.json(Dict("kind" => "assistant_text", "data" => Dict("text" => "see http://127.0.0.1:9/n/not_a_tool"))) * "\n")
    @test withenv(() -> K.agent_urls("a1"), "XDG_CACHE_HOME" => home) == ["http://127.0.0.1:8765/n/computed_1"]
    # The service's own Kaimon logs them in its cache, which it is told of.
    @test withenv(() -> K.agent_urls("a1"), "KAIMON_CACHE_DIR" => joinpath(home, "kaimon"), "XDG_CACHE_HOME" => mktempdir()) ==
          ["http://127.0.0.1:8765/n/computed_1"]
    # A call is named as it starts, before its inputs are written, and looking up a tool is not a step.
    @test K.agent_step(Dict("kind" => "tool_use", "data" => Dict("call" => Dict("title" => "Write", "rawInput" => nothing)))).says == "writing"
    @test K.agent_step(Dict("kind" => "tool_use", "data" => Dict("call" => Dict("title" => "ToolSearch")))) === nothing
    @test step("Write", Dict("file_path" => "/c/files/recruits.svg")) == "drawing a figure"
    @test step("Write", Dict("file_path" => "/c/files/explorer.html")) == "building a page"
end

@zset "authors" begin
    @test author_key("Dana Iles") == author_key("D. Iles") == author_key("Iles, Dana") == "iles|d"
    @test author_key("Håkon M. Lind") == "lind|h" && author_key("Jan van der Berg") == "van der berg|j"
    @test author_key("{Reef Survey Team}") == author_key("the Reef Survey team") == "reef survey team|"
    @test K.author_matches("Dana Iles", "d il") && K.author_matches("Håkon Lind", "hakon") && !K.author_matches("Dana Iles", "marsh")
    kb = open_kb(temp_config())
    add_papers!(kb, ["2609.00001", "2609.00002", "2609.00003"])
    for (id, who, when) in (("2609.00001", ["Dana Iles", "Beatrice J. Marsh"], "2022-01-01"),
                            ("2609.00002", ["D. Iles", "B. Marsh", "C. Okafor"], "2023-01-01"),
                            ("2609.00003", ["Cyrus\u00a0Okafor"], "2024-01-01"))
        K.execute!(kb, "UPDATE papers SET title = ?, authors = ?, published = ? WHERE doc_id = ?", ("Paper $id", K.JSON.json(who), when, id))
    end
    people = authors(kb)
    di = only(a for a in people if a.key == "iles|d")
    @test di.name == "Dana Iles" && Set(di.variants) == Set(["Dana Iles", "D. Iles"])
    @test di.papers == ["2609.00002", "2609.00001"]                       # newest first
    @test first(di.coauthors).name == "Beatrice J. Marsh" && first(di.coauthors).count == 2
    co = only(a for a in people if a.key == "okafor|c")
    @test co.papers == ["2609.00003", "2609.00002"] && Set(co.variants) == Set(["Cyrus Okafor", "C. Okafor"])   # a non-breaking space is a space
    listed = K.format_paper_list(kb, "", "", 30; author = "iles")
    @test occursin("2 paper(s)", listed) && !occursin("2609.00003", listed)
    @test Dict("name" => "D. Iles", "key" => "iles|d") in K.paper_json(K.site_paper(kb, "2609.00002"; related = false))["authors"]
    close(kb)
end

@zset "missing papers" begin
    ref(text; kw...) = Reference(; text, kw...)
    @test K.work_key(ref("x"; arxiv = "1412.6980", doi = "10.1/y")) == "arxiv:1412.6980"
    @test K.work_key(ref("x"; doi = "10.1063/1.4920931")) == "doi:10.1063/1.4920931"
    @test K.work_key(ref("A. H. Marsh, Ecol. Lett. 22, 032505 (2015).")) == "ref:2015:22:32505"
    @test K.work_key(ref("Marsh, A. H. 2015 Ecol. Lett. 22, 032505")) == "ref:2015:22:32505"      # the same work, another style
    @test K.work_key(ref("A. Author, A book (2015).")) === nothing                                 # too little to group by
    citing = ["p1" => [ref("Okafor, Cy (2014) arXiv:1412.6980"; arxiv = "1412.6980"),
                       ref("A. H. Marsh, Ecol. Lett. 22, 032505 (2015)."),
                       ref("In the knowledge base"; arxiv = "2401.00001", cites = "2401.00001")],
              "p2" => [ref("C. P. Okafor and J. Lind, Anneal: a method for stochastic search, arXiv:1412.6980 (2014)"; arxiv = "1412.6980"),
                       ref("In the knowledge base"; arxiv = "2401.00001", cites = "2401.00001")],
              "p3" => [ref("Marsh, A. H. 2015 Ecol. Lett. 22, 032505"), ref("Cited once, 2020, 12, 345")]]
    works = cited_works(citing)
    @test [w.key for w in works] == ["arxiv:1412.6980", "ref:2015:22:32505"]   # cited twice; matched and once-cited left out
    @test works[1].cited_by == ["p1", "p2"] && startswith(works[1].text, "C. P. Okafor")          # the fuller reference
    @test length(cited_works(citing; min_cited = 1)) == 3
    # Cited by DOI in one paper and by journal and page alone in another: one work, cited twice.
    review = cited_works(["p1" => [ref("P. Iles, Rep. Prog. Phys. 77, 087001 (2014), doi:10.1088/0034-4885/77/8/086901"; doi = "10.1088/0034-4885/77/8/086901")],
                          "p2" => [ref("Iles, P. 2014 Theory of reef resilience. Rep. Prog. Phys. 77, 087001.")]])
    @test only(review).key == "doi:10.1088/0034-4885/77/8/086901" && only(review).cited_by == ["p1", "p2"]

    # Works cited only by DOI, looked up on arXiv once, then offered by their arXiv id; one the
    # knowledge base holds already is not missing.
    kb = open_kb(temp_config())
    add_papers!(kb, ["2108.03771"])
    asked = String[]
    lookup(dois, contact) = (append!(asked, dois); Dict("10.1/a" => "2108.03771", "10.1/b" => "2201.00001", "10.1/c" => nothing))
    @test find_on_arxiv!(kb, ["10.1/A", "10.1/b", "10.1/c", "10.1/d"]; lookup) == 2
    @test find_on_arxiv!(kb, ["10.1/a", "10.1/e"]; lookup) == 0 && asked[end] == "10.1/e"   # asked once
    works = [CitedWork(; key = "doi:10.1/$x", doi = "10.1/$x", text = x, cited_by = ["p1", "p2"]) for x in ("a", "b", "c")]
    @test [(w.key, w.arxiv) for w in K.on_arxiv(kb, works)] == [("doi:10.1/b", "2201.00001"), ("doi:10.1/c", nothing)]
    @test K.on_arxiv(kb, [CitedWork(; key = "arxiv:2108.03771", arxiv = "2108.03771", text = "held")]) == []
    close(kb)
    # Where OpenAlex says a work is posted, read as an arXiv id.
    m(url) = parse_arxiv_id(url).id
    @test m("http://arxiv.org/abs/2108.03771") == "2108.03771" && m("https://doi.org/10.48550/arxiv.2108.03771") == "2108.03771"
    @test m("https://arxiv.org/abs/solv-int/9901001v2") == "solv-int/9901001"
end

@zset "paper of the day" begin
    # Where a figure is: above its caption, down to the nearest paragraph above it; labels inside a
    # figure (short text, or long text read as an equation or footnote) do not bound it.
    b(kind, page, x0, y0, x1, y1, text) = (; kind, page, x0, y0, x1, y1, text)
    blocks = [b("caption", 2, 72.0, 300.0, 520.0, 340.0, "Figure 3 follows the currents across the reef, read as a caption."),
              b("paragraph", 3, 72.0, 70.0, 520.0, 140.0, repeat("A paragraph of the paper's text. ", 4)),
              b("paragraph", 3, 120.0, 200.0, 130.0, 210.0, "x"),
              b("equation", 3, 80.0, 220.0, 500.0, 300.0, repeat("Z φ · N FP/2π = 0.000 ", 4)),
              b("footnote", 3, 400.0, 310.0, 500.0, 330.0, repeat("initial optimized ", 4)),
              b("caption", 3, 72.0, 400.0, 520.0, 430.0, "Figure 3. Coral cover across the reef."),
              b("caption", 4, 300.0, 300.0, 520.0, 320.0, "Fig. 4: a narrow one."),
              b("paragraph", 4, 300.0, 100.0, 520.0, 200.0, repeat("Column text that sits above the figure. ", 3)),
              b("paragraph", 4, 72.0, 250.0, 290.0, 290.0, repeat("The other column, beside it. ", 3))]
    r = K.figure_region(blocks, "Figure 3")
    @test r.page == 3 && (r.y0, r.y1) == (142.0, 398.0) && (r.x0, r.x1) == (72.0, 520.0) && startswith(r.caption, "Figure 3.")  # the caption, not the paragraph
    n = K.figure_region(blocks, "Figure 4")
    @test n.page == 4 && (n.x0, n.x1) == (294.0, 526.0) && n.y0 == 202.0               # its column, not the one beside it
    @test K.figure_region(blocks, "Figure 9") === nothing
    @test K.parse_figure_label("Fig. 2b") == ("figure", 2) && K.parse_figure_label("Table II.") == ("table", 2)
    @test K.parse_figure_label("3") == ("figure", 3) && K.parse_figure_label("FIGURE 12: the reef") == ("figure", 12)
    @test K.parse_figure_label("the reef") === nothing
    @test occursin(r"^\d{4}-\d{2}-\d{2}$", K.utc_today())

    # The judge reads the best placed new papers together; the pick comes from those it promoted.
    asked = String[]
    port = 19000 + rand(0:999)
    chat = K.HTTP.serve!("127.0.0.1", port) do req
        K.HTTP.URI(req.target).path == "/v1/models" && return K.HTTP.Response(200, "{}")
        prompt = string(K.JSON.parse(String(req.body))["messages"][end]["content"])
        push!(asked, prompt)
        reply = occursin("New papers:", prompt) ?
            Dict("papers" => filter(p -> occursin("[$(p["id"])]", prompt),         # those it was given
                                    [Dict("id" => "2610.00001", "relevance" => 3, "reason" => "A reef survey design."),
                                     Dict("id" => "2610.00002", "relevance" => 1, "reason" => "Tangential.")])) :
            Dict("id" => match(r"Candidates:\n\n\[([^\]]+)\]", prompt)[1], "why" => "It bears on the reef study.", "relevance" => 1)
        K.HTTP.Response(200, K.JSON.json(Dict("choices" => [Dict("message" => Dict("content" => K.JSON.json(reply)))])))
    end
    try
        s = Summarizer(; name = "judge-t", url = "http://127.0.0.1:$port/v1", model = "m")
        kb = open_kb(temp_config(; layers = Layer[], summarizers = [s], summarizer = "judge-t", code_summarizer = "judge-t", judge = "judge-t"))
        for (id, score) in (("2610.00001", 0.7), ("2610.00002", 0.6))
            K.execute!(kb, "INSERT INTO watch (doc_id, title, authors, abstract, published, category, score, area, area_score, nearest, found_at) VALUES (?, ?, '[]', 'About it.', '2026-10-01', 'physics.ao-ph', ?, 'Corals', 0.5, '[]', ?)",
                       (id, "Paper $id", score, K.now_iso()))
        end
        @test judge_watched!(kb; batch = 1) == 2 && length(asked) == 2                # every paper, a batch at a time
        @test occursin("Paper 2610.00002", asked[end]) && occursin(kb.config.group.description, asked[end])
        @test judge_watched!(kb) == 0                                              # judged once
        @test [(w.id, w.relevance) for w in watched(kb)] == [("2610.00001", 3), ("2610.00002", 1)]
        @test [c.id for c in K.daily_candidates(kb)] == ["2610.00001"]             # only the promoted, no unread papers yet
        p = pick_daily!(kb; day = "2026-10-02")
        @test p.id == "2610.00001" && p.source == "new" && occursin("Candidates:", asked[end])
        @test p.relevance == 3                                                      # the judge's rating of the new paper, kept
        @test isempty(K.daily_candidates(kb))                                       # picked once, not again
        # A library paper is rated as it is picked.
        add_papers!(kb, ["2401.00003"])
        K.execute!(kb, "UPDATE papers SET title = 'Unread' WHERE doc_id = '2401.00003'")
        lib = pick_daily!(kb; day = "2026-10-03")
        @test lib.id == "2401.00003" && lib.source == "library" && lib.relevance == 1
        @test K.scalar(kb, "SELECT relevance FROM daily WHERE day = '2026-10-03'") == 1
        K.execute!(kb, "DELETE FROM daily WHERE day = '2026-10-03'")
        @test_throws "can only have its paper analysed again" K.start_daily(kb; day = "2026-10-01")

        # The pages: the day's paper, its figures and its analysis, citations as links and mathematics as
        # written; a figure not cut is left out; each day has its page, linked to the days either side.
        add_papers!(kb, ["2610.00001", "2401.00001"])
        K.execute!(kb, "UPDATE papers SET title = 'A library paper' WHERE doc_id = '2401.00001'")
        figs = K.JSON.json([Dict("label" => "Figure 3", "why" => "The main result.", "file" => "2610-00001-1.png"),
                            Dict("label" => "Figure 9", "why" => "Not found.")])
        K.execute!(kb, """UPDATE daily SET status = 'done', analysis = ?, figures = ?, computable = ? WHERE day = '2026-10-02'""",
                   ("## What it does\nIt builds on [arXiv:2401.00001; arXiv:2999.00001], with {{ x }} < 1 where \$\\beta < 1\$.\n\n```math\n\\kappa = \\{a\\} < 2\n```\n",
                    figs, K.JSON.json(Dict("tractable" => true, "idea" => "Evaluate the scaling."))))
        K.execute!(kb, "INSERT INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at) VALUES ('2026-10-01', '2401.00001', 'library', 'Earlier.', 'done', 'Text.', '[]', '{}', ?)", (K.now_iso(),))
        # The landing page shows the latest day; each day's page is made from a template and its data file.
        days = K.daily_pages(kb, dailies(kb))
        pages, data = Dict(days.pages), Dict(days.data)
        @test Set(keys(pages)) == Set(["daily.md", "daily/2026-10-02/index.md", "daily/2026-10-01/index.md"])
        @test occursin("<KBDayPage latest />", pages["daily.md"]) && pages["daily/2026-10-01/index.md"] == K.template_markdown("daily")
        main = data["2026-10-02/index"]
        @test [f["label"] for f in main["figures"]] == ["Figure 3"]                   # one without a file is left out
        # A pick the analysis never mentions comes first; the analysis's sections under the paper's heading.
        @test main["analysis"][1] == Dict("figure" => 0) && startswith(main["analysis"][2]["text"], "### What it does")
        # For agents: the latest day's paper with its analysis and figures, or another day's, and the days with one.
        latest = K.format_daily(kb)
        @test startswith(latest, "Paper of the day, 2026-10-02: ") && occursin("## Analysis", latest) && occursin("- Figure 3", latest)
        @test occursin("- 2026-10-01: A library paper (arXiv:2401.00001)", latest)
        @test startswith(K.format_daily(kb, "2026-10-01"), "Paper of the day, 2026-10-01: A library paper")
        # Its relevance heads its page, as rated when picked; a day without one shows none.
        @test main["relevance"] == Dict("level" => 3, "label" => "central", "note" => "")
        @test occursin("Relevance to the group: 3 of 3, central", latest)
        @test data["2026-10-01/index"]["relevance"] === nothing && !occursin("Relevance", K.format_daily(kb, "2026-10-01"))
        # Once the paper is classified, the rating from its full text stands instead.
        K.execute!(kb, "INSERT INTO classifications VALUES (?, 'judge-t', 'm', ?, ?)",
                   (K.paper_id(kb, "2610.00001"), K.JSON.json(Dict("relevance" => 2, "relevance_note" => "Touches the reef work.")), K.now_iso()))
        @test Dict(K.daily_pages(kb, dailies(kb)).data)["2026-10-02/index"]["relevance"] ==
              Dict("level" => 2, "label" => "related", "note" => "Touches the reef work.")
        @test occursin("Relevance to the group: 2 of 3, related. Touches the reef work.", K.format_daily(kb))
        # The paper's page says it was the paper of the day, linking to that day.
        K.record_arrival!(kb, K.paper_id(kb, "2610.00001"), "daily")
        post = only(p for p in K.paper_json(K.site_paper(kb, "2610.00001"; related = false))["posts"] if p["source"] == "daily")
        @test post["day"] == "2026-10-02" && post["where"] == "Picked as paper of the day" && post["on"] == "2 October 2026"
        K.execute!(kb, "DELETE FROM classifications")
        # From a service, with the addresses of the day's page and its figures, to link to.
        linked = K.format_daily(kb; site = "https://kb.example.org")
        @test occursin("Page: https://kb.example.org/generated/kb/daily/2026-10-02/index.html", linked)
        @test occursin("  Image: https://kb.example.org/api/daily/2026-10-02/2610-00001-1.png", linked) && !occursin("Page: ", latest)
        figure(target) = K.respond_local(kb, K.HTTP.Request("GET", target))
        mkpath(K.figures_dir(kb.config, "2610.00001"))
        write(joinpath(K.figures_dir(kb.config, "2610.00001"), "2610-00001-1.png"), UInt8[0x89, 0x50, 0x4e, 0x47])
        @test figure("/api/daily/2026-10-02/2610-00001-1.png").body == UInt8[0x89, 0x50, 0x4e, 0x47]
        @test figure("/api/daily/2026-10-02/nothing.png").status == 404 && figure("/api/daily/2026-10-02/..%2Fx.png").status == 404
        # And the figures' images, as cut, in that order: those whose files are here.
        mkpath(K.figures_dir(kb.config, "2610.00001"))
        write(joinpath(K.figures_dir(kb.config, "2610.00001"), "2610-00001-1.png"), UInt8[0x89, 0x50, 0x4e, 0x47])
        @test [(f.bytes, f.type) for f in K.daily_figures(kb)] == [(UInt8[0x89, 0x50, 0x4e, 0x47], "image/png")]
        @test isempty(K.daily_figures(kb, "2026-10-01"))
        @test startswith(K.format_daily(kb, "2026-09-30"), "No paper of the day on 2026-09-30. Days with one: 2026-10-02, 2026-10-01")
        @test K.daily_json(dailies(kb)) == [Dict("day" => "2026-10-02", "id" => "2610.00001", "title" => "2610.00001"),
                                            Dict("day" => "2026-10-01", "id" => "2401.00001", "title" => "A library paper")]
        # Its citations link to the papers' pages (or arXiv); its mathematics stays as written, for the page to render.
        text = main["analysis"][2]["text"]
        @test occursin("([A library paper](/generated/kb/papers/2401-00001.html); [arXiv:2999.00001](https://arxiv.org/abs/2999.00001))", text)
        @test occursin("{{ x }} < 1 where \$\\beta < 1\$", text) && occursin("```math\n\\kappa = \\{a\\} < 2\n```", text)
        @test main["idea"] == "Evaluate the scaling."
        @test main["before"] == Dict("day" => "2026-10-01", "title" => "A library paper") && main["after"] === nothing
        @test data["2026-10-01/index"]["after"]["day"] == "2026-10-02"
        # A paper's notebooks: made by the agent, attached by someone, or found in its folder (from a
        # clone); each shown on its day's page and its own, with a link to download it.
        docs = kb.config.content_dir
        try
            nbdir = mkpath(joinpath(docs, "notebooks", "papers", "2610-00001"))
            write(joinpath(nbdir, "computed-1.jl"), "#%% md id=a\n@md\"\"\"\n# Equivalent reefs\n\"\"\"\n")
            K.execute!(kb, "INSERT INTO notebooks (doc_id, path, kind, title, status, summary, idea, started_at) VALUES ('2610.00001', 'notebooks/papers/2610-00001/computed-1.jl', 'agent', 'Equivalent reefs', 'done', 'It computes them.', 'Evaluate Eq. 3.6\nfor the fore reef, with \$\\bar\\eta < 0\$.', ?)", (K.now_iso(),))
            K.execute!(kb, "INSERT INTO notebooks (doc_id, path, kind, status, started_at) VALUES ('2610.00001', 'notebooks/papers/2610-00001/computed-2.jl', 'agent', 'failed: no', ?)", (K.now_iso(),))
            rel = add_notebook!(kb, "2610.00001", "#%% code id=x\n1 + 1\n"; name = "My Scan!.jl", title = "A scan", added_by = "Ada")
            @test rel == "notebooks/papers/2610-00001/my-scan.jl"
            @test add_notebook!(kb, "2610.00001", "x"; name = "My Scan!.jl") == "notebooks/papers/2610-00001/my-scan-2.jl"   # a name taken gets a number
            # Unique across the papers too, as the site shows each notebook under its name alone.
            @test add_notebook!(kb, "2401.00001", "x"; name = "My Scan!.jl") == "notebooks/papers/2401-00001/my-scan-3.jl"
            @test basename(K.free_notebook_file(kb, K.notebook_dir(kb.config, "2401.00001"), "computed"; numbered = true)) == "computed-3.jl"
            write(joinpath(nbdir, "from-a-clone.jl"), "#%% md id=a\n@md\"\"\"\n# Shared work\n\"\"\"\n")
            nbs = paper_notebooks(kb, "2610.00001")
            @test [(n.title, n.kind) for n in nbs][1:3] == [("Equivalent reefs", "agent"), ("A scan", "upload"), ("my scan 2", "upload")]
            @test ("Shared work", "shared") in [(n.title, n.kind) for n in nbs] && !any(n -> endswith(n.path, "computed-2.jl"), nbs)
            @test [s.status for s in K.notebook_states(kb, "2610.00001")][1:2] == ["done", "failed: no"]
            # The paper's page lists them; each has a page of its own under the paper's, which the day links to.
            listed = Dict(K.daily_pages(kb, dailies(kb)).data)["2026-10-02/index"]["notebooks"]
            @test any(n -> (n["title"], n["page"], n["by"], n["summary"]) == ("Equivalent reefs", "computed-1", "made by an agent", "It computes them."), listed)
            @test any(n -> n["title"] == "A scan" && n["by"] == "added by Ada", listed)
            listed = K.paper_json(K.site_paper(kb, "2610.00001"; related = false); notebooks = nbs)["notebooks"]
            @test any(n -> n["title"] == "Shared work" && n["page"] == "from-a-clone" && n["by"] == "added", listed)
            @test any(n -> n["title"] == "A scan" && n["by"] == "added by Ada", listed)
            nbpage = K.notebook_page(first(nbs), "2610.00001", "Paper 2610.00001")
            @test occursin("<p><em>A notebook from <a href=\"../2610-00001.html\">Paper 2610.00001</a>, made by an agent.</em></p>", nbpage)
            @test occursin("<KBDownload src=\"/notebooks/papers/2610-00001/computed-1.jl\">", nbpage)
            @test occursin("```@slate ../../../../../notebooks/papers/2610-00001/computed-1.jl\n```", nbpage)
            @test withenv(() -> !occursin("@slate", K.notebook_page(first(nbs), "2610.00001", "P")), "ZEMI_SITE_NOTEBOOKS" => "0")
            @test occursin("**Asked to compute:**\n\n> Evaluate Eq. 3.6\n> for the fore reef, with ``\\bar\\eta < 0``.", nbpage)   # the prompt, its math as math
            @test !occursin("Asked to compute", K.notebook_page(nbs[2], "2610.00001", "P"))             # an attached one has none
            @test "mcp__kaimon__slate_run" in K.notebook_tools() && !any(startswith("Read"), K.notebook_tools())
            @test withenv(() -> "mcp__kaimon__slatembse_open" in K.notebook_tools(), "ZEMI_NOTEBOOK_HUB" => "slatembse")
            p = K.notebook_prompt("x.jl", "", "slatembse"; others = ["Equivalent reefs"])
            @test occursin("mcp__kaimon__slatembse_", p) && occursin("Decide what in the paper", p) && occursin("Compute something they do not", p)
        finally
        end
        close(kb)
    finally
        close(chat)
    end
end

@zset "bibliography" begin
    kb = open_kb(temp_config())
    add_papers!(kb, ["2609.00001"])
    K.execute!(kb, """UPDATE papers SET title = 'Reef & lagoon', authors = '["Ada Lovelace", "Reef Survey Team"]',
                      published = '2026-09-01', primary_category = 'physics.ao-ph'""")
    K.execute!(kb, """INSERT INTO papers (doc_id, title, authors, added_at, kind)
                      VALUES ('doc-0123456789', 'A handbook', '[]', '2026-10-01', 'paper'),
                             ('code-0123456789', 'A codebase', '[]', '2026-10-01', 'code')""")
    bib = bibliography(kb)
    @test startswith(bib, "% The documents of the knowledge base: 2 entries.")
    @test occursin("@article{arXiv:2609.00001,", bib) && occursin("author = {Lovelace, Ada and {Reef Survey Team}}", bib)
    @test occursin("title = {{Reef \\& lagoon}}", bib) && occursin("url = {https://arxiv.org/abs/2609.00001}", bib)
    @test occursin("@misc{doc-0123456789,\n  title = {{A handbook}},\n}", bib)   # an upload: its own key, no arXiv fields
    @test !occursin("code-", bib) && !occursin("docpage", bib)                # no codebases; no docs-site paths
    @test occursin("docpage = {generated/kb/papers/2609-00001.md}", bib_entry(kb, "2609.00001"))
    # In prose: a preprint in its arXiv record; an upload with no authors or date, led by its title, at its page here.
    @test K.citation(kb, "2609.00001") ==
          "Lovelace, A., & Reef Survey Team. (2026). Reef & lagoon. arXiv preprint arXiv:2609.00001. https://arxiv.org/abs/2609.00001"
    @test K.citation(kb, "doc-0123456789") == rstrip("A handbook. (n.d.). " * K.document_link(kb.config, "doc-0123456789"))
    c = K.cite_json(kb, "2609.00001")
    @test c["reference"] == "@arXiv:2609.00001" && c["bibtex"] == bib_entry(kb, "2609.00001"; docpage = false)
    close(kb)
end

@zset "codebase" begin
    dir = mktempdir()
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "README.md"), "# Demo\n\nA demo package that adds numbers.\n\n## Use\n\nCall add.\n")
    write(joinpath(dir, "src", "Demo.jl"), """
        module Demo

        \"\"\"Add two numbers.\"\"\"
        add(a, b) = a + b

        # The product, for when adding is not enough.
        mul(a, b) = a * b

        struct Point
            x::Int
        end

        end
        """)
    write(joinpath(dir, "data.bin"), "not code")
    write(joinpath(dir, "Manifest.toml"), "# generated")
    # A link, which could lead out of the codebase to anything on the machine, is not read.
    outside = joinpath(mktempdir(), "secret.toml"); write(outside, "key = \"s3cret\"")
    symlink(outside, joinpath(dir, "notes.toml"))
    @test K.code_files(dir) == ["README.md", "src/Demo.jl"]
    parsed, abstract, sha = K.parse_codebase(dir)
    @test abstract == "A demo package that adds numbers."
    @test [s.title for s in parsed.sections] == ["README.md", "src/Demo.jl", "src/"]   # files first, then directories
    @test [s.level for s in parsed.sections] == [1, 2, 1]
    code = [x.text for x in parsed.pieces if x.section == 2]
    @test any(t -> occursin("Add two numbers", t) && occursin("add(a, b)", t), code)            # docstring with its definition
    @test any(t -> occursin("# The product", t) && occursin("mul(a, b)", t), code)             # comment with its definition
    @test !any(t -> occursin("add(a, b)", t) && occursin("mul(a, b)", t), code)
    @test length(K.chunk_code(parsed)) >= 2

    kb = open_kb(temp_config(layers = Layer[]))
    id = add_codebase!(kb, dir; name = "Demo.jl")
    @test id == "code-demo" && K.document_kind(id) === K.CODEBASE
    @test K.parse_code!(kb, id) && !K.parse_code!(kb, id)                 # unchanged files are not read again
    write(joinpath(dir, "src", "Demo.jl"), read(joinpath(dir, "src", "Demo.jl"), String) * "\nsub(a, b) = a - b\n")
    @test K.parse_code!(kb, id)
    @test occursin("sub(a, b)", K.read_paper(kb, id; section = "Demo"))
    @test only(list_documents(kb; state = "code").documents).id == id

    # Browsing: a tree with directories before files, and definitions named with their docstrings.
    tree = K.code_tree(kb, id)
    @test [c["name"] for c in tree["children"]] == ["src/", "README.md"]
    demo = only(tree["children"][1]["children"])
    @test demo["page"] == "src_Demo_jl" && demo["definitions"] > 0
    defs = K.file_definitions(kb, id, "src/Demo.jl")
    @test [d.name for d in defs] == ["Demo", "add", "mul", "Point", "sub"]
    @test only(d for d in defs if d.name == "add").doc == "Add two numbers."
    @test startswith(only(d for d in defs if d.name == "mul").doc, "The product")
    @test K.code_stats(kb, id).files == 2
    # A file's page is made from its data file: its place, and each definition with its source.
    page = K.code_file_json(kb, only(K.query(kb, "SELECT * FROM papers WHERE doc_id = ?", (id,))), demo)
    @test page["codebase"]["slug"] == "code-demo" && page["path"] == "src/Demo.jl" && page["dirs"] == ["src"] && page["fence"] == "julia"
    @test [d["name"] for d in page["definitions"]] == ["Demo", "add", "mul", "Point", "sub"] && page["notebook"] === nothing
    @test endswith(only(d for d in page["definitions"] if d["name"] == "add")["source"], "add(a, b) = a + b")

    # Sync: a changed codebase is read again, a bare record needs its metadata, and only with
    # `unread` is a recorded paper read.
    add_papers!(kb, ["2609.00001"])
    actions(plan) = Set((t.id, t.action) for t in plan)
    @test actions(sync_plan(kb)) == Set([(id, :classify), ("2609.00001", :metadata)])
    # A classification by another model than the configured summarizer is out of date too.
    classified_by(name) = K.execute!(kb, "INSERT OR REPLACE INTO classifications VALUES (?, ?, 'm', '{}', ?)",
                                     (K.paper_id(kb, id), name, K.now_iso()))
    classified_by("another-model")
    @test only(t for t in sync_plan(kb) if t.action == :classify).reason == "classified by another-model"
    classified_by(kb.config.summarizer)
    @test !any(t -> t.action == :classify, sync_plan(kb))
    K.execute!(kb, "DELETE FROM classifications")
    @test ("2609.00001", :ingest) in actions(sync_plan(kb; unread = true))
    write(joinpath(dir, "src", "More.jl"), "more() = 1\n")
    plan = sync_plan(kb)
    @test only(t for t in plan if t.action == :ingest).reason == "files changed"
    r = sync!(kb; arxiv = false, classify = false, plan = filter(t -> t.action == :ingest, plan))
    @test only(r.ingested).ok && only(r.ingested).parsed && isempty(r.failed)
    @test !any(t -> t.action == :ingest, sync_plan(kb))
    mv(dir, dir * "-moved")
    @test only(t for t in sync_plan(kb) if t.id == id).action == :missing
    close(kb)
end

@zset "records" begin
    HTTP, JSON = K.HTTP, K.JSON
    prompts = String[]
    port = 18000 + rand(0:999)
    # A stand-in summarizer that keeps what it is asked.
    server = HTTP.serve!("127.0.0.1", port) do req
        body = JSON.parse(String(req.body))
        push!(prompts, body["messages"][1]["content"] * "\n" * body["messages"][2]["content"])
        reply = occursin("Summaries of its parts:", prompts[end]) ?
                "Rowan reported the pump held.\nDecided: rerun it\nOpen: the seal\nActions: Bea: rerun\nTouched: none\nTopics: pumps, seals" :
                "Rowan reported a pressure."
        HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => reply))])))
    end
    s = Summarizer(; name = "fake", url = "http://127.0.0.1:$port", model = "fake-model")
    kb = open_kb(temp_config(summarizers = [s], summarizer = "fake", code_summarizer = "fake", judge = "fake", layers = Layer[]))
    try
        png = tempname() * ".png"
        K.PNGFiles.save(png, fill(K.RGB{K.N0f8}(0.2, 0.4, 0.6), 20, 30))
        K.create_project!(kb, "Pumps"; key = "PU", owner = nothing, by = K.person("Ada"))
        K.create_project!(kb, "Seals"; key = "SE", owner = nothing, by = K.person("Bea"))
        long = repeat("Rowan reported that the pump held three bar through the morning run. ", 6)
        meeting(; kw...) = (; key = "2026-10-02 pump test", title = "Pump test review", date = "2026-10-02T14:00",
                              people = ["Ada", "Rowan", "Bea"],
                              sections = ["Results" => "$long\n\n![](screen-1)\n\n## Next\n\nBea will rerun it.",
                                          (heading = "Open", text = "Whether the seal lasts.")],
                              figures = [(; name = "screen-1", caption = "Pressure over time", image = png)],
                              transcript = [(; speaker = "Rowan", start = 0, stop = 4.5, text = "It held three bar.")],
                              projects = ["PU"], kw...)

        # What a source hands in is checked before anything is written.
        @test_throws "needs a title" put_record!(kb, "notes", meeting(title = " "))
        @test_throws "ISO 8601" put_record!(kb, "notes", meeting(date = "next Tuesday"))
        @test_throws "No such day" put_record!(kb, "notes", meeting(date = "2026-02-30"))
        @test_throws "not a PNG, JPEG or WebP" put_record!(kb, "notes", meeting(figures = [(; name = "x", caption = "", image = b"GIF89a....")]))
        @test_throws "same name" put_record!(kb, "notes", meeting(figures = [(; name = "x", caption = "", image = png),
                                                                             (; name = "x", caption = "", image = png)]))
        @test_throws "later one" put_record!(kb, "notes", meeting(transcript = [(; speaker = "Ada", start = 5, stop = 1, text = "")]))
        @test_throws "a section" put_record!(kb, "notes", meeting(sections = []))
        @test_throws "access" put_record!(kb, "notes", meeting(access = "everyone"))
        @test_throws "lower case" put_record!(kb, "Notes!", meeting())
        @test_throws "No project XX" put_record!(kb, "notes", meeting(projects = ["XX"]))
        @test isempty(K.query(kb, "SELECT 1 FROM papers"))

        # The same source and key always name one record; an id is made safe and short.
        @test K.record_id("notes", "2026-10-02") == "rec-notes-2026-10-02"
        @test K.record_id("notes", "Pump Test") == K.record_id("notes", "Pump Test") != K.record_id("notes", "pump-test")
        @test length(K.record_id("notes", "a"^300)) <= K.RECORD_ID_MAX && K.record_id("notes", "a"^300) != K.record_id("notes", "a"^299)
        id, changed = put_record!(kb, "notes", meeting(); read = false)
        @test changed && K.document_kind(id) === K.RECORD && id == K.record_id("notes", "2026-10-02 pump test")
        @test put_record!(kb, "notes", meeting(); read = false) == (id, false)          # unchanged: skipped
        p = K.paper_row(kb, id)
        @test p.kind == "record" && p.access == "projects" && K.json_list(p.authors) == ["Ada", "Rowan", "Bea"] && p.published == "2026-10-02"
        @test occursin("2 October 2026, with Ada, Rowan and Bea", p.abstract)
        r = K.record_row(kb, id)
        @test r.source == "notes" && r.key == "2026-10-02 pump test" && r.happened == "2026-10-02T14:00:00" && r.label == "From notes"
        @test K.document_projects(kb, id) == ["PU"] && isfile(K.record_file(kb.config, id))
        @test only(K.mentions(kb, id)).source == "notes"
        # Its figure is its own, a WebP image, captioned.
        @test only(K.paper_figures(kb, id)) == (; kind = "figure", number = 1, label = "screen-1", caption = "Pressure over time", file = "fig-1.webp")
        @test readdir(K.figures_dir(kb.config, id)) == ["fig-1.webp"] && K.image_size(joinpath(K.figures_dir(kb.config, id), "fig-1.webp")) == (30, 20)

        # Read, it is sections, blocks and passages, its figure placed where its text places it, its
        # transcript last; the reader's version is stored, so sync has nothing to read again.
        @test K.read_record!(kb, id) && !K.read_record!(kb, id)
        pid = K.paper_id(kb, id)
        @test [(x.title, x.path, x.level) for x in K.query(kb, "SELECT title, path, level FROM sections WHERE paper_id = ? ORDER BY ord", (pid,))] ==
              [("Results", "Results", 1), ("Next", "Results › Next", 3), ("Open", "Open", 1), ("Transcript", "Transcript", 1)]
        blocks = K.query(kb, "SELECT section, kind, text, x0, x1 FROM blocks WHERE paper_id = ? AND kind != 'heading' ORDER BY ord", (pid,))
        @test [(b.section, b.kind) for b in blocks] == [(1, "paragraph"), (1, "caption"), (2, "paragraph"), (3, "paragraph"), (4, "paragraph")]
        @test blocks[2].text == "Pressure over time" && blocks[5].text == "Rowan: It held three bar." && blocks[5].x1 == 4.5
        @test !isempty(K.query(kb, "SELECT 1 FROM chunks WHERE paper_id = ?", (pid,)))
        @test K.query(kb, "SELECT parser_version FROM parses WHERE paper_id = ?", (pid,))[1].parser_version == K.PARSER_VERSION
        @test !any(t -> t.id == id && occursin("parsed", t.reason), sync_plan(kb))
        @test !any(t -> t.id == id && t.action == :classify, sync_plan(kb))                    # records are not classified
        @test_throws "not classified" K.classify!(kb, id)

        # Summarized with a record's prompts: what was said, by whom, and not as established.
        @test summarize_paper!(kb, s, id) >= 2
        @test all(x -> occursin("records of a research group's own discussions", x), prompts)
        @test any(x -> occursin("Attribute each claim", x) && occursin("Part: Results", x), prompts)
        @test any(x -> occursin("Decided:", x) && occursin("2 October 2026, with Ada, Rowan and Bea", x), prompts)
        # Agents are told what it is wherever they are given it.
        @test occursin("record of the group's own work, from 2 October 2026 (From notes), with Ada, Rowan and Bea",
                       K.record_note(kb, id))
        @test occursin("not as established", K.document_note(kb, id)) && K.document_note(kb, "2609.00001") == ""

        # Its people reordered and its label changed alone, it is written in place: not read again, its
        # summaries kept, its opening line saying who and how.
        n = K.scalar(kb, "SELECT count(*) FROM summaries WHERE paper_id = ?", (pid,))
        @test put_record!(kb, "notes", meeting(people = ["Bea", "Ada", "Rowan"], label = "Notes kept by hand"); read = false) == (id, true)
        @test occursin("with Bea, Ada and Rowan. Notes kept by hand.", K.paper_row(kb, id).abstract)
        @test !any(t -> t.id == id && t.action == :ingest, sync_plan(kb)) && !K.read_record!(kb, id)
        @test K.scalar(kb, "SELECT count(*) FROM summaries WHERE paper_id = ?", (pid,)) == n

        # Changed, it is written again and read again, keeping its id and its links; a new project is linked.
        K.link_document!(kb, id, "SE")
        changed_meeting = meeting(sections = ["Results" => "$long Bea disagreed."], figures = [], projects = ["PU"])
        @test put_record!(kb, "notes", changed_meeting; read = false) == (id, true)
        @test K.document_projects(kb, id) == ["PU", "SE"] && K.paper_row(kb, id).access == "projects"
        @test isempty(K.paper_figures(kb, id)) && isempty(readdir(K.figures_dir(kb.config, id)))
        @test occursin("its source changed it", only(t for t in sync_plan(kb) if t.id == id && t.action == :ingest).reason)
        # Queued, the job reading records reads it.
        job = K.queue_reading!(kb, [id])
        wait(job)
        @test job.status == :done && only(job.result).ok && only(job.result).parsed && id in job.ids
        @test occursin("Bea disagreed", K.read_paper(kb, id))
        @test K.READING.job[] === nothing

        # A source's records go with everything made from them.
        other, _ = put_record!(kb, "notes", meeting(key = "another"); read = false)
        K.read_record!(kb, other)
        kept, _ = put_record!(kb, "minutes", meeting(key = "another"); read = false)
        @test other != kept
        @test purge_source!(kb, "notes") == 2
        @test ismissing(K.paper_id(kb, id)) && ismissing(K.paper_id(kb, other)) && !isfile(K.record_file(kb.config, id))
        @test !isdir(K.figures_dir(kb.config, other)) && isempty(K.query(kb, "SELECT 1 FROM records x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)))
        @test isempty(K.query(kb, "SELECT 1 FROM chunks WHERE paper_id = ?", (pid,)))
        @test K.document_kind(kept) === K.RECORD && !ismissing(K.paper_id(kb, kept))
        delete_record!(kb, kept)
        @test ismissing(K.paper_id(kb, kept))
        @test_throws "not a record" delete_record!(kb, "2609.00001")
    finally
        close(server)
        close(kb)
    end
end

@zset "resources" begin
    kb = open_kb(temp_config(layers = Layer[]))
    try
        K.create_project!(kb, "Wetlands"; key = "WE", owner = nothing, by = K.person("Ada"))
        dem(; kw...) = K.Resource(; key = "AB12CD34", title = "Copernicus DEM GLO-30", type = "dataset", authors = ["ESA"],
                                     date = "2021", url = "https://example.org/dem", doi = "10.5270/ESA-c5d3d65", note = "Data set, CC BY 4.0",
                                     projects = ["WE"], kw...)
        @test_throws "needs a title" K.put_resource!(kb, "zotero", dem(title = " "))
        @test_throws "No project XX" K.put_resource!(kb, "zotero", dem(projects = ["XX"]))
        @test isempty(K.query(kb, "SELECT 1 FROM papers"))

        # A resource is a document of its own kind, its source's key naming it; unchanged, it is not written again.
        id, changed = K.put_resource!(kb, "zotero", dem())
        @test changed && id == "res-zotero-ab12cd34-" * bytes2hex(K.sha256("zotero\0AB12CD34"))[1:8] && K.is_resource(id)
        @test K.put_resource!(kb, "zotero", dem()) == (id, false)
        p = K.paper_row(kb, id)
        @test p.kind == "resource" && p.title == "Copernicus DEM GLO-30" && p.doi == "10.5270/esa-c5d3d65" && p.abstract == "Data set, CC BY 4.0"
        @test only(K.mentions(kb, id)).source == "zotero" && only(K.mentions(kb, id)).url == "https://example.org/dem"
        @test [(x.target, x.status) for x in K.library(kb, "WE")] == [(id, "kept")]

        # Read, it is one section of what it says about itself, searchable; it is not summarized or classified.
        @test only(K.query(kb, "SELECT title FROM sections WHERE paper_id = ?", (p.id,))).title == "Copernicus DEM GLO-30"
        text = join([r.text for r in K.query(kb, "SELECT text FROM chunks WHERE paper_id = ?", (p.id,))], "\n")
        @test occursin("dataset · ESA · 2021", text) && occursin("CC BY 4.0", text) && occursin("doi:10.5270/esa-c5d3d65", text)
        @test !any(t -> t.id == id, K.sync_plan(kb))
        @test K.document_note(kb, id) == "Resource (dataset) from zotero: title, authors, date and note only, not read in full."
        # What its source changes, it is read again for.
        K.put_resource!(kb, "zotero", dem(note = "Data set, CC BY 4.0; accessed November 2026"); read = false)
        @test only(t for t in K.sync_plan(kb) if t.id == id).reason == "its source changed it"

        # Cited with `@`, it is a paper's kind of source: kept in a library, and evidence for a finding.
        @test only(K.at_references("Elevation from @$id.")) == (; kind = "paper", target = id, label = id)
        @test K.evidence_source("@$id") == (; kind = "paper", target = id, page = 0)
        K.create_project!(kb, "Floods"; key = "FL", owner = nothing, by = K.person("Bea"))
        r, _ = K.put_resource!(kb, "zotero", K.Resource(; key = "EF56", title = "Bali flood facts so far", type = "news", projects = ["FL"],
                                                        container = "Tempo English", url = "https://example.org/floods?id=1_2");
                                proposed = true)
        @test [(x.target, x.status) for x in K.library(kb, "FL")] == [(r, "proposed")]
        # Cited: a news story is an article in its newspaper, its address as it is.
        bib = K.bib_entry(kb, r)
        @test startswith(bib, "@article{$r,") && occursin("journal = {Tempo English}", bib) && occursin("url = {https://example.org/floods?id=1_2}", bib)
        # In prose, as APA has it: a data set described, a work with no authors led by its title.
        @test K.citation(kb, id) == "ESA. (2021). Copernicus DEM GLO-30 [Data set]. https://doi.org/10.5270/esa-c5d3d65"
        @test K.citation(kb, r) == "Bali flood facts so far. (n.d.). Tempo English. https://example.org/floods?id=1_2"
        @test K.apa_name("Rowan A. Hale") == "Hale, R. A." && K.apa_name("Ng, Bea") == "Ng, B." && K.apa_name("World Bank", Set(["World Bank"])) == "World Bank"
        @test K.apa_authors(["Hale, R.", "Ng, B.", "Lee, A."]) == "Hale, R., Ng, B., & Lee, A." && K.apa_authors(["Hale, R.", "et al."]) == "Hale, R., et al."
        @test K.apa_authors(["N$i, A." for i in 1:25]) == join(["N$i, A." for i in 1:19], ", ") * ", … N25, A."
        K.put_resource!(kb, "zotero", K.Resource(; key = "GH78", title = "Rainfall records", type = "data portal", authors = ["Rowan Hale"],
                                                 publisher = "Weather Office", url = "https://example.org/rain", accessed = "2026-11-05"); read = false)
        @test K.citation(kb, K.resource_id("zotero", "GH78")) ==
              "Hale, R. (n.d.). Rainfall records [Data portal]. Weather Office. Retrieved November 5, 2026, from https://example.org/rain"
        K.put_resource!(kb, "zotero", K.Resource(; key = "IJ90", title = "Land cover", type = "dataset", authors = ["Weather Office"],
                                                 organizations = ["Weather Office"], publisher = "Weather Office", date = "2022"); read = false)
        @test K.citation(kb, K.resource_id("zotero", "IJ90")) == "Weather Office. (2022). Land cover [Data set]."

        # On the site: a page of each from its data, and the page listing them, linked from the sidebar.
        site, public = mktempdir(), mktempdir()
        nav = K.write_site(kb, site, public; related = false)
        @test nav.resources == "resources.md" && K.site_from_json(K.site_json(nav)).resources == "resources.md"
        d = K.JSON.parsefile(joinpath(public, "kb-data", "resources", K.page_slug(id) * ".json"))
        @test d["title"] == "Copernicus DEM GLO-30" && d["type"] == "dataset" && d["doi"] == "10.5270/esa-c5d3d65" && d["source"] == "zotero"
        @test d["cite"]["reference"] == "@$id" && startswith(d["cite"]["citation"], "ESA. (2021).") && startswith(d["cite"]["bibtex"], "@misc{$id,")
        @test isfile(joinpath(site, "resources", K.page_slug(id) * ".md")) && K.document_page(id) == "resources/$(K.page_slug(id))"
        @test [x["title"] for x in K.JSON.parsefile(joinpath(public, "resources.json"))] == ["Bali flood facts so far", "Copernicus DEM GLO-30", "Land cover", "Rainfall records"]

        # Its PDF uploaded, a resource becomes a paper: what named it names the paper, and its id leads there.
        me = K.person("Ada")
        t = K.create_task!(kb, "WE", "Map the catchment"; body = "From @$id.", by = me)
        f = K.create_finding!(kb, "WE", "The catchment drains south"; evidence = [(; kind = "paper", target = id)], by = me)
        dir = mktempdir()
        write(joinpath(dir, "dem.txt"), "%%MediaBox 0 0 612 792\n%%Font F1 Helvetica\nBT /F1 10 Tf 72 700 Td (Elevation tiles.) Tj ET\n")
        run(`mutool create -o $(joinpath(dir, "dem.pdf")) $(joinpath(dir, "dem.txt"))`)
        paper = K.promote_resource!(kb, id, joinpath(dir, "dem.pdf"); by = "Ada")
        q = K.paper_row(kb, paper)
        @test startswith(paper, "doc-") && q.title == "Copernicus DEM GLO-30" && q.doi == "10.5270/esa-c5d3d65" && q.published == "2021"
        @test ismissing(K.paper_id(kb, id)) && K.current_document(kb, id) == paper && K.current_document(kb, paper) == paper
        @test [x.target for x in K.library(kb, "WE")] == [paper]
        @test any(l -> l.kind == "paper" && l.target == paper, K.task(kb, t).links)
        @test only(K.finding(kb, f).evidence).target == paper
        # A mention of its old id still names the paper.
        K.update_task!(kb, t; body = "From @$id, again.", by = me)
        @test count(l -> l.kind == "paper", K.task(kb, t).links) == 1
        @test_throws "No resource" K.promote_resource!(kb, id, joinpath(dir, "dem.pdf"))
        K.write_site(kb, site, public; related = false)
        @test K.JSON.parsefile(joinpath(public, "kb-data", "resources", K.page_slug(id) * ".json")) == Dict("moved" => K.document_page(paper))
    finally
        close(kb)
    end
end

@zset "record sources" begin
    kb = open_kb(temp_config(layers = Layer[], sources = Dict{String,Any}("zz-fake" => Dict{String,Any}("folder" => "/notes", "token" => "file:/nowhere"))))
    saved, stop = K.SOURCES[], Ref(false)
    K.READ_PUT[] = false
    waitfor(f; timeout = 30) = timedwait(f, timeout; pollint = 0.05) == :ok
    try
        K.create_project!(kb, "Pumps"; key = "PU", owner = nothing, by = K.person("Ada"))
        # The registry: a name registered again is replaced; a source for another interface is refused.
        noop(run) = nothing
        n = length(K.SOURCES[])
        record_source!("zz-notes"; label = "Written up by Notetaker", every = 60, poll = noop, api = K.PLUGIN_API)
        s = record_source!("zz-notes"; label = "Written up by Notetaker from recordings", every = K.Dates.Minute(5), poll = noop,
                           api = K.PLUGIN_API)
        @test length(K.SOURCES[]) == n + 1 && K.registered_source("zz-notes") === s
        @test s.every == 300 && s.modes == [:local, :shared] && s.budget == K.DEFAULT_BUDGET && s.plugin == ""
        @test_throws "plugin interface 2, and this Zemi's is 1" record_source!("zz-new"; label = "x", every = 1, poll = noop, api = 2)
        @test_throws "neither polls" record_source!("zz-x"; label = "x", api = K.PLUGIN_API)
        @test_throws "both `poll` and `every`" record_source!("zz-x"; label = "x", poll = noop, api = K.PLUGIN_API)
        @test_throws "both `accepts` and `read`" record_source!("zz-x"; label = "x", read = (r, p) -> nothing, api = K.PLUGIN_API)
        @test_throws "modes" record_source!("zz-x"; label = "x", every = 1, poll = noop, modes = (:cloud,), api = K.PLUGIN_API)
        @test_throws "not pages" record_source!("zz-x"; label = "x", every = 1, poll = noop, budget = (; pages = 3), api = K.PLUGIN_API)
        @test_throws "lower case" record_source!("Notes"; label = "x", every = 1, poll = noop, api = K.PLUGIN_API)
        @test K.registered_source("zz-new") === nothing && K.registered_source("zz-x") === nothing

        # A run reaches the knowledge base only through its context: its settings and secrets, its state.
        f = tempname(); write(f, "# a comment\ns3cret\n")
        run = K.SourceRun(kb, record_source!("zz-fake"; label = "x", every = 1, poll = noop, api = K.PLUGIN_API))
        @test K.settings(run) == Dict("folder" => "/notes", "token" => "file:/nowhere") && K.upload(run) === nothing
        K.settings(run)["folder"] = "changed"                                  # a copy: the config is not changed
        @test K.settings(run)["folder"] == "/notes"
        @test_throws "no key file" K.secret(run, "token")
        @test_throws "a file: or env: reference" K.secret(run, "folder")
        @test_throws "is not set" K.secret(run, "password")
        kb.config = K.with_config(kb.config; sources = Dict{String,Any}("zz-fake" => Dict{String,Any}("token" => "file:$f")))
        @test K.secret(run, "token") == "s3cret"
        @test isempty(K.state(run))
        K.save_state!(run, Dict("seen" => "m0"))
        @test K.state(run) == Dict("seen" => "m0") && K.source_state(kb, "zz-fake") == Dict("seen" => "m0")
        @test_throws "more than" K.save_state!(run, Dict("x" => "y"^K.SOURCE_STATE_MAX))
        K.save_state!(run, Dict{String,Any}())

        # A stand-in source, run by the scheduler every 0.3 seconds.
        meeting(key; kw...) = (; key, title = "Pump review $key", date = "2026-10-02", sections = ["Notes" => "It held, said $key."],
                                 label = "A paper, honestly", projects = ["PU"], kw...)
        meetings, fail, seen = Ref([meeting("m1")]), Ref(false), Ref{Any}(nothing)
        function poll_fake(run)
            seen[] = K.state(run)
            fail[] && error("the service is down")
            foreach(m -> put!(run, m), meetings[])
            K.save_state!(run, Dict("runs" => get(K.state(run), "runs", 0) + 1))
            K.progress(run, "read $(length(meetings[]))")
        end
        fake = record_source!("zz-fake"; label = "Written up by a stand-in", every = 0.3, poll = poll_fake, budget = (; records = 2),
                              api = K.PLUGIN_API)
        st() = K.source_status(kb, "zz-fake")
        loop = K.follow_sources(kb; tick = 0.05, stop)
        # Records arrive with the source's label, whatever they say, and its name.
        @test waitfor(() -> get(st(), "outcome", "") == "ok")
        id = K.record_id("zz-fake", "m1")
        @test st()["added"] == 1 && st()["trigger"] == "scheduled" && st()["failures"] == 0
        @test K.record_row(kb, id).label == "Written up by a stand-in" && K.record_row(kb, id).source == "zz-fake"
        @test K.document_projects(kb, id) == ["PU"] && isempty(seen[])
        # Run again, an unchanged record is skipped, and the state saved is given back.
        @test waitfor(() -> get(st(), "skipped", 0) == 1)
        @test st()["added"] == 0 && seen[]["runs"] >= 1
        # A failure is tried again later each time, and a success sets it back.
        fail[] = true
        @test waitfor(() -> get(st(), "failures", 0) >= 2)
        @test st()["outcome"] == "failed" && occursin("the service is down", st()["error"])
        @test K.retry_wait(0.3, 1) == 0.3 && K.retry_wait(0.3, 2) == 0.6 && K.retry_wait(3600, 3) == 240 &&
              K.retry_wait(600, 12) == K.SOURCE_RETRY_CAP && K.retry_wait(86400, 30) == 86400
        fail[] = false
        @test waitfor(() -> get(st(), "failures", 1) == 0 && st()["outcome"] == "ok")
        # A run that has written its budget's records stops; the next goes on from there.
        meetings[] = [meeting("m1"); [meeting("m$i") for i in 2:4]]
        @test waitfor(() -> get(st(), "outcome", "") == "spent")
        @test st()["added"] == 2 && occursin("its 2 records", st()["error"])
        @test waitfor(() -> get(st(), "outcome", "") == "ok" && st()["added"] == 1 && st()["skipped"] == 3)
        # Paused, it is not run; run now, it is, paused or not.
        K.pause_source!(kb, "zz-fake")
        @test waitfor(() -> !K.source_running("zz-fake"))
        runs = K.source_state(kb, "zz-fake")["runs"]
        sleep(1)
        @test K.source_state(kb, "zz-fake")["runs"] == runs && st()["paused"]
        job = K.run_source_now!(kb, "zz-fake")
        @test_throws "running already" K.run_source_now!(kb, "zz-fake")
        wait(job)
        @test job.status == :done && job.name == "source zz-fake" && job.result == "0 added, 0 changed, 4 skipped" &&
              K.source_state(kb, "zz-fake")["runs"] == runs + 1 && !K.source_running("zz-fake")
        # A run that fails is a failed job, its error the source's.
        fail[] = true
        job = wait(K.run_source_now!(kb, "zz-fake"))
        @test job.status == :failed && occursin("the service is down", job.error)
        fail[] = false
        K.pause_source!(kb, "zz-fake", false)
        @test !st()["paused"]
        @test_throws "No source zz-gone" K.pause_source!(kb, "zz-gone")
        K.pause_source!(kb, "zz-fake")

        stop[] = true
        wait(loop)

        # A source for the shared service is not started for one person.
        record_source!("zz-shared"; label = "x", modes = (:shared,), every = 60, poll = noop, api = K.PLUGIN_API)
        @test !any(j -> j.name == "source zz-shared", K.due_sources!(kb))
        @test_throws "only in shared mode" K.run_source_now!(kb, "zz-shared")
        K.SHARED_MODE[] = true
        try
            @test only(filter(j -> j.name == "source zz-shared", K.due_sources!(kb))).name == "source zz-shared"
        finally
            K.SHARED_MODE[] = false
        end

        # A one-off command runs no source, however due.
        record_source!("zz-due"; label = "x", every = 1, poll = noop, api = K.PLUGIN_API)
        before = K._KB[]
        K._KB[] = kb
        try
            redirect_stdout(() -> K.cli(["bib"]), devnull)
        finally
            K._KB[] = before
        end
        @test isempty(K.source_status(kb, "zz-due"))

        # Forgetting a source removes its records and its state, and pauses it.
        K.pause_source!(kb, "zz-fake", false)
        @test K.forget_source!(kb, "zz-fake") == 4
        @test isempty(K.query(kb, "SELECT 1 FROM records WHERE source = 'zz-fake'")) && ismissing(K.paper_id(kb, id))
        @test isempty(K.source_state(kb, "zz-fake")) && st()["paused"] && st()["added"] == 0
    finally
        stop[] = true
        K.SOURCES[] = saved
        K.READ_PUT[] = true
        close(kb)
    end
end

@zset "uploading records" begin
    kb = open_kb(temp_config(layers = Layer[]))
    saved = K.SOURCES[]
    K.READ_PUT[] = false
    try
        K.create_project!(kb, "Pumps"; key = "PU", owner = nothing, by = K.person("Ada"))
        # A Markdown file's title is its first heading, its sections the headings below it.
        md = K.markdown_record("""
            # Pump review

            Ada opened.

            ## Results

            It held.

            ### Detail

            Three bar.

            ```
            # not a heading
            ```

            ## Next

            Bea reruns it.
            """)
        @test md.title == "Pump review" && [s.heading for s in md.sections] == ["Pump review", "Results", "Next"]
        @test occursin("### Detail", md.sections[2].text) && occursin("# not a heading", md.sections[2].text)
        @test K.markdown_record("Just text.") == (; title = nothing, sections = [(heading = "Notes", text = "Just text.")])

        # The upload source reads it as one record, dated as given, linked to the page's project.
        dir = mktempdir()
        path = joinpath(dir, "pump review.md")
        write(path, "# Pump review\n\n## Results\n\nIt held.\n")
        @test K.registered_source("upload").label == "Uploaded as a Markdown file"
        run = K.upload_record!(kb, path; date = "2026-10-02", project = "pu", by = "Rowan")
        id = only(run.ids)
        @test run.source.name == "upload" && run.added == 1 && id == K.record_id("upload", "2026-10-02 pump review")
        r = K.record_row(kb, id)
        @test r.label == "Uploaded as a Markdown file" && r.happened == "2026-10-02" && K.paper_row(kb, id).title == "Pump review"
        @test K.document_projects(kb, id) == ["PU"] && only(K.mentions(kb, id)).author == "Rowan"
        @test [s["heading"] for s in K.record_document(kb, id)["sections"]] == ["Results"]
        @test K.source_status(kb, "upload")["trigger"] == "upload" && !haskey(K.source_status(kb, "upload"), "next_at")
        # The same file again is the same record, skipped; without a date, it is the file's.
        @test K.upload_record!(kb, path; date = "2026-10-02").skipped == 1
        @test K.record_row(kb, only(K.upload_record!(kb, path).ids)).happened == string(K.Dates.Date(K.Dates.unix2datetime(mtime(path))))
        @test_throws "No source here reads notes.txt" K.upload_record!(kb, (write(joinpath(dir, "notes.txt"), "x"); joinpath(dir, "notes.txt")))
        @test_throws "has no text" K.upload_record!(kb, (write(joinpath(dir, "empty.md"), "# Title only\n"); joinpath(dir, "empty.md")))
        @test_throws "No project XX" K.upload_record!(kb, path; project = "XX")

        # A plugin's source that accepts the file is asked before Zemi's own.
        read_transcript(run, path) = put!(run, (; key = basename(path), title = "Transcript", date = "2026-10-03",
                                               sections = ["Said" => read(path, String)]))
        task_local_storage(:zemi_plugin, "ZemiFakePlugin") do
            record_source!("zz-transcripts"; label = "Transcribed by a stand-in", accepts = p -> endswith(p, ".md"),
                           read = read_transcript, api = K.PLUGIN_API)
        end
        run = K.upload_record!(kb, path)
        @test run.source.name == "zz-transcripts" && K.record_row(kb, only(run.ids)).label == "Transcribed by a stand-in"
        @test K.upload_record!(kb, path; source = "upload").source.name == "upload"
        record_source!("zz-shared-reader"; label = "x", modes = (:shared,), accepts = p -> true, read = read_transcript, api = K.PLUGIN_API)
        @test_throws "does not read" K.upload_record!(kb, path; source = "zz-shared-reader")

        # Uploaded through the API by whoever runs it.
        call(target, body) = (r = K.handle(kb, K.HTTP.Request("POST", target, ["Content-Type" => "text/markdown"], body));
                              (r.status, K.JSON.parse(String(r.body))))
        s, b = call("/api/records/upload?name=standup.md&date=2026-10-05&project=PU&source=upload", "# Standup\n\nAll well.\n")
        @test s == 200 && b["source"] == "upload" && b["added"] == 1 && K.document_projects(kb, only(b["ids"])) == ["PU"]
        @test call("/api/records/upload?date=2026-10-05", "# Standup\n")[1] == 400
        @test call("/api/records/upload?name=x.md", "")[1] == 400
    finally
        K.SOURCES[] = saved
        K.READ_PUT[] = true
        close(kb)
    end
end

@zset "plugins" begin
    # A plugins' environment holding the tests' two plugin packages, loaded through `[plugins]`.
    env, notes = mktempdir(), mktempdir()
    fixtures = joinpath(@__DIR__, "plugins")
    zemi = (; uuid = "0e5eba47-1706-456b-9465-8f454330c072", path = pkgdir(K))
    plugins = [(; name = "ZemiTestPlugin", uuid = "94c98385-d235-47cb-9ed8-b7cb2192aef5"),
               (; name = "ZemiOldPlugin", uuid = "859a89f9-2362-47d9-afa1-f8ffc0bd475b")]
    write(joinpath(env, "Project.toml"), "[deps]\n" * join(("$(p.name) = \"$(p.uuid)\"\n" for p in plugins)))
    write(joinpath(env, "Manifest.toml"), "manifest_format = \"2.0\"\n\n" *
          join(("[[deps.$(p.name)]]\ndeps = [\"Zemi\"]\npath = $(repr(joinpath(fixtures, p.name)))\nuuid = \"$(p.uuid)\"\nversion = \"0.1.0\"\n\n"
                for p in plugins)) *
          "[[deps.Zemi]]\npath = $(repr(zemi.path))\nuuid = \"$(zemi.uuid)\"\n")
    write(joinpath(notes, "pumps.md"), "# Pump review\n\nIt held.\n")
    c = temp_config(layers = Layer[], plugins = K.PluginConfig(; env, load = ["ZemiTestPlugin", "ZemiOldPlugin", "ZemiNowhere"]),
                    sources = Dict{String,Any}("zz-folder" => Dict{String,Any}("folder" => notes)))
    kb = open_kb(c)
    saved, path = K.SOURCES[], copy(LOAD_PATH)
    K.READ_PUT[] = false
    try
        # A one-off command loads no plugin.
        before = K._KB[]
        K._KB[] = kb
        try
            redirect_stdout(() -> K.cli(["bib"]), devnull)
        finally
            K._KB[] = before
        end
        @test K.registered_source("zz-folder") === nothing && !(env in LOAD_PATH)

        # One that loads registers its source; one for another interface, or not there, is left out.
        tracked = Module[]
        K.TRACK_PLUGIN[] = m -> push!(tracked, m)
        r = K.load_plugins!(kb.config)
        @test [(p.name, p.loaded) for p in r] == [("ZemiTestPlugin", true), ("ZemiOldPlugin", false), ("ZemiNowhere", false)]
        @test r[1].sources == ["zz-folder"] && occursin("plugin interface 2, and this Zemi's is 1", r[2].error)
        @test occursin("No package ZemiNowhere", r[3].error) && LOAD_PATH[end] == env && LOAD_PATH[1:end-1] == path
        @test nameof.(tracked) == [:ZemiTestPlugin] && K.registered_source("zz-old") === nothing
        s = K.registered_source("zz-folder")
        @test s.plugin == "ZemiTestPlugin" && s.label == "Read from a folder of notes"
        # Its source runs as any does, through its run alone.
        run = K.run_source!(kb, s)
        @test run.added == 1 && K.paper_row(kb, K.record_id("zz-folder", "pumps.md")).title == "Pump review"
        @test K.source_state(kb, "zz-folder") == Dict("read" => 1)
        # The service runs on and shows what became of each.
        resp = K.handle(kb, K.HTTP.Request("GET", "/api/sources"))
        b = K.JSON.parse(String(resp.body))
        @test resp.status == 200 && [p["loaded"] for p in b["plugins"]] == [true, false, false]
        @test only(x for x in b["sources"] if x["name"] == "zz-folder")["plugin"] == "ZemiTestPlugin"
    finally
        K.TRACK_PLUGIN[] = nothing
        K.PLUGINS[] = empty(K.PLUGINS[])
        K.SOURCES[] = saved
        K.READ_PUT[] = true
        empty!(LOAD_PATH); append!(LOAD_PATH, path)
        close(kb)
    end
end

@zset "nightly ingest" begin
    (; DateTime, Time, Hour, Day) = K.Dates
    la = K.TimeZones.TimeZone("America/Los_Angeles")
    # 02:00 in Los Angeles is 09:00 UTC in summer and 10:00 in winter; before it, the night before's is the latest.
    @test K.nightly_due(Time(2), la, DateTime(2026, 10, 10, 8, 59)) == DateTime(2026, 10, 9, 9)
    @test K.nightly_due(Time(2), la, DateTime(2026, 10, 10, 9)) == DateTime(2026, 10, 10, 9)
    @test K.nightly_due(Time(2), la, DateTime(2026, 12, 10, 12)) == DateTime(2026, 12, 10, 10)
    # The night the clocks skip 02:00 it comes at 03:00; the night they pass 01:30 twice, at the first.
    @test K.nightly_due(Time(2), la, DateTime(2027, 3, 14, 12)) == DateTime(2027, 3, 14, 10)
    @test K.nightly_due(Time(1, 30), la, DateTime(2026, 11, 1, 12)) == DateTime(2026, 11, 1, 8, 30)
    @test_throws "nightly_ingest" K.validate(temp_config(shared = K.SharedConfig(nightly_ingest = "25:00")))
    @test_throws "timezone" K.validate(temp_config(shared = K.SharedConfig(timezone = "Mars/Olympus")))
    @test occursin("4 summaries written", K.format_ingest([(; id = "code-x", ok = true, parsed = true, summarized = 4,
                                                            embedded = Dict{String,Int}(), error = nothing, seconds = 1.0)]))

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), "f() = 1\n")
    kb = open_kb(temp_config(layers = Layer[]))
    id = K.add_codebase!(kb, dir; name = "nightly")
    K.create_project!(kb, "Nightly"; key = "NI", codebase = id, by = K.person("Rowan"))
    K.add_codebase!(kb, mktempdir(); name = "unlinked")                    # in no project: left alone
    finished(job) = (timedwait(() -> job.finished !== nothing, 60); job)
    night = DateTime(2026, 10, 10, 9, 30)                                    # 02:30 in Los Angeles
    # Never read, and no pass yet: the missed night is caught up at once.
    @test K.changed_codebases(kb) == [id]
    job = finished(K.nightly_ingest!(kb; now = night))
    @test job.name == "nightly ingest: 1 codebase(s)" && job.status == :done && only(job.result).ok && only(job.result).parsed
    @test isempty(K.changed_codebases(kb))
    # Changed later that night: read the next night, not before.
    write(joinpath(dir, "b.jl"), "g() = 2\n")
    @test K.nightly_ingest!(kb; now = night + Hour(3)) === nothing && K.changed_codebases(kb) == [id]
    # A job already working on it keeps it; the night after, it is read.
    busy = K.start_job(j -> while !K.cancelled(j); sleep(0.05); end, "reading"; ids = [id])
    @test K.nightly_ingest!(kb; now = night + Day(1)) === nothing
    finished(K.cancel!(busy))
    @test K.nightly_ingest!(kb; now = night + Day(1) + Hour(1)) === nothing          # that night's pass is spent
    job = finished(K.nightly_ingest!(kb; now = night + Day(2)))
    @test job.status == :done && only(job.result).parsed && isempty(K.changed_codebases(kb))
    # Unchanged, nothing is started.
    @test K.nightly_ingest!(kb; now = night + Day(3)) === nothing
    close(kb)

    # With no time set there is no pass.
    kb = open_kb(temp_config(layers = Layer[], shared = K.SharedConfig(nightly_ingest = "")))
    id = K.add_codebase!(kb, dir; name = "nightly")
    K.create_project!(kb, "Nightly"; key = "NI", codebase = id, by = K.person("Rowan"))
    @test K.nightly_ingest!(kb; now = night) === nothing && K.changed_codebases(kb) == [id]
    @test ismissing(scalar(kb, "SELECT value FROM kv WHERE key = 'nightly_ingest_at'"))
    close(kb)
end

@zset "the watch takes in what it rates" begin
    kb = open_kb(temp_config(layers = Layer[]))
    rate(id, r, why) = K.execute!(kb, """INSERT INTO watch (doc_id, title, authors, abstract, published, category, score, area, area_score,
                                         nearest, found_at, relevance, reason) VALUES (?, ?, '[]', 'About it.', '2026-10-10', 'physics.ao-ph',
                                         0.5, 'Corals', 0.5, '[]', ?, ?, ?)""", (id, "Paper $id", K.now_iso(), r, why))
    rate("2610.00011", 3, "The group's own question."); rate("2610.00012", 2, "Bears on the reef work.")
    rate("2610.00013", 1, "Tangential."); rate("2610.00014", 0, "Another field.")
    read, recorded = String[], String[]
    took = K.take_watched!(kb; read_in_full = ids -> append!(read, ids), record = ids -> append!(recorded, ids))
    # Central and related read in full, peripheral recorded, unrelated let go.
    @test took.read == read == ["2610.00011", "2610.00012"] && took.recorded == recorded == ["2610.00013"]
    @test ismissing(K.paper_id(kb, "2610.00014"))
    @test only(K.mentions(kb, "2610.00011")).source == "watch" && only(K.mentions(kb, "2610.00011")).message == "central: The group's own question."
    @test [(t.id, t.taken, t.read) for t in K.watch_taken(kb)][1:3] ==
          [("2610.00011", "read", false), ("2610.00012", "read", false), ("2610.00013", "recorded", false)]
    @test isempty(K.take_watched!(kb; read_in_full = ids -> error("again"), record = ids -> error("again")).read)   # each once
    # Taken in, they are still the paper of the day's candidates; their pages say how they came.
    @test [c.id for c in K.daily_candidates(kb)][1:2] == ["2610.00011", "2610.00012"]
    K.execute!(kb, "UPDATE papers SET metadata_at = ?, title = 'Paper 2610.00011' WHERE doc_id = '2610.00011'", (K.now_iso(),))
    post = only(K.paper_json(K.site_paper(kb, "2610.00011"; related = false))["posts"])
    @test (post["where"], post["rating"], post["reason"]) == ("Added from the arXiv watch", "central", "The group's own question.")
    @test K.watch_taken_json(kb)[1]["slug"] == K.page_slug("2610.00011")
    # Removed, it leaves the list and is not taken in again.
    K.remove_paper!(kb, "2610.00013")
    @test "2610.00013" ∉ [t.id for t in K.watch_taken(kb)]
    @test K.take_watched!(kb; read_in_full = ids -> error("again"), record = ids -> error("again")).recorded == String[]
    close(kb)
    # Thresholds above 3 take nothing in.
    kb = open_kb(temp_config(layers = Layer[], watch_read_from = 4, watch_record_from = 4))
    K.execute!(kb, """INSERT INTO watch (doc_id, title, authors, abstract, published, category, score, area, area_score, nearest, found_at, relevance)
                      VALUES ('2610.00021', 'P', '[]', '', '2026-10-10', 'x', 0.5, 'A', 0.5, '[]', ?, 3)""", (K.now_iso(),))
    @test K.take_watched!(kb; read_in_full = ids -> error("none"), record = ids -> error("none")) == (; read = String[], recorded = String[])
    @test ismissing(K.paper_id(kb, "2610.00021"))
    close(kb)
end

@zset "a codebase read again redoes only what changed" begin
    dir = mktempdir()
    mkpath(joinpath(dir, "src"))
    long(prefix, n) = join(("$prefix$i() = $i  # " * "x"^200 for i in 1:n), "\n")      # several passages
    write(joinpath(dir, "src", "b.jl"), "b() = 2\n")
    write(joinpath(dir, "src", "c.jl"), long("c", 40))
    write(joinpath(dir, "src", "d.jl"), long("d", 40))
    kb = open_kb(temp_config(layers = Layer[]))
    id = add_codebase!(kb, dir; name = "Keep")
    @test K.parse_code!(kb, id)
    pid = K.paper_id(kb, id)
    numbers() = Dict(String(r.title) => Int(r.ord) for r in K.query(kb, "SELECT ord, title FROM sections WHERE paper_id = ?", (pid,)))
    # What a layer would embed, as (key, text) pairs: for passages and for whole files.
    units(unit) = Set((u.key, K.text_sha(u.text)) for u in K.units(kb, Layer(; name = "t", model = "m", unit), id))
    before, chunks_before, sections_before = numbers(), units(:chunk), units(:section)
    # A file added first in order, one removed, one grown.
    write(joinpath(dir, "src", "a.jl"), "a() = 1\n")
    rm(joinpath(dir, "src", "b.jl"))
    write(joinpath(dir, "src", "c.jl"), long("e", 20) * "\n" * long("c", 40))      # grown at its start, which a layer embeds
    @test K.parse_code!(kb, id)
    after = numbers()
    # Every other file and directory keeps its number; the new file takes one never used.
    @test [after[f] for f in ("src/c.jl", "src/d.jl", "src/")] == [before[f] for f in ("src/c.jl", "src/d.jl", "src/")]
    @test after["src/a.jl"] == maximum(values(before)) + 1 && !haskey(after, "src/b.jl")
    # So only the changed files' passages and sections are embedded again (and summarized again,
    # summaries being kept by the same numbers); a passage is numbered within its file.
    file_of(key) = (n = parse(Int, split(key, ':')[3]); n >= K.CHUNK_STRIDE ? n ÷ K.CHUNK_STRIDE : n)
    redo(now, was) = Set(file_of(k) for (k, _) in setdiff(now, was))
    @test redo(units(:chunk), chunks_before) == Set([after["src/a.jl"], after["src/c.jl"]])
    @test redo(units(:section), sections_before) == Set([after["src/a.jl"], after["src/c.jl"]])
    # Shown by path all the same, whatever the numbers.
    outline = K.format_paper(kb, id)
    @test findfirst("src/a.jl", outline)[1] < findfirst("src/c.jl", outline)[1] < findfirst("src/d.jl", outline)[1]
    # A file gone leaves its number unused while anything is still kept under it.
    K.execute!(kb, """INSERT INTO summaries (paper_id, unit_key, summarizer, model, prompt_version, input_sha, text, created_at)
                      VALUES (?, ?, 's', 'm', 1, 'x', 'about a.jl', 'now')""",
               (pid, "s:$id:$(after["src/a.jl"])"))
    rm(joinpath(dir, "src", "a.jl"))
    K.parse_code!(kb, id)
    write(joinpath(dir, "src", "f.jl"), "f() = 6\n")
    K.parse_code!(kb, id)
    @test numbers()["src/f.jl"] > after["src/a.jl"]
    @test K.parse_codebase(dir)[1].sections[1].ord == 1                          # read with no earlier numbers
    close(kb)
end

@zset "base set" begin
    kb = open_kb(temp_config())
    add_papers!(kb, ["2609.00001", "2609.00002"])
    for (id, at, who) in (("2609.00001", 1.7e9, "Ada"), ("2609.00001", 1.7e9 + 100, "Alan"), ("2609.00002", 1.7e9 + 200, "Alan"))
        K.execute!(kb, "INSERT INTO mentions (paper_id, source, channel, posted_at, author) VALUES (?, 'seminar', 'reading-list', ?, ?)",
                   (K.paper_id(kb, id), at, who))
    end
    K.execute!(kb, "UPDATE papers SET title = 'T ' || doc_id, abstract = 'A', authors = '[\"X\"]', categories = '[]', metadata_at = 'x'")
    base = joinpath(mktempdir(), "base.json")
    @test export_base_set(kb, base; source = "seminar") == 2
    close(kb)

    # A new knowledge base seeds itself from its base set; an existing one does not.
    fresh = open_kb(temp_config(base_set = base))
    @test K.scalar(fresh, "SELECT count(*) FROM papers") == 2
    @test [m.author for m in mentions(fresh, "2609.00001")] == ["Ada", "Alan"]
    @test K.paper_row(fresh, "2609.00002").title == "T 2609.00002"
    @test seed!(fresh, base) == 0
    close(fresh)
    @test K.scalar(open_kb(temp_config(base_set = "")), "SELECT count(*) FROM papers") == 0
end

@zset "S3 signing" begin
    # AWS's published example (Signature Version 4, "GET Object").
    empty_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    auth = K.sigv4_authorization(; method = "GET", path = "/test.txt", payload_hash = empty_sha,
        headers = Dict("host" => "examplebucket.s3.amazonaws.com", "range" => "bytes=0-9",
                       "x-amz-content-sha256" => empty_sha, "x-amz-date" => "20130524T000000Z"),
        access_key_id = "AKIAIOSFODNN7EXAMPLE", secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region = "us-east-1", amzdate = "20130524T000000Z")
    @test auth == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " *
                  "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " *
                  "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    @test K.uri_encode("docs/a b~.json"; path = true) == "docs/a%20b~.json" && K.uri_encode("a/b") == "a%2Fb"
    # S3 answers in its namespace, a stand-in in none: elements are found by name either way.
    listing = K.s3_xml(K.HTTP.Response(200, """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Contents><Key>docs/a&amp;b&#123;.json</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>"""))
    @test [K.s3_text(c, "Key") for c in K.s3_elements(listing, "Contents")] == ["docs/a&b{.json"] && K.s3_text(listing, "IsTruncated") == "false"
    @test K.s3_xml(K.HTTP.Response(200, "")) === nothing && K.s3_text(listing, "NextContinuationToken") === nothing

    # Objects through a stand-in S3 that keeps them in memory and checks every request's signature,
    # on a port of its own, which the signature must name.
    s3 = standin_s3(Dict("key" => "secret"); page = 2)          # two keys a listing, so paging is tested
    objects = s3.objects
    try
        store = S3Store(s3.endpoint, "bucket", "kb", "auto", "key", "secret")
        @test K.read_object(store, "manifest.json") === nothing && !K.has_object(store, "manifest.json")
        K.write_object!(store, "docs/x.json.gz", Vector{UInt8}("hello"))
        @test haskey(objects, "bucket/kb/docs/x.json.gz") && K.has_object(store, "docs/x.json.gz")
        @test String(K.read_object(store, "docs/x.json.gz")) == "hello"
        # A large object goes up in parts, with how much has been sent told as each part is.
        big = rand(UInt8, 20 * 1024^2)
        sent = Int[]
        K.write_object!(store, "site/big.tar.gz", big; progress = (n, total) -> (push!(sent, n); @assert total == length(big)))
        @test objects["bucket/kb/site/big.tar.gz"] == big && isempty(s3.uploads)
        @test length(sent) == 3 && maximum(sent) == length(big)
        # Listing, a page at a time, and deleting.
        K.write_object!(store, "site/a", UInt8[1]); K.write_object!(store, "site/b", UInt8[2])
        @test sort(K.list_objects(store, "site/")) == ["site/a", "site/b", "site/big.tar.gz"]
        K.delete_object!(store, "site/a")
        @test sort(K.list_objects(store, "site/")) == ["site/b", "site/big.tar.gz"] && !haskey(objects, "bucket/kb/site/a")
        # A key the store does not know, or the right key with the wrong secret, is refused.
        @test_throws "HTTP 403" K.read_object(S3Store(s3.endpoint, "bucket", "kb", "auto", "key", "wrong"), "docs/x.json.gz")
        @test_throws "HTTP 403" K.write_object!(S3Store(s3.endpoint, "bucket", "kb", "auto", "nobody", "secret"), "docs/y", UInt8[1])
        # A dataset published to the bucket and imported from it.
        pub, con = open_kb(temp_config(; layers = Layer[])), open_kb(temp_config(; layers = Layer[], dataset = DatasetConfig(; role = :consume)))
        add_papers!(pub, ["2609.00001"])
        K.execute!(pub, "UPDATE papers SET title = 'Coral recovery' WHERE doc_id = '2609.00001'")
        @test publish!(pub; store).uploaded == 1
        @test pull!(con; store).imported == 1 && K.paper_row(con, "2609.00001").title == "Coral recovery"
        close(pub); close(con)
    finally
        close(s3.server)
    end
    # Kept in a folder, the objects outlast the stand-in.
    kept = mktempdir()
    s3 = standin_s3(Dict("key" => "secret"); dir = kept)
    K.write_object!(S3Store(s3.endpoint, "bucket", "kb", "auto", "key", "secret"), "docs/x", Vector{UInt8}("kept"))
    close(s3.server)
    s3 = standin_s3(Dict("key" => "secret"); dir = kept)
    try
        store = S3Store(s3.endpoint, "bucket", "kb", "auto", "key", "secret")
        @test String(K.read_object(store, "docs/x")) == "kept" && K.list_objects(store, "docs/") == ["docs/x"]
    finally
        close(s3.server)
    end
end

@zset "dataset" begin
    HTTP, JSON = K.HTTP, K.JSON
    qdrant, colls, qport = standin_qdrant()
    saved = qdrant_state()
    K.Qdrant.use!("http://127.0.0.1:$qport")
    try
        layer = Layer(; name = "chunk-t", model = "m", unit = :chunk)
        s = Summarizer(; name = "sum", url = "http://127.0.0.1:1", model = "m")
        pub = open_kb(temp_config(qdrant_url = "http://127.0.0.1:$qport", layers = [layer], summarizers = [s], summarizer = "sum", code_summarizer = "sum", judge = "sum"))
        add_papers!(pub, ["2609.00001", "2609.00002"])
        head(t) = K.Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 1, "")
        body(t) = K.Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 0, "")
        K.store_parse!(pub, "2609.00001", K.ParsedPaper(1, [head("1. Body"), body("Corals feed on plankton at night.")],
                                                        [K.Section(1, 1, "1", "1. Body", "1. Body", 1, 1)]))
        pid = K.paper_id(pub, "2609.00001")
        K.execute!(pub, "UPDATE papers SET title = 'Corals' WHERE id = ?", (pid,))
        K.execute!(pub, "INSERT INTO mentions (paper_id, source, channel, posted_at, author) VALUES (?, 'seminar', 'reading-list', 1.7e9, 'Ada')", (pid,))
        K.execute!(pub, "INSERT INTO summaries VALUES (?, 'p:2609.00001', 'sum', 'm', 1, 'x', 'About corals.', 1, 1, ?)", (pid, K.now_iso()))
        K.execute!(pub, "INSERT INTO classifications VALUES (?, 'sum', 'm', '{\"category\": \"physics.ao-ph\"}', ?)", (pid, K.now_iso()))
        coll = K.ensure_layer!(pub, layer, 3)
        units = K.units(pub, layer, "2609.00001")
        ids = [K.point_id(layer.name, u.key) for u in units]
        K.upsert_vectors!(coll, ids, [Float32[0.5, -0.25, 1.0] for _ in units], [merge(u.payload, Dict("unit" => u.key)) for u in units])
        for (u, id) in zip(units, ids)
            K.execute!(pub, "INSERT INTO embeddings VALUES (?, ?, ?, ?, ?, ?)", (layer.name, u.key, pid, K.text_sha(u.text), id, K.now_iso()))
        end
        K.execute!(pub, "INSERT INTO papers (doc_id, title, added_at, kind) VALUES ('doc-private', 'Mine', ?, 'paper')", (K.now_iso(),))

        store = DirStore(mktempdir())
        r = publish!(pub; store)
        @test r.documents == 2 && r.changed == 2 && r.uploaded == 2     # the unshared upload stays home
        again = publish!(pub; store)
        @test again.changed == 0 && again.uploaded == 0                 # nothing changed: nothing exported or uploaded
        K.execute!(pub, "DELETE FROM published_docs")
        lost = publish!(pub; store)
        @test lost.changed == 2 && lost.uploaded == 0                   # exported again, but the store has them
        # A vector Qdrant lost: the document's earlier copy stays published, and its record is forgotten
        # for a sync to embed it again; once it is, the document is published whole.
        stream_doc() = K.JSON.parsefile(joinpath(store.dir, "streams", K.stream_name(pub.config) * ".json"))["documents"]["2609.00001"]
        before, gone = stream_doc(), first(ids)
        point = pop!(colls[coll], string(gone))
        K.execute!(pub, "DELETE FROM published_docs")
        @test publish!(pub; store).incomplete == 1 && stream_doc() == before
        @test K.scalar(pub, "SELECT count(*) FROM embeddings WHERE point_id = ?", (gone,)) == 0
        colls[coll][string(gone)] = point
        K.execute!(pub, "INSERT INTO embeddings VALUES (?, ?, ?, ?, ?, ?)", (layer.name, first(units).key, pid, K.text_sha(first(units).text), gone, K.now_iso()))
        @test publish!(pub; store).incomplete == 0 && stream_doc()["hash"] == before["hash"]

        con = open_kb(temp_config(qdrant_url = "http://127.0.0.1:$qport", layers = Layer[], dataset = DatasetConfig(; role = :consume)))
        @test K.Qdrant.search("zemi_test_not_made", [0.1, 0.2]) == []        # nothing embedded in that layer yet
        # The consumer's Qdrant is the same stand-in, so its collection must not be the publisher's.
        empty!(colls)
        @test new_publish(con; store) !== nothing                       # a publish not yet imported
        p = pull!(con; store)
        @test new_publish(con; store) === nothing && !ismissing(K.scalar(con, "SELECT value FROM kv WHERE key = 'dataset_checked'"))
        @test p.documents == 2 && p.imported == 2 && p.removed == 0
        @test K.paper_row(con, "2609.00001").title == "Corals"
        ms = mentions(con, "2609.00001")                                # its arrival and its post in a channel travel with it
        @test [m.source for m in ms] == ["seminar", "added"] && first(ms).author == "Ada"
        @test occursin("plankton", K.read_paper(con, "2609.00001"))
        @test only(x.text for x in summaries(con, "2609.00001")) == "About corals."
        @test classification(con, "2609.00001")["category"] == "physics.ao-ph"
        @test any(startswith("c:2609.00001:"), K.keyword_ranking(con, "corals"))          # the keyword index is rebuilt
        got = K.fetch_vectors(K.collection_name(con.config, layer), ids)
        unit(v) = v ./ sqrt(sum(abs2, v))                  # cosine collections keep vectors at unit length
        @test length(got) == length(ids) && all(v -> isapprox(unit(first(v)), unit(Float32[0.5, -0.25, 1.0]); atol = 1e-3), values(got))
        # The consumer's config follows the dataset's layers and summarizer.
        followed = K.follow_profile(con.config)
        @test [l.name for l in followed.layers] == ["chunk-t"] && followed.summarizer == "sum"
        @test pull!(con; store).imported == 0

        # Changes, sharing and removal reach the consumer, and nothing else is downloaded.
        K.execute!(pub, "UPDATE papers SET title = 'Corals, revised' WHERE doc_id = '2609.00002'")
        K.execute!(pub, "UPDATE papers SET shared = 1 WHERE doc_id = 'doc-private'")
        changes = publish!(pub; store)
        @test changes.changed == 2 && changes.uploaded == 2
        @test pull!(con; store).imported == 2 && K.paper_row(con, "2609.00002").title == "Corals, revised"
        K.remove_paper!(pub, "2609.00002")
        publish!(pub; store)
        @test pull!(con; store).removed == 1 && ismissing(K.paper_id(con, "2609.00002"))

        # Without Qdrant, a consumer imports everything but the vectors, and a later import adds them.
        late = open_kb(temp_config(qdrant_url = "http://127.0.0.1:$qport", layers = Layer[], collection_prefix = "zemi_late", dataset = DatasetConfig(; role = :consume)))
        K.Qdrant.use!("http://127.0.0.1:1")
        @test pull!(late; store).imported == 2
        @test occursin("plankton", K.read_paper(late, "2609.00001")) && isempty(K.query(late, "SELECT * FROM embeddings"))
        unembedded() = [d.id for d in K.list_documents(late; state = "unembedded").documents]
        @test "2609.00001" in unembedded() && "2609.00001" in [d.id for d in K.list_documents(late; state = "read").documents]
        @test pull!(late; store).imported == 0                           # nothing to add while Qdrant is away
        K.Qdrant.use!("http://127.0.0.1:$qport")
        @test pull!(late; store).imported == 1                           # the paper with vectors, once Qdrant runs

        # The papers of the day go with the dataset: their analyses, and their figures uploaded once.
        figdir = mkpath(K.figures_dir(pub.config, "2609.00001"))
        image(path, color) = (K.save_image(path, fill(color, 24, 32)); read(path))
        fig1 = image(joinpath(figdir, "fig-1.webp"), K.RGB(0.1, 0.4, 0.8))
        fig2 = image(joinpath(figdir, "fig-2.webp"), K.RGB(0.8, 0.3, 0.1))
        for (n, file) in ((1, "fig-1.webp"), (2, "fig-2.webp"))
            K.execute!(pub, "INSERT INTO figures VALUES (?, ?, ?, ?, ?, ?)", (K.paper_id(pub, "2609.00001"), "figure", n, "Figure $n", "Figure $n. A caption.", file))
        end
        K.execute!(pub, """INSERT INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at, done_at, notebook, notebook_status)
                           VALUES ('2026-10-02', '2609.00001', 'new', 'Why.', 'done', '## What it does', ?, '{"tractable": true}', ?, ?, 'notebooks/daily/x.jl', 'done')""",
                   (K.JSON.json([Dict("label" => "Figure 1", "why" => "It.", "file" => "fig-1.webp"), Dict("label" => "Figure 9", "why" => "Not cut.")]),
                    K.now_iso(), K.now_iso()))
        K.execute!(pub, "INSERT INTO daily (day, doc_id, source, why, status, picked_at) VALUES ('2026-10-03', '2609.00002', 'new', '', 'failed', ?)", (K.now_iso(),))
        publish!(pub; store)
        sha = bytes2hex(K.sha256(fig1))
        @test isfile(joinpath(store.dir, "daily", "figures", "$sha.webp"))
        pull!(con; store)
        d = only(dailies(con))                                           # finished days only
        @test d.day == "2026-10-02" && d.analysis == "## What it does"
        @test read(joinpath(K.figures_dir(con.config, "2609.00001"), "fig-1.webp")) == fig1
        @test [g["file"] for g in d.gallery] == ["fig-1.webp", "fig-2.webp"]         # every figure of the paper, with it
        @test read(joinpath(K.figures_dir(con.config, "2609.00001"), "fig-2.webp")) == fig2
        @test [f["label"] for f in d.figures] == ["Figure 1", "Figure 9"] && !haskey(d.figures[2], "file")
        rm(joinpath(store.dir, "daily", "figures", "$sha.webp"))
        publish!(pub; store)                                             # unchanged: nothing uploaded again
        @test !isfile(joinpath(store.dir, "daily", "figures", "$sha.webp"))
        write(joinpath(store.dir, "daily", "figures", "$sha.webp"), fig1)   # for the members below
        @test !isempty(K.query(late, "SELECT * FROM embeddings WHERE paper_id = ?", (K.paper_id(late, "2609.00001"),)))
        @test !("2609.00001" in unembedded())

        # Every document's figures go with it, each image uploaded once: a member without its PDF shows them.
        # These were cut as PNG images, as before figures were WebP, and are published as they are.
        mine = K.paper_id(pub, "doc-private")
        figdir = mkpath(K.figures_dir(pub.config, "doc-private"))
        old_fig = image(joinpath(figdir, "fig-1.png"), K.RGB(0.2, 0.6, 0.3))
        image(joinpath(figdir, "tab-1.png"), K.RGB(0.9, 0.9, 0.9))
        K.execute!(pub, "INSERT INTO figures VALUES (?, 'figure', 1, 'Figure 1', 'Figure 1. Reef cover.', 'fig-1.png')", (mine,))
        K.execute!(pub, "INSERT INTO figures VALUES (?, 'table', 1, 'Table 1', 'Table 1. Sites.', 'tab-1.png')", (mine,))
        K.execute!(pub, "INSERT INTO figure_cuts VALUES (?, 'pdf-sha', ?)", (mine, K.now_iso()))
        @test publish!(pub; store).changed == 1                          # cutting its figures here republishes it
        @test isfile(joinpath(store.dir, "figures", bytes2hex(K.sha256(old_fig)) * ".png"))
        fresh = open_kb(temp_config(qdrant_url = "http://127.0.0.1:$qport", layers = Layer[], collection_prefix = "zemi_fresh",
                                    dataset = DatasetConfig(; role = :consume, stream = "bea")))
        pull!(fresh; store)
        # Imported as PNG images, and converted to WebP.
        freshdir = K.figures_dir(fresh.config, "doc-private")
        @test [(f.label, f.file) for f in K.paper_figures(fresh, "doc-private")] == [("Figure 1", "fig-1.webp"), ("Table 1", "tab-1.webp")]
        @test sort(readdir(freshdir)) == ["fig-1.webp", "tab-1.webp"] && K.image_size(joinpath(freshdir, "tab-1.webp")) == (32, 24)
        # Imported, they leave the document its stream's: the member does not publish it as its own.
        @test isempty(K.own_documents(fresh, ["doc-private"]))
        # The publisher's own converted: the document's data names them anew, so it is published again,
        # its images as WebP objects; members take them as they come.
        @test K.webp_figures!(pub) == 2 && [f.file for f in K.paper_figures(pub, "doc-private")] == ["fig-1.webp", "tab-1.webp"]
        @test publish!(pub; store).changed == 1
        new_fig = read(joinpath(figdir, "fig-1.webp"))
        @test isfile(joinpath(store.dir, "figures", bytes2hex(K.sha256(new_fig)) * ".webp"))
        @test pull!(fresh; store).imported == 1 && read(joinpath(freshdir, "fig-1.webp")) == new_fig
        @test isempty(K.own_documents(fresh, ["doc-private"]))
        close(pub); close(con); close(late); close(fresh)
    finally
        restore_qdrant!(saved)
        close(qdrant)
    end
end

@zset "streams: several members publishing to one dataset" begin
    s = Summarizer(; name = "sum", url = "http://127.0.0.1:1", model = "m")
    member(role, stream = ""; summarizer = "sum") = open_kb(temp_config(; layers = Layer[], summarizers = [s, Summarizer(; name = "other", url = "http://127.0.0.1:1", model = "o")],
        summarizer, code_summarizer = summarizer, judge = summarizer, dataset = DatasetConfig(; role, stream)))
    head(t) = K.Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 1, "")
    body(t) = K.Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 0, "")
    function read!(kb, id, text)
        add_papers!(kb, [id])
        K.store_parse!(kb, id, K.ParsedPaper(1, [head("1. Body"), body(text)], [K.Section(1, 1, "1", "1. Body", "1. Body", 1, 1)]))
        K.execute!(kb, "UPDATE papers SET title = ? WHERE doc_id = ?", (text, id))
    end
    summarize!(kb, id, text) = K.execute!(kb, "INSERT OR REPLACE INTO summaries VALUES (?, ?, 'sum', 'm', 1, 'x', ?, 1, 1, ?)",
                                          (K.paper_id(kb, id), "p:$id", text, K.now_iso()))
    streams_of(kb) = Dict(r.doc_id => r.stream for r in K.query(kb, "SELECT doc_id, stream FROM dataset_docs"))
    store = DirStore(mktempdir())
    ada, bea, con = member(:publish, "ada"), member(:publish, "bea"), member(:consume)
    @test_throws "nothing has been published" pull!(con; store)
    @test pull!(ada; store).imported == 0                             # the first publisher has nothing to import
    read!(ada, "2609.00001", "Reef recovery after bleaching.")
    read!(bea, "2609.00002", "Larval settlement on reefs.")
    @test publish!(ada; store).documents == 1 && isfile(joinpath(store.dir, "profile.json"))
    @test publish!(bea; store).documents == 1
    @test isfile(joinpath(store.dir, "streams", "ada.json")) && isfile(joinpath(store.dir, "streams", "bea.json"))
    # Each member imports the other's stream, and publishes only what it read itself.
    @test new_publish(ada; store) !== nothing
    a = pull!(ada; store)
    @test (a.streams, a.documents, a.imported) == (2, 2, 1) && streams_of(ada) == Dict("2609.00002" => "bea")
    @test new_publish(ada; store) === nothing                          # its own stream is not news to it
    @test publish!(ada; store).documents == 1
    pull!(bea; store)
    c = pull!(con; store)
    @test c.imported == 2 && streams_of(con) == Dict("2609.00001" => "ada", "2609.00002" => "bea")
    @test K.paper_row(con, "2609.00002").title == "Larval settlement on reefs."
    # A member who reads another's document again publishes it: the more complete copy is imported.
    summarize!(ada, "2609.00002", "Settlement, summarized.")
    @test K.own_documents(ada, ["2609.00001", "2609.00002"]) == ["2609.00001", "2609.00002"]
    @test publish!(ada; store).documents == 2
    @test pull!(con; store).imported == 1 && streams_of(con)["2609.00002"] == "ada"
    @test only(x.text for x in summaries(con, "2609.00002")) == "Settlement, summarized."
    @test pull!(bea; store).imported == 1 && streams_of(bea)["2609.00002"] == "ada"
    publish!(bea; store)
    # Bea's copy is now Ada's, as imported, so Bea's stream no longer carries it.
    @test isempty(K.JSON.parsefile(joinpath(store.dir, "streams", "bea.json"))["documents"])
    # What its stream drops goes from those who imported it.
    K.remove_paper!(ada, "2609.00001")
    publish!(ada; store)
    @test pull!(con; store).removed == 1 && ismissing(K.paper_id(con, "2609.00001"))
    @test pull!(bea; store).removed == 1
    # The first publish set the dataset's models; a member making documents another way is refused.
    cy = member(:publish, "cy"; summarizer = "other")
    read!(cy, "2609.00003", "Coral spawning.")
    @test_throws "does not make documents the way the dataset does" publish!(cy; store)
    @test !isfile(joinpath(store.dir, "streams", "cy.json"))
    @test K.profile_differences(K.read_profile(store), cy.config) == ["the summarizer is other here and sum in the dataset",
                                                                    "the code summarizer is other here and sum in the dataset"]
    @test K.follow_profile(K.with_config(cy.config; data_dir = con.config.data_dir)).summarizer == "sum"   # as an import leaves it
    # Following it keeps where this machine reaches a layer's model, and the layers searched.
    here = K.with_config(cy.config; data_dir = mktempdir(), layers = [Layer(; name = "l", model = "m", unit = :chunk, url = "http://127.0.0.1:9", key = "env:K")],
                         search_layers = ["l"])
    write(K.profile_cache(here), K.JSON.json(Dict("layers" => [K.layer_json(Layer(; name = "l", model = "m", unit = :chunk))],
                                                  "summarizers" => [], "summarizer" => "sum", "code_summarizer" => "sum")))
    followed = K.follow_profile(here)
    @test (only(followed.layers).url, only(followed.layers).key, followed.search_layers) == ("http://127.0.0.1:9", "env:K", ["l"])
    @test_throws "must be lowercase" K.stream_name(K.with_config(cy.config; dataset = DatasetConfig(; role = :publish, stream = "Ada Lovelace")))
    # A paper of the day naming a file outside its paper's figures is not taken in.
    goodday = Dict("day" => "2026-10-02", "doc_id" => "2609.00002", "figures" => [Dict("file" => "fig-1.png")], "gallery" => [])
    @test K.imported_day_ok(goodday)
    @test !K.imported_day_ok(merge(goodday, Dict("figures" => [Dict("file" => "../../../.bashrc")])))
    @test !K.imported_day_ok(merge(goodday, Dict("doc_id" => "../escape"))) && !K.imported_day_ok(merge(goodday, Dict("day" => "../x")))
    # Figures are named as WebP images, or PNG ones as published before; nothing else is taken in.
    @test K.imported_day_ok(merge(goodday, Dict("figures" => [Dict("file" => "fig-1.webp")], "gallery" => [Dict("file" => "table-2.png")])))
    @test !K.imported_day_ok(merge(goodday, Dict("figures" => [Dict("file" => "fig-1.svg")])))
    @test !K.imported_day_ok(merge(goodday, Dict("gallery" => [Dict("file" => "fig-1.html")])))
    sha = repeat("a", 64)
    @test K.figure_ok(Dict("file" => "fig-1.webp", "sha" => sha)) && K.figure_ok(Dict("file" => "table-2.png", "sha" => sha))
    @test !any(f -> K.figure_ok(Dict("file" => f, "sha" => sha)), ["fig-1.svg", "fig-1.jpg", "fig-1.webp.sh", ".webp", "../fig-1.webp", "fig-1.WEBP"])
    @test K.figure_key("figures", sha, "fig-1.webp") == "figures/$sha.webp" && K.figure_key("daily/figures", sha, "fig-1.png") == "daily/figures/$sha.png"
    # Copies compared: the most complete, then the newest, then the stream named last.
    entry(complete, at) = Dict("documents" => Dict("x" => Dict{String,Any}("hash" => "h", "complete" => complete, "at" => at)))
    pick(streams) = first(K.stream_winners(streams)["x"])
    @test pick(Dict("ada" => entry([1, 1, 0], "2026-10-01"), "bea" => entry([1, 0, 1], "2026-10-05"))) == "ada"
    @test pick(Dict("ada" => entry([1, 0, 9], "2026-10-01"), "bea" => entry([1, 0, 1], "2026-10-05"))) == "bea"   # not by how many
    later = Dict("ada" => entry([1, 0, 9], "2026-10-09"), "bea" => entry([1, 0, 1], "2026-10-01"))
    later["bea"]["documents"]["x"]["version"] = "v2"; later["ada"]["documents"]["x"]["version"] = "v1"
    @test pick(later) == "bea"                                                                      # the latest version first
    @test pick(Dict("ada" => entry([1, 0, 1], "2026-10-01"), "bea" => entry([1, 0, 1], "2026-10-05"))) == "bea"
    @test pick(Dict("bea" => entry([1, 0, 1], "2026-10-01"), "ada" => entry([1, 0, 1], "2026-10-01"))) == "bea"
    # The papers of the day from every stream; a day two members picked, as it was finished last.
    day(kb, id, done) = K.execute!(kb, """INSERT OR REPLACE INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at, done_at)
                                          VALUES ('2026-10-02', ?, 'new', 'Why.', 'done', ?, '[]', '{}', ?, ?)""", (id, "About $id, by $(kb.config.dataset.stream).", done, done))
    day(ada, "2609.00002", "2026-10-02T08:00:00Z")
    day(bea, "2609.00002", "2026-10-02T09:00:00Z")
    publish!(ada; store); publish!(bea; store)
    pull!(con; store)
    @test only(dailies(con)).analysis == "About 2609.00002, by bea."
    # The models the dataset's profile names are not set here, but shown as the dataset's.
    @test_throws "follow the dataset's profile" K.save_settings!(con, Dict("summarizer" => "x"))
    @test only(s for s in K.settings_json(con)["settings"] if s["key"] == "summarizer")["follows"]
    pull!(ada; store)
    @test only(dailies(ada)).analysis == "About 2609.00002, by bea."
    # Two papers for one day: the one finished last, for every member, though the other was picked later.
    other_day(kb, id, picked, done) = K.execute!(kb, """INSERT INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at, done_at)
                                                       VALUES ('2026-10-04', ?, 'new', 'Why.', 'done', 'About it.', '[]', '{}', ?, ?)""", (id, picked, done))
    other_day(ada, "2609.00001", "2026-10-04T08:00:00Z", "2026-10-04T12:00:00Z")
    other_day(bea, "2609.00002", "2026-10-04T09:00:00Z", "2026-10-04T10:00:00Z")
    publish!(ada; store); publish!(bea; store)
    foreach(kb -> pull!(kb; store), (ada, bea, con))
    @test all(kb -> first(dailies(kb)).id == "2609.00001", (ada, bea, con))
    foreach(close, (ada, bea, con, cy))
end

@zset "content through the streams" begin
    member(role, stream = "") = open_kb(temp_config(; layers = Layer[], dataset = DatasetConfig(; role, stream)))
    page(kb) = (f = K.content_path(kb.config, "pages", "about.md"); isfile(f) ? read(f, String) : nothing)
    write_page(kb, text) = (mkpath(K.content_path(kb.config, "pages")); write(K.content_path(kb.config, "pages", "about.md"), text))
    store = DirStore(mktempdir())
    ada, bea, con = member(:publish, "ada"), member(:publish, "bea"), member(:consume)
    write_page(ada, "Written by Ada.")
    write(joinpath(mkpath(K.content_path(ada.config, "notebooks")), "Manifest.toml"), "each machine's own")
    add_papers!(ada, ["2609.00001"])
    publish!(ada; store)
    @test only(keys(K.JSON.parsefile(joinpath(store.dir, "streams", "ada.json"))["content"])) == "pages/about.md"
    pull!(bea; store)
    @test page(bea) == "Written by Ada."
    # A change made to the file as it is elsewhere is taken there; the one who took it no longer carries it.
    write_page(bea, "Edited by Bea.")
    publish!(bea; store)
    pull!(ada; store); pull!(con; store)
    @test page(ada) == "Edited by Bea." && page(con) == "Edited by Bea."
    publish!(ada; store)
    @test isempty(K.JSON.parsefile(joinpath(store.dir, "streams", "ada.json"))["content"])
    # Both change it: each keeps their own, with the other's set aside; others take the newest.
    write_page(ada, "Ada's version."); write_page(bea, "Bea's version.")
    publish!(ada; store); publish!(bea; store)
    pull!(ada; store)
    @test page(ada) == "Ada's version." && only(K.content_conflicts(ada)).stream == "bea"
    pull!(con; store)
    @test page(con) == "Bea's version."                               # (published in the same second: the stream named last)
    # Settled as Ada's: published as a change to Bea's, which Bea and everyone else then take.
    @test startswith(K.resolve_conflict!(ada, "pages/about.md"; take = false), "pages/about.md stands")
    @test isempty(K.content_conflicts(ada))
    publish!(ada; store)
    pull!(bea; store); pull!(con; store)
    @test page(bea) == "Ada's version." && page(con) == "Ada's version." && isempty(K.content_conflicts(bea))
    # Settled as the other's: the file here becomes it.
    write_page(ada, "Ada again."); write_page(bea, "Bea again.")
    publish!(bea; store)
    pull!(ada; store)
    @test_throws "with cy's version" K.resolve_conflict!(ada, "pages/about.md"; take = true, stream = "cy", hash = "none")
    c = only(K.content_conflicts(ada))
    K.resolve_conflict!(ada, "pages/about.md"; take = true, c.stream, c.hash)
    @test page(ada) == "Bea again." && isempty(readdir(K.conflicts_dir(ada.config)))
    # A deletion travels like a change.
    rm(K.content_path(bea.config, "pages", "about.md"))
    publish!(bea; store)
    pull!(ada; store); pull!(con; store)
    @test page(ada) === nothing && page(con) === nothing
    # A file in a stream where a folder is here is not put in the folder's place.
    write(K.content_path(bea.config, "notes"), "Bea's notes, a file.")
    publish!(bea; store)
    mkpath(K.content_path(ada.config, "notes")); write(K.content_path(ada.config, "notes", "kept.md"), "Ada's, in a folder.")
    pull!(ada; store)
    @test isfile(K.content_path(ada.config, "notes", "kept.md"))
    @test K.safe_content_path("pages/a.md") && !K.safe_content_path("../a.md") && !K.safe_content_path("pages/../../a") &&
          !K.safe_content_path("/etc/passwd") && !K.safe_content_path("pages/.hidden")
    # The member on a new machine takes their stream as it is, and publishing it keeps what it carries;
    # publishing before taking it is refused, as it would drop what the stream holds.
    again = member(:publish, "ada")
    @test_throws "import the dataset first" publish!(again; store)
    @test haskey(K.JSON.parsefile(joinpath(store.dir, "streams", "ada.json"))["documents"], "2609.00001")
    pull!(again; store)
    @test !ismissing(K.paper_id(again, "2609.00001"))
    @test publish!(again; store).documents == 1
    @test haskey(K.JSON.parsefile(joinpath(store.dir, "streams", "ada.json"))["documents"], "2609.00001")
    # The first machine, the stream since published from the second, takes it before publishing again.
    @test_throws "import the dataset first" publish!(ada; store)
    pull!(ada; store)
    @test publish!(ada; store).documents == 1
    # An import cancelled part way notes no stream as imported, so the next takes up from there.
    late = member(:consume)
    @test pull!(late; store, cancelled = () -> true).imported == 0 && K.streams_imported(late) == Dict()
    @test pull!(late; store).imported >= 1 && haskey(K.streams_imported(late), "ada")
    foreach(close, (ada, bea, con, again, late))
end

@zset "setting up a new knowledge base" begin
    HTTP, JSON = K.HTTP, K.JSON
    dir = mktempdir()
    cfg = joinpath(dir, "config", "config.toml")
    withenv("ZEMI_CONFIG" => cfg, "XDG_DATA_HOME" => joinpath(dir, "share")) do
        kb = open_kb(K.load_config())
        call(method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                              body === nothing ? UInt8[] : JSON.json(body)), K.local_caller());
                                                (r.status, JSON.parse(String(r.body))))
        s, setup = call("GET", "/api/config/setup")
        @test s == 200 && setup["needed"] && any(c -> c["id"] == "q-bio.PE", setup["categories"]) && !isempty(setup["summarizers"])
        @test call("GET", "/api/config/setup?needed=1") == (200, Dict("needed" => true))       # the front page's question alone
        answers = Dict("group" => Dict("name" => "Reef Ecology Lab", "field" => "coral reef ecology", "description" => "Reefs after bleaching.",
                                       "focus_areas" => [Dict("name" => "Recovery", "description" => "How reefs recover"), Dict("name" => " ", "description" => "")]),
                       "watch" => ["q-bio.PE", "nowhere.XX"], "contact" => "lab@example.org", "model" => Dict("id" => "deepseek-v4.1-flash"),
                       "dataset" => Dict("mode" => "start", "store" => "dir:" * joinpath(dir, "dataset"), "stream" => "rowan"))
        @test_throws "A focus area needs a name" K.apply_setup!(kb, answers)
        answers["group"]["focus_areas"] = answers["group"]["focus_areas"][1:1]
        s, err = call("POST", "/api/config/setup", answers)
        @test s == 400 && occursin("nowhere.XX", err["error"]) && K.setup_needed(kb)          # nothing was written
        answers["watch"] = ["q-bio.PE"]
        @test call("POST", "/api/config/setup", answers) == (200, Dict("ok" => true, "job" => nothing))
        c = kb.config
        @test !K.setup_needed(kb) && c.group.name == "Reef Ecology Lab" && only(c.group.focus_areas).name == "Recovery"
        @test c.watch_categories == ["q-bio.PE"] && c.summarizer == c.judge == c.code_summarizer == "deepseek-v4.1-flash"
        @test (c.dataset.role, c.dataset.stream, c.dataset.store) == (:publish, "rowan", "dir:" * joinpath(dir, "dataset"))
        @test occursin("coral reef ecology", first(c.layers).query_prefix)     # nothing embedded yet: the layers follow the field
        @test K.load_config().group.name == "Reef Ecology Lab"                  # in the settings file
        # Run again: the models stay as they are unless chosen anew, a new field keeps the layers the
        # vectors were made with, and choosing to read alone leaves the dataset.
        K.save_settings!(kb, Dict("judge" => "opus-agent-pdf"))
        K.execute!(kb, "INSERT INTO papers (doc_id, title, added_at, kind) VALUES ('2609.00009', 'x', '2026-10-01', 'paper')")
        layer = first(kb.config.layers)
        K.execute!(kb, "INSERT INTO layers VALUES (?, ?, 'paper', 4, 'c', '2026-10-01')", (layer.name, layer.model))
        K.execute!(kb, "INSERT INTO embeddings VALUES (?, 'p:2609.00009', ?, 'x', 1, '2026-10-01')",
                   (layer.name, K.paper_id(kb, "2609.00009")))
        prefix = first(kb.config.layers).query_prefix
        again = merge(answers, Dict("group" => merge(answers["group"], Dict("field" => "marine biology")), "dataset" => Dict("mode" => "alone")))
        delete!(again, "model")
        K.apply_setup!(kb, again)
        @test kb.config.judge == "opus-agent-pdf" && kb.config.summarizer == "deepseek-v4.1-flash"
        @test first(kb.config.layers).query_prefix == prefix && kb.config.group.field == "marine biology"
        @test kb.config.dataset.role == :none
        @test K.current_choice(kb.config)["id"] == "deepseek-v4.1-flash"
        @test_throws "endpoint, its name" K.apply_setup!(kb, merge(again, Dict("dataset" => Dict("mode" => "start", "store" => "s3"))))
        # The models offered, and those made from the choice: a local one, another API with its key saved privately.
        @test any(m -> m["id"] == "opus-agent-pdf" && m["agent"] && m["cost"] === nothing, setup["models"])
        @test any(m -> m["id"] == "deepseek-v4.1-flash" && m["cost"] > 0, setup["models"])
        @test !any(m -> m["id"] == "opus-agent-code", setup["models"])                   # chosen with its reader
        agent = K.model_choice(c, Dict("id" => "opus-agent-pdf"); config_dir = dir)
        @test (agent.summarizer, agent.code) == ("opus-agent-pdf", "opus-agent-code")
        local_ = K.model_choice(c, Dict("id" => "ollama", "model" => "qwen3:32b"); config_dir = dir)
        @test local_.summarizer == "ollama-qwen3-32b" && only(local_.summarizers)["url"] == rstrip(c.ollama_url, '/') * "/v1"
        other = K.model_choice(c, Dict("id" => "custom", "url" => "https://api.example.org/v1", "model" => "Reader-2", "key" => "sk-1");
                               config_dir = joinpath(dir, "keys"))
        keyfile = only(other.summarizers)["key"][6:end]
        @test other.summarizer == "reader-2" && strip(read(keyfile, String)) == "sk-1" && filemode(keyfile) & 0o777 == 0o600
        @test_throws "address and model" K.model_choice(c, Dict("id" => "custom"); config_dir = dir)
        # The group's focus areas and the tutoring profile, from the Configuration page.
        K.save_settings!(kb, Dict("group.questions" => [Dict("id" => "stage", "text" => "Your stage?", "options" => ["Student", " ", "Staff"])]))
        @test only(kb.config.group.questions).options == ["Student", "Staff"]
        @test_throws "same id" K.save_settings!(kb, Dict("group.questions" => [Dict("id" => "a", "text" => "A?", "options" => ["x"]),
                                                                              Dict("id" => "a", "text" => "B?", "options" => ["y"])]))
        @test_throws "needs options" K.save_settings!(kb, Dict("group.questions" => [Dict("id" => "a", "text" => "A?", "options" => [])]))
        @test K.coerce_setting("watch.days", "7") === 7 && K.coerce_setting("watch.hours", "1.5") === 1.5 && K.coerce_setting("watch.days", 3) === 3
        # The front page's panels: the default four until the group names its own, kept in the order given.
        @test [p.title for p in kb.config.group.panels] == ["Papers", "Tutor", "Findings", "Projects"]
        K.save_settings!(kb, Dict("group.panels" => [Dict("title" => " Field notes ", "text" => "What we saw.", "link" => "/findings"),
                                                     Dict("title" => "Seminar", "text" => "Thursdays at four.")]))
        @test kb.config.group.panels == [K.Panel("Field notes", "What we saw.", "/findings"), K.Panel("Seminar", "Thursdays at four.", "")]
        @test K.load_config().group.panels == kb.config.group.panels                  # in the settings file too
        page = K.front_page(kb.config)
        @test occursin("- title: \"Field notes\"\n    details: \"What we saw.\"\n    link: \"/findings\"", page) &&
              occursin("- title: \"Seminar\"\n    details: \"Thursdays at four.\"\n", page) && !occursin("Tutor", page)
        @test_throws "needs a title" K.coerce_setting("group.panels", [Dict("text" => "No title")])
        K.save_settings!(kb, Dict("group.panels" => []))
        @test !occursin("features:", K.front_page(kb.config))
        @test_throws "a whole number" K.coerce_setting("watch.days", "seven")
        s, conf = call("GET", "/api/config")
        @test only(x for x in conf["settings"] if x["key"] == "group.focus_areas")["value"] == [Dict("name" => "Recovery", "description" => "How reefs recover")]
        @test only(x for x in conf["settings"] if x["key"] == "dataset.role")["value"] == "none"           # as read alone, above
        @test call("GET", "/api/config/conflicts") == (200, Dict("conflicts" => []))
        # A key someone issued, saved for the dataset it reaches.
        key = """name = "b: rowan"\nrole = "consume"\nendpoint = "https://e.example"\nbucket = "b"\nprefix = "kb"\naccess_key_id = "k"\nsecret_access_key = "s"\n"""
        t = K.save_key(key; config_dir = joinpath(dir, "keys"))
        @test t["role"] == "consume" && t["bucket"] == "b" && filemode(t["credentials"]) & 0o777 == 0o600 && !haskey(t, "stream")
        @test_throws "not a key file" K.save_key("role = \"consume\""; config_dir = joinpath(dir, "keys"))
        close(kb)
    end
end

@zset "the knowledge base's look" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    c = kb.config
    call(method, target, body = UInt8[]) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "image/png"], body), K.local_caller());
                                            (r.status, r.body))
    # Zemi's own images until the content has its own.
    @test !any(b -> b["own"], values(JSON.parse(String(call("GET", "/api/config/brand")[2]))))
    @test first.(K.hero_files(c)) == ["hero-light.svg", "hero-dark.svg"] && occursin("dark: /hero-dark.svg", K.hero_image(c))
    # A logo, not square: centred on a transparent square, then made into the logo, the icon and the favicon.
    red = [K.RGBA{K.N0f8}(1, 0, 0, 1) for _ in 1:60, _ in 1:120]
    @test call("POST", "/api/config/brand/logo", K.png_bytes(red))[1] == 200
    logo = K.PNGFiles.load(K.content_path(c, "assets", "logo.png"))
    @test size(logo) == (256, 256) && K.alpha(logo[10, 128]) == 0 && logo[128, 128] == K.RGBA{K.N0f8}(1, 0, 0, 1)
    @test size(K.PNGFiles.load(K.content_path(c, "assets", "icon.png"))) == (64, 64)
    ico = read(K.content_path(c, "assets", "favicon.ico"))
    @test ico[1:6] == UInt8[0, 0, 1, 0, 3, 0] && ico[7] == 16 && ico[23] == 32 && ico[39] == 48
    @test K.site_icon(c, "favicon.ico") == K.content_path(c, "assets", "favicon.ico")
    # The page shown while the service restarts: its own headline, else the package's.
    @test count("Back in a moment", K.down_page(c)) == 2
    tidy = K.Config(; group = K.Group(; restarting = "Tidying <the> shelves"))
    @test count("Tidying &lt;the&gt; shelves", K.down_page(tidy)) == 2 && !occursin("Back in a moment", K.down_page(tidy))
    @test K.hero_files(c) == ["logo.png" => K.content_path(c, "assets", "logo.png")] && occursin("src: /logo.png", K.hero_image(c))
    @test occursin("at least 64 pixels", String(call("POST", "/api/config/brand/logo", K.png_bytes(red[1:20, 1:20]))[2]))
    @test call("POST", "/api/config/brand/logo", Vector{UInt8}("not an image"))[1] == 400
    # The front page's images: an SVG without scripts or links, or a PNG; one stands in for the other.
    svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\"/></svg>"
    @test call("POST", "/api/config/brand/hero-dark", Vector{UInt8}(svg))[1] == 200
    @test K.hero_files(c) == ["hero-dark.svg" => K.content_path(c, "assets", "hero-dark.svg")]
    @test call("POST", "/api/config/brand/hero-light", K.png_bytes(red))[1] == 200
    @test first.(K.hero_files(c)) == ["hero-light.png", "hero-dark.svg"]
    for bad in ("<svg><script>alert(1)</script></svg>", "<svg onload=\"x()\"></svg>", "<svg><image href=\"https://e.example/x.png\"/></svg>",
                "<svg xmlns:s=\"http://www.w3.org/2000/svg\"><s:script>alert(1)</s:script></svg>", "<svg/onload=\"x()\"></svg>",
                "<!DOCTYPE svg [<!ENTITY x \"y\">]><svg></svg>")
        @test call("POST", "/api/config/brand/hero-dark", Vector{UInt8}(bad))[1] == 400
    end
    @test call("GET", "/api/config/brand/hero-dark")[2] == Vector{UInt8}(svg)
    # Zemi's put back.
    @test call("POST", "/api/config/brand/logo?reset=1")[1] == 200 && !isfile(K.content_path(c, "assets", "favicon.ico"))
    call("POST", "/api/config/brand/hero-light?reset=1"); call("POST", "/api/config/brand/hero-dark?reset=1")
    @test first.(K.hero_files(c)) == ["hero-light.svg", "hero-dark.svg"]
    close(kb)
end

@zset "dataset keys" begin
    HTTP, JSON = K.HTTP, K.JSON
    account = "0123456789abcdef0123456789abcdef"
    tokens = Dict{String,Any}()
    port = 18000 + rand(0:999)
    ok(result) = HTTP.Response(200, JSON.json(Dict("success" => true, "errors" => [], "result" => result)))
    # A stand-in for the Cloudflare API's account token endpoints.
    server = HTTP.serve!("127.0.0.1", port) do req
        HTTP.header(req, "Authorization") == "Bearer issuer" || return HTTP.Response(403, JSON.json(Dict("success" => false,
            "errors" => [Dict("message" => "bad token")])))
        path = HTTP.URI(req.target).path
        base = "/accounts/$account/tokens"
        if req.method == "GET" && path == "$base/permission_groups"
            ok([Dict("id" => "r", "name" => "Workers R2 Storage Bucket Item Read"),
                Dict("id" => "w", "name" => "Workers R2 Storage Bucket Item Write"), Dict("id" => "x", "name" => "Other")])
        elseif req.method == "POST" && path == base
            b = JSON.parse(String(Vector{UInt8}(req.body)))
            id = "tok$(length(tokens) + 1)"
            tokens[id] = Dict("id" => id, "name" => b["name"], "status" => "active", "policies" => b["policies"])
            ok(Dict("id" => id, "value" => "value-of-$id"))
        elseif req.method == "GET" && path == base
            # A page of one at a time, as Cloudflare pages longer lists.
            page = parse(Int, get(HTTP.queryparams(HTTP.URI(req.target)), "page", "1"))
            all = sort!(collect(values(tokens)); by = t -> t["id"])
            HTTP.Response(200, JSON.json(Dict("success" => true, "errors" => [], "result" => all[page:min(page, end)],
                                              "result_info" => Dict("page" => page, "total_pages" => max(length(all), 1)))))
        elseif req.method == "DELETE" && startswith(path, base * "/")
            delete!(tokens, last(split(path, '/'))); ok(Dict())
        else
            HTTP.Response(404, JSON.json(Dict("success" => false, "errors" => [])))
        end
    end
    saved = K.CLOUDFLARE_API[]
    K.CLOUDFLARE_API[] = "http://127.0.0.1:$port"
    try
        dir = mktempdir()
        write(joinpath(dir, "cloudflare_admin"), "api_token = \"issuer\"\n")
        c = Config(; dataset = DatasetConfig(; role = :publish, store = "s3", bucket = "kb-bucket",
            endpoint = "https://$account.r2.cloudflarestorage.com", admin_credentials = joinpath(dir, "cloudflare_admin")))
        key = issue_key(c, "alice")
        @test key.access_key_id == "tok1" && key.secret_access_key == bytes2hex(K.sha256("value-of-tok1"))
        policy = only(tokens["tok1"]["policies"])
        @test only(keys(policy["resources"])) == "com.cloudflare.edge.r2.bucket.$(account)_default_kb-bucket"
        @test [g["id"] for g in policy["permission_groups"]] == ["r"]                    # read-only
        @test [g["id"] for g in only(tokens[issue_key(c, "me"; write = true).token_id]["policies"])["permission_groups"]] == ["r", "w"]
        @test_throws ErrorException issue_key(c, "alice")                               # one key each
        @test Set(k.name for k in list_keys(c)) == Set(["kb-bucket: alice", "kb-bucket: me"])
        # A publisher's name makes their stream, one no other key's holder publishes to.
        @test_throws "makes no stream name" issue_key(c, "李明"; write = true)
        @test_throws "which kb-bucket: alice names too" issue_key(c, "Alice"; write = true)
        @test length(tokens) == 2
        saved_key = K.TOML.parse(K.key_file(c, key))
        @test saved_key["access_key_id"] == "tok1" && saved_key["secret_access_key"] == key.secret_access_key
        quoted = K.with_config(c; group = K.Group(; name = "The \"Reef\" Lab"))
        @test K.TOML.parse(K.key_file(quoted, key))["group"] == "The \"Reef\" Lab"
        @test saved_key["role"] == "consume" && saved_key["bucket"] == "kb-bucket"

        # Its holder installs it: the key saved privately beside their config, whatever that file is
        # named, and the dataset set in its settings file, over a Setup that chose to read alone.
        home = mktempdir()
        cfg = joinpath(home, "kb2.toml")
        write(cfg, "data_dir = \"$(joinpath(home, "data"))\"\n")
        write(K.settings_path(cfg), "[dataset]\nrole = \"none\"\n")
        sent = joinpath(home, "alice.toml")
        write(sent, K.key_file(c, key))
        @test occursin("set the dataset", K.install_key(sent; path = cfg))
        @test filemode(joinpath(home, "r2_read")) & 0o777 == 0o600
        installed = K.load_config(cfg).dataset
        @test installed.role == :consume && installed.bucket == "kb-bucket" && installed.credentials == joinpath(home, "r2_read")
        @test !haskey(K.TOML.parsefile(cfg), "dataset")
        @test occursin("left as it is", K.install_key(sent; path = cfg))
        @test_throws ErrorException K.install_key(joinpath(dir, "cloudflare_admin"); path = cfg)   # not a key file
        # A publisher's key names the stream they publish to, which installing it sets.
        writer = joinpath(home, "rowan.toml")
        write(writer, K.key_file(c, key; write = true, who = "Rowan Hale"))
        @test K.TOML.parsefile(writer)["stream"] == "rowan-hale"
        elsewhere = joinpath(mktempdir(), "config.toml")
        K.install_key(writer; path = elsewhere)
        @test K.load_config(elsewhere).dataset.stream == "rowan-hale"
        revoke_key(c, "alice")
        @test [k.name for k in list_keys(c)] == ["kb-bucket: me"]
        @test_throws K.Refusal revoke_key(c, "alice")

        # The command writes the key to a file only its owner can read, and never prints the secret.
        cfg = joinpath(dir, "zemi")
        mkpath(cfg)
        write(joinpath(cfg, "config.toml"), """
            [dataset]
            role = "publish"
            store = "s3"
            bucket = "kb-bucket"
            endpoint = "https://$account.r2.cloudflarestorage.com"
            admin_credentials = "$(joinpath(dir, "cloudflare_admin"))"
            """)
        out = joinpath(dir, "bob.toml")
        printed = withenv("XDG_CONFIG_HOME" => dir) do
            mktemp() do path, io
                status = redirect_stdout(() -> K.cli(["token", "create", "bob", "--out", out]), io)
                close(io)
                (status, read(path, String))
            end
        end
        @test first(printed) == 0 && isfile(out) && filemode(out) & 0o777 == 0o600
        @test !occursin(K.TOML.parsefile(out)["secret_access_key"], last(printed))
        @test K.cli(["token", "create", "carol"]) == 1                                  # no --out: refused
    finally
        K.CLOUDFLARE_API[] = saved
        close(server)
    end
end

@zset "mutool's recovered errors" begin
    # mutool exits with an error after recovering from a fault in a PDF, having written every page.
    dir = mktempdir()
    script(name, body) = (path = joinpath(dir, name); write(path, "#!/bin/sh\n" * body); chmod(path, 0o755); path)
    recovers = script("recovers", """
        if [ "\$1" = pages ]; then echo '<MediaBox l="0" b="0" r="612" t="792" />'; exit 1; fi
        echo '{"pages": []}' > "\$8"; echo 'syntax error: cannot find ExtGState resource' >&2; exit 1
        """)
    fails = script("fails", "echo 'cannot open document' >&2; exit 1\n")
    blocks, sizes = K.read_stext("x.pdf", Config(; mutool = recovers))
    @test isempty(blocks) && sizes == [(612.0, 792.0)]
    e = try K.read_stext("x.pdf", Config(; mutool = fails)); nothing catch e; e end
    @test e isa ErrorException && occursin("cannot open document", e.msg) && occursin("exit 1", e.msg)
end

@zset "reference lists under any heading" begin
    # A reference list reads as one wherever the reading put it; prose citing its sources does not.
    @test K.reads_as_references("[1] A. J. Hale, M. A. Marsh, Ordered and chaotic motion, Springer (1992). [2] R. da Costa, D. E. Iles, Appl. Math. Model. 40, 123 (2016).")
    @test K.reads_as_references("Okafor, C. C. & Iles, D. 2024 The residual flow in well-mixed lagoons. J. Mar. Res. 90, 905900205. Marsh, B. H. 2015 J. Mar. Res. 81, 515810606.")
    @test K.reads_as_references("Hale, A. & Okafor, C. Coral recovery after bleaching. Nat. Ecol. Evol. 4, 112 (2020). Marsh, B. Larval supply. Proc. Natl. Acad. Sci. 117, 2201 (2019).")
    @test !K.reads_as_references("Artificial reefs, used in the Red Sea (Hale et al. 2001; Marsh et al. 2002) and the Caribbean (Okafor et al. 2019), work by leveraging larval settlement and tidal flows.")
    @test !K.reads_as_references("We show that the reef crest is a barrier to larval transport [12], and that it breaks up when the perturbation grows [13, 14], as was observed in earlier work.")
    @test !K.reads_as_references("Smith et al. 2020")                                       # too short to tell
    # A bibliography after the acknowledgements, with no heading of its own, is kept out of passages.
    piece(kind, text) = K.Piece(kind, 1, (0.0, 0.0, 0.0, 0.0), text, 0, kind == :heading ? 1 : 0, "")
    body = "The reef crest acts as a barrier to larval transport, and it is what we study here in detail."
    bib = "[1] D. del-Monte-Hale, J. M. Marsh, P. J. Okafor, Physica D 91, 1 (1996). [2] G. C. Iles et al., Phys. Rev. E 108, 054201 (2023)."
    p = K.assign_sections([piece(:heading, "1. Introduction"), piece(:paragraph, body), piece(:heading, "Acknowledgments"),
                           piece(:paragraph, "We thank the group for discussions about this work, which was funded by a grant."),
                           piece(:paragraph, bib)], 1)
    @test [x.kind for x in p.pieces if x.kind != :heading] == [:paragraph, :paragraph, :reference]
    @test !any(c -> occursin("del-Monte", c.text), K.chunk_paper(p))
end

@zset "references" begin
    texts(refs) = [r.text for r in refs]
    # Numbered in one block, with a [12] inside an entry left alone.
    refs = split_references(["[1] A. One, J. Phys. 1, 2 (2001), as in [12]. [2] B. Two, Mar. Biol. 57, 066001 (2017). [3] C. Three (2019)."])
    @test [r.label for r in refs] == ["1", "2", "3"] && refs[1].text == "A. One, J. Phys. 1, 2 (2001), as in [12]."
    # Numbered inline after sentences, an entry split across blocks.
    refs = split_references(["1. Hale, J. W. Generalized equations. Phys. Fluids 27, 102504 (2020). 2. Lindt, D. Über die",
                             "Existenz. Z. angew. Math. 21, 196 (1970)."])
    @test length(refs) == 2 && refs[2].text == "Lindt, D. Über die Existenz. Z. angew. Math. 21, 196 (1970)."
    # Author–year, a line per block: an entry starts with an author; a journal's initial is not one.
    refs = split_references(["Alder, D., Lu, R. and Gibb, H.R. (2006). What Is the Role of the",
                             "Tidal Torque? Astrophys. J. Lett., 569, L255, doi:10.1086/",
                             "379530", "Arden, T.D. (2001) A staggered grid code. J. Comp. Phys. 171, 151"])
    @test length(refs) == 2 && refs[1].doi == "10.1086/379530" && endswith(refs[2].text, "J. Comp. Phys. 171, 151")
    # A DOI broken across lines anywhere is joined back; one that ends a sentence is left as it is.
    @test K.reference_doi("Mar. Biol. 61 (2021) 066022, doi:10.1088/1748-9326/\nabf99f") == "10.1088/1748-9326/abf99f"
    @test K.reference_doi("Phys. Fluids 22, 032505 (2015). doi:10.1063/1.\n4920931") == "10.1063/1.4920931"
    @test K.reference_doi("doi:10.1063/5.0015420. Phys. Fluids follows.") == "10.1063/5.0015420"
    @test K.reference_doi("doi:10.1063/5.0015420 (2020)") == "10.1063/5.0015420"
    # The rest of one lost from the text leaves no DOI, rather than half of one.
    @test K.reference_doi("Phys. Fluids 13 (2006) 092309. doi:10.1063/1.") === nothing
    @test K.reference_doi("https://doi.org/10.1063/5. [HM22b] A.E. Hampton") === nothing
    @test K.reference_doi("doi:10.1088/1748-9326/") === nothing
    # Author–year entries run together in one block.
    refs = split_references(["Garner, D. A. & Marsh, A. H. 1991 Existence of tidal fronts. Phys. Fluids B 3, 2822. " *
                             "Iles, Andrew & Okafor, F. 2023 Direct reef mapping. Phys. Fluids 30, 042511. " *
                             "A.H. Marsh. Tidal equilibrium. Phys. Fluids, 24:1999, 1981. arXiv:physics/0403037v1"])
    @test length(refs) == 3 && startswith(refs[2].text, "Iles") && refs[3].arxiv == "physics/0403037"

    # Matching: by arXiv id, DOI, title and journal reference, never to the citing paper itself.
    kb = open_kb(temp_config(; layers = Layer[]))
    for (id, title, doi, journal, authors) in (
            ("2401.00001", "Citing paper", missing, missing, ["Ada Lovelace"]),
            ("2401.00002", "Fast surveys of reefs", missing, missing, ["Bea Bard"]),
            ("2401.00003", "Another short one", "10.1063/5.0015420", missing, ["Cy Chen"]),
            ("2401.00004", "Larval dispersal across fragmented reefs with protected corridors", missing, missing, ["Di Dee"]),
            ("2401.00005", "Untitled in the citation", missing, "Mar. Biol. 57 (2017) 066001", ["Tomi Ames"]))
        K.execute!(kb, """INSERT INTO papers (doc_id, title, doi, journal_ref, authors, added_at, metadata_at, kind)
                          VALUES (?, ?, ?, ?, ?, ?, ?, 'paper')""", (id, title, doi, journal, K.JSON.json(authors), K.now_iso(), K.now_iso()))
    end
    ix = K.ReferenceIndex(kb)
    cites(text) = (r = K.cited_paper(ix, K.reference("1", text); citing = "2401.00001"); r === nothing ? nothing : r)
    @test cites("B. Bard, Fast surveys, arXiv:2401.00002 (2024).") == ("2401.00002", :arxiv)
    @test cites("C. Chen, Phys. Fluids 27, 102504, doi: 10.1063/5.0015420.") == ("2401.00003", :doi)
    @test cites("D. Dee, Larval dispersal across fragmented reefs with protected corridors, J. Mar. Res. (2023).") == ("2401.00004", :title)
    @test cites("T. Ames et al., Mar. Biol. 57, 066001 (2017).") == ("2401.00005", :journal)
    @test cites("T. Ames et al., Mar. Biol. 58, 066001 (2017).") === nothing              # another volume
    @test cites("A. Lovelace, arXiv:2401.00001.") === nothing                             # not itself
    @test cites("Fast surveys of reefs") === nothing                                      # a short title alone does not match
    # An upload titled with its journal's name is not every paper that journal printed.
    K.execute!(kb, """INSERT INTO papers (doc_id, title, authors, added_at, metadata_at, kind)
                      VALUES ('doc-journal', 'Journal of Computational Physics and Numerical Methods', '[]', ?, ?, 'paper')""", (K.now_iso(), K.now_iso()))
    jx = K.ReferenceIndex(kb)
    @test K.cited_paper(jx, K.reference("1", "C. Sorensen et al., Nonlinear waves, Journal of Computational Physics and Numerical Methods, vol. 195, pp. 355–386, 2004.");
                        citing = "2401.00001") === nothing
    @test K.cited_paper(jx, K.reference("2", "A survey, in Journal of Computational Physics and Numerical Methods 12 (2004) 1."); citing = "2401.00001") === nothing
    @test K.cited_paper(jx, K.reference("4", "O. K. and L. C., A fully implicit algorithm, Journal of Computational Physics and Numerical Methods, p. 113381, 2024.");
                        citing = "2401.00001") === nothing
    @test K.cited_paper(jx, K.reference("3", "The book \"Journal of Computational Physics and Numerical Methods\", Springer."); citing = "2401.00001") ==
          ("doc-journal", :title)

    # A page lists its references, names those in the knowledge base, and a cited paper lists who cites it.
    K.store_parse!(kb, "2401.00001", K.ParsedPaper(1, [
        K.Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), "References", 1, 1, ""),
        K.Piece(:reference, 1, (0.0, 0.0, 0.0, 0.0), "[1] T. Ames et al., Mar. Biol. 57, 066001 (2017). [2] Someone, Elsewhere 1, 2 (2000).", 1, 0, "")],
        [K.Section(1, 1, "", "References", "References", 1, 1)]))
    data = K.paper_json(K.site_paper(kb, "2401.00001"; related = false))
    @test only(data["sections"])["references"] && length(data["references"]) == 2 && data["references"][2]["label"] == "2" &&
          startswith(data["references"][2]["text"], "Someone")
    @test [(h["slug"], h["title"], h["label"]) for h in data["here"]] == [("2401-00005", "Untitled in the citation", "1")]
    site, public = mktempdir(), mktempdir()
    written = write_site(kb, site, public; related = false)
    cited = K.JSON.parsefile(joinpath(public, "kb-data", "papers", "2401-00005.json"))["cited_by"]
    @test [(c["slug"], c["title"]) for c in cited] == [("2401-00001", "Citing paper")]
    # Who cites a paper, for agents, found without reading every paper's references.
    @test [(c.doc_id, c.label) for c in K.citing_papers(kb, "2401.00005")] == [("2401.00001", "1")]
    @test isempty(K.citing_papers(kb, "2401.00002"))
    @test K.site_from_json(K.site_json(written)) == written          # what the service wrote, as a build process reads it
    close(kb)
end

@zset "studies" begin
    HTTP, JSON = K.HTTP, K.JSON
    dir = mktempdir()
    write(joinpath(dir, "study.toml"), """
        title = "Restoration"
        question = "What has been done?"
        audience = "A newcomer."
        context = "Notebooks and a cluster."
        [[themes]]
        name = "Restoration methods"
        description = "Coral gardening and larval reseeding."
        queries = ["coral gardening"]
        arxiv = ["abs:restoration"]
        [[themes]]
        name = "AI, computation & GPUs"
        queries = ["surrogate"]
        arxiv = ["abs:GPU"]
        [[syntheses]]
        name = "Overview"
        slug = "overview"
        instructions = "Answer the question."
        """)
    study = load_study(dir)
    @test study.audience == "A newcomer." && [K.slugify(t.name) for t in study.themes] == ["restoration-methods", "ai-computation-gpus"]
    @test only(study.syntheses).slug == "overview"

    # Overlaps and crossings between themes.
    paper(id, year) = K.EvidencePaper(; id, title = "Paper $id", authors = ["A. Author"], year, strength = 1.0, queries = 1, passages = K.Passage[])
    ev = [study.themes[1] => [paper("2401.00001", "2024"), paper("2401.00002", "2023")],
          study.themes[2] => [paper("2401.00002", "2023"), paper("2401.00003", "2023")]]
    @test theme_overlaps(ev) == [2 1; 1 2]
    @test [(c.paper.id, c.themes) for c in crossings(ev, "Restoration methods")] == [("2401.00002", ["AI, computation & GPUs"])]
    @test theme_timeline(ev)[2] == ("AI, computation & GPUs" => [("2023", 2)])

    # Candidates: what the searches find that the knowledge base lacks, with the themes that found it.
    meta(id) = K.PaperMeta(; doc_id = id, version = "v1", title = "On $id", abstract = "", authors = String[],
                           published = "2024-01-01", updated = "2024-01-01", primary_category = "physics.ao-ph", categories = String[])
    kb = open_kb(temp_config(; layers = Layer[], ollama_url = "http://127.0.0.1:1"))
    add_papers!(kb, ["2401.00001"])
    fake(q, c; max_results) = q == "abs:restoration" ? [meta("2401.00001"), meta("2401.00009")] : [meta("2401.00009"), meta("2401.00008")]
    cands = find_candidates(kb, study; search = fake)
    @test [c.meta.doc_id for c in cands] == ["2401.00009", "2401.00008"] && all(c -> isnan(c.similarity), cands)
    @test only(c.themes for c in cands if c.meta.doc_id == "2401.00009") == ["Restoration methods", "AI, computation & GPUs"]

    # Drafts: written by the summarizer, kept while their inputs stand, never over an edit.
    asked = Ref(0)
    port = 19000 + rand(0:999)
    chat = HTTP.serve!("127.0.0.1", port) do req
        HTTP.URI(req.target).path == "/v1/models" && return HTTP.Response(200, "{}")
        asked[] += 1
        reply = "A section citing [arXiv:2401.00001] and [arXiv:2999.99999]."
        HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => reply))])))
    end
    try
        s = Summarizer(; name = "writer", url = "http://127.0.0.1:$port/v1", model = "m")
        kb2 = open_kb(temp_config(; layers = Layer[], summarizers = [s], summarizer = "writer", code_summarizer = "writer", judge = "writer"))
        add_papers!(kb2, ["2401.00001"])
        K.execute!(kb2, "UPDATE papers SET title = 'Paper one', authors = '[\"Ada Lovelace\"]', published = '2024-01-02', abstract = 'About it.'")
        theme = study.themes[1]
        papers = [paper("2401.00001", "2024")]
        @test draft_theme!(kb2, study, theme, papers).written && asked[] == 1
        @test draft_theme!(kb2, study, theme, papers).reason == "up to date" && asked[] == 1
        @test draft_theme!(kb2, study, theme, papers; force = true).written && asked[] == 2
        path = joinpath(dir, "restoration-methods.md")
        write(path, read(path, String) * "\nMy own note.\n")
        @test draft_theme!(kb2, study, theme, papers; force = true).reason == "edited since it was drafted" && asked[] == 2
        @test draft_synthesis!(kb2, study, only(study.syntheses)).written && asked[] == 3
        shown = draft_markdown(kb2, study, "restoration-methods")
        @test occursin("[@arXiv:2401.00001]", shown) && occursin("(arXiv:2999.99999)", shown)
        bib = read(write_study_bib(kb2, study), String)
        @test occursin("@article{arXiv:2401.00001,", bib) && occursin("author = {Lovelace, Ada}", bib)
        @test occursin("journal = {arXiv preprint arXiv:2401.00001}", bib)
        @test occursin("docpage = {generated/kb/papers/2401-00001.md}", bib) && occursin("url = {https://arxiv.org/abs/2401.00001}", bib)
        @test !occursin("2999.99999", bib)                                                   # not in the knowledge base
        md(x) = sprint(show, MIME("text/markdown"), x)
        text = study_text(kb2, study, "restoration-methods")
        @test md(text) == shown && sprint(show, MIME("text/plain"), text) == shown          # whole, either way
        @test occursin("Not drafted yet", md(study_text(kb2, study, "missing")))
        table = md(papers_table(kb2, papers))
        @test occursin("| [Paper 2401.00001](slate-docpage:generated/kb/papers/2401-00001.md) · Author | abstract |", table)
        @test occursin("2401-00002.md", md(crossings_table(ev, "Restoration methods")))
        @test startswith(md(overlaps_table(ev)), "| | Restoration methods | AI, computation & GPUs |")
        @test occursin("My own note.", shown)
        close(kb2)
    finally
        close(chat)
    end
    close(kb)
end

@zset "version checks" begin
    # A quarter of the time since the latest version, between a week and half a year.
    now = K.DateTime(2026, 10, 1)
    due(latest, checked) = K.version_check_due(latest, checked; now)
    @test !due("2026-09-20", "2026-09-28T00:00:00Z") && due("2026-09-20", "2026-09-23T00:00:00Z")   # new: weekly
    @test !due("2025-10-01", "2026-08-01T00:00:00Z") && due("2025-10-01", "2026-06-01T00:00:00Z")   # a year: quarterly
    @test !due("2020-01-01", "2026-05-01T00:00:00Z") && due("2020-01-01", "2026-03-01T00:00:00Z")   # old: half-yearly
    @test due("2020-01-01", missing) && due(missing, "2026-01-01T00:00:00Z")
end

@zset "landscape" begin
    HTTP, JSON = K.HTTP, K.JSON
    qdrant, colls, qport = standin_qdrant()
    # A stand-in for the embedding and chat APIs: a text's vector counts its topic words, so papers on
    # one topic sit together, and the namer names each group it is asked about.
    topics = ["coral", "kelp", "engineering"]
    vectorize(text) = [[Float64(count(w, lowercase(text))) for w in topics]; 0.05 * (hash(text) % 7)]
    asked = Ref(0)
    eport = 19000 + rand(0:999)
    service = HTTP.serve!("127.0.0.1", eport) do req
        path = HTTP.URI(req.target).path
        path == "/v1/models" && return HTTP.Response(200, "{}")
        body = JSON.parse(String(req.body))
        if path == "/v1/embeddings"
            HTTP.Response(200, JSON.json(Dict("data" => [Dict("index" => i - 1, "embedding" => vectorize(t))
                                                         for (i, t) in enumerate(body["input"])])))
        elseif path == "/v1/chat/completions"
            asked[] += 1
            prompt = string(body["messages"][end]["content"])
            groups = [parse(Int, m.captures[1]) for m in eachmatch(r"Group (\d+) \(", prompt)]
            reply = Dict("groups" => [Dict("group" => j, "name" => "Group $j", "description" => "Papers of group $j.") for j in groups])
            HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => JSON.json(reply)))])))
        else
            HTTP.Response(404, "{}")
        end
    end
    saved = qdrant_state()
    try
        url = "http://127.0.0.1:$eport/v1"
        namer = Summarizer(; name = "namer", url, model = "m")
        c = temp_config(; qdrant_url = "http://127.0.0.1:$qport", layers = [Layer(; name = "paper-t", model = "m", unit = :paper, url)],
                        summarizers = [namer], summarizer = "namer", code_summarizer = "namer", judge = "namer",
                        landscape_clusters = 3, group = K.Group(; focus_areas = [FocusArea("Corals", "coral"), FocusArea("Engineering", "engineering")]))
        kb = open_kb(c)
        topic_of = Dict{String,String}()
        for (t, topic) in enumerate(topics), i in 1:6
            id = "2609.$(lpad(10t + i, 5, '0'))"
            topic_of[id] = topic
            K.execute!(kb, """INSERT INTO papers (doc_id, title, abstract, added_at, kind, metadata_at, published)
                              VALUES (?, ?, ?, ?, 'paper', ?, '2025-0$i-01')""",
                       (id, "A $topic study, part $i", "On the $topic, and the $topic again.", K.now_iso(), K.now_iso()))
        end
        @test count(t -> t.action == :embed, sync_plan(kb)) == 18
        r = sync!(kb; arxiv = false, classify = false)
        @test r.embedded == 18 && isempty(r.failed) && r.landscape.changed && !any(t -> t.action == :embed, sync_plan(kb))
        d = r.landscape.data
        @test length(d["papers"]) == 18 && length(d["clusters"]) == 3 && asked[] == 1
        # Each cluster is one topic, named by the namer, and each paper is nearest its own topic's area.
        for cl in d["clusters"]
            @test length(unique(topic_of[p["id"]] for p in d["papers"] if p["cluster"] == cl["id"])) == 1
            @test cl["named"] && startswith(cl["name"], "Group ") && cl["size"] == 6
        end
        area(id) = only(p["area"] for p in d["papers"] if p["id"] == id)
        @test area("2609.00011") == 1 && area("2609.00031") == 2
        relevance(topic) = maximum(p["relevance"] for p in d["papers"] if topic_of[p["id"]] == topic)
        @test relevance("kelp") < relevance("coral")
        @test all(0 <= p["x"] <= 1 && 0 <= p["y"] <= 1 for p in d["papers"])
        # Unchanged vectors: nothing is rebuilt. Rebuilt anyway, the clusters keep their names unasked.
        @test !landscape!(kb).changed && asked[] == 1
        again = landscape!(kb; force = true)
        @test again.changed && asked[] == 1 && sort([cl["name"] for cl in again.data["clusters"]]) == sort([cl["name"] for cl in d["clusters"]])
        @test read_landscape(c)["input_sha"] == d["input_sha"]
        # Classifying a paper shows its relevance on the landscape.
        K.execute!(kb, "INSERT INTO classifications VALUES (?, 'namer', 'm', '{\"relevance\": 3, \"one_line\": \"Corals.\"}', ?)",
                   (K.paper_id(kb, "2609.00011"), K.now_iso()))
        classified = landscape!(kb)
        @test classified.changed && asked[] == 1 &&
              only(p for p in classified.data["papers"] if p["id"] == "2609.00011")["llm_relevance"] == 3
        d = classified.data
        @test K.keyword_label(["A coral study", "Coral polyps"], ["A kelp study", "A coral study", "Coral polyps"]) ==
              "polyps · coral"
        # A cluster of papers with no titles yet is left for later rather than named from its ids.
        untitled = K.name_clusters!(kb, [["2609.99901", "2609.99902"]], [String[]], ["2609.99901", "2609.99902"])
        @test asked[] == 1 && !only(untitled).named

        # The site draws it, and a consumer gets it with the dataset.
        site, public = mktempdir(), mktempdir()
        nav = write_site(kb, site, public; related = false)
        @test nav.landscape == "landscape.md" && occursin("<KBLandscape", read(joinpath(site, "landscape.md"), String))
        @test JSON.parsefile(joinpath(public, "landscape.json"))["input_sha"] == d["input_sha"]
        store = DirStore(mktempdir())
        publish!(kb; store)
        con = open_kb(temp_config(qdrant_url = "http://127.0.0.1:$qport", layers = Layer[], dataset = DatasetConfig(; role = :consume)))
        pull!(con; store)
        @test read_landscape(con.config)["input_sha"] == d["input_sha"]

        # Sync classifies a document as soon as it has read it, in the same sync.
        repo = mktempdir()
        write(joinpath(repo, "Tool.jl"), "\"Add two numbers.\"\nadd(a, b) = a + b\n")
        code = add_codebase!(kb, repo; name = "Tool")
        r = sync!(kb; arxiv = false)
        @test only(r.ingested).ok && code in r.classified && isempty(r.failed)
        @test K.scalar(kb, "SELECT classifier FROM classifications WHERE paper_id = ?", (K.paper_id(kb, code),)) == "namer"

        # Watching arXiv: new papers in the categories, placed against the focus areas and the library;
        # old ones, those already here and those already watched are passed over.
        meta(id, title, published) = K.PaperMeta(; doc_id = id, version = "v1", title, abstract = title, authors = ["A. Author"],
                                                 published, updated = published, primary_category = "physics.ao-ph", categories = String[])
        posted = [meta("2610.00001", "A new coral coral design", "2026-10-01"),
                  meta("2610.00002", "An engineering engineering review", "2026-09-30"),
                  meta("2609.00011", "Already here", "2026-10-01"),
                  meta("2601.00001", "An old coral paper", "2026-01-01")]
        cats = String[]
        list(cat, since, c) = (push!(cats, cat); @test since == K.Dates.Date(2026, 9, 25); posted)
        w = K.with_config(kb.config; watch_categories = ["physics.ao-ph"], watch_days = 7)
        wkb = K.KB(w, kb.db, kb.lock)
        now = K.Dates.DateTime(2026, 10, 2)
        @test watch!(wkb; list, now) == 2 && cats == ["physics.ao-ph"]
        got = watched(wkb)
        @test [p.id for p in got] |> sort == ["2610.00001", "2610.00002"]
        coral = only(p for p in got if p.id == "2610.00001")
        @test coral.area == "Corals" && topic_of[first(coral.nearest).id] == "coral" && length(coral.nearest) == 3
        @test only(p for p in got if p.id == "2610.00002").area == "Engineering"
        K.execute!(wkb, "DELETE FROM kv WHERE key = 'watch_checked_at'")
        @test watch!(wkb; list, now) == 0                                   # watched already
        @test !ismissing(K.scalar(wkb, "SELECT value FROM kv WHERE key = 'watch_checked_at'"))   # and checked, so not again at once
        add_papers!(kb, ["2610.00001"])
        @test [p.id for p in watched(wkb)] == ["2610.00002"]                # once added, not new any more
        close(kb); close(con)
    finally
        restore_qdrant!(saved)
        close(qdrant); close(service)
    end
end

@zset "what this machine can run" begin
    saved_agents, saved_qdrant = K.AGENTS_AVAILABLE[], qdrant_state()
    try
        K.AGENTS_AVAILABLE[] = () -> false
        layers = [Layer(; name = "paper-summary-t", model = "qwen3-embedding:4b", unit = :paper, source = "opus-agent-pdf"),
                  Layer(; name = "hosted-t", model = "m", unit = :chunk, url = "https://example.com/v1", key = "env:ZEMI_NO_SUCH_KEY")]
        kb = open_kb(temp_config(; layers, mutool = "no-such-mutool", ollama_url = "http://127.0.0.1:1", qdrant_url = "http://127.0.0.1:1",
                                 summarizer = "opus-agent-pdf", code_summarizer = "opus-agent-code"))
        gone = K.unavailable(kb; fresh = true)
        @test Set(keys(gone)) == Set([:parser, :embedder, :qdrant, :summarizer, :code_summarizer, :record_summarizer])
        @test occursin("no-such-mutool", gone[:parser]) && occursin("opus-agent-code", gone[:code_summarizer])
        @test occursin("Ollama is not running", gone[:embedder]) && occursin("ZEMI_NO_SUCH_KEY", gone[:embedder])
        # While the service starts Qdrant and its Kaimon, they are said to be starting. Once it has
        # started, that check is given once more while a new one is made, without waiting on it.
        K.STARTING[] = true
        starting = K.unavailable(kb; fresh = true)
        @test starting[:qdrant] == "Qdrant is starting" && occursin("Kaimon is starting", starting[:summarizer])
        @test K.UNAVAILABLE[].starting && !K.services_stale(K.UNAVAILABLE[])
        K.STARTING[] = false
        @test K.services_stale(K.UNAVAILABLE[]) && K.unavailable(kb)[:qdrant] == "Qdrant is starting"
        @test timedwait(() -> !K.UNAVAILABLE[].starting, 30) == :ok
        @test occursin("not answering", K.unavailable(kb)[:qdrant])
        # A check half a minute old is given, and replaced in the background.
        K.UNAVAILABLE[] = (; at = time() - 60, out = Dict(:qdrant => "an old answer"), starting = false)
        @test K.unavailable(kb) == Dict(:qdrant => "an old answer")
        @test timedwait(() -> K.UNAVAILABLE[].at > time() - 30, 30) == :ok && occursin("not answering", K.unavailable(kb)[:qdrant])
        # A codebase is read from its files, so it needs no PDF parser; removing needs nothing.
        @test K.action_needs(kb.config, "ingest") == [:parser, :embedder, :qdrant, :summarizer]
        @test K.action_needs(kb.config, "ingest"; kind = K.CODEBASE) == [:embedder, :qdrant, :code_summarizer]
        @test K.action_needs(kb.config, "classify"; kind = K.CODEBASE) == [:summarizer]
        @test isempty(K.action_needs(kb.config, "drop"))
        @test isempty(K.action_needs(temp_config(; layers = Layer[]), "ingest"; kind = K.CODEBASE))
        add_papers!(kb, ["2609.00001"])
        @test isempty(K.cannot_run(kb, "refresh", ["2609.00001"]))
        e = try K.start_action(kb, "ingest", ["2609.00001"]); nothing catch e; e end
        @test e isa ErrorException && startswith(e.msg, "Can't ingest here: MuPDF")
        # Documents are still listed, but none are added where they cannot be read.
        request(method, target, body = UInt8[]) = K.respond_local(kb, K.HTTP.Request(method, target,
            ["X-Zemi" => "1", "Content-Type" => "application/json"], body)).status
        @test request("GET", "/api/documents?q=2609.00001") == 200
        @test request("POST", "/api/documents", K.JSON.json(Dict("arxiv" => "2609.00002"))) == 400
        cannot = K.status_json(kb)["cannot"]
        @test length(cannot["ingest"]["paper"]) == 4 && isempty(cannot["drop"]["paper"])
        # Sync leaves what it cannot read for a machine that can, and says so.
        r = sync!(kb; arxiv = false, classify = false, plan = filter(t -> t.action == :ingest, sync_plan(kb; unread = true)))
        @test isempty(r.ingested) && first(only(r.failed)) == "reading 1 document(s)"
        close(kb)
    finally
        K.AGENTS_AVAILABLE[] = saved_agents
        restore_qdrant!(saved_qdrant)
        K.UNAVAILABLE[] = (; at = 0.0, out = Dict{Symbol,String}(), starting = false)
        K.STARTING[] = false
    end
end

@zset "a project's map: its threads, where each stands, and what waits" begin
    kb = open_kb(temp_config(layers = Layer[]))
    me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    (; Date, Day, DateTime) = K.Dates
    K.create_project!(kb, "Edge"; key = "ED", by = me)
    K.create_milestone!(kb, "ED", "Paper"; due = "2026-11-15")
    add_papers!(kb, ["2609.00001"])
    settling = K.create_task!(kb, "ED", "Settlement rates"; milestone = "Paper", status = "in_progress", by = me)
    found = K.create_task!(kb, "ED", "Count the recruits"; parent = settling, status = "done", by = me)
    expand = K.create_task!(kb, "ED", "Expand the settlement model"; parent = settling, status = "ready", by = me)
    figures = K.create_task!(kb, "ED", "Figures"; status = "review", by = me)
    K.decline_task!(kb, K.create_task!(kb, "ED", "Dropped"; status = "proposed", by = bot); by = me)
    K.note_task!(kb, found, "Cycles to period 16."; kind = "progress", by = bot)
    K.note_task!(kb, figures, "Which colour map?"; kind = "question", by = bot)
    K.link_task!(kb, settling, "paper", "2609.00001"; by = me)
    f = K.create_finding!(kb, "ED", "The model matches the counts"; evidence = [(; kind = "task", target = found)], by = bot)
    # Read as the service sends it: every task but the declined, with what they rest on and link to.
    m = K.read_project_map(K.JSON.parse(K.JSON.json(K.project_map(kb, "ed"))))
    @test sort(collect(keys(m.tasks))) == sort([settling, found, expand, figures]) && m.tasks[found].parent == settling
    @test only(m.findings).ref == f && only(m.findings).tasks == [found]
    @test (settling, "paper", "2609.00001") in [(l.task, l.kind, l.target) for l in m.links]
    @test only(m.milestones).due == Date(2026, 11, 15) && only(m.milestones).start == Date(m.generated)
    # Threads: a milestone's tasks, then each task in none; or named by hand, the rest under Other.
    ts = K.threads(m)
    @test [(t.name, t.roots) for t in ts] == [("Paper", [settling]), ("No milestone", [figures])]
    @test [(t.name, t.roots) for t in K.threads(m; groups = ["Settling" => [lowercase(settling)]])] == [("Settling", [settling]), ("Other", [figures])]
    # A task in another milestone than the one above it goes to its own milestone's thread.
    K.create_milestone!(kb, "ED", "Week")
    K.update_task!(kb, expand; milestone = "Week", by = me)
    moved = K.read_project_map(kb, "ED")
    @test [(t.name, t.tasks) for t in K.threads(moved)] == [("Paper", [settling, found]), ("Week", [expand]), ("No milestone", [figures])]
    K.update_task!(kb, expand; milestone = "Paper", by = me)
    # A subtask named on its own is its thread's, and leaves the thread above it.
    @test [(t.name, t.tasks) for t in K.threads(m; groups = ["Settling" => [settling], "Escape" => [expand]])] ==
          [("Settling", [settling, found]), ("Escape", [expand]), ("Other", [figures])]
    s = K.thread_state(m, ts[1])
    @test (s.state, s.done, s.total, [x.ref for x in s.next]) == ("active", 1, 3, [settling, expand])
    s = K.thread_state(m, ts[2])
    @test [x.ref for x in s.review] == [figures] && only(s.asked).text == "Which colour map?"
    @test K.thread_state(m, ts[1]; now = m.generated + Day(20)).state == "dormant"
    @test sum(values(K.activity_by_day(m, ts[1]))) == 4                 # three made and a note
    # Planning is not work: a move between the planning columns leaves a thread as it was.
    K.update_task!(kb, expand; status = "backlog", priority = 1, by = me)
    later = K.read_project_map(kb, "ED")
    @test sum(values(K.activity_by_day(later, K.threads(later)[1]))) == 4
    table = K.glance_markdown(m, ts)
    @test occursin("| Paper | active | 1/3 |", table) && occursin("| No milestone | active | 0/1 |", table) && occursin("1 in Review, 1 question |", table)
    text = K.summary_markdown(m, ts)
    @test occursin("2 threads, 2 still open", text) && occursin("1 finding drafted: $f.", text) && occursin("Due next: Paper (15 Nov).", text)
    @test occursin("Waiting on a person: 1 in Review, 1 question from agents.", text)
    # What is finished: a done task whose parent is not, with what is under it and when it was done.
    done = only(K.finished(m))
    @test (done.ref, done.subtasks, done.commits) == (found, 0, 0) && done.at == K.done_at(m, found)
    @test occursin("**$found** Count the recruits · done", K.finished_markdown(m)) && occursin("**$f** (draft,", K.finished_markdown(m))
    # Its codebase as read: each file's size, definitions and summary.
    root = mktempdir()
    write(joinpath(root, "edge.jl"), "\"Trace a line.\"\nfunction trace(x)\n    x\nend\n\nstep(x) = x + 1\n")
    mkpath(joinpath(root, "notebooks"))
    write(joinpath(root, "notebooks", "scan.jl"), "#%% code id=run\ny = trace(1)\n")
    write(joinpath(root, "notebooks", "other.jl"), "#%% code id=run\nz = 2\n")
    code = K.add_codebase!(kb, root; name = "edge")
    K.parse_code!(kb, code)
    K.update_project!(kb, "ED"; codebase = code, by = me)
    withcode = K.read_project_map(K.JSON.parse(K.JSON.json(K.project_map(kb, "ED"))))
    @test [(f.path, f.definitions, f.work, f.used_by) for f in withcode.code] == [("edge.jl", 2, Dict{String,Int}(), ["notebooks/scan.jl"])]
    @test only(withcode.code).lines > 0
    # Its notebooks, with the files whose definitions they call and the tasks that link to them.
    K.link_task!(kb, settling, "notebook", "notebooks/scan.jl"; by = me)
    nbs = K.read_project_map(K.JSON.parse(K.JSON.json(K.project_map(kb, "ED")))).notebooks
    @test sort([(n.path, n.uses, n.tasks) for n in nbs]) == [("notebooks/other.jl", String[], String[]), ("notebooks/scan.jl", ["edge.jl"], [settling])]
    # Times from git carry an offset.
    @test K.parse_iso("2026-10-05T12:00:00-07:00") == DateTime(2026, 10, 5, 19) && K.parse_iso("2026-10-05T12:00:00Z") == DateTime(2026, 10, 5, 12)
    @test K.parse_iso("2026-10-05T12:00:00+0530") == DateTime(2026, 10, 5, 6, 30) && K.parse_iso("2026-10-05T12:00:00.250Z") == DateTime(2026, 10, 5, 12)
    @test_throws "Not an ISO 8601 time" K.parse_iso("yesterday")
    @test K.iso(DateTime(2026, 10, 5, 12, 0, 9)) == "2026-10-05T12:00:09Z" && K.iso(0.9) == "1970-01-01T00:00:00Z"
    close(kb)
end

@zset "a project's library" begin
    kb = open_kb(temp_config(layers = Layer[]))
    me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    K.create_project!(kb, "Edge"; key = "ED", by = me)
    add_papers!(kb, ["2609.00001", "2609.00002"])
    # A person's item is kept, with why it matters; an agent's is proposed until a person keeps it.
    a = K.library_add!(kb, "ED", "@arXiv:2609.00001"; why = "The scan's method.", by = me)
    b = K.library_add!(kb, "ED", "2609.00002"; why = "A rival result.", by = bot)
    @test [(x.target, x.status) for x in K.library(kb, "ED")] == [("2609.00001", "kept"), ("2609.00002", "proposed")]
    @test_throws "Only a person" K.library_keep!(kb, "ED", b; by = bot)
    @test_throws "No paper" K.library_add!(kb, "ED", "2609.99999"; by = me)
    @test_throws "A library holds" K.library_add!(kb, "ED", "@ED-1"; by = me)
    @test K.library_add!(kb, "ED", "2609.00001"; why = "Its method.", by = me) == a && first(K.library(kb, "ED")).why == "Its method."
    K.library_keep!(kb, "ED", b; by = me)
    @test all(x -> x.status == "kept", K.library(kb, "ED")) && K.library_papers(kb, "ED") == Set(["2609.00001", "2609.00002"])
    @test_throws "only what an agent proposed" K.library_remove!(kb, "ED", a; by = bot)
    # What cites an item: the project's tasks that link to it, and its findings that rest on it.
    t = K.create_task!(kb, "ED", "Reproduce the scan"; by = me)
    K.link_task!(kb, t, "paper", "2609.00001"; by = me)
    f = K.create_finding!(kb, "ED", "The scan holds"; evidence = [(; kind = "paper", target = "2609.00001")], by = me)
    x = first(K.library(kb, "ED"))
    @test x.tasks == [t] && x.findings == [f]
    # The project's codebase is always in it, first; agents read it all as text.
    code = K.add_codebase!(kb, mktempdir(); name = "edge")
    K.update_project!(kb, "ED"; codebase = code, by = me)
    @test (first(K.library(kb, "ED")).kind, first(K.library(kb, "ED")).id) == ("codebase", 0)
    text = K.format_library(kb, "ED")
    @test occursin("- paper arXiv:2609.00001: Its method. · cited by $t, $f", text) && occursin("- codebase $code", text)
    # The libraries holding a source, for its page, named there as a full reference.
    K.create_project!(kb, "Wall"; key = "WA", by = me)
    K.library_add!(kb, "WA", "@[2609.00002](paper:2609.00002)"; by = bot)
    @test K.library_holding(kb, "paper", "2609.00002") == Dict("ED" => (; id = b, status = "kept", why = "A rival result."),
                                                              "WA" => (; id = b + 1, status = "proposed", why = ""))
    @test K.library_holding(kb, "codebase", code)["ED"].id == 0
    # Searching within it.
    @test [h.doc_id for h in K.search(kb, "2609.00002 2609.00001"; only = Set(["2609.00001"]))] == ["2609.00001"]
    K.library_remove!(kb, "ED", b; by = me)
    @test K.library_papers(kb, "ED") == Set(["2609.00001"])
    close(kb)
end

@zset "searching for the tasks a person took part in" begin
    kb = open_kb(temp_config(layers = Layer[]))
    K.add_test_account!(kb, "Benedikt Okafor"; roles = String[])
    ada_id = K.add_test_account!(kb, "Ada Byron"; roles = String[])
    ben, ada = K.person("Benedikt Okafor"), K.person("Ada Byron")
    K.create_project!(kb, "Edge"; key = "ED", owner = ada_id, by = ada)
    made = K.create_task!(kb, "ED", "Trace the currents"; by = ben)
    noted = K.create_task!(kb, "ED", "Map the spawning sites"; by = ada)
    K.note_task!(kb, noted, "The reef model is too coarse"; by = ben)
    moved = K.create_task!(kb, "ED", "Fit the growth curves"; by = ada)
    K.update_task!(kb, moved; status = "ready", by = K.agent("Claude for Benedikt Okafor"))         # their agent, for them
    given = K.create_task!(kb, "ED", "Check the reef"; by = ada)
    K.set_member!(kb, "ED", "benedikt-okafor@example.test", "contributor"; by = "ada-byron@example.test")
    K.update_task!(kb, given; assignee = "benedikt-okafor@example.test", by = ada)
    named = K.create_task!(kb, "ED", "Ask Benedikt about the reef"; by = ada)
    K.link_task!(kb, named, "person", "benedikt-okafor@example.test"; by = ada)                 # names him
    K.create_task!(kb, "ED", "Unrelated"; by = ada)
    nomeaning = (kb, t) -> Tuple{Int,String}[]
    refs(q) = Set(h.ref for h in K.search_tasks(kb, q; meaning = nomeaning))
    his = Set([made, noted, moved, given, named])
    # A name alone, its beginnings, or one letter off; a filter; a reference as the board writes it.
    @test refs("Benedict") == refs("Ben Ok") == refs("person:Benedikt") == his
    @test refs("@[Benedikt Okafor](person:benedikt-okafor@example.test)") == his
    @test refs("person:benedikt-okafor@example.test reef") == Set([noted, given, named])
    @test isempty(refs("person:Nobody")) && refs("curves") == Set([moved])
    # Each shows what the person did.
    did(ref) = only(h for h in K.search_tasks(kb, "Benedict"; meaning = nomeaning) if h.ref == ref).matches[1]
    @test did(noted).field == "person" && did(noted).snippet == "wrote: The reef model is too coarse" && did(noted).event > 0
    @test startswith(did(moved).snippet, "moved it from") && did(moved).who == "Claude for Benedikt Okafor"
    @test did(given).snippet == "assigned to it" && did(made).snippet == "created it" && did(named).snippet == "named in it"
    close(kb)
end

@zset "matching text to the tasks it is about" begin
    @test K.match_line((; field = "note", who = "Ada", kind = "comment", at = "2026-10-04T13:49:17Z", snippet = "the \x01reef\x02\nsurvey")) ==
          "Ada (comment, 2026-10-04): the **reef** survey"
    @test K.match_line((; field = "title", who = "", kind = "", at = "", snippet = "x")) == "title: x"
    kb = open_kb(temp_config(layers = Layer[]))
    me = K.person("Rowan")
    K.create_project!(kb, "Match"; key = "MT", by = me)
    build = K.create_task!(kb, "MT", "Speed up the site build"; by = me)
    K.note_task!(kb, build, "Cached the pages keyed by a hash in figure_cuts, so unchanged ones are kept"; kind = "progress", by = me)
    K.execute!(kb, "UPDATE tasks SET archived_at = '2026-10-01' WHERE id = ?", (K.task_id_or_nothing(kb, build),))   # finished and archived
    phone = K.create_task!(kb, "MT", "Add a gallery for the hydrophone images"; by = me)
    transect = K.create_task!(kb, "MT", "Add a gallery for the transect drawings"; by = me)
    gone = K.create_task!(kb, "MT", "Hydrophone gallery, as first asked"; by = me)
    K.execute!(kb, "UPDATE tasks SET declined_at = '2026-10-02' WHERE id = ?", (K.task_id_or_nothing(kb, gone),))
    for i in 1:30
        K.create_task!(kb, "MT", "Other work number $i on the site and its pages"; by = me)
    end
    refs(m) = [t.ref for t in m.tasks]
    @test K.match_terms("Where is the hydrophone gallery, and what did QC do in 3D?") == ["hydrophone", "gallery", "qc", "3d"]
    # A sentence naming an identifier finds the archived task whose note alone names it, by words alone.
    one = only(K.match_tasks(kb, [(; id = "a", text = "We should reuse the figure_cuts hash when a build makes the pages again")]))
    @test one.id == "a" && build in first(refs(one), 3)
    hit = only(t for t in one.tasks if t.ref == build)
    @test hit.archived && any(x -> x.field == "note" && x.kind == "progress" && occursin("\x01figure\x02", x.snippet), hit.matches)
    @test !(build in refs(only(K.match_tasks(kb, [(; id = "a", text = "the figure_cuts hash")]; archived = false))))
    # The task naming the subject ranks above one of the same kind; a declined one never shows.
    two = only(K.match_tasks(kb, [(; id = "b", text = "Where is the gallery for the hydrophone images going?")]))
    @test first(refs(two)) == phone && findfirst(==(transect), refs(two)) > 1 && !(gone in refs(two))
    @test !(phone in refs(only(K.match_tasks(kb, [(; id = "b", text = "hydrophone gallery")]; visible = r -> r != phone))))
    @test isempty(only(K.match_tasks(kb, [(; id = "c", text = "the and of it")])).tasks)
    # Many at once, by words alone, quickly; with meaning, every text embedded in one request.
    items = [(; id = string(i), text = "The hydrophone gallery and the transect drawings, item $i") for i in 1:25]
    t = @elapsed out = K.match_tasks(kb, items)
    @test length(out) == 25 && all(m -> !isempty(m.tasks), out) && t < 5
    asked = Ref(0)
    rankings(kb, texts) = (asked[] += 1; [[(K.task_id_or_nothing(kb, transect), "t:$(K.task_id_or_nothing(kb, transect))")] for _ in texts])
    fused = K.match_tasks(kb, items[1:3]; meaning = true, rankings)
    @test asked[] == 1 && all(m -> transect in refs(m), fused)
    # Where several tasks stand, in one call.
    st = K.task_statuses(kb, [build, phone, "MT-999"])
    @test [x.ref for x in st] == [build, phone] && st[1].archived && !isempty(st[1].last_note_at) && st[2].last_note_at == ""
    close(kb)
end

@zset "a task or project asked for twice" begin
    kb = open_kb(temp_config())
    me, ada = K.person("Rowan"), K.person("Ada")
    @test K.create_project!(kb, "Twice"; key = "TW", by = me) == "TW"
    @test K.create_project!(kb, "Twice"; key = "tw", by = me) == "TW"                    # the same, moments later: that one
    @test_throws "already" K.create_project!(kb, "Other"; key = "TW", by = me)
    @test_throws "already" K.create_project!(kb, "Twice"; key = "TW", by = ada)
    made = K.create_task!(kb, "TW", "Write it"; subtasks = ["One"], by = me)
    @test K.create_task!(kb, "TW", "Write it"; subtasks = ["One"], by = me) == made
    @test K.scalar(kb, "SELECT count(*) FROM tasks") == 2                                 # the task and its subtask, once
    @test K.create_task!(kb, "TW", "Write it"; by = ada) != made                         # someone else's
    @test K.create_task!(kb, "TW", "Write it"; body = "More", by = me) != made           # another task
    @test K.create_task!(kb, "TW", "One"; parent = made, by = me) == "TW-2"              # the plan's subtask, asked for again
    # Asked for again later, it is another task.
    K.execute!(kb, "UPDATE tasks SET created_at = '2020-01-01T00:00:00Z'")
    @test K.create_task!(kb, "TW", "Write it"; by = me) != made
    close(kb)
end

@zset "codebases from their repositories" begin
    @test K.clone_url("git@github.com:ada/demo.jl.git") == K.clone_url("https://ada@github.com/ada/demo.jl/") ==
          K.clone_url("https://github.com/ada/demo.jl") == "https://github.com/ada/demo.jl.git"
    @test K.github_repo("https://github.com/ada/demo.jl") == ("ada", "demo.jl") && K.github_repo("/srv/demo.git") === nothing
    @test K.is_repository("https://github.com/ada/demo") && K.is_repository("git@github.com:ada/demo") && !K.is_repository("code-demo")

    # A repository with a commit naming a task, and a knowledge base whose project links it by its address.
    origin = mktempdir()
    gito(args...) = run(pipeline(`git -C $origin -c user.name=Ada -c user.email=ada@x.org -c commit.gpgsign=false $args`; stdout = devnull, stderr = devnull))
    gito("init", "-q", "-b", "main")
    write(joinpath(origin, "a.jl"), "f() = 1\n"); gito("add", "a.jl"); gito("commit", "-q", "-m", "Add f\n\nTasks: RP-1")
    kb = open_kb(temp_config())
    me = K.person("Rowan")
    K.create_project!(kb, "Repo"; key = "RP", by = me)
    K.create_task!(kb, "RP", "Write f"; by = me)
    try
        K.SHARED_MODE[] = true
        # A repository the knowledge base does not have is added only by someone who may add sources;
        # one it has may be linked by anyone who can change the project.
        @test_throws "paper.add" K.update_project!(kb, "RP"; codebase = "file://$origin", add_codebase = false, by = me)
        @test_throws "paper.add" K.create_project!(kb, "Too"; key = "TO", codebase = "file://$origin", add_codebase = false, by = me)
        @test K.scalar(kb, "SELECT count(*) FROM papers WHERE kind = 'code'") == 0
        K.update_project!(kb, "RP"; codebase = "file://$origin", by = me)
        id = String(K.scalar(kb, "SELECT d.doc_id FROM projects p JOIN papers d ON d.id = p.codebase_id WHERE p.key = 'RP'"))
        @test startswith(id, "code-") && K.codebase_dir(kb, id) == K.clone_dir(kb.config, id)
        K.create_project!(kb, "Too"; key = "TO", codebase = "file://$origin", add_codebase = false, by = me)
        @test only(p for p in K.projects(kb) if p.key == "TO").codebase == id
        # Not fetched yet: the status says so, and reading it says why it can't.
        @test only(t.reason for t in K.sync_plan(kb) if t.id == id) == "it is not fetched from file://$origin yet"
        @test_throws "can't be read here" K.parse_code!(kb, id)
        # Fetched, it is read from the clone: its files, and its commits against their tasks.
        @test K.fetch_codebases!(kb) == 1 && isfile(joinpath(K.clone_dir(kb.config, id), "a.jl"))
        @test K.parse_code!(kb, id) && K.read_commits!(kb, id) == 1
        @test [c.subject for c in K.task(kb, "RP-1").commits] == ["Add f"]
        # New commits on another branch arrive with the next fetch.
        gito("checkout", "-q", "-b", "side")
        # A task of a project not linked to the codebase is not this codebase's to record or move.
        K.create_project!(kb, "Elsewhere"; key = "OX", by = me)
        K.create_task!(kb, "OX", "Not this codebase's"; status = "in_progress", by = me)
        write(joinpath(origin, "b.jl"), "g() = 2\n"); gito("add", "b.jl"); gito("commit", "-q", "-m", "Add g\n\nTasks: RP-1\nFixes OX-1")
        @test K.fetch_codebase!(kb, id) && K.read_commits!(kb, id) == 1
        @test [c.subject for c in K.task(kb, "RP-1").commits] == ["Add f", "Add g"] && occursin("+g() = 2", K.task_diff(kb, "RP-1"))
        @test isempty(K.task(kb, "OX-1").commits) && K.task(kb, "OX-1").status == "in_progress"
        # A repository that can't be fetched says what git said; one with none recorded, how to link one.
        K.execute!(kb, "UPDATE papers SET remote = ? WHERE doc_id = ?", ("file:///no/such/repo", id))
        rm(K.clone_dir(kb.config, id); recursive = true)
        @test !K.fetch_codebase!(kb, id) && occursin("/no/such/repo", K.codebase_problem(kb, id))
        K.execute!(kb, "UPDATE papers SET remote = NULL WHERE doc_id = ?", (id,))
        @test occursin("project_codebase", K.codebase_problem(kb, id)) && K.codebase_dir(kb, id) == ""
        # Outside shared mode a codebase is read from its directory, and records the repository it is a clone of.
        K.SHARED_MODE[] = false
        local_id = K.add_codebase!(kb, origin; name = "local")
        @test K.codebase_dir(kb, local_id) == origin && ismissing(K.scalar(kb, "SELECT remote FROM papers WHERE doc_id = ?", (local_id,)))
        gito("remote", "add", "origin", "git@github.com:ada/local.git")
        K.record_remotes!(kb)
        @test K.scalar(kb, "SELECT remote FROM papers WHERE doc_id = ?", (local_id,)) == "https://github.com/ada/local.git"
        # Added from the Manage page, by its repository's address or a folder here: one by its address is
        # read from a clone of it, fetched with the others; a folder needs a machine of its own.
        url_id = K.add_codebase_from!(kb, "file://$(dirname(origin))/$(basename(origin))")
        @test K.codebase_dir(kb, url_id) == K.clone_dir(kb.config, url_id)
        @test occursin("not fetched", K.codebase_problem(kb, url_id))
        @test K.fetch_codebases!(kb) == 1 && isfile(joinpath(K.clone_dir(kb.config, url_id), "a.jl"))   # not the one from a folder
        @test K.codebase_dir(kb, K.add_codebase_from!(kb, origin)) == origin
        @test_throws "No folder" K.add_codebase_from!(kb, joinpath(origin, "nothing-here"))
        K.SHARED_MODE[] = true
        @test_throws "from their repositories" K.add_codebase_from!(kb, origin)
        # A shared service clones from https:// or ssh only: not from its own disk.
        K.LOCAL_REPOSITORIES[] = false
        @test_throws "https:// or ssh" K.add_codebase_from!(kb, "file://$origin")
        @test_throws "https:// or ssh" K.link_repository!(kb, "/srv/elsewhere/repo")
        K.LOCAL_REPOSITORIES[] = true
        # Another owner's repository of the same name is another codebase.
        a_id, b_id = K.link_repository!(kb, "https://github.com/ada/tools.jl"), K.link_repository!(kb, "https://github.com/bea/tools.jl")
        @test a_id == "code-tools" && b_id == "code-bea-tools" && K.link_repository!(kb, "https://github.com/ada/tools.jl") == a_id
    finally
        K.SHARED_MODE[] = false
        empty!(K.FETCH_PROBLEMS)
        close(kb)
    end

    # As a GitHub App: a token signed with its key, an installation token per repository kept until
    # near its expiry, given to git in the environment, and a hint where it is not installed.
    dir = mktempdir()
    key, pub = joinpath(dir, "app.pem"), joinpath(dir, "app.pub")
    run(pipeline(`openssl genrsa -out $key 2048`; stderr = devnull)); run(pipeline(`openssl rsa -in $key -pubout -out $pub`; stderr = devnull))
    app = K.GitHubApp(; client_id = "Iv-test", private_key = key)
    jwt = K.app_jwt(app; now = 1_000_000)
    head, payload, sig = split(jwt, '.')
    @test K.JSON.parse(String(K.base64url_decode(payload))) == Dict("iat" => 999_940, "exp" => 1_000_540, "iss" => "Iv-test")
    write(joinpath(dir, "sig"), K.base64url_decode(sig))
    @test success(pipeline(`openssl dgst -sha256 -verify $pub -signature $(joinpath(dir, "sig"))`; stdin = IOBuffer("$head.$payload"), stdout = devnull))
    minted = Ref(0)
    port = 18000 + rand(0:999)
    server = K.HTTP.serve!("127.0.0.1", port) do req
        startswith(K.HTTP.header(req, "Authorization"), "Bearer ") || return K.HTTP.Response(401)
        req.target == "/app" && return K.HTTP.Response(200, K.JSON.json(Dict("slug" => "kb-test")))
        req.target == "/repos/ada/demo.jl/installation" && return K.HTTP.Response(200, K.JSON.json(Dict("id" => 7)))
        req.target == "/app/installations/7/access_tokens" || return K.HTTP.Response(404)
        minted[] += 1
        K.HTTP.Response(201, K.JSON.json(Dict("token" => "tok-$(minted[])", "expires_at" => "2099-01-01T00:00:00Z")))
    end
    saved = K.GITHUB_API[]
    try
        K.GITHUB_API[] = "http://127.0.0.1:$port"
        c = temp_config(; shared = K.SharedConfig(; github_app = app))
        a = K.repository_access(c, "https://github.com/ada/demo.jl")
        @test a.hint === nothing && a.env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader" &&
              a.env["GIT_CONFIG_VALUE_0"] == "Authorization: Basic " * K.base64encode("x-access-token:tok-1")
        @test K.repository_access(c, "https://github.com/ada/demo.jl").env == a.env && minted[] == 1   # kept
        other = K.repository_access(c, "https://github.com/ada/other")
        @test isempty(other.env) && other.hint == "the GitHub App is not installed on ada/other (https://github.com/apps/kb-test/installations/new)"
        @test isempty(K.repository_access(c, "file:///srv/demo").env)                                 # not GitHub
        @test isempty(K.repository_access(temp_config(), "https://github.com/ada/demo.jl").env)       # no App
        # A codebase new from a repository read as the App, a private one, is open only to its projects' members.
        app_kb = open_kb(c)
        access(id) = K.scalar(app_kb, "SELECT access FROM papers WHERE doc_id = ?", (id,))
        @test access(K.link_repository!(app_kb, "https://github.com/ada/demo.jl")) == "projects"
        @test access(K.link_repository!(app_kb, "https://github.com/ada/other")) == "open"
        close(app_kb)
    finally
        K.GITHUB_API[] = saved
        empty!(K.APP_TOKENS); K.APP_SLUG[] = ""
        close(server)
    end
end

@zset "state threads share" begin
    d = K.LockedDict{Int,Int}()
    computed = Threads.Atomic{Int}(0)
    # Many threads at once: each key's first value is kept, whichever computed it.
    @sync for i in 1:200
        Threads.@spawn get!(() -> (Threads.atomic_add!(computed, 1); i), d, i % 10)
    end
    @test length(d) == 10 && computed[] >= 10 && all(k -> get(d, k, -1) % 10 == k, 0:9)
    d[3] = 42
    @test get!(() -> error("not computed again"), d, 3) == 42
    delete!(d, 3)
    @test !haskey(d, 3) && get(d, 3, nothing) === nothing
end

@zset "background loops" begin
    # Work done on a period goes on past a failure, and ends once the process is stopping, without
    # waiting out its period.
    runs = Threads.Atomic{Int}(0)
    t = K.every!("Counting"; seconds = 0.05) do
        Threads.atomic_add!(runs, 1) == 1 && error("one failure")
    end
    try
        timedwait(() -> runs[] >= 4, 10) == :ok || error("the loop stopped running")
        @test runs[] >= 4
        K.STOPPING[] = true
        @test timedwait(() -> istaskdone(t), 10) == :ok
        t0 = time()
        K.pause(60)
        @test time() - t0 < 1
    finally
        K.STOPPING[] = false
    end
end

@zset "jobs" begin
    # A job touches its stamp when it ends, whether it succeeds or fails.
    waitfor(job) = (timedwait(() -> job.finished !== nothing, 10); job)
    ok, bad = tempname(), tempname()
    @test waitfor(K.start_job(j -> 1, "ok"; changes = ok)).status == :done && isfile(ok)
    @test waitfor(K.start_job(j -> error("no"), "bad"; changes = bad)).status == :failed && isfile(bad)
    @test K.changes_stamp(Config(; data_dir = "/d")) == "/d/changed"
    # A job's report is shown whatever it returns.
    report = waitfor(K.start_job(j -> "Everything was up to date.", "sync"))
    @test endswith(K.format_job(report; detail = true), "Everything was up to date.")
    # A job over documents says how many failed, and fails if every one did.
    some = waitfor(K.start_job(j -> [(; id = "a", ok = true), (; id = "b", ok = false, error = "timed out")], "ingest"))
    # Waiting on a job returns once it has ended.
    gate = Base.Event()
    slow = K.start_job(j -> (wait(gate); 7), "slow")
    @test slow.finished === nothing
    notify(gate)
    @test wait(slow).result == 7 && slow.finished !== nothing
    # A finished job is kept for a day, for whoever follows it, then forgotten.
    lock(K.JOBS_LOCK) do
        K.forget_old_jobs!(slow.finished + K.JOB_KEEP - K.Dates.Minute(1))
        @test haskey(K.JOBS, slow.id)
        K.forget_old_jobs!(slow.finished + K.JOB_KEEP + K.Dates.Minute(1))
        @test !haskey(K.JOBS, slow.id)
    end
    # The site's files' tags: of files gone (an old build's), dropped as the table fills.
    f = tempname(); write(f, "page")
    lock(() -> foreach(i -> K.ETAGS["/gone/$i"] = (0.0, "x"), 1:K.ETAGS_MAX), K.ETAGS_LOCK)
    tag = K.file_etag(f)
    @test K.file_etag(f) == tag && haskey(K.ETAGS, f) && !haskey(K.ETAGS, "/gone/1")
    @test some.status == :done && some.message == "1 of 2 failed: timed out"
    all_ = waitfor(K.start_job(j -> [(; id = "b", ok = false, error = "timed out")], "ingest"))
    @test all_.status == :failed && all_.error == "b: timed out"
end

@zset "embedding a batch that outlasts the timeout" begin
    # Ollama taking too long over a batch: it is embedded in halves, down to what answers in time, and
    # the batches after it start at that size.
    port, sizes = 17000 + rand(0:999), Int[]
    server = K.HTTP.serve!("127.0.0.1", port) do req
        n = length(K.JSON.parse(String(req.body))["input"])
        push!(sizes, n)
        n > 2 && sleep(8)
        K.HTTP.Response(200, K.JSON.json(Dict("embeddings" => [[Float32(n), 1f0] for _ in 1:n])))
    end
    try
        vecs = K.ollama_embed(temp_config(; ollama_url = "http://127.0.0.1:$port"), "m", ["t$i" for i in 1:6]; timeout = 3, size = Ref(4))
        @test length(vecs) == 6 && all(v -> v[1] <= 2, vecs)
        @test sizes == [4, 2, 2, 2]                                     # the batches after it start at the size that answered
    finally
        close(server)
    end
end

@zset "a search's query embedded ahead of bulk batches" begin
    # A bulk embedding holds back its next batch while a search waits on Ollama, and fits its batches
    # to about BATCH_SECONDS of work.
    port, sent = 17000 + rand(0:999), String[]
    server = K.HTTP.serve!("127.0.0.1", port) do req
        input = K.JSON.parse(String(req.body))["input"]
        push!(sent, startswith(first(input), "q") ? "query" : "batch of $(length(input))")
        startswith(first(input), "q") && sleep(1)
        K.HTTP.Response(200, K.JSON.json(Dict("embeddings" => [[1f0, 0f0] for _ in input])))
    end
    try
        c, l = temp_config(; ollama_url = "http://127.0.0.1:$port"), K.Layer(; name = "t", model = "m", unit = :chunk)
        q = Threads.@spawn K.embed(c, l, ["q one"]; query = true)
        while isempty(sent)
            sleep(0.01)
        end
        size = Ref(4)
        vecs = K.embed(c, l, ["t$i" for i in 1:40]; size)
        wait(q)
        @test length(vecs) == 40 && first(sent) == "query" && sent[2] == "batch of 4"
        @test size[] == K.EMBED_BATCH                                   # quick batches grow to the largest
    finally
        close(server)
    end
end

@zset "summarizer configuration" begin
    path = tempname() * ".toml"
    write(path, """
        summarizer = "opus-agent-pdf"
        judge = "local-judge"

        [[summarizers]]
        name = "local-judge"
        kind = "agent"
        model = "ollama:qwen3:32b"
        reads = "text"
        """)
    c = K.validate(K.load_config(path))
    @test c.summarizer == "opus-agent-pdf" && c.code_summarizer == "deepseek-v4.1-flash"
    @test K.summarizer(c, "local-judge").kind == :agent && K.summarizer(c, "local-judge").reads == :text
    @test K.summarizer(c, "deepseek-flash").kind == :api                   # the defaults stay alongside
    summary_layers = [l for l in c.layers if !isempty(l.source) && !l.trial]
    @test all(l -> l.source == "opus-agent-pdf", summary_layers)
    # A codebase's summaries come from the code summarizer.
    @test K.summarizer_for(c, first(summary_layers), "code-demo").name == "deepseek-v4.1-flash"
    @test K.summarizer_for(c, first(summary_layers), "2609.00001").name == "opus-agent-pdf"
    @test K.validate(Config(; code_summarizer = "opus-agent-code")) isa Config          # agents summarize code too
    @test_throws ErrorException K.validate(Config(; judge = "nobody"))
    # Layers of summaries are named for whose summaries they embed: the summarizer's model.
    l = first(summary_layers)
    @test occursin(r"^(paper|section) summaries by opus · ", K.ranking_label(c, l.name))
    @test K.ranking_label(c, "keyword") == "keyword"
end

@zset "agent summarizer" begin
    # A stand-in for Kaimon's agent tools that plays the agent: asked to follow BRIEF.md, it writes a
    # summary for every section task.md lists; asked anything else, it answers from its working directory.
    opened = Dict{String,String}()
    replies = Dict{String,String}()
    sent = String[]
    skip_file = Ref(false)         # the next code batch leaves out a file
    fake(name, args) = if name == :agent_open
        opened[args["id"]] = args["cwd"]
        # Summarizers only read and write files, in their own folder; the tutor also searches the
        # knowledge base. What they are linked to (a PDF, a codebase) they may read too.
        files = K.file_tools(args["cwd"])
        @test args["allowed_tools"] == (startswith(args["id"], "zemi-chat-") ? [files; K.tutor_tools()] : files) &&
              args["permission"] == "default" && args["only"] === true             # those tools and no others
        @test all(t -> endswith(t, "(/" * realpath(args["cwd"]) * "/**)"), files)
        @test args["confine_allow"] == K.agent_reads(args["cwd"])
        isdir(joinpath(args["cwd"], "repo")) && @test realpath(joinpath(args["cwd"], "repo")) in args["confine_allow"]
        startswith(args["id"], "zemi-chat-") && @test args["effort"] == "medium"     # quick turns, to converse
        K.JSON.json(Dict("agent_id" => args["id"]))
    elseif name == :agent_send
        push!(sent, args["text"])
        dir = opened[args["agent_id"]]
        if occursin("BRIEF-files.md", args["text"])
            task = only(m[1] for m in eachmatch(r"(files-[\w-]+)\.md", args["text"]))
            ords = [m[1] for m in eachmatch(r"^- (\d+):"m, read(joinpath(dir, "$task.md"), String))]
            @test isdir(joinpath(dir, "repo"))
            skip_file[] && !endswith(task, "-again") && (skip_file[] = false; pop!(ords))     # an agent passing over a file
            write(joinpath(dir, "$task.json"), K.JSON.json(Dict(o => "File $o." for o in ords)))
            replies[args["agent_id"]] = "Written."
        elseif occursin("BRIEF-tree.md", args["text"])
            ords = [m[1] for m in eachmatch(r"^- (\d+):"m, read(joinpath(dir, "tree.md"), String))]
            write(joinpath(dir, "tree.json"), K.JSON.json(Dict("dirs" => Dict(o => "Directory $o." for o in ords),
                                                                "codebase" => "A demo.\nTopics: demo")))
            replies[args["agent_id"]] = "Written."
        elseif occursin("BRIEF-part.md", args["text"])
            task = only(m[1] for m in eachmatch(r"(part-\d+)\.md", args["text"]))
            ords = [m[1] for m in eachmatch(r"^- (\d+):"m, read(joinpath(dir, "$task.md"), String))]
            @test all(o -> occursin("=== $o: ", read(joinpath(dir, "$task.txt"), String)), ords)
            write(joinpath(dir, "$task.json"), K.JSON.json(Dict(o => "Part section $o." for o in ords)))
            replies[args["agent_id"]] = "Written."
        elseif occursin("BRIEF-whole.md", args["text"])
            @test occursin("Part section 1.", read(joinpath(dir, "whole.md"), String))
            write(joinpath(dir, "whole.json"), K.JSON.json(Dict("paper" => "The document.\nTopics: x")))
            replies[args["agent_id"]] = "Written."
        elseif occursin("BRIEF.md", args["text"])
            ords = [m[1] for m in eachmatch(r"^- (\d+):"m, read(joinpath(dir, "task.md"), String))]
            @test occursin("First words", read(joinpath(dir, "paper.txt"), String))
            write(joinpath(dir, "summaries.json"), K.JSON.json(Dict(
                "sections" => Dict(o => "Section $o, read whole." for o in ords), "paper" => "The paper.\nTopics: a, b")))
            replies[args["agent_id"]] = "Written."
        else
            replies[args["agent_id"]] = "Seen: " * join(sort(readdir(dir)), ", ")
        end
        K.JSON.json(Dict("turn" => 1))
    elseif name == :agent_status
        K.JSON.json(Dict("status" => haskey(opened, args["agent_id"]) ? "idle" : "dead"))
    elseif name == :agent_output
        K.JSON.json(Dict("done" => true, "status" => "idle", "text" => replies[args["agent_id"]]))
    else
        "{}"
    end
    saved = K.AGENT_CALL[]
    K.AGENT_CALL[] = fake
    try withenv("XDG_CACHE_HOME" => mktempdir()) do
        s = Summarizer(; name = "agent-t", kind = :agent, model = "opus", reads = :text)
        api = Summarizer(; name = "api-t", url = "http://127.0.0.1:1", model = "m")
        kb = open_kb(temp_config(layers = Layer[], summarizers = [s, api], summarizer = "agent-t", code_summarizer = "api-t", judge = "agent-t"))
        add_papers!(kb, ["2609.00001"])
        piece(kind, text, sec) = K.Piece(kind, 1, (0.0, 0.0, 0.0, 0.0), text, sec, kind == :heading ? 1 : 0, "")
        sections = [K.Section(1, 1, "1", "1. One", "1. One", 1, 1), K.Section(2, 1, "2", "2. Two", "2. Two", 1, 1)]
        K.store_parse!(kb, "2609.00001", K.ParsedPaper(1, [piece(:heading, "1. One", 1), piece(:paragraph, repeat("First words. ", 30), 1),
                                                          piece(:heading, "2. Two", 2), piece(:paragraph, repeat("Second words. ", 30), 2)], sections))
        @test summarize_paper!(kb, s, "2609.00001") == 3                  # two sections and the paper
        @test [x.text for x in summaries(kb, "2609.00001"; summarizer = "agent-t")] ==
              ["The paper.\nTopics: a, b", "Section 1, read whole.", "Section 2, read whole."]
        n = length(opened)
        @test summarize_paper!(kb, s, "2609.00001") == 0 && length(opened) == n   # current: no agent opened
        # A paper summary from an older brief is out of date even when every section summary is current.
        K.execute!(kb, "UPDATE summaries SET input_sha = 'older' WHERE unit_key = 'p:2609.00001'")
        @test summarize_paper!(kb, s, "2609.00001") == 3 && length(opened) == n + 1
        # Whether reading the paper again would replace the agent's summaries, which sync limits.
        same = open_kb(Config(; data_dir = kb.config.data_dir, collection_prefix = "zemi_test", summarizers = [s, api],
                              summarizer = "agent-t", code_summarizer = "api-t", judge = "agent-t",
                              layers = [Layer(; name = "paper-summary-t", model = "m", unit = :paper, source = "agent-t")]))
        @test K.agent_summaries(kb, s, "2609.00001") == :current && !K.resummarizes(same, "2609.00001")
        @test K.resummarizes(same, "2609.00001"; newer = true)                  # a newer version is read whole again
        add_papers!(kb, ["2609.00002"])
        @test K.agent_summaries(kb, s, "2609.00002") == :none && !K.resummarizes(same, "2609.00002"; newer = true)
        K.execute!(kb, "UPDATE summaries SET input_sha = 'older' WHERE unit_key = 's:2609.00001:1'")
        @test K.agent_summaries(kb, s, "2609.00001") == :stale && K.resummarizes(same, "2609.00001")
        close(same)
        # A long document: only the out-of-date section is read again, in its batch, then the whole.
        n = length(opened)
        @test K.agent_summarize_long!(kb, s, "2609.00001", K.section_texts(kb, "2609.00001"); batch_chars = 10) == 2
        @test length(opened) == n + 2 && K.agent_summaries(kb, s, "2609.00001") == :current
        @test [x.text for x in summaries(kb, "2609.00001"; summarizer = "agent-t")] ==
              ["The document.\nTopics: x", "Part section 1.", "Section 2, read whole."]

        # An agent that reads the PDF is judged by the PDF and the section list: reading the same PDF
        # better leaves its summaries current, where a text reader's go out of date.
        pdf = Summarizer(; name = "agent-pdf", kind = :agent, model = "opus", reads = :pdf)
        pid = K.paper_id(kb, "2609.00001")
        K.execute!(kb, "UPDATE parses SET file_sha = 'pdf-1' WHERE paper_id = ?", (pid,))
        K.import_summaries!(kb, pdf, "2609.00001"; sections = Dict(1 => "One.", 2 => "Two."), paper = "Paper.\nTopics: a")
        @test K.agent_summaries(kb, pdf, "2609.00001") == :current
        K.execute!(kb, "UPDATE blocks SET text = text || ' Read better.' WHERE paper_id = ? AND kind = 'paragraph'", (pid,))
        @test K.agent_summaries(kb, pdf, "2609.00001") == :current && K.agent_summaries(kb, s, "2609.00001") == :stale
        K.execute!(kb, "UPDATE parses SET file_sha = 'pdf-2' WHERE paper_id = ?", (pid,))
        @test K.agent_summaries(kb, pdf, "2609.00001") == :stale                   # another PDF
        # Summaries judged by the text, as before, are judged by the PDF once the knowledge base opens.
        texts = K.section_texts(kb, "2609.00001")
        old(text) = K.summary_input_sha(pdf, text)
        K.execute!(kb, "UPDATE summaries SET input_sha = ? WHERE paper_id = ? AND summarizer = 'agent-pdf' AND unit_key = 'p:2609.00001'",
                   (old(K.paper_input(texts)), pid))
        for t in texts
            K.execute!(kb, "UPDATE summaries SET input_sha = ? WHERE paper_id = ? AND summarizer = 'agent-pdf' AND unit_key = ?",
                       (old(t.text), pid, "s:2609.00001:$(t.ord)"))
        end
        K.execute!(kb, "DELETE FROM kv WHERE key = 'pdf_summary_keys'")
        again = open_kb(Config(; data_dir = kb.config.data_dir, collection_prefix = "zemi_test", summarizers = [s, api, pdf],
                               summarizer = "agent-t", code_summarizer = "api-t", judge = "agent-t", layers = Layer[]))
        @test K.agent_summaries(again, pdf, "2609.00001") == :current && K.rekey_pdf_summaries!(again) == 0   # once
        close(again)
        K.execute!(kb, "UPDATE blocks SET text = replace(text, ' Read better.', '') WHERE paper_id = ?", (pid,))

        # A conversation with the tutor about a paper: its folder holds the paper and what is known of
        # it, the reply is written as it comes, and the conversation is kept and goes on.
        chat = K.ask_chat!(kb, "2609.00001", "What does it do?")
        for _ in 1:200
            last(K.chat_messages(kb, chat).messages).status == "thinking" || break
            sleep(0.05)
        end
        c = K.chat_messages(kb, chat)
        @test c.doing === nothing                                       # answered: nothing in progress
        @test [m.role for m in c.messages] == ["user", "tutor"] && last(c.messages).status == "done"
        @test occursin("context.md", last(c.messages).text) && occursin("paper.txt", last(c.messages).text)
        @test occursin("## Its sections, summarized", read(joinpath(K.agents_dir("chats", chat), "context.md"), String))
        @test only(K.chats(kb, "2609.00001")).title == "What does it do?"
        # What the tutor writes into files/ is served, and nothing else in or beyond its folder.
        files = joinpath(K.agents_dir("chats", chat), "files")
        write(joinpath(files, "plot.svg"), "<svg/>"); write(joinpath(files, "page.html"), "<p>hi</p>")
        @test K.chat_file(kb, chat, "plot.svg") == joinpath(files, "plot.svg")
        @test all(n -> K.chat_file(kb, chat, n) === nothing, ["../context.md", "context.md", ".x", "", "missing.png"])
        @test K.chat_file(kb, "nochat", "plot.svg") === nothing
        page = K.chat_file_response(K.chat_file(kb, chat, "page.html"))
        @test K.HTTP.header(page, "Content-Security-Policy") == "sandbox allow-scripts"
        @test K.HTTP.header(K.chat_file_response(joinpath(files, "plot.svg")), "Content-Type") == "image/svg+xml"
        K.ask_chat!(kb, "2609.00001", "And then?"; chat)
        for _ in 1:200
            last(K.chat_messages(kb, chat).messages).status == "thinking" || break
            sleep(0.05)
        end
        @test length(K.chat_messages(kb, chat).messages) == 4 && length(K.chats(kb, "2609.00001")) == 1
        @test_throws ErrorException K.ask_chat!(kb, "2609.00001", "  ")
        # A tutoring profile reaches the agent as a guideline not to be repeated, and is never stored: the
        # conversation keeps its hash, and passes it on again only when it changes.
        note = K.profile_note("- Stage: PhD student")
        @test occursin("- Stage: PhD student", note) && occursin("only as a guideline", note) && occursin("Include nothing", note)
        @test K.profile_note("  ") == "" && occursin("Never include anything from it", K.tutor_system(Config()))
        wait_reply(c) = for _ in 1:200
            last(K.chat_messages(kb, c).messages).status == "thinking" || break
            sleep(0.05)
        end
        n = length(sent)
        pc = K.ask_chat!(kb, "2609.00001", "Where to start?"; profile = "- Stage: PhD student"); wait_reply(pc)
        @test occursin("- Stage: PhD student", sent[end]) && length(sent) == n + 1
        K.ask_chat!(kb, "2609.00001", "And next?"; chat = pc, profile = "- Stage: PhD student"); wait_reply(pc)
        @test !occursin("Stage:", sent[end])                                         # unchanged: not sent again
        K.ask_chat!(kb, "2609.00001", "Simpler?"; chat = pc, profile = "- Stage: Undergraduate"); wait_reply(pc)
        @test occursin("- Stage: Undergraduate", sent[end])                          # changed: sent again
        stored = K.query(kb, "SELECT * FROM chats WHERE id = ?", (pc,))
        @test !any(v -> v isa AbstractString && occursin("Stage:", v), values(first(stored)))
        @test !any(m -> occursin("Stage:", m.text), K.chat_messages(kb, pc).messages)
        # One question: the preamble and attachments are files in the agent's directory, removed after.
        pdf = tempname() * ".pdf"
        write(pdf, "%PDF-1.4")
        answer = K.ask(s, "system", "What do you see?"; preamble = "The paper.", pdfs = [pdf])
        @test answer == "Seen: $(basename(pdf)), preamble.txt"
        @test !any(startswith("ask-"), readdir(K.agents_dir("agent-t")))

        # A codebase: files in batches, then its directories and the whole; only what changed is redone.
        repo = mktempdir()
        mkpath(joinpath(repo, "src"))
        write(joinpath(repo, "README.md"), "# Demo\n\n" * repeat("A demo package that adds numbers. ", 12))
        write(joinpath(repo, "src", "Demo.jl"), "module Demo\n" * join("add$i(a, b) = a + b + $i\n" for i in 1:20) * "end\n")
        write(joinpath(repo, "src", "More.jl"), join("more$i() = $i\n" for i in 1:40))
        code = add_codebase!(kb, repo; name = "Demo")
        K.parse_code!(kb, code)
        @test K.agent_summarize_code!(kb, s, code; batch_chars = 400) == 3 + 1 + 1   # 3 files, src/, the codebase
        @test K.agent_summarize_code!(kb, s, code) == 0
        write(joinpath(repo, "src", "More.jl"), join("more$i() = $i + 1\n" for i in 1:40))
        K.parse_code!(kb, code)
        @test K.agent_summarize_code!(kb, s, code) == 1 + 1 + 1                       # More.jl, src/, the codebase
        # A file the agent passes over is asked for once more.
        write(joinpath(repo, "src", "More.jl"), join("more$i() = $i + 2\n" for i in 1:40))
        K.parse_code!(kb, code)
        skip_file[] = true
        @test K.agent_summarize_code!(kb, s, code) == 1 + 1 + 1 && !skip_file[]
        @test any(startswith(f, "files-1-again") for f in readdir(K.agents_dir("agent-t", code)))
        @test only(x.text for x in summaries(kb, code; summarizer = "agent-t") if startswith(x.unit, "p:")) == "A demo.\nTopics: demo"
        close(kb)
    end
    finally
        K.AGENT_CALL[] = saved
    end
end

@zset "hosted models" begin
    HTTP, JSON = K.HTTP, K.JSON
    keyfile = tempname()
    write(keyfile, "# The key:\n\nsk-test\n")
    @test K.resolve_key("file:$keyfile", "t") == "sk-test" && K.resolve_key("", "t") == ""
    placeholder = tempname()
    write(placeholder, "# Paste the key on the next line.\n\n")
    @test_throws ErrorException K.resolve_key("file:$placeholder", "t")
    withenv("ZEMI_TEST_KEY" => "from-env") do
        @test K.resolve_key("env:ZEMI_TEST_KEY", "t") == "from-env"
    end
    @test_throws ErrorException K.resolve_key("file:/nonexistent/key", "t")
    @test_throws ErrorException K.resolve_key("plain-key", "t")
    # A model's refusal, thrown in one of the tasks that summarize, is told as itself: no task, no stack trace.
    e = try asyncmap(_ -> K.upstream_failed("Summarizer s answered HTTP 401: expired"), 1:2; ntasks = 2); nothing catch e; e end
    @test !(e isa K.Refusal) && K.failure_message(e) == "Summarizer s answered HTTP 401: expired"
    @test K.error_status(e) == 502 && K.reason(e) == "Summarizer s answered HTTP 401: expired"
    @test K.failure_message(ErrorException("plain")) == "plain"
    # OpenCode's key: its login where there is one, else OPENCODE_API_KEY (a container's).
    data = mktempdir()
    withenv("XDG_DATA_HOME" => data, "OPENCODE_API_KEY" => nothing) do
        @test_throws "no OPENCODE_API_KEY set" K.resolve_key("opencode", "t")
        withenv(() -> (@test K.resolve_key("opencode", "t") == "from-env"), "OPENCODE_API_KEY" => "from-env")
        mkpath(joinpath(data, "opencode"))
        write(joinpath(data, "opencode", "auth.json"), K.JSON.json(Dict("opencode" => Dict("key" => "from-login"))))
        withenv(() -> (@test K.resolve_key("opencode", "t") == "from-login"), "OPENCODE_API_KEY" => "from-env")
    end

    seen = Dict{String,Any}()
    port = 18000 + rand(0:999)
    # A stand-in for an OpenAI-compatible API: embeddings come back out of order, as the API allows.
    server = HTTP.serve!("127.0.0.1", port) do req
        body = JSON.parse(String(req.body))
        seen[req.target] = (; auth = HTTP.header(req, "Authorization"), body)
        endswith(req.target, "/embeddings") || return HTTP.Response(200, JSON.json(Dict(
            "choices" => [Dict("message" => Dict("content" => "ok"))], "usage" => Dict())))
        data = [Dict("index" => i - 1, "embedding" => [Float64(length(t)), 1.0]) for (i, t) in enumerate(body["input"])]
        HTTP.Response(200, JSON.json(Dict("data" => reverse(data))))
    end
    try
        l = Layer(; name = "hosted", model = "m", unit = :chunk, url = "http://127.0.0.1:$port/v1", key = "file:$keyfile")
        @test K.embed(Config(), l, ["a", "bbb", "cc"]) == [Float32[1, 1], Float32[3, 1], Float32[2, 1]]
        @test seen["/v1/embeddings"].auth == "Bearer sk-test" && seen["/v1/embeddings"].body["model"] == "m"
        # Each summarizer sends its own request fields: a temperature by default, or what it names.
        K.complete(Summarizer(; name = "a", url = "http://127.0.0.1:$port/a", model = "m"), "s", "p")
        K.complete(Summarizer(; name = "b", url = "http://127.0.0.1:$port/b", model = "m",
                              request = Dict{String,Any}("reasoning_effort" => "low")), "s", "p")
        @test seen["/a/chat/completions"].body["temperature"] == 0.2
        b = seen["/b/chat/completions"].body
        @test b["reasoning_effort"] == "low" && !haskey(b, "temperature")
        # A PDF goes ahead of the prompt as a file part.
        pdf = tempname() * ".pdf"
        write(pdf, "%PDF-1.4 test")
        K.complete(Summarizer(; name = "c", url = "http://127.0.0.1:$port/c", model = "m"), "s", "the prompt"; pdfs = [pdf])
        parts = seen["/c/chat/completions"].body["messages"][2]["content"]
        @test parts[1]["type"] == "file" && parts[1]["file"]["filename"] == basename(pdf)
        @test parts[1]["file"]["file_data"] == "data:application/pdf;base64," * K.base64encode("%PDF-1.4 test")
        @test parts[2] == Dict("type" => "text", "text" => "the prompt")
    finally
        close(server)
    end
end

@zset "JSON in LLM replies" begin
    @test K.reply_json("{\"a\": \"mischaracterizes \\(p\\).\"}", "t")["a"] == "mischaracterizes \\(p\\)."     # LaTeX in a string
    @test K.reply_json("{\"a\": \"C:\\\\(x) and \\\\\\\\\"}", "t")["a"] == "C:\\(x) and \\\\"                   # real escaped backslashes
    @test K.reply_json("{\"a\": \"\\upsilon, \\u00e9, a\\nb\"}", "t")["a"] == "\\upsilon, é, a\nb"
    # Quotation marks a model left unescaped inside a string are read as text.
    @test K.reply_json("{\"why\": \"whether the \"last intact chain\" holds\", \"n\": 2}", "t") ==
          Dict("why" => "whether the \"last intact chain\" holds", "n" => 2)
    @test_throws "does not parse" K.reply_json("{\"a\": [1 2]}", "t")
    @test K.reply_json("Here: {\"a\": [1]} as asked", "t")["a"] == [1]
    @test_throws ErrorException K.reply_json("no object here", "t")
end

@zset "judging summaries" begin
    HTTP, JSON = K.HTTP, K.JSON
    port = 18000 + rand(0:999)
    # A judge that rates by content, so scores reach the right summarizer however the letters are shuffled.
    calls = Ref(0)
    server = HTTP.serve!("127.0.0.1", port) do req
        calls[] += 1
        content = JSON.parse(String(req.body))["messages"][2]["content"]
        prompt = content isa String ? content : join((p["text"] for p in content if p["type"] == "text"), "\n")
        verdict = Dict(m[1] => Dict("accuracy" => occursin("careful", m[2]) ? 5 : 2, "coverage" => 4, "specificity" => 3,
                                    "errors" => occursin("careful", m[2]) ? String[] : ["made up"])
                       for m in eachmatch(r"\[([A-Z])\]\n(.*?)(?=\n\n\[|\n\nThe summarizers)"s, prompt))
        HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => JSON.json(verdict)))], "usage" => Dict())))
    end
    try
        kb = open_kb(temp_config(layers = Layer[]))
        add_papers!(kb, ["2609.00001"])
        piece(kind, text, sec) = K.Piece(kind, 1, (0.0, 0.0, 0.0, 0.0), text, sec, kind == :heading ? 1 : 0, "")
        sections = [K.Section(1, 1, "1", "1. One", "1. One", 1, 1), K.Section(2, 1, "2", "2. Two", "2. Two", 1, 1)]
        K.store_parse!(kb, "2609.00001", K.ParsedPaper(1, [piece(:heading, "1. One", 1), piece(:paragraph, repeat("First words. ", 30), 1),
                                                          piece(:heading, "2. Two", 2), piece(:paragraph, repeat("Second words. ", 30), 2)], sections))
        pid = K.paper_id(kb, "2609.00001")
        for ord in 1:2, (name, text) in ("careful" => "A careful summary.", "sloppy" => "A sloppy summary.")
            K.execute!(kb, "INSERT INTO summaries VALUES (?, ?, ?, 'm', 1, 'x', ?, 1, 1, ?)", (pid, "s:2609.00001:$ord", name, text, K.now_iso()))
        end
        judge = Summarizer(; name = "judge", url = "http://127.0.0.1:$port", model = "m")
        r = judge_summaries(kb, judge, ["sloppy", "careful"]; ids = ["2609.00001"], sections = 5)
        @test [s.summarizer for s in r.summary] == ["careful", "sloppy"]
        careful = first(r.summary)
        @test careful.sections == 2 && careful.accuracy == 5.0 && careful.sections_with_errors == 0.0
        @test last(r.summary).accuracy == 2.0 && last(r.summary).errors_per_section == 1.0
        @test length(r.details) == 4 && isempty(r.failed)
        n = calls[]
        @test judge_summaries(kb, judge, ["sloppy", "careful"]; ids = ["2609.00001"], sections = 5).summary == r.summary
        @test calls[] == n                                         # verdicts are stored, not paid for twice
        @test occursin("First words.", K.judge_preamble(K.read_paper(kb, "2609.00001")))
        close(kb)
    finally
        close(server)
    end
end

@zset "summaries" begin
    HTTP, JSON = K.HTTP, K.JSON
    calls = Ref(0)
    port = 18000 + rand(0:999)
    # A stand-in for an OpenAI-compatible chat completions endpoint.
    server = HTTP.serve!("127.0.0.1", port) do req
        calls[] += 1
        content = JSON.parse(String(req.body))["messages"][2]["content"]
        prompt = content isa String ? content : join((p["text"] for p in content if p["type"] == "text"), "\n")
        # Replies depend on their input, as a real model's do.
        reply = occursin("\"document_type\"", prompt) ?
                    """Here it is: {"document_type": "journal article", "venue": "Design Journal", "year": 1999,
                    "authors": ["Ada Lovelace"], "category": "cs.MA", "secondary_categories": ["cs.AI"],
                    "research_areas": ["engineering design"], "methods": ["agent-based search"], "applications": ["gear trains"],
                    "keywords": ["agents", "Pareto"], "one_line": "Agents design machines.", "relevance": 2,
                    "relevance_note": "Design optimization, as in MBSE."}""" :
                occursin("Section summaries:", prompt) ? "Paper summary.\nTopics: a, b" :
                "Summary of a section ($(length(prompt)) characters)."
        HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => reply))],
            "usage" => Dict("prompt_tokens" => 10, "completion_tokens" => 5))))
    end
    try
        s = Summarizer(; name = "fake", url = "http://127.0.0.1:$port", model = "fake-model")
        kb = open_kb(temp_config(summarizers = [s], summarizer = "fake", code_summarizer = "fake", judge = "fake", layers = Layer[]))
        add_papers!(kb, ["2609.00001"])
        piece(kind, text, sec) = K.Piece(kind, 1, (0.0, 0.0, 0.0, 0.0), text, sec, kind == :heading ? 1 : 0, "")
        sections = [K.Section(1, 1, "1", "1. One", "1. One", 1, 1), K.Section(2, 1, "2", "2. Two", "2. Two", 1, 1),
                    K.Section(3, 1, "", "References", "References", 1, 1)]
        parsed(two) = K.ParsedPaper(1, [piece(:heading, "1. One", 1), piece(:paragraph, repeat("First words. ", 30), 1),
                                        piece(:heading, "2. Two", 2), piece(:paragraph, two, 2),
                                        piece(:heading, "References", 3), piece(:reference, "A. Author 2020", 3)], sections)
        K.store_parse!(kb, "2609.00001", parsed(repeat("Second words. ", 30)))

        @test summarize_paper!(kb, s, "2609.00001") == 3   # two sections and the paper; not References
        @test calls[] == 3
        @test summarize_paper!(kb, s, "2609.00001") == 0   # nothing changed, nothing sent
        @test calls[] == 3
        ss = summaries(kb, "2609.00001")
        @test [x.unit for x in ss] == ["p:2609.00001", "s:2609.00001:1", "s:2609.00001:2"]
        @test startswith(ss[1].text, "Paper summary") && ss[2].section == "1. One" && ss[2].input_tokens == 10

        # A changed section is rewritten, and so is the paper summary that reads it.
        K.store_parse!(kb, "2609.00001", parsed(repeat("Different words. ", 30)))
        @test summarize_paper!(kb, s, "2609.00001") == 2

        # Sections that swap numbers keep their summaries: only the paper's, whose input order changed, is asked for.
        swapped = [K.Section(1, 1, "2", "2. Two", "2. Two", 1, 1), K.Section(2, 1, "1", "1. One", "1. One", 1, 1),
                   K.Section(3, 1, "", "References", "References", 1, 1)]
        K.store_parse!(kb, "2609.00001", K.ParsedPaper(1, [piece(:heading, "2. Two", 1), piece(:paragraph, repeat("Different words. ", 30), 1),
                                                           piece(:heading, "1. One", 2), piece(:paragraph, repeat("First words. ", 30), 2),
                                                           piece(:heading, "References", 3), piece(:reference, "A. Author 2020", 3)], swapped))
        before_swap = calls[]
        @test summarize_paper!(kb, s, "2609.00001") == 1 && calls[] == before_swap + 1

        us = K.units(kb, Layer(; name = "t", model = "m", unit = :section, source = "fake"), "2609.00001")
        @test length(us) == 2 && all(u -> occursin("Summary of a section", u.text), us)
        @test only(K.units(kb, Layer(; name = "t", model = "m", unit = :paper, source = "fake"), "2609.00001")).key == "p:2609.00001"

        # A classification is stored whole; the record takes the category, authors and year it lacked.
        c = classify!(kb, "2609.00001"; summarizer = "fake")
        @test c["methods"] == ["agent-based search"] && classification(kb, "2609.00001")["relevance"] == 2
        p = K.paper_row(kb, "2609.00001")
        @test p.primary_category == "cs.MA" && K.json_list(p.authors) == ["Ada Lovelace"] && p.published == "1999"
        data = K.paper_json(K.site_paper(kb, "2609.00001"; related = false))
        @test any(r -> r["label"] == "Relevance" && startswith(r["value"], "2 of 3, related"), data["classification"])
        # A section's text is sent when it is opened, not carried in the page's data.
        @test data["sections"][1]["text"] == "Full text, p. 1" && !occursin("Different words.", K.JSON.json(data))
        @test [b["kind"] for b in K.section_text_json(kb, "2609.00001", 1)] == ["paragraph"] &&
              startswith(K.section_text_json(kb, "2609.00001", 1)[1]["text"], "Different words.")
        # A related codebase links to its page in the code section, a related paper to its own.
        sp = K.site_paper(kb, "2609.00001"; related = false)
        near = [(; doc_id = "code-demo", title = "Demo", score = 0.9), (; doc_id = "2609.00002", title = "Other", score = 0.8)]
        related = K.paper_json(K.SitePaper((f == :related ? near : getfield(sp, f) for f in fieldnames(K.SitePaper))...))["related"]
        @test [(r["slug"], r["page"]) for r in related] == [("code-demo", "code/code-demo/"), ("2609-00002", "papers/2609-00002")]
        @test occursin("Methods: agent-based search", K.format_classification(c))

        # A codebase: directories are summarized from what they hold, and adding a file (which shifts
        # every section number) reuses what was written instead of asking again.
        repo = mktempdir()
        mkpath(joinpath(repo, "src"))
        write(joinpath(repo, "src", "long.jl"), "\"Adds.\"\nadd(a, b) = a + b\n" * repeat("# more explanation of adding\n", 20))
        write(joinpath(repo, "src", "tiny.jl"), "x = 1\n")
        cid = add_codebase!(kb, repo; name = "Repo")
        ingest_summaries(id) = (K.parse_code!(kb, id); summarize_paper!(kb, s, id))
        @test ingest_summaries(cid) == 3                          # long.jl, src/, the project; tiny.jl is too short
        src_summary = only(x for x in summaries(kb, cid) if x.section == "src/")
        write(joinpath(repo, "a.jl"), "b = 2\n")                 # sorts first: every number shifts
        before_add = calls[]
        ingest_summaries(cid)
        @test calls[] == before_add                               # everything reused
        @test only(x for x in summaries(kb, cid) if x.section == "src/").text == src_summary.text
        @test [x.section for x in summaries(kb, cid) if x.section != "(paper)"] |> sort == ["src/", "src/long.jl"]

        # Ingesting classifies what it reads, once; a classifier that fails leaves the reading standing.
        r = only(ingest!(kb, [cid]))
        @test r.ok && r.classified && classification(kb, cid)["relevance"] == 2 && occursin(", classified", K.format_ingest([r]))
        before = calls[]
        @test !only(ingest!(kb, [cid])).classified && calls[] == before
        @test !only(ingest!(kb, [add_codebase!(kb, mktempdir(); name = "Other")]; classify = false)).classified
        broken_port = 18000 + rand(0:999)
        broken = HTTP.serve!(req -> HTTP.URI(req.target).path == "/models" ? HTTP.Response(200, "{}") : HTTP.Response(500, "down"),
                             "127.0.0.1", broken_port)
        try
            b = Summarizer(; name = "broken", url = "http://127.0.0.1:$broken_port", model = "m")
            kb2 = open_kb(temp_config(summarizers = [b], summarizer = "broken", code_summarizer = "broken", judge = "broken", layers = Layer[]))
            r = only(ingest!(kb2, [add_codebase!(kb2, repo; name = "Repo")]))
            @test r.ok && r.parsed && !r.classified && occursin("classifier", r.error) && classification(kb2, r.id) === nothing
            close(kb2)
        finally
            close(broken)
        end

        # Probe questions are written once per seed and stored; asking again sends nothing.
        before = calls[]
        qs = probe_questions(kb, s, ["2609.00001"])      # no abstract recorded, so only a specific one
        @test [q.kind for q in qs] == [:specific] && calls[] == before + 1
        @test probe_questions(kb, s, ["2609.00001"]) == qs && calls[] == before + 1
        @test length(probe_questions(kb, s, ["2609.00001"]; seed = 2)) == 1 && calls[] == before + 2
        close(kb)
    finally
        close(server)
    end
    @test_throws ErrorException validate_layers = K.validate(Config(; layers = [Layer(; name = "x", model = "m", unit = :chunk, source = "deepseek-flash")]))
end

@zset "agents confined" begin
    home = realpath(mktempdir())
    cfg = joinpath(home, "conf", "config.toml")
    mkpath(dirname(cfg))
    write(cfg, """
        data_dir = "$(joinpath(home, "data"))"
        [[layers]]
        name = "remote"
        model = "m"
        unit = "chunk"
        url = "https://embed.example.org"
        key = "file:$(joinpath(home, "keys", "embed"))"
        [shared]
        github_app = { client_id = "a", private_key = "$(joinpath(home, "keys", "app.pem"))" }
        """)
    write(K.settings_path(cfg), "[[shared.providers]]\nname = \"Campus\"\nissuer = \"https://id.example.org\"\n" *
                                "client_id = \"c\"\nclient_secret = \"file:$(joinpath(home, "keys", "oidc"))\"\n")
    c = K.load_config(cfg)
    keys = K.key_files(c; path = cfg)
    @test all(in(keys), joinpath.(home, "keys", ["embed", "oidc", "app.pem"]))          # from the file and its settings
    policy = K.confine_policy(c, joinpath(home, "kaimon-cache"); path = cfg)
    denied = Set(chopprefix(l, "deny ") for l in split(policy, '\n') if startswith(l, "deny "))
    @test dirname(cfg) in denied && c.data_dir in denied && K.agents_dir() in denied
    @test joinpath(home, "kaimon-cache") in denied && joinpath(home, "keys", "oidc") in denied
    @test joinpath(homedir(), ".ssh") in denied
    @test isempty(K.confinement_env(K.Config(; shared = K.SharedConfig(; confine_agents = false)), nothing))
    @test K.load_config(cfg).shared.confine_agents                                    # on unless turned off
    Sys.islinux() || @test isempty(@test_logs (:warn, r"not confined") K.confinement_env(c, nothing))

    # An agent reads what its folder links to, and its file tools stay in its folder.
    dir = mkpath(joinpath(home, "agent"))
    pdf = joinpath(home, "data", "paper.pdf")
    mkpath(dirname(pdf)); touch(pdf)
    symlink(pdf, joinpath(dir, "paper.pdf"))
    symlink(joinpath(home, "gone"), joinpath(dir, "dangling"))
    touch(joinpath(dir, "notes.md"))
    @test K.agent_reads(dir) == [realpath(pdf)]
    @test K.file_tools(dir) == ["Read(/$dir/**)", "Write(/$dir/**)", "Edit(/$dir/**)"]
end

@zset "rank fusion" begin
    ranked =["keyword" => ["c:p1:0", "c:p2:3"], "layer-b" => ["c:p2:3", "s:p3:1"]]
    f = fuse(ranked)
    @test K.ranked_papers(f) == ["p2", "p1", "p3"]          # p2 appears in both rankings
    @test Set(e.ranking for e in f.paper_evidence["p2"]) == Set(["keyword", "layer-b"])
    @test only(e for e in f.paper_evidence["p2"] if e.ranking == "layer-b").rank == 1
    @test f.max_score ≈ 2 / (K.RRF_K + 1)                   # first place in both rankings
    @test haskey(f.chunk_score, "c:p2:3") && !haskey(f.chunk_score, "s:p3:1")   # sections score papers only
    @test f.paper_chunks == Dict("p1" => ["c:p1:0"], "p2" => ["c:p2:3"])
    @test K.ranked_papers(fuse(ranked; weights = Dict("layer-b" => 0.0))) == ["p1", "p2"]
    @test K.ranked_papers(fuse(ranked; weights = Dict("keyword" => 0.1))) == ["p2", "p3", "p1"]
    # A larger k flattens rank differences: at k = 0 one first place outweighs two second places.
    two = ["a" => ["c:x:0", "c:y:0"], "b" => ["c:z:0", "c:y:0"], "c" => ["c:x:0"]]
    @test K.ranked_papers(fuse(two; k = 0))[1] == "x"
    # Tasks and findings: unweighted, and one named by its reference first.
    @test K.rrf_scores([1, 2], [2]) == Dict(1 => 1 / 11, 2 => 1 / 12 + 1 / 11)
    ids, score = K.rank_found([3], [1, 2], [2, 3])
    @test ids == [3, 1, 2] && sort(ids; by = id -> -score(id)) == [3, 2, 1] && score(3) == 1 + 1 / 12

    q(paper, kind) = ProbeQuestion(paper, kind, "q", "")
    prs = [K.ProbeRankings(q("p1", :broad), ranked), K.ProbeRankings(q("p3", :specific), ranked)]
    m = score_ranking(prs)
    @test m.mrr_broad ≈ 1 / 2 && m.hit1_broad == 0.0 && m.hit5_broad == 1.0
    @test m.mrr_specific ≈ 1 / 3 && m.mrr ≈ (1 / 2 + 1 / 3) / 2
    @test score_ranking(prs; weights = Dict("layer-b" => 0.0)).mrr_broad == 1.0
    @test score_ranking(prs; weights = Dict("layer-b" => 0.0)).mrr_specific == 0.0   # p3 is only in layer-b
end

@zset "design point" begin
    ranked = ["keyword" => ["c:p1:0", "c:p2:3"], "chunk-a" => ["c:p2:3"], "section-s" => ["s:p2:1"]]
    q(paper, kind) = ProbeQuestion(paper, kind, "q", "")
    cost(name, source; s, ms, bytes, ctx = 8000) = LayerCost(; layer = name, unit = :chunk, model = "m", source,
        seconds_per_paper = s, query_ms = ms, vectors_per_paper = 10, bytes_per_paper = bytes, context_chars = ctx)
    d = DesignData(; probes = [K.ProbeRankings(q("p2", :broad), ranked), K.ProbeRankings(q("p1", :specific), ranked)],
        layers = Dict("chunk-a" => cost("chunk-a", ""; s = 2.0, ms = 50, bytes = 1e6),
                      "section-s" => cost("section-s", "llm"; s = 1.0, ms = 30, bytes = 1e5, ctx = 100_000)),
        summaries = Dict("llm" => SummaryCost(; summarizer = "llm", dollars_per_paper = 0.01, seconds_per_paper = 20.0)),
        keyword_ms = 5.0, fetch_seconds_per_paper = 3.0, parse_seconds_per_paper = 1.0)

    all_on = design_point(d; weights = Dict("keyword" => 1.0, "chunk-a" => 1.0, "section-s" => 1.0), corpus = 100)
    @test all_on.rankings_used == 3 && all_on.embed.layers == 2
    @test all_on.llm_dollars ≈ 1.0                                   # 100 papers × $0.01
    @test all_on.ingest_hours ≈ 100 * (3 + 1 + 20 + 2 + 1) / 3600
    @test all_on.storage_gb ≈ 100 * 1.1e6 / 1e9
    @test all_on.query_ms ≈ 85 && all_on.embed.min_context_chars == 8000
    @test all_on.mrr_broad == 1.0                                    # p2 leads two of three rankings

    # A weight under the threshold drops the layer and everything it costs; the summarizer goes
    # with the last layer that reads its summaries.
    lean = design_point(d; weights = Dict("keyword" => 1.0, "chunk-a" => 0.02, "section-s" => 0.0), corpus = 100)
    @test lean.rankings_used == 1 && lean.llm_dollars == 0.0 && lean.storage_gb == 0.0
    @test lean.ingest_hours ≈ 100 * 4 / 3600 && lean.query_ms ≈ 5
    @test lean.mrr_specific == 1.0 && lean.mrr_broad == 0.5          # keyword alone puts p1 first
end

@zset "evaluation" begin
    # With no vector layers embedded, the rankings are just keyword search, which is enough to check
    # the scoring.
    kb = open_kb(temp_config(layers = Layer[]))
    add_papers!(kb, ["2609.00001", "2609.00002"])
    head(t) = K.Piece(:heading, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 1, "")
    body(t) = K.Piece(:paragraph, 1, (0.0, 0.0, 0.0, 0.0), t, 1, 0, "")
    sections = [K.Section(1, 1, "1", "1. Body", "1. Body", 1, 1)]
    K.store_parse!(kb, "2609.00001", K.ParsedPaper(1, [head("1. Body"), body("Spawning corals release buoyant gamete bundles for reef replenishment.")], sections))
    K.store_parse!(kb, "2609.00002", K.ParsedPaper(1, [head("1. Body"), body("Seagrass beds grow where the water is shallow and clear.")], sections))
    passage(id) = K.scalar(kb, "SELECT c.text FROM chunks c JOIN papers p ON p.id = c.paper_id WHERE p.doc_id = ?", (id,))
    qs = [ProbeQuestion("2609.00001", :specific, "Which corals release buoyant gamete bundles?", passage("2609.00001")),
          ProbeQuestion("2609.00002", :specific, "Where do seagrass beds grow?", passage("2609.00002")),
          ProbeQuestion("2609.00002", :broad, "coral replenishment", "")]  # answered by the other paper
    ev = evaluate_rankings(kb, qs)
    row(level, kind, ranking) = only(r for r in ev.summary if r.level == level && r.kind == kind && r.ranking == ranking)
    kw = row(:paper, :specific, "keyword")
    @test kw.n == 2 && kw.hit1 == 1.0 && kw.mrr == 1.0
    broad = row(:paper, :broad, "fused")
    @test broad.hit1 == 0.0 && broad.mrr == 0.0
    @test Set(r.ranking for r in ev.summary) == Set(["keyword", "fused"])
    # The passage level: keyword search ranks passages, and finds each question's own.
    @test row(:passage, :specific, "keyword").hit1 == 1.0
    @test !any(r -> r.level == :passage && (r.kind == :broad || r.ranking == "fused"), ev.summary)
    close(kb)
end

@zset "papers by DOI" begin
    dir = mktempdir()
    write(joinpath(dir, "a.txt"), "%%MediaBox 0 0 612 792\n%%Font F1 Helvetica\nBT /F1 24 Tf 72 700 Td (Floods in a Small Catchment) Tj ET\n")
    run(`mutool create -o $(joinpath(dir, "a.pdf")) $(joinpath(dir, "a.txt"))`)
    port = 18000 + rand(0:999)
    server = K.HTTP.serve!("127.0.0.1", port) do req
        req.target == "/a.pdf" ? K.HTTP.Response(200, read(joinpath(dir, "a.pdf"))) : K.HTTP.Response(200, "<html>a publisher's page</html>")
    end
    copies = Dict("10.1/onarxiv" => (; arxiv = "2401.00002", pdfs = String[]), "10.1/open" => (; arxiv = nothing, pdfs = ["http://127.0.0.1:$port/a.pdf"]),
                  "10.1/page" => (; arxiv = nothing, pdfs = ["http://127.0.0.1:$port/page"]),
                  "10.1/second" => (; arxiv = nothing, pdfs = ["http://127.0.0.1:$port/page", "http://127.0.0.1:$port/a.pdf"]))
    saved = K.DOI_COPIES[]
    K.DOI_COPIES[] = (doi; contact = "") -> get(copies, doi, (; arxiv = nothing, pdfs = String[]))
    kb = open_kb(temp_config(layers = Layer[]))
    try
        # Its arXiv copy is that arXiv paper; its open PDF is read like an upload, with the source's title and the DOI.
        @test K.add_doi!(kb, "https://doi.org/10.1/OnArxiv"; source = "zotero") == "2401.00002"
        id = K.add_doi!(kb, "10.1/open"; title = "Floods in a small catchment", authors = ["Ada"], published = "2021", source = "zotero")
        p = K.paper_row(kb, id)
        @test startswith(id, "doc-") && p.title == "Floods in a small catchment" && p.doi == "10.1/open" && p.published == "2021"
        @test [m.source for m in K.mentions(kb, id)] == ["zotero"] && [m.source for m in K.mentions(kb, "2401.00002")] == ["zotero"]
        # Asked again, it is the paper already here; with no copy to read, or a page in place of one, there is none.
        @test K.add_doi!(kb, "10.1/open"; source = "zotero") == id
        @test K.add_doi!(kb, "10.1/page") === nothing && K.add_doi!(kb, "10.1/closed") === nothing
        # A copy that is a page is passed over for the next.
        @test startswith(something(K.add_doi!(kb, "10.1/second"), ""), "doc-")
        # A closed paper kept as a resource is no paper here: its copy, when one is found, is added.
        K.put_resource!(kb, "zotero", K.Resource(; key = "C1", title = "A closed paper", doi = "10.1/onarxiv2"); read = false)
        copies["10.1/onarxiv2"] = (; arxiv = "2401.00003", pdfs = String[])
        @test K.add_doi!(kb, "10.1/onarxiv2") == "2401.00003"
        # A copy OpenAlex does not know is searched for on arXiv by its title: the same title, and its DOI or an author's surname.
        meta(id, t, authors; doi = nothing) = K.PaperMeta(; doc_id = id, version = "v1", title = t, abstract = "", authors, published = "2020",
                                                          updated = "2020", primary_category = "physics.ao-ph", categories = ["physics.ao-ph"], doi)
        saved_search = K.ARXIV_TITLE_SEARCH[]
        K.ARXIV_TITLE_SEARCH[] = (t, c) -> [meta("2401.00009", "Rainfall over Bali", ["Rowan Hale"]), meta("2401.00004", "Rainfall over Bali", ["Bea Ng"])]
        try
            @test K.add_doi!(kb, "10.1/rain"; title = "Rainfall Over Bali", authors = ["Ng, Bea"]) == "2401.00004"
            @test K.add_doi!(kb, "10.1/snow"; title = "Snowfall over Bali", authors = ["Ng, Bea"]) === nothing
            @test K.add_doi!(kb, "10.1/rain2"; title = "Rainfall over Bali", authors = ["Ada Lovelace"]) === nothing
        finally
            K.ARXIV_TITLE_SEARCH[] = saved_search
        end
        @test_throws "Not a DOI" K.add_doi!(kb, " ")
    finally
        K.DOI_COPIES[] = saved
        close(server)
        close(kb)
    end
end

@zset "zotero" begin
    # A stand-in for Zotero's API: a group's items, each with the library version it was last changed in.
    item(key, version, type, title; doi = "", url = "", parent = "", note = "", creators = []) =
        Dict("key" => key, "version" => version, "data" => Dict("key" => key, "itemType" => type, "title" => title, "DOI" => doi, "url" => url,
                                                               "parentItem" => parent, "note" => note, "creators" => creators, "date" => "2021-03-01"))
    items = [item("A1", 1, "journalArticle", "Rainfall over Bali"; doi = "10.1/rain", creators = [Dict("creatorType" => "author", "firstName" => "Bea", "lastName" => "Ng")]),
             item("A2", 1, "journalArticle", "Rainfall over Bali"; doi = "10.1/rain"),
             item("D1", 1, "document", "Copernicus DEM GLO-30"; url = "https://example.org/dem"),
             item("N1", 1, "note", ""; parent = "D1", note = "<p>Data set, CC BY 4.0</p>"),
             item("D2", 1, "document", "Copernicus DEM GLO-30"),
             item("C1", 1, "journalArticle", "A closed paper"; doi = "10.1/closed"),
             item("C2", 1, "journalArticle", "A closed paper"; doi = "10.1/CLOSED"),
             item("B1", 1, "journalArticle", "A paper OpenAlex fails on"; doi = "10.1/boom")]
    # What a citation needs: who published the data set, an organization as its author, and when it was accessed.
    merge!(items[3]["data"], Dict("publisher" => "European Space Agency", "extra" => "Published: Copernicus Data Space",
                                  "creators" => [Dict("creatorType" => "author", "name" => "European Space Agency"),
                                                 Dict("creatorType" => "author", "firstName" => "Rowan", "lastName" => "Hale")]))
    items[4]["data"]["note"] = "<p>Data set, CC BY 4.0. Accessed 5 November 2026</p>"
    booms = Ref(0)
    port = 18000 + rand(0:999)
    asked = String[]
    server = K.HTTP.serve!("127.0.0.1", port) do req
        q = K.HTTP.queryparams(K.HTTP.URI(req.target))
        push!(asked, q["since"])
        since = parse(Int, q["since"])
        latest = maximum(x -> x["version"], items)
        K.HTTP.header(req, "If-Modified-Since-Version", "") == string(latest) && return K.HTTP.Response(304, ["Last-Modified-Version" => string(latest)])
        changed = haskey(q, "itemKey") ? [x for x in items if x["key"] in split(q["itemKey"], ',')] : [x for x in items if x["version"] > since]
        K.HTTP.Response(200, ["Last-Modified-Version" => string(maximum(x -> x["version"], items)), "Total-Results" => string(length(changed))],
                        K.JSON.json(changed))
    end
    saved_api, saved_copies = K.ZOTERO_API[], K.DOI_COPIES[]
    K.ZOTERO_API[] = "http://127.0.0.1:$port"
    opened = Ref(false)                              # the closed paper's copy, found later
    K.DOI_COPIES[] = (doi; contact = "") -> doi == "10.1/boom" && (booms[] += 1) == 1 ? error("OpenAlex is busy") :
                                             doi == "10.1/rain" ? (; arxiv = "2401.00002", pdfs = String[]) :
                                             doi == "10.1/closed" && opened[] ? (; arxiv = "2401.00003", pdfs = String[]) : (; arxiv = nothing, pdfs = String[])
    K.READ_PUT[] = false
    kb = open_kb(temp_config(layers = Layer[]))
    try
        # Run only where the config has its section.
        z = K.registered_source("zotero")
        @test z.configured && !K.used_here(kb, z) && !any(x -> x["name"] == "zotero", K.sources_status(kb))
        K.create_project!(kb, "Wetlands"; key = "WE", owner = nothing, by = K.person("Ada"))
        kb.config = K.with_config(kb.config; sources = Dict{String,Any}("zotero" => Dict{String,Any}("groups" => Dict{String,Any}("1" => "WE"))))
        @test K.used_here(kb, z)
        @test K.code_host_repository("https://github.com/Ada/Geomorphometry.jl") && K.code_host_repository("https://gitlab.com/ada/flow.git")
        @test !K.code_host_repository("https://example.org/dem") && !K.code_host_repository("https://github.com/Ada/Geomorphometry.jl/issues/3")

        # The paper with an arXiv copy, once for its two items; the data set a resource with its note, once for its two;
        # the closed paper a resource with its DOI. All kept in the project's library.
        run = K.SourceRun(kb, z)
        K.zotero_poll(run)
        res = [r.doc_id for r in K.query(kb, "SELECT doc_id FROM papers WHERE kind = 'resource' ORDER BY title")]
        @test length(res) == 2 && !ismissing(K.paper_id(kb, "2401.00002"))
        # An item that failed does not stop the run, and is tried again in the next.
        @test K.state(run)["retry"] == Dict("1" => ["B1"])
        dem = only(r for r in res if K.paper_row(kb, r).title == "Copernicus DEM GLO-30")
        @test K.resource_row(kb, dem).note == "Data set, CC BY 4.0. Accessed 5 November 2026" && K.resource_row(kb, dem).type == "document" && K.paper_row(kb, dem).published == "2021-03-01"
        closed = only(r for r in res if r != dem)
        @test K.paper_row(kb, closed).doi == "10.1/closed"
        @test Set(x.target for x in K.library(kb, "WE")) == Set(["2401.00002", dem, closed])
        @test K.state(run)["versions"] == Dict("1" => 1) && [m.source for m in K.mentions(kb, "2401.00002")] == ["zotero"]
        # Nothing changed since: Zotero says so, and only the item that failed is asked for again.
        K.zotero_poll(run)
        @test K.state(run)["versions"] == Dict("1" => 1) && K.state(run)["retry"] == Dict("1" => String[])

        # Where it appeared, who published it, which authors are organizations, and when it was accessed.
        d = K.resource_row(kb, dem)
        @test (d.container, d.publisher, d.accessed) == ("Copernicus Data Space", "European Space Agency", "2026-11-05")
        @test K.json_list(d.organizations) == ["European Space Agency"]
        bib = K.bib_entry(kb, dem)
        @test startswith(bib, "@misc{$dem,") && occursin("author = {{European Space Agency} and Hale, Rowan}", bib)
        @test occursin("howpublished = {Copernicus Data Space}", bib) && !occursin("note = ", bib)
        @test occursin("url = {https://example.org/dem}", bib) && occursin("urldate = {2026-11-05}", bib)
        @test occursin("docpage = {generated/kb/resources/", bib)
        # A run made by an older reading reads the whole library again: its resources gain what is read
        # now, and items that are one work stay one document.
        resources() = K.scalar(kb, "SELECT count(*) FROM papers WHERE kind = 'resource'")
        before = resources()
        K.save_state!(run, merge(K.state(run), Dict("reading" => 1)))
        empty!(asked)
        K.zotero_poll(run)
        @test asked == ["0"] && K.state(run)["reading"] == K.ZOTERO_READING && resources() == before
        # A copy of a closed paper found since: the paper takes its resource's place.
        opened[] = true
        K.save_state!(run, merge(K.state(run), Dict("reading" => 1)))
        K.zotero_poll(run)
        @test resources() == before - 1 && ismissing(K.paper_id(kb, closed)) && K.current_document(kb, closed) == "2401.00003"
        @test "2401.00003" in [x.target for x in K.library(kb, "WE")] && !(closed in [x.target for x in K.library(kb, "WE")])

        # The next run asks only for what changed since; a document dropped here is not brought in again.
        K.drop!(kb, dem; by = "Ada", why = "Not ours")
        items[3]["version"] = 2; items[3]["data"]["title"] = "Copernicus DEM GLO-30 (2021)"
        push!(items, item("R1", 2, "report", "Treatment wetlands"))
        run = K.SourceRun(kb, z)
        K.zotero_poll(run)
        @test "1" in asked && ismissing(K.paper_id(kb, dem)) && run.dropped == 1
        @test K.state(run)["retry"] == Dict("1" => String[]) && any(r -> K.paper_row(kb, r.doc_id).title == "A paper OpenAlex fails on",
                                                                    K.query(kb, "SELECT doc_id FROM papers WHERE kind = 'resource'"))
        wet = only(r.doc_id for r in K.query(kb, "SELECT doc_id FROM papers WHERE kind = 'resource'")
                   if K.paper_row(kb, r.doc_id).title == "Treatment wetlands")
        # A report is a technical report of its institution; without one, a misc.
        @test startswith(K.bib_entry(kb, wet), "@misc{")
        items[end]["version"] = 3; items[end]["data"]["institution"] = "University of Kassel"
        K.zotero_poll(run)
        @test startswith(K.bib_entry(kb, wet), "@techreport{") && occursin("institution = {University of Kassel}", K.bib_entry(kb, wet))
        # Restored, the next run brings it back, though Zotero has no change to it.
        K.restore!(kb, dem; by = "Ada")
        empty!(asked)
        K.zotero_poll(run)
        @test !ismissing(K.paper_id(kb, dem)) && K.paper_row(kb, dem).title == "Copernicus DEM GLO-30 (2021)"
    finally
        K.ZOTERO_API[], K.DOI_COPIES[] = saved_api, saved_copies
        K.READ_PUT[] = true
        close(server)
        close(kb)
    end
end

@zset "the Zotero prescreen" begin
    HTTP, JSON = K.HTTP, K.JSON
    item(key, type, title; doi = "", url = "") =
        Dict("key" => key, "version" => 1, "data" => Dict("key" => key, "itemType" => type, "title" => title, "DOI" => doi, "url" => url,
                                                          "creators" => [], "date" => "2025"))
    items = [item("P1", "journalArticle", "Rain over the hills"; doi = "10.1/rain"),
             item("J1", "journalArticle", "A digital elevation model"; doi = "10.1/dem"),
             item("W1", "document", "Floods in the south"; url = "https://example.org/floods"),
             item("S1", "document", "Untitled stub"),
             item("L1", "document", "Left out by the model")]
    # What the model says of each, by key; one it leaves out, and a key it was not asked about.
    says = Dict("P1" => Dict("as" => "paper", "sure" => true, "why" => "a research article"),
                "J1" => Dict("as" => "resource", "type" => "dataset", "sure" => true, "why" => "a data set filed as an article"),
                "W1" => Dict("as" => "resource", "type" => "news", "sure" => false, "why" => "a news story, perhaps a report"),
                "S1" => Dict("as" => "skip", "sure" => true, "why" => "a placeholder"),
                "X9" => Dict("as" => "paper", "sure" => true, "why" => "not asked"))
    asked = Ref(0)
    port = 18000 + rand(0:999)
    server = HTTP.serve!("127.0.0.1", port) do req
        path = HTTP.URI(req.target).path
        if endswith(path, "/chat/completions")
            asked[] += 1
            content = JSON.parse(String(req.body))["messages"][2]["content"]
            prompt = content isa String ? content : join((p["text"] for p in content if p["type"] == "text"), "\n")
            keys = [m[1] for m in eachmatch(r"- key: (\w+);", prompt)]
            reply = Dict("items" => [merge(Dict("key" => k), says[k]) for k in [keys; "X9"] if haskey(says, k)])
            HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "Sorted: " * JSON.json(reply)))],
                                              "usage" => Dict("prompt_tokens" => 10, "completion_tokens" => 5))))
        else
            HTTP.Response(200, ["Last-Modified-Version" => "1", "Total-Results" => string(length(items))], JSON.json(items))
        end
    end
    saved = (K.ZOTERO_API[], K.DOI_COPIES[], K.ZOTERO_PRESCREEN[])
    K.ZOTERO_API[] = "http://127.0.0.1:$port"
    tried = String[]
    K.DOI_COPIES[] = (doi; contact = "") -> (push!(tried, doi); doi == "10.1/rain" ? (; arxiv = "2401.00003", pdfs = String[]) : (; arxiv = nothing, pdfs = String[]))
    K.ZOTERO_PRESCREEN[] = K.zotero_prescreen
    K.READ_PUT[] = false
    s = Summarizer(; name = "fake", url = "http://127.0.0.1:$port", model = "fake-model")
    kb = open_kb(temp_config(summarizers = [s], summarizer = "fake", code_summarizer = "fake", judge = "fake", layers = Layer[],
                             sources = Dict{String,Any}("zotero" => Dict{String,Any}("groups" => Dict{String,Any}("1" => "WE")))))
    try
        K.create_project!(kb, "Wetlands"; key = "WE", owner = nothing, by = K.person("Ada"))
        run = K.SourceRun(kb, K.registered_source("zotero"))
        K.zotero_poll(run)
        # The paper is looked for by its DOI; the data set filed as an article is not, and is a data set.
        @test tried == ["10.1/rain"] && !ismissing(K.paper_id(kb, "2401.00003"))
        resource(title) = only(r.doc_id for r in K.query(kb, "SELECT doc_id, title FROM papers WHERE kind = 'resource'") if r.title == title)
        @test K.resource_row(kb, resource("A digital elevation model")).type == "dataset"
        # One it is unsure of is proposed, with its reason; the rest are kept; a placeholder is not brought in.
        lib = Dict(x.target => x for x in K.library(kb, "WE"))
        news = resource("Floods in the south")
        @test K.resource_row(kb, news).type == "news" && lib[news].status == "proposed" && occursin("perhaps a report", lib[news].why)
        @test lib["2401.00003"].status == "kept" && lib[resource("A digital elevation model")].status == "kept"
        @test K.scalar(kb, "SELECT count(*) FROM papers WHERE title = 'Untitled stub'") == 0
        # One the model left out is tried again in the next run, and only it is asked about.
        @test K.state(run)["retry"] == Dict("1" => ["L1"])
        says["L1"] = Dict("as" => "resource", "type" => "web page", "sure" => true, "why" => "a portal")
        before = asked[]
        K.zotero_poll(run)
        @test asked[] == before + 1 && K.resource_row(kb, resource("Left out by the model")).type == "web page"
        @test K.state(run)["retry"] == Dict("1" => String[])
        # The model is told each item's fields, and the group.
        @test K.prescreen_prompt(items[1:1], Dict{String,Vector{String}}(), "Wetland hydrology") |> p ->
              occursin("- key: P1; zotero type: journalArticle; title: Rain over the hills", p) && occursin("Wetland hydrology", p)
    finally
        K.ZOTERO_API[], K.DOI_COPIES[], K.ZOTERO_PRESCREEN[] = saved
        K.READ_PUT[] = true
        close(server)
        close(kb)
    end
end

@zset "a paper uploaded that is already here" begin
    dir = mktempdir()
    page = """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 24 Tf 72 700 Td (A Paper Read Twice) Tj ET
        BT /F1 10 Tf 72 650 Td (Abstract. Uploads of a paper the knowledge base has are that paper.) Tj ET
        """
    pdf(name, extra = "") = (write(joinpath(dir, "$name.txt"), page * extra);
                             run(`mutool create -o $(joinpath(dir, "$name.pdf")) $(joinpath(dir, "$name.txt"))`); joinpath(dir, "$name.pdf"))
    kb = open_kb(temp_config(layers = Layer[]))
    saved = K.UPLOAD_LOOKUP[]
    try
        # arXiv's PDF of a paper, stamped with its id on the first page, is that arXiv paper.
        stamped = pdf("stamped", "BT /F1 8 Tf 20 400 Td (arXiv:2401.00001v2  [physics.ao-ph]  3 Jan 2024) Tj ET\n")
        @test K.arxiv_stamp(stamped, kb.config) == "2401.00001" && K.arxiv_stamp(pdf("plain"), kb.config) === nothing
        @test add_pdf!(kb, stamped) == "2401.00001" && add_pdf!(kb, stamped) == "2401.00001"
        docs() = K.scalar(kb, "SELECT count(*) FROM papers WHERE doc_id LIKE 'doc-%'")
        @test docs() == 0 && only(mentions(kb, "2401.00001")).source == "upload"
        # Another file of a paper here, its published record giving the paper's DOI, is that paper.
        K.execute!(kb, "UPDATE papers SET doi = '10.1000/xyz' WHERE doc_id = '2401.00001'")
        K.UPLOAD_LOOKUP[] = (p; contact = "") -> (; title = "A Paper Read Twice", authors = String[], year = "2024",
                                                   journal_ref = nothing, doi = "10.1000/XYZ", abstract = nothing)
        files = length(readdir(K.pdf_dir(kb.config)))
        @test add_pdf!(kb, pdf("journal", "BT /F1 10 Tf 72 600 Td (Published in a journal.) Tj ET\n")) == "2401.00001"
        @test docs() == 0 && length(readdir(K.pdf_dir(kb.config))) == files      # nothing recorded, its copy not kept
        # Where the record can't be looked up, the upload is added, to be looked up again later.
        K.UPLOAD_LOOKUP[] = (p; contact = "") -> error("offline")
        other = add_pdf!(kb, pdf("other", "BT /F1 10 Tf 72 600 Td (Another version.) Tj ET\n"))
        @test startswith(other, "doc-") && ismissing(K.paper_row(kb, other).looked_up_at)
        # So is one whose lookup takes too long.
        K.UPLOAD_LOOKUP[] = (p; contact = "") -> (sleep(5); nothing)
        wait_was = K.UPLOAD_LOOKUP_WAIT[]
        K.UPLOAD_LOOKUP_WAIT[] = 0.2
        slow = try @timed add_pdf!(kb, pdf("slow", "BT /F1 10 Tf 72 600 Td (A slow record.) Tj ET\n")) finally K.UPLOAD_LOOKUP_WAIT[] = wait_was end
        @test slow.time < 4 && ismissing(K.paper_row(kb, slow.value).looked_up_at)
        K.remove_paper!(kb, slow.value)
        K.UPLOAD_LOOKUP[] = (p; contact = "") -> error("offline")
        @test K.already_read(kb, ["2401.00001", other]) == []                     # neither read yet
        # Uploaded again, its record stays as it was made (healed from the published one, say).
        K.execute!(kb, "UPDATE papers SET title = 'Healed title', authors = '[\"Ada Lovelace\"]' WHERE doc_id = ?", (other,))
        @test add_pdf!(kb, pdf("other", "BT /F1 10 Tf 72 600 Td (Another version.) Tj ET\n")) == other
        @test (K.paper_row(kb, other).title, K.paper_row(kb, other).authors) == ("Healed title", "[\"Ada Lovelace\"]")
        @test add_pdf!(kb, pdf("other", "BT /F1 10 Tf 72 600 Td (Another version.) Tj ET\n"); title = "Given") == other &&
              K.paper_row(kb, other).title == "Given"                             # but for what the upload gives
    finally
        K.UPLOAD_LOOKUP[] = saved
        close(kb)
    end
end

@zset "a dropped document is kept out" begin
    dir = mktempdir()
    write(joinpath(dir, "a.txt"), "%%MediaBox 0 0 612 792\n%%Font F1 Helvetica\nBT /F1 24 Tf 72 700 Td (A Survey of Wells) Tj ET\n")
    run(`mutool create -o $(joinpath(dir, "a.pdf")) $(joinpath(dir, "a.txt"))`)
    pdf = joinpath(dir, "a.pdf")
    saved_lookup, saved_copies = K.UPLOAD_LOOKUP[], K.DOI_COPIES[]
    K.UPLOAD_LOOKUP[] = (p; contact = "") -> nothing
    K.DOI_COPIES[] = (doi; contact = "") -> (; arxiv = nothing, pdfs = String[])
    K.READ_PUT[] = false
    kb = open_kb(temp_config(layers = Layer[]))
    try
        # Dropped, an arXiv paper is gone and listed with who dropped it and why.
        add_papers!(kb, ["2609.00001"])
        K.drop!(kb, "2609.00001"; by = "Ada", why = "Off topic")
        @test ismissing(K.paper_id(kb, "2609.00001"))
        d = only(K.dropped_documents(kb))
        @test (d.id, d.title, d.kind, d.by, d.why) == ("2609.00001", "2609.00001", "paper", "Ada", "Off topic")
        # A source bringing it leaves it out; a person adding it is told, and adding it anyway restores it.
        @test add_papers!(kb, ["2609.00001", "2609.00002"]; source = "watch") == ["2609.00002"]
        e = try add_papers!(kb, ["2609.00001"]); nothing catch e; e end
        @test e isa K.DroppedError && sprint(showerror, e) ==
              "2609.00001 (2609.00001) was dropped by Ada on $(first(K.now_iso(), 10)): Off topic. Adding it anyway restores it."
        @test K.error_status(e) == 409 && K.reason(e) == sprint(showerror, e)
        @test add_papers!(kb, ["2609.00001"]; anyway = true, by = "Rowan") == ["2609.00001"]
        @test isempty(K.dropped_documents(kb)) && K.restored_documents(kb) == Set(["2609.00001"])
        @test K.scalar(kb, "SELECT restored_by FROM dropped WHERE doc_id = '2609.00001'") == "Rowan"
        @test_throws "is not dropped" K.restore!(kb, "2609.00001")

        # An upload is kept out as its file and by its DOI.
        up = add_pdf!(kb, pdf)
        K.execute!(kb, "UPDATE papers SET doi = '10.1/wells' WHERE doc_id = ?", (up,))
        K.drop!(kb, up; by = "Ada")
        @test_throws K.DroppedError add_pdf!(kb, pdf)
        @test_throws K.DroppedError K.add_doi!(kb, "https://doi.org/10.1/WELLS"; source = "zotero")
        K.UPLOAD_LOOKUP[] = (p; contact = "") -> (; title = "A Survey of Wells", authors = String[], year = "2024",
                                                   journal_ref = nothing, doi = "10.1/wells", abstract = nothing)
        write(joinpath(dir, "b.txt"), read(joinpath(dir, "a.txt"), String) * "BT /F1 10 Tf 72 600 Td (Another file.) Tj ET\n")
        run(`mutool create -o $(joinpath(dir, "b.pdf")) $(joinpath(dir, "b.txt"))`)
        files = length(readdir(K.pdf_dir(kb.config)))
        @test_throws K.DroppedError add_pdf!(kb, joinpath(dir, "b.pdf"))
        @test length(readdir(K.pdf_dir(kb.config))) == files                       # its copy not kept
        @test add_pdf!(kb, pdf; anyway = true) == up && isempty(K.dropped_documents(kb))

        # A record is kept out by its source's key: the run counts it, and it comes back once restored.
        kb.config = K.with_config(kb.config; sources = Dict{String,Any}("zz-drop" => Dict{String,Any}()))
        noop(run) = nothing
        src = record_source!("zz-drop"; label = "Written up", every = 60, poll = noop, api = K.PLUGIN_API)
        meeting = (; key = "m1", title = "Pump review", date = "2026-10-02", sections = ["Notes" => "It held."])
        run1 = K.SourceRun(kb, src)
        id = put!(run1, meeting)
        K.drop!(kb, id; by = "Ada", why = "A test meeting")
        run2 = K.SourceRun(kb, src)
        @test put!(run2, meeting) === nothing && run2.dropped == 1 && ismissing(K.paper_id(kb, id))
        @test K.run_summary(run2) == "0 added, 0 changed, 0 skipped, 1 dropped kept out"
        K.restore!(kb, id; by = "Ada")
        @test put!(K.SourceRun(kb, src), meeting) == id && !ismissing(K.paper_id(kb, id))

        # A resource, by its title where it has no DOI; a codebase, by its repository.
        rid, _ = K.put_resource!(kb, "zotero", K.Resource(; key = "R1", title = "Well levels, 2020"); read = false)
        K.drop!(kb, rid; by = "Ada")
        @test_throws K.DroppedError K.put_resource!(kb, "zotero", K.Resource(; key = "R2", title = "Well Levels 2020"); read = false)
        @test first(K.put_resource!(kb, "zotero", K.Resource(; key = "R3", title = "Well levels, 2021"); read = false)) != rid
        code = K.link_repository!(kb, "https://github.com/ada/wells")
        K.drop!(kb, code; by = "Ada")
        @test_throws K.DroppedError K.link_repository!(kb, "https://github.com/ada/wells.git")
        @test K.link_repository!(kb, "https://github.com/ada/wells"; anyway = true) == code

        # The watch does not take in, nor the judge rate, a paper dropped here.
        K.drop!(kb, "2609.00002"; by = "Ada")
        K.execute!(kb, """INSERT INTO watch (doc_id, title, authors, abstract, published, category, score, area, area_score,
                          nearest, found_at, relevance, reason) VALUES ('2609.00002', 'P', '[]', '', '2026-10-10', 'x', 0.5, 'A', 0.5,
                          '[]', ?, 3, 'Central')""", (K.now_iso(),))
        @test K.take_watched!(kb; read_in_full = ids -> error("none"), record = ids -> error("none")) == (; read = String[], recorded = String[])
        @test "2609.00002" ∉ [c.id for c in K.daily_candidates(kb)]

        # Through the API: dropping with a reason, the list, a refusal that says why, restoring.
        call(method, target, body = Dict()) = (r = K.respond_local(kb, K.HTTP.Request(method, target,
                                                   ["X-Zemi" => "1", "Content-Type" => "application/json"], K.JSON.json(body)));
                                               (r.status, K.JSON.parse(String(r.body))))
        add_papers!(kb, ["2609.00003"])
        status, body = call("POST", "/api/actions", Dict("action" => "drop", "ids" => ["2609.00003"], "why" => "Duplicate"))
        @test status == 200
        @test timedwait(() -> K.get_job(body["job"]).status != :running, 30; pollint = 0.05) == :ok && K.get_job(body["job"]).status == :done
        listed = call("GET", "/api/dropped")[2]["dropped"]
        @test [(x["id"], x["why"]) for x in listed] == [("2609.00003", "Duplicate"), ("2609.00002", ""), (rid, "")]
        status, body = call("POST", "/api/documents", Dict("arxiv" => "2609.00003", "read" => false))
        @test status == 409 && body["dropped"]["id"] == "2609.00003" && occursin("Duplicate", body["error"])
        @test call("POST", "/api/dropped/restore", Dict("ids" => [x["id"] for x in listed])) ==
              (200, Dict("restored" => [x["id"] for x in listed]))
        @test isempty(call("GET", "/api/dropped")[2]["dropped"])
    finally
        K.UPLOAD_LOOKUP[], K.DOI_COPIES[] = saved_lookup, saved_copies
        K.READ_PUT[] = true
        close(kb)
    end
end

@zset "every figure and table of a paper" begin
    # Captions that name their figure or table and say what it shows; Roman-numbered tables read as paragraphs.
    cap(text; kind = "caption") = (; kind, text)
    found = K.captions([cap("Figure 3 follows the currents."), cap("FIG. 4. The tide."), cap("Fig. 2: X."), cap("Figure 4: again."),
                        cap("Figure 1. Not a caption."; kind = "paragraph"), cap("TABLE IV. Roman."; kind = "paragraph"), cap("Table 2: Two.")])
    @test [(c.kind, c.number, c.label) for c in found] == [("figure", 2, "Figure 2"), ("figure", 4, "Figure 4"), ("table", 2, "Table 2"), ("table", 4, "Table IV")]
    @test K.caption_number("XIV") == 14 && K.caption_number("12") == 12 && K.caption_number("Q") === nothing
    # Mentions in an analysis's text, and each figure the analysis picked placed after the paragraph first discussing it.
    @test K.figure_mentions("Figs. 2 and 4 compare; Figure 3b too; FIG. 2 again; Table II lists; the configuration 3") ==
          [("figure", 2), ("figure", 4), ("figure", 3), ("table", 2)]
    @test K.figure_mentions("figure 5 and Fig. IV") == [("figure", 5)]                # a figure's number is in digits
    md = "Intro.\n\nThe result is in Fig. 2.\n\n```math\na\n\nFig. 9\n```\n\nTable II lists them.\n\n## On Fig. 7\n"
    placed = K.figure_places(md, Dict(("figure", 2) => 2, ("table", 2) => 3, ("figure", 7) => 7))
    @test placed[1:3] == [7, "Intro.\n\nThe result is in Fig. 2.", 2] && placed[5:6] == [3, "## On Fig. 7"]
    @test placed[4] == "```math\na\n\nFig. 9\n```\n\nTable II lists them."         # a math block kept whole
    dir = mktempdir()
    pdf = joinpath(dir, "figures.pdf")
    write(joinpath(dir, "page1.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 18 Tf 72 740 Td (Figures Everywhere) Tj ET
        BT /F1 10 Tf 72 715 Td (Abstract. A paper with two figures on its page, to cut both of them from it.) Tj ET
        0 0 1 rg 100 520 200 150 re f
        BT /F1 4 Tf 110 600 Td (A legend inside the figure, long but narrow, which is no running text.) Tj ET
        BT /F1 9 Tf 72 500 Td (Figure 1. A blue box, the first figure, with a caption that spans the page.) Tj ET
        BT /F1 10 Tf 72 470 Td (Body text between the figures, long enough to read as a paragraph, as Fig. 2 shows.) Tj ET
        1 0 0 rg 100 260 200 150 re f
        BT /F1 9 Tf 72 240 Td (Figure 2: A red box, the second figure.) Tj ET
        """)
    write(joinpath(dir, "page2.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 10 Tf 72 740 Td (A paragraph that opens the second page, long enough to be read as running text here.) Tj ET
        BT /F1 9 Tf 72 700 Td (Table 1. Two numbers and their names.) Tj ET
        BT /F1 9 Tf 100 680 Td (alpha 1.0) Tj ET
        BT /F1 9 Tf 400 680 Td (third column) Tj ET
        BT /F1 9 Tf 100 666 Td (beta 2.0) Tj ET
        BT /F1 10 Tf 72 620 Td (Running text after the table, a sentence long enough to read as a paragraph of words.) Tj ET
        BT /F1 9 Tf 72 560 Td (TABLE II. Roman numbered.) Tj ET
        BT /F1 9 Tf 100 540 Td (gamma 3.0) Tj ET
        BT /F1 10 Tf 72 500 Td (More running text after the second table, again long enough to read as a paragraph.) Tj ET
        """)
    write(joinpath(dir, "page3.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 10 Tf 72 740 Td (Running text that opens the third page, long enough to be read as a paragraph here.) Tj ET
        BT /F1 9 Tf 150 700 Td (delta 4.0) Tj ET
        BT /F1 9 Tf 150 686 Td (epsilon 5.0) Tj ET
        BT /F1 9 Tf 72 660 Td (TABLE III. Set below its rows, as some journals set their tables.) Tj ET
        BT /F1 10 Tf 72 620 Td (Running text after the third table, a sentence long enough to read as a paragraph.) Tj ET
        """)
    run(`mutool create -o $pdf $(joinpath(dir, "page1.txt")) $(joinpath(dir, "page2.txt")) $(joinpath(dir, "page3.txt"))`)
    kb = open_kb(temp_config(layers = Layer[]))
    saved = K.UPLOAD_LOOKUP[]
    K.UPLOAD_LOOKUP[] = (p; contact = "") -> nothing
    try
        id = add_pdf!(kb, pdf)
        @test only(ingest!(kb, [id])).ok
        # Reading it cut every figure and table, once, as WebP images at 300 DPI.
        folder = K.figures_dir(kb.config, id)
        files = ["fig-1.webp", "fig-2.webp", "table-1.webp", "table-2.webp", "table-3.webp"]
        @test [f.file for f in K.paper_figures(kb, id)] == files && sort(readdir(folder)) == files
        @test read(joinpath(folder, "fig-1.webp"), 12)[9:12] == b"WEBP"
        r1 = K.figure_region(K.query(kb, "SELECT kind, page, x0, y0, x1, y1, text FROM blocks WHERE paper_id = ? ORDER BY ord", (K.paper_id(kb, id),)), "Figure 1")
        @test all(abs.(K.image_size(joinpath(folder, "fig-1.webp")) .- ((r1.x1 - r1.x0) * 300 / 72, (r1.y1 - r1.y0) * 300 / 72)) .<= 1)
        @test [f.label for f in K.paper_figures(kb, id)] == ["Figure 1", "Figure 2", "Table 1", "Table II", "Table III"]
        K.execute!(kb, "INSERT INTO kv VALUES ('daily_figures_swept', 'x')")
        @test K.start_figure_sweep(kb) === nothing                                 # nothing left to sweep
        blocks = K.query(kb, "SELECT kind, page, x0, y0, x1, y1, text FROM blocks WHERE paper_id = ? ORDER BY ord", (K.paper_id(kb, id),))
        t = K.figure_region(blocks, "Table 1")
        @test t.page == 2 && t.y0 > 90 && t.y1 < 175                               # below its caption, above the text after it
        @test t.x1 > 300                                                           # as wide as its rows, past its caption
        f1 = K.figure_region(blocks, "Figure 1")
        @test f1.y0 < 125                                                          # from the top of the box, past its own legend
        t3 = K.figure_region(blocks, "Table III")
        @test t3.page == 3 && t3.y1 < 132 && t3.y0 < 95                          # above its caption, where its rows are
        @test K.figure_region(blocks, "Table II").page == 2                        # "II" is not "I"
        write(joinpath(folder, "fig-9.webp"), "left from before")
        write(joinpath(folder, "fig-1.png"), "cut as PNG before")
        @test length(K.cut_paper_figures!(kb, id)) == 5 && sort(readdir(folder)) == files   # what is no longer cut goes
        # The analysis's picks point at the paper's figures; one not found is kept, to try again.
        picks = [Dict{String,Any}("label" => "Figure 2", "why" => "The red one."), Dict{String,Any}("label" => "Table 1", "why" => "Numbers."),
                 Dict{String,Any}("label" => "Figure 7", "why" => "None.")]
        @test K.cut_figures!(kb, id, picks) == 2 && picks[1]["file"] == "fig-2.webp" && picks[2]["file"] == "table-1.webp" && !haskey(picks[3], "file")
        # Sent as they are looked at, in either theme; the site's build copies only the picks of the days.
        slug = K.page_slug(id)
        @test [f["src"] for f in K.figures_json(kb, id)][1] == "/api/figures/$slug/fig-1.webp"
        @test K.figure_file(kb, slug, "fig-1.webp") == joinpath(folder, "fig-1.webp")
        @test K.figure_file(kb, slug, "fig-1.webp"; theme = "dark") == joinpath(folder, "fig-1-dark.webp") && isfile(joinpath(folder, "fig-1-dark.webp"))
        @test K.figure_file(kb, slug, "../x.webp") == "" && K.figure_file(kb, slug, "fig-1.svg") == ""
        get(target) = K.respond_local(kb, K.HTTP.Request("GET", target))
        served = get("/api/figures/$slug/table-1.webp")
        @test served.status == 200 && K.HTTP.header(served, "Content-Type") == "image/webp" && get("/api/figures/$slug/fig-9.webp").status == 404
        @test K.JSON.parse(String(get("/api/figures?id=$id").body))[3]["label"] == "Table 1"
        # For agents: picked by label, found where the text mentions them, and a page as an image.
        figs = K.paper_figures(kb, id)
        @test [f.label for f in K.pick_figures(figs, "2, Table II, fig. 1")] == ["Figure 2", "Table II", "Figure 1"]
        @test_throws "No Fig. 7" K.pick_figures(figs, "Fig. 7")
        @test only(K.figure_mentions_in(kb, id)[("figure", 2)]).page == 1
        @test K.page_image(kb, id, 2)[2:4] == b"PNG"
        @test_throws "no page 9" K.page_image(kb, id, 9)
        data = K.paper_json(K.site_paper(kb, id; related = false))
        @test (data["figures"], data["tables"]) == (2, 3) && !occursin("fig-1.webp", K.JSON.json(data))   # the images on demand
        site = mktempdir()
        @test isempty(K.site_figures!(kb, joinpath(site, "figures"), Set{String}())) && !isdir(joinpath(site, "figures"))
        # A day from before every figure was cut: its picks' files in the day's folder, brought over once.
        K.execute!(kb, "DELETE FROM kv WHERE key = 'daily_figures_swept'")
        old = mkpath(joinpath(kb.config.data_dir, "daily", "2026-10-01"))
        write(joinpath(old, "$slug-1.png"), "old cut")
        K.execute!(kb, "INSERT INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at) VALUES ('2026-10-01', ?, 'library', 'Why.', 'done', 'Text.', ?, '{}', ?)",
                   (id, K.JSON.json([Dict("label" => "Figure 1", "why" => "Blue.", "file" => "$slug-1.png")]), K.now_iso()))
        job = K.start_figure_sweep(kb)
        timedwait(() -> job.finished !== nothing, 60)
        @test job.status == :done && isempty(readdir(old)) && K.start_figure_sweep(kb) === nothing
        d = only(dailies(kb))
        @test only(d.figures)["file"] == "fig-1.webp" && [g["file"] for g in d.gallery] == files
        built = K.site_figures!(kb, joinpath(site, "figures"), Set{String}())[id]["fig-1.webp"]     # a day's pick is built in
        @test built["width"] == K.image_size(joinpath(folder, "fig-1.webp"))[1] ÷ 2 && built["dark"] == "fig-1-dark.webp"
        @test isfile(joinpath(site, "figures", slug, "fig-1-dark.webp"))
        day = Dict(K.daily_pages(kb, dailies(kb)).data)["2026-10-01/index"]
        @test day["gallery"] == Dict("figures" => 2, "tables" => 3, "discussed" => ["fig-1.webp"]) && only(day["figures"])["file"] == "fig-1.webp"
        @test only(K.daily_figures(kb, "2026-10-01")).type == "image/webp"
        @test occursin("## Its other figures\n\n- Figure 2: Figure 2: A red box", K.format_daily(kb)) && occursin("- Table II: TABLE II.", K.format_daily(kb))
        # Figures cut before they were WebP: the sweep converts the PNG images, without cutting them again,
        # and the records and the day's picks name the WebP images.
        for f in files
            png = replace(f, ".webp" => ".png")
            K.save_image(joinpath(folder, png), K.load_image(joinpath(folder, f)))
            K.execute!(kb, "UPDATE figures SET file = ? WHERE file = ?", (png, f))
        end
        K.execute!(kb, "UPDATE daily SET figures = replace(figures, '.webp', '.png')")
        foreach(f -> rm(joinpath(folder, f)), filter(f -> !endswith(f, ".png"), readdir(folder)))
        @test endswith(K.figure_file(kb, slug, "fig-1.png"; theme = "dark"), "fig-1-dark.png")   # its copy for the other theme, as PNG
        K.execute!(kb, "UPDATE figure_cuts SET at = (SELECT parsed_at FROM parses x WHERE x.paper_id = figure_cuts.paper_id)")
        before = K.fingerprints(kb, [id])[id]
        @test K.png_figure_papers(kb) == [id]
        job = K.start_figure_sweep(kb)
        timedwait(() -> job.finished !== nothing, 60)
        @test job.status == :done && K.start_figure_sweep(kb) === nothing
        @test [f.file for f in K.paper_figures(kb, id)] == files && sort(readdir(folder)) == files
        @test only(only(dailies(kb)).figures)["file"] == "fig-1.webp"
        @test K.query(kb, "SELECT file_sha FROM figure_cuts") == K.query(kb, "SELECT file_sha FROM parses")   # not cut again
        @test K.fingerprints(kb, [id])[id] != before                    # cut here, its data changed: to publish again
        # A paper read again (by a newer parser, say) has its figures cut again from the new reading.
        K.execute!(kb, "UPDATE figure_cuts SET at = '2000-01-01T00:00:00Z'")
        @test !K.figures_cut(kb, id) && any(r -> r.id == id, K.query(kb, K.uncut_sql()))
        job = K.start_figure_sweep(kb)
        timedwait(() -> job.finished !== nothing, 60)
        @test job.status == :done && K.figures_cut(kb, id) && length(K.paper_figures(kb, id)) == 5 && K.start_figure_sweep(kb) === nothing
        # A read paper whose figures were never cut has them cut once, by the sweep.
        K.execute!(kb, "DELETE FROM figure_cuts")
        K.execute!(kb, "DELETE FROM figures")
        job = K.start_figure_sweep(kb)
        timedwait(() -> job.finished !== nothing, 60)
        @test job.status == :done && length(K.paper_figures(kb, id)) == 5 && K.start_figure_sweep(kb) === nothing
        K.remove_paper!(kb, id)
        @test !isdir(folder) && isempty(K.query(kb, "SELECT * FROM figures"))
    finally
        K.UPLOAD_LOOKUP[] = saved
        close(kb)
    end
end

@zset "a paper's PDF through the API" begin
    kb = open_kb(temp_config(layers = Layer[]))
    record(id; version = missing) = K.execute!(kb, "INSERT INTO papers (doc_id, version, title, added_at) VALUES (?, ?, ?, ?)",
                                               (id, version, "Reef patches", K.now_iso()))
    get(target) = K.respond_local(kb, K.HTTP.Request("GET", target))
    # An upload read here: its file, inline.
    record("doc-0123456789")
    path = joinpath(K.pdf_dir(kb.config), K.pdf_filename("doc-0123456789", ""))
    write(path, "%PDF-1.4 uploaded")
    K.execute!(kb, "INSERT INTO files VALUES (?, ?, 'x', 17, ?)", (K.paper_id(kb, "doc-0123456789"), path, K.now_iso()))
    r = get("/api/pdf/doc-0123456789")
    @test r.status == 200 && String(r.body) == "%PDF-1.4 uploaded"
    @test K.HTTP.header(r, "Content-Type") == "application/pdf" && startswith(K.HTTP.header(r, "Content-Disposition"), "inline")
    # An upload whose PDF is elsewhere, a paper not here, a codebase: none.
    record("doc-abcdefabcd")
    r = get("/api/pdf/doc-abcdefabcd")
    @test r.status == 404 && occursin("uploaded to another knowledge base", K.JSON.parse(String(r.body))["error"])
    @test get("/api/pdf/2609.09999").status == 404
    record("code-reefs")
    @test get("/api/pdf/code-reefs").status == 404

    # An arXiv paper imported from another member's stream, read there: its PDF is fetched from arXiv
    # once and kept, and the paper stays as it was imported (not its own to publish, its figures not cut here).
    id = "2609.00002"
    record(id; version = "v2")
    pid = K.paper_id(kb, id)
    K.execute!(kb, "INSERT INTO parses VALUES (?, 'sha-there', ?, 3, ?)", (pid, K.PARSER_VERSION, K.now_iso()))
    K.execute!(kb, "INSERT INTO dataset_docs (doc_id, hash, imported_at, stream, fingerprint) VALUES (?, 'h', ?, 'ada-reefs', ?)",
               (id, K.now_iso(), K.fingerprints(kb, [id]; record = false)[id]))
    port = 18000 + rand(0:999)
    asked = String[]
    server = K.HTTP.serve!("127.0.0.1", port) do req
        push!(asked, req.target)
        req.target == "/$(id)v2" ? K.HTTP.Response(200, "%PDF-1.5 from arXiv") : K.HTTP.Response(404, "no")
    end
    saved = K.ARXIV_PDF[]
    K.ARXIV_PDF[] = "http://127.0.0.1:$port"
    try
        r = get("/api/pdf/$id")
        @test r.status == 200 && String(r.body) == "%PDF-1.5 from arXiv" && asked == ["/$(id)v2"]
        @test get("/api/pdf/$id").status == 200 && length(asked) == 1
        @test K.scalar(kb, "SELECT count(*) FROM files WHERE paper_id = ?", (pid,)) == 0
        @test isempty(K.own_documents(kb, [id])) && !any(r -> r.id == id, K.query(kb, K.uncut_sql()))
        # Reading it here later takes the file kept.
        @test K.fetch_pdf!(kb, id) == K.paper_pdf(kb, id) && length(asked) == 1
        # arXiv without it: the reason, not a PDF.
        record("2609.00003"; version = "v1")
        r = get("/api/pdf/2609.00003")
        @test r.status == 502 && occursin("arXiv answered HTTP 404", K.JSON.parse(String(r.body))["error"])
    finally
        K.ARXIV_PDF[] = saved
        close(server)
        close(kb)
    end
end

@zset "a folder dataset leaves out hidden files" begin
    # A dataset unpacked from an archive made on a Mac carries `._` files beside each file.
    store = K.DirStore(mktempdir())
    K.write_object!(store, "streams/demo.json", Vector{UInt8}("{\"documents\": {}}"))
    write(joinpath(store.dir, "streams", "._demo.json"), "\0\x05\x16\aMac OS X")
    write(joinpath(store.dir, ".DS_Store"), "x")
    mkpath(joinpath(store.dir, ".hidden")); write(joinpath(store.dir, ".hidden", "x.json"), "x")
    @test K.list_objects(store, "") == ["streams/demo.json"]
    @test collect(keys(K.read_streams(store))) == ["demo"]
end

@zset "Qdrant's API key" begin
    # A Qdrant that takes only its key, as the one Kaimon runs does.
    port = 19000 + rand(0:999)
    server = K.HTTP.serve!("127.0.0.1", port) do req
        K.HTTP.header(req, "api-key", "") == "s3cret" ? K.HTTP.Response(200, """{"result": {"collections": [{"name": "zemi_t"}]}, "status": "ok"}""") :
                                                       K.HTTP.Response(401, "Must provide an API key")
    end
    saved = qdrant_state()
    try
        K.Qdrant.use!("http://127.0.0.1:$port", "s3cret")
        @test K.Qdrant.ping() && K.Qdrant.list_collections() == ["zemi_t"]
        K.Qdrant.use!("http://127.0.0.1:$port")
        @test !K.Qdrant.ping()
        # The config names a Qdrant and the file its key is in; the client asks the config again as it goes.
        dir = mktempdir()
        write(joinpath(dir, "qdrant_key"), "s3cret\n")
        c = temp_config(; qdrant_url = "http://127.0.0.1:$port/", qdrant_key = "file:" * joinpath(dir, "qdrant_key"))
        @test K.qdrant_endpoint(c) == ("http://127.0.0.1:$port/", "s3cret")
        K.Qdrant.use!(() -> K.qdrant_endpoint(c))
        @test K.Qdrant.url() == "http://127.0.0.1:$port" && K.Qdrant.ping()
        @test K.same_qdrant("http://localhost:6333/", "http://127.0.0.1:6333")
    finally
        restore_qdrant!(saved)
        close(server)
    end
end

@zset "request bodies" begin
    req = K.HTTP.Request("POST", "/x", [], Vector{UInt8}("""{"a": 1}"""))
    @test K.json_body(req) == Dict("a" => 1) && K.json_body(req) == Dict("a" => 1)     # read twice, it is still there
    @test K.json_body(K.HTTP.Request("POST", "/x", [], UInt8[])) == Dict{String,Any}()
    form = K.HTTP.Request("POST", "/x", [], Vector{UInt8}("url=https%3A%2F%2Fexample.org&name=Bea"))
    @test K.form_body(form) == Dict("url" => "https://example.org", "name" => "Bea") && K.body_bytes(form) == Vector{UInt8}("url=https%3A%2F%2Fexample.org&name=Bea")
end

@zset "request times" begin
    saved = copy(K.METRICS)
    empty!(K.METRICS)
    try
        route(method, target) = K.metric_route(K.HTTP.Request(method, target), filter(!isempty, split(target, '/')))
        # Each request under the pattern it matched; long polls marked; the rest under their first parts.
        @test route("GET", "/api/tasks/EHS-12") == ("GET /api/tasks/:task", false)
        @test route("GET", "/api/tasks/changes") == ("GET /api/tasks/changes", true)
        @test route("GET", "/api/presence") == ("GET /api/presence", true) && route("POST", "/api/presence") == ("POST /api/presence", false)
        @test route("GET", "/api/nowhere/at/all") == ("GET /api/nowhere", false)
        @test route("GET", "/auth/sign-in") == ("GET /auth/sign-in", false) && route("GET", "/generated/kb/papers") == ("site", false)
        # A route's first requests compile what they run, so they are counted but not timed.
        foreach(s -> K.record!("GET /api/x", 200, s), (5.0, 4.0, 0.010, 0.020, 0.030))
        K.record!("GET /api/x", 500, 0.040)
        x = only(m for m in K.metrics_json() if m["route"] == "GET /api/x")
        @test (x["count"], x["errors"], x["mean_ms"], x["p95_ms"], x["max_ms"]) == (6, 1, 25.0, 40.0, 40.0)
        foreach(_ -> K.record!("GET /api/w", 200, 25.0; waits = true), 1:3)
        K.record!("GET /api/y", 200, 0.001)
        @test [m["route"] for m in K.metrics_json()] == ["GET /api/x", "GET /api/y", "GET /api/w"]   # long polls last
        @test only(m for m in K.metrics_json() if m["route"] == "GET /api/y")["mean_ms"] === nothing
        # The latest times are kept for the percentile, the oldest given up.
        foreach(i -> K.record!("GET /api/z", 200, i / 1000), 1:1102)
        z = K.METRICS["GET /api/z"]
        @test length(z.recent) == K.METRIC_RECENT && minimum(z.recent) == 0.103 && K.percentile(z, 0.95) == 1.052
    finally
        empty!(K.METRICS)
        merge!(K.METRICS, saved)
    end
end

@zset "routes" begin
    # A literal part wins over a named one; `*paper` takes the rest of the path, slashes and all.
    r, path = K.find_route("GET", ["api", "tasks", "search"])
    @test r.pattern == "/api/tasks/search" && isempty(path)
    r, path = K.find_route("GET", ["api", "tasks", "KB-12"])
    @test r.pattern == "/api/tasks/:task" && path[:task] == "KB-12" && r.project == K.VIEW
    r, path = K.find_route("GET", ["api", "paper", "hep-th", "9901001"])
    @test r.pattern == "/api/paper/*paper" && path[:paper] == "hep-th/9901001"
    @test K.find_route("GET", ["api", "paper"]) === nothing
    @test K.find_route("DELETE", ["api", "tasks", "KB-12"]) === nothing
    # Declaring a route again, as Revise does, replaces it.
    n = length(K.ROUTES[])
    try
        K.route!(c -> 1, "GET", "/api/zz-test/:key"; project = K.VIEW)
        K.route!(c -> 2, "GET", "/api/zz-test/:key"; project = K.VIEW)
        @test length(K.ROUTES[]) == n + 1 && K.find_route("GET", ["api", "zz-test", "A"])[1].f(nothing) == 2
    finally
        K.ROUTES[] = filter(r -> r.pattern != "/api/zz-test/:key", K.ROUTES[])
    end
    # A route needing project access names the project.
    @test_throws ErrorException K.route!(c -> 1, "GET", "/api/zz-test"; project = K.VIEW)

    kb = open_kb(temp_config())
    try
        call(method, target) = (r = K.handle(kb, K.HTTP.Request(method, target)); (r.status, K.JSON.parse(String(r.body))))
        @test call("GET", "/api/zz-nothing")[1] == 404
        @test call("DELETE", "/api/status")[1] == 405
        # A task of a project that does not exist, or a reference that is no task's, is not found.
        @test call("GET", "/api/tasks/ZZ-1") == (404, Dict("error" => "No task ZZ-1"))
        @test call("GET", "/api/tasks/nonsense")[1] == 404
    finally
        close(kb)
    end
end

@zset "the codebases page" begin
    # It offers adding one, with or without any there yet.
    kb = open_kb(temp_config())
    try
        dir, public = mktempdir(), mktempdir()
        @test isempty(K.write_code_site(kb, dir, public))
        page = read(joinpath(dir, "index.md"), String)
        @test occursin("<KBCodebases none />", page) && occursin("<KBUpload codebases />", page)
        # An open codebase's page and each of its files' are made from their templates and data files.
        # One open only to its projects' members is not built into the site, which every reader is served.
        reef, tide = mktempdir(), mktempdir()
        write(mkpath(joinpath(reef, "src")) * "/Reef.jl", "\"Grow the reef.\"\ngrow(x) = x + 1\n")
        write(joinpath(tide, "tide.jl"), "tide(t) = sin(t)\n")
        open_id, closed_id = K.add_codebase!(kb, reef; name = "Reef"), K.add_codebase!(kb, tide; name = "Tide")
        K.parse_code!(kb, open_id); K.parse_code!(kb, closed_id)
        K.set_document_access!(kb, closed_id, "projects")
        site, public = mktempdir(), mktempdir()
        in_site(path...) = joinpath(site, "code", path...)
        in_public(path...) = joinpath(public, path...)
        write(K.landscape_path(kb.config), K.JSON.json(Dict("papers" => [Dict("id" => open_id), Dict("id" => closed_id)], "clusters" => [])))
        nav = write_site(kb, site, public; related = false)
        @test nav.code == ["Reef" => "code/code-reef/index.md"]
        @test read(in_site("code-reef", "index.md"), String) == K.template_markdown("codebase") &&
              read(in_site("code-reef", "files", "src_Reef_jl.md"), String) == K.template_markdown("code")
        page = K.JSON.parsefile(in_public("kb-data", "codebase", "code-reef", "index.json"))
        @test page["title"] == "Reef" && page["files"] == 1 && page["access"] == "open" &&
              page["tree"] == "/code/code-reef.json" && page["pages"] == "/generated/kb/code/code-reef/files/"
        @test K.JSON.parsefile(in_public("code", "code-reef.json"))["id"] == open_id &&
              K.JSON.parsefile(in_public("kb-data", "code", "code-reef", "src_Reef_jl.json"))["path"] == "src/Reef.jl"
        @test !ispath(in_site("code-tide")) && !ispath(in_public("code", "code-tide.json")) &&
              !ispath(in_public("kb-data", "codebase", "code-tide")) && !ispath(in_public("kb-data", "code", "code-tide"))
        listing = read(in_site("index.md"), String)
        @test occursin("[Reef](./code-reef/index.md)", listing) && !occursin("Tide", listing) &&
              occursin("<KBCodebases />", listing) && occursin("<KBUpload codebases manage />", listing)
        @test [p["id"] for p in K.JSON.parsefile(in_public("landscape.json"))["papers"]] == [open_id]
        # Closed after the site was written, it leaves the site as the site is written again.
        K.set_document_access!(kb, open_id, "projects")
        write_site(kb, site, public; related = false)
        @test !ispath(in_site("code-reef", "index.md")) && !ispath(in_public("code", "code-reef.json")) &&
              !ispath(in_public("kb-data", "codebase", "code-reef", "index.json"))
    finally
        close(kb)
    end
end

@zset "uploaded PDF, site and API" begin
    # A request refused with a reason is a warning in the log; any other failure, an error.
    req = K.HTTP.Request("POST", "/api/projects")
    @test_logs (:warn, "API request refused: A project's key is already TP") K.log_failure(req, ErrorException("A project's key is already TP"), [])
    @test_logs (:error, "API request failed") K.log_failure(req, BoundsError([1], 2), [])
    # The person is told the reason for a refusal, and of anything else only that it went wrong.
    @test K.client_message(ErrorException("No project ZZ")) == "No project ZZ"
    @test K.client_message(K.Refusal(404, "No task ZZ-1")) == "No task ZZ-1"
    # The status says why: none of that name, not permitted, not as asked, or the service's own failure.
    @test K.error_status.([K.Refusal(404, ""), K.Refusal(403, ""), ErrorException(""), BoundsError([1], 2)]) == [404, 403, 400, 500]
    @test !occursin("/", K.client_message(SystemError("opening /home/svc/.config/x", 2)))
    dir = mktempdir()
    pdf = joinpath(dir, "upload.pdf")
    write(joinpath(dir, "page.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 24 Tf 72 700 Td (A Test Paper Title) Tj ET
        BT /F1 10 Tf 72 650 Td (Abstract. We check that uploaded papers join the knowledge base.) Tj ET
        BT /F1 10 Tf 72 620 Td (Coral polyps are fed by algae living in their tissue.) Tj ET
        BT /F1 10 Tf 72 606 Td (The reef crest breaks the force of storm waves.) Tj ET
        """)
    run(`mutool create -o $pdf $(joinpath(dir, "page.txt"))`)
    # A stand-in summarizer, so reading the upload summarizes and classifies it the same everywhere.
    port = 18000 + rand(0:999)
    stand_in = K.HTTP.serve!("127.0.0.1", port) do req
        content = K.JSON.parse(String(req.body))["messages"][end]["content"]
        prompt = content isa String ? content : join((p["text"] for p in content if p["type"] == "text"), "\n")
        reply = occursin("\"document_type\"", prompt) ? """{"document_type": "journal article", "relevance": 1, "one_line": "It checks."}""" :
                occursin("Section summaries:", prompt) ? "Paper summary.\nTopics: checks" : "Summary of a section."
        K.HTTP.Response(200, K.JSON.json(Dict("choices" => [Dict("message" => Dict("content" => reply))],
                                              "usage" => Dict("prompt_tokens" => 10, "completion_tokens" => 5))))
    end
    kb = open_kb(temp_config(layers = Layer[], summarizers = [Summarizer(; name = "stand-in", url = "http://127.0.0.1:$port", model = "m")],
                             summarizer = "stand-in", code_summarizer = "stand-in", judge = "stand-in"))
    K._KB[] = kb
    try
        id = add_pdf!(kb, pdf; added_by = "Ada")
        @test startswith(id, "doc-") && add_pdf!(kb, pdf) == id    # the same file is the same paper
        p = K.paper_row(kb, id)
        @test p.title == "A Test Paper Title" && startswith(p.abstract, "We check")
        r = only(ingest!(kb, [id]))
        @test r.ok && r.parsed
        @test only(mentions(kb, id)).author == "Ada"
        # Described with a date but without arXiv's other metadata, and without an arXiv link.
        K.execute!(kb, """UPDATE papers SET published = '2026-09-01', updated = NULL, primary_category = NULL,
                          categories = NULL, version = NULL WHERE doc_id = ?""", (id,))
        text = K.format_paper(kb, id)
        @test occursin("Published 2026-09-01\n", text) && !occursin("arxiv.org", text)
        @test_throws ErrorException add_pdf!(kb, joinpath(dir, "page.txt"))
        @test_throws K.Refusal add_papers!(kb, ["doc-0000000000"])

        # Every paper's arrival is recorded, once: how it came, and who added it where known.
        add_papers!(kb, ["2609.00001"]; source = "watch", by = "Bea")
        add_papers!(kb, ["2609.00001"])
        @test [(m.source, m.author) for m in mentions(kb, "2609.00001")] == [("watch", "Bea")]
        @test occursin("https://arxiv.org/abs/2609.00001", K.format_paper(kb, "2609.00001"))
        @test_throws ErrorException add_papers!(kb, ["2609.00002"]; source = "elsewhere")

        # The site: a page per paper, index pages and the search data.
        K.execute!(kb, "UPDATE papers SET title = 'An arXiv paper', abstract = ?, metadata_at = 'x', primary_category = 'physics.ao-ph' WHERE doc_id = '2609.00001'",
                   ("Uses \$\\beta\$ and *stars*.",))
        site, public = joinpath(dir, "site"), joinpath(dir, "public")
        nav = write_site(kb, site, public; related = false)
        @test nav.papers == 2 && nav.topics == ["Atmospheric and oceanic physics" => "topics/physics-ao-ph.md"]
        upload_page = K.JSON.parsefile(joinpath(public, "kb-data", "papers", K.page_slug(id) * ".json"))
        @test upload_page["local"] && [(p["where"], p["author"]) for p in upload_page["posts"]] == [("Uploaded", "Ada")]
        # The lists of papers are drawn from papers.json: how each came, and each topic's page from its data file.
        @test occursin("<KBPaperList by=\"month\" />", read(joinpath(site, nav.timeline), String))
        listed = Dict(r["id"] => r for r in K.JSON.parsefile(joinpath(public, "papers.json")))
        @test startswith(only(listed[id]["arrivals"])["text"], "uploaded by Ada") &&
              startswith(only(listed["2609.00001"]["arrivals"])["text"], "added from the arXiv watch by Bea")
        @test listed["2609.00001"]["category_title"] == "Atmospheric and oceanic physics"
        @test K.JSON.parsefile(joinpath(public, "kb-data", "topics", "physics-ao-ph.json"))["title"] == "Atmospheric and oceanic physics"
        @test read(joinpath(site, "topics", "physics-ao-ph.md"), String) == K.template_markdown("topics")
        arxiv_page = K.JSON.parsefile(joinpath(public, "kb-data", "papers", "2609-00001.json"))
        @test arxiv_page["abstract"] == "Uses \$\\beta\$ and *stars*." && !arxiv_page["local"]   # as stored, for the page to render
        @test occursin("<KBSearch", read(joinpath(site, "index.md"), String))
        @test occursin("<KBStatusTables />", read(joinpath(site, nav.status), String))
        contents = K.JSON.parsefile(joinpath(public, "status.json"))
        @test contents["papers"]["recorded"] == 2 && contents["papers"]["uploaded"] == 1
        @test Dict("who" => "Ada", "papers" => 1) in contents["shared_by"]
        records = K.JSON.parsefile(joinpath(public, "papers.json"))
        @test Set(r["id"] for r in records) == Set([id, "2609.00001"])
        mtime0 = mtime(joinpath(site, "index.md"))
        write_site(kb, site, public; related = false)
        @test mtime(joinpath(site, "index.md")) == mtime0            # unchanged pages are not rewritten
        # A paper's page is a stub for the build, its content a data file; the template is built once.
        @test read(joinpath(site, "papers", "2609-00001.md"), String) == K.template_markdown("papers") ==
              read(joinpath(site, "templates", "paper.md"), String)
        @test K.JSON.parsefile(joinpath(public, "kb-data", "papers", "2609-00001.json"))["title"] == "An arXiv paper"

        # In the built site, a copy of the built template for each data file, and none left for one gone.
        built = mktempdir()
        tpl(path...) = joinpath(built, "generated", "kb", path...)
        write(mkpath(tpl("templates")) * "/paper.html", "<p>template</p>")
        assets(f) = joinpath(mkpath(joinpath(built, "assets")), f)
        write(assets("generated_kb_templates_paper.md.H1.js"), "script"); write(assets("generated_kb_templates_paper.md.H1.lean.js"), "lean")
        write(assets("generated_kb_templates_paper.md.H1.lean.js"), "lean {\"relativePath\":\"generated/kb/templates/paper.md\"}")
        foreach(s -> write(joinpath(mkpath(joinpath(built, "kb-data", "papers")), s * ".json"), "{}"), ("a-1", "b-2"))
        write(joinpath(mkpath(tpl("papers", "a-1")), "nb.html"), "a notebook's page")
        @test K.stamp_templates!(built) == 2 && read(tpl("papers", "b-2.html"), String) == "<p>template</p>"
        # Each copy's script names its own page, whose address VitePress then keeps.
        @test read(assets("generated_kb_papers_b-2.md.H1.$(K.TEMPLATE_COPY).js"), String) == "script" &&
              read(assets("generated_kb_papers_b-2.md.H1.$(K.TEMPLATE_COPY).lean.js"), String) == "lean {\"relativePath\":\"generated/kb/papers/b-2.md\"}"
        @test K.stamp_templates!(built) == 0
        rm(joinpath(built, "kb-data", "papers", "b-2.json"))
        write(tpl("papers", "built.html"), "a page built for itself")
        K.stamp_templates!(built)
        @test !isfile(tpl("papers", "b-2.html")) && isfile(tpl("papers", "a-1.html")) && isfile(tpl("papers", "built.html"))
        @test !isfile(assets("generated_kb_papers_b-2.md.H1.$(K.TEMPLATE_COPY).js")) && isfile(assets("generated_kb_papers_a-1.md.H1.$(K.TEMPLATE_COPY).js"))
        @test isfile(tpl("papers", "a-1", "nb.html"))

        # The site served takes the knowledge base's changes without a build: data files and pages.
        @test K.refresh_site!(kb.config) === nothing                       # none served yet
        K.build_site!(kb.config; build = (out, log) -> begin
            write(mkpath(joinpath(out, "1")) * "/index.html", "home")
            write(mkpath(joinpath(out, "1", "generated", "kb", "templates")) * "/paper.html", "<p>template</p>")
        end)
        served = K.current_site(kb.config)
        @test K.refresh_site!(kb.config) >= 0 && read(joinpath(served, "generated", "kb", "papers", "2609-00001.html"), String) == "<p>template</p>"
        @test K.JSON.parsefile(joinpath(served, "kb-data", "papers", "2609-00001.json"))["title"] == "An arXiv paper"
        @test K.site_file(kb.config, "/generated/kb/papers/not-copied-yet.html") == joinpath(served, "generated", "kb", "templates", "paper.html")
        # A paper changed changes no page the build compiles, so the refresh asks for no build.
        built = read(joinpath(served, K.BUILT_PAGES_FILE), String)
        K.execute!(kb, "UPDATE papers SET title = 'Retitled' WHERE doc_id = '2609.00001'")
        K.refresh_site!(kb.config)
        @test K.JSON.parsefile(joinpath(served, "kb-data", "papers", "2609-00001.json"))["title"] == "Retitled"
        @test read(joinpath(served, K.BUILT_PAGES_FILE), String) == built && !K.SITE.building
        K.execute!(kb, "UPDATE papers SET title = 'An arXiv paper' WHERE doc_id = '2609.00001'")

        # The API, keyword search only here since no layer is embedded.
        get(target) = (r = K.respond_local(kb, K.HTTP.Request("GET", target)); (r.status, K.JSON.parse(String(r.body))))
        status, body = get("/api/status")
        @test status == 200 && body["papers"] == 2 && body["processed"] == 1
        status, body = get("/api/search?q=reef+crest")
        @test status == 200 && body["hits"][1]["id"] == id && body["findings"] == []
        top = body["hits"][1]
        @test only(top["evidence"])["ranking"] == "keyword" && only(top["evidence"])["rank"] == 1
        @test top["score"] ≈ top["max_score"]                  # first in the only ranking there is
        @test startswith(top["passages"][1]["evidence"][1]["matched"], "passage ")
        @test get("/api/search")[1] == 400
        @test get("/api/status")[2]["keyword"]["default"] == true
        # A site build running, and for how long, for the top bar.
        @test get("/api/status")[2]["building"] === nothing
        lock(() -> (K.SITE.building = true; K.SITE.started = K.Dates.now() - K.Dates.Second(90)), K.SITE_LOCK)
        @test get("/api/status")[2]["building"] in 89:92
        lock(() -> (K.SITE.building = false; K.SITE.started = nothing), K.SITE_LOCK)
        @test isempty(get("/api/search?q=reef+crest&keyword=0&layers=none")[2]["hits"])          # nothing left to search with
        @test get("/api/paper/$id")[2]["title"] == "A Test Paper Title"
        # The published record, once found, replaces what was read from the PDF, and its own abstract
        # stays; a title someone typed is kept. A paper is looked for once unless asked again.
        rec = (; title = "A Test Paper, as Published", authors = ["A. Author"], year = "2020",
               journal_ref = "J. Tests 1, 2 (2020)", doi = "10.1234/t", abstract = "Published abstract.")
        heal(; force = true) = K.heal_upload!(kb, id; force, lookup = (p; contact = "") -> rec)
        @test !heal(force = false)                                       # looked for when it was added
        @test heal() && K.paper_row(kb, id).title == rec.title && K.paper_row(kb, id).doi == "10.1234/t"
        @test K.paper_row(kb, id).journal_ref == rec.journal_ref && startswith(K.paper_row(kb, id).abstract, "We check")
        K.execute!(kb, "UPDATE papers SET title = 'My name for it' WHERE doc_id = ?", (id,))
        @test heal() && K.paper_row(kb, id).title == "My name for it"
        # A journal's name taken for the title is replaced, as no one's typed title; such uploads are looked up again.
        K.execute!(kb, "UPDATE papers SET title = 'J. Tests', looked_up_at = '2026-01-01' WHERE doc_id = ?", (id,))
        @test K.heal_upload!(kb, id; force = true, lookup = (p; contact = "") -> merge(rec, (; journal = "J. Tests"))) &&
              K.paper_row(kb, id).title == rec.title
        K.execute!(kb, "UPDATE papers SET title = 'A Test Paper Title' WHERE doc_id = ?", (id,))
        @test get("/api/paper/2609.99999")[1] == 404
        @test get("/api/nothing")[1] == 404
        @test get("/api/missing") == (200, [])          # nothing cited and lacking here
        # The upload was classified as it was read; without that, sync lists it to classify.
        @test classification(kb, id) !== nothing
        K.execute!(kb, "DELETE FROM classifications")
        plan = get("/api/sync")[2]                  # the upload is read but not classified; the arXiv paper is unread
        @test plan["unread"] == 1 && plan["job"] === nothing
        @test only(plan["tasks"])["action"] == "classify" && only(plan["tasks"])["page"] == "papers/$id"
        # Syncing, adding and the sources are on the Documents page; the Status page shows what the knowledge base holds.
        docs_page, status_page = read(joinpath(site, nav.manage), String), read(joinpath(site, nav.status), String)
        @test all(c -> occursin(c, docs_page), ("<KBSync", "<KBUpload", "<KBManager", "<KBSources"))
        @test occursin("<KBServices", status_page) && !occursin("<KBSync", status_page)

        # Managing documents: listing, and changes only from this machine's pages with the header.
        listing = get("/api/documents?q=test+paper")[2]
        @test listing["total"] == 1 && listing["documents"][1]["id"] == id && listing["documents"][1]["parsed"]
        @test get("/api/documents?state=recorded")[2]["documents"][1]["id"] == "2609.00001"
        @test get("/api/documents?state=uploaded")[2]["total"] == 1
        post(target, body; headers = ["X-Zemi" => "1", "Content-Type" => "application/json"]) =
            (r = K.respond_local(kb, K.HTTP.Request("POST", target, headers, body)); (r.status, K.JSON.parse(String(r.body))))
        remove = K.JSON.json(Dict("action" => "drop", "ids" => ["2609.00001"]))
        @test post("/api/actions", remove; headers = ["Content-Type" => "application/json"])[1] == 403
        @test post("/api/actions", remove; headers = ["X-Zemi" => "1", "Origin" => "https://example.com"])[1] == 403
        @test post("/api/actions", K.JSON.json(Dict("action" => "explode", "ids" => [id])))[1] == 400
        function finished(job)
            for _ in 1:600
                j = K.get_job(job)
                j.status == :running || return j
                sleep(0.05)
            end
            error("job $job did not finish")
        end
        status, body = post("/api/actions", remove)
        @test status == 200 && finished(body["job"]).status == :done
        @test ismissing(K.paper_id(kb, "2609.00001"))
        status, body = post("/api/documents", read(pdf); headers = ["X-Zemi" => "1", "Content-Type" => "application/pdf"])
        @test status == 200 && body["ids"] == [id] && finished(body["job"]).status == :done
        job = get("/api/jobs/$(body["job"])")[2]
        @test job["result"] isa String && job["ids"] == [id]

        # A refresh of the documents changed writes what a whole one would.
        part, whole = (mktempdir(), mktempdir()), (mktempdir(), mktempdir())
        write_site(kb, part...)
        add_papers!(kb, ["2609.00004"]; by = "Bea")
        K.execute!(kb, "UPDATE papers SET title = 'A fourth', metadata_at = 'x', primary_category = 'physics.comp-ph' WHERE doc_id = '2609.00004'")
        K.execute!(kb, "UPDATE papers SET title = 'Renamed' WHERE doc_id = ?", (id,))
        @test K.write_site_changes!(kb, part..., ["2609.00004", id]) == 2
        write_site(kb, whole...)
        json(root, path...) = K.JSON.parsefile(joinpath(root, path...))
        for f in ("2609-00004.json", K.page_slug(id) * ".json")
            @test json(part[2], "kb-data", "papers", f) == json(whole[2], "kb-data", "papers", f)
        end
        @test json(part[2], "papers.json") == json(whole[2], "papers.json")
        @test Set(readdir(joinpath(part[2], "kb-data", "topics"))) == Set(readdir(joinpath(whole[2], "kb-data", "topics"))) ∋ "physics-comp-ph.json"
        @test delete!(json(part[2], "status.json"), "at") == delete!(json(whole[2], "status.json"), "at")
        @test read(joinpath(part[2], K.BUILT_PAGES_FILE), String) == read(joinpath(whole[2], K.BUILT_PAGES_FILE), String)
        # A paper removed takes its files and its topic with it; a codebase changed needs the whole site.
        K.remove_paper!(kb, "2609.00004")
        K.write_site_changes!(kb, part..., ["2609.00004"])
        @test !isfile(joinpath(part[2], "kb-data", "papers", "2609-00004.json")) && !isfile(joinpath(part[2], "kb-data", "topics", "physics-comp-ph.json"))
        @test !any(r -> r["id"] == "2609.00004", json(part[2], "papers.json"))
        @test K.write_site_changes!(kb, part..., ["code-demo"]) === nothing
        # Jobs note what they changed; a change naming nothing is a change to everything.
        K.take_changes!()
        K.note_changes!(["a"]); K.note_changes!(["b"])
        @test K.take_changes!() == Set(["a", "b"])
        K.note_changes!(["a"]); K.note_changes!(String[]); K.note_changes!(["b"])
        @test K.take_changes!() === nothing
    finally
        K.shutdown()
        close(stand_in)
    end
end

@zset "tools" begin
    G = K.kaimon().KaimonGate
    empty!(K.JOBS)
    K.AUTOSYNC[] = false
    tools = create_tools(G.GateTool)
    @test Set(t.name for t in tools) ==
          Set(["search", "paper", "read", "figures", "figure", "page", "references", "similar", "ingest", "add_pdf", "ingest_code", "papers", "records", "status", "daily", "sync", "publish", "job_status",
               "projects", "tasks", "task", "next_task", "plan", "task_update", "task_note", "task_note_edit", "task_diff", "task_link", "project_create", "project_codebase", "library", "library_add", "milestones",
               "milestone_create", "milestone_update", "milestone_activate", "milestone_done", "task_wait", "task_search", "task_match", "task_status", "task_attach", "media_upload",
               "findings", "finding", "finding_draft", "finding_update", "finding_comment", "finding_evidence"])
    # Each says what it needs over /mcp; those that read the service's own disk are offered no one there.
    @test all(t -> t.need === nothing || t.need in K.PERMISSION_NAMES, K.TOOLS[])
    # Each permission is in one group of those the forms choose them by, with what it allows.
    grouped = [p for (_, ps) in K.PERMISSION_GROUPS for p in ps]
    @test sort(grouped) == sort(K.PERMISSION_NAMES)
    @test all(g -> all(p -> !isempty(p["description"]), g["permissions"]), K.permission_groups_json())
    @test [t.name for t in K.TOOLS[] if t.need === nothing] == ["add_pdf", "ingest_code"]
    # What an agent sees: every tool needs a description, and optional parameters must be keywords.
    for t in tools
        meta = G._reflect_tool(t)
        @test length(meta["description"]) > 40
        # Optional positionals bind from the front, so a caller could not skip one.
        @test all(a -> a["required"] || a["is_kwarg"], meta["arguments"])
    end
    search_args = Dict(a["name"] => a for a in G._reflect_tool(only(t for t in tools if t.name == "search"))["arguments"])
    @test search_args["query"]["required"] == true && search_args["limit"]["required"] == false
    K._KB[] = open_kb(temp_config())
    try
        add_papers!(K._KB[], ["2609.00001"])
        tool(name) = only(t for t in tools if t.name == name).handler
        @test occursin("1 recorded", tool("status")())
        @test occursin("2609.00001", tool("papers")())
        @test occursin("not parsed", tool("paper")("2609.00001"))
        @test occursin("No jobs", tool("job_status")())
    finally
        K.shutdown()
    end
end

@zset "a search naming papers by their arXiv ids" begin
    kb = open_kb(temp_config())
    add_papers!(kb, ["2610.00746", "2609.00001"])
    named, rest = K.named_papers(kb, "arXiv:2610.00746v2, hep-th/9901001 and 2609.00001 on reefs")
    @test named == ["2610.00746", "2609.00001"] && strip(replace(rest, r"[\s,]+" => " ")) == "and on reefs"
    @test isempty(first(K.named_papers(kb, "12610.00746 or 2610.007461 or 2601.00001")))   # inside a number, or not here
    # Named papers come first, in the order named, found by their id and as strong as a match can be.
    hits = K.search(kb, "2609.00001 2610.00746")
    @test [h.doc_id for h in hits] == ["2609.00001", "2610.00746"] && all(h -> h.score == h.max_score, hits)
    @test first(first(hits).evidence).ranking == "id" && K.ranking_label(kb.config, "id") == "arXiv id"
    @test first(K.search(kb, "larval transport in 2610.00746"; layers = String[])).doc_id == "2610.00746"
    close(kb)
end

# Needs network access to arXiv plus running Ollama and Qdrant; opt in with ZEMI_INTEGRATION=1.
if get(ENV, "ZEMI_INTEGRATION", "") == "1"
    @testset "end to end" begin
        cfg = temp_config(layers = [Layer(; name = "chunk-test", model = "nomic-embed-text", unit = :chunk,
            query_prefix = "search_query: ", doc_prefix = "search_document: ")])
        kb = open_kb(cfg)
        try
            r = only(ingest!(kb, ["1706.03762"]))
            @test r.ok && r.parsed && r.embedded["chunk-test"] > 10
            @test only(ingest!(kb, ["1706.03762"])).embedded["chunk-test"] == 0
            hits = search(kb, "attention for sequence transduction"; limit = 3)
            @test first(hits).doc_id == "1706.03762" && !isempty(first(hits).passages)
        finally
            drop_layer!(kb, "chunk-test")
            close(kb)
        end
    end
end

@zset "projects and tasks" begin
    kb = open_kb(temp_config())
    me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    saved_user = K.LOCAL_USER[]
    K.LOCAL_USER[] = "Rowan"                                                       # who runs it: the one person work goes to
    root = mktempdir()
    id = K.add_codebase!(kb, root; name = "demo")
    @test K.create_project!(kb, "Demo"; key = "dm", codebase = id, by = me) == "DM"
    @test_throws ErrorException K.create_project!(kb, "Again"; key = "DM", by = me)
    @test_throws ErrorException K.create_project!(kb, "Bad"; key = "9x", by = me)
    # An agent working in the codebase's directory, or below it, finds its project.
    @test [p.key for p in K.projects(kb; path = joinpath(root, "src"))] == ["DM"] && isempty(K.projects(kb; path = tempdir()))
    # Linked to a codebase later, or unlinked, by an agent too; only to a codebase.
    K.update_project!(kb, "DM"; codebase = "none", by = bot)
    @test isempty(K.projects(kb; path = root)) && only(K.projects(kb)).codebase == ""
    @test_throws "No codebase" K.update_project!(kb, "DM"; codebase = "code-missing", by = bot)
    @test_throws "No codebase" K.create_project!(kb, "Paper"; key = "PP", codebase = "2402.00785", by = me)
    K.update_project!(kb, "DM"; codebase = id, by = bot)
    @test [p.key for p in K.projects(kb; path = root)] == ["DM"]
    @test_throws "Only a person" K.update_project!(kb, "DM"; name = "Mine", codebase = id, by = bot)
    K.create_milestone!(kb, "DM", "First"; due = "2026-11-01")
    @test_throws ErrorException K.create_milestone!(kb, "DM", "Bad date"; due = "soon")
    # Changed after it is made: its date, description and name; what is not given stays.
    K.create_project!(kb, "Milestones"; key = "ME", by = me)
    K.create_milestone!(kb, "ME", "Kept")
    K.create_milestone!(kb, "ME", "Later"; description = "After the first.")
    @test K.update_milestone!(kb, "ME", "Later"; due = "2026-12-01") == "Later"
    @test K.update_milestone!(kb, "ME", "Later"; rename = "Second pass") == "Second pass"
    m = only(filter(x -> x.name == "Second pass", K.milestones(kb, "ME")))
    @test (m.due, m.description) == ("2026-12-01", "After the first.")
    K.update_milestone!(kb, "ME", "Second pass"; due = "")
    @test only(filter(x -> x.name == "Second pass", K.milestones(kb, "ME"))).due == ""
    @test_throws "already has a milestone Kept" K.update_milestone!(kb, "ME", "Second pass"; rename = "Kept")
    @test_throws "YYYY-MM-DD" K.update_milestone!(kb, "ME", "Second pass"; due = "soon")
    @test_throws "No milestone Nowhere" K.update_milestone!(kb, "ME", "Nowhere"; due = "2026-12-01")
    K.update_milestone!(kb, "ME", "Second pass"; start = "2026-11-15")
    @test only(filter(x -> x.name == "Second pass", K.milestones(kb, "ME"))).start == "2026-11-15"
    K.update_milestone!(kb, "ME", "Second pass"; rename = "Later")

    # An agent's plan, with its subtasks, waits in Proposed; only a person moves it on, and they go with it.
    ref = K.create_task!(kb, "DM", "Plan the work"; body = "1. a\n2. b", milestone = "First", subtasks = ["Step one", "Step two"], status = "ready", by = bot)
    @test ref == "DM-1" && all(t -> t.status == "proposed", K.tasks(kb; project = "DM"))
    @test_throws ErrorException K.update_task!(kb, ref; status = "in_progress", by = bot)
    K.update_task!(kb, "dm-1"; status = "ready", by = me)
    @test [(t.ref, t.status) for t in K.tasks(kb; project = "DM")] == [("DM-1", "ready"), ("DM-2", "ready"), ("DM-3", "ready")]
    K.update_task!(kb, "DM-1"; status = "in_progress", by = bot)                # approved: the agent moves it along
    @test_throws ErrorException K.update_task!(kb, "DM-1"; status = "proposed", by = bot)
    # Commits against tasks: read from the linked codebase's repository on every branch, by their trailers.
    @test K.commit_tasks("Fix it\n\nWhy.\n\nTasks: DM-1, dm-2 NOPE\nTask: DM-3") == ["DM-1", "DM-2", "DM-3"]
    @test K.commit_tasks("Draw the legend\n\nFixes DM-4 and DM-5, part of DM-1. Unlike DM-9, which was about colour.") ==
          ["DM-4", "DM-5", "DM-1"]                                               # said to be done, not only mentioned
    @test K.commit_tasks("Closed: dm-7; resolves DM-8 & DM-6") == ["DM-7", "DM-8", "DM-6"] && isempty(K.commit_tasks("See DM-3"))
    @test K.commit_tasks("Add the scan\n\nRefs: DM-5, DM-3") == ["DM-5", "DM-3"] && isempty(K.commit_tasks("Refs DM-5 in passing"))
    @test K.commit_relations("Draw it\n\nRefs: DM-5\n\nFixes DM-5 and DM-4, unlike DM-9 on x86-64") ==
          ["DM-5" => "finishes", "DM-4" => "finishes", "DM-9" => "mentions"]  # the strongest, and only task-like mentions
    @test K.iso(K.parse_iso("2026-10-04T14:03:11-07:00")) == "2026-10-04T21:03:11Z" && K.iso(K.parse_iso("2026-10-04T14:03:11Z")) == "2026-10-04T14:03:11Z"
    @test K.read_commits!(kb, id) == 0                                          # not a repository yet
    gitc(args...) = run(pipeline(`git -C $root -c user.name=Ada -c user.email=ada@x.org -c commit.gpgsign=false $args`; stdout = devnull, stderr = devnull))
    gitc("init", "-q", "-b", "main")
    write(joinpath(root, "a.jl"), "f() = 1\n"); gitc("add", "a.jl"); gitc("commit", "-q", "-m", "Add f\n\nTasks: DM-2")
    write(joinpath(root, "b.jl"), "g() = 2\n"); gitc("add", "b.jl"); gitc("commit", "-q", "-m", "Add g, for nothing")
    @test K.read_commits!(kb, id) == 2 && K.read_commits!(kb, id) == 0          # every commit, once
    gitc("checkout", "-q", "-b", "side")
    write(joinpath(root, "a.jl"), "f() = 1\nh() = 3\n"); gitc("commit", "-q", "-am", "Add h\n\nTasks: DM-1, NOPE-9")
    gitc("checkout", "-q", "main")
    @test K.read_all_commits!(kb) == 1                                          # the side branch's commit too
    K.execute!(kb, "UPDATE kv SET value = '1' WHERE key = ?", ("commit_reader:$id",))  # an older reader read it
    @test K.read_all_commits!(kb) == 3 && K.read_all_commits!(kb) == 0          # so they are read again, once
    cs = K.task(kb, "DM-1").commits                                             # its own and its subtasks', oldest first
    @test [(c.subject, c.task, c.ref) for c in cs] == [("Add f", "DM-2", "main"), ("Add h", "DM-1", "side")]
    @test cs[2].files == [Dict("path" => "a.jl", "added" => 1, "removed" => 0)] && cs[2].author == "Ada" && endswith(cs[2].at, "Z")
    @test [c.subject for c in K.task(kb, "DM-2").commits] == ["Add f"]
    @test occursin("+h() = 3", K.task_diff(kb, "DM-1")) && occursin("Add f", K.task_diff(kb, "DM-1")) && K.task_diff(kb, "DM-3") == ""
    @test occursin("## Commits", K.format_task(K.task(kb, "DM-1")))
    @test K.remote_url(root) == ""
    gitc("remote", "add", "origin", "git@github.com:ada/demo.jl.git"); empty!(K.REMOTE_URLS)
    @test K.commit_url(root, "abc") == "https://github.com/ada/demo.jl/commit/abc"
    # A file's work: the tasks whose commits changed it; the project's commits in its review.
    @test Set(w.ref for w in K.file_work(kb, id, "a.jl")) == Set(["DM-1", "DM-2"]) && isempty(K.file_work(kb, id, "b.jl"))
    @test K.project_review(kb, "DM")["stats"]["commits"] == 2 && sum(b -> b["commits"], K.project_review(kb, "DM")["buckets"]) == 2
    # The codebase's activity: every commit, those naming tasks among them.
    act = K.code_activity(kb, "DM"; days = 30)
    @test act["totals"]["commits"] == 3 && act["totals"]["with_tasks"] == 2 && act["totals"]["added"] == 3 && act["totals"]["removed"] == 0
    @test act["totals"]["files"] == 2 && only(act["authors"])["name"] == "Ada" && only(act["authors"])["commits"] == 3 && act["step"] == "day"
    @test sum(b -> b["commits"], act["buckets"]) == 3 && sum(d -> d["commits"], act["calendar"]) == 3
    @test K.code_activity(kb, "DM")["totals"]["commits"] == 3
    # @code references: files and definitions of the project's codebase, suggested and linked there.
    @test [(r.kind, r.target) for r in K.at_references("See @code:src/a.jl#f!, and @code:docs/x.md.")] ==
          [("code", "src/a.jl#f!"), ("code", "docs/x.md")]
    K.parse_code!(kb, id)
    @test any(m -> m.target == "b.jl" && m.detail == "file", K.code_reference_matches(kb, id, "b.j"))
    @test first(K.code_reference_matches(kb, id, "g")).target == "b.jl#g" && first(K.code_reference_matches(kb, id, "g")).detail == "b.jl:1"
    picked = K.at_reference_matches(kb, "code:a"; project = "DM")
    @test !isempty(picked) && all(m -> m.kind == "code", picked) && isempty(K.at_reference_matches(kb, "code:a"))
    K.link_at_references!(kb, "DM-1", "Changed @code:b.jl#g"; by = me)            # as a note would, without one
    @test ("code", "$id:b.jl#g") in [(l.kind, l.target) for l in K.task(kb, "DM-1").links]
    # A commit read as it comes that finishes a task in progress moves it to review; not one read again
    # from the start, not one older than the task's last move, and not a task in another column.
    K.update_task!(kb, "DM-2"; status = "in_progress", by = bot)
    gitd(date, args...) = run(pipeline(addenv(`git -C $root -c user.name=Ada -c user.email=ada@x.org -c commit.gpgsign=false $args`,
                                              "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date); stdout = devnull, stderr = devnull))
    K.execute!(kb, "UPDATE kv SET value = '1' WHERE key = ?", ("commit_reader:$id",))
    write(joinpath(root, "c.jl"), "c() = 1\n"); gitc("add", "c.jl"); gitc("commit", "-q", "-m", "Add c\n\nFixes DM-2")
    K.read_all_commits!(kb)                                                      # read again from the start
    @test K.task(kb, "DM-2").status == "in_progress"
    write(joinpath(root, "c.jl"), "c() = 2\n"); gitd("2026-01-01T00:00:00Z", "commit", "-q", "-am", "Change c\n\nFinishes DM-2")
    K.read_all_commits!(kb)                                                      # made before DM-2 was last moved
    @test K.task(kb, "DM-2").status == "in_progress"
    write(joinpath(root, "c.jl"), "c() = 3\n"); gitc("commit", "-q", "-am", "Settle c\n\nCloses DM-2, fixes DM-3. Unlike DM-1, keeps the cache.")
    K.read_all_commits!(kb)
    t2 = K.task(kb, "DM-2")
    @test t2.status == "review" && any(e -> e.kind == "progress" && occursin("says it finishes this", e.text), t2.activity)
    @test K.task(kb, "DM-3").status == "ready"                                  # not in progress: left
    @test [c.subject for c in K.task(kb, "DM-1").mentions] == ["Settle c"] && !any(c -> c.subject == "Settle c" && c.task == "DM-1", K.task(kb, "DM-1").commits)
    # A person's task starts where they put it; ordering within a column; blocking; notes and links.
    K.create_task!(kb, "DM", "Read the papers"; by = me)
    K.create_task!(kb, "DM", "Write it up"; by = me)
    K.update_task!(kb, "DM-5"; before = "DM-4", by = me)
    @test [t.ref for t in K.tasks(kb; project = "DM", status = "backlog", top = true)] == ["DM-5", "DM-4"]
    K.update_task!(kb, "DM-4"; blocked = "Waiting for the PDFs", by = me)
    K.link_task!(kb, "DM-2", "blocks", "dm-1"; by = bot)
    K.link_task!(kb, "DM-1", "paper", "2402.00785"; by = bot)
    @test_throws K.Refusal K.link_task!(kb, "DM-1", "task", "DM-99"; by = bot)
    K.note_task!(kb, "DM-1", "Started on step one"; kind = "progress", by = bot)
    K.update_task!(kb, "DM-2"; status = "done", by = bot)
    t = K.task(kb, "DM-1")
    @test t.status == "in_progress" && (t.subtasks, t.subtasks_done) == (2, 1) && t.blocked_by == ["DM-2"] && t.milestone == "First"
    @test [(a.who, a.kind) for a in t.activity] == [("Claude for Rowan", "created"), ("Rowan", "status"), ("Rowan", "edit"),   # approved: given to the agents
                                                   ("Claude for Rowan", "status"), ("Claude for Rowan", "link"), ("Claude for Rowan", "progress")]
    @test K.task(kb, "DM-4").blocked == "Waiting for the PDFs"
    @test Base.structdiff(only(K.milestones(kb, "DM")), (; created_at = "")) ==
          (; name = "First", description = "", start = "", due = "2026-11-01", closed = false, closed_at = "", done = 0, total = 1, active = false)
    @test [p.open for p in K.projects(kb) if p.key == "DM"] == [3]                 # subtasks are not counted
    # Approving a plan approves the tasks under it at every depth.
    K.create_project!(kb, "Nested"; key = "NE", by = me)
    top = K.create_task!(kb, "NE", "Top"; subtasks = ["Middle"], by = bot)                   # NE-1, with NE-2
    deep = K.create_task!(kb, "NE", "Bottom"; parent = "NE-2", by = bot)                     # NE-3, under NE-2
    K.update_task!(kb, top; status = "ready", by = me)
    @test K.task(kb, "NE-2").status == "ready" && K.task(kb, deep).status == "ready"
    # Moving tasks into and out of other tasks; never under one of their own.
    K.update_task!(kb, deep; parent = "", by = me)
    @test K.task(kb, deep).parent == "" && K.task(kb, "NE-2").subtasks == 0
    K.update_task!(kb, deep; parent = "NE-1", by = me)
    @test K.task(kb, deep).parent == "NE-1" && K.task(kb, "NE-1").subtasks == 2
    @test_throws ErrorException K.update_task!(kb, "NE-1"; parent = "NE-2", by = me)          # NE-2 is part of NE-1
    @test_throws ErrorException K.update_task!(kb, "NE-1"; parent = "DM-1", by = me)          # another project
    # A person's task is theirs; its subtasks assigned to an agent are the agent's to take.
    K.update_task!(kb, "NE-1"; status = "in_progress", assignee = "Rowan", by = me)
    K.update_task!(kb, "NE-2"; status = "ready", assignee = "Rowan", by = me)
    K.update_task!(kb, deep; status = "ready", assignee = K.AGENT_ASSIGNEE, by = me)
    @test K.next_task(kb, "NE") == deep
    # What waits on a person: whole plans to approve once, a subtask proposed under an approved task,
    # tasks in Review, and their own open tasks.
    K.create_task!(kb, "NE", "Proposed under an approved task"; parent = "NE-1", by = bot)          # NE-4
    K.update_task!(kb, "NE-2"; status = "review", by = me)
    w = K.waiting(kb; me = "Rowan")
    @test "NE-4" in [t.ref for t in w.proposed] && !any(t -> t.parent == "DM-6", w.proposed)       # DM-6's subtasks come with it
    @test [t.ref for t in w.review] == ["NE-2"] && [t.ref for t in w.mine] == ["NE-1", "NE-2"]
    @test isempty(K.waiting(kb).mine)
    # An agent's question waits on the person until a person comments after it.
    K.note_task!(kb, "NE-1", "Should the bottom task stay under NE-1?"; kind = "question", by = bot)
    q = K.waiting(kb).questions
    @test [(t.ref, t.question) for t in q] == [("NE-1", "Should the bottom task stay under NE-1?")]
    K.note_task!(kb, "NE-1", "Still checking"; kind = "progress", by = bot)                     # not an answer
    @test length(K.waiting(kb).questions) == 1
    K.note_task!(kb, "NE-1", "Yes, keep it there."; by = me)
    @test isempty(K.waiting(kb).questions)
    @test_throws ErrorException K.note_task!(kb, "NE-1", "?"; kind = "shout", by = bot)
    # A question asked back answers one too, and waits on the other side in turn.
    K.note_task!(kb, "NE-1", "Shall I split it?"; kind = "question", by = bot)
    K.note_task!(kb, "NE-1", "Split how?"; kind = "question", by = me)
    @test isempty(K.waiting(kb).questions)
    @test [(t.ref, t.question) for t in K.asked_of_agents(kb, "NE")] == [("NE-1", "Split how?")]
    @test occursin("asked (answered): Shall I split it?", K.format_task(K.task(kb, "NE-1")))
    K.note_task!(kb, "NE-1", "In two, by phase."; kind = "comment", by = bot)
    @test isempty(K.asked_of_agents(kb, "NE"))
    K.resolve_question!(kb, "NE-1"; asker = "Rowan")
    # A person's question waits on the agents, shown before the next task, until an agent comments after it.
    K.note_task!(kb, "NE-2", "Why is this in Review?"; kind = "question", by = me)
    a = K.asked_of_agents(kb, "NE")
    @test [(t.ref, t.question, t.asker) for t in a] == [("NE-2", "Why is this in Review?", "Rowan")]
    @test isempty(K.waiting(kb).questions) && isempty(K.asked_of_agents(kb, "DM"))
    @test occursin("Rowan asked: Why is this in Review?", K.questions_text(a))
    @test occursin("asked (waiting for an agent's reply): Why", K.format_task(K.task(kb, "NE-2")))
    K.note_task!(kb, "NE-2", "Adding to that."; by = me)                                         # not an answer
    @test length(K.asked_of_agents(kb, "NE")) == 1
    K.note_task!(kb, "NE-2", "Its subtasks are done."; kind = "comment", by = bot)
    @test isempty(K.asked_of_agents(kb, "NE")) && K.questions_text(K.asked_of_agents(kb, "NE")) == ""
    @test occursin("asked (answered): Why", K.format_task(K.task(kb, "NE-2")))
    # An answer waits on whoever asked while the agent has had the last word: writing again takes it
    # off, asking again sends it back to the agents, their next reply brings it back, and marking it
    # resolved ends it.
    answered() = [(t.ref, t.question, t.answer) for t in K.waiting(kb; asker = "Rowan").answered]
    @test answered() == [("NE-2", "Why is this in Review?", "Its subtasks are done.")]
    @test isempty(K.waiting(kb; asker = "Ada").answered) && isempty(K.waiting(kb).answered)
    K.note_task!(kb, "NE-2", "Which ones?"; kind = "question", by = me)
    @test isempty(answered()) && any(t -> t.ref == "NE-2", K.asked_of_agents(kb, "NE"))
    K.note_task!(kb, "NE-2", "All three."; kind = "comment", by = bot)
    @test answered() == [("NE-2", "Which ones?", "All three.")]
    K.resolve_question!(kb, "NE-2"; asker = "Rowan")
    @test isempty(answered())
    # An agent's question waits until someone writes after it, or a person marks it resolved (answered
    # some other way); on a task that is done it no longer waits.
    qt = K.create_task!(kb, "NE", "Ask about it"; status = "ready", by = me)
    K.note_task!(kb, qt, "Which mesh?"; kind = "question", by = bot)
    asking() = [t.ref for t in K.waiting(kb).questions]
    @test qt in asking()
    K.resolve_question!(kb, qt; agents = true)
    @test !(qt in asking())
    K.note_task!(kb, qt, "And the boundary?"; kind = "question", by = bot)
    @test qt in asking()
    K.update_task!(kb, qt; status = "done", by = me)
    @test !(qt in asking())
    K.delete_task!(kb, qt; by = me)
    @test occursin("asked (resolved): Which ones?", K.format_task(K.task(kb, "NE-2")))
    # @-references: read from the prose (not code), each once, and shown to agents plainly.
    text = "See @NE-1 and @arXiv:2402.00785, with @[Dana Iles](author:iles|d), `@NE-2` and @NE-1 again."
    @test [(r.kind, r.target, r.label) for r in K.at_references(text)] ==
          [("task", "NE-1", "NE-1"), ("paper", "2402.00785", "2402.00785"), ("author", "iles|d", "Dana Iles")]
    @test isempty(K.at_references("mail me@NE-1.org, or see ```\n@NE-1\n```"))
    # An uploaded paper, short or labelled.
    @test [(r.kind, r.target) for r in K.at_references("From @doc-5f13926ae1, and @[Tori](paper:doc-0123456789).")] ==
          [("paper", "doc-5f13926ae1"), ("paper", "doc-0123456789")]
    @test K.plain_at_references("@[Tori](paper:doc-0123456789)") == "@doc-0123456789 (Tori)"
    @test K.plain_at_references("ask @[Rowan](person:rowan@x.org) about @[NE-1](task:NE-1), not `@[x](task:NE-9)`") ==
          "ask @Rowan (person rowan@x.org) about @NE-1, not `@[x](task:NE-9)`"
    # Each becomes a link of the task, once: not a task that does not exist, nor the task itself.
    K.note_task!(kb, "NE-2", "Builds on @NE-1, see @arXiv:2402.00785; not @NE-999 or @NE-2."; by = me)
    linked() = [(l.kind, l.target) for l in K.task(kb, "NE-2").links]
    @test ("task", "NE-1") in linked() && ("paper", "2402.00785") in linked() && !any(l -> l[2] in ("NE-999", "NE-2"), linked())
    n = length(linked())
    K.note_task!(kb, "NE-2", "Again @NE-1"; by = bot)
    @test length(linked()) == n
    made = K.create_task!(kb, "NE", "Follows @NE-1"; body = "Ask @[Rowan](person:Rowan).", by = me)
    @test Set((l.kind, l.target, l.label) for l in K.task(kb, made).links) == Set([("task", "NE-1", ""), ("person", "Rowan", "")])
    # Editing a note: its author, or a person for an agent's; the earlier text kept, links and search following.
    note = K.note_task!(kb, "NE-2", "Checked the stochastic runs"; kind = "progress", by = bot)
    @test K.edit_note!(kb, "NE-2", note, "Checked the deterministic runs against @arXiv:2501.00001"; by = bot) == note
    edited = only(e for e in K.task(kb, "NE-2").activity if e.id == note)
    @test edited.text == "Checked the deterministic runs against @arXiv:2501.00001" && !isempty(edited.edited_at) && edited.kind == "progress"
    @test [h.text for h in K.note_history(kb, note)] == ["Checked the stochastic runs"] && only(K.note_history(kb, note)).who == bot.name
    @test ("paper", "2501.00001") in linked()
    nomeaning(kb, text) = Tuple{Int,String}[]
    @test any(t -> t.ref == "NE-2", K.search_tasks(kb, "deterministic"; meaning = nomeaning)) &&
          !any(t -> t.ref == "NE-2", K.search_tasks(kb, "stochastic"; meaning = nomeaning))
    K.edit_note!(kb, "NE-2", note, "Checked the deterministic runs"; by = me)   # a person corrects an agent's note
    @test length(K.note_history(kb, note)) == 2
    @test occursin("[note $note, edited]: reported: Checked the deterministic runs", K.format_task(K.task(kb, "NE-2")))
    mine = K.note_task!(kb, "NE-2", "My own words"; by = me)
    @test_throws "An agent edits only its own" K.edit_note!(kb, "NE-2", mine, "Changed"; by = bot)
    @test_throws "their own notes" K.edit_note!(kb, "NE-2", mine, "Changed"; by = K.person("Bea"))
    @test_throws "A note needs text" K.edit_note!(kb, "NE-2", mine, "  "; by = me)
    @test_throws "No note" K.edit_note!(kb, "NE-1", mine, "Elsewhere"; by = me)
    status = first(e.id for e in K.task(kb, "NE-2").activity if e.kind == "status")
    @test_throws "Only comments" K.edit_note!(kb, "NE-2", status, "Moved"; by = me)
    # An edited question stays the question it was.
    asked = K.note_task!(kb, "NE-2", "Which runs?"; kind = "question", by = bot)
    K.edit_note!(kb, "NE-2", asked, "Which runs, deterministic or stochastic?"; by = bot)
    @test only(e for e in K.task(kb, "NE-2").activity if e.id == asked).kind == "question"
    K.note_task!(kb, "NE-2", "Deterministic."; by = me)
    @test !any(e -> e.kind == "link", K.task(kb, made).activity)                 # the text shows them
    K.update_task!(kb, made; body = "Read @[Dana Iles](author:iles|d).", by = me)
    @test ("author", "iles|d", "Dana Iles") in [(l.kind, l.target, l.label) for l in K.task(kb, made).links]
    @test occursin("Read @Dana Iles (author iles|d).", K.format_task(K.task(kb, made)))
    # What the picker offers for what is typed.
    @test ("task", "NE-1") in [(m.kind, m.target) for m in K.at_reference_matches(kb, "ne-1")]
    @test all(m -> m.kind in K.AT_REFERENCE_KINDS, K.at_reference_matches(kb, ""))
    K.delete_task!(kb, made; by = me)
    # Deleting a task takes its subtasks, their links and other tasks' links to them; numbers are not reused.
    gone = K.create_task!(kb, "NE", "Short-lived"; parent = "NE-1", subtasks = ["Under it"], by = me)
    K.link_task!(kb, "NE-2", "blocks", K.task(kb, gone).subtasks_list[1].ref; by = me)
    K.link_task!(kb, gone, "paper", "2402.00785"; by = me)
    @test K.delete_task!(kb, gone; by = me) == 2
    @test_throws K.Refusal K.task(kb, gone)
    @test !any(l -> l.kind == "blocks", K.task(kb, "NE-2").links)
    @test K.task(kb, "NE-1").activity[end].kind == "deleted" && K.task(kb, "NE-1").activity[end].text == gone
    @test K.create_task!(kb, "NE", "After"; by = me) != gone
    # Done tasks leave the board for the archive, with their subtasks, and can come back.
    arch = K.create_task!(kb, "NE", "Finished"; status = "done", subtasks = ["Its part"], by = me)
    @test_throws ErrorException K.archive_task!(kb, "NE-2"; by = me)                            # not done
    @test K.archive_done!(kb, "NE"; by = me) == 1
    @test !any(t -> t.ref == arch, K.tasks(kb; project = "NE", limit = 1000)) && K.next_task(kb, "NE") !== arch
    @test [t.ref for t in K.tasks(kb; project = "NE", archived = true, top = true)] == [arch]
    @test !isempty(K.task(kb, arch).archived_at) && !isempty(K.task(kb, K.task(kb, arch).subtasks_list[1].ref).archived_at)
    K.archive_task!(kb, arch; undo = true, by = me)
    @test isempty(K.task(kb, arch).archived_at) && any(t -> t.ref == arch, K.tasks(kb; project = "NE", status = "done"))
    @test [e.kind for e in K.task(kb, arch).activity][end-1:end] == ["archived", "unarchived"]
    # ASAP work is taken before anything else, in the order it was marked so; it stops being ASAP
    # when its priority changes. Priorities are named or numbered.
    first_asap = K.create_task!(kb, "NE", "Urgent, asked first"; status = "ready", priority = 0, by = me)
    later_asap = K.create_task!(kb, "NE", "Urgent, asked later"; status = "ready", by = me)
    sleep(1.1)
    K.update_task!(kb, later_asap; priority = 0, by = me)
    @test K.next_task(kb, "NE") == first_asap && !isempty(K.task(kb, later_asap).asap_at)
    K.update_task!(kb, first_asap; priority = 1, by = me)
    @test K.next_task(kb, "NE") == later_asap && isempty(K.task(kb, first_asap).asap_at)
    @test (K.parse_priority("ASAP"), K.parse_priority("high"), K.parse_priority("3"), K.parse_priority(" ")) == (0, 1, 3, nothing)
    @test_throws "asap, high, normal or low" K.parse_priority("urgent")
    K.delete_task!(kb, first_asap; by = me); K.delete_task!(kb, later_asap; by = me)
    # Searching the tasks: words in titles, plans and what is said on them, with filters; the last
    # word as a prefix; references first; the index following edits, notes and deletions.
    sx = K.create_task!(kb, "NE", "Calibrate the bolometer array"; body = "Use the reference lamp.", by = me)
    K.note_task!(kb, sx, "The lamp drifts above forty kelvin"; by = bot)
    ref_of(hits) = [h.ref for h in hits]
    @test first(ref_of(K.search_tasks(kb, "bolometer"))) == sx
    @test first(K.search_tasks(kb, "bolometer")).matches[1].field == "title"
    hit = only(h for h in K.search_tasks(kb, "drifts kelvin") if h.ref == sx)
    @test hit.matches[1].field == "note" && hit.matches[1].who == "Claude for Rowan" && occursin("\x01drifts\x02", hit.matches[1].snippet)
    @test sx in ref_of(K.search_tasks(kb, "calib"))                                     # a prefix while typing
    @test !(sx in ref_of(K.search_tasks(kb, "calib ")))                                 # a whole word once a space follows
    @test sx in ref_of(K.search_tasks(kb, "\"reference lamp\""))
    @test !(sx in ref_of(K.search_tasks(kb, "\"lamp reference\"")))
    @test sx in ref_of(K.search_tasks(kb, "lamp status:backlog")) && isempty(K.search_tasks(kb, "lamp status:done"))
    @test sx in ref_of(K.search_tasks(kb, "is:open project:NE"; limit = 500)) && first(ref_of(K.search_tasks(kb, "$sx lamp"))) == sx
    n = split(sx, '-')[2]                                                               # its number alone, in its project
    @test first(ref_of(K.search_tasks(kb, n; project = "NE", meaning = nomeaning))) == sx
    @test first(ref_of(K.search_tasks(kb, "#$n project:NE"; meaning = nomeaning))) == sx
    @test !(sx in ref_of(K.search_tasks(kb, n; meaning = nomeaning)))                  # not across projects
    @test isempty(K.search_tasks(kb, "lamp project:DM")) && isempty(K.search_tasks(kb, "\"unbalanced"))
    K.update_task!(kb, sx; title = "Calibrate the spectrometer", by = me)
    @test isempty(K.search_tasks(kb, "bolometer")) && sx in ref_of(K.search_tasks(kb, "spectrometer"))
    K.delete_task!(kb, sx; by = me)
    @test isempty(K.search_tasks(kb, "spectrometer")) && isempty(K.search_tasks(kb, "drifts"))
    # By meaning as well: a task found only for what it is about shows the text that was nearest,
    # and one found both ways ranks above one found by its words alone.
    mx = K.create_task!(kb, "NE", "Install the cryostat"; by = me)
    K.note_task!(kb, mx, "Cooling takes two days"; by = bot)
    ev = K.task(kb, mx).activity[end].id
    nearest(kb, text) = [(K.task_ref(kb, mx), "e:$ev")]
    hits = K.search_tasks(kb, "refrigeration schedule"; meaning = nearest)
    @test [h.ref for h in hits] == [mx] && hits[1].matches[1].field == "note" && hits[1].matches[1].snippet == "Cooling takes two days"
    other = K.create_task!(kb, "NE", "Order the cryostat cables"; by = me)
    @test [h.ref for h in K.search_tasks(kb, "cryostat"; meaning = nearest)][1:2] == [mx, other]
    @test Set(h.ref for h in K.search_tasks(kb, "cryostat"; meaning = (kb, t) -> Tuple{Int,String}[])) == Set([mx, other])
    docs = K.task_documents(kb)
    @test docs["t:$(K.task_ref(kb, mx))"][2] == "Install the cryostat" && docs["e:$ev"] == (K.task_ref(kb, mx), "Cooling takes two days")
    @test K.point_id("t:5") == K.TASK_POINT + 5 && K.point_id("e:7") == 7
    K.delete_task!(kb, mx; by = me); K.delete_task!(kb, other; by = me)
    # A declined plan leaves the board with its subtasks, is kept among the declined (not the archive)
    # with the reason, and can come back to Proposed. Only a person declines, and only a proposal.
    plan = K.create_task!(kb, "NE", "Not now"; subtasks = ["Its step"], by = bot)
    @test_throws "Only a person" K.decline_task!(kb, plan; by = bot)
    @test_throws "Only a proposed plan" K.decline_task!(kb, arch; by = me)
    K.decline_task!(kb, plan; reason = "Out of scope", by = me)
    @test !any(t -> t.ref == plan, K.tasks(kb; project = "NE", limit = 1000)) && !any(t -> t.ref == plan, K.waiting(kb).proposed)
    @test [t.ref for t in K.tasks(kb; project = "NE", declined = true, top = true)] == [plan]
    @test !any(t -> t.ref == plan, K.tasks(kb; project = "NE", archived = true))
    @test !isempty(K.task(kb, K.task(kb, plan).subtasks_list[1].ref).declined_at)
    @test occursin("declined it: Out of scope", K.format_task(K.task(kb, plan)))
    K.decline_task!(kb, plan; undo = true, by = me)
    @test K.task(kb, plan).status == "proposed" && any(t -> t.ref == plan, K.tasks(kb; project = "NE"))
    K.delete_task!(kb, plan; by = me)
    # A knowledge base open in this process is brought up to the code's schema (as when code is
    # applied in a running service).
    push!(K.MIGRATIONS, ["CREATE TABLE migrate_open_check (x INTEGER)"])            # a migration that arrives with code
    K._KB[] = kb
    try
        K.migrate_open!()
        @test K.scalar(kb, "SELECT value FROM kv WHERE key = 'schema_version'") == string(K.schema_version())
        @test !isempty(K.query(kb, "SELECT name FROM sqlite_master WHERE name = 'migrate_open_check'"))
    finally
        K._KB[] = nothing
        pop!(K.MIGRATIONS)
        K.execute!(kb, "DROP TABLE migrate_open_check")
        K.execute!(kb, "UPDATE kv SET value = ? WHERE key = 'schema_version'", (string(K.schema_version()),))
    end
    # A migration defined again (Revise evaluating an edited one) replaces it rather than adding one;
    # one defined early waits for those below it, and nothing is migrated while one is missing.
    n = K.schema_version()
    kept = copy(K.MIGRATIONS[n])
    @test K.migration!(n, ["SELECT 1"]) == n && K.schema_version() == n && K.MIGRATIONS[n] == ["SELECT 1"]
    K.migration!(n, kept)
    @test K.MIGRATIONS[n] == kept
    K.migration!(n + 2, ["SELECT 2"])
    @test K.schema_version() == n
    @test_throws "Migration $(n + 1) is missing" K.migrate!(kb)
    K.migration!(n + 1, ["SELECT 1"])
    @test K.schema_version() == n + 2 && K.MIGRATIONS[n + 2] == ["SELECT 2"]
    pop!(K.MIGRATIONS); pop!(K.MIGRATIONS)
    @test K.schema_version() == n
    # Pages follow changes: a wait answers at once when it is behind, wakes on the next change, and
    # gives up after its timeout.
    v = K.TASKS_VERSION[]
    @test K.wait_tasks_changed(v - 1) == v
    waiter = @async K.wait_tasks_changed(v; timeout = 10)
    sleep(0.3); K.note_task!(kb, "NE-1", "A change to wake the page"; by = me)
    @test timedwait(() -> istaskdone(waiter), 5) == :ok && fetch(waiter) > v
    t0 = time(); @test K.wait_tasks_changed(K.TASKS_VERSION[]; timeout = 0.5) == K.TASKS_VERSION[] && time() - t0 >= 0.4
    # New tasks go into the project's active milestone, subtasks into their parent's.
    K.create_milestone!(kb, "NE", "Now"); K.create_milestone!(kb, "NE", "Later")
    K.set_active_milestone!(kb, "NE", "Now")
    @test only(p for p in K.projects(kb) if p.key == "NE").active_milestone == "Now" && any(m -> m.name == "Now" && m.active, K.milestones(kb, "NE"))
    plain = K.create_task!(kb, "NE", "Goes into Now"; by = me)
    given = K.create_task!(kb, "NE", "Goes into Later"; milestone = "Later", subtasks = ["Follows its parent"], by = me)
    @test K.task(kb, plain).milestone == "Now" && K.task(kb, given).milestone == "Later"
    @test K.task(kb, K.task(kb, given).subtasks_list[1].ref).milestone == "Later"
    K.set_active_milestone!(kb, "NE", "")
    @test K.task(kb, K.create_task!(kb, "NE", "No milestone"; by = me)).milestone == ""
    # Marking a milestone done archives its completed tasks, with their subtasks; an unfinished one
    # stays on the board until it is completed. It is no longer the active milestone.
    K.set_active_milestone!(kb, "NE", "Later")
    # A task is done only with everything under it: refused while a subtask is open, unless they go too.
    sub = K.task(kb, given).subtasks_list[1].ref
    deeper = K.create_task!(kb, "NE", "Under the subtask"; parent = sub, by = me)
    @test (K.task(kb, given).subtasks, K.task(kb, given).subtasks_done) == (2, 0)          # every level below it
    @test_throws "has subtasks not done ($sub, $deeper)" K.update_task!(kb, given; status = "done", by = me)
    @test K.task(kb, given).status != "done"
    K.update_task!(kb, given; status = "done", with_subtasks = true, by = me)
    @test K.task(kb, sub).status == "done" && K.task(kb, deeper).status == "done" && K.task(kb, given).subtasks_done == 2
    @test K.task(kb, deeper).activity[end].kind == "status"
    # Only what is done goes under a done task: moving or adding anything else there is refused,
    # while a task done in the same move may go.
    loose = K.create_task!(kb, "NE", "Not done yet"; by = me)
    @test_throws "only what is done goes under a done task" K.update_task!(kb, loose; parent = given, by = me)
    K.update_task!(kb, loose; status = "done", parent = given, by = me)
    @test K.task(kb, loose).parent == given
    # Work added under a finished task sends it back, and a task leaving Done reopens the done tasks
    # above it; agents take work sent back before anything new.
    closed = K.create_task!(kb, "NE", "Closed one"; status = "done", subtasks = ["Its piece"], by = me)
    piece = K.task(kb, closed).subtasks_list[1].ref
    late = K.create_task!(kb, "NE", "Late addition"; parent = closed, status = "ready", assignee = K.AGENT_ASSIGNEE, by = me)
    @test K.task(kb, closed).status == "in_progress" && K.task(kb, closed).sent_back && !K.task(kb, late).sent_back
    K.update_task!(kb, late; status = "done", by = me)
    K.update_task!(kb, closed; status = "done", by = me)
    K.update_task!(kb, piece; status = "in_progress", by = me)
    @test K.task(kb, closed).status == "in_progress"
    K.delete_task!(kb, closed; by = me)
    # Sending work back from review: back to its agent, with the request and what to add.
    rev = K.create_task!(kb, "NE", "Under review"; status = "review", assignee = "agent:Claude", by = me)
    @test_throws "Say what is needed" K.send_back!(kb, rev; request = " ", by = me)
    @test_throws "Only a person" K.send_back!(kb, rev; request = "More", by = bot)
    K.send_back!(kb, rev; request = "Cover the edge cases.", subtasks = ["Empty input", ""], by = me)
    r = K.task(kb, rev)
    @test r.status == "in_progress" && r.assignee == "agent:Claude" && r.sent_back
    @test [(x.title, x.status, x.assignee) for x in r.subtasks_list] == [("Empty input", "ready", "agent:Claude")]
    @test K.next_task(kb, "NE") == rev
    # Not while a task still open blocks it.
    blocker = K.create_task!(kb, "NE", "Blocks the rework"; status = "backlog", by = me)
    K.link_task!(kb, blocker, "blocks", rev; by = me)
    @test K.next_task(kb, "NE") != rev
    K.link_task!(kb, blocker, "blocks", rev; remove = true, by = me)
    K.delete_task!(kb, blocker; by = me)
    @test K.next_task(kb, "NE") == rev
    @test startswith(K.format_task(r), "Sent back from review by Rowan, who wrote:\n> Cover the edge cases.")
    K.update_task!(kb, K.task(kb, rev).subtasks_list[1].ref; status = "done", by = me)
    K.update_task!(kb, rev; status = "review", by = bot)
    @test !K.task(kb, rev).sent_back && K.next_task(kb, "NE") != rev
    fresh = K.create_task!(kb, "NE", "Fresh"; by = me)
    @test_throws "not in review" K.send_back!(kb, fresh; request = "x", by = me)
    K.delete_task!(kb, fresh; by = me)
    K.delete_task!(kb, rev; by = me)
    unfinished = K.create_task!(kb, "NE", "Unfinished in Later"; milestone = "Later", by = me)
    K.finish_milestone!(kb, "NE", "Later"; by = me)
    @test !isempty(K.task(kb, given).archived_at) && !isempty(K.task(kb, K.task(kb, given).subtasks_list[1].ref).archived_at)
    @test isempty(K.task(kb, unfinished).archived_at) && only(p for p in K.projects(kb) if p.key == "NE").active_milestone == ""
    @test only(m for m in K.milestones(kb, "NE") if m.name == "Later").closed
    @test K.task(kb, given).activity[end].who == "Milestone Later"
    K.update_task!(kb, unfinished; status = "done", by = me)
    @test !isempty(K.task(kb, unfinished).archived_at)
    # A milestone's date passing changes nothing.
    K.create_milestone!(kb, "NE", "Past"; due = "2000-01-01")
    past = K.create_task!(kb, "NE", "Done in a past milestone"; milestone = "Past", by = me)
    K.update_task!(kb, past; status = "done", by = me)
    @test isempty(K.task(kb, past).archived_at)
    K.finish_milestone!(kb, "NE", "Later"; reopen = true, by = me)
    # Completing a milestone settles its unfinished tasks as decided: done with what is under them
    # (then archived with the rest), or to the backlog, into another milestone.
    K.create_milestone!(kb, "NE", "Sprint"); K.create_milestone!(kb, "NE", "Next sprint")
    finish_me = K.create_task!(kb, "NE", "Finish me"; milestone = "Sprint", status = "in_progress", subtasks = ["Its part"], by = me)
    carry_me = K.create_task!(kb, "NE", "Carry me over"; milestone = "Sprint", status = "ready", by = me)
    @test_throws "either marked done or moved" K.finish_milestone!(kb, "NE", "Sprint";
        decisions = [(; ref = carry_me, action = "drop", milestone = "")], by = me)
    # Only the project's own tasks: another's is refused as one that is not there, and nothing changes.
    K.create_project!(kb, "Neighbour"; key = "NB", by = me)
    theirs = K.create_task!(kb, "NB", "Theirs"; status = "ready", by = me)
    for ref in (theirs, "NB-999")
        @test_throws "No task $ref in NE" K.finish_milestone!(kb, "NE", "Sprint";
            decisions = [(; ref, action = "done", milestone = "")], by = me)
    end
    @test K.task(kb, theirs).status == "ready" && !only(m for m in K.milestones(kb, "NE") if m.name == "Sprint").closed
    K.finish_milestone!(kb, "NE", "Sprint"; decisions = [(; ref = finish_me, action = "done", milestone = ""),
                                                         (; ref = carry_me, action = "backlog", milestone = "Next sprint")], by = me)
    @test K.task(kb, finish_me).status == "done" && !isempty(K.task(kb, finish_me).archived_at)
    @test K.task(kb, K.task(kb, finish_me).subtasks_list[1].ref).status == "done"
    c = K.task(kb, carry_me)
    @test c.status == "backlog" && c.milestone == "Next sprint" && isempty(c.archived_at)
    # The project's history: milestones done, newest first, with the work finished in them, and other
    # archived work by day; a milestone reopened leaves it.
    h = K.project_history(kb, "NE")
    sprint = only(m for m in h.milestones if m.name == "Sprint")
    @test !isempty(sprint.closed_at) && [t.ref for t in sprint.tasks] == [finish_me]
    @test only(m for m in K.milestones(kb, "NE") if m.name == "Sprint").closed_at == sprint.closed_at
    @test all(a -> all(t -> !isempty(t.archived_at) && startswith(t.archived_at, a.day), a.tasks), h.archived)
    # The review: totals, the columns over time in readable steps, and the milestones' spans.
    rv = K.project_review(kb, "NE")
    @test rv["step"] == "hour" && rv["stats"]["done"] == count(t -> t.status == "done", K.tasks(kb; project = "NE", limit = 5000)) +
          count(t -> t.status == "done", K.tasks(kb; project = "NE", archived = true, limit = 5000))
    last_cols = rv["buckets"][end]["columns"]
    @test sum(values(last_cols)) == rv["stats"]["done"] + rv["stats"]["open"] && last_cols["review"] == rv["stats"]["in_review"]
    @test any(m -> m["name"] == "Sprint" && !isempty(m["closed_at"]), rv["milestones"])
    # One closed before completion times were kept, with no work finished in it, ends where it began,
    # however recently its open work changed.
    K.create_milestone!(kb, "NE", "Shelved")
    shelf = K.create_task!(kb, "NE", "Someday"; milestone = "Shelved", by = me)
    K.execute!(kb, "UPDATE milestones SET closed = 1, closed_at = NULL WHERE name = 'Shelved'")
    K.update_task!(kb, shelf; title = "Someday, maybe", by = me)
    shelved = only(m for m in K.project_review(kb, "NE")["milestones"] if m["name"] == "Shelved")
    @test shelved["closed_at"] == shelved["created_at"]
    K.delete_task!(kb, shelf; by = me)
    later =K.project_review(kb, "NE"; now = K.Dates.now(K.Dates.UTC) + K.Dates.Day(10))
    @test later["step"] == "day" && length(later["buckets"]) in 11:12
    K.finish_milestone!(kb, "NE", "Sprint"; reopen = true, by = me)
    @test !any(m -> m.name == "Sprint", K.project_history(kb, "NE").milestones)
    @test isempty(only(m for m in K.milestones(kb, "NE") if m.name == "Sprint").closed_at)
    @test !only(m for m in K.milestones(kb, "NE") if m.name == "Later").closed
    who = K.people(kb)
    @test any(p -> p.id == K.AGENT_ASSIGNEE && p.agent && p.label == "Claude (agent)", who)
    # An agent by its id or name; one that does not exist is refused, not added to the list. Without
    # accounts, a person is whoever is named.
    @test K.assignee_id(kb, "Claude (agent)") == K.assignee_id(kb, "Claude") == "agent:Claude" && K.assignee_id(kb, "rowan") == "Rowan"
    @test_throws "No one called agent:Claudea" K.update_task!(kb, "NE-1"; assignee = "agent:Claudea", by = me)
    @test_throws "No one called Bea" K.assignee_id(kb, "Bea")
    @test [p.id for p in K.people(kb) if p.agent] == K.AGENTS

    # The API behind the Projects page: a person's changes, and the board read back.
    api(method, path, body = nothing) = (r = K.handle(kb, K.HTTP.Request(method, path, ["Content-Type" => "application/json"],
                                                                         body === nothing ? "" : K.JSON.json(body)));
                                         (r.status, K.JSON.parse(String(r.body))))
    @test api("POST", "/api/projects", Dict("name" => "Web", "key" => "web"))[2]["key"] == "WEB"
    s, t = api("POST", "/api/tasks", Dict("project" => "WEB", "title" => "Draw the board"))
    @test s == 200 && t["ref"] == "WEB-1" && t["status"] == "backlog" && !t["by_agent"]
    @test api("POST", "/api/tasks/WEB-1", Dict("status" => "in_progress", "blocked" => "Waiting on fonts"))[2]["blocked"] == "Waiting on fonts"
    @test api("POST", "/api/tasks/WEB-1/notes", Dict("text" => "Looks good"))[2]["activity"][end]["kind"] == "comment"
    @test api("POST", "/api/tasks/WEB-1/notes", Dict("text" => "Why fonts?", "kind" => "question"))[2]["activity"][end]["kind"] == "question"
    @test api("POST", "/api/tasks/WEB-1/notes", Dict("text" => "Done it", "kind" => "progress"))[1] == 400   # an agent's report
    # What waits on the person comes as lists, also those that are empty.
    s, w = api("GET", "/api/tasks/waiting")
    @test s == 200 && all(v -> v isa AbstractVector, values(w)) && any(isempty, values(w)) && haskey(w, "findings")
    # Declining a proposal through the API: listed among the declined with why, and brought back.
    prop = api("POST", "/api/tasks", Dict("project" => "WEB", "title" => "Maybe later", "status" => "proposed"))[2]["ref"]
    @test api("POST", "/api/tasks/$prop/decline", Dict("reason" => "Not this term"))[1] == 200
    s, d = api("GET", "/api/projects/WEB/declined")
    @test s == 200 && [(x["ref"], x["reason"]) for x in d] == [(prop, "Not this term")]
    @test api("POST", "/api/tasks/$prop/decline", Dict("undo" => true))[2]["status"] == "proposed"
    api("POST", "/api/tasks/$prop/delete", Dict())
    # Sending a reviewed task back through the API.
    rv = api("POST", "/api/tasks", Dict("project" => "WEB", "title" => "Reviewed", "status" => "review"))[2]["ref"]
    s, t = api("POST", "/api/tasks/$rv/send-back", Dict("request" => "Add the legend.", "subtasks" => ["Legend"]))
    @test s == 200 && t["status"] == "in_progress" && t["sent_back"] && t["subtasks_list"][1]["title"] == "Legend"
    @test api("POST", "/api/tasks/$rv/send-back", Dict("request" => "Again"))[1] == 400            # not in review now
    api("POST", "/api/tasks/$rv/delete", Dict())
    s, b = api("POST", "/api/projects/WEB", Dict("description" => "The board's web page."))
    @test s == 200 && b["project"]["description"] == "The board's web page."
    @test api("GET", "/api/projects/WEB")[2]["milestones"] == []   # an empty list, before there are any
    @test api("GET", "/api/projects/FNREF1")[1] == 404                       # a key no project has
    # Findings through the API: made, listed, given evidence (named), changed, and their versions.
    s, f = api("POST", "/api/findings", Dict("project" => "WEB", "claim" => "The board loads fast"))
    @test s == 200 && f["ref"] == "WEB-F1" && f["status"] == "draft"
    @test [x["ref"] for x in api("GET", "/api/findings?project=WEB")[2]] == ["WEB-F1"]
    s, f = api("POST", "/api/findings/WEB-F1/evidence", Dict("kind" => "task", "target" => "WEB-1"))
    @test s == 200 && only(f["sources"])["label"] == "Draw the board" && only(f["sources"])["evidence"] == only(f["evidence"])["id"]
    @test api("POST", "/api/findings/WEB-F1", Dict("status" => "contested"))[1] == 400          # without a reason
    s, f = api("POST", "/api/findings/WEB-F1", Dict("status" => "contested", "reason" => "Measured on one machine"))
    @test s == 200 && f["status_reason"] == "Measured on one machine"
    api("POST", "/api/findings/WEB-F1", Dict("status" => "draft"))
    s, f = api("POST", "/api/findings/WEB-F1", Dict("status" => "accepted"))
    @test s == 200 && f["status"] == "accepted" && f["versions"] == 3 && length(api("GET", "/api/findings/WEB-F1/versions")[2]) == 3
    @test api("POST", "/api/findings/WEB-F1/evidence/$(only(f["evidence"])["id"])/delete", Dict())[2]["evidence"] == []
    @test api("GET", "/api/findings/WEB-F9")[1] == 404 && api("GET", "/api/findings")[1] != 200
    # Started from a task, which is its first source; the board counts the project's findings.
    s, f = api("POST", "/api/findings", Dict("project" => "WEB", "claim" => "Cards redraw only when changed", "task" => "WEB-1"))
    @test s == 200 && [(x["kind"], x["target"]) for x in f["sources"]] == [("task", "WEB-1")]
    @test api("GET", "/api/projects/WEB")[2]["findings"] == 2
    @test [x["ref"] for x in api("GET", "/api/findings?project=WEB&q=redraw")[2]] == ["WEB-F2"]
    # The project's map, as a notebook reads it, with the task the new finding rests on.
    m = K.read_project_map(api("GET", "/api/projects/WEB/map")[2])
    @test isempty(m.code)                                                             # no codebase
    @test m.key == "WEB" && haskey(m.tasks, "WEB-1") && any(f -> f.ref == "WEB-F2" && f.tasks == ["WEB-1"], m.findings)
    @test api("POST", "/api/findings/WEB-F1/archive", Dict())[2]["archived_at"] != "" && api("GET", "/api/projects/WEB")[2]["findings"] == 1
    @test [x["ref"] for x in api("GET", "/api/findings?project=WEB&archived=1")[2]] == ["WEB-F1"]
    @test api("POST", "/api/findings/WEB-F1/archive", Dict("restore" => true))[2]["archived_at"] == ""
    @test api("POST", "/api/findings/WEB-F1/delete", Dict())[1] == 400                     # accepted: archived, not deleted
    @test api("POST", "/api/findings/WEB-F2/delete", Dict())[2]["deleted"] == "WEB-F2" && api("GET", "/api/findings/WEB-F2")[1] == 404
    s, found = api("GET", "/api/tasks/search?q=draw&project=WEB")
    @test s == 200 && found[1]["ref"] == "WEB-1" && found[1]["matches"][1]["field"] == "title"
    s, found = api("GET", "/api/tasks/references?q=draw")
    @test s == 200 && Dict("kind" => "task", "target" => "WEB-1", "label" => "WEB-1", "detail" => "Draw the board") in found
    @test api("POST", "/api/tasks/WEB-1/links", Dict("kind" => "paper", "target" => "2402.00785"))[2]["links"][1]["target"] == "2402.00785"
    @test api("POST", "/api/projects/WEB/milestones", Dict("name" => "v1", "due" => "2026-12-01"))[1] == 200
    s, b = api("GET", "/api/projects/web")
    @test s == 200 && [x["ref"] for x in b["tasks"]] == ["WEB-1"] && b["milestones"][1]["name"] == "v1" && length(b["statuses"]) == 6
    @test api("POST", "/api/tasks/WEB-1", Dict("status" => "nowhere"))[1] == 400
    @test api("GET", "/api/tasks/WEB-1")[2]["status"] == "in_progress"
    @test api("POST", "/api/tasks/WEB-1/delete", Dict())[2]["deleted"] == 1 && api("GET", "/api/tasks/WEB-1")[1] == 404
    # Starting, the service answers the board's first requests once, so the first person need not wait.
    @test K.warm_up(kb) >= 10

    # The agents' tools: plans proposed, refusals as answers, and changes recorded for whom the agent works.
    K._KB[] = kb
    try
        tools = Dict(t.name => t.f for t in K.TOOLS[])
        # Whom an agent works for comes from its MCP session (see `mcp_person`), not from the call.
        @test !any(f -> any(m -> :by in Base.kwarg_decl(m), methods(f)), values(tools))
        K.MCP_CALLERS["s-ada"] = (K.Caller(nothing, "Ada", "", Set(K.PERMISSION_NAMES), :token, nothing), K.Dates.now())
        as_ada(f) = task_local_storage(f, :gate_caller, "s-ada")
        # An agent working for someone outside a project does not reach it.
        K.MCP_CALLERS["s-bea"] = (K.Caller(nothing, "Bea", "", Set(["tasks.view", "tasks.edit"]), :token, nothing), K.Dates.now())
        as_bea(f) = task_local_storage(f, :gate_caller, "s-bea")
        @test startswith(as_bea(() -> tools["plan"]("DM", "Not mine")), "⛔ No project DM")
        @test startswith(as_bea(() -> tools["task"]("DM-1")), "⛔ No project DM") && !occursin("DM:", as_bea(() -> tools["projects"]()))
        # A shared service serving /mcp refuses a call from no one it knows, rather than act as whoever
        # runs it, and an agent it opened for someone acts with that person's access and no more. One
        # giving its tools to this machine's sessions instead (`--kaimon`) acts for whoever runs it.
        K.SHARED_MODE[] = true
        try
            @test occursin("DM-1 [", tools["task"]("DM-1"))
            K.EMBEDDED[] = K.EmbeddedKaimon(; port = 1, key = "k", config_dir = mktempdir(), cache_dir = mktempdir())
            @test startswith(tools["task"]("DM-1"), "⛔ Not permitted: this tool call is from no one the service knows")
            @test startswith(tools["task_attach"]("DM-1"; path = "~/.ssh/id_ed25519"), "⛔ Not permitted")
            K.act_for!("zemi-chat-c1", K.session_owner("s-bea"))
            task_local_storage(:gate_agent_id, "zemi-chat-c1") do
                @test startswith(tools["task"]("DM-1"), "⛔ No project DM")
            end
            K.stop_acting!("zemi-chat-c1")
            task_local_storage(:gate_agent_id, "zemi-chat-c1") do
                @test startswith(tools["task"]("DM-1"), "⛔ Not permitted")
            end
        finally
            K.SHARED_MODE[] = false
            K.EMBEDDED[] = nothing
        end
        out = as_ada(() -> tools["plan"]("DM", "Survey the field"; body = "Find the key papers.", subtasks = "- Search\n- Read the top five\n\n"))
        @test occursin("DM-6 proposed, with 2 subtask(s)", out) && occursin("## Subtasks", out) && occursin("Claude for Ada (agent)", out)
        @test startswith(tools["task_update"]("DM-6"; status = "ready"), "⛔ DM-6 waits for a person's approval")
        @test occursin("DM-1 [In progress", tools["tasks"](; project = "DM")) && !occursin("DM-7", tools["tasks"](; project = "DM"))
        @test occursin("DM-7", tools["tasks"](; project = "DM", all = true))
        noted = as_ada(() -> tools["task_note"]("dm-6", "Looked at the arXiv lists"))
        @test occursin("Noted on DM-6 (note ", noted)
        n = parse(Int, match(r"note (\d+)", noted)[1])
        @test as_ada(() -> tools["task_note_edit"]("DM-6", n, "Looked at the arXiv listings")) == "Edited note $n on DM-6."
        @test occursin("[note $n, edited]: reported: Looked at the arXiv listings", tools["task"]("DM-6"))
        @test occursin("DM: Demo · ", tools["projects"](; path = root)) && occursin("No project for", tools["projects"](; path = tempdir()))
        @test occursin("First · due 2026-11-01 · 0/1 done", tools["milestones"]("DM"))
        @test startswith(tools["task"]("DM-404"), "⛔ No task DM-404")
        @test occursin("made active", tools["milestone_create"]("DM", "Second"; active = true))
        @test occursin("Second · 0/0 done · active", tools["milestones"]("DM")) && occursin("active milestone Second", tools["projects"]())
        @test occursin("First is DM's active milestone", tools["milestone_activate"]("DM", "First"))
        @test tools["milestone_update"]("DM", "Second"; due = "2026-11-20") == "Milestone Second of DM: due 2026-11-20."
        @test tools["milestone_update"]("DM", "Second"; due = "none") == "Milestone Second of DM: no end date."
        @test occursin("First is done", tools["milestone_done"]("DM", "First")) && occursin("open again", tools["milestone_done"]("DM", "First"; reopen = true))
        tools["milestone_activate"]("DM", "First")
        # A task sent back from review says so first, with what the person wrote.
        K.update_task!(kb, "DM-1"; status = "review", by = bot)
        K.note_task!(kb, "DM-1", "The second step misses the point."; by = me)
        K.update_task!(kb, "DM-1"; status = "ready", by = me)
        @test startswith(tools["task"]("DM-1"), "Sent back from review by Rowan, who wrote:\n> The second step misses the point.")
        K.update_task!(kb, "DM-1"; status = "in_progress", by = bot)
        @test startswith(tools["task"]("DM-1"), "Sent back")                  # while it is being reworked
        @test K.next_task(kb, "DM") == "DM-1"                                    # rework first
        K.update_task!(kb, "DM-1"; status = "review", by = bot)
        @test !startswith(tools["task"]("DM-1"), "Sent back")

        # What to work on next: approved, unblocked, highest priority first; taking it starts it.
        K.update_task!(kb, "DM-3"; status = "done", by = me)
        @test occursin("Nothing approved", tools["next_task"]("DM")) && occursin("task_wait", tools["next_task"]("DM"))
        # A project's description, set by its people, comes with work to do, not with nothing.
        K.update_project!(kb, "DM"; description = "Demo work: keep plans short.", by = me)
        @test startswith(tools["next_task"]("DM"), "Nothing approved")
        @test_throws "Only a person" K.update_project!(kb, "DM"; description = "Mine now", by = bot)
        # With nothing to do, an agent waits for people: it hears what a person does, not what agents do.
        waiter = @async tools["task_wait"]("DM"; minutes = 0.5)
        sleep(0.3)
        K.note_task!(kb, "DM-1", "Agent chatter"; by = bot)
        sleep(0.3)
        @test !istaskdone(waiter)
        @test [w.agent for w in K.agents_at_work(kb, "DM").waiting] == [K.tool_actor().name]   # shown on the board while it waits
        K.note_task!(kb, "DM-1", "Go ahead with it"; by = me)
        @test timedwait(() -> istaskdone(waiter), 10) == :ok
        heard = fetch(waiter)
        @test occursin("DM-1", heard) && occursin("Rowan wrote: Go ahead with it", heard) && !occursin("chatter", heard)
        @test startswith(tools["task_wait"]("DM"; minutes = 0.01), "Nothing from people on DM")
        K.create_task!(kb, "DM", "Low"; status = "ready", priority = 3, by = me)                    # DM-9
        @test startswith(tools["next_task"]("DM"), "## Project DM: context from its people\n\nDemo work: keep plans short.")
        K.update_project!(kb, "DM"; description = "", by = me)
        @test !startswith(tools["next_task"]("DM"), "## Project")
        # Work approved before the wait began ends it at once: approving it was not missed.
        @test startswith(tools["task_wait"]("DM"; minutes = 5.0), "In DM, waiting for you already: DM-9 is approved and unblocked")
        K.create_task!(kb, "DM", "Waiting"; status = "ready", priority = 1, by = me)                # DM-10
        K.create_task!(kb, "DM", "Urgent"; status = "ready", priority = 1, by = me)                 # DM-11
        K.link_task!(kb, "DM-5", "blocks", "DM-10"; by = me)                                         # DM-5 is open
        @test K.next_task(kb, "DM") == "DM-11"
        out = as_ada(() -> tools["next_task"]("DM"; take = true))
        @test startswith(out, "Taken: DM-11") && K.task(kb, "DM-11").status == "in_progress" && K.task(kb, "DM-11").assignee == K.AGENT_ASSIGNEE
        K.update_task!(kb, "DM-5"; status = "done", by = me)                                         # DM-10 unblocked
        @test K.next_task(kb, "DM") == "DM-10"
        @test isempty(K.agents_at_work(kb, "DM").waiting)
        # What agents are at work on: tasks in progress they changed or read lately, and those above them.
        step = K.create_task!(kb, "DM", "A step"; parent = "DM-11", status = "in_progress", by = me)
        as_ada(() -> tools["task"](step))
        at = K.agents_at_work(kb, "DM").tasks
        @test [(a.ref, a.agent, a.via) for a in at] == [(step, "Claude for Ada", ""), ("DM-11", "Claude for Ada", step)]
        K.update_task!(kb, step; status = "done", by = me)
        @test [a.ref for a in K.agents_at_work(kb, "DM").tasks] == ["DM-11"]

        # Attachments: a file on this machine by its path (for an agent running here), or its bytes.
        file = tempname() * ".png"
        write(file, UInt8[0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        @test occursin("(note ", tools["task_attach"]("DM-11"; path = file, caption = "The scan"))
        @test startswith(last(K.task(kb, "DM-11").activity).text, "The scan\n\n![The scan](media/")
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; path = file)), "⛔ A path is read on the knowledge base's machine")
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; data = K.base64encode(UInt8[5, 6]), name = "data.csv")), "Attached data.csv")
        @test occursin("[data.csv](media/", last(K.task(kb, "DM-11").activity).text)
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; data = "eA==")), "⛔ Name the file")
        # Local paths in Markdown: kept and linked by address for an agent here, refused for one elsewhere
        # (which cannot be read here) naming the upload tool; links to the site's pages are left alone.
        tools["task_note"]("DM-11", "Here: ![p]($file) and [site](/generated/kb/index.html)")
        here = last(K.task(kb, "DM-11").activity).text
        @test occursin("![p](media/", here) && occursin("[site](/generated/kb/index.html)", here)
        refused = as_ada(() -> tools["task_note"]("DM-11", "Mine: ![p]($file)"))
        @test startswith(refused, "⛔") && occursin("media_upload", refused) && !occursin("Mine:", last(K.task(kb, "DM-11").activity).text)
        @test startswith(tools["task_note"]("DM-11", "Gone: ![p](/tmp/no-such-figure.png)"), "⛔ No file /tmp/no-such-figure.png")
        # A file uploaded from elsewhere is attached by its reference.
        a = K.add_media!(kb, UInt8[0x89, 0x50, 0x4e, 0x47, 9], "wave.png"; by = "Claude for Ada", project = "DM")
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; media = a.address, caption = "The wave")), "Attached wave.png")
        # One the caller may not have (of no project they see, attached by someone else) is not there for them.
        hidden = K.add_media!(kb, UInt8[0x89, 0x50, 0x4e, 0x47, 10], "hidden.png"; by = "someone")
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; media = hidden.address)), "⛔ No file")
        @test isempty(K.query(kb, "SELECT 1 FROM media_projects WHERE hash = ?", (hidden.hash,)))
        @test occursin("![The wave]($(a.address))", last(K.task(kb, "DM-11").activity).text)
        @test startswith(as_ada(() -> tools["task_attach"]("DM-11"; media = "media/$("0"^64)/x.png")), "⛔ No file")
        # The link is the service's, or where this process serves the knowledge base.
    K.SERVED_AT[] = "http://localhost:8123"
    link = try as_ada(() -> tools["media_upload"]("DM-11"; name = "fig.png")) finally K.SERVED_AT[] = "" end
    @test occursin("curl -sS -T fig.png \"http", link)
        # Reading a task shows the agent its images, after the text.
        seen = tools["task"]("DM-11")
        @test startswith(seen, K.kaimon().KaimonGate.MCP_CONTENT_SENTINEL) && occursin("\"mimeType\":\"image/png\"", seen)
        @test !startswith(tools["task"]("DM-1"), K.kaimon().KaimonGate.MCP_CONTENT_SENTINEL)          # none to show

        # Findings: an agent drafts one from its task, cites and adds sources; a person accepts it.
        @test as_ada(() -> tools["finding_draft"]("DM", "The key papers agree on the method"; task = "DM-11",
                                                    body = "Both @arXiv:2402.00785 and @DM-1 say so.")) == "Drafted DM-F1."
        @test startswith(as_bea(() -> tools["finding_draft"]("DM", "Not mine")), "⛔ No project DM")
        @test startswith(as_ada(() -> tools["finding_evidence"]("DM-F1", "result:0.42"; detail = "[1]")), "⛔ detail is a JSON object")
        added = as_ada(() -> tools["finding_evidence"]("DM-F1", "result:0.42"; detail = "{\"notebook\": \"scan.jl\"}"))
        @test startswith(added, "Added source ")
        out = tools["finding"]("dm-f1")
        @test startswith(out, "DM-F1 [draft] The key papers agree on the method") && occursin("By Claude for Ada (agent)", out)
        @test occursin("- [", out) && occursin("] task DM-11 (Urgent)", out) && occursin("result 0.42; notebook scan.jl", out)
        @test occursin("task DM-1 (", out) && occursin(", cited", out)
        noted = as_ada(() -> tools["finding_evidence"]("DM-F1", "@DM-11"; note = "Its scan **agrees**."))
        @test startswith(noted, "Added source ") && occursin("\n  Its scan **agrees**.\n", tools["finding"]("DM-F1"))
        @test startswith(as_ada(() -> tools["finding_evidence"]("DM-F1", "@DM-11 and @DM-1")), "⛔ Name one source")
        @test as_ada(() -> tools["finding_update"]("DM-F1"; claim = "The key papers agree")) == "Updated DM-F1."
        @test occursin("DM-F1 [draft] The key papers agree", tools["findings"]("DM"))
        # Served, the answers give the addresses of the pages they name, to hand people.
        K.SERVED_AT[] = "https://kb.example.org"
        try
            at = "https://kb.example.org"
            @test endswith(tools["findings"]("DM"), "The key papers agree\n  $at/findings.html#DM-F1")
            out = tools["finding"]("DM-F1")
            @test occursin("\nPage: $at/findings.html#DM-F1\n", out) && occursin("\n  $at/projects.html#DM-11\n", out)
            @test as_ada(() -> tools["finding_update"]("DM-F1"; claim = "The key papers agree")) == "Updated DM-F1.\n  $at/findings.html#DM-F1"
            @test occursin("Page: $at/projects.html#DM-11", tools["task"]("DM-11"))   # (with images, the answer is JSON)
            @test K.document_link(kb.config, "2402.00785") == "$at/generated/kb/papers/2402-00785.html"
            @test K.document_link(kb.config, "rec-upload-a") == "$at/generated/kb/records/rec-upload-a.html"
            @test K.site_link(kb.config, "/generated/kb/code/code-kb/") == "$at/generated/kb/code/code-kb/"
        finally
            K.SERVED_AT[] = ""
        end
        K.update_finding!(kb, "DM-F1"; status = "accepted", by = me)
        @test startswith(as_ada(() -> tools["finding_update"]("DM-F1"; body = "More")), "⛔ DM-F1 is accepted")
        n = parse(Int, match(r"Added source (\d+)", added)[1])
        @test startswith(as_ada(() -> tools["finding_evidence"]("DM-F1", ""; remove = n)), "⛔ DM-F1 is not a draft")
        K.update_finding!(kb, "DM-F1"; status = "contested", reason = "Only two papers.", by = me)
        @test occursin("\nContested by Rowan: Only two papers.\n", tools["finding"]("DM-F1"))
        # Comments: an agent's, then corrected, shown in the finding's activity with its changes.
        said = as_ada(() -> tools["finding_comment"]("DM-F1", "A third paper agrees: @arXiv:2402.00785"))
        n = parse(Int, match(r"comment (\d+)", said)[1])
        @test startswith(as_ada(() -> tools["finding_comment"]("DM-F1", "A third paper agrees."; note = n)), "Edited comment")
        out = tools["finding"]("DM-F1")
        @test occursin("## Activity", out) && occursin("Claude for Ada (agent): wrote [comment $n, edited]: A third paper agrees.", out) &&
              occursin("moved it from accepted to contested: Only two papers.", out)
        # What the project found comes with its context for the next task.
        K.create_finding!(kb, "DM", "The survey covers the field"; by = bot)
        K.update_finding!(kb, "DM-F2"; status = "accepted", by = me)
        @test startswith(tools["next_task"]("DM"), "## What DM has found (read one with `finding`)\n\n- DM-F2 The survey covers the field\n" *
                                                    "- DM-F1 [contested: Only two papers.] The key papers agree\n\n---\n\n")
        @test tools["findings"]("DM"; status = "superseded") == "No findings in DM superseded."
        # Its library is counted by kind; only what people said matters is listed.
        for (key, title) in (("R1", "A data portal"), ("R2", "A news story"), ("R3", "A statistics yearbook"))
            K.put_resource!(kb, "zotero", K.Resource(; key, title, type = "dataset", projects = ["DM"]); read = false)
        end
        portal = K.resource_id("zotero", "R1")
        K.library_add!(kb, "DM", portal; why = "Where the rain records come from", by = me)
        ctx = tools["next_task"]("DM")
        @test occursin("## What DM works from\n\nIts library holds 3 resources", ctx) && occursin("`library(\"DM\")` lists them", ctx)
        @test occursin("- $portal A data portal: Where the rain records come from\n", ctx) && !occursin("A news story", ctx)
        @test occursin("- resource $portal (A data portal): Where the rain records come from", K.format_library(kb, "DM"))
    finally
        K._KB[] = nothing
        close(kb)
    end
    K.LOCAL_USER[] = saved_user
end

@zset "the site's parts, published with the dataset" begin
    # The content's notebooks, as two machines have them: the publisher's, with a notebook rendered, and a consumer's.
    function content!(c)
        nbs = mkpath(K.content_path(c, "notebooks"))
        write(joinpath(nbs, "nb.jl"), "#%% md id=a\nHello\n")
        mkpath(joinpath(nbs, "papers", "p1"))
        write(joinpath(nbs, "papers", "p1", "deep.jl"), "#%% md id=b\nDeep\n")   # a paper's
        write(joinpath(nbs, "Manifest.toml"), "resolved here: $(rand())\n")       # each machine's own
        return c
    end
    # What builds write and hidden folders are not sources; the pages' theme is, and the content.
    package = mktempdir()
    mkpath(joinpath(package, "src")); write(joinpath(package, "src", "a.jl"), "x = 1\n")
    c = content!(temp_config())
    d0 = K.site_source_digest(c; package)
    for (dir, f) in (("generated", "x.md"), (joinpath(".vitepress", "cache"), "c.js"), (".hidden", "h.md"))
        mkpath(joinpath(package, "docs", "src", dir)); write(joinpath(package, "docs", "src", dir, f), "written")
    end
    @test K.site_source_digest(c; package) == d0 && all(K.site_source_digest(c; package) == d0 for _ in 1:20)
    mkpath(joinpath(package, "docs", "src", ".vitepress", "theme"))
    write(joinpath(package, "docs", "src", ".vitepress", "theme", "overrides.css"), "a {}")
    d1 = K.site_source_digest(c; package)
    @test d1 != d0
    mkpath(K.content_path(c, "pages")); write(K.content_path(c, "pages", "about.md"), "# About")
    @test K.site_source_digest(c; package) != d1
    # Beside a build folder: the site's packages less the browser tests'; installed ones are kept until they change.
    beside = mktempdir()
    mkpath(joinpath(beside, "node_modules", "x"))
    @test K.site_packages!(beside) && !isdir(joinpath(beside, "node_modules"))
    written = K.JSON.parsefile(joinpath(beside, "package.json"))
    @test haskey(written["dependencies"], "vitepress") && !haskey(get(written, "devDependencies", Dict()), "playwright-core")
    mkpath(joinpath(beside, "node_modules", "x"))
    @test !K.site_packages!(beside) && isdir(joinpath(beside, "node_modules", "x"))
    @test !K.site_packages!(joinpath(pkgdir(K), "docs"))
    @test sort(first.(K.site_notebooks(c))) == ["deep", "nb"]
    pub = open_kb(content!(temp_config(; layers = Layer[], dataset = DatasetConfig(; stream = "pub"))))
    con = open_kb(content!(temp_config(; layers = Layer[])))
    @test K.site_source_digest(pub.config) == K.site_source_digest(con.config)
    sha = K.notebook_sha(K.content_path(pub.config, "notebooks", "nb.jl"))
    bundle = joinpath(K.slate_dir(pub.config), "nb")
    mkpath(joinpath(bundle, "cells"))
    write(joinpath(bundle, "slate-bundle.json"), K.JSON.json(Dict("schema" => 1, "inputs" => Dict("(notebook)" => sha), "cells" => [])))
    write(joinpath(bundle, "cells", "a.html"), "<p>Hello</p>")
    deep = joinpath(K.slate_dir(pub.config), "deep")
    mkpath(deep)
    write(joinpath(deep, "slate-bundle.json"),
          K.JSON.json(Dict("schema" => 1, "inputs" => Dict("(notebook)" => K.notebook_sha(K.content_path(pub.config, "notebooks", "papers", "p1", "deep.jl"))), "cells" => [])))
    add_papers!(pub, ["2609.00001"])
    # The publisher's site, built with its sources recorded.
    store = K.DirStore(mktempdir())
    K.publish!(pub; store, site_parts = true)                   # before any build: the site goes up as null
    @test K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))["site"] === nothing
    # A site like VitePress's: a page loading a script named by its content's hash, and two chunks of one name.
    page(app) = "<script src=\"/assets/app.$app.js\"></script><link href=\"/assets/chunks/index.Aaaaaaa1.js\">home"
    function build!(app)
        sleep(1)                                                    # a build is named by the second it starts
        K.build_site!(pub.config; build = (out, log) -> begin
            site = joinpath(out, "1")
            mkpath(joinpath(site, "assets", "chunks"))
            write(joinpath(site, "index.html"), page(app))
            write(joinpath(site, "assets", "app.$app.js"), "app $app")
            write(joinpath(site, "assets", "chunks", "index.Aaaaaaa1.js"), "one")
            write(joinpath(site, "assets", "chunks", "index.Bbbbbbb2.js"), "two")
            write(joinpath(site, K.DOCUMENTS_FILE), K.documents_digest(pub))         # as site.jl writes it
        end)
        return K.JSON.parsefile(dirname(K.current_site(pub.config)) * ".json")
    end
    info = build!("Xxxxxxx1")
    @test !K.site_outdated(pub.config)
    K.publish!(pub; store, site_parts = true)
    m = K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))
    @test m["notebooks"]["nb"]["notebook"] == sha && haskey(m["notebooks"], "deep") && m["site"]["build"] == info["build"]
    @test m["site"]["refs"] == Dict("assets/app.js" => "assets/app.Xxxxxxx1.js")          # the index chunks share a name
    packed = Set("site/packs/$(e["hash"]).tar.zst" for e in values(m["site"]["packs"]))
    @test Set(K.list_objects(store, "site/")) == packed
    # The consumer takes the render and serves the site, which nothing here differs from.
    K.pull!(con; store, site_parts = true)
    @test read(joinpath(K.slate_dir(con.config), "nb", "cells", "a.html"), String) == "<p>Hello</p>" && K.published_renders_current(con.config)
    @test read(joinpath(K.current_site(con.config), "index.html"), String) == page("Xxxxxxx1")
    @test K.published_site_current(con.config; db = () -> con)
    # A build whose script changed: its pack alone goes up and comes down; the page's is the same.
    build!("Yyyyyyy2")
    K.publish!(pub; store, site_parts = true)
    m2 = K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))
    changed = [n for (n, e) in m2["site"]["packs"] if e["hash"] != get(get(m["site"]["packs"], n, Dict()), "hash", "")]
    @test changed == ["runtime"]
    @test K.stable_path("assets/index.md.Cp4ouCgi.lean.js") == "assets/index.md.lean.js"
    # Files that change together share a pack: a document's page, scripts and figures; the pages
    # listing every document with the data files; VitePress's scripts that change with any change.
    s = mktempdir()
    files = Dict("generated/kb/papers/2609-00001.html" => "", "assets/generated_kb_papers_2609-00001.md.Aaaaaaa1.js" => "",
                 "assets/generated_kb_papers_2609-00001.md.Aaaaaaa1.lean.js" => "", "assets/2609-00001-1.Bbbbbbb1.png" => "",
                 "generated/kb/timeline.html" => "", "papers.json" => "", "assets/chunks/theme.Ccccccc1.js" => "",
                 "assets/chunks/index.Ddddddd1.js" => "import{a}from\"./theme.Ccccccc1.js\";",
                 "assets/chunks/index.Eeeeeee1.js" => "export const b = 1", "notes/x.html" => "")
    for (f, text) in files
        mkpath(dirname(joinpath(s, f))); write(joinpath(s, f), text)
    end
    names = K.pack_names(s, collect(keys(files)))
    @test length(unique(names[f] for f in keys(files) if occursin("2609-00001", f))) == 1 && startswith(names["assets/2609-00001-1.Bbbbbbb1.png"], "docs-")
    @test names["generated/kb/timeline.html"] == names["papers.json"] == "hub"
    @test names["assets/chunks/theme.Ccccccc1.js"] == names["assets/chunks/index.Ddddddd1.js"] == "runtime"
    @test startswith(names["assets/chunks/index.Eeeeeee1.js"], "chunks-") && startswith(names["notes/x.html"], "pages-")
    K.pull!(con; store, site_parts = true)
    @test read(joinpath(K.current_site(con.config), "index.html"), String) == page("Yyyyyyy2")
    @test length(readdir(K.site_packs_dir(con.config))) == length(m2["site"]["packs"])     # the replaced pack is gone
    # Publishing again keeps the packs of this manifest and the one before; older ones are deleted, once
    # past the grace a new one no manifest names yet has (another member's, for a manifest still to come).
    saved_grace = K.PRUNE_GRACE[]
    K.PRUNE_GRACE[] = K.Dates.Second(-1)
    build!("Zzzzzzz3")
    K.publish!(pub; store, site_parts = true)
    K.PRUNE_GRACE[] = saved_grace
    m3 = K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))
    kept = Set("site/packs/$(e["hash"]).tar.zst" for mm in (m2, m3) for e in values(mm["site"]["packs"]))
    @test Set(K.list_objects(store, "site/")) == kept && length(kept) == length(m3["site"]["packs"]) + 1
    write(joinpath(store.dir, "site", "packs", "unnamed.tar.zst"), "another member's")
    K.publish!(pub; store, site_parts = true)
    @test isfile(joinpath(store.dir, "site", "packs", "unnamed.tar.zst"))
    # A site written before the latest documents is not published with them.
    saved = K.SITE_WAIT[]
    K.SITE_WAIT[] = (start = 0.0, build = 0.0)
    add_papers!(pub, ["2609.00002"])
    K.publish!(pub; store, site_parts = true)
    @test K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))["site"] === nothing
    K.SITE_WAIT[] = saved
    # Once something differs, the site is built here: the content, or a document of one's own.
    page_file = K.content_path(con.config, "pages", "extra.md")
    mkpath(dirname(page_file)); write(page_file, "# Extra")
    @test !K.published_site_current(con.config; db = () -> con)
    rm(page_file)
    K.execute!(con, "INSERT INTO papers (doc_id, added_at) VALUES ('doc-0123456789', ?)", (K.now_iso(),))
    @test !K.published_site_current(con.config; db = () -> con)
    # A notebook changed here does not get the publisher's render; a site built from other sources is not taken.
    write(K.content_path(con.config, "notebooks", "nb.jl"), "#%% md id=a\nChanged\n")
    @test !K.published_renders_current(con.config)
    # A publisher with a document of its own not shared keeps its site to itself.
    K.execute!(pub, "INSERT INTO papers (doc_id, added_at) VALUES ('doc-0123456789', ?)", (K.now_iso(),))
    K.publish!(pub; store, site_parts = true)
    @test K.JSON.parsefile(joinpath(store.dir, "streams", "pub.json"))["site"] === nothing
    close(pub); close(con)
end

@zset "notebooks in codebases" begin
    nb = "try; import KaimonSlate; catch; end\n\n#%% md id=intro\n@md\"\"\"\n# Title\n\nWith \$x\$.\n\"\"\"\n\n#%% code id=setup\nusing Foo\nx = 1\n\n#%% code\n" *
         "\n# ╔═╡ Slate.env · notebook packages\n#   Foo 1.0.0 uuid\n# ╚═╡\n# ╔═╡ Slate.config · settings\n#   format = 2\n# ╚═╡\n"
    cells = K.slate_cells(nb)
    @test [(c.kind, c.id) for c in cells] == [("md", "intro"), ("code", "setup"), ("code", "")]
    @test cells[1].source == "# Title\n\nWith \$x\$." && cells[2].source == "using Foo\nx = 1" && cells[3].source == ""
    @test K.slate_cells("function f()\n    1\nend\n") === nothing
end

@zset "approving gives the work to whoever planned it" begin
    kb = open_kb(temp_config(layers = Layer[]))
    saved = K.LOCAL_USER[]
    K.LOCAL_USER[] = "Rowan"
    try
        me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
        K.create_project!(kb, "Approvals"; key = "AP", by = me)
        plan = K.create_task!(kb, "AP", "Survey"; subtasks = ["Search", "Read"], by = bot)
        K.update_task!(kb, plan; status = "ready", by = me)
        @test all(t -> t.assignee == K.AGENT_ASSIGNEE, [K.task(kb, plan); K.task(kb, plan).subtasks_list])
        mine = K.create_task!(kb, "AP", "Think it over"; status = "proposed", by = me)
        K.update_task!(kb, mine; status = "ready", by = me)
        @test K.task(kb, mine).assignee == "Rowan"
        given = K.create_task!(kb, "AP", "Already given"; by = bot)
        K.update_task!(kb, given; assignee = "Rowan", by = me)
        K.update_task!(kb, given; status = "ready", by = me)
        @test K.task(kb, given).assignee == "Rowan"                  # an assignee already set stays
    finally
        K.LOCAL_USER[] = saved
        close(kb)
    end
end

@zset "findings" begin
    kb = open_kb(temp_config(layers = Layer[]))
    me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    K.create_project!(kb, "Edge"; key = "ED", by = me)
    t = K.create_task!(kb, "ED", "Scan the reef crest"; by = me)
    add_papers!(kb, ["2609.00001"])
    # A claim with its evidence: a paper's passage, a computed result with where it came from, the task.
    f = K.create_finding!(kb, "ed", "RRE gives the rotation number in fewer transits";
                          body = "On the saved settling, \$\\omega\$ to 1e-7 within 70 transits.",
                          evidence = [(; kind = "paper", target = "2609.00001", excerpt = "converges faster", page = 4),
                                      Dict("kind" => "result", "target" => "media/$("a"^64)/omega.png",
                                           "detail" => Dict("notebook" => "rotation_rre.jl", "commit" => "abc123")),
                                      (; kind = "task", target = t)], by = bot)
    @test f == "ED-F1" && K.finding_parts("ed-f1") == ("ED", 1)
    x = K.finding(kb, f)
    @test x.status == "draft" && x.by_agent && [e.kind for e in x.evidence] == ["paper", "result", "task"]
    @test x.evidence[1].excerpt == "converges faster" && x.evidence[1].page == 4 && x.evidence[2].detail["commit"] == "abc123"
    @test x.evidence[3].target == t && x.versions == 0
    # Building on it, or contradicting it; nothing that does not exist.
    g = K.create_finding!(kb, "ED", "Classification needs a 1e-12 threshold"; by = me)
    @test g == "ED-F2"
    K.add_evidence!(kb, g; kind = "finding", target = "ed-f1", by = me)
    K.add_evidence!(kb, g; kind = "finding", target = f, relation = "contradicts", by = me)
    @test [(e.target, e.relation) for e in K.finding(kb, g).evidence] == [("ED-F1", "builds_on"), ("ED-F1", "contradicts")]
    @test_throws "not its own evidence" K.add_evidence!(kb, g; kind = "finding", target = g, by = me)
    @test_throws "No paper" K.add_evidence!(kb, g; kind = "paper", target = "2609.99999", by = me)
    @test_throws "No task" K.add_evidence!(kb, g; kind = "task", target = "ED-99", by = me)
    @test_throws "Only a finding is built on" K.add_evidence!(kb, g; kind = "paper", target = "2609.00001", relation = "builds_on", by = me)
    @test_throws "No finding ED-F9" K.finding(kb, "ED-F9")
    # Agents draft; people accept, contest, supersede. Every change keeps what it replaced.
    K.update_finding!(kb, f; claim = "RRE gives the rotation number in 10 to 30 times fewer transits", by = bot)
    @test_throws "Only a person accepts" K.update_finding!(kb, f; status = "accepted", by = bot)
    K.update_finding!(kb, f; status = "accepted", by = me)
    @test_throws "an agent changes only drafts" K.update_finding!(kb, f; body = "More", by = bot)
    @test_throws "an agent changes only drafts" K.remove_evidence!(kb, f, K.finding(kb, f).evidence[1].id; by = bot)
    @test_throws "an agent changes only drafts" K.add_evidence!(kb, f; kind = "paper", target = "2609.00001", relation = "contradicts", by = bot)
    @test [(v.claim, v.status, v.changed_by) for v in K.finding_versions(kb, f)] ==
          [("RRE gives the rotation number in fewer transits", "draft", "Claude for Rowan"),
           ("RRE gives the rotation number in 10 to 30 times fewer transits", "draft", "Rowan")]
    @test K.finding(kb, f).status == "accepted" && K.finding(kb, f).versions == 2
    @test_throws "A finding is" K.update_finding!(kb, f; status = "settled", by = me)
    # Comments, among its changes; a comment is corrected only by its writer, keeping what it said.
    c = K.comment_finding!(kb, f, "Does this hold at the reef crest?"; by = me)
    K.comment_finding!(kb, f, "Yes: see @ED-F2."; by = bot)
    @test_throws "Only Rowan corrects" K.edit_finding_comment!(kb, f, c, "Changed"; by = bot)
    K.edit_finding_comment!(kb, f, c, "Does this hold near the reef crest?"; by = me)
    @test_throws "A comment needs text" K.comment_finding!(kb, f, "  "; by = me)
    act = K.finding_activity(kb, f)
    @test [a.kind for a in act] == ["created", "source", "source", "source", "revised", "status", "comment", "comment"]
    @test act[5].text == "revised the claim" && act[5].who == "Claude for Rowan" && act[6].text == "moved it from draft to accepted"
    @test (act[7].text, act[7].edited, act[8].by_agent) == ("Does this hold near the reef crest?", true, true)
    @test K.JSON.parse(K.scalar(kb, "SELECT earlier FROM finding_comments WHERE id = ?", (c,)))[1]["text"] == "Does this hold at the reef crest?"
    @test [x.ref for x in K.findings(kb; project = "ED", status = "accepted")] == [f] && length(K.findings(kb; project = "ED")) == 2
    # Contesting or superseding it takes a reason, kept while it has that status and in its versions.
    @test_throws "Say why it is contested" K.update_finding!(kb, f; status = "contested", by = me)
    @test_throws "Say what supersedes it" K.update_finding!(kb, f; status = "superseded", reason = " ", by = me)
    K.update_finding!(kb, f; status = "contested", reason = "The scan used too few lines.", by = me)
    x = K.finding(kb, f)
    @test (x.status, x.status_reason, x.status_by) == ("contested", "The scan used too few lines.", "Rowan")
    K.update_finding!(kb, f; body = "With more lines.", by = me)
    @test K.finding(kb, f).status_reason == "The scan used too few lines."
    K.update_finding!(kb, f; status = "accepted", by = me)
    @test K.finding(kb, f).status_reason == "" && K.finding_versions(kb, f)[end].status_reason == "The scan used too few lines."
    K.remove_evidence!(kb, f, K.finding(kb, f).evidence[2].id; by = me)
    @test [e.kind for e in K.finding(kb, f).evidence] == ["paper", "task"]
    # Referred to as @ED-F1 in text: linked when it exists, suggested by the picker, shown to agents as it is.
    @test [(r.kind, r.target) for r in K.at_references("Builds on @ed-f1, not @ED-12.")] == [("finding", "ED-F1"), ("task", "ED-12")]
    K.note_task!(kb, t, "Concluded in @ED-F1; see also @ED-F9."; by = me)
    @test ("finding", "ED-F1") in [(l.kind, l.target) for l in K.task(kb, t).links] && !any(l -> l.target == "ED-F9", K.task(kb, t).links)
    @test any(m -> m.kind == "finding" && m.target == "ED-F2", K.at_reference_matches(kb, "classif"))
    @test K.plain_at_references("@[the scan](finding:ed-f1)") == "@ED-F1"
    # Where a finding is used: the task it came from lists it, a finding lists those building on it.
    @test [(x.ref, x.status) for x in K.task(kb, t).findings] == [(f, "accepted")]
    @test [(u.ref, u.relation) for u in K.finding(kb, f).used_by] == [(g, "builds_on"), (g, "contradicts")]
    @test occursin("## Findings from it", K.format_task(K.task(kb, t)))
    @test K.ref_project("ed-f1") == "ED" && K.ref_project("ED-12") == "ED"
    # Its sources: its evidence, then what its text cites that is not evidence; code in the project's codebase.
    K.update_finding!(kb, g; body = "Against @ED-F1, using @arXiv:2609.00001 and @[the scan](notebook:notebooks/papers/2609-00001/scan.jl), " *
                                    "@code:src/scan.jl#classify and @[Rowan](person:rowan@example.test).", by = me)
    src = K.finding_sources(kb, g)
    @test [(x.kind, x.target, x.evidence > 0, x.cited) for x in src] ==
          [("finding", "ED-F1", true, true), ("finding", "ED-F1", true, true), ("paper", "2609.00001", false, true),
           ("notebook", "notebooks/papers/2609-00001/scan.jl", false, true), ("code", "src/scan.jl#classify", false, true)]
    @test src[4].label == "the scan" && src[1].label == K.finding(kb, f).claim
    @test_throws "has no codebase" K.add_evidence!(kb, g; kind = "code", target = "src/scan.jl", by = me)
    K.add_evidence!(kb, g; kind = "notebook", target = "notebooks/papers/2609-00001/scan.jl", detail = Dict("cell" => "widths"), by = me)
    @test count(x -> x.kind == "notebook", K.finding_sources(kb, g)) == 1
    # Started from a task: the task is its first evidence.
    h = K.create_finding!(kb, "ED", "Edge scans need finer grids"; task = t, by = bot)
    @test [(e.kind, e.target) for e in K.finding(kb, h).evidence] == [("task", t)]
    @test [x.ref for x in K.waiting(kb).findings] == [h]                 # agents' drafts wait to be accepted
    # Searched by their words (kept by the index as they change), by reference, and by meaning.
    none = (_, _) -> Tuple{Int,String}[]
    found = K.search_findings(kb, "rotation transits"; meaning = none)
    @test [x.ref for x in found] == [f] && occursin("\x01", only(found).snippet)
    @test first(K.search_findings(kb, "see ed-f2"; meaning = none)).ref == g
    @test isempty(K.search_findings(kb, "rotation"; projects = ("XX",), meaning = none))
    @test isempty(K.search_findings(kb, "rotation"; status = "draft", meaning = none))
    K.update_finding!(kb, h; claim = "Edge scans need finer meshes", by = bot)
    @test [x.ref for x in K.search_findings(kb, "meshes"; meaning = none)] == [h] && isempty(K.search_findings(kb, "grids"; meaning = none))
    @test [x.ref for x in K.search_findings(kb, "unrelated words"; meaning = (kb, _) -> [(K.finding_id(kb, h), "f:0")])] == [h]
    @test Set(keys(K.finding_documents(kb))) == Set("f:$(K.finding_id(kb, x))" for x in (f, g, h))
    # Archived: kept, but out of the lists and searches until restored. Only a person archives one.
    @test_throws "Only a person" K.archive_finding!(kb, f; by = bot)
    K.archive_finding!(kb, f; by = me)
    @test !(f in [x.ref for x in K.findings(kb; project = "ED")]) && [x.ref for x in K.findings(kb; project = "ED", archived = true)] == [f]
    @test isempty(K.search_findings(kb, "rotation transits"; meaning = none)) && K.finding(kb, f).archived_by == "Rowan"
    K.archive_finding!(kb, f; restore = true, by = me)
    @test f in [x.ref for x in K.findings(kb; project = "ED")] && K.finding(kb, f).archived_at == ""
    # Deleted: only a draft nothing else cites, by a person, with its links from tasks.
    @test_throws "not a draft" K.delete_finding!(kb, f; by = me)
    @test_throws "Only a person" K.delete_finding!(kb, h; by = bot)
    K.add_evidence!(kb, g; kind = "finding", target = h, by = me)
    @test_throws "ED-F2 cites ED-F3" K.delete_finding!(kb, h; by = me)
    K.remove_evidence!(kb, g, last(K.finding(kb, g).evidence).id; by = me)
    K.note_task!(kb, t, "See @ED-F3."; by = me)
    K.delete_finding!(kb, h; by = me)
    @test_throws "No finding ED-F3" K.finding(kb, h)
    @test !any(l -> l.target == h, K.task(kb, t).links) && isempty(K.search_findings(kb, "meshes"; meaning = none))
    @test_throws "No task" K.create_finding!(kb, "ED", "Nothing"; task = "ED-99", by = bot)
    # Evidence named by an @-reference, the `@` optional, a paper with its page; with a note on what it shows.
    @test K.evidence_source("@arXiv:2609.00001#p5") == (; kind = "paper", target = "2609.00001", page = 5)
    @test K.evidence_source("2609.00001") == (; kind = "paper", target = "2609.00001", page = 0)
    @test K.evidence_source("ED-1").kind == "task" && K.evidence_source("@ed-f1").kind == "finding"
    @test K.evidence_source("@code:src/edge.jl#scan").kind == "code"
    @test_throws "Name one source" K.evidence_source("@ED-1 and @ED-F1")
    n = K.create_finding!(kb, "ED", "The scan disagrees with one paper"; by = me)
    e = K.add_evidence!(kb, n; source = "@arXiv:2609.00001#p7", relation = "contradicts", note = "Its Fig. 2 *disagrees*.", by = me)
    ev = only(x for x in K.finding(kb, n).evidence if x.id == e)
    @test (ev.kind, ev.target, ev.page, ev.relation, ev.note) == ("paper", "2609.00001", 7, "contradicts", "Its Fig. 2 *disagrees*.")
    # A paper's page lists the findings resting on it, in the projects its viewer sees.
    on = K.paper_findings(kb, "2609.00001"; projects = Set(["ED"]))
    @test (last(on).ref, last(on).page, last(on).relation, last(on).note) == (n, 7, "contradicts", "Its Fig. 2 *disagrees*.")
    @test isempty(K.paper_findings(kb, "2609.00001"; projects = Set(["XX"])))
    # Evidence that changes marks its finding for a second look, with what changed: a paper's new version,
    # a notebook changed, a finding it builds on contested. A person says it still holds, or asks an agent
    # to re-check it.
    K.execute!(kb, "UPDATE papers SET version = 'v1' WHERE doc_id = '2609.00001'")
    let
        nb = "notebooks/edge/scan.jl"
        mkpath(dirname(K.content_path(kb.config, nb))); write(K.content_path(kb.config, nb), "x = 1\n")
        up = K.create_finding!(kb, "ED", "The edge is ergodic"; by = me)
        held = K.create_finding!(kb, "ED", "The scan holds"; by = me, evidence = [(; kind = "paper", target = "2609.00001"),
                                 (; kind = "notebook", target = nb), (; kind = "finding", target = up)])
        K.check_findings!(kb)
        @test isempty(K.finding(kb, held).recheck)
        K.execute!(kb, "UPDATE papers SET version = 'v2' WHERE doc_id = '2609.00001'")
        write(K.content_path(kb.config, nb), "x = 2\n")
        K.update_finding!(kb, up; status = "accepted", by = me)
        K.update_finding!(kb, up; status = "contested", reason = "A counterexample.", by = me)
        K.check_findings!(kb)
        @test K.finding(kb, held).recheck == ["arXiv:2609.00001 has a new version, v2 (it was v1)", "$nb changed", "$up is contested"]
        @test held in [f.ref for f in K.waiting(kb).findings]
        t = K.task(kb, K.recheck_task!(kb, held; by = me))
        @test t.status == "ready" && t.assignee == "agent:Claude" && occursin("has a new version, v2", t.body)
        @test_throws "Only a person" K.keep_finding!(kb, held; by = bot)
        K.keep_finding!(kb, held; by = me)
        K.check_findings!(kb)
        @test isempty(K.finding(kb, held).recheck) && !(held in [f.ref for f in K.waiting(kb).findings])
        @test_throws "has not changed" K.recheck_task!(kb, held; by = me)
    end
    # A project's deletion takes its findings with it.
    K.delete_project!(kb, "ED")
    @test isempty(K.findings(kb)) && isempty(K.search_findings(kb, "rotation"; meaning = none))
end

@zset "a finding citing a record" begin
    kb = open_kb(temp_config(layers = Layer[]))
    try
        ada = K.person("Ada")
        K.create_project!(kb, "Pumps"; key = "PU", owner = nothing, by = ada)
        meeting(text) = (; key = "pump-test", title = "Pump test review", date = "2026-10-02", people = ["Ada", "Rowan"],
                           sections = ["Results" => text], projects = ["PU"])
        id, _ = put_record!(kb, "notes", meeting("Rowan reported the pump held three bar."); read = false)
        # A record is cited by its id, as evidence or in the text, and its version is its content's hash.
        @test only(K.at_references("As @$id said.")) == (; kind = "record", target = id, label = id)
        @test K.evidence_source("@$id") == (; kind = "record", target = id, page = 0)
        @test K.plain_at_references("See @[the review](record:$id).") == "See @$id (the review)."
        ref = K.create_finding!(kb, "PU", "The pump holds three bar"; body = "As reported in @$id.", by = ada,
                                evidence = [(; kind = "record", target = id, excerpt = "the pump held three bar")])
        f = K.finding(kb, ref)
        @test only(f.evidence).kind == "record"
        @test K.scalar(kb, "SELECT basis FROM finding_evidence") == K.record_row(kb, id).content_sha
        src = only(K.finding_sources(kb, ref))
        @test src.kind == "record" && src.label == "Pump test review, 2 October 2026" && src.cited
        @test only(K.paper_findings(kb, id; projects = ["PU"])).ref == ref
        @test only(K.findings_citing(kb, "record", id)).ref == ref
        # Named as a document, a record is still a record.
        K.add_evidence!(kb, ref; kind = "paper", target = id, note = "again", by = ada)
        @test all(e -> e.kind == "record", K.finding(kb, ref).evidence)
        @test_throws "No record rec-notes-none" K.add_evidence!(kb, ref; source = "@rec-notes-none", by = ada)
        # The picker offers the records the person may see.
        @test any(m -> m.kind == "record" && m.target == id, K.at_reference_matches(kb, "pump"))
        # Changed or gone, the finding is marked for a second look.
        put_record!(kb, "notes", meeting("Rowan reported the pump held two bar."); read = false)
        K.check_findings!(kb)
        @test K.finding(kb, ref).recheck == ["$id changed"]
        delete_record!(kb, id)
        K.check_findings!(kb)
        @test K.finding(kb, ref).recheck == ["$id is gone"]
    finally
        close(kb)
    end
end

@zset "deleting a project" begin
    # Other projects' links to its tasks go with it, so a project later given its key starts clean.
    kb = open_kb(temp_config(layers = Layer[]))
    me = K.Actor("Rowan", false)
    K.create_project!(kb, "Old"; key = "OLD", by = me); K.create_project!(kb, "Keep"; key = "KP", by = me)
    old = K.create_task!(kb, "OLD", "Gone"; by = me); keep = K.create_task!(kb, "KP", "Stays"; by = me)
    K.link_task!(kb, keep, "blocks", old; by = me); K.link_task!(kb, keep, "task", old; by = me)
    @test K.task(kb, old).blocked_by == [keep]
    K.delete_project!(kb, "OLD")
    K.create_project!(kb, "Old again"; key = "OLD", by = me)
    again = K.create_task!(kb, "OLD", "New"; by = me)
    @test again == old && isempty(K.task(kb, again).blocked_by) && isempty(K.task(kb, keep).links)
    close(kb)
end

@zset "attached files" begin
    kb = open_kb(temp_config(layers = Layer[]))
    me = K.person("Rowan")
    png = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]
    m = K.add_media!(kb, png, "../My Plot (final).png"; by = "Rowan")
    @test m.name == "My-Plot-final-.png" || m.name == "My-Plot-final.png"
    @test m.type == "image/png" && m.size == length(png) && m.address == "media/$(m.hash)/$(m.name)"
    @test isfile(K.media_path(kb.config, m.hash))
    @test K.add_media!(kb, png, "again.png"; by = "Bea").hash == m.hash && K.media_file(kb, m.hash).added_by == "Rowan"   # kept once
    @test_throws "empty" K.add_media!(kb, UInt8[], "x.png"; by = "Rowan")
    @test K.media_type("run.jl") == "text/plain; charset=utf-8" && K.media_type("clip.MP4") == "video/mp4" && K.media_type("x.bin") == "application/octet-stream"
    @test K.media_name("") == "file" && K.media_name("a/b\\c d.txt") == "c-d.txt"
    # Served with its type, kept for good, and pages run sandboxed; what a browser does not show, as a download.
    r = K.media_response(kb, m.hash, m.name)
    @test r.status == 200 && K.HTTP.header(r, "Content-Type") == "image/png" && occursin("immutable", K.HTTP.header(r, "Cache-Control")) && r.body == png
    page = K.add_media!(kb, Vector{UInt8}("<script>alert(1)</script>"), "page.html"; by = "Rowan")
    @test K.HTTP.header(K.media_response(kb, page.hash, page.name), "Content-Security-Policy") == "sandbox"
    blob = K.add_media!(kb, UInt8[1, 2, 3], "data.bin"; by = "Rowan")
    @test startswith(K.HTTP.header(K.media_response(kb, blob.hash, blob.name), "Content-Disposition"), "attachment")
    @test K.media_response(kb, "nope", "x").status == 404 && K.media_response(kb, "0"^64, "x").status == 404
    # Through the API: the bytes as the body, the name a parameter.
    up = K.handle(kb, K.HTTP.Request("POST", "/api/media?name=notes.txt", ["Content-Type" => "text/plain"], "Some notes."))
    got = K.JSON.parse(String(up.body))
    @test up.status == 200 && got["type"] == "text/plain; charset=utf-8" && startswith(got["address"], "media/")
    back = K.handle(kb, K.HTTP.Request("GET", "/api/" * got["address"]))
    @test back.status == 200 && String(back.body) == "Some notes."
    # Swept when nothing refers to it any more, after a grace period.
    K.create_project!(kb, "Media"; key = "MD", by = me)
    K.create_task!(kb, "MD", "Plot"; body = "The plot: ![plot]($(m.address))", by = me)
    later = K.Dates.now(K.Dates.UTC) + K.Dates.Day(8)
    @test K.media_in_use(kb) == Set([m.hash])
    # A finding's figure, and a result it rests on, are in use too.
    f = K.create_finding!(kb, "MD", "The page renders"; body = "See ![page]($(page.address))", by = me)
    K.add_evidence!(kb, f; kind = "result", target = got["address"], by = me)
    @test K.media_in_use(kb) == Set([m.hash, page.hash, got["address"][7:70]])
    @test K.sweep_media!(kb; now = K.Dates.now(K.Dates.UTC)) == 0                         # all still within the grace period
    @test K.sweep_media!(kb; now = later) == 1 && K.media_file(kb, m.hash) !== nothing && K.media_file(kb, blob.hash) === nothing
    @test !isfile(K.media_path(kb.config, blob.hash))
    # A file a comment on a finding shows is in use too.
    noted = K.add_media!(kb, Vector{UInt8}("A fit."), "fit.txt"; by = "Rowan")
    K.comment_finding!(kb, f, "The fit: [fit]($(noted.address))"; by = me)
    @test noted.hash in K.media_in_use(kb)
    big = K.Config(; data_dir = kb.config.data_dir, media_max_mb = 0)
    @test_throws "at most 0 MB" K.add_media!(K.KB(big, kb.db, kb.lock), UInt8[1], "x.png"; by = "Rowan")
    # With a backup: the files attached before it are caught up, each new one is copied as it is
    # attached, a file lost from disk comes back from it, and a swept file's copy goes too.
    dir = mktempdir()
    bk = K.KB(K.with_config(kb.config; media_backup = K.StoreConfig(; store = "dir:$dir")), kb.db, kb.lock)
    store = K.DirStore(dir)
    @test K.sync_media_backup!(bk) == (; uploaded = 4, restored = 0, lost = 0)
    @test K.sync_media_backup!(bk) == (; uploaded = 0, restored = 0, lost = 0)
    fresh = K.add_media!(bk, Vector{UInt8}("fresh"), "fresh.txt"; by = "Rowan")
    t0 = time()
    while !K.has_object(store, K.media_key(fresh.hash)) && time() - t0 < 10
        sleep(0.05)
    end
    @test K.has_object(store, K.media_key(fresh.hash))
    rm(K.media_path(bk.config, m.hash))
    r = K.media_response(bk, m.hash, m.name)                                            # restored as it is served
    @test r.status == 200 && r.body == png && isfile(K.media_path(bk.config, m.hash))
    rm(K.media_path(bk.config, page.hash))
    @test K.sync_media_backup!(bk) == (; uploaded = 0, restored = 1, lost = 0) && isfile(K.media_path(bk.config, page.hash))
    # A copy that does not match its hash is not taken.
    write(joinpath(dir, K.media_key(page.hash)), "changed")
    rm(K.media_path(bk.config, page.hash))
    @test !K.restore_media!(bk, page.hash) && K.sync_media_backup!(bk).lost == 1
    @test K.sweep_media!(bk; now = later) == 1 && !K.has_object(store, K.media_key(fresh.hash))
    @test K.has_object(store, K.media_key(m.hash))                                     # in use, so kept
    # Configured as [media.backup], in the form [dataset] names its store.
    cfg = joinpath(mktempdir(), "config.toml")
    write(cfg, "data_dir = \"$(kb.config.data_dir)\"\n[media.backup]\nstore = \"s3\"\nendpoint = \"https://r2.example\"\nbucket = \"kb-files\"\ncredentials = \"~/keys/files\"\n")
    c = K.load_config(cfg)
    @test c.media_backup.bucket == "kb-files" && c.media_backup.credentials == expanduser("~/keys/files")
    @test_throws "[media.backup] credentials" K.media_backup(c)
    # Files and folders named relative to the config are in its folder, wherever it is started from.
    home = mktempdir()
    rel = joinpath(home, "kb.toml")
    write(rel, "data_dir = \"data\"\nbase_set = \"base.zip\"\n[dataset]\nrole = \"none\"\nstore = \"dir:dataset\"\n" *
               "[media.backup]\nstore = \"dir:backup\"\n[shared.github_app]\nclient_id = \"Iv1\"\nprivate_key = \"app.pem\"\n")
    rc = cd(() -> K.load_config(rel), mktempdir())
    @test rc.data_dir == joinpath(home, "data") && rc.base_set == joinpath(home, "base.zip")
    @test rc.dataset.store == "dir:" * joinpath(home, "dataset") && rc.media_backup.store == "dir:" * joinpath(home, "backup")
    @test rc.shared.github_app.private_key == joinpath(home, "app.pem")
end

@zset "site components" begin
    # The modules the site's components share, run by Node with the docs' packages (test/frontend/), and
    # the components' types, checked by vue-tsc (`npm run check` in docs/).
    root = dirname(@__DIR__)
    node = Sys.which("node")
    if node === nothing || !isdir(joinpath(root, "docs", "node_modules", "markdown-it"))
        @info "Skipping the site's component tests: they need Node and the docs' packages (npm install in docs/)"
    else
        out = IOBuffer()
        tests = ["test/frontend/" * f for f in readdir(joinpath(root, "test", "frontend")) if endswith(f, ".test.mjs")]
        ok = success(pipeline(Cmd(`$node --import ./test/frontend/register.mjs --test $tests`; dir = root);
                              stdout = out, stderr = out))
        ok || print(String(take!(out)))
        @test ok
        tsc = joinpath(root, "docs", "node_modules", "vue-tsc", "bin", "vue-tsc.js")
        if isfile(tsc)
            out = IOBuffer()
            ok = success(pipeline(Cmd(`$node $tsc --noEmit -p tsconfig.json`; dir = joinpath(root, "docs")); stdout = out, stderr = out))
            ok || print(String(take!(out)))
            @test ok
        else
            @info "Skipping the components' type check: it needs vue-tsc (npm install in docs/)"
        end
    end
end

@zset "figures in both themes" begin
    RGB, Oklab = K.RGB, K.Oklab
    lab(c) = convert(Oklab, c)
    # A figure drawn on white: black text, a red line, and a colormap with a black label on it.
    W, B, R = RGB(1.0, 1.0, 1.0), RGB(0.0, 0.0, 0.0), RGB(0.85, 0.1, 0.1)
    img = fill(W, 120, 160)
    img[10:14, 10:60] .= B                                   # text
    img[30:31, 10:150] .= R                                  # a red line
    for i in 50:110, j in 80:150                             # a colormap, with a label on it
        img[i, j] = RGB((j - 80) / 70, 0.3, 1 - (j - 80) / 70)
    end
    img[70:74, 90:100] .= B
    dir = mktempdir()
    src = joinpath(dir, "fig.png")
    K.PNGFiles.save(src, img)
    t = K.theme_figures(src)
    @test t == (; light = src, dark = joinpath(dir, "fig-dark.png")) && isfile(t.dark)
    dark = K.PNGFiles.load(t.dark)
    near(c, d) = abs(lab(c).l - d.l) < 0.03
    @test near(dark[1, 1], K.THEME_COLORS.dark.bg)            # white: the dark theme's background
    @test near(dark[12, 30], K.THEME_COLORS.dark.fg)          # black text: its text
    @test abs(K.chroma(lab(dark[30, 80])) - K.chroma(lab(R))) < 0.03 && lab(dark[30, 80]).l >= K.DARK_MIN_L - 0.01
    same(a, b) = all(abs(Float64(f(a)) - Float64(f(b))) <= 2 / 255 for f in (K.Colors.red, K.Colors.green, K.Colors.blue))
    @test same(dark[90, 120], img[90, 120]) && same(dark[60, 145], img[60, 145])   # the colormap as it was
    @test lab(dark[72, 95]).l < 0.2                           # and the label on it, still black
    # Kept, and made again when the figure changes.
    made = mtime(t.dark)
    sleep(1.1); K.theme_figures(src)
    @test mtime(t.dark) == made
    sleep(1.1); K.PNGFiles.save(src, img); K.theme_figures(src)
    @test mtime(t.dark) > made

    # A figure drawn on dark gets a copy for the light theme; one drawn on neither (a photograph) none.
    dsrc = joinpath(dir, "dark.png")
    K.PNGFiles.save(dsrc, dark)
    d = K.theme_figures(dsrc)
    @test d == (; light = joinpath(dir, "dark-light.png"), dark = dsrc)
    light = K.PNGFiles.load(d.light)
    @test lab(light[1, 1]).l > 0.97 && lab(light[12, 30]).l < 0.45
    photo = joinpath(dir, "photo.png")
    K.PNGFiles.save(photo, [RGB(rand(), rand(), rand()) for _ in 1:60, _ in 1:60])
    @test K.theme_figures(photo) === nothing && !isfile(joinpath(dir, "photo-dark.png"))
    @test K.image_size(src) == (160, 120)
    # A WebP figure's copy for the other theme is WebP too.
    wsrc = joinpath(dir, "fig-w.webp")
    K.save_image(wsrc, img)
    tw = K.theme_figures(wsrc)
    @test tw == (; light = wsrc, dark = joinpath(dir, "fig-w-dark.webp")) && K.image_size(tw.dark) == (160, 120)
    @test near(K.load_image(tw.dark)[1, 1], K.THEME_COLORS.dark.bg) && near(K.load_image(tw.dark)[12, 30], K.THEME_COLORS.dark.fg)
end
