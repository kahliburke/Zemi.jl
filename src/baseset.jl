# A base set: papers a group has shared, as one file, so a new knowledge base (a colleague's machine,
# a new service) starts with them without any arXiv requests (the config's
# `base_set`). It holds each paper's arXiv metadata and where it was posted; PDFs, parses, summaries
# and vectors are made by ingesting.

"""
    export_base_set(kb, path; source)

Write every arXiv paper in the knowledge base that was posted in `source`, with its metadata and
posts, to `path` as JSON, oldest post first.
"""
function export_base_set(kb::KB, path::AbstractString; source::AbstractString)
    rows = query(kb, """
        SELECT p.*, min(m.posted_at) AS first_posted FROM papers p JOIN mentions m ON m.paper_id = p.id
        WHERE m.source = ? AND p.metadata_at IS NOT NULL GROUP BY p.id ORDER BY first_posted""", (source,))
    papers = map(rows) do p
        posts = query(kb, "SELECT channel, posted_at, author, url FROM mentions WHERE paper_id = ? AND source = ? ORDER BY posted_at",
                      (p.id, source))
        Dict("doc_id" => p.doc_id, "version" => coalesce(p.version, ""), "title" => p.title,
             "authors" => json_list(p.authors), "published" => p.published, "updated" => p.updated,
             "primary_category" => p.primary_category, "categories" => json_list(p.categories),
             "doi" => coalesce(p.doi, nothing), "journal_ref" => coalesce(p.journal_ref, nothing),
             "abstract" => p.abstract,
             "posts" => [Dict("channel" => coalesce(m.channel, nothing), "posted_at" => m.posted_at,
                              "author" => coalesce(m.author, nothing), "url" => m.url) for m in posts])
    end
    mkpath(dirname(path))
    open(io -> JSON.json(io, Dict("source" => source, "exported" => now_iso(), "papers" => papers); pretty = true), path, "w")
    return length(papers)
end

"""
    seed!(kb, path = kb.config.base_set) -> Int

Record the papers of a base set, with their metadata and posts, returning how many were new.
Papers already in the knowledge base are left as they are; nothing is fetched.
"""
function seed!(kb::KB, path::AbstractString = kb.config.base_set)
    data = JSON.parsefile(path)
    source = get(data, "source", "added")
    added = 0
    transaction(kb) do
        for p in data["papers"]
            ismissing(paper_id(kb, p["doc_id"])) || continue
            execute!(kb, """
                INSERT INTO papers (doc_id, version, title, abstract, authors, published, updated, primary_category,
                                    categories, doi, journal_ref, metadata_at, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (p["doc_id"], p["version"], p["title"], p["abstract"], JSON.json(p["authors"]), p["published"],
                 p["updated"], p["primary_category"], JSON.json(p["categories"]), something(p["doi"], missing),
                 something(p["journal_ref"], missing), now_iso(), now_iso()))
            pid = paper_id(kb, p["doc_id"])
            for m in p["posts"]
                execute!(kb, """
                    INSERT OR IGNORE INTO mentions (paper_id, source, channel, posted_at, author, url, message)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)""",
                    (pid, source, something(m["channel"], missing), m["posted_at"], something(m["author"], missing), m["url"]))
            end
            added += 1
        end
    end
    return added
end
