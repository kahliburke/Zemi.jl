# Searching the findings: their claims and write-ups in a full-text index kept by triggers as they
# change, ranked by BM25 with claims counting most, and fused with a ranking by meaning (see
# task_vectors.jl). Findings belong to projects, so a search names which ones it may see.

"""
    search_findings(kb, q; projects = nothing, status = "", limit = 10) -> Vector{NamedTuple}

Findings matching search `q`, best first: its words in a finding's claim or write-up, and by
meaning where the findings have been embedded, the two rankings fused; a finding named by its
reference (`KB-F3`) first. Archived findings are left out, and so are those not in `projects` (a
collection of keys; `nothing` for all) or not in `status` when given. Each is a finding as [`findings`](@ref) gives it, with `score` and
`snippet`, its matching words marked with `\\x01` … `\\x02` (the claim's start for one found by
meaning alone). `meaning` gives that ranking (for tests).
"""
function search_findings(kb::KB, q::AbstractString; projects = nothing, status::AbstractString = "", limit::Integer = 10,
                         meaning = finding_meaning_ranking)
    named = Int[]
    named_ref = Regex("\\b$(FINDING_REF.pattern)\\b")
    for m in eachmatch(named_ref, q)
        id = try finding_id(kb, m.match) catch e; reason(e) === nothing ? rethrow() : nothing end
        id === nothing || push!(named, id)
    end
    tq = parse_task_query(replace(q, named_ref => " "))
    fts = fts_query(tq)
    snippets = Dict{Int,String}()
    by_words = Int[]
    if !isempty(fts)
        rows = fts_rows(kb, """SELECT rowid AS id, snippet(finding_search, -1, char(1), char(2), '…', 16) AS snip
                               FROM finding_search WHERE finding_search MATCH ? ORDER BY bm25(finding_search, 6.0, 1.0) LIMIT 200""", (fts,))
        for r in rows
            push!(by_words, Int(r.id)); snippets[Int(r.id)] = String(r.snip)
        end
    end
    text = meaning_text(tq)
    nearest = text === nothing ? Int[] : first.(meaning(kb, text))
    ids, score = rank_found(named, by_words, nearest)
    isempty(ids) && return NamedTuple[]
    wanted(f) = isempty(f.archived_at) && (projects === nothing || f.project in projects) &&
                (isempty(status) || f.status == lowercase(strip(status)))
    out = NamedTuple[]
    for r in query(kb, FINDING_SELECT * " WHERE f.id IN ($(join(ids, ',')))")
        f = finding_row(r)
        wanted(f) || continue
        id = Int(r.id)
        push!(out, merge(f, (; score = score(id), snippet = get(snippets, id, first(f.claim, 200)))))
    end
    sort!(out; by = f -> -f.score)
    return first(out, limit)
end
