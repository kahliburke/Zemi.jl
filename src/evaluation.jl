# Measuring retrieval: questions with a known source paper, and how well each ranking (and the
# fused search) finds that paper. Used to decide which layers earn their cost.

"""
    ProbeQuestion

A question whose answer is known to be in `paper`. `kind` is `:broad` (written from the abstract,
as someone who does not know the paper would ask) or `:specific` (written from one passage).
"""
struct ProbeQuestion
    paper::String
    kind::Symbol
    question::String
    source::String
end

const BROAD_QUESTION_PROMPT = """
    Below is the abstract of a research paper. Write one question that a researcher who does not know \
    this paper exists might type into a literature search, and that this paper answers. Use your own \
    words: do not copy distinctive phrases or the title from the abstract. Reply with the question only.

    Abstract:
    """

const SPECIFIC_QUESTION_PROMPT = """
    Below is a passage from a research paper. Write one specific question that this passage answers, as \
    a researcher looking for this detail would phrase it in a literature search. Use your own words: \
    do not copy distinctive phrases from the passage. Reply with the question only.

    Passage:
    """

"""
    probe_questions(kb, summarizer, ids; seed = 1) -> Vector{ProbeQuestion}

Two questions per paper, written by an LLM: a broad one from the abstract and a specific one from a
randomly chosen passage (any but the abstract, which is chunk 0). Questions are stored, so a paper's questions for a
given `seed` are written once and every later evaluation asks the same ones; a new `seed` gives a
new set (and a different passage for the specific question).
"""
function probe_questions(kb::KB, s::Summarizer, ids::AbstractVector{<:AbstractString}; seed::Integer = 1)
    stored(id) = query(kb, "SELECT kind, question, source FROM probes WHERE paper_id = ? AND seed = ?",
                       (paper_id(kb, id), seed))
    jobs = []
    for id in ids
        p = paper_row(kb, id)
        have = Set(r.kind for r in stored(id))
        "broad" in have || isempty(strip(coalesce(p.abstract, ""))) || push!(jobs, (id, p.id, :broad, p.abstract, BROAD_QUESTION_PROMPT))
        "specific" in have && continue
        passages = query(kb, "SELECT text FROM chunks WHERE paper_id = ? AND NOT (ord = 0 AND section = 0) ORDER BY ord", (p.id,))
        isempty(passages) && continue
        # A deterministic pick per (seed, paper), without a global RNG.
        pick = passages[mod(hash((seed, id)), length(passages)) + 1].text
        push!(jobs, (id, p.id, :specific, pick, SPECIFIC_QUESTION_PROMPT))
    end
    asyncmap(jobs; ntasks = 6) do (id, pid, kind, text, prompt)
        q = ask(s, "You write search questions for evaluating a scientific literature search engine.", prompt * text)
        execute!(kb, "INSERT OR IGNORE INTO probes (paper_id, kind, seed, question, source, model, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (pid, string(kind), seed, strip(q, ['"', ' ', '\n']), text, s.model, now_iso()))
    end
    return [ProbeQuestion(id, Symbol(r.kind), r.question, r.source) for id in ids for r in stored(id)]
end

"""
    ProbeRankings

A probe question with each ranking's result for it, computed once by [`probe_rankings`](@ref) so that
fusion settings can be scored without re-running any search.
"""
struct ProbeRankings
    question::ProbeQuestion
    ranked::Vector{Pair{String,Vector{String}}}
end

"""
    probe_rankings(kb, questions; depth = 30) -> Vector{ProbeRankings}

Run every question through every ranking (keyword and each embedded layer, see
[`rankings`](@ref)). This is the expensive part of an evaluation: each question is embedded by each
layer's model and searched in each collection.
"""
probe_rankings(kb::KB, questions::AbstractVector{ProbeQuestion}; depth::Integer = 30) =
    asyncmap(q -> ProbeRankings(q, rankings(kb, q.question; depth)), questions; ntasks = 4)

paper_rank(papers, paper) = something(findfirst(==(paper), papers), 0)

function metrics(ranks)
    n = length(ranks)
    n == 0 && return (; n, hit1 = 0.0, hit5 = 0.0, mrr = 0.0)
    return (; n, hit1 = count(==(1), ranks) / n, hit5 = count(r -> 0 < r <= 5, ranks) / n,
              mrr = sum(r -> r == 0 ? 0.0 : 1 / r, ranks) / n)
end

"""
    score_ranking(prs; weights = nothing, k = RRF_K) -> NamedTuple

How well fused search with these settings finds each question's paper: hit@1, hit@5 and mean
reciprocal rank for broad questions, specific questions and all of them (`mrr_broad`,
`hit5_specific`, `mrr`, …). Cheap enough to call many times, since it only re-fuses the stored
rankings.
"""
function score_ranking(prs::AbstractVector{ProbeRankings}; weights = nothing, k::Real = RRF_K)
    ranks = [(pr.question.kind, paper_rank(ranked_papers(fuse(pr.ranked; weights, k)), pr.question.paper)) for pr in prs]
    b = metrics([r for (kind, r) in ranks if kind == :broad])
    s = metrics([r for (kind, r) in ranks if kind == :specific])
    a = metrics(last.(ranks))
    return (; mrr_broad = b.mrr, hit1_broad = b.hit1, hit5_broad = b.hit5,
              mrr_specific = s.mrr, hit1_specific = s.hit1, hit5_specific = s.hit5,
              mrr = a.mrr, hit1 = a.hit1, hit5 = a.hit5)
end

"""
    probe_passages(kb, questions) -> Dict{String,Tuple{String,String}}

For each specific question, the unit keys of the passage it was written from and of that passage's
section, keyed by the question; questions whose passage is no longer stored (the paper was parsed
again since) are left out.
"""
function probe_passages(kb::KB, questions::AbstractVector{ProbeQuestion})
    out = Dict{String,Tuple{String,String}}()
    for q in questions
        q.kind == :specific || continue
        r = query(kb, "SELECT c.ord, c.section FROM chunks c JOIN papers p ON p.id = c.paper_id WHERE p.doc_id = ? AND c.text = ?",
                  (q.paper, q.source))
        isempty(r) && continue
        out[q.question] = ("c:$(q.paper):$(first(r).ord)", "s:$(q.paper):$(first(r).section)")
    end
    return out
end

"""
    evaluate_rankings(prs; passages = Dict()) -> (summary, details)
    evaluate_rankings(kb, questions; depth = 30)

For every question, the rank at which each ranking first reaches the question's paper, and where
equal-weight fusion of all of them puts it (`level = :paper`). With `passages` (see
[`probe_passages`](@ref)), each specific question is also scored at `level = :passage`: where a
ranking of passages puts the exact passage it was written from, and a ranking of sections that
passage's section. Finding the paper is easy in a small corpus, so the passage level is the one
that tells models apart. `summary` has one row per level, question kind and ranking: hit@1,
hit@5 and mean reciprocal rank (a miss within the search depth counts as 0). `details` has one row
per question, ranking and level.
"""
function evaluate_rankings(kb::KB, questions::AbstractVector{ProbeQuestion}; depth::Integer = 30)
    evaluate_rankings(probe_rankings(kb, questions; depth); passages = probe_passages(kb, questions))
end

function evaluate_rankings(prs::AbstractVector{ProbeRankings}; passages = Dict{String,Tuple{String,String}}())
    details = []
    for pr in prs
        q = pr.question
        target = get(passages, q.question, nothing)
        for (name, keys) in pr.ranked
            papers = unique(split(k, ':')[2] for k in keys)
            push!(details, (; level = :paper, q.kind, ranking = name, rank = paper_rank(papers, q.paper), q.question))
            target === nothing && continue
            unit = isempty(keys) ? "" : first(first(keys), 1)
            unit in ("c", "s") || continue
            push!(details, (; level = :passage, q.kind, ranking = name,
                              rank = something(findfirst(==(unit == "c" ? target[1] : target[2]), keys), 0), q.question))
        end
        push!(details, (; level = :paper, q.kind, ranking = "fused", rank = paper_rank(ranked_papers(fuse(pr.ranked)), q.paper), q.question))
    end
    summary = []
    for level in (:paper, :passage), kind in (:broad, :specific, :all), name in unique(d.ranking for d in details)
        ranks = [d.rank for d in details if d.level == level && d.ranking == name && (kind == :all || d.kind == kind)]
        isempty(ranks) && continue
        m = metrics(ranks)
        push!(summary, (; level, kind, ranking = name, m.n, hit1 = round(m.hit1; digits = 2),
            hit5 = round(m.hit5; digits = 2), mrr = round(m.mrr; digits = 3)))
    end
    return (; summary, details)
end

# ── Judging summaries ────────────────────────────────────────────────────────────────────────────

summary_judge_system(c::Config) = "You are an expert$(in_field(c)) reviewing summaries of sections of research papers " *
                                  "for a research group's knowledge base. Reply with a JSON object only."

# The judge's message in two parts: the paper, the same for every section of it (so a judge with
# prompt caching pays full price for it once per paper), then the section and its summaries.
judge_preamble(paper) = "The whole paper, as extracted from its PDF (equations may be garbled):\n$paper\n\n────────"

function judge_prompt(path, text, labelled; pages = false)
    typeset = pages ? """
        The pages of the paper holding this section are attached as a PDF. The text above and below was extracted
        from them, so its equations may be garbled (fractions flattened, overbars and square roots lost); where they
        differ, the attached pages are what the paper says.

        """ : ""
    """
    $(typeset)The section to be summarized: $path

    Section text:
    $text

    Summaries of this section to review:
    $(join(("[$l]\n$s" for (l, s) in labelled), "\n\n"))

    The summarizers could see the whole paper, so a summary may use other sections for context (notation,
    acronyms, how the section fits the paper). Judge each summary as a summary of this section, checking every
    statement against the paper:
    - "accuracy": 1-5, where 5 means every statement is supported by the paper; lower it for any claim the paper
      contradicts or does not support, including acronym expansions, names and numbers it does not give.
    - "coverage": 1-5, where 5 means it captures all of this section's main points (aims, methods, results,
      conclusions).
    - "specificity": 1-5, where 5 means it keeps the specific quantities, named methods, devices and findings a
      researcher would search for, rather than generic statements.
    - "errors": each statement that is wrong or unsupported by the paper, quoted briefly (an empty list if none).
    Reply with {"A": {"accuracy": n, "coverage": n, "specificity": n, "errors": [...]}, "B": {...}, ...}
    with one entry per summary label.
    """
end

"""
    judge_summaries(kb, [judge,] names; ids, sections = 40, seed = 1, pdf = false, max_chars = 12000, paper_chars = 200_000)
        -> (summary, details, failed)

Have `judge` (a [`Summarizer`](@ref) of either kind, ideally stronger than any it judges; by default
the config's `judge`) compare the
section summaries written by the summarizers named in `names`. Sections of `ids` summarized by all
of them are sampled (deterministically, spread over the papers by `seed`); for each, the judge sees
the whole paper's extracted text, then the section's text and every summary under a shuffled
letter, and scores each for accuracy, coverage and specificity (1-5) and lists its statements the
paper does not support. With `pdf`, the pages the section is on are also attached, cut from the
paper's PDF, for a judge that reads PDFs: extraction loses overbars, fractions and square roots, so
without them a summary true to the typeset paper can be marked wrong.

`summary` has one row per summarizer: the mean scores, errors per section, and the share of
sections with any error. `details` has one row per section and summarizer, with the errors quoted;
`failed` lists sections whose verdict could not be read, which are left out. Verdicts are stored in
the knowledge base, so running again judges only what is missing.
"""
function judge_summaries(kb::KB, judge::Summarizer, names::AbstractVector{<:AbstractString};
                         ids::AbstractVector{<:AbstractString}, sections::Integer = 40, seed::Integer = 1,
                         max_chars::Integer = 12000, paper_chars::Integer = 200_000, pdf::Bool = false,
                         progress = msg -> nothing)
    candidates = []
    for id in ids, s in section_texts(kb, id)
        key = "s:$id:$(s.ord)"
        texts = [scalar(kb, "SELECT text FROM summaries WHERE unit_key = ? AND summarizer = ?", (key, n)) for n in names]
        any(ismissing, texts) || push!(candidates, (; id, s.ord, s.path, text = first(s.text, max_chars), summaries = String.(texts)))
    end
    picked = first(sort(candidates; by = c -> hash((seed, c.id, c.path))), sections)
    preambles = Dict(id => judge_preamble(read_paper(kb, id; max_chars = paper_chars)) for id in unique(c.id for c in picked))
    excerpt(c) = pdf ? section_pages_pdf(kb, c.id, c.ord) : nothing
    labels = string.('A':'Z')[1:length(names)]
    done = Threads.Atomic{Int}(0)
    failed = String[]
    judge_one = function (c)
        order = sort(1:length(names); by = i -> hash((seed, c.path, i)))     # summary order i is shown as labels[j]
        rows = try
            pages = excerpt(c)
            prompt = judge_prompt(c.path, c.text, [labels[j] => c.summaries[i] for (j, i) in enumerate(order)]; pages = pages !== nothing)
            verdict = judge_verdict(kb, judge, preambles[c.id], prompt; pdfs = pages === nothing ? String[] : [pages])
            [(; paper = c.id, section = c.path, summarizer = names[i], accuracy = verdict[labels[j]]["accuracy"],
                coverage = verdict[labels[j]]["coverage"], specificity = verdict[labels[j]]["specificity"],
                errors = String.(get(verdict[labels[j]], "errors", String[])))
             for (j, i) in enumerate(order)]
        catch e
            e isa InterruptException && rethrow()
            push!(failed, "$(c.id) $(c.path): " * first(failure_message(e), 200))
            []
        end
        progress("judged $(Threads.atomic_add!(done, 1) + 1)/$(length(picked)) sections")
        rows
    end
    # One section of each paper first, so a caching judge has the paper cached before the rest arrive.
    firsts = [c for (i, c) in enumerate(picked) if !any(d -> d.id == c.id, picked[1:i-1])]
    judged = [asyncmap(judge_one, firsts; ntasks = 4); asyncmap(judge_one, filter(c -> !any(f -> f === c, firsts), picked); ntasks = 4)]
    details = reduce(vcat, judged; init = [])
    mean(xs) = isempty(xs) ? 0.0 : sum(xs) / length(xs)
    summary = map(names) do n
        rows = [d for d in details if d.summarizer == n]
        (; summarizer = n, sections = length(rows), accuracy = round(mean([r.accuracy for r in rows]); digits = 2),
           coverage = round(mean([r.coverage for r in rows]); digits = 2), specificity = round(mean([r.specificity for r in rows]); digits = 2),
           errors_per_section = round(mean([length(r.errors) for r in rows]); digits = 2),
           sections_with_errors = round(mean([!isempty(r.errors) for r in rows]); digits = 2))
    end
    return (; summary = sort(summary; by = r -> -(r.accuracy + r.coverage + r.specificity)), details, failed)
end

judge_summaries(kb::KB, names::AbstractVector{<:AbstractString}; kw...) =
    judge_summaries(kb, summarizer(kb.config, kb.config.judge), names; kw...)

"""
    section_pages_pdf(kb, doc_id, ord) -> Union{String,Nothing}

A PDF of just the pages section `ord` of the paper is on, cut from the paper's PDF and kept under
`~/.cache/zemi/section-pages`; `nothing` when the paper has no PDF. The file is named
from the source PDF's hash and the page range, which identify its content.
"""
function section_pages_pdf(kb::KB, doc_id::AbstractString, ord::Integer)
    pid = paper_id(kb, doc_id)
    f = query(kb, "SELECT path, sha256 FROM files WHERE paper_id = ?", (pid,))
    (isempty(f) || !isfile(first(f).path)) && return nothing
    r = only(query(kb, "SELECT min(page) AS a, max(page) AS b FROM blocks WHERE paper_id = ? AND section = ?", (pid, ord)))
    ismissing(r.a) && return nothing
    dir = mkpath(joinpath(xdg_home("XDG_CACHE_HOME", ".cache"), "zemi", "section-pages"))
    out = joinpath(dir, "$(first(first(f).sha256, 16))-p$(r.a)-$(r.b).pdf")
    isfile(out) || run(pipeline(`$(kb.config.mutool) merge -o $out $(first(f).path) $(r.a)-$(r.b)`; stdout = devnull, stderr = devnull))
    return out
end

# Verdicts are stored, keyed by judge model, message and attached files (by name: the names say what
# the files hold), so a judgement is paid for once: repeating a run, after a failure or a restart,
# judges only what is missing.
function judge_verdict(kb::KB, judge::Summarizer, preamble::AbstractString, prompt::AbstractString;
                       pdfs::AbstractVector{<:AbstractString} = String[])
    key = text_sha(join([judge.model, preamble, prompt, basename.(pdfs)...], "\0"))
    stored = scalar(kb, "SELECT verdict FROM judgements WHERE key = ?", (key,))
    ismissing(stored) || return JSON.parse(stored)
    reply = ask(judge, summary_judge_system(kb.config), prompt; preamble, pdfs)
    verdict = reply_json(reply, "The judge")
    execute!(kb, "INSERT OR REPLACE INTO judgements VALUES (?, ?, ?, ?)", (key, judge.model, JSON.json(verdict), now_iso()))
    return verdict
end
