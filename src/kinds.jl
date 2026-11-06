# The kinds of documents: papers, codebases and records. Each kind's entry in `DOCUMENT_KINDS` says what the
# knowledge base does with a document of it (whether it is literature, published, looked up on
# arXiv, how it is read, summarized and shown), and a document's kind is told from its id. Code that
# treats kinds differently asks the entry, so a kind not listed for something is left out of it.

"""
    DocumentKind

A kind of document, as its entry in [`DOCUMENT_KINDS`](@ref):

- `name`: its `kind` in `papers`; `noun`: what one is called (`codebase`); `prefix`: how the ids
  of those added here begin (`doc-`, `code-`)
- `arxiv`: an arXiv id names one too, its record and PDF fetched from arXiv
- `literature`: it is the group's reading: in the lists of papers and the site's pages of them,
  authors, references and the works they cite, topics, the papers `@` finds, the paper of the day
- `cited`: it is in the bibliography, cited by its key (see bibliography.jl)
- `landscape`: it is placed on the landscape
- `pdf`: it is read from a PDF: the PDF reader parses it, its figures are cut, an agent may read the
  PDF itself, and the tutor and notebooks work from it
- `tree`: it is read from a tree of files: each section a file, ordered by path, each directory
  summarized from what it holds, each file a page of its own
- `access`: it may be open only to the members of its projects (see document_access.jl);
  `unassigned`, for such a kind, the permission whose holders alone see one linked to no project
  (`nothing`: no one but whoever runs the knowledge base)
- `site`: its pages are built into the site every reader is served (one with access only while it
  is open); the others' pages the service serves as they are read, to those who may see them
- `classified`: it is classified (see [`classify!`](@ref))
- `summarized`: its summarizer writes summaries of it (and the layers over summaries embed them)
- `published`: one added here is published with the dataset when marked shared (one from arXiv
  always is)
- `category`: what it is classified as, whatever the classifier says (`nothing` to take the
  classifier's, or arXiv's)
- `summarizer`: the config's field naming its summarizer
- `prompts`: its summarizers' prompts: `system(config)`, `section(title, path, text)`,
  `whole(title, abstract, sections)`, and for an agent `agent_system(config)` and
  `agent_brief(reads)`
- `read`: `read(kb, id; force, step)` reads it into sections, blocks and passages, returning
  whether it was read
- `note`: `note(kb, id)`, what a reader or an agent is told of where one came from wherever it is
  given them (`nothing` for a kind that needs no word)
- `page`: `page(slug)` is where its page is, under the knowledge base's pages; `section_page`
  `(slug, section)` where a section's is, for a kind whose sections have pages
"""
Base.@kwdef struct DocumentKind
    name::String
    noun::String = name
    prefix::String
    arxiv::Bool = false
    literature::Bool = false
    cited::Bool = false
    landscape::Bool = false
    pdf::Bool = false
    tree::Bool = false
    access::Bool = false
    unassigned::Union{String,Nothing} = nothing
    site::Bool = true
    classified::Bool = true
    summarized::Bool = true
    published::Bool = false
    category::Union{String,Nothing} = nothing
    summarizer::Symbol
    prompts::NamedTuple
    read::Function
    note::Union{Function,Nothing} = nothing
    page::Function
    section_page::Union{Function,Nothing} = nothing
end

Base.show(io::IO, k::DocumentKind) = print(io, "DocumentKind(", repr(k.name), ")")

# The functions named here are defined with what they read and write; each is called through a
# closure so the table can stand before them.
const PAPER = DocumentKind(;
    name = "paper", prefix = "doc-", arxiv = true, literature = true, cited = true, landscape = true, pdf = true, published = true,
    summarizer = :summarizer,
    prompts = (; system = c -> summary_system(c), section = (t, p, x) -> section_prompt(t, p, x),
                 whole = (t, a, s) -> paper_prompt(t, a, s), agent_system = c -> agent_system(c), agent_brief = r -> agent_brief(r)),
    read = (kb, id; kw...) -> read_pdf!(kb, id; kw...),
    page = slug -> "papers/$slug")

const CODEBASE = DocumentKind(;
    name = "code", noun = "codebase", prefix = "code-", landscape = true, tree = true, access = true, published = true, category = "code",
    summarizer = :code_summarizer,
    prompts = (; system = c -> CODE_SUMMARY_SYSTEM, section = (t, p, x) -> code_section_prompt(t, p, x),
                 whole = (t, a, s) -> code_paper_prompt(t, a, s)),
    read = (kb, id; kw...) -> read_codebase!(kb, id; kw...),
    page = slug -> "code/$slug/", section_page = (slug, section) -> "code/$slug/files/$(file_slug(section))")

# A record of the group's own work (see records.jl): no one sees one before it is linked to a project
# but those who look after the documents.
const RECORD = DocumentKind(;
    name = "record", prefix = "rec-", cited = true, access = true, unassigned = "paper.manage", site = false, classified = false,
    summarizer = :record_summarizer,
    prompts = (; system = c -> record_summary_system(c), section = (t, p, x) -> record_section_prompt(t, p, x),
                 whole = (t, a, s) -> record_prompt(t, a, s), agent_system = c -> record_agent_system(c),
                 agent_brief = r -> record_agent_brief(r)),
    read = (kb, id; kw...) -> read_record!(kb, id; kw...),
    note = (kb, id) -> record_note(kb, id),
    page = slug -> "records/$slug")

# A resource the group uses without reading it in full (see resources.jl): what it says about
# itself is all there is of it, so it is not summarized or classified.
const RESOURCE = DocumentKind(;
    name = "resource", prefix = "res-", cited = true, classified = false, summarized = false,
    summarizer = :summarizer, prompts = (;),
    read = (kb, id; kw...) -> read_resource!(kb, id; kw...),
    note = (kb, id) -> resource_note(kb, id),
    page = slug -> "resources/$slug")

"Every kind of document the knowledge base holds (see [`DocumentKind`](@ref)), in the order ids are told apart."
const DOCUMENT_KINDS = DocumentKind[]

"""
    document_kind!(kind) -> DocumentKind

Add `kind` to [`DOCUMENT_KINDS`](@ref), or replace the kind of its name, so Revise evaluating an edited
entry does not add it twice. Its prefix may not begin another kind's.
"""
function document_kind!(kind::DocumentKind)
    i = findfirst(k -> k.name == kind.name, DOCUMENT_KINDS)
    any(k -> k.name != kind.name && (startswith(k.prefix, kind.prefix) || startswith(kind.prefix, k.prefix)), DOCUMENT_KINDS) &&
        error("The ids of kind $(kind.name) would begin as another kind's: $(kind.prefix)")
    i === nothing ? push!(DOCUMENT_KINDS, kind) : (DOCUMENT_KINDS[i] = kind)
    return kind
end

document_kind!(PAPER)
document_kind!(CODEBASE)
document_kind!(RECORD)
document_kind!(RESOURCE)

"A document's id when it is an arXiv id without its version, as ids are stored."
const ARXIV_DOC_ID = Regex("^$ARXIV_ID\$")

"Whether `id` is an arXiv id (`2401.12345`, `physics/0601001`), as a document's is stored."
is_arxiv_id(id::AbstractString) = occursin(ARXIV_DOC_ID, id)

"The kind of document added here that `id` names by its prefix, or `nothing`."
local_kind(id::AbstractString) = (i = findfirst(k -> startswith(id, k.prefix), DOCUMENT_KINDS); i === nothing ? nothing : DOCUMENT_KINDS[i])

"""
    document_kind(id) -> Union{DocumentKind,Nothing}

The kind of the document `id` names: by its prefix, else the kind arXiv ids name for an arXiv id.
`nothing` for an id of no kind, which is neither a paper nor on arXiv.
"""
function document_kind(id::AbstractString)
    k = local_kind(id)
    k === nothing || return k
    is_arxiv_id(id) || return nothing
    i = findfirst(k -> k.arxiv, DOCUMENT_KINDS)
    return i === nothing ? nothing : DOCUMENT_KINDS[i]
end

"Whether `id` names a document of a kind `f` holds for."
is_kind(f::Function, id::AbstractString) = (k = document_kind(id); k !== nothing && f(k))

"Whether `id` names a codebase."
is_codebase(id::AbstractString) = document_kind(id) === CODEBASE

"Whether `id` names a record."
is_record(id::AbstractString) = document_kind(id) === RECORD

"Whether `id` names a resource."
is_resource(id::AbstractString) = document_kind(id) === RESOURCE

"The layers a document of kind `k` is embedded in, of `layers`: those over summaries only for a kind that is summarized."
kind_layers(k::DocumentKind, layers) = k.summarized ? layers : filter(l -> isempty(l.source), layers)

"Whether `id` names a document of the group's reading (see [`DocumentKind`](@ref))."
is_literature(id::AbstractString) = is_kind(k -> k.literature, id)

"Whether `id` names a document uploaded here as a PDF, not fetched from arXiv."
is_upload(id::AbstractString) = (k = local_kind(id); k !== nothing && k.pdf)

"""
    kind_in(f; on = "") -> String
    kind_in(kind; on = "") -> String

SQL true of a row of `papers` whose kind `f` holds for (or is `kind`), as `kind IN ('paper')`; `on`
names the table's alias. A kind not in `DOCUMENT_KINDS` is never one.
"""
function kind_in(f::Function; on::AbstractString = "")
    names = [k.name for k in DOCUMENT_KINDS if f(k)]
    isempty(names) && return "0"
    return "$(isempty(on) ? "" : on * ".")kind IN ($(join(("'$n'" for n in names), ", ")))"
end
kind_in(kind::DocumentKind; on::AbstractString = "") = kind_in(==(kind); on)

"SQL true of a row of `papers` that is literature (see [`DocumentKind`](@ref)); `on` its table's alias."
literature_sql(; on::AbstractString = "") = kind_in(k -> k.literature; on)

"""
SQL true of a row of `papers` open to every reader: not one of a kind with access (see
document_access.jl) open only to its projects' members; `on` its table's alias.
"""
open_sql(; on::AbstractString = "") =
    "NOT ($(kind_in(k -> k.access; on)) AND $(isempty(on) ? "" : on * ".")access = 'projects')"

"""
The name of the summarizer configured for documents of kind `k` (or document `id`'s, a paper's for an
id of no kind): the paper summarizer where the kind's is not set.
"""
kind_summarizer(c, k::DocumentKind) = (s = getfield(c, k.summarizer); isempty(s) ? c.summarizer : s)
kind_summarizer(c, id::AbstractString) = kind_summarizer(c, something(document_kind(id), PAPER))

"Where document `id`'s page is, under the knowledge base's pages (a paper's, for an id of no kind)."
document_page(id::AbstractString) = something(document_kind(id), PAPER).page(page_slug(id))

"What a reader or an agent is told of where document `id` came from (see [`DocumentKind`](@ref)), empty for most."
document_note(kb, id::AbstractString) = (k = document_kind(id); k === nothing || k.note === nothing ? "" : k.note(kb, id))

"How document `id` is cited in text: `arXiv:` and its id for an arXiv paper, else its id."
cited_as(id::AbstractString) = is_arxiv_id(id) ? "arXiv:" * id : String(id)
