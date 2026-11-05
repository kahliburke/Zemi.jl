# The names things go by in text: arXiv ids, DOIs and titles as they are compared, the references of
# tasks and findings (`KB-12`, `KB-F3`), and the slugs of names in addresses. Each is written once
# here, and what reads one builds on it.

# ── arXiv ids ─────────────────────────────────────────────────────────────────────────────────────

"""
An arXiv id without its version, as a pattern capturing it: new style (`2401.12345`) or old
(`physics/0601001`, `math.GT/0309136`). Patterns finding one in text are built from it.
"""
const ARXIV_ID = raw"(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})"

# An abs/pdf/html address on arXiv, or the DOI arXiv gives a paper (`10.48550/arXiv.2401.12345`).
const ARXIV_URL_ID = Regex("(?:arxiv\\.org/(?:abs|pdf|html)/|10\\.48550/arxiv\\.)$ARXIV_ID(v\\d+)?", "i")
const ARXIV_BARE_ID = Regex("^\\s*(?:arxiv:\\s*)?$ARXIV_ID(v\\d+)?\\s*\$", "i")

"""
    parse_arxiv_id(s) -> Union{Nothing, @NamedTuple{id::String, version::String}}

Pull an arXiv identifier out of an abs/pdf/html URL, arXiv's DOI for it, an `arXiv:` reference or a
bare id. Handles both current (`2401.12345v2`) and old-style (`physics/0601001`) identifiers;
`version` is `""` when none is given.
"""
function parse_arxiv_id(s::AbstractString)
    m = something(match(ARXIV_URL_ID, s), match(ARXIV_BARE_ID, s), Some(nothing))
    m === nothing && return nothing
    return (id = String(m.captures[1]), version = something(m.captures[2], ""))
end

# ── DOIs and titles ───────────────────────────────────────────────────────────────────────────────

"""
A DOI as DOIs are compared: lower case (they are case-insensitive), without a `doi.org` address or
`doi:` before it, nor the punctuation of the sentence it ended.
"""
normalize_doi(d::AbstractString) =
    lowercase(rstrip(replace(strip(d), r"^(?:https?://(?:dx\.)?doi\.org/|doi:\s*)"i => ""), ['.', ',', ';', ')', ']']))

"A title as titles are compared: lower case, accents dropped, and every run of other characters than letters and digits one space."
normalize_title(s) = String(strip(replace(Base.Unicode.normalize(string(s); stripmark = true, casefold = true), r"[^\p{L}\p{N}]+" => " ")))

# ── Tasks and findings ────────────────────────────────────────────────────────────────────────────
# A task is referred to as its project's key and its number (`KB-12`), a finding with an F before
# its number (`KB-F3`). Either is read in any case, and its key upper-cased.

"A project's key as references write it: a letter, then letters and digits."
const PROJECT_KEY = raw"[A-Za-z][A-Za-z0-9]*"
"A task's reference (`KB-12`), for patterns finding one in text to build on."
const TASK_REF = Regex(PROJECT_KEY * raw"-\d+")
"A finding's reference (`KB-F3`, or `kb-f3`), for patterns finding one in text to build on."
const FINDING_REF = Regex(PROJECT_KEY * raw"-[Ff]\d+")

const TASK_PARTS = Regex("^\\s*($PROJECT_KEY)-(\\d+)\\s*\$")
const FINDING_PARTS = Regex("^\\s*($PROJECT_KEY)-[Ff](\\d+)\\s*\$")

"The project key and number of task reference `ref` (`KB-12`), or `nothing` for something else."
task_parts(ref::AbstractString) = (m = match(TASK_PARTS, ref); m === nothing ? nothing : (uppercase(m[1]), parse(Int, m[2])))

"The project key and number of finding reference `ref` (`KB-F3`), or `nothing` for something else."
finding_parts(ref::AbstractString) = (m = match(FINDING_PARTS, ref); m === nothing ? nothing : (uppercase(m[1]), parse(Int, m[2])))

is_task_ref(s::AbstractString) = task_parts(s) !== nothing
is_finding_ref(s::AbstractString) = finding_parts(s) !== nothing

"The project key of a task's or finding's reference (`KB` for `KB-12` and `KB-F3`), or `nothing` for something else."
ref_project(ref::AbstractString) = (p = something(task_parts(ref), finding_parts(ref), Some(nothing)); p === nothing ? nothing : first(p))

# ── Slugs ─────────────────────────────────────────────────────────────────────────────────────────

"""
    slugify(s; keep = "") -> String

`s` as a part of an address or a file name: lower case, each run of characters other than letters,
digits and those in `keep` one `-`, with none at either end (`Campus Login` → `campus-login`).
"""
slugify(s::AbstractString; keep::AbstractString = "") =
    String(strip(replace(lowercase(s), Regex("[^a-z0-9" * join("\\" * c for c in keep) * "]+") => "-"), '-'))
