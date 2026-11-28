# Reference lists fetched for papers: a paper read here has its own, from its text (see
# `paper_references`); one known only by its abstract has the list Semantic Scholar keeps for it, or
# OpenAlex for a work Semantic Scholar does not know. Fetched lists are kept per paper and stand in
# for a list from the text until the paper is read.

migration!(33, [
    """CREATE TABLE fetched_references (
        paper_id INTEGER NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
        ord INTEGER NOT NULL,
        arxiv TEXT,
        doi TEXT,
        title TEXT NOT NULL DEFAULT '',
        authors TEXT NOT NULL DEFAULT '[]',
        year INTEGER,
        PRIMARY KEY (paper_id, ord))""",
    "CREATE INDEX fetched_references_arxiv ON fetched_references (arxiv)",
    "CREATE INDEX fetched_references_doi ON fetched_references (doi)",
    # Each paper whose list was asked for: where from, when, and how many entries were found (0 for
    # none, which is asked again after `REFETCH_EMPTY`).
    """CREATE TABLE references_fetched (
        paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
        source TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        count INTEGER NOT NULL)"""])

"How long a paper with no list found waits before it is asked about again: lists are added as papers are indexed."
const REFETCH_EMPTY = Day(30)

"""
    fetch_references!(kb, ids; force = false, s2 = s2_references, openalex = openalex_references,
                      progress, cancelled) -> (; found, unanswered, error)

Fetch the reference lists of the papers `ids` and keep them (see [`fetched_references`](@ref)):
`found` is how many papers a list was found for. Each is asked of Semantic Scholar by its arXiv id or
DOI; a paper it does not know, knows no references of, or did not answer for, is asked of OpenAlex by
its DOI (an arXiv paper's being its arXiv DOI). A paper whose list was found before is skipped unless
`force`, and one both services answered with none for is asked again after [`REFETCH_EMPTY`](@ref).

A service that is down or answers wrongly costs nothing kept: the papers it did not answer for keep
what they had and are asked again next time (`unanswered` of them, `error` saying why). Nothing is
summarized or embedded.
"""
function fetch_references!(kb::KB, ids::AbstractVector{<:AbstractString}; force::Bool = false, s2 = s2_references,
                           openalex = openalex_references, progress = msg -> nothing, cancelled = () -> false)
    since = iso_ago(REFETCH_EMPTY)
    done = Set(String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM references_fetched f JOIN papers p ON p.id = f.paper_id
                                                    WHERE f.count > 0 OR f.fetched_at >= ?""", (since,)))
    asked = Dict{String,String}()                    # each paper by what it is asked under
    for id in unique(ids)
        (force || !(id in done)) || continue
        rows = query(kb, "SELECT doi FROM papers WHERE doc_id = ?", (id,))
        isempty(rows) && continue
        p = first(rows)
        work = is_arxiv_id(id) ? "ARXIV:" * id : ismissing(p.doi) || isempty(p.doi) ? nothing : "DOI:" * normalize_doi(p.doi)
        work === nothing || (asked[id] = work)
    end
    isempty(asked) && return (; found = 0, unanswered = 0, error = "")
    errors = String[]
    key = try
        resolve_key(kb.config.semantic_scholar_key, "semantic_scholar_key")
    catch e                                          # asked without it, as with none
        push!(errors, failure_message(e))
        ""
    end
    progress("Fetching the reference lists of $(length(asked)) paper(s) from Semantic Scholar")
    s = s2(collect(values(asked)); key, progress, cancelled)
    isempty(s.error) || push!(errors, s.error)
    lists = Dict{String,Tuple{String,Vector{FetchedReference}}}()
    none = Set{String}()                             # those Semantic Scholar answered for with no list
    for (id, work) in asked
        haskey(s.found, work) || continue
        refs = s.found[work]
        refs === nothing || isempty(refs) ? push!(none, id) : (lists[id] = ("semanticscholar", refs))
    end
    rest = Dict(id => normalize_doi(startswith(work, "DOI:") ? work[5:end] : "10.48550/arxiv." * id)
                for (id, work) in asked if !haskey(lists, id))
    answered = Set{String}()                         # those OpenAlex answered for
    if !isempty(rest) && !cancelled()
        progress("Asking OpenAlex for $(length(rest)) paper(s) Semantic Scholar has no list for")
        o = openalex(collect(values(rest)); contact = kb.config.contact)
        isempty(o.error) || push!(errors, o.error)
        for (id, doi) in rest
            haskey(o.found, doi) || continue
            push!(answered, id)
            refs = o.found[doi]
            refs === nothing || isempty(refs) || (lists[id] = ("openalex", refs))
        end
    end
    at = now_iso()
    # Kept: the lists found, and "none" for those both services answered for without one.
    kept = [[(id, src, refs) for (id, (src, refs)) in lists]; [(id, "", FetchedReference[]) for id in none if id in answered && !haskey(lists, id)]]
    transaction(kb) do
        for (id, source, refs) in kept
            pid = paper_id(kb, id)
            execute!(kb, "DELETE FROM fetched_references WHERE paper_id = ?", (pid,))
            for (i, r) in enumerate(refs)
                execute!(kb, """INSERT INTO fetched_references (paper_id, ord, arxiv, doi, title, authors, year)
                                VALUES (?, ?, ?, ?, ?, ?, ?)""", (pid, i, r.arxiv, r.doi, r.title, JSON.json(r.authors), r.year))
            end
            execute!(kb, """INSERT INTO references_fetched (paper_id, source, fetched_at, count) VALUES (?, ?, ?, ?)
                            ON CONFLICT (paper_id) DO UPDATE SET source = excluded.source, fetched_at = excluded.fetched_at,
                            count = excluded.count""", (pid, source, at, length(refs)))
        end
    end
    unanswered = length(asked) - length(kept)
    unanswered > 0 && !isempty(errors) && @warn "Reference lists not fetched for $unanswered paper(s): $(join(errors, "; "))"
    return (; found = length(lists), unanswered, error = join(errors, "; "))
end

"""
    references_report(r) -> String

What a [`fetch_references!`](@ref) did, said for a job or the terminal.
"""
references_report(r) = "Reference lists found for $(r.found) paper(s)." *
    (r.unanswered > 0 && !isempty(r.error) ? " $(r.unanswered) not answered, to be asked again next time ($(r.error))." : "")

"The ids of the knowledge base's papers and uploads, those a reference list can be fetched for."
literature_ids(kb::KB) = String[r.id for r in query(kb, "SELECT doc_id AS id FROM papers WHERE $(literature_sql()) ORDER BY doc_id")]

"""
    fetched_references(kb, doc_id) -> Vector{Reference}

The reference list fetched for a paper (see [`fetch_references!`](@ref)), each entry as a reference
list's entry reads, its authors, year and title, with its arXiv id and DOI beside it.
"""
function fetched_references(kb::KB, doc_id::AbstractString)
    rows = query(kb, """SELECT f.ord, f.arxiv, f.doi, f.title, f.authors, f.year FROM fetched_references f
                        JOIN papers p ON p.id = f.paper_id WHERE p.doc_id = ? ORDER BY f.ord""", (doc_id,))
    return [Reference(; label = string(r.ord), text = fetched_text(r), arxiv = coalesce(r.arxiv, nothing), doi = coalesce(r.doi, nothing))
            for r in rows]
end

function fetched_text(r)
    names = json_list(r.authors)
    who = isempty(names) ? "" : length(names) > 3 ? join(names[1:3], ", ") * " et al." : join(names, ", ")
    return join(filter(!isempty, [who * (ismissing(r.year) ? "" : " ($(r.year))"), strip(r.title)]), ". ")
end
