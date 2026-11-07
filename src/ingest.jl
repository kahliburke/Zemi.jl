"""
    add_papers!(kb, ids; source = "added", by = nothing, anyway = false) -> Vector{String}

Record papers by arXiv id (URLs and `arXiv:` references are accepted too) without fetching
anything. Returns the normalized ids. A paper new to the knowledge base gets a mention of how it
came: `source` is one of [`ARRIVALS`](@ref) or a registered source's name (see
[`record_source!`](@ref)), and `by` who added it, where known.

A paper a person dropped (see [`drop!`](@ref)) is left out when a source brings it, and refused with
a [`DroppedError`](@ref) when a person adds it by hand ([`BY_HAND`](@ref)), unless `anyway`, which
restores it.
"""
function add_papers!(kb::KB, ids::AbstractVector{<:AbstractString}; source::AbstractString = "added", by = nothing,
                     anyway::Bool = false)
    source in keys(ARRIVALS) || registered_source(source) !== nothing || error("Not a way a paper arrives: $source")
    out = String[]
    transaction(kb) do
        for s in ids
            if local_kind(s) !== nothing
                ismissing(paper_id(kb, s)) && not_found("No document $s in the knowledge base")
                push!(out, String(s))
                continue
            end
            id = parse_arxiv_id(s)
            id === nothing && error("Not an arXiv id or URL: $s")
            new = ismissing(paper_id(kb, id.id))
            d = new ? dropped_as(kb; id = id.id) : nothing
            if d !== nothing
                source in BY_HAND || continue                    # a source's: left out
                anyway || throw(DroppedError(d))
                restore!(kb, d.id; by)
            end
            execute!(kb, "INSERT OR IGNORE INTO papers (doc_id, version, added_at) VALUES (?, ?, ?)",
                (id.id, id.version, now_iso()))
            new && record_arrival!(kb, paper_id(kb, id.id), source, by)
            push!(out, id.id)
        end
    end
    return unique!(out)
end

"""
How papers come into the knowledge base, as their mentions' `source`, with how the site words each:
uploads are recorded where they are read, the rest by [`add_papers!`](@ref). A mention from
elsewhere (a base set's posts in a channel, say) is worded by its source and channel.
"""
const ARRIVALS = Dict("upload" => "uploaded", "added" => "added",
                      "cited" => "added from citations", "watch" => "added from the arXiv watch",
                      "daily" => "picked as paper of the day", "study" => "found for a study")

"The ways in of [`ARRIVALS`](@ref) that are a person's, who is told a paper was dropped rather than it being left out."
const BY_HAND = ("added", "upload", "cited")

"""
    mentions(kb, doc_id) -> Vector{NamedTuple}

How a document came and where it was posted: each mention's source, channel, time, author, address
and message, oldest first.
"""
function mentions(kb::KB, doc_id::AbstractString)
    rows = query(kb, """
        SELECT m.source, m.channel, m.posted_at, m.author, m.url, m.message FROM mentions m
        JOIN papers p ON p.id = m.paper_id WHERE p.doc_id = ? ORDER BY m.posted_at""", (doc_id,))
    return [(; r.source, r.channel, posted = unix2datetime(r.posted_at), r.author, r.url, r.message) for r in rows]
end

"""
    local_user() -> Union{String,Nothing}

Who runs this knowledge base, as git knows them (`git config user.name`), taken as who adds papers and
notebooks through its site. `nothing` where git has no name.
"""
function local_user()
    ismissing(LOCAL_USER[]) || return LOCAL_USER[]
    name = try strip(readchomp(`git config user.name`)) catch; "" end
    return LOCAL_USER[] = isempty(name) ? nothing : String(name)
end
const LOCAL_USER = Ref{Union{String,Nothing,Missing}}(missing)

"Note that paper `pid` came into the knowledge base by `source` (see [`ARRIVALS`](@ref)), from `by` if known."
record_arrival!(kb::KB, pid, source::AbstractString, by = nothing) =
    execute!(kb, """INSERT OR IGNORE INTO mentions (paper_id, source, channel, posted_at, author, url, message)
                    VALUES (?, ?, NULL, ?, ?, NULL, NULL)""", (pid, source, time(), something(by, missing)))

"""
    add_pdf!(kb, path; title = nothing, authors = String[], abstract = nothing, published = nothing,
             added_by = nothing, source = "upload", anyway = false) -> String

Add a paper that is not on arXiv from its PDF, returning its id: `doc-` and the start of the file's
SHA-256, so adding the same file again gives the same paper. The file is copied into the data
directory, where [`ingest!`](@ref) finds it like a downloaded one. A title or abstract not given
is taken from the parsed PDF: the largest type on the first page, and the text under or after
an "Abstract" heading. Its arrival is recorded as a mention from `source`, with `added_by` who added
it where given.

A paper is not added twice. An arXiv PDF (its first page stamped with its id, see
[`arxiv_stamp`](@ref)) is added as that arXiv paper; a PDF whose published record has the DOI of a
paper here (from arXiv, or uploaded before as another file) gives that paper's id, and adds nothing.
One a person dropped, as this file, as its arXiv paper or by its DOI, is refused with a
[`DroppedError`](@ref), unless `anyway`, which restores it.
"""
function add_pdf!(kb::KB, path::AbstractString; title = nothing, authors::AbstractVector{<:AbstractString} = String[],
                  abstract = nothing, published = nothing, added_by = nothing, source::AbstractString = "upload",
                  anyway::Bool = false)
    startswith(String(read(path, 5)), "%PDF") || error("$path is not a PDF")
    stamp = arxiv_stamp(path, kb.config)
    if stamp !== nothing
        ismissing(paper_id(kb, stamp)) && keep_out!(kb, anyway; by = added_by, id = stamp)
        return only(add_papers!(kb, [stamp]; source, by = added_by))
    end
    sha = bytes2hex(open(sha256, path))
    id = PAPER.prefix * sha[1:10]
    ismissing(paper_id(kb, id)) && keep_out!(kb, anyway; by = added_by, id)
    dest = joinpath(pdf_dir(kb.config), pdf_filename(id, ""))
    copied = !isfile(dest)
    copied && cp(path, dest)
    parsed = parse_pdf(dest, kb.config)
    # Its published record, looked for before it is recorded so that a paper already here is not.
    looked, rec = false, nothing
    if ismissing(paper_id(kb, id))
        # Waited for a while only, as an upload waits on it: one slower is left for `heal_uploads!`.
        lookup = Threads.@spawn UPLOAD_LOOKUP[](parsed; contact = kb.config.contact)
        if timedwait(() -> istaskdone(lookup), UPLOAD_LOOKUP_WAIT[]) == :timed_out
            @warn "The published record of $id took longer than $(UPLOAD_LOOKUP_WAIT[]) s to look up; it is looked up again later"
        else
            try
                rec = fetch(lookup)
                looked = true
            catch e
                @warn "Could not look up the published record of $id" exception = e
            end
        end
        if rec !== nothing && rec.doi !== nothing
            try
                keep_out!(kb, anyway; by = added_by, doi = rec.doi)
            catch
                copied && rm(dest; force = true)
                rethrow()
            end
        end
        same = rec === nothing || rec.doi === nothing ? missing : paper_with_doi(kb, rec.doi)
        if !ismissing(same)
            copied && rm(dest; force = true)
            return same
        end
    end
    given = (; title, abstract, published, authors = isempty(authors) ? nothing : JSON.json(authors))
    title = something(title, parsed_title(parsed), splitext(basename(path))[1])
    abstract = something(abstract, parsed_abstract(parsed), "")
    cited = parsed_citation(parsed)
    published = something(published, cited === nothing ? missing : cited.year)
    transaction(kb) do
        if ismissing(paper_id(kb, id))
            execute!(kb, """
                INSERT INTO papers (doc_id, version, title, abstract, authors, published, primary_category,
                                    categories, journal_ref, metadata_at, added_at)
                VALUES (?, '', ?, ?, ?, ?, '', '[]', ?, ?, ?)""",
                (id, title, abstract, JSON.json(authors), published, cited === nothing ? missing : cited.ref,
                 now_iso(), now_iso()))
        else
            # Uploaded again: its record stays as it is (healed from its published one, perhaps), but
            # for what the upload gave itself.
            for (k, v) in pairs(given)
                v === nothing || execute!(kb, "UPDATE papers SET $k = ? WHERE doc_id = ?", (v, id))
            end
        end
        pid = paper_id(kb, id)
        ismissing(scalar(kb, "SELECT 1 FROM mentions WHERE paper_id = ? AND source = ?", (pid, source))) && execute!(kb, """
            INSERT INTO mentions (paper_id, source, channel, posted_at, author, url, message)
            VALUES (?, ?, NULL, ?, ?, NULL, ?)""", (pid, source, time(), something(added_by, missing), basename(path)))
    end
    # A lookup that failed is left for heal_uploads! to try again.
    looked && heal_upload!(kb, id; parsed, lookup = (_; contact) -> rec)
    return id
end

"""
    add_doi!(kb, doi; title = nothing, authors = String[], published = nothing, source = "added", by = nothing, anyway = false)
        -> Union{String,Nothing}

Add the paper with DOI `doi` to be read in full, returning its id: the paper here with that DOI; else
its arXiv copy, as that arXiv paper, which OpenAlex knows or a search of arXiv for `title` finds (see
[`arxiv_copy`](@ref)); else the first of the open PDFs of it OpenAlex knows that is one (see [`doi_copies`](@ref)),
added as [`add_pdf!`](@ref) does with `title`, `authors` and `published` where given. `nothing` when
there is no copy to read, as for a closed paper. Its arrival is a mention from `source`, as `by` added
it. It is not read here (see [`ingest!`](@ref)). A work a person dropped is refused with a
[`DroppedError`](@ref), unless `anyway`, which restores it.
"""
function add_doi!(kb::KB, doi::AbstractString; title = nothing, authors::AbstractVector{<:AbstractString} = String[],
                  published = nothing, source::AbstractString = "added", by = nothing, anyway::Bool = false)
    d = normalize_doi(doi)
    isempty(d) && error("Not a DOI: $(repr(doi))")
    here = paper_with_doi(kb, d)
    ismissing(here) || return here
    keep_out!(kb, anyway; by, doi = d)
    c = DOI_COPIES[](d; contact = kb.config.contact)
    arxiv = c.arxiv
    arxiv === nothing && title !== nothing && (arxiv = arxiv_copy(kb.config, title; doi = d, authors))
    if arxiv !== nothing
        ismissing(paper_id(kb, arxiv)) && keep_out!(kb, anyway; by, id = arxiv)
        return only(add_papers!(kb, [arxiv]; source, by))
    end
    for url in c.pdfs
        body = open_pdf(url)
        body === nothing && continue
        path = tempname() * ".pdf"
        try
            write(path, body)
            id = add_pdf!(kb, path; title, authors, published, added_by = by, source, anyway)
            execute!(kb, "UPDATE papers SET doi = ? WHERE doc_id = ? AND doi IS NULL", (d, id))
            return id
        finally
            rm(path; force = true)
        end
    end
    isempty(c.pdfs) || @info "None of the open copies of $d could be read" copies = c.pdfs
    return nothing
end

# The PDF at `url`, or `nothing` when it is not one: a publisher's page in place of the file, a
# sign-in it sends the request round, a refusal.
function open_pdf(url::AbstractString)
    r = try
        HTTP.get(url; status_exception = false, connect_timeout = 20, readtimeout = 120, redirect_limit = 5)
    catch e
        e isa InterruptException && rethrow()
        @warn "An open copy could not be fetched" url exception = e
        return nothing
    end
    return r.status == 200 && length(r.body) > 4 && String(r.body[1:5]) == "%PDF-" ? r.body : nothing
end

"""
    arxiv_copy(config, title; doi, authors = String[]) -> Union{String,Nothing}

The arXiv id of the work titled `title`, found by searching arXiv for the title: a paper whose title is
the same and that names `doi` or shares one of `authors`' surnames (any paper of the same title, with
no authors given). `nothing` for none, and when arXiv's search does not answer.
"""
function arxiv_copy(c::Config, title::AbstractString; doi::AbstractString, authors::AbstractVector{<:AbstractString} = String[])
    found = try
        ARXIV_TITLE_SEARCH[](title, c)
    catch e
        e isa InterruptException && rethrow()
        @warn "arXiv's search did not answer for a title" title exception = e
        return nothing
    end
    surname(a) = lowercase(last(split(strip(replace(a, r",.*" => "")))))
    theirs(m) = Set(surname(a) for a in m.authors if !isempty(strip(a)))
    i = findfirst(m -> same_title(m.title, title) &&
                       (isequal(m.doi === nothing ? nothing : normalize_doi(m.doi), doi) || isempty(authors) ||
                        !isempty(intersect(theirs(m), Set(surname(a) for a in authors if !isempty(strip(a)))))), found)
    return i === nothing ? nothing : found[i].doc_id
end

"How arXiv is searched for a title (see [`arxiv_copy`](@ref)); tests put a stand-in here."
const ARXIV_TITLE_SEARCH = Ref{Function}((title, c) -> search_arxiv("ti:\"$(replace(title, '"' => ""))\"", c; max_results = 5))

"How long, in seconds, adding a PDF waits for its published record to be looked up."
const UPLOAD_LOOKUP_WAIT = Ref(20.0)

"An arXiv paper's id where arXiv stamps it on the first page of its PDF, with its category."
const ARXIV_ID_STAMP = Regex("arXiv:$ARXIV_ID(?:v\\d+)?\\s*\\[[A-Za-z.\\-]+\\]")

"""
    arxiv_stamp(pdf, config) -> Union{String,Nothing}

The arXiv id stamped on the first page of `pdf` ("arXiv:2401.00001v1 [cs.LG] …"), which
arXiv adds to the PDFs it builds, or nothing. Read from the page's raw text: parsing leaves the stamp
out, as it does the page's margins.
"""
function arxiv_stamp(pdf::AbstractString, c::Config)
    text = try read(pipeline(`$(c.mutool) draw -q -F txt -o - $pdf 1`; stderr = devnull), String) catch; "" end
    m = match(ARXIV_ID_STAMP, replace(text, r"\s+" => " "))
    return m === nothing ? nothing : String(m[1])
end

"""
    paper_with_doi(kb, doi) -> Union{String,Missing}

The paper here with DOI `doi`: by its own record, or as the arXiv paper the DOI was found to be
(see [`find_on_arxiv!`](@ref)). `missing` for none. A resource with the DOI is no paper: it is what a
work is kept as until a copy of it can be read.
"""
function paper_with_doi(kb::KB, doi::AbstractString)
    d = normalize_doi(doi)
    id = scalar(kb, "SELECT doc_id FROM papers WHERE lower(doi) = ? AND NOT $(kind_in(RESOURCE)) LIMIT 1", (d,))
    ismissing(id) || return String(id)
    id = scalar(kb, "SELECT d.doc_id FROM doi_arxiv d JOIN papers p ON p.doc_id = d.doc_id WHERE lower(d.doi) = ? LIMIT 1", (d,))
    return ismissing(id) ? missing : String(id)
end

"""
    reread_upload!(kb, id) -> NamedTuple

Read an uploaded PDF's title, journal reference and year again from the file, as [`add_pdf!`](@ref)
does, and store what was found (an abstract only where there is none). Returns the title and
journal reference now stored.
"""
function reread_upload!(kb::KB, id::AbstractString)
    is_upload(id) || error("$id is not an uploaded document")
    pdf = joinpath(pdf_dir(kb.config), pdf_filename(id, ""))
    isfile(pdf) || error("The PDF of $id is not in the data directory")
    p = parse_pdf(pdf, kb.config)
    cited = parsed_citation(p)
    execute!(kb, """
        UPDATE papers SET title = coalesce(?, title), journal_ref = coalesce(?, journal_ref),
            published = coalesce(published, ?), abstract = CASE WHEN coalesce(abstract, '') = '' THEN ? ELSE abstract END
        WHERE doc_id = ?""",
        (something(parsed_title(p), missing), cited === nothing ? missing : cited.ref,
         cited === nothing ? missing : cited.year, something(parsed_abstract(p), missing), id))
    heal_upload!(kb, id; parsed = p, force = true)
    r = paper_row(kb, id)
    return (; title = r.title, journal_ref = r.journal_ref)
end

# ── An upload's published record ──────────────────────────────────────────────────────────────────
# A PDF's own type is a weak guide to its title: a journal prints its name larger than the title,
# and a publisher's download sheet puts its own lines first, the article starting on the next page.
# OpenAlex has the record of most published papers, and the first pages usually carry what finds
# it: a DOI, or the title itself. So does the PDF's own metadata, often.

const PAGE_DOI = r"\b(10\.\d{4,9}/[^\s\"<>]+)"

"""
The pages a paper's record is looked for on: the first, and the second, where the article starts
after a publisher's download sheet.
"""
const LOOKUP_PAGES = 2

"The DOIs a paper gives: in its PDF's metadata (Subject, Keywords), then on its first pages, in order."
page_dois(p::ParsedPaper) =
    unique([[normalize_doi(m[1]) for k in ("Subject", "Keywords") for m in eachmatch(PAGE_DOI, get(p.info, k, ""))];
            [normalize_doi(m[1]) for x in p.pieces if x.page <= LOOKUP_PAGES for m in eachmatch(PAGE_DOI, x.text)]])

"""
Whether two titles are the same: alike in letters and digits, with spacing ignored too, since a
hyphen at a line break is lost in the reading ("NASEMcompliant" for "NASEM-compliant").
"""
same_title(a::AbstractString, b::AbstractString) = normalize_title(a) == normalize_title(b) || replace(normalize_title(a), " " => "") == replace(normalize_title(b), " " => "")

"Whether the PDF's metadata Title reads as a paper's title, not a file name or a word processor's."
metadata_title(t::AbstractString) =
    3 <= length(split(t)) <= 40 && !occursin(r"\.(pdf|docx?|tex|dvi)$"i, t) && !occursin(r"^(microsoft word|untitled|arxiv:)"i, t)

"""
The lines that could be the title, in order: the PDF's metadata Title, then on its first pages the
large type, then the front matter and headings.
"""
title_candidates(p::ParsedPaper) =
    unique([[t for t in [get(p.info, "Title", "")] if metadata_title(t)];
            [x.text for page in 1:LOOKUP_PAGES for kind in (:title, :front, :heading) for x in p.pieces
             if x.page == page && x.kind == kind && 3 <= length(split(x.text)) <= 40]])

"""
    lookup_upload(parsed; contact = "", find = openalex_work) -> Union{NamedTuple,Nothing}

The published record of an uploaded paper, `(; title, authors, year, journal, journal_ref, doi,
abstract)`: found by a DOI it gives (see [`page_dois`](@ref)), taken only when the record's title is
printed on its first pages too, or by a line there that is exactly a work's title (see
[`title_candidates`](@ref)). Only a paper is taken (see [`is_paper`](@ref)), never a journal's own
record. `nothing` when neither finds one.
"""
function lookup_upload(p::ParsedPaper; contact::AbstractString = "", find = openalex_work)
    text = join((x.text for x in p.pieces if x.page <= LOOKUP_PAGES), " ")
    page, joined = " " * normalize_title(text) * " ", replace(normalize_title(text), " " => "")
    function printed(w)
        t = normalize_title(something(w["title"], ""))
        return length(t) >= 10 && (occursin(" $t ", page) || occursin(replace(t, " " => ""), joined))
    end
    for doi in first(page_dois(p), 4)
        w = find(; doi, contact)
        w !== nothing && is_paper(w) && printed(w) && return work_record(w)
    end
    for t in first(title_candidates(p), 6)
        w = find(; title = t, contact)
        w !== nothing && is_paper(w) && return work_record(w)
    end
    return nothing
end

"How an upload's published record is looked for: [`lookup_upload`](@ref), unless replaced (in tests)."
const UPLOAD_LOOKUP = Ref{Function}(lookup_upload)

"""
    heal_upload!(kb, id; parsed = nothing, force = false, lookup = UPLOAD_LOOKUP[]) -> Bool

Put the published record of uploaded paper `id` in place of what its PDF suggested: its title,
authors, year, journal and DOI, and its abstract where it has none. A title someone typed is kept:
only one read from the PDF or its file name is replaced, or one that is the journal's name, which no
one types as a paper's title. Looked for once, unless `force`; true when a record was found.
"""
function heal_upload!(kb::KB, id::AbstractString; parsed = nothing, force::Bool = false, lookup = UPLOAD_LOOKUP[])
    r = paper_row(kb, id)
    force || ismissing(r.looked_up_at) || return false
    if parsed === nothing
        pdf = joinpath(pdf_dir(kb.config), pdf_filename(id, ""))
        isfile(pdf) || return false
        parsed = parse_pdf(pdf, kb.config)
    end
    rec = lookup(parsed; contact = kb.config.contact)
    execute!(kb, "UPDATE papers SET looked_up_at = ? WHERE doc_id = ?", (now_iso(), id))
    rec === nothing && return false
    file = scalar(kb, "SELECT message FROM mentions WHERE paper_id = ? AND source = 'upload'", (r.id,))
    read_title = coalesce(r.title, "") in (something(parsed_title(parsed), ""), ismissing(file) ? "" : splitext(file)[1], "") ||
                 is_journal_name(coalesce(r.title, ""), something(get(rec, :journal, nothing), ""))
    execute!(kb, """
        UPDATE papers SET title = ?, authors = ?, published = coalesce(?, published), journal_ref = coalesce(?, journal_ref),
            doi = coalesce(?, doi), abstract = CASE WHEN coalesce(abstract, '') = '' THEN coalesce(?, abstract) ELSE abstract END
        WHERE doc_id = ?""",
        (read_title ? rec.title : r.title, isempty(rec.authors) ? r.authors : JSON.json(rec.authors), something(rec.year, missing),
         something(rec.journal_ref, missing), something(rec.doi, missing), something(rec.abstract, missing), id))
    return true
end

"Whether `title` is journal `journal`'s name, or the start of it (\"PHYSICA\" for Physica D)."
is_journal_name(title::AbstractString, journal::AbstractString) =
    !isempty(normalize_title(title)) && !isempty(normalize_title(journal)) && startswith(normalize_title(journal) * " ", normalize_title(title) * " ")

"""
    heal_uploads!(kb; progress) -> Int

Look up the published record of every uploaded paper not yet looked for (see [`heal_upload!`](@ref));
the number found. A consumer leaves the dataset's papers to their publisher.
"""
function heal_uploads!(kb::KB; progress = msg -> nothing)
    ids = [r.id for r in query(kb, """
        SELECT doc_id AS id FROM papers WHERE looked_up_at IS NULL
          AND (? = 0 OR doc_id NOT IN (SELECT doc_id FROM dataset_docs))""", (Int(kb.config.dataset.role == :consume),)) if is_upload(r.id)]
    found = 0
    for (i, id) in enumerate(ids)
        progress("[$i/$(length(ids))] looking up the published record of $id")
        found += heal_upload!(kb, id)
    end
    return found
end

"""
    parsed_citation(parsed) -> (; ref, year) or nothing

Where the paper says it appeared, from the citation line a journal prints on its first page
("Ecological Modelling 87 (2012) 1453–1456"), and the year in it.
"""
function parsed_citation(p::ParsedPaper)
    for x in p.pieces
        x.page == 1 || continue
        m = match(JOURNAL_CITATION, x.text)
        m === nothing || return (; ref = String(m.match), year = String(m[2]))
    end
    return nothing
end

parsed_title(p::ParsedPaper) = (i = findfirst(x -> x.kind == :title, p.pieces); i === nothing ? nothing : p.pieces[i].text)

"The abstract as printed: the text under an Abstract heading, or a front-matter paragraph that opens with the word."
function parsed_abstract(p::ParsedPaper)
    for (i, x) in enumerate(p.pieces)
        if x.kind == :heading && occursin(r"^abstract\.?$"i, x.text)
            body = [y.text for y in p.pieces[i+1:end] if y.section == x.section && y.kind == :paragraph]
            isempty(body) || return join(body, "\n\n")
        elseif x.kind in (:front, :paragraph) && (m = match(r"^abstract[.:—–-]?\s*(.+)"is, x.text)) !== nothing
            return String(m[1])
        end
    end
    return nothing
end

"""
    refresh_metadata!(kb, ids; force = false)

Fill in arXiv metadata for papers that don't have it yet (or all of `ids` with `force`).
"""
function refresh_metadata!(kb::KB, ids::AbstractVector{<:AbstractString}; force::Bool = false)
    ids = filter(is_arxiv_id, ids)   # an uploaded paper's metadata is what it was given
    todo = force ? ids : filter(id -> ismissing(paper_row(kb, id).metadata_at), ids)
    isempty(todo) && return 0
    # Stored a batch at a time, so arXiv failing part way keeps what it gave before; when it gives
    # nothing at all, that is the error.
    stored, failure = 0, nothing
    for batch in Iterators.partition(todo, 50)
        metas = try
            fetch_metadata(collect(batch), kb.config)
        catch e
            e isa InterruptException && rethrow()
            failure = e
            break
        end
        transaction(kb) do
            for m in values(metas)
                execute!(kb, """
                    UPDATE papers SET version = ?, title = ?, abstract = ?, authors = ?, published = ?,
                        updated = ?, primary_category = ?, categories = ?, doi = ?, journal_ref = ?, metadata_at = ?
                    WHERE doc_id = ?""",
                    (m.version, m.title, m.abstract, JSON.json(m.authors), m.published, m.updated,
                     m.primary_category, JSON.json(m.categories), something(m.doi, missing),
                     something(m.journal_ref, missing), now_iso(), m.doc_id))
            end
        end
        stored += length(metas)
        missing_ids = setdiff(batch, keys(metas))
        isempty(missing_ids) || @warn "arXiv returned no metadata" ids = missing_ids
    end
    if failure !== nothing
        stored == 0 && throw(failure)
        @warn "arXiv stopped answering part way; the records fetched are kept" stored exception = failure
    end
    return stored
end

"""
    fetch_pdf!(kb, doc_id) -> String

Download the paper's PDF (the version its metadata names) and record the file.
"""
function fetch_pdf!(kb::KB, doc_id::AbstractString)
    p = paper_row(kb, doc_id)
    path = download_pdf(doc_id, coalesce(p.version, ""), kb.config)
    sha = bytes2hex(open(sha256, path))
    execute!(kb, "INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?)",
        (p.id, path, sha, filesize(path), now_iso()))
    return path
end

"""
    paper_pdf(kb, doc_id) -> String

The path of a paper's PDF, for reading it as it is: the file read here, else one kept from an
earlier look, else an arXiv paper's, fetched from arXiv and kept where [`fetch_pdf!`](@ref) would
put it, so reading the paper later reuses it. A PDF fetched only to be looked at is not recorded as
the paper's file: that would start its reading (see [`sync_plan`](@ref)) and queue its figures to be
cut (see `uncut_sql`), whose record would make a document imported from a dataset this knowledge base's
own to publish (see [`own_documents`](@ref)). An upload whose PDF is not here, and a document of a
kind not read from a PDF (a codebase), have none.
"""
function paper_pdf(kb::KB, doc_id::AbstractString)
    p = paper_row(kb, doc_id)
    is_kind(k -> k.pdf, doc_id) || not_found("No PDF of $doc_id: it is not read from one")
    f = query(kb, "SELECT path FROM files WHERE paper_id = ?", (p.id,))
    !isempty(f) && isfile(first(f).path) && return String(first(f).path)
    if !is_arxiv_id(doc_id)
        kept = joinpath(pdf_dir(kb.config), pdf_filename(doc_id, ""))
        isfile(kept) || not_found("No PDF of $doc_id here: it was uploaded to another knowledge base")
        return kept
    end
    return download_pdf(doc_id, coalesce(p.version, ""), kb.config)       # one kept from an earlier look, or fetched
end

"How a paper is read as its kind's entry says (see [`DocumentKind`](@ref)): its PDF fetched, then parsed."
function read_pdf!(kb::KB, id::AbstractString; force::Bool = false, step = msg -> nothing)
    step("downloading PDF")
    fetch_pdf!(kb, id)
    step("parsing")
    return parse_paper!(kb, id; force)
end

"""
    parse_paper!(kb, doc_id; force = false) -> Bool

Parse the paper's PDF into sections, blocks and chunks, replacing any earlier parse. Skipped
(returning false) when the file and parser version are unchanged since the last parse.
"""
function parse_paper!(kb::KB, doc_id::AbstractString; force::Bool = false)
    p = paper_row(kb, doc_id)
    files = query(kb, "SELECT path, sha256 FROM files WHERE paper_id = ?", (p.id,))
    isempty(files) && not_found("No PDF recorded for $doc_id; fetch it first")
    f = first(files)
    prev = query(kb, "SELECT file_sha, parser_version FROM parses WHERE paper_id = ?", (p.id,))
    if !force && !isempty(prev) && first(prev).file_sha == f.sha256 &&
       first(prev).parser_version == PARSER_VERSION
        return false
    end
    store_parse!(kb, doc_id, parse_pdf(f.path, kb.config); file_sha = f.sha256)
    return true
end

"""
    store_parse!(kb, doc_id, parsed; file_sha = "", chunks = chunk_paper(parsed, abstract))

Replace a paper's sections, blocks and chunks (and their keyword index) with a new parse.
"""
function store_parse!(kb::KB, doc_id::AbstractString, parsed::ParsedPaper; file_sha::AbstractString = "",
                      chunks = nothing)
    p = paper_row(kb, doc_id)
    chunks = something(chunks, chunk_paper(parsed, coalesce(p.abstract, "")))
    title = coalesce(p.title, doc_id)
    paths = Dict(s.ord => s.path for s in parsed.sections)
    transaction(kb) do
        execute!(kb, "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE paper_id = ?)", (p.id,))
        for t in ("chunks", "blocks", "sections")
            execute!(kb, "DELETE FROM $t WHERE paper_id = ?", (p.id,))
        end
        for s in parsed.sections
            execute!(kb, "INSERT INTO sections VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (p.id, s.ord, s.level, s.number, s.title, s.path, s.page_start, s.page_end))
        end
        for (i, b) in enumerate(parsed.pieces)
            execute!(kb, "INSERT INTO blocks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (p.id, i, b.section, string(b.kind), b.page, b.bbox..., b.text))
        end
        for c in chunks
            execute!(kb, "INSERT INTO chunks (paper_id, ord, section, page_start, page_end, text) VALUES (?, ?, ?, ?, ?, ?)",
                (p.id, c.ord, c.section, c.page_start, c.page_end, c.text))
            execute!(kb, "INSERT INTO chunks_fts (rowid, text, section, title) VALUES (last_insert_rowid(), ?, ?, ?)",
                (c.text, c.section == 0 ? "Abstract" : get(paths, c.section, ""), title))
        end
        execute!(kb, "INSERT OR REPLACE INTO parses VALUES (?, ?, ?, ?, ?)",
            (p.id, file_sha, PARSER_VERSION, parsed.pages, now_iso()))
    end
    return nothing
end

"""
    embed_paper!(kb, layer, doc_id) -> Int

Bring one paper's vectors in `layer` up to date: embed units that are new or whose text changed,
and delete vectors for units that no longer exist. Returns the number of units embedded.
"""
function embed_paper!(kb::KB, l::Layer, doc_id::AbstractString)
    (; pid, todo, stale) = embedding_diff(kb, l, doc_id)
    isempty(todo) || embed_units!(kb, l, [(pid, u) for u in todo])
    if !isempty(stale)
        coll = collection_name(kb.config, l)
        delete_vectors!(coll, [point_id(l.name, k) for k in stale])
        transaction(kb) do
            for k in stale
                execute!(kb, "DELETE FROM embeddings WHERE layer = ? AND unit_key = ?", (l.name, k))
            end
        end
    end
    return length(todo)
end

"""
Embed units in a layer and store their vectors: `todo` pairs each unit with its paper's row id.
Each batch is stored as it is embedded, so work stopped partway resumes after what was stored.
"""
function embed_units!(kb::KB, l::Layer, todo::AbstractVector)
    size = Ref(isempty(l.url) ? EMBED_BATCH_START : HOSTED_EMBED_BATCH)
    done = 0
    while done < length(todo)
        part = todo[done+1:min(done + size[], end)]
        vecs = embed(kb.config, l, [u.text for (_, u) in part]; size)
        coll = ensure_layer!(kb, l, length(first(vecs)))
        ids = [point_id(l.name, u.key) for (_, u) in part]
        upsert_vectors!(coll, ids, vecs, [merge(u.payload, Dict("unit" => u.key)) for (_, u) in part])
        transaction(kb) do
            for ((pid, u), id) in zip(part, ids)
                execute!(kb, "INSERT OR REPLACE INTO embeddings VALUES (?, ?, ?, ?, ?, ?)",
                    (l.name, u.key, pid, text_sha(u.text), id, now_iso()))
            end
        end
        done += length(part)
    end
end

"""
    embed_records!(kb, ids; progress, cancelled) -> Int

Embed the title and abstract of papers that are only recorded, in the layers that embed papers by
them (see [`record_layers`](@ref)), so every paper has a place on the landscape before it is read.
Returns the number of vectors made.
"""
function embed_records!(kb::KB, ids::AbstractVector{<:AbstractString};
                        progress = msg -> nothing, cancelled = () -> false)
    made = 0
    for l in record_layers(kb.config)
        todo = [(d.pid, u) for d in (embedding_diff(kb, l, id) for id in ids) for u in d.todo]
        for batch in Iterators.partition(todo, 64)
            cancelled() && return made
            embed_units!(kb, l, collect(batch))
            made += length(batch)
            progress("Embedding titles and abstracts in $(l.name) [$made/$(length(todo))]")
        end
    end
    return made
end

"""
    embedding_diff(kb, layer, doc_id) -> (; pid, todo, stale)

What embedding the paper in `layer` would do: the units that are new or whose text changed
(`todo`), and the keys of stored vectors whose units no longer exist (`stale`).
"""
function embedding_diff(kb::KB, l::Layer, doc_id::AbstractString)
    pid = paper_id(kb, doc_id)
    us = units(kb, l, doc_id)
    have = Dict(r.unit_key => r.text_sha for r in query(kb,
        "SELECT unit_key, text_sha FROM embeddings WHERE layer = ? AND paper_id = ?", (l.name, pid)))
    todo = filter(u -> get(have, u.key, "") != text_sha(u.text), us)
    stale = setdiff(keys(have), (u.key for u in us))
    return (; pid, todo, stale)
end

"""
    ingest!(kb, ids; layers = ingest_layers(kb.config), force_parse = false, progress = msg -> nothing,
            on_read = id -> nothing) -> Vector

Take papers all the way through: record them, fetch arXiv metadata and PDFs, parse, chunk, and
embed in each layer (all but the trial layers, unless `layers` says otherwise). Every step skips work that is already done, so re-running is cheap and
picks up where a failure stopped. With `classify`, each document read is then classified (see
[`classify!`](@ref)) unless the configured summarizer has classified it already, where this machine
can classify; a classification that fails is a warning on the document, whose reading stands.
`progress` receives a one-line status message per step, and `on_read` the id of each paper as soon
as it is read. Returns one named tuple per paper with what happened, including any error.
"""
function ingest!(kb::KB, ids::AbstractVector{<:AbstractString};
                 layers::AbstractVector{Layer} = ingest_layers(kb.config), force_parse::Bool = false, classify::Bool = true,
                 progress = msg -> nothing, cancelled = () -> false, on_read = id -> nothing, source = "added")
    ids = add_papers!(kb, ids; source)
    progress("Fetching metadata for $(length(ids)) paper(s)")
    # arXiv not answering leaves each paper without its record to fail on its own, not the batch:
    # uploads and codebases need none.
    try
        refresh_metadata!(kb, ids)
    catch e
        e isa InterruptException && rethrow()
        @warn "arXiv's records could not be fetched; reading what can be read without them" exception = e
    end
    classify = classify && isempty(cannot_run(kb, "classify", String[]))
    results = []
    for (i, id) in enumerate(ids)
        cancelled() && break
        step(msg) = progress("[$i/$(length(ids))] $id: $msg")
        t0 = time()
        try
            r = lock(() -> ingest_paper!(kb, id, layers; force_parse, step), paper_lock(id))
            classified, warning = false, r.error
            if classify && is_kind(k -> k.classified, id) && !isequal(scalar(kb, "SELECT classifier FROM classifications WHERE paper_id = ?", (paper_id(kb, id),)),
                                    kb.config.summarizer)
                step("classifying")
                try
                    classify!(kb, id)
                    classified = true
                catch e
                    e isa InterruptException && rethrow()
                    @warn "Classifying failed" id exception = e
                    warning = join(filter(!isnothing, [warning, "classifier: $(failure_message(e))"]), "; ")
                end
            end
            push!(results, (; id, ok = true, r..., classified, error = warning, seconds = time() - t0))
            on_read(id)
        catch e
            e isa InterruptException && rethrow()
            @error "Ingest failed" id exception = (e, catch_backtrace())
            push!(results, (; id, ok = false, parsed = false, summarized = 0, embedded = Dict{String,Int}(), classified = false,
                error = failure_message(e), seconds = time() - t0))
        end
    end
    return results
end

# Two ingests of one paper at once would overwrite each other's parse and embeddings, so each paper
# is processed under its own lock. The lock is per process: the extension and a notebook ingesting
# the same paper at the same moment are not serialized.
const _PAPER_LOCKS = Dict{String,ReentrantLock}()
const _PAPER_LOCKS_LOCK = ReentrantLock()
paper_lock(id::AbstractString) = lock(() -> get!(ReentrantLock, _PAPER_LOCKS, String(id)), _PAPER_LOCKS_LOCK)

"""
    ingest_paper!(kb, doc_id, layers; force_parse = false, step = msg -> nothing)

The steps of [`ingest!`](@ref) for one recorded paper with metadata: download, parse, summarize
and embed. Returns `(; parsed, summarized, embedded, error)`: whether it was parsed, the number of
summaries written, the units embedded in each layer, and in `error` the summarizer failures, which
cost only the layers built on that summarizer, not the paper.
"""
function ingest_paper!(kb::KB, id::AbstractString, layers::AbstractVector{Layer};
                       force_parse::Bool = false, step = msg -> nothing)
    kind = document_kind(id)
    kind === nothing && error("$id is not a kind of document the knowledge base reads")
    layers = kind_layers(kind, layers)
    parsed = kind.read(kb, id; force = force_parse, step)
    warnings = String[]
    # Its figures and tables, cut once from each reading of its PDF.
    if kind.pdf && !figures_cut(kb, id)
        step("cutting its figures")
        try
            cut_paper_figures!(kb, id)
        catch e
            e isa InterruptException && rethrow()
            push!(warnings, "figures: $(failure_message(e))")
        end
    end
    failed = Set{String}()
    summarized = 0
    for s in unique(summarizer_for(kb.config, l, id) for l in layers if !isempty(l.source))
        try
            summarized += summarize_paper!(kb, s, id; progress = msg -> step("$(s.name): $msg"))
        catch e
            e isa InterruptException && rethrow()
            push!(failed, s.name)
            push!(warnings, "summarizer $(s.name): $(failure_message(e))")
            @warn "Summarizing failed; skipping its layers" id summarizer = s.name exception = e
        end
    end
    embedded = Dict{String,Int}()
    for l in layers
        !isempty(l.source) && summarizer_for(kb.config, l, id).name in failed && continue
        step("embedding ($(l.name))")
        embedded[l.name] = embed_paper!(kb, l, id)
    end
    return (; parsed, summarized, embedded, error = isempty(warnings) ? nothing : join(warnings, "; "))
end

"""
    build_layer!(kb, name; ids = every parsed paper, progress, cancelled) -> Int

Embed papers in one layer, typically a trial layer that ingesting leaves alone; for a layer over
summaries, missing summaries are written first. Papers not yet parsed are skipped. Returns the
number of units embedded.
"""
function build_layer!(kb::KB, name::AbstractString; ids = nothing, progress = msg -> nothing, cancelled = () -> false)
    l = layer(kb.config, name)
    parsed = [r.id for r in query(kb, "SELECT p.doc_id AS id FROM papers p JOIN parses x ON x.paper_id = p.id ORDER BY p.doc_id")]
    ids = ids === nothing ? parsed : filter(in(Set(parsed)), ids)
    n = 0
    for (i, id) in enumerate(ids)
        cancelled() && break
        progress("[$i/$(length(ids))] $id: embedding ($(l.name))")
        lock(paper_lock(id)) do
            isempty(l.source) || summarize_paper!(kb, summarizer_for(kb.config, l, id), id; progress)
            n += embed_paper!(kb, l, id)
        end
    end
    return n
end

"""
    remove_paper!(kb, doc_id)

Delete a paper, its parse and its vectors in every layer, with its figures and a record's source document.
"""
function remove_paper!(kb::KB, doc_id::AbstractString)
    pid = paper_id(kb, doc_id)
    ismissing(pid) && not_found("No paper $doc_id")
    for r in query(kb, "SELECT DISTINCT e.layer, l.collection FROM embeddings e JOIN layers l ON l.name = e.layer WHERE e.paper_id = ?", (pid,))
        keys = [x.point_id for x in query(kb, "SELECT point_id FROM embeddings WHERE layer = ? AND paper_id = ?", (r.layer, pid))]
        delete_vectors!(r.collection, keys)
    end
    transaction(kb) do
        execute!(kb, "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE paper_id = ?)", (pid,))
        execute!(kb, "DELETE FROM embeddings WHERE paper_id = ?", (pid,))
        execute!(kb, "DELETE FROM papers WHERE id = ?", (pid,))
    end
    rm(figures_dir(kb.config, doc_id); force = true, recursive = true)
    rm(record_file(kb.config, doc_id); force = true)
end
