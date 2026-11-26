# Ingestion events share the audit table. Each document attempt gets a durable
# identifier, including synchronous ingests that have no in-memory job.
function ingest_event!(kb, attempt, action, detail)
    execute!(kb, "INSERT INTO audit (at, who, action, target, detail) VALUES (?, 'Zemi ingestion', ?, ?, ?)",
             (now_iso(), "ingest." * action, attempt, JSON.json(detail)))
end

"Remove all history events for attempts that finished before the retention cutoff."
function prune_ingest_history!(kb; at = now(UTC))
    days = kb.config.ingestion_history_days
    days == 0 && return
    # A terminal event is the last row of its attempt. Its id also bounds the deletion
    # so an empty set of expired attempts needs no scan of the rest of the audit log.
    execute!(kb, """WITH expired AS MATERIALIZED (
                        SELECT id, target FROM audit WHERE action = 'ingest.stage'
                        AND at < strftime('%Y-%m-%dT%H:%M:%SZ', ?, ?)
                        AND json_extract(detail, '\$.stage') IN ('done', 'warning', 'failed', 'cancelled', 'interrupted'))
                    DELETE FROM audit WHERE id <= (SELECT max(id) FROM expired)
                        AND action IN ('ingest.started', 'ingest.stage')
                        AND target IN (SELECT target FROM expired)""", (iso(at), "-$days days"))
end

follow_ingest_history(kb) = every!(() -> prune_ingest_history!(kb), "Pruning ingestion history"; seconds = 3600)

"Recent ingestion attempts and their recorded stages, newest first. `before` pages by stable audit id."
function ingest_history(kb, caller; before = typemax(Int), limit = 25, doc_id = "", run = "")
    document = "json_extract(a.detail, '\$.document')"
    hidden = JSON.json(collect(hidden_documents(kb, caller)))
    # Read the page and its stages in one snapshot, including during retention cleanup.
    rows = query(kb, """WITH starts AS (
                           SELECT a.id, a.at, a.target, a.detail FROM audit a
                           JOIN papers p ON p.doc_id = $document
                           WHERE a.action = 'ingest.started' AND a.id < ? AND (? = '' OR p.doc_id = ?)
                             AND (? = '' OR json_extract(a.detail, '\$.run') = ?)
                             AND p.doc_id NOT IN (SELECT value FROM json_each(?))
                           ORDER BY a.id DESC LIMIT ?)
                       SELECT s.*, e.at AS event_at, e.detail AS event_detail FROM starts s
                       LEFT JOIN audit e ON e.target = s.target AND e.action = 'ingest.stage' AND e.id > s.id
                       ORDER BY s.id DESC, e.id""", (before, doc_id, doc_id, run, run, hidden, clamp(limit, 1, 100)))
    out = []
    for r in rows
        if isempty(out) || last(out).cursor != r.id
            start = JSON.parse(r.detail)
            push!(out, (; cursor = r.id, attempt = r.target, at = r.at, document = start["document"],
                        run = start["run"], job = start["job"], events = []))
        end
        ismissing(r.event_at) && continue
        detail = JSON.parse(r.event_detail)
        if SHARED_MODE[] && get(detail, "error", nothing) isa AbstractString
            detail["error"] = redact(detail["error"], kb.config)
        end
        push!(last(out).events, (; at = r.event_at, detail))
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
