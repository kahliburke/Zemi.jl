# The demo knowledge base, served as `zemi` serves one for one person, at http://localhost:8020
# (ZEMI_PORT for another): `julia --project=app demo/serve.jl`. Its data is kept in
# ~/.cache/zemi/demo/serve between runs.
#
# With `--shared`, as a group's shared service instead, signed in on this machine (local sign-in) as
# rowan@example.org, an admin. Ada and Bea are on the RB board, Ada planning with a task open and a
# comment half written, and the group's agent is at work on a task and waiting for people, for the
# guide's screenshots of working together. Rowan keeps a vault in their library, synced from a
# machine, and RB's library is kept in step with a Zotero group (as last read: the demo reads nothing
# from Zotero).
#
# Without the arXiv watch, and its Kaimon session serves no tools, so it leaves the `zemi` tools of
# another knowledge base on this machine alone. The tutor runs through Kaimon's agents.

include("seed.jl")
import Kaimon               # the agents behind the tutor

ENV["ZEMI_SITE_NOTEBOOKS"] = "0"            # the demo has none
port = parse(Int, get(ENV, "ZEMI_PORT", "8020"))
shared = "--shared" in ARGS
dir = joinpath(DEMO_CACHE, "serve")
ready = joinpath(dir, "ready")                # there once the site is built and served
rm(ready; force = true)

"The demo's people in the shared service, each `(email, name, role, project role)`."
const PEOPLE = [("rowan@example.org", DEMO_USER, "Admin", "maintainer"),
                ("ada@example.org", "Ada", "Learner", "contributor"),
                ("bea@example.org", "Bea", "Learner", "contributor")]

# Ada and Bea on the board, reported as their boards report them, again before they would count as
# gone; and Rowan's machine syncing their library.
function keep_present(kb, ids)
    ada, bea = (K.account_caller(kb, ids[e], :session) for e in ("ada@example.org", "bea@example.org"))
    view = K.JSON.json(Dict("milestone" => "", "declined" => false, "reviewing" => false, "library" => false,
                            "focus" => "RB-10", "hover" => "", "panel" => 0.4, "control" => "comment"))
    while true
        K.report_presence!(ada, "planning"; project = "RB", open = "RB-10", draft_ref = "RB-10",
                           draft = "The 10 m ones: they sit below the thermocline most of the summer, as our deeper", view)
        K.report_presence!(bea, "present"; project = "RB")
        K.agent_seen!("RB-6", "Claude for Rowan")
        K.agent_waiting!("RB", "Claude for Rowan", true)
        K.execute!(kb, "UPDATE api_tokens SET last_used = ? WHERE scope = 'library'", (K.now_iso(),))   # zemi connect syncing
        sleep(20)
    end
end

"Rowan's field notes, an Obsidian vault in their library, each `path => text`."
const VAULT = [
    ".obsidian/app.json" => "{}",
    "Sites/North channel.md" => """
        ---
        tags: [site]
        depth: 3-10 m
        ---
        # North channel

        Exposed to the channel current on the ebb. Macroalgae cover rose from 12 % to 31 % between the
        2025 surveys; turf holds most of the rest. Parrotfish counts are the lowest of the six sites.

        Loggers at 3, 5 and 10 m. The 10 m string sits below the thermocline from December to March.
        """,
    "Sites/Lagoon patch reef.md" => """
        ---
        tags: [site]
        depth: 2-4 m
        ---
        # Lagoon patch reef

        Sheltered, warm, and the first to bleach. Coral cover back to 40 % of its 2023 value; recruits on
        every quadrat since the spring.
        """,
    "Methods/Scoring turf.md" => """
        # Scoring turf

        Turf is scored apart from macroalgae on every quadrat photo: filaments under 1 cm, no upright
        thallus, as [@lindqvist2021surveys, ch. 4] scores it. The crowding model (arXiv:2606.14955) needs
        coral, macroalgae and turf as three cover classes, so a point on turf is never lumped with bare
        substrate.
        """,
    "Reading/Crowding model.md" => """
        ---
        arxiv: "2606.14955"
        tags: [reading]
        ---
        Two grazing thresholds: below the lower one the reef ends macroalgae-dominated whatever its start.
        Our North channel site may already be under it.
        """,
]

"""
Rowan's references, a `.bib` file beside the vault as JabRef keeps it: an arXiv paper, a book, a web
page, and a report whose PDF is not synced.
"""
const REFERENCES = raw"""
    @String{tide = {Tidewater Press}}

    @Article{blackwood2026crowding,
      author        = {Blackwood, Julie C. and Nik, Katerina and Nik, Simon},
      title         = {Dynamics of Coral-Macroalgae Interactions under Crowding},
      year          = {2026},
      eprint        = {2606.14955},
      archivePrefix = {arXiv},
    }

    @Book{lindqvist2021surveys,
      author    = {Lindqvist, Bea and Hale, Rowan},
      title     = {Reef Survey Methods: Transects, Quadrats and Photo Scoring},
      publisher = tide,
      edition   = {2},
      year      = {2021},
    }

    @Online{coastal2026station,
      author  = {{Coastal Data Service}},
      title   = {Tide and Temperature Records, North Channel Station},
      url     = {https://example.org/stations/north-channel},
      date    = {2026},
      urldate = {2026-11-02},
    }

    @TechReport{reefwatch2025bleaching,
      author      = {{Reef Watch Network}},
      title       = {Bleaching Survey of the Lagoon Sites, 2025},
      institution = {Reef Watch Network},
      year        = {2025},
      file        = {:reports/bleaching-2025.pdf:PDF},
    }

    @Comment{jabref-meta: databaseType:biblatex;}
    """

"""
The demo's library, Zotero and jobs, seeded once in the shared service: Rowan's vault and references
read into their library, a note of it shared with RB and one contributed, a machine syncing it, a
Zotero group linked to RB as last read, and a backup run.
"""
function seed_shared!(kb, ids)
    rowan = ids["rowan@example.org"]
    space = "people/$rowan"
    fresh = isempty(K.library_files(kb, space))
    bib = "References/references.bib"           # before the vault is read, so its notes cite by its keys
    any(f -> f.path == bib, K.library_files(kb, space)) || K.put_library_file!(kb, space, bib, Vector{UInt8}(REFERENCES))
    if fresh
        foreach(((p, t),) -> K.put_library_file!(kb, space, "Field notes/" * p, Vector{UInt8}(t)), VAULT)
        K.read_space!(kb, space)
        note(name) = String(K.scalar(kb, """SELECT p.doc_id FROM records r JOIN papers p ON p.id = r.paper_id
                                            WHERE r.source = 'obsidian' AND r.key LIKE ?""", ("%/$name",)))
        caller = K.account_caller(kb, rowan, :session)
        K.share_document!(kb, caller, note("Scoring turf.md"), "projects"; projects = ["RB"])
        K.contribute_document!(kb, caller, note("North channel.md"))
        t = K.create_token!(kb, rowan; name = "zemi connect on field-laptop", permissions = ["library"], days = 0)
        K.execute!(kb, "UPDATE api_tokens SET scope = 'library', last_used = ? WHERE id = ?", (K.now_iso(), t.id))
    end
    group = "5512830"
    if ismissing(K.scalar(kb, "SELECT 1 FROM zotero_links WHERE group_id = ?", (group,)))
        K.execute!(kb, """INSERT INTO zotero_links (group_id, project_id, name, linked_by, linked_at)
                          VALUES (?, (SELECT id FROM projects WHERE key = 'RB'), 'Reef recovery reading', ?, ?)""",
                   (group, "rowan@example.org", K.iso(K.Dates.now(K.Dates.UTC) - K.Dates.Day(12))))
        st = K.source_state(kb, "zotero")
        st["status"] = Dict(group => Dict("read" => K.iso(K.Dates.now(K.Dates.UTC) - K.Dates.Hour(2)), "items" => 38, "error" => ""))
        K.execute!(kb, "INSERT OR REPLACE INTO kv VALUES (?, ?)", (K.source_state_key("zotero"), K.JSON.json(st)))
    end
    K.queue_library!(kb, [space])
    K.start_job(job -> (K.report!(job, "Backing up"); basename(K.backup!(kb.config))), "backup")
end

if shared
    K.LOCAL_SIGN_IN[] = true
    # Providers as a group's would have, for the sign-in page's screenshot: their buttons lead nowhere
    # here, where people sign in on this machine.
    providers = [Dict("name" => "GitHub", "kind" => "github", "client_id" => "demo", "client_secret" => "demo"),
                 Dict("name" => "Google", "issuer" => "https://accounts.google.com", "client_id" => "demo", "client_secret" => "demo")]
    kb = demo_kb(dir; shared = Dict("port" => port, "base_url" => "http://127.0.0.1:$port", "providers" => providers))
    K.ensure_roles!(kb)
    ids = Dict(map(PEOPLE) do (email, name, role, member)
        if ismissing(K.scalar(kb, "SELECT id FROM users WHERE email = ?", (email,)))
            K.invite!(kb, email; roles = [role], projects = Dict("RB" => member, "LS" => member))
        else            # Rowan, whose account the seeding made (see `owner`): their place as the invitation gives it
            foreach(k -> K.set_member!(kb, k, email, member; by = DEMO_USER), ("RB", "LS"))
        end
        email => K.sign_in!(kb, kb.config.shared, "local", email; email, verified = true, name)
    end)
    seed_shared!(kb, ids)
    K.agent_session()
    server = K.serve_shared(; kb)
    errormonitor(@async keep_present(kb, ids))
else
    kb = demo_kb(dir)
    K.agent_session()
    server = K.serve_local(; kb, port, sources = false)
end
while K.SITE.building || K.current_site(kb.config) === nothing        # a build served, from this run or the last
    sleep(2)
end
touch(ready)
println("READY ", shared ? kb.config.shared.base_url : K.local_link(kb.config, port))   # the local one with its key, which the browser keeps
flush(stdout)
wait(server)
