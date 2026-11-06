# The demo knowledge base: the demo dataset imported, then the work of the group, which lives in its
# database rather than in a dataset: projects, tasks, notes and findings. Included by the scripts
# that serve or build the demo.

include("demo.jl")
using Zemi
const K = Zemi

"The person the demo runs as, run for one person: tasks are assigned to them or to an agent."
const DEMO_USER = "Rowan"

"""
    demo_kb(dir; store, shared) -> KB

The demo knowledge base in `dir`: its config written there (with `shared` as its `[shared]`), the
dataset at `store` imported, and the group's work seeded the first time.
"""
function demo_kb(dir::AbstractString; store::AbstractString = DEMO_DATASET, shared::AbstractDict = Dict{String,Any}())
    isdir(store) || error("No demo dataset at $store: make it with demo/make_dataset.jl")
    ENV["ZEMI_CONFIG"] = demo_config(dir; prefix = "zemi_demo", shared,
                                     dataset = Dict("role" => "consume", "store" => "dir:$(abspath(store))"))
    K.LOCAL_USER[] = DEMO_USER
    kb = K.kb()
    K.pull!(kb; progress = msg -> @info msg)
    ismissing(K.scalar(kb, "SELECT id FROM projects WHERE key = 'RB'")) && seed_work!(kb)
    return kb
end

"""
    ago(f, kb, days)

Do `f` as the group's work `days` ago: every time it writes is dated then, in working hours.
"""
function ago(f, kb, days::Integer)
    t0 = K.now_iso()
    out = f()
    t1 = K.now_iso()
    at = K.iso(floor(K.Dates.now(K.Dates.UTC), K.Dates.Day) - K.Dates.Day(days) + K.Dates.Hour(9 + 5days % 8) + K.Dates.Minute(7days % 60))
    for t in K.query(kb, "SELECT name FROM sqlite_master WHERE type = 'table'"),
        c in K.query(kb, "SELECT name FROM pragma_table_info(?)", (t.name,))
        (c.name == "at" || endswith(c.name, "_at")) || continue
        K.execute!(kb, "UPDATE \"$(t.name)\" SET \"$(c.name)\" = ? WHERE \"$(c.name)\" BETWEEN ? AND ?", (at, t0, t1))
    end
    return out
end

"""
Projects as the group worked on them over six weeks: a pilot survey finished, a field season under
way with tasks in every column, notes, an agent's plan and question, findings and a library.
"""
function seed_work!(kb)
    rowan, ada, bea, claude = K.person("Rowan"), K.person("Ada"), K.person("Bea"), K.agent("Claude for Rowan")
    move(ref, status, by) = K.update_task!(kb, ref; status, by)

    # The pilot survey, finished four weeks ago.
    ago(kb, 44) do
        K.create_project!(kb, "Recovery after bleaching"; key = "RB", by = rowan,
            description = "How our survey sites recover after the last bleaching event, and what the models say should help.")
        K.create_milestone!(kb, "RB", "Pilot survey"; description = "The sites chosen, the protocol settled and the first loggers in the water.")
        K.create_task!(kb, "RB", "Choose the resurvey sites"; milestone = "Pilot survey", assignee = DEMO_USER, by = rowan,
            body = "Six sites from the 2025 survey: two sheltered, two exposed, two near the channel.")
    end
    sites, memo, protocol, loggers, cleanup = "RB-1", "RB-2", "RB-3", "RB-4", "RB-5"
    ago(() -> move(sites, "in_progress", rowan), kb, 43)
    ago(kb, 43) do
        K.create_task!(kb, "RB", "Survey design memo"; milestone = "Pilot survey", assignee = DEMO_USER, by = rowan,
            body = "Transects, quadrat spacing and the photo protocol for the resurvey.")
    end
    ago(() -> move(memo, "in_progress", rowan), kb, 42)
    ago(kb, 42) do
        K.create_task!(kb, "RB", "Photo-quadrat protocol"; milestone = "Pilot survey", by = bea,
            body = "What each quadrat photo records, and how cover is scored from it.")
    end
    ago(kb, 41) do
        K.create_task!(kb, "RB", "Deploy temperature loggers at 3, 5 and 10 m"; milestone = "Pilot survey", by = ada,
            body = "One string of loggers at each site, read every three months.")
    end
    ago(() -> (move(sites, "done", rowan); move(protocol, "in_progress", bea)), kb, 40)
    ago(kb, 39) do
        K.create_task!(kb, "RB", "Clean and merge the 2025 transect data"; milestone = "Pilot survey", by = claude,
            body = "One table of cover by site, transect and survey, with the species names checked against WoRMS.")
        move(memo, "review", rowan)
    end
    ago(() -> (move(cleanup, "ready", rowan); move(memo, "done", rowan)), kb, 38)
    ago(() -> (move(cleanup, "in_progress", claude); move(loggers, "in_progress", ada)), kb, 37)
    ago(() -> move(protocol, "review", bea), kb, 36)
    ago(kb, 35) do
        move(protocol, "in_progress", rowan)
        K.note_task!(kb, protocol, "Score turf separately from macroalgae: the models need both."; by = rowan)
        move(cleanup, "review", claude)
        K.note_task!(kb, cleanup, "Merged 412 transects; 9 species names corrected."; kind = "progress", by = claude)
    end
    ago(() -> move(cleanup, "done", rowan), kb, 34)
    ago(() -> move(protocol, "review", bea), kb, 33)
    ago(() -> move(protocol, "done", rowan), kb, 32)
    ago(() -> move(loggers, "done", ada), kb, 29)
    ago(() -> K.finish_milestone!(kb, "RB", "Pilot survey"; by = rowan), kb, 28)

    # The field season, under way.
    ago(kb, 27) do
        K.create_milestone!(kb, "RB", "Field season"; due = string(K.Dates.today() + K.Dates.Day(45)),
                            description = "The transects resurveyed and the loggers recovered.")
        K.set_active_milestone!(kb, "RB", "Field season")
    end
    models = ago(kb, 24) do
        K.create_task!(kb, "RB", "Compare recovery models against our transect data"; status = "ready",
            assignee = DEMO_USER, priority = 1, by = rowan,
            subtasks = ["Fit the coral–macroalgae model to cover at each site", "Fit a logistic baseline", "Compare the fits"],
            body = """
                Cover of coral, macroalgae and turf at each site, every survey since the event, against the
                crowding model in @arXiv:2606.14955 and a logistic baseline. The grazing rate is the parameter
                to watch: the model's two thresholds in \$g\$ separate the coral- and macroalgae-dominated states.""")
    end
    ago(() -> K.library_add!(kb, "RB", "2606.14955"; why = "The crowding model we fit to our transects.", by = rowan), kb, 24)
    ago(() -> move(models, "in_progress", rowan), kb, 20)
    heat = ago(kb, 18) do
        K.create_task!(kb, "RB", "Depth-resolved heat exposure for our sites"; by = ada, body = """
            Satellite SST overstates the heat at depth (@arXiv:2604.13131). Constrain a profile at each site with
            our loggers at 3, 5 and 10 m, and give degree heating weeks by depth.""")
    end
    ago(() -> K.library_add!(kb, "RB", "2604.13131"; why = "Heat exposure at depth, from satellite SST and loggers.", by = rowan), kb, 18)
    bleaching = ago(kb, 16) do
        K.create_task!(kb, "RB", "Review bleaching assessment methods for the survey protocol"; by = bea,
            body = "What @arXiv:2511.12234 recommends for modelling bleaching from survey data, and what our protocol should record for it.")
    end
    ago(() -> K.library_add!(kb, "RB", "2511.12234"; why = "What the survey protocol should record for a bleaching assessment.", by = bea), kb, 16)
    ago(() -> move(heat, "ready", ada), kb, 15)
    growth = ago(kb, 14) do
        K.create_task!(kb, "RB", "Fit growth curves to the 2025 cover at each site"; by = claude,
            body = "A biphasic growth curve per site, with its uncertainty, as @arXiv:2406.19591 fits them.")
    end
    ago(() -> move(growth, "ready", rowan), kb, 13)
    ago(() -> (move(growth, "in_progress", claude); move(bleaching, "in_progress", bea)), kb, 12)
    retrieval = ago(kb, 11) do
        K.create_task!(kb, "RB", "Logger retrieval checklist"; by = ada,
            body = "What to bring, and the order to swap and read the loggers at each site.")
    end
    ago(kb, 10) do
        K.create_task!(kb, "RB", "Reading list for new students"; by = ada,
            body = "A path through the library for someone new to reef ecology.")
    end
    ago(() -> move(growth, "review", claude), kb, 9)
    ago(() -> move(growth, "done", rowan), kb, 8)
    ago(() -> move(retrieval, "in_progress", ada), kb, 7)
    ago(kb, 6) do
        K.note_task!(kb, models, "Fitted the crowding model at the two sheltered sites; the macroalgae-dominated state is stable at both."; kind = "progress", by = claude)
    end
    ago(() -> move(retrieval, "done", ada), kb, 5)
    ago(() -> K.note_task!(kb, models, "Can we use the turf cover from the photo transects, or only the quadrat counts?"; by = bea), kb, 4)
    ago(() -> move(bleaching, "review", bea), kb, 3)
    ago(() -> K.note_task!(kb, heat, "Should the logger comparison use the 5 m or the 10 m loggers where a site has both?"; kind = "question", by = claude), kb, 2)
    plan = ago(kb, 1) do
        K.create_task!(kb, "RB", "Map macroalgae cover against fishing pressure across sites"; by = claude,
            subtasks = ["Collect fishing effort per site", "Plot cover against effort", "Mark the model's thresholds"],
            body = """
                The crowding model (@arXiv:2606.14955) and the rate-induced tipping result (@arXiv:2605.23487) both say
                herbivore loss can flip a reef to macroalgae. Plotting our sites' macroalgae cover against fishing effort,
                with the model's grazing thresholds marked, would show which sites are near the edge.""")
    end
    ago(() -> K.library_add!(kb, "RB", "2605.23487"; why = "A slow rise in fishing effort can collapse a reef: the pressure our sites are under.", by = claude), kb, 1)
    K.note_task!(kb, plan, "Fishing effort is in the 2025 creel survey; ask Bea for the export."; by = ada)

    tiles = ago(kb, 30) do
        K.create_project!(kb, "Settlement tiles"; key = "LS", by = ada,
            description = "Textured settlement tiles for restoration: which surface relief gets the most larvae to settle.")
        t = K.create_task!(kb, "LS", "Print tiles with 1, 2 and 4 mm ridges"; status = "ready", by = ada,
            body = "Ridge spacing ten to twenty times the height, after @arXiv:2401.17216; a flat tile as the control.")
        K.create_task!(kb, "LS", "Model near-bed flow over the tile array"; status = "backlog", by = ada,
            body = "The recirculation behind the ridges is what brings larvae down (@arXiv:2203.05645). Does it survive in an array of tiles?")
        K.create_task!(kb, "LS", "Write up the pilot season"; status = "backlog", by = bea)
        t
    end

    ridges = ago(kb, 22) do
        K.create_finding!(kb, "LS", "Millimetre-scale ridges raise coral larval settlement in wave-driven flow, most with ridge spacing ten to twenty times the ridge height";
            task = tiles, by = ada,
            body = """
                A flume experiment found ridged surfaces settle an order of magnitude more larvae than flat ones, and
                simulations of the same flow put the best spacing at ten to twenty ridge heights. Our tiles follow that
                design.""",
            evidence = [(; kind = "paper", target = "2203.05645",
                         excerpt = "millimeter-scale benthic topography increases the settlement of slow-swimming coral larvae by an order of magnitude relative to flat substrates"),
                        (; kind = "paper", target = "2401.17216",
                         excerpt = "ridge spacing-to-height ratios of 10 to 20, spacings of more than 30 coral larval body lengths, resulted in the highest settlement rates")])
    end
    ago(() -> K.update_finding!(kb, ridges; status = "accepted", by = rowan), kb, 21)
    grazing = ago(kb, 9) do
        K.create_finding!(kb, "RB", "Grazing decides whether a recovering reef returns to coral or to macroalgae";
            task = models, by = rowan,
            body = "In the crowding model, two grazing thresholds separate a coral-dominated and a macroalgae-dominated reef, so protecting herbivores belongs in the recovery plan.",
            evidence = [(; kind = "paper", target = "2606.14955",
                         excerpt = "The grazing intensity \$g\$ organizes the dynamics through two thresholds")])
    end
    ago(() -> K.update_finding!(kb, grazing; status = "accepted", by = rowan), kb, 7)
    ago(kb, 2) do
        K.create_finding!(kb, "RB", "Satellite SST alone overstates the heat stress at our deeper sites"; task = heat, by = claude,
            body = "Temperatures at depth run one to three degrees below the surface, so exposure below 5 m should come from logger-constrained profiles.",
            evidence = [(; kind = "paper", target = "2604.13131",
                         excerpt = "applying satellite SST uniformly to all depths therefore overestimates subsurface thermal stress")])
    end
    return kb
end
