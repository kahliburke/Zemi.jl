# Ingestion events share the append-only audit log. Each document attempt gets a durable
# identifier, including synchronous ingests that have no in-memory job.
function ingest_event!(kb, attempt, action, detail)
    execute!(kb, "INSERT INTO audit (at, who, action, target, detail) VALUES (?, 'Zemi ingestion', ?, ?, ?)",
             (now_iso(), "ingest." * action, attempt, JSON.json(detail)))
end

"Recent ingestion attempts and their recorded stages, newest first. `before` pages by stable audit id."
function ingest_history(kb, caller; before = typemax(Int), limit = 25, doc_id = "", run = "")
    document = "json_extract(a.detail, '\$.document')"
    hidden = JSON.json(collect(hidden_documents(kb, caller)))
    starts = query(kb, """SELECT a.id, a.at, a.target, a.detail FROM audit a
                          JOIN papers p ON p.doc_id = $document
                          WHERE a.action = 'ingest.started' AND a.id < ? AND (? = '' OR p.doc_id = ?)
                            AND (? = '' OR json_extract(a.detail, '\$.run') = ?)
                            AND p.doc_id NOT IN (SELECT value FROM json_each(?))
                          ORDER BY a.id DESC LIMIT ?""", (before, doc_id, doc_id, run, run, hidden, clamp(limit, 1, 100)))
    out = []
    for r in starts
        start = JSON.parse(r.detail)
        push!(out, (; cursor = r.id, attempt = r.target, at = r.at, document = start["document"],
                    run = start["run"], job = start["job"], events = []))
    end
    isempty(out) && return out
    events = Dict(x.attempt => x.events for x in out)
    for r in query(kb, """SELECT target, at, detail FROM audit WHERE id > ? AND action = 'ingest.stage'
                          AND target IN ($(in_marks(length(out)))) ORDER BY id""", (last(starts).id, keys(events)...))
        detail = JSON.parse(r.detail)
        if SHARED_MODE[] && get(detail, "error", nothing) isa AbstractString
            detail["error"] = redact(detail["error"], kb.config)
        end
        push!(events[r.target], (; at = r.at, detail))
    end
    return out
end

# Re-parsing may remove the highest rowid before new summaries are written. Compare
# each unit with its old row to count replacements and leave cached summaries out.
function summary_rows(kb, id, s)
    return query(kb, """SELECT rowid AS revision, unit_key, input_sha, input_tokens, output_tokens
                        FROM summaries WHERE paper_id = ? AND summarizer = ?""", (paper_id(kb, id), s.name))
end

function summary_usage_marker(kb, id, s)
    return Dict(r.unit_key => (r.revision, r.input_sha) for r in summary_rows(kb, id, s))
end

function ingest_summary_usage(kb, id, s, marker)
    changed = filter(r -> get(marker, r.unit_key, nothing) != (r.revision, r.input_sha), summary_rows(kb, id, s))
    function reported(values)
        known = collect(skipmissing(values))
        return isempty(known) ? nothing : sum(known)
    end
    return (; model = s.model, summarizer = s.name, summaries = length(changed),
            input = reported(r.input_tokens for r in changed), output = reported(r.output_tokens for r in changed))
end
