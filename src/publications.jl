# A work has one project, a stable id and at most one draft following its published editions.
migration!(31, [
    """CREATE TABLE publications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        latest INTEGER NOT NULL DEFAULT 0,
        audience TEXT NOT NULL DEFAULT 'project' CHECK (audience IN ('project','instance')))""",
    """CREATE TABLE publication_editions (
        id INTEGER PRIMARY KEY, work INTEGER NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
        version INTEGER NOT NULL, revision TEXT NOT NULL, title TEXT NOT NULL, authors TEXT NOT NULL,
        abstract TEXT NOT NULL, body TEXT NOT NULL, date TEXT NOT NULL, changes TEXT NOT NULL,
        pdf_hash TEXT REFERENCES media(hash), prepared_by TEXT NOT NULL, published_by TEXT NOT NULL DEFAULT '',
        published_at TEXT NOT NULL DEFAULT '', UNIQUE(work,version))""",
    """CREATE VIRTUAL TABLE publication_search USING fts5(title, authors, abstract, body,
        tokenize = 'porter unicode61 remove_diacritics 2')""",
    """CREATE TRIGGER publication_unindex AFTER DELETE ON publication_editions BEGIN
        DELETE FROM publication_search WHERE rowid = old.id; END""",
    "CREATE INDEX publication_pdf ON publication_editions(pdf_hash) WHERE pdf_hash IS NOT NULL"
])

publication_url(id, version = 0) = "/publications/$id/" * (version == 0 ? "" : "v$version/")
publication_conflict() = throw(Refusal(409, "The draft has changed. Reopen it before saving or publishing."))

# Shared with the instance still respects the scope of a token issued for specific projects.
function instance_reader(caller, project)
    can(caller, "read") && (caller.projects === nothing || project in caller.projects)
end

function publication_work(kb, caller, id; editing = false)
    rows = query(kb, """SELECT w.*, p.key AS project FROM publications w
                        JOIN projects p ON p.id = w.project_id WHERE w.id = ?""", (id,))
    isempty(rows) && not_found("No such publication")
    w = only(rows)
    if editing
        need_project!(kb, caller, w.project, CONTRIBUTE)
    elseif w.latest == 0 || !(project_access(kb, caller, w.project) >= VIEW ||
                              (w.audience == "instance" && instance_reader(caller, w.project)))
        not_found("No such publication")
    end
    return w
end

function publication_edition(kb, caller, id; version = 0, editing = false)
    w = publication_work(kb, caller, id; editing)
    rows = query(kb, """SELECT version, revision, title, authors, abstract, body, date, changes,
                               pdf_hash, prepared_by, published_by, published_at
                        FROM publication_editions WHERE work = ? AND version = ?""",
                 (id, editing ? w.latest + 1 : version == 0 ? w.latest : version))
    isempty(rows) && not_found("No such edition")
    e = only(rows)
    !editing && isempty(e.published_at) && not_found("No such edition")
    return (; id = w.id, w.project, w.audience, w.latest, e..., url = publication_url(id, e.version))
end

# Search and discovery both select only the latest published edition, before ranking or limiting.
function publication_list(kb, caller; project = "", q = "", limit = -1)
    seen = collect(visible_projects(kb, caller))
    access = "p.key IN ($(in_marks(length(seen))))"
    args = Any[seen...]
    if can(caller, "read")
        scope = caller.projects
        scope_sql = scope === nothing ? "1" : "p.key IN ($(in_marks(length(scope))))"
        access *= " OR (w.audience = 'instance' AND $scope_sql)"
        scope === nothing || append!(args, scope)
    end
    extra, ranked, ordering = "", "", "e.published_at DESC, w.id DESC"
    if !isempty(project)
        extra *= " AND p.key = ?"
        push!(args, uppercase(strip(project)))
    end
    if !isempty(q)
        words = keyword_query(q)
        isempty(words) && return NamedTuple[]
        ranked = "JOIN publication_search ON publication_search.rowid = e.id"
        extra *= " AND publication_search MATCH ?"
        ordering = "bm25(publication_search, 5, 2, 2, 1), w.id"
        push!(args, words)
    end
    push!(args, limit)
    return query(kb, """SELECT w.id, p.key AS project, e.version, e.title, e.authors, e.abstract, e.published_at
                       FROM publications w JOIN projects p ON p.id = w.project_id
                       JOIN publication_editions e ON e.work = w.id AND e.version = w.latest $ranked
                       WHERE ($access) $extra ORDER BY $ordering LIMIT ?""", args)
end

function publication_source(kb, caller, address)
    m = match(MEDIA_ADDRESS, address)
    (m !== nothing && m.match == address && media_visible(kb, caller, m[1])) || not_found("No such manuscript")
    ext = lowercase(splitext(m[2])[2])
    ext in (".md", ".pdf") || error("Choose a Markdown or PDF file")
    f = media_file(kb, m[1])
    f === nothing && not_found("No such manuscript")
    path = media_path(kb.config, f.hash)
    isfile(path) || restore_media!(kb, f.hash)
    isfile(path) || not_found("Manuscript unavailable")
    if ext == ".pdf"
        open(io -> read(io, 5), path) == codeunits("%PDF-") || error("Choose a PDF manuscript")
        return (; pdf = f.hash, body = "", title = "", date = "")
    end
    text = read(path, String)
    isvalid(text) || error("Markdown must be UTF-8")
    fm = split_frontmatter(text)
    props = note_properties(fm.yaml)
    return (; pdf = missing, body = isempty(props) ? text : fm.body,
            title = string(get(props, "title", "")), date = string(get(props, "date", "")))
end

"""Save the next edition as a project draft. A revision identifies exactly the text approved for editing or release."""
function draft_publication!(kb, caller, by, project; id = 0, revision = "", title = "", authors = "",
                            abstract = "", body = "", date = "", changes = "", source = "")
    key = need_project!(kb, caller, project, CONTRIBUTE)
    return transaction(kb) do
        pdf = missing
        if !isempty(source)
            s = publication_source(kb, caller, source)
            title = isempty(strip(title)) ? s.title : title
            date = isempty(strip(date)) ? s.date : date
            body = isempty(body) ? s.body : body
            pdf = s.pdf
            ismissing(pdf) || belongs!(kb, pdf, key)
        end
        isempty(strip(title)) && error("Give the publication a title")
        if id == 0
            isempty(revision) || publication_conflict()
            id = insert_row!(kb, "INSERT INTO publications(project_id) VALUES (?)", (project_id(kb, key),))
        end
        w = publication_work(kb, caller, id; editing = true)
        w.project == key || not_found("No such publication in this project")
        previous = query(kb, "SELECT version, revision FROM publication_editions WHERE work = ? ORDER BY version DESC LIMIT 1", (id,))
        revision == (isempty(previous) ? "" : only(previous).revision) || publication_conflict()
        use_media!(kb, key, body)
        next = w.latest + 1
        token = string(uuid4())
        execute!(kb, """INSERT INTO publication_editions
            (work,version,revision,title,authors,abstract,body,date,changes,pdf_hash,prepared_by)
            VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(work,version) DO UPDATE SET
            revision=excluded.revision,title=excluded.title,authors=excluded.authors,abstract=excluded.abstract,
            body=excluded.body,date=excluded.date,changes=excluded.changes,pdf_hash=excluded.pdf_hash,
            prepared_by=excluded.prepared_by""",
            (id,next,token,strip(title),strip(authors),strip(abstract),body,strip(date),strip(changes),pdf,by.name))
        return publication_edition(kb, caller, id; editing = true)
    end
end

function publish_publication!(kb, caller, by, id, revision; audience = "project")
    return transaction(kb) do
        w = publication_work(kb, caller, id; editing = true)
        audience in ("project", "instance") || error("Choose project or instance")
        audience == "instance" && need_project!(kb, caller, w.project, MAINTAIN)
        w.latest == 0 || w.audience == audience || error("Keep the audience chosen for the first edition")
        rows = query(kb, "SELECT * FROM publication_editions WHERE work = ? AND revision = ?", (id, revision))
        isempty(rows) && publication_conflict()
        e = only(rows)
        if isempty(e.published_at)
            isempty(e.authors) && error("Name the authors before publishing")
            isempty(e.abstract) && error("Add an abstract before publishing")
            isempty(strip(e.body)) && ismissing(e.pdf_hash) && error("Add a manuscript before publishing")
            e.version > 1 && isempty(e.changes) && error("Describe what changed in this version")
            execute!(kb, "UPDATE publication_editions SET published_at = ?, published_by = ? WHERE id = ?",
                     (now_iso(), by.name, e.id))
            execute!(kb, "UPDATE publications SET latest = ?, audience = ? WHERE id = ?", (e.version, audience, id))
            execute!(kb, "INSERT INTO publication_search(rowid,title,authors,abstract,body) VALUES (?,?,?,?,?)",
                     (e.id,e.title,e.authors,e.abstract,e.body))
        end
        return publication_edition(kb, caller, id; version = e.version)
    end
end
