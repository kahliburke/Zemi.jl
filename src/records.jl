# Records: the group's own records of its work, usually of a meeting: a title, a date, the people in
# it, the text as Markdown sections, screenshots placed in it with captions, and a transcript where
# there is one. Sources hand them in through `put_record!`: Markdown notes uploaded here, or packages
# that read another system (a tool that writes meetings up from their recordings, say). Each record
# is labelled by its source with how it was made. A record is searched, read, cited and given to agents
# as any document is, but it is not the group's reading: it is in no list of papers, never
# published, never looked up elsewhere, and seen by the members of the projects it is linked to.

# What a record carries beyond its row of `papers`: the source that made it and its key there (one
# record a key), when what it records happened, its address in the source, the label saying how it
# was made, the hash of its content (see `record_sha`) and when that last changed. The content itself
# is the record's source document in the data directory (see `record_file`).
migration!(4, ["""CREATE TABLE records (
                      paper_id INTEGER PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,
                      source TEXT NOT NULL,
                      key TEXT NOT NULL,
                      happened TEXT NOT NULL,
                      url TEXT NOT NULL DEFAULT '',
                      label TEXT NOT NULL,
                      content_sha TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      UNIQUE (source, key))""",
               "CREATE INDEX records_happened ON records (happened)"])

"""
    RecordSection(heading, text)

A part of a record: its heading, and its text in Markdown, where a figure is placed as an image
whose address is the figure's name (`![](screen-1)`). Headings in the text begin parts within it.
"""
struct RecordSection
    heading::String
    text::String
end

"""
    RecordFigure(name, caption, image)

A figure of a record: the name its text places it by, its caption, and its image, the bytes of a
PNG, JPEG or WebP image or the path of one.
"""
struct RecordFigure
    name::String
    caption::String
    image::Vector{UInt8}
end
function RecordFigure(name::AbstractString, caption::AbstractString, image::AbstractString)
    isfile(image) || error("Figure $name: no image file $image")
    return RecordFigure(name, caption, read(image))
end

"A turn of a record's transcript: who spoke, from and to when (seconds into the recording), and what they said."
struct RecordSegment
    speaker::String
    start::Float64
    stop::Float64
    text::String
end

"""
    Record(; key, title, date, people = [], sections, figures = [], transcript = [], url = "",
           projects = [], access = nothing, label = "")

What a source hands in for one record (see [`put_record!`](@ref)), checked as it is made:

- `key`: the record's key in its source, which names it for good
- `title`; `date`, when it happened: a `Date`, a `DateTime` or one written as ISO 8601
- `people`: the names of those who took part
- `sections`: its parts, each a [`RecordSection`](@ref), a `heading => text` pair, or a NamedTuple or
  Dict with `heading` and `text`
- `figures`: each a [`RecordFigure`](@ref), or a NamedTuple or Dict with `name`, `caption` and
  `image` (bytes or a path)
- `transcript`: each segment a [`RecordSegment`](@ref), or a NamedTuple or Dict with `speaker`,
  `start`, `stop` (or `end`) and `text`
- `url`: its address in the source; `projects`: the keys of the projects to link it to
- `access`: `"open"` or `"projects"`; `nothing` leaves it as it is, `projects` for a new record
- `label`: how it was made, as readers are told it (its source's name, by default)
"""
struct Record
    key::String
    title::String
    date::String
    people::Vector{String}
    sections::Vector{RecordSection}
    figures::Vector{RecordFigure}
    transcript::Vector{RecordSegment}
    url::String
    projects::Vector{String}
    access::Union{String,Nothing}
    label::String
end

"The most a record may hold: what a source hands in past these is refused."
const RECORD_LIMITS = (; key = 200, title = 500, name = 200, people = 200, sections = 1000, text = 2_000_000,
                         figures = 200, caption = 2000, image = 20_000_000, segments = 50_000, transcript = 5_000_000,
                         url = 2000, label = 300)

record_field(x, k::Symbol, default = nothing) =
    x isa AbstractDict ? get(x, String(k), get(x, k, default)) : hasproperty(x, k) ? getproperty(x, k) : default

record_section(s::RecordSection) = s
record_section(s::Pair) = RecordSection(string(first(s)), string(last(s)))
record_section(s) = RecordSection(string(something(record_field(s, :heading), "")), string(something(record_field(s, :text), "")))

record_figure(f::RecordFigure) = f
function record_figure(f)
    name, caption = string(something(record_field(f, :name), "")), string(something(record_field(f, :caption), ""))
    image = something(record_field(f, :image), record_field(f, :bytes), record_field(f, :file), Some(nothing))
    image === nothing && error("Figure $name has no image")
    return image isa AbstractString ? RecordFigure(name, caption, image) : RecordFigure(name, caption, Vector{UInt8}(image))
end

record_segment(s::RecordSegment) = s
function record_segment(s)
    num(k) = (v = record_field(s, k); v isa Real ? Float64(v) : v === nothing ? NaN : something(tryparse(Float64, string(v)), NaN))
    stop = record_field(s, :stop) === nothing ? num(:end) : num(:stop)
    return RecordSegment(string(something(record_field(s, :speaker), "")), num(:start), stop, string(something(record_field(s, :text), "")))
end

"When a record's event happened, as stored: `yyyy-mm-dd`, or with its time, `yyyy-mm-ddTHH:MM:SS`."
record_date(d::Date) = Dates.format(d, "yyyy-mm-dd")
record_date(d::DateTime) = Dates.format(d, "yyyy-mm-ddTHH:MM:SS")
function record_date(s::AbstractString)
    given = strip(s)
    m = match(r"^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$", given)
    m === nothing && error("A record's date is ISO 8601 (2026-10-02, or 2026-10-02T14:00): $(repr(s))")
    d = tryparse(Date, m[1])
    d === nothing && error("No such day: $(m[1])")
    m[2] === nothing && return record_date(d)
    t = tryparse(Time, count(==(':'), m[2]) == 1 ? m[2] * ":00" : m[2])
    t === nothing && error("No such time: $(m[2])")
    return record_date(DateTime(d, t))
end

function Record(; key, title, date, people = String[], sections, figures = [], transcript = [], url = "",
                projects = String[], access = nothing, label = "")
    L = RECORD_LIMITS
    text(s, what, max; empty = false) = (s = String(strip(string(s)));
        isvalid(s) || error("$what is not valid text");
        !empty && isempty(s) && error("A record needs $what");
        length(s) <= max || error("$what is longer than $max characters");
        s)
    key = text(key, "a key", L.key)
    any(iscntrl, key) && error("A record's key has control characters: $(repr(key))")
    title = text(title, "a title", L.title)
    date = record_date(date)
    people = unique([text(p, "a person's name", L.name) for p in people])
    length(people) <= L.people || error("A record names at most $(L.people) people")
    sections = [record_section(s) for s in sections]
    isempty(sections) && error("A record needs a section of text")
    length(sections) <= L.sections || error("A record has at most $(L.sections) sections")
    sections = [RecordSection(text(s.heading, "a section's heading", L.title), text(s.text, "a section's text", L.text; empty = true))
                for s in sections]
    sum(s -> length(s.text), sections) <= L.text || error("A record's text is longer than $(L.text) characters")
    figures = [record_figure(f) for f in figures]
    length(figures) <= L.figures || error("A record has at most $(L.figures) figures")
    for f in figures
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", f.name) ||
            error("A figure's name is letters, digits, dots, dashes and underscores: $(repr(f.name))")
        length(f.caption) <= L.caption && isvalid(f.caption) || error("Figure $(f.name)'s caption is not text of at most $(L.caption) characters")
        length(f.image) <= L.image || error("Figure $(f.name) is larger than $(L.image) bytes")
        image_kind(f.image) === nothing && error("Figure $(f.name) is not a PNG, JPEG or WebP image")
    end
    allunique(f.name for f in figures) || error("Two figures have the same name")
    figures = [RecordFigure(f.name, strip(f.caption), f.image) for f in figures]
    transcript = [record_segment(s) for s in transcript]
    length(transcript) <= L.segments || error("A transcript has at most $(L.segments) segments")
    for s in transcript
        isfinite(s.start) && isfinite(s.stop) && 0 <= s.start <= s.stop ||
            error("A transcript segment runs from a time to a later one, in seconds: $(s.start) to $(s.stop)")
    end
    transcript = [RecordSegment(text(s.speaker, "a speaker", L.name; empty = true), s.start, s.stop,
                                text(s.text, "a segment's text", L.transcript; empty = true)) for s in transcript]
    sum(s -> length(s.text), transcript; init = 0) <= L.transcript || error("A transcript is longer than $(L.transcript) characters")
    url = text(url, "an address", L.url; empty = true)
    isempty(url) || occursin(r"^https?://\S+$", url) || error("A record's address is a web address: $(repr(url))")
    projects = unique([uppercase(text(k, "a project's key", 40)) for k in projects])
    access === nothing || (access = lowercase(strip(string(access)))) in DOCUMENT_ACCESS ||
        error("A record's access is \"open\" or \"projects\", not $(repr(access))")
    label = text(label, "a label", L.label; empty = true)
    return Record(key, title, date, people, sections, figures, transcript, url, projects, access, label)
end

"A record from what a source handed in: a [`Record`](@ref), or the NamedTuple or Dict of its fields."
as_record(r::Record) = r
as_record(r::NamedTuple) = Record(; r...)
as_record(r::AbstractDict) = Record(; (Symbol(k) => v for (k, v) in r)...)

"The kind of image `bytes` are, as a file's extension (`png`, `jpg`, `webp`), or `nothing`."
function image_kind(b::AbstractVector{UInt8})
    length(b) >= 8 && b[1:8] == b"\x89PNG\r\n\x1a\n" && return "png"
    length(b) >= 3 && b[1:3] == b"\xff\xd8\xff" && return "jpg"
    length(b) >= 12 && b[1:4] == b"RIFF" && b[9:12] == b"WEBP" && return "webp"
    return nothing
end

"A source's name, as its records' ids and mentions carry it: lower case letters, digits and dashes."
function record_source(source::AbstractString)
    s = String(strip(source))
    occursin(r"^[a-z0-9][a-z0-9-]{0,39}$", s) || error("A source's name is lower case letters, digits and dashes: $(repr(source))")
    return s
end

"How long a record's id may be."
const RECORD_ID_MAX = 80

"""
    record_id(source, key) -> String

The id of the record `source` keeps as `key`: `rec-`, the source and the key in lower case letters,
digits and dashes, at most `RECORD_ID_MAX` long. A key that changes in being made so, or is cut, has
a hash of the source and key after it, so two keys never give one id and one key always gives the same.
"""
record_id(source::AbstractString, key::AbstractString) = source_id(RECORD.prefix, source, key)

"The id a document a source keeps as `key` is given, after its kind's `prefix` (see [`record_id`](@ref))."
function source_id(prefix::AbstractString, source::AbstractString, key::AbstractString)
    safe(s) = strip(replace(lowercase(s), r"[^a-z0-9]+" => "-"), '-')
    id = prefix * join(filter(!isempty, [safe(source), safe(key)]), "-")
    safe(key) == key && length(id) <= RECORD_ID_MAX && return id
    hash = bytes2hex(sha256(source * "\0" * key))[1:8]
    return rstrip(first(id, RECORD_ID_MAX - 9), '-') * "-" * hash
end

"Where record `id`'s source document is kept: its content as its source handed it in."
record_file(c::Config, id::AbstractString) = joinpath(c.data_dir, "records", page_slug(id) * ".json")

"Record `id`'s source document (see [`record_file`](@ref)), as a Dict."
function record_document(kb::KB, id::AbstractString)
    f = record_file(kb.config, id)
    isfile(f) || not_found("The source document of record $id is not here")
    return JSON.parsefile(f)
end

"""
What a record's source document holds, in the order it is written and hashed: its text, people,
figures (by their images' hashes, and the files they are kept as) and transcript, with its label and
address. Projects and access are not content: they are the knowledge base's to change.
"""
function record_content(source::AbstractString, r::Record)
    label = isempty(r.label) ? "From $source" : r.label
    return (; source, r.key, r.title, r.date, r.people, label, r.url,
              sections = [(; s.heading, s.text) for s in r.sections],
              figures = [(; f.name, f.caption, sha = bytes2hex(sha256(f.image)), file = "fig-$i.webp") for (i, f) in enumerate(r.figures)],
              transcript = [(; s.speaker, s.start, var"end" = s.stop, s.text) for s in r.transcript])
end

"The hash of a record's content (see [`record_content`](@ref)): it changes whenever what a reader is shown does."
record_sha(content) = bytes2hex(sha256(JSON.json(content)))

"""
The hash of what reading a record uses: its title, date, sections, figures and transcript. Its people,
label and address change without it, and are then updated in place rather than read again (see
[`put_record!`](@ref)).
"""
reading_sha(c) = bytes2hex(sha256(JSON.json((; title = c["title"], date = c["date"], sections = c["sections"],
                                               figures = [(f["name"], f["caption"], f["sha"]) for f in c["figures"]],
                                               transcript = c["transcript"]))))
reading_sha(c::NamedTuple) = reading_sha(JSON.parse(JSON.json(c)))

# The reading hash beside the content's, so a change to a record's people or label alone is not read again.
migration!(6, ["ALTER TABLE records ADD COLUMN reading_sha TEXT NOT NULL DEFAULT ''"])

"""
The reading hash of record `id` as stored (see [`reading_sha`](@ref)), from its source document for
one stored before it was kept; `nothing` for none.
"""
function stored_reading_sha(kb::KB, id::AbstractString)
    r = record_row(kb, id)
    r === nothing && return nothing
    isempty(r.reading_sha) || return String(r.reading_sha)
    f = record_file(kb.config, id)
    return isfile(f) ? reading_sha(JSON.parsefile(f)) : nothing
end

"`names` as a list in prose: `Ada`, `Ada and Bea`, `Ada, Rowan and Bea`."
prose_list(names) = length(names) <= 2 ? join(names, " and ") : join(names[1:end-1], ", ") * " and " * last(names)

"A record's date in words (`2 October 2026`), from its stored date."
record_day(date::AbstractString) = (d = tryparse(Date, first(date, 10)); d === nothing ? String(date) : Dates.format(d, "d U yyyy"))

"""
What a record's abstract is: when it happened and who took part, and how it was made. It stands
where a paper's abstract does, for what a record's summaries are written from and its reader sees first.
"""
record_abstract(c) = record_day(c.date) * (isempty(c.people) ? "" : ", with " * prose_list(c.people)) * ". " * c.label * "."

"""
    put_record!(kb, source, r; read = true, label = nothing, by = nothing, anyway = false) -> (id, changed)

Store record `r` (a [`Record`](@ref), or the NamedTuple or Dict of its fields, checked as it is made)
that source `source` made, returning its id (see [`record_id`](@ref)) and whether it changed. The one
call a source makes for each record it has:

- a record whose content is as it was (see [`record_sha`](@ref)) is left as it is: `changed` false
- otherwise its source document is written, its figures kept as its own (WebP images, in place in
  its text with their captions), its row of `papers` set (its people as authors, its date as when it
  was published), and it is linked to the projects `r` names (see [`link_document!`](@ref)); a new one
  takes `r`'s access, `projects` unless it says otherwise, and its arrival is a mention from `source`
- with `read`, it is then queued to be read (see [`queue_reading!`](@ref)): sections, passages,
  summaries and vectors. A record read again keeps its id, its links and the findings citing it.
  One whose people, label or address alone changed is not read again (see [`reading_sha`](@ref)):
  written in place, it is embedded again where that changed what it embeds, its summaries kept.

`label`, given, is the record's whatever `r` says (a registered source's, see [`record_source!`](@ref));
`by` is who added it, as its arrival's mention names them. A new record a person dropped is refused
with a [`DroppedError`](@ref), unless `anyway`, which restores it.
"""
function put_record!(kb::KB, source::AbstractString, r; read::Bool = true, label::Union{AbstractString,Nothing} = nothing,
                     by::Union{AbstractString,Nothing} = nothing, anyway::Bool = false)
    r = as_record(r)
    label === nothing || (r = Record(r.key, r.title, r.date, r.people, r.sections, r.figures, r.transcript, r.url, r.projects, r.access,
                                     String(label)))
    source = record_source(source)
    for key in r.projects
        project_id(kb, key)                          # each named project is there before anything is written
    end
    known = scalar(kb, "SELECT p.doc_id FROM records x JOIN papers p ON p.id = x.paper_id WHERE x.source = ? AND x.key = ?",
                   (source, r.key))
    id = ismissing(known) ? record_id(source, r.key) : String(known)
    if ismissing(known) && !ismissing(paper_id(kb, id))
        error("The id $id of $source's record $(repr(r.key)) is another document's")
    end
    ismissing(known) && keep_out!(kb, anyway; by, id, source, key = r.key)
    content = record_content(source, r)
    sha = record_sha(content)
    isequal(scalar(kb, "SELECT x.content_sha FROM records x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,)), sha) &&
        return (id, false)
    rsha = reading_sha(content)
    # Only its people, label or address changed: written in place, the summaries kept.
    in_place = stored_reading_sha(kb, id) == rsha
    lock(paper_lock(id)) do
        store_record_figures!(kb.config, id, r.figures)
        mkpath(dirname(record_file(kb.config, id)))
        write_atomic(record_file(kb.config, id), JSON.json(content))
        at = now_iso()
        transaction(kb) do
            new = ismissing(paper_id(kb, id))
            execute!(kb, """
                INSERT INTO papers (doc_id, version, title, abstract, authors, published, primary_category, categories, kind,
                                    metadata_at, added_at, access)
                VALUES (?, '', ?, ?, ?, ?, '', '[]', ?, ?, ?, ?)
                ON CONFLICT (doc_id) DO UPDATE SET title = excluded.title, abstract = excluded.abstract, authors = excluded.authors,
                    published = excluded.published, metadata_at = excluded.metadata_at""",
                (id, r.title, record_abstract(content), JSON.json(r.people), first(r.date, 10), RECORD.name, at, at,
                 something(r.access, "projects")))
            pid = paper_id(kb, id)
            r.access === nothing || execute!(kb, "UPDATE papers SET access = ? WHERE id = ?", (r.access, pid))
            execute!(kb, """
                INSERT INTO records (paper_id, source, key, happened, url, label, content_sha, reading_sha, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (paper_id) DO UPDATE SET happened = excluded.happened, url = excluded.url, label = excluded.label,
                    content_sha = excluded.content_sha, reading_sha = excluded.reading_sha, updated_at = excluded.updated_at""",
                (pid, source, r.key, r.date, r.url, content.label, sha, rsha, at))
            # Read before under the hash of all its content: what it was read from is still what it is.
            in_place && execute!(kb, "UPDATE parses SET file_sha = ? WHERE paper_id = ?", (rsha, pid))
            execute!(kb, "DELETE FROM figures WHERE paper_id = ?", (pid,))
            for (i, f) in enumerate(content.figures)
                execute!(kb, "INSERT INTO figures VALUES (?, 'figure', ?, ?, ?, ?)", (pid, i, f.name, f.caption, f.file))
            end
            new && execute!(kb, """INSERT INTO mentions (paper_id, source, channel, posted_at, author, url, message)
                                   VALUES (?, ?, NULL, ?, ?, ?, ?)""",
                            (pid, source, time(), something(by, missing), isempty(r.url) ? missing : r.url, content.label))
            foreach(key -> link_document!(kb, id, key), r.projects)
        end
    end
    if read
        in_place ? refresh_record_vectors!(kb, id) : queue_reading!(kb, [id])
    end
    return (id, true)
end

"""
Keep a record's figures as its own, in its folder of figures: `fig-<n>.webp` in order, each image
encoded as WebP (see [`encode_webp`](@ref)) unless it is one; what was kept before and is not now goes.
"""
function store_record_figures!(c::Config, id::AbstractString, figures)
    dir = figures_dir(c, id)
    for (i, f) in enumerate(figures)
        file = joinpath(dir, "fig-$i.webp")
        kind = image_kind(f.image)
        if kind == "webp"
            mkpath(dir)
            write_atomic(file, f.image)
            continue
        end
        given = tempname() * "." * kind
        try
            write(given, f.image)
            encode_webp(given, file)
        finally
            rm(given; force = true)
        end
    end
    clear_figures!(dir, Set("fig-$i.webp" for i in eachindex(figures)))
    return nothing
end

"""
    delete_record!(kb, id)

Remove record `id` with everything made from it: its passages, summaries, vectors, figures, links
and source document (see [`remove_paper!`](@ref)). Findings citing it keep the citation, and are
told it is gone (see [`check_findings!`](@ref)).
"""
function delete_record!(kb::KB, id::AbstractString)
    is_record(id) || error("$id is not a record")
    remove_paper!(kb, id)
    return nothing
end

"""
    purge_source!(kb, source) -> Int

Remove every record source `source` made (see [`delete_record!`](@ref)); how many there were.
"""
function purge_source!(kb::KB, source::AbstractString)
    ids = [String(r.doc_id) for r in query(kb, "SELECT p.doc_id FROM records x JOIN papers p ON p.id = x.paper_id WHERE x.source = ?",
                                           (record_source(source),))]
    foreach(id -> delete_record!(kb, id), ids)
    return length(ids)
end

"Record `id`'s row of `records`, or `nothing` for a document that is not a record here."
function record_row(kb::KB, id::AbstractString)
    rows = query(kb, "SELECT x.* FROM records x JOIN papers p ON p.id = x.paper_id WHERE p.doc_id = ?", (id,))
    return isempty(rows) ? nothing : first(rows)
end

# ── Reading ─────────────────────────────────────────────────────────────────────────────────────

"The documents sources handed in that wait to be read, and the job reading them, if one is (see [`queue_reading!`](@ref))."
const READING = (; ids = Set{String}(), job = Ref{Union{Job,Nothing}}(nothing), lock = ReentrantLock())

"""
    queue_reading!(kb, ids) -> Job

Have documents `ids` that sources handed in read (see [`ingest!`](@ref)) by the job reading them: one
job reads every document queued while it runs, so a source handing in many starts one. A record it
does not read (the service stopping first) is queued again when the service next starts (see
[`queue_unread_records!`](@ref)); another document is left for a sync.
"""
function queue_reading!(kb::KB, ids)
    lock(READING.lock) do
        union!(READING.ids, ids)
        READING.job[] === nothing || return READING.job[]
        READING.job[] = start_job("read documents"; changes = changes_stamp(kb.config)) do job
            results = []
            try
                while true
                    id = lock(READING.lock) do
                        isempty(READING.ids) || cancelled(job) ? nothing : pop!(READING.ids)
                    end
                    id === nothing && break
                    push!(job.ids, id)
                    !ismissing(paper_id(kb, id)) &&
                        append!(results, ingest!(kb, [id]; progress = m -> report!(job, m)))
                end
            finally
                lock(() -> READING.job[] === job && (READING.job[] = nothing), READING.lock)
            end
            results
        end
    end
end

"""
Embed record `id` again where what it embeds has changed (its opening line, with its people and
label, after a change in place), leaving its summaries. A failure is left for the next sync, which
finds the vectors out of date.
"""
function refresh_record_vectors!(kb::KB, id::AbstractString)
    for l in ingest_layers(kb.config)
        try
            embed_paper!(kb, l, id)
        catch e
            @warn "Could not embed $id again; the next sync will" layer = l.name exception = e
        end
    end
end

"""
    queue_unread_records!(kb) -> Vector{String}

Queue the records never read (see [`queue_reading!`](@ref)): those a service stopped before reading,
since the queue is not kept across restarts and a source handing them in again unchanged queues
nothing. The serving processes do this as they start their sources.
"""
function queue_unread_records!(kb::KB)
    ids = [String(r.doc_id) for r in query(kb, """SELECT p.doc_id FROM records r JOIN papers p ON p.id = r.paper_id
                                                  WHERE NOT EXISTS (SELECT 1 FROM parses x WHERE x.paper_id = r.paper_id)""")]
    isempty(ids) || queue_reading!(kb, ids)
    return ids
end

"""
    parse_record(content) -> ParsedPaper

A record's source document read into the structure a parsed paper has: each of its sections a
section, opening with its heading, a heading in its text beginning one within it; each paragraph a
piece, and each figure it places a caption, where it is placed (one not placed follows its text);
its transcript, where it has one, a last section of turns, each `speaker: text` with its times as
the piece's `x0` and `x1`.
"""
function parse_record(c::AbstractDict)
    pieces, sections = Piece[], Section[]
    figures = Dict(String(f["name"]) => f for f in c["figures"])
    placed = Set{String}()
    piece!(kind, text, ord; times = (0.0, 0.0)) = push!(pieces, Piece(kind, 1, (times[1], 0.0, times[2], 0.0), String(text), ord, 0, ""))
    function section!(level, title, path)
        push!(sections, Section(length(sections) + 1, level, "", title, path, 1, 1))
        piece!(:heading, title, length(sections))
        return length(sections)
    end
    caption(f) = isempty(f["caption"]) ? String(f["name"]) : String(f["caption"])
    function paragraph!(lines, ord)
        text = strip(join(lines, '\n'))
        isempty(text) && return
        named = [String(m[1]) for m in eachmatch(FIGURE_IMAGE, text) if haskey(figures, m[1])]
        rest = strip(replace(text, FIGURE_IMAGE => m -> haskey(figures, match(FIGURE_IMAGE, m)[1]) ? "" : m))
        isempty(rest) || piece!(:paragraph, rest, ord)
        for n in named
            n in placed || (push!(placed, n); piece!(:caption, caption(figures[n]), ord))
        end
    end
    for s in c["sections"]
        heading = String(s["heading"])
        ord = section!(1, heading, heading)
        trail = [(1, heading)]                       # the headings above the text, by level
        lines, fenced = String[], false
        for line in split(String(s["text"]), '\n')
            startswith(lstrip(line), "```") && (fenced = !fenced)
            m = fenced ? nothing : match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
            if m !== nothing
                paragraph!(lines, ord); empty!(lines)
                level = 1 + length(m[1])
                filter!(t -> first(t) < level, trail)
                push!(trail, (level, String(m[2])))
                ord = section!(level, String(m[2]), join(last.(trail), " › "))
            elseif !fenced && isempty(strip(line))
                paragraph!(lines, ord); empty!(lines)
            else
                push!(lines, line)
            end
        end
        paragraph!(lines, ord)
    end
    last_text = length(sections)
    for f in c["figures"]
        f["name"] in placed || piece!(:caption, caption(f), last_text)
    end
    if !isempty(c["transcript"])
        ord = section!(1, "Transcript", "Transcript")
        for t in c["transcript"]
            isempty(strip(t["text"])) && continue
            piece!(:paragraph, isempty(t["speaker"]) ? t["text"] : "$(t["speaker"]): $(t["text"])", ord;
                   times = (Float64(t["start"]), Float64(t["end"])))
        end
    end
    return ParsedPaper(1, pieces, sections)
end

"A Markdown image whose address may be a record's figure's name (`![](screen-1)`), the name its first group."
const FIGURE_IMAGE = r"!\[[^\]\n]*\]\(([A-Za-z0-9][A-Za-z0-9._-]*)\)"

"""
How a record is read as its kind's entry says (see [`DocumentKind`](@ref)): from its source document
(see [`parse_record`](@ref)), its figures placed. Skipped (returning false) when what reading uses
(see [`reading_sha`](@ref)) and the reader are as they were when it was last read.
"""
function read_record!(kb::KB, id::AbstractString; force::Bool = false, step = msg -> nothing)
    step("reading the record")
    pid = paper_id(kb, id)
    r = record_row(kb, id)
    r === nothing && not_found("No record $id in the knowledge base")
    prev = query(kb, "SELECT file_sha, parser_version FROM parses WHERE paper_id = ?", (pid,))
    doc = record_document(kb, id)
    rsha = reading_sha(doc)
    !force && !isempty(prev) && first(prev).file_sha == rsha && first(prev).parser_version == PARSER_VERSION && return false
    parsed = parse_record(doc)
    store_parse!(kb, id, parsed; file_sha = rsha, chunks = chunk_paper(parsed))
    return true
end

# ── What readers and agents are told ──────────────────────────────────────────────────────────────

"""
    record_note(kb, id) -> String

What a reader or an agent is told wherever record `id` is given them: that it is a record of the
group's own work, with its date, its label (how it was made) and its people, to be weighed as what
people said.
"""
function record_note(kb::KB, id::AbstractString)
    r = record_row(kb, id)
    r === nothing && return ""
    people = json_list(scalar(kb, "SELECT authors FROM papers WHERE doc_id = ?", (id,)))
    return "$id is a record of the group's own work, from $(record_day(r.happened)) ($(r.label))" *
           (isempty(people) ? "" : ", with $(prose_list(people))") *
           ". Weigh what it says as what the people in it said, not as established."
end

"What record summarizers are told they are doing."
record_summary_system(c::Config) =
    "You summarize records of a research group's own discussions$(in_field(c)) for its knowledge base: notes of " *
    "its meetings and other work, some written up by a tool from a recording. A record says what people said, " *
    "not what is established."

record_section_prompt(title, path, text) = """
    Record: $title
    Part: $path

    Summarize this part of the record in 2–5 sentences for a member of the group deciding whether to read \
    it: what was discussed, what was decided, what was left open, and who is to do what. Attribute each \
    claim, result and opinion to the person who made it, by name, and present nothing that was said as \
    established. Name the papers, codebases and tasks it mentions as it names them. Write plain prose: no \
    heading, no bullet points, no preamble.

    A tool wrote the text up from a recording, so names and terms may be misheard; keep them as written.

    Text:
    $text"""

record_prompt(title, abstract, parts) = """
    Record: $title
    $abstract

    Summaries of its parts:
    $parts

    Summarize the record. First one paragraph of 3–6 sentences on what was discussed, attributing each \
    claim, result and opinion to the person who made it, by name, and presenting nothing that was said as \
    established. Then four lines, each beginning with its label and listing its items separated by \
    semicolons, or "none":
    Decided: what the people agreed on or decided.
    Open: the questions left open.
    Actions: who is to do what, as "name: what".
    Touched: the papers, codebases and tasks it names, as it names them (arXiv ids, task references such as KB-12).
    Then, on a new line beginning "Topics:", list 3–8 specific topics it covers, separated by commas. No \
    heading and no preamble."""

record_agent_system(c::Config) =
    "You are a specialist who summarizes a research group's records of its own discussions$(in_field(c)) for its " *
    "knowledge base. Use only the Read and Write tools."

record_agent_brief(reads::Symbol) = """
    task.md names the record and lists the parts to summarize, each with a number (its "ord") and its heading path.

    1. Read the whole record first: paper.txt holds its text, which a tool wrote up from a recording (with \
    its transcript, where it has one), so names and terms may be misheard; keep them as written.
    2. Summarize each listed part in 2–5 sentences: what was discussed, what was decided, what was left \
    open, and who is to do what. Attribute each claim, result and opinion to the person who made it, by \
    name, and present nothing that was said as established.
    3. Summarize the whole record: one paragraph of 3–6 sentences on what was discussed, attributed the \
    same way; then four lines, each beginning with its label and listing its items separated by \
    semicolons, or "none": "Decided:", "Open:", "Actions:" (who is to do what, as "name: what") and \
    "Touched:" (the papers, codebases and tasks it names, as it names them); then, on a new line beginning \
    "Topics:", 3–8 specific topics it covers, separated by commas.

    Write the result to summaries.json as a JSON object: {"sections": {"<ord>": "<summary>", ...}, "paper": \
    "<record summary>\\nTopics: ..."} with exactly one entry per listed part (an empty "sections" object if \
    none are listed). Write the JSON carefully: you have no tool to check it. Then reply with one line \
    saying it is written.
    """

"""
    visible_records(kb, caller; project = "", source = "") -> Vector{NamedTuple}

The records `caller` may see (see [`document_visible`](@ref)), newest first, of `project` and from
`source` when given: each `(; id, title, date, people, label, source, url, access, projects, read)`.
"""
function visible_records(kb::KB, caller::Caller; project::AbstractString = "", source::AbstractString = "")
    hidden = hidden_documents(kb, caller)
    rows = query(kb, """SELECT p.id AS pid, p.doc_id, p.title, p.authors, p.access, x.source, x.happened, x.label, x.url,
                               EXISTS (SELECT 1 FROM parses y WHERE y.paper_id = p.id) AS read
                        FROM records x JOIN papers p ON p.id = x.paper_id
                        WHERE (? = '' OR x.source = ?) ORDER BY x.happened DESC, p.id DESC""", (source, source))
    out = NamedTuple[]
    for r in rows
        r.doc_id in hidden && continue
        projects = document_projects(kb, r.doc_id)
        isempty(project) || uppercase(strip(project)) in projects || continue
        push!(out, (; id = String(r.doc_id), title = String(r.title), date = String(r.happened), people = json_list(r.authors),
                      label = String(r.label), source = String(r.source), url = String(r.url), access = String(r.access),
                      projects, read = r.read == 1))
    end
    return out
end
