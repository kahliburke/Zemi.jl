# Discussing a paper with a tutor: an agent (the configured summarizer) with the paper in front of it
# (its PDF, its text, its summaries, any analysis and notebooks of it, the library's papers nearest it
# and the group's areas of work) and the knowledge base's search, answering a student's questions to
# build their understanding of the paper and its field. Conversations are kept, one or more a paper,
# and each keeps its agent while it is in use.

"What the tutor is told it is: a tutor in the group's field, with the ways it should teach."
tutor_system(c::Config) = """
    You are a patient, knowledgeable tutor$(in_field(c)), working with a student
    who has joined a research group and needs to come up to speed with the state of the art. Far more
    papers appear each year than anyone can read, so your aim is the student's understanding, not a
    summary: help them grasp what this paper does and why it matters, and through it the field around it.

    - Explain the terminology, acronyms, notation and idioms of the field as they come up, as a
      colleague would to a newcomer, without condescension and without skipping steps.
    - Name the systems, devices, codes and methods the paper relies on, and say what each is and does.
    - Place the paper in its literature: what came before it, what it changes, what remains open. Use
      the knowledge base's search to find related papers the group has, and cite them as [arXiv:id].
    - Bring out the open questions in the area and the assumptions results rest on, so the student can
      think critically and talk with confidence to their advisor.
    - Connect the paper to the group's work where it touches it (context.md describes the group).
    - Be precise and honest: say what the paper shows, what it only suggests, and where you are unsure.
      Never invent results, references or numbers; check the paper when in doubt.
    - Teach: build up from what the student knows, use small examples or back-of-envelope estimates,
      and offer a question or two to check understanding when it helps, without quizzing every reply.
    - Pitch explanations to the student's background as they describe it: build up from fundamentals
      for someone early in their studies, focus on what is new for a researcher. Never condescend.
    - You may be given a profile of the student from an optional survey. Treat it only as a guideline
      for tailoring how you explain, to suit their needs. Never include anything from it in what you
      write: do not quote, restate, summarize or allude to it in your replies, notebooks, files or notes,
      and do not mention it unless the student asks about it.
    - This is a conversation, not a lecture. Keep each reply short, a few paragraphs at most: answer the
      question at hand, one idea at a time, then offer where to go next or ask what the student would like
      to explore. Go into depth when they ask for it, not before.
    - Answer promptly. context.md holds the paper's summaries section by section; start from it, and open
      the paper or search the knowledge base only for what the question in front of you needs.
    - Show as well as tell, when a picture explains better than words. What you write into files/ in your
      folder reaches the student: put a figure (.svg or .png) in your reply as ![what it shows](files/name.svg),
      and link an interactive page (.html) as [what it is](files/name.html); it opens in place, under the
      paragraph that links it. The student sees them as you send them, so there is no need to say you
      could not open them. A page must be self-contained, with no external scripts, styles, fonts or
      data. Keep them small, and make them now and then, not with every reply. When you make one, let it
      carry the detail: say in a few lines what it shows and what to try first, and offer to go further.
    - To compute or plot in Julia, use the Slate notebook scratch.jl in your folder through your Slate
      tools: open it, add and run cells, and save figures with CairoMakie, in Makie's dark theme
      (set_theme!(theme_dark())), into files/ by its full path. It is slow the first time, while packages
      load, so tell the student it may take a minute.
    - Write Markdown, with mathematics in LaTeX (\$…\$ inline, \$\$…\$\$ displayed), and code in fenced
      blocks naming the language (```julia).
    """

"""
    tutor_tools() -> Vector{String}

The tools a tutor has beside its file tools (reading the paper's files, writing figures and pages
into its folder; see [`file_tools`](@ref)): the knowledge base's search, and the Slate tools of
[`notebook_hub`](@ref) for its Julia notebook.
"""
tutor_tools() = unique(vcat(["mcp__kaimon__$(MCP_NAMESPACE)_" * t for t in ("search", "read", "paper", "similar", "papers", "records")],
                            notebook_tools()))

"How long a conversation's agent is kept after its last turn."
const CHAT_IDLE = 30 * 60

"What the tutor is doing in each conversation it is answering (reading the paper, searching…), until it writes."
const CHAT_DOING = Dict{String,String}()
const CHAT_LOCK = ReentrantLock()
doing!(chat, says) = lock(() -> (says === nothing ? delete!(CHAT_DOING, chat) : (CHAT_DOING[chat] = says); nothing), CHAT_LOCK)

"""
    chat_context(kb, id) -> String

What a tutor knows of paper `id` before reading it (`context.md`): its record, its summaries
section by section, its classification, any analysis written of it as a paper of the day, its
notebooks, the library's papers nearest it, and the group and its areas of work.
"""
function chat_context(kb::KB, id::AbstractString)
    p = paper_row(kb, id)
    io = IOBuffer()
    println(io, "# [", cited_as(id), "] ", coalesce(p.title, id), "\n")
    note = document_note(kb, id)
    isempty(note) || println(io, note, "\n")
    a = json_list(p.authors)
    isempty(a) || println(io, "Authors: ", join(a, ", "))
    ismissing(p.published) || println(io, "Published: ", p.published)
    ismissing(p.journal_ref) || println(io, "Journal: ", p.journal_ref)
    println(io, "\n## Abstract\n\n", coalesce(p.abstract, ""), "\n")
    who = something(shown_summarizer(kb, id), "")
    sums = query(kb, "SELECT unit_key, text FROM summaries WHERE paper_id = ? AND summarizer = ?", (p.id, who))
    paths = Dict(r.ord => r.path for r in query(kb, "SELECT ord, path FROM sections WHERE paper_id = ?", (p.id,)))
    whole = [r.text for r in sums if startswith(r.unit_key, "p:")]
    isempty(whole) || println(io, "## Summary\n\n", first(whole), "\n")
    parts = [(parse(Int, last(split(r.unit_key, ':'))), r.text) for r in sums if startswith(r.unit_key, "s:")]
    tree = is_kind(k -> k.tree, id)
    sort!(parts; by = ((o, _),) -> tree ? (0, get(paths, o, "")) : (o, ""))      # a codebase's files by path
    if !isempty(parts)
        println(io, "## Its sections, summarized\n")
        foreach(((o, t),) -> println(io, "### ", get(paths, o, "Section $o"), "\n\n", t, "\n"), parts)
    end
    c = classification(kb, id)
    c === nothing || println(io, "## As classified for the group\n\n", JSON.json(c), "\n")
    d = query(kb, "SELECT day, analysis FROM daily WHERE doc_id = ? AND status = 'done' ORDER BY picked_at DESC", (id,))
    isempty(d) || println(io, "## The analysis written of it as the paper of the day, ", first(d).day, "\n\n", coalesce(first(d).analysis, ""), "\n")
    nbs = paper_notebooks(kb, id)
    if !isempty(nbs)
        println(io, "## Its notebooks\n")
        foreach(n -> println(io, "- ", n.title, isempty(n.summary) ? "" : ": " * n.summary), nbs)
        println(io)
    end
    near = related_papers(kb, id; limit = 8)
    if !isempty(near)
        println(io, "## The group's papers nearest it\n")
        for n in near
            s = coalesce(scalar(kb, "SELECT text FROM summaries WHERE paper_id = ? AND unit_key LIKE 'p:%' LIMIT 1", (paper_id(kb, n.doc_id),)), "")
            println(io, "- [arXiv:", n.doc_id, "] ", n.title, isempty(s) ? "" : "\n  " * replace(first(s, 700), "\n" => " "))
        end
        println(io)
    end
    brief = group_brief(kb.config)
    isempty(brief) || println(io, "## The group\n\n", brief)
    return String(take!(io))
end

"Make a conversation's folder: the paper's PDF and text, and `context.md` (see [`chat_context`](@ref))."
function chat_folder(kb::KB, chat::AbstractString, id::AbstractString)
    dir = mkpath(agents_dir("chats", chat))
    mkpath(joinpath(dir, "files"))
    write(joinpath(dir, "context.md"), chat_context(kb, id))
    write(joinpath(dir, "paper.txt"), read_paper(kb, id; max_chars = typemax(Int)))
    f = query(kb, "SELECT path FROM files WHERE paper_id = ?", (paper_id(kb, id),))
    pdf = joinpath(dir, "paper.pdf")
    isempty(f) || ispath(pdf) || symlink(first(f).path, pdf)
    return dir
end

"""
    chat_file(kb, chat, name) -> Union{String,Nothing}

The path of `name`, a file the tutor wrote into conversation `chat`'s `files/`, or `nothing`: only a
plain name of a file directly in that folder is given.
"""
function chat_file(kb::KB, chat::AbstractString, name::AbstractString)
    ismissing(scalar(kb, "SELECT 1 FROM chats WHERE id = ?", (chat,))) && return nothing
    (isempty(name) || name != basename(name) || startswith(name, ".")) && return nothing
    dir = joinpath(agents_dir("chats", chat), "files")
    path = joinpath(dir, name)
    isfile(path) && startswith(realpath(path), realpath(dir) * "/") || return nothing
    return path
end

"""
    chats(kb, id) -> Vector{NamedTuple}

The conversations about paper `id`, latest first: `(; id, title, updated_at, messages)`.
"""
chats(kb::KB, id::AbstractString; user = nothing) =
    [(; id = r.id, title = r.title, updated_at = r.updated_at, messages = r.n)
     for r in query(kb, """SELECT c.id, c.title, c.updated_at, (SELECT count(*) FROM chat_messages m WHERE m.chat_id = c.id) AS n
                           FROM chats c WHERE c.doc_id = ? AND (? IS NULL OR c.user_id = ?) ORDER BY c.updated_at DESC""",
                       (id, something(user, missing), something(user, missing)))]

"The account conversation `chat` belongs to, or `nothing` (one started outside the shared service)."
chat_owner(kb::KB, chat::AbstractString) = (u = scalar(kb, "SELECT user_id FROM chats WHERE id = ?", (chat,)); ismissing(u) ? nothing : Int(u))

"""
    chat_messages(kb, chat) -> NamedTuple

A conversation: `(; id, paper, title, messages)`, each message `(; role, text, status)`, `status`
"done", "thinking" (being written, its text so far) or "failed".
"""
function chat_messages(kb::KB, chat::AbstractString)
    c = query(kb, "SELECT doc_id, title FROM chats WHERE id = ?", (chat,))
    isempty(c) && not_found("No conversation $chat")
    msgs = [(; r.role, r.text, r.status) for r in query(kb, "SELECT role, text, status FROM chat_messages WHERE chat_id = ? ORDER BY ord", (chat,))]
    # The tutor's Julia notebook, once it has opened one: where it can be watched and used.
    agent = scalar(kb, "SELECT agent FROM chats WHERE id = ?", (chat,))
    urls = ismissing(agent) ? String[] : agent_urls(agent)
    return (; id = chat, paper = first(c).doc_id, title = first(c).title, messages = msgs,
            doing = (d = lock(() -> get(CHAT_DOING, chat, ""), CHAT_LOCK); isempty(d) ? nothing : d), notebook = isempty(urls) ? nothing : first(urls))
end

"""
    profile_note(profile) -> String

How a student's tutoring profile (their survey answers, kept in their browser) is put to the tutor:
for pitching its explanations only, never to be repeated. Empty when there is none.
"""
profile_note(profile::AbstractString) = isempty(strip(profile)) ? "" : """
    About the student, from an optional survey they chose to take (anonymous, and possibly incomplete):

    $(strip(profile))

    Treat this only as a guideline for tailoring your explanations to the student's needs. Include nothing
    from it in your replies or in anything you write: do not quote, restate, summarize or allude to it,
    and do not mention it unless the student asks.

    """

"""
    ask_chat!(kb, id, message; chat = nothing, profile = "", user = nothing) -> String

Put `message` to the tutor about paper `id`, in conversation `chat` or a new one, returning the
conversation's id at once: the reply is written as the agent writes it (see [`chat_messages`](@ref)).
`profile` is the student's tutoring profile, from their browser: it goes to the agent with the
message when the conversation starts or the profile has changed (see [`profile_note`](@ref)), and is
not stored: the conversation keeps only its hash, to tell when it changes.
A new conversation belongs to account `user`, when given (in the shared service), and the tutor's
tools act for `caller`.
A paper not yet read is read in full first. A conversation whose agent has gone (idle too long, or
Kaimon restarted) gets a new one, given the conversation so far.
"""
function ask_chat!(kb::KB, id::AbstractString, message::AbstractString; chat = nothing, profile::AbstractString = "", user = nothing,
                   caller::Union{Caller,Nothing} = nothing)
    isempty(strip(message)) && error("Nothing to ask")
    id = only(add_papers!(kb, [id]))
    if chat === nothing
        chat = "c" * string(rand(UInt64); base = 36)
        execute!(kb, "INSERT INTO chats (id, doc_id, title, started_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?, ?)",
                 (chat, id, first(strip(message), 80), now_iso(), now_iso(), something(user, missing)))
    end
    busy = scalar(kb, "SELECT 1 FROM chat_messages WHERE chat_id = ? AND status = 'thinking'", (chat,))
    ismissing(busy) || error("The tutor is still answering in this conversation")
    n = coalesce(scalar(kb, "SELECT max(ord) FROM chat_messages WHERE chat_id = ?", (chat,)), 0)
    execute!(kb, "INSERT INTO chat_messages VALUES (?, ?, 'user', ?, 'done', ?)", (chat, n + 1, message, now_iso()))
    execute!(kb, "INSERT INTO chat_messages VALUES (?, ?, 'tutor', '', 'thinking', ?)", (chat, n + 2, now_iso()))
    execute!(kb, "UPDATE chats SET updated_at = ? WHERE id = ?", (now_iso(), chat))
    reply(text, status = "thinking") = execute!(kb, "UPDATE chat_messages SET text = ?, status = ? WHERE chat_id = ? AND ord = ?",
                                                (text, status, chat, n + 2))
    doing!(chat, "")                                            # answering, from now until it has
    Threads.@spawn try
        if ismissing(scalar(kb, "SELECT 1 FROM parses WHERE paper_id = ?", (paper_id(kb, id),)))
            reply("*Reading the paper in full first…*")
            refresh_metadata!(kb, [id])
            r = only(ingest!(kb, [id]))
            r.ok || error("Reading $id failed: $(r.error)")
        end
        agent = chat_agent(kb, chat, id)
        caller === nothing || act_for!(agent.id, caller)        # its tools act for the student, with their access
        sha = isempty(strip(profile)) ? "" : bytes2hex(sha256(profile))
        told = agent.fresh ? "" : coalesce(scalar(kb, "SELECT profile_sha FROM chats WHERE id = ?", (chat,)), "")
        note = sha == told ? "" : profile_note(profile)
        text = if agent.fresh
            earlier = [m for m in chat_messages(kb, chat).messages[1:end-2] if m.status == "done"]
            "Start from context.md: it summarizes the paper and describes the group. The paper itself is in " *
            "paper.pdf, its text in paper.txt. Your folder is $(agents_dir("chats", chat)).\n\n" * note *
            (isempty(earlier) ? "" : "Our conversation so far:\n\n" *
                join(("**$(m.role == "user" ? "Student" : "You")**: $(m.text)" for m in earlier), "\n\n") * "\n\n") *
            "The student asks:\n\n" * message
        else
            note * message
        end
        execute!(kb, "UPDATE chats SET profile_sha = ? WHERE id = ?", (sha, chat))
        answer = agent_turn(agent.id, text; timeout = 1800, poll = 1.5, partial = t -> reply(t),
                            activity = st -> doing!(chat, st.says))
        doing!(chat, nothing)
        reply(answer, "done")
        execute!(kb, "UPDATE chats SET updated_at = ? WHERE id = ?", (now_iso(), chat))
    catch e
        doing!(chat, nothing)
        @error "The tutor could not answer" chat exception = (e, catch_backtrace())
        reply("The tutor could not answer: " * first(client_message(e), 400), "failed")
    end
    return chat
end

"""
    chat_agent(kb, chat, id) -> (; id, fresh)

The agent of conversation `chat`: the one it has while that is still alive, else a new one in the
conversation's folder (`fresh`, so it is told the conversation so far).
"""
function chat_agent(kb::KB, chat::AbstractString, id::AbstractString)
    was = scalar(kb, "SELECT agent FROM chats WHERE id = ?", (chat,))
    if !ismissing(was)
        st = try kaimon_tool(:agent_status, Dict{String,Any}("agent_id" => was)) catch; nothing end
        st isa AbstractDict && get(st, "status", "dead") in ("idle", "working", "ready") && return (; id = was, fresh = false)
    end
    s = purpose(kb.config, :tutor)
    dir = chat_folder(kb, chat, id)
    agent = open_agent(dir; id = "zemi-chat-" * chat, s.model, tools = tutor_tools(), system = tutor_system(kb.config),
                       effort = kb.config.tutor_effort)
    execute!(kb, "UPDATE chats SET agent = ? WHERE id = ?", (agent, chat))
    start_chat_reaper!(kb)
    return (; id = agent, fresh = true)
end

const CHAT_REAPER = Ref{Union{Task,Nothing}}(nothing)
const CHAT_REAPER_LOCK = ReentrantLock()

"Close conversations' agents left idle longer than [`CHAT_IDLE`](@ref); the conversations are kept."
function start_chat_reaper!(kb::KB)
    @lock CHAT_REAPER_LOCK start_reaper!(kb)
end

function start_reaper!(kb::KB)
    # One ended with the service it ran under (see `stop!`) is started again with the next.
    CHAT_REAPER[] === nothing || istaskdone(CHAT_REAPER[]) || return CHAT_REAPER[]
    CHAT_REAPER[] = Threads.@spawn while !STOPPING[]
        pause(300)
        try
            since = iso_ago(Second(CHAT_IDLE))
            for r in query(kb, """SELECT id, agent FROM chats WHERE agent IS NOT NULL AND updated_at < ?
                                  AND NOT EXISTS (SELECT 1 FROM chat_messages m WHERE m.chat_id = chats.id AND m.status = 'thinking')""", (since,))
                try kaimon_tool(:agent_close, Dict{String,Any}("agent_id" => r.agent)) catch end
                stop_acting!(r.agent)
                execute!(kb, "UPDATE chats SET agent = NULL WHERE id = ?", (r.id,))
            end
        catch e
            (e isa InterruptException || STOPPING[]) && break
            @warn "Closing idle conversations' agents failed" exception = e
        end
    end
end
