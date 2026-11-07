# The knowledge base the browser tests run against: a fresh one in a temporary directory, with its
# own config file (the page writer, a process of its own, reads it too), seeded with projects,
# tasks, a finding and a question, run for one person. The API on ZEMI_TEST_API_PORT (8701),
# the pages from VitePress's development server on ZEMI_TEST_SITE_PORT (5181). Prints `READY`
# once both answer, and serves until its input closes; then it stops the development server and
# removes the knowledge base. (Not a signal: Julia stopped by one while compiling can hang.) Run by
# test/browser/run.jl.

using Zemi, Sockets
const K = Zemi

api_port = parse(Int, get(ENV, "ZEMI_TEST_API_PORT", "8701"))
site_port = parse(Int, get(ENV, "ZEMI_TEST_SITE_PORT", "5181"))
dir = mktempdir(; prefix = "zemi-browser-", cleanup = false)
config = joinpath(dir, "config.toml")
write(config, """
    data_dir = "$(joinpath(dir, "data"))"
    collection_prefix = "zemi_browser"
    """)
ENV["ZEMI_CONFIG"] = config
ENV["ZEMI_SITE_NOTEBOOKS"] = "0"            # they cite papers this knowledge base does not have
K.LOCAL_USER[] = "Rowan"

"Projects, tasks in every column, subtasks, a milestone, a plan with mathematics, an agent's question, a finding and a paper."
function seed!(kb)
    me, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    K.create_project!(kb, "Browser tests"; key = "BR", description = "Work the browser tests look at.", by = me)
    K.create_project!(kb, "Other"; key = "OT", by = me)
    K.create_milestone!(kb, "BR", "First"; due = "2026-12-01")
    t1 = K.create_task!(kb, "BR", "Read the reef papers"; status = "ready", milestone = "First",
                        body = "The rate \$\\omega\$ and\n\n\$\$\\int_0^1 x\\,dx\$\$\n\n- one\n- two", by = me)
    K.create_task!(kb, "BR", "Scan the reef crest"; status = "in_progress", subtasks = ["Coarse scan", "Fine scan"], by = me)
    K.create_task!(kb, "BR", "Write it up"; status = "review", by = me)
    K.create_task!(kb, "BR", "Plot the reef patches"; by = bot)                     # proposed
    K.create_task!(kb, "BR", "Done already"; status = "done", by = me)
    K.note_task!(kb, t1, "Which transect first?"; kind = "question", by = bot)
    K.create_task!(kb, "OT", "Something else"; status = "ready", by = me)
    K.create_finding!(kb, "BR", "The crest is sharp"; body = "Measured with \$\\omega\$; see @BR-1.", task = t1, by = me)
    # A paper the references offer after the tasks.
    K.execute!(kb, """INSERT INTO papers (doc_id, title, authors, published, metadata_at, added_at, kind)
                      VALUES ('2609.00001', 'Patches of recovery on bleached reefs', '["Ada Lovelace"]', '2026-09-01', ?, ?, 'paper')""",
               (K.now_iso(), K.now_iso()))
    # One for the Documents page to drop and restore.
    K.execute!(kb, """INSERT INTO papers (doc_id, title, authors, published, metadata_at, added_at, kind)
                      VALUES ('2609.00099', 'Tide gauges along a reef flat', '["Bea Ng"]', '2026-09-02', ?, ?, 'paper')""",
               (K.now_iso(), K.now_iso()))
end

"""
A paper with two figures and a table, read and cut from a PDF made here, with a summary that mentions
a figure and a paper of the day whose analysis discusses them.
"""
function seed_figures!(kb)
    pages = mktempdir()
    write(joinpath(pages, "1.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 18 Tf 72 740 Td (Figures to look at) Tj ET
        BT /F1 10 Tf 72 715 Td (Abstract. A paper with two figures and a table, for the browser tests to look at.) Tj ET
        0 0 1 rg 100 520 200 150 re f
        BT /F1 9 Tf 72 500 Td (Figure 1. A blue box, the first figure, with a caption that spans the page.) Tj ET
        BT /F1 10 Tf 72 470 Td (Body text between the figures, long enough to read as a paragraph of the paper.) Tj ET
        1 0 0 rg 100 260 200 150 re f
        BT /F1 9 Tf 72 240 Td (Figure 2: A red box, the second figure, with a caption that spans the page.) Tj ET
        """)
    write(joinpath(pages, "2.txt"), """
        %%MediaBox 0 0 612 792
        %%Font F1 Helvetica
        BT /F1 10 Tf 72 740 Td (A paragraph that opens the second page, long enough to be read as running text here.) Tj ET
        BT /F1 9 Tf 72 700 Td (Table 1. Two numbers and their names.) Tj ET
        BT /F1 9 Tf 100 680 Td (alpha 1.0) Tj ET
        BT /F1 9 Tf 100 666 Td (beta 2.0) Tj ET
        BT /F1 10 Tf 72 620 Td (Running text after the table, a sentence long enough to read as a paragraph of words.) Tj ET
        """)
    pdf = joinpath(pages, "figures.pdf")
    run(`$(kb.config.mutool) create -o $pdf $(joinpath(pages, "1.txt")) $(joinpath(pages, "2.txt"))`)
    K.UPLOAD_LOOKUP[] = (p; contact = "") -> nothing             # no published record to look for
    id = K.add_pdf!(kb, pdf; title = "Figures to look at")
    K.fetch_pdf!(kb, id)                                     # records the uploaded file, as reading needs
    K.parse_paper!(kb, id)
    K.cut_paper_figures!(kb, id)
    pid = K.paper_id(kb, id)
    # Its second page as a section, whose text and PDF its page offers.
    K.execute!(kb, "INSERT INTO sections VALUES (?, 1, 1, '1', 'Results', 'Results', 2, 2)", (pid,))
    K.execute!(kb, "UPDATE blocks SET section = 1 WHERE paper_id = ? AND page = 2", (pid,))
    K.execute!(kb, "INSERT INTO summaries VALUES (?, ?, ?, 'm', 'v1', 'x', ?, NULL, NULL, ?)",
               (pid, "p:$id", kb.config.summarizer, "Two boxes, as Fig. 2 shows, and a table.\nTopics: boxes", K.now_iso()))
    analysis = "## What it does\n\nAn opening paragraph that names no figure.\n\nThe blue box in Fig. 1 is the first result.\n\n" *
               "Table 1 lists the numbers, and Figs. 1 and 2 compare them.\n"
    K.execute!(kb, """INSERT INTO daily (day, doc_id, source, why, status, analysis, figures, computable, picked_at)
                      VALUES ('2026-10-01', ?, 'library', 'To look at its figures.', 'done', ?, ?, '{}', ?)""",
               (id, analysis, K.JSON.json([Dict("label" => "Figure 1", "why" => "The blue box.", "file" => "fig-1.webp")]), K.now_iso()))
    return id
end

kb = K.kb()
seed!(kb)
figures_paper = seed_figures!(kb)
server = K.serve_local(; kb, port = api_port, site = false)
stop = K.start_dev!(kb; api = "http://127.0.0.1:$api_port", dev_port = site_port)

# VitePress may listen on IPv6 only.
answers(port) = any(ip -> try close(Sockets.connect(ip, port)); true catch; false end, (ip"127.0.0.1", ip"::1"))
t0 = time()
while !answers(site_port)
    time() - t0 > 600 && error("The development server did not start; see $(joinpath(K.dev_dir(kb.config), "server.log"))")
    sleep(1)
end
println("READY api=http://127.0.0.1:$api_port site=http://localhost:$site_port dir=$dir figures=$figures_paper key=$(K.local_key(kb.config))")
flush(stdout)
read(stdin)                                     # until run.jl closes it
stop()
close(server)
rm(dir; recursive = true, force = true)
exit(0)
