# The source Zemi has of its own, `upload`: a Markdown file someone uploads, made one record. It
# needs no plugin, and it is written as a plugin's source is (see guide/src/extensions.md), through
# its run alone. Uploads reach the source that accepts them through `upload_record!`.

"Whether `path` is a file the upload source reads: Markdown."
upload_accepts(path::AbstractString) = lowercase(splitext(path)[2]) in (".md", ".markdown")

"""
    markdown_record(text) -> (; title, sections)

A Markdown file's title and sections: its title the first heading (`nothing` without one), its
sections begun by the headings of the shallowest level after it, the text before the first of them a
section under the title. Deeper headings stay in their section's text; nothing in a fenced block is
a heading.
"""
function markdown_record(text::AbstractString)
    lines = split(replace(text, "\r\n" => "\n"), '\n')
    headings = Tuple{Int,Int,String}[]                  # line, level, text
    fenced = false
    for (i, line) in enumerate(lines)
        startswith(lstrip(line), "```") && (fenced = !fenced)
        m = fenced ? nothing : match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        m === nothing || push!(headings, (i, length(m[1]), String(m[2])))
    end
    isempty(headings) && return (; title = nothing, sections = [(heading = "Notes", text = strip(text))])
    (start, _, title), rest = headings[1], headings[2:end]
    level = isempty(rest) ? 0 : minimum(h[2] for h in rest)
    cuts = [h for h in rest if h[2] == level]
    body(from, to) = strip(join(lines[from:to], '\n'))
    sections = NamedTuple[]
    lead = body(start + 1, isempty(cuts) ? length(lines) : cuts[1][1] - 1)
    isempty(lead) || push!(sections, (heading = title, text = lead))
    for (j, (line, _, heading)) in enumerate(cuts)
        push!(sections, (heading = heading, text = body(line + 1, j < length(cuts) ? cuts[j+1][1] - 1 : length(lines))))
    end
    return (; title, sections)
end

"""
Read an uploaded Markdown file as one record: its title its first heading (or the file's name), its
date the one given with it (or the day the file was last changed), its sections by heading. Its key
is its date and file name, so the same notes uploaded again replace the record they made.
"""
function read_upload(run::SourceRun, path::AbstractString)
    given = upload(run)
    name = given === nothing ? basename(path) : given.name
    title, sections = markdown_record(read(path, String))
    all(s -> isempty(s.text), sections) && error("$name has no text")
    date = given === nothing || given.date === nothing ? Date(unix2datetime(mtime(path))) : given.date
    stem = splitext(name)[1]
    put!(run, (; key = "$(record_date(date)) $stem", title = something(title, stem), date, sections))
    return nothing
end

record_source!("upload"; label = "Uploaded as a Markdown file", accepts = upload_accepts, read = read_upload, api = PLUGIN_API)

"""
    upload_record!(kb, path; name = basename(path), date = nothing, project = "", by = nothing,
                   source = "") -> SourceRun

Have the source that accepts the file at `path` read it (see [`record_source!`](@ref)), as uploaded
under `name`, with the date given with it (or `nothing`), on project `project`'s page (each record
it makes linked to that project) by `by`. The sources of plugins are asked before Zemi's own, and
only those that run in this mode; `source` names one to ask alone. Returns the run, with the ids of
the records it handed in.
"""
function upload_record!(kb::KB, path::AbstractString; name::AbstractString = basename(path), date = nothing,
                        project::AbstractString = "", by::Union{AbstractString,Nothing} = nothing, source::AbstractString = "")
    project = uppercase(strip(project))
    isempty(project) || project_id(kb, project)
    date = date === nothing || date isa Date ? date : Date(first(record_date(string(date)), 10))
    candidates = [filter(s -> !isempty(s.plugin), SOURCES[]); filter(s -> isempty(s.plugin), SOURCES[])]
    i = findfirst(s -> s.read !== nothing && runs_here(s) && (isempty(source) || s.name == source) &&
                       Base.invokelatest(s.accepts, path) === true, candidates)
    i === nothing && error(isempty(source) ? "No source here reads $name: Markdown files (.md) are read as records" :
                                             "Source $source does not read $name here")
    return run_source!(kb, candidates[i]; path, upload = (; name = String(name), date, project, by))
end

# A file uploaded as records: its bytes, with `?name=` its file's name, `date=` the day it records
# (else the file's own), `project=` the project whose board it was uploaded on and `source=` the
# source to read it. A record is uploaded to a project, which the uploader contributes to, so that it
# is seen by that project's members from the start.
route!("POST", "/api/records/upload"; need = "paper.add") do c
    name = basename(strip(get(c.params, "name", "")))
    isempty(name) && error("Name the file uploaded (?name=)")
    project = uppercase(strip(get(c.params, "project", "")))
    isempty(project) && error("A record is uploaded to a project: name it (?project=)")
    need_project!(c.kb, c.caller, project, CONTRIBUTE)
    bytes = body_bytes(c)
    isempty(bytes) && error("$name is empty")
    length(bytes) <= UPLOAD_RECORD_MAX || error("$name is larger than $(UPLOAD_RECORD_MAX ÷ 1_000_000) MB")
    date = strip(get(c.params, "date", ""))
    dir = mktempdir()
    try
        # The file keeps its name, so a source tells what it is by it.
        path = joinpath(dir, replace(name, r"[^A-Za-z0-9._ -]" => "_"))
        write(path, bytes)
        run = upload_record!(c.kb, path; name, date = isempty(date) ? nothing : date, project, by = adder(nothing, c.caller),
                             source = get(c.params, "source", ""))
        Dict("source" => run.source.name, "ids" => run.ids, "added" => run.added, "changed" => run.changed, "skipped" => run.skipped)
    finally
        rm(dir; recursive = true, force = true)
    end
end

"The largest file uploaded as records."
const UPLOAD_RECORD_MAX = 50_000_000
