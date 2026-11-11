# Managing the documents in the knowledge base: finding them, and redoing any step of the pipeline for
# them. The site's Manage page and the tools call these.

"""
    list_documents(kb; q = "", state = "", except = Set(), limit = 50, offset = 0) -> (; total, documents)

Documents most recently posted or added first. `q` matches words of the title, authors or id;
`state` is `"recorded"` (not read yet), `"read"` (parsed), `"uploaded"`, a kind of document's name
(`"code"`, `"record"`, see [`DocumentKind`](@ref)), `"unsummarized"` (read but without summaries) or
`"unembedded"` (read but without vectors). Those in `except` (the documents someone may not see, see
[`hidden_documents`](@ref)) are left out. Each document comes with what has been done to it, who may
see it and the projects it is linked to (see document_access.jl).
"""
function list_documents(kb::KB; q::AbstractString = "", state::AbstractString = "", except = Set{String}(), limit::Integer = 50,
                        offset::Integer = 0)
    rows = query(kb, """
        SELECT p.id, p.doc_id, p.title, p.authors, p.published, p.primary_category, p.kind, p.access, p.added_at,
               (SELECT max(posted_at) FROM mentions m WHERE m.paper_id = p.id) AS posted,
               (SELECT count(*) FROM parses x WHERE x.paper_id = p.id) AS parsed,
               (SELECT count(*) FROM chunks c WHERE c.paper_id = p.id) AS passages,
               (SELECT count(DISTINCT layer) FROM embeddings e WHERE e.paper_id = p.id) AS layers,
               (SELECT count(*) FROM summaries s WHERE s.paper_id = p.id) AS summaries
        FROM papers p ORDER BY coalesce(posted, 0) DESC, p.added_at DESC""")
    words = [lowercase(w) for w in split(q) if !isempty(w)]
    matches(r) = all(w -> occursin(w, lowercase(string(coalesce(r.title, ""), " ", coalesce(r.authors, ""), " ", r.doc_id))), words)
    in_state(r) = state == "" ||
        (state == "recorded" && r.parsed == 0) || (state == "read" && r.parsed > 0) ||
        (state == "uploaded" && is_upload(r.doc_id)) ||
        state == r.kind || (state == "unsummarized" && r.parsed > 0 && r.summaries == 0) ||
        (state == "unembedded" && r.parsed > 0 && r.layers == 0)
    found = filter(r -> !(r.doc_id in except) && matches(r) && in_state(r), rows)
    page = found[min(offset + 1, end + 1):min(offset + limit, end)]
    docs = [(; id = r.doc_id, slug = page_slug(r.doc_id), page = document_page(r.doc_id), title = coalesce(r.title, r.doc_id),
               authors = json_list(r.authors), published = coalesce(r.published, ""),
               category = coalesce(r.primary_category, ""), kind = r.kind, access = r.access,
               projects = is_kind(k -> k.access, r.doc_id) ? document_projects(kb, r.doc_id) : String[],
               posted = ismissing(r.posted) ? "" : Dates.format(unix2datetime(r.posted), "yyyy-mm-dd"),
               parsed = r.parsed > 0, r.passages, r.layers, r.summaries) for r in page]
    return (; total = length(found), documents = docs)
end

"""
    reindex!(kb, ids; progress, cancelled) -> Vector

Read documents again from the start: parse, chunk, summarize what changed, and embed, even when
nothing seems to have changed.
"""
reindex!(kb::KB, ids::AbstractVector{<:AbstractString}; kw...) = ingest!(kb, ids; force_parse = true, kw...)

"""
    resummarize!(kb, ids; progress, cancelled) -> Vector

Write every summary of these documents again, and embed the new summaries.
"""
function resummarize!(kb::KB, ids::AbstractVector{<:AbstractString}; kw...)
    for id in ids
        execute!(kb, "DELETE FROM summaries WHERE paper_id = ?", (paper_id(kb, id),))
    end
    return ingest!(kb, ids; kw...)
end

const CLASSIFY_SYSTEM = "You classify research documents for a research group's knowledge base, and read their " *
                        "metadata. Reply with a JSON object only."

function classify_prompt(p, front::AbstractString, summary::AbstractString, categories, group::AbstractString)
    known = join(("$c ($(category_title(c)))" for c in categories), ", ")
    """
    The group: $group

    Title: $(coalesce(p.title, ""))
    Authors on record: $(join(json_list(p.authors), ", "))
    Abstract on record: $(first(coalesce(p.abstract, ""), 2000))
    Summary on record: $(first(summary, 2500))

    Opening text of the document:
    $front

    Reply with a JSON object with these fields:
    - "document_type": one of "journal article", "conference paper", "preprint", "review", "thesis",
      "technical report", "book chapter", "lecture notes", "software", "other".
    - "venue": the journal, conference or institution it appeared in, as printed, or null.
    - "year": the year it was published or written, as a number, or null.
    - "authors": the authors' names as printed, in order (an empty list if none are shown).
    - "affiliations": the authors' institutions as printed (an empty list if none are shown).
    - "abstract": the abstract as printed, or a two-sentence description if it has none.
    - "category": the one category that fits best, from: $known. Use "code" for software, and a category
      not in the list only if none fits.
    - "secondary_categories": up to three more categories that also fit, in the same form.
    - "research_areas": 2-5 fields of research it belongs to, in plain words.
    - "methods": 2-6 methods, techniques or tools it uses or develops, specific to this document.
    - "applications": 1-4 systems or problems it is applied to.
    - "keywords": 5-12 specific keywords a researcher would search for.
    - "one_line": one sentence saying what the document contributes.
    - "relevance": how relevant it is to the group described above, from 0 (unrelated) to 3 (central).
    - "relevance_note": one or two sentences on how it relates to the group's work.
    """
end

"""
    classify!(kb, id; summarizer = kb.config.summarizer) -> Dict

Have an LLM classify a document from its opening text, abstract and summary: its type and venue,
categories, research areas, methods, applications, keywords, a one-line description, and how
relevant it is to the group (the config's `group_description`). The classification is stored and
returned. Authors, year and abstract are copied to the document's record where it has none, and
the category where it has none (an arXiv paper keeps arXiv's).
"""
function classify!(kb::KB, id::AbstractString; summarizer = kb.config.summarizer)
    is_kind(k -> k.classified, id) || error("$id is a $(document_kind(id).noun): documents of its kind are not classified")
    s = Zemi.summarizer(kb.config, summarizer)
    p = paper_row(kb, id)
    front = join((r.text for r in query(kb, "SELECT text FROM blocks WHERE paper_id = ? ORDER BY ord LIMIT 40", (p.id,))), "\n")
    summary = coalesce(scalar(kb, "SELECT text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%' AND summarizer = ?",
                              (p.id, something(shown_summarizer(kb, id), ""))), "")
    categories = sort!(unique([collect(keys(ARXIV_CATEGORIES)); [r.c for r in query(kb,
        "SELECT DISTINCT primary_category AS c FROM papers WHERE primary_category IS NOT NULL AND primary_category != ''")]]))
    text = try
        ask(s, CLASSIFY_SYSTEM, classify_prompt(p, first(front, 6000), summary, categories, kb.config.group.description))
    catch e
        e isa InterruptException || note_summary!(s.name, e)
        rethrow()
    end
    note_summary!(s.name)
    c = reply_json(text, "The classifier")
    has(x) = !ismissing(x) && !isempty(strip(string(x)))
    authors = isempty(json_list(p.authors)) ? String.(get(c, "authors", String[])) : json_list(p.authors)
    year = get(c, "year", nothing)
    published = has(p.published) ? p.published : year isa Integer ? "$year" : missing
    abstract = has(p.abstract) ? p.abstract : (a = get(c, "abstract", nothing); has(something(a, "")) ? String(a) : missing)
    # arXiv's categories stand for an arXiv paper; a kind with a category of its own takes it (a
    # codebase is "code"); anything else takes the LLM's.
    llm = String(something(get(c, "category", nothing), ""))
    arxiv = is_arxiv_id(id) && has(p.primary_category)
    kind = document_kind(id)
    category = kind !== nothing && kind.category !== nothing ? kind.category : arxiv ? p.primary_category : llm
    categories_list = arxiv ? json_list(p.categories) :
                      unique([category; String.(something(get(c, "secondary_categories", nothing), String[]))])
    transaction(kb) do
        execute!(kb, """UPDATE papers SET primary_category = ?, categories = ?, authors = ?, published = ?, abstract = ?
                        WHERE id = ?""", (category, JSON.json(categories_list), JSON.json(authors), published, abstract, p.id))
        execute!(kb, "INSERT OR REPLACE INTO classifications VALUES (?, ?, ?, ?, ?)",
                 (p.id, s.name, s.model, JSON.json(c), now_iso()))
    end
    return c
end

"""
    classification(kb, id) -> Union{Dict,Nothing}

A document's stored classification (see [`classify!`](@ref)), or `nothing`.
"""
function classification(kb::KB, id::AbstractString)
    d = scalar(kb, "SELECT data FROM classifications WHERE paper_id = ?", (paper_id(kb, id),))
    return ismissing(d) ? nothing : JSON.parse(d)
end

const RELEVANCE = ("unrelated", "peripheral", "related", "central")

"A classification as lines of text."
function format_classification(c::AbstractDict)
    field(k) = (v = get(c, k, nothing); v === nothing ? "" : v isa AbstractVector ? join(v, ", ") : string(v))
    lines = String[]
    add(label, k) = (v = field(k); isempty(v) || push!(lines, "$label: $v"))
    add("Type", "document_type"); add("Venue", "venue"); add("Year", "year")
    add("Category", "category"); add("Also", "secondary_categories")
    add("Research areas", "research_areas"); add("Methods", "methods"); add("Applications", "applications")
    add("Keywords", "keywords"); add("In one line", "one_line")
    r = get(c, "relevance", nothing)
    r isa Integer && 0 <= r <= 3 && push!(lines, "Relevance to the group: $r ($(RELEVANCE[r+1])). $(field("relevance_note"))")
    return join(lines, "\n")
end
