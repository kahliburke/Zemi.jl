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

"Projects with tasks in every column, a milestone, notes, an agent's plan and question, findings and a library."
function seed_work!(kb)
    rowan, ada, bea, claude = K.person("Rowan"), K.person("Ada"), K.person("Bea"), K.agent("Claude for Rowan")

    K.create_project!(kb, "Recovery after bleaching"; key = "RB", by = rowan,
        description = "How our survey sites recover after the last bleaching event, and what the models say should help.")
    K.create_milestone!(kb, "RB", "Field season"; due = string(K.Dates.today() + K.Dates.Day(45)),
                        description = "The transects resurveyed and the loggers recovered.")
    models = K.create_task!(kb, "RB", "Compare recovery models against our transect data"; status = "in_progress",
        assignee = DEMO_USER, milestone = "Field season", priority = 1, by = rowan,
        subtasks = ["Fit the coral–macroalgae model to cover at each site", "Fit a logistic baseline", "Compare the fits"],
        body = """
            Cover of coral, macroalgae and turf at each site, every survey since the event, against the
            crowding model in @arXiv:2606.14955 and a logistic baseline. The grazing rate is the parameter
            to watch: the model's two thresholds in \$g\$ separate the coral- and macroalgae-dominated states.""")
    heat = K.create_task!(kb, "RB", "Depth-resolved heat exposure for our sites"; status = "ready", milestone = "Field season",
        by = ada, body = """
            Satellite SST overstates the heat at depth (@arXiv:2604.13131). Constrain a profile at each site with
            our loggers at 3, 5 and 10 m, and give degree heating weeks by depth.""")
    K.create_task!(kb, "RB", "Review bleaching assessment methods for the survey protocol"; status = "review", by = bea,
        body = "What @arXiv:2511.12234 recommends for modelling bleaching from survey data, and what our protocol should record for it.")
    K.create_task!(kb, "RB", "Survey design memo"; status = "done", by = rowan,
        body = "Transects, quadrat spacing and the photo protocol for the resurvey.")
    K.create_task!(kb, "RB", "Reading list for new students"; status = "backlog", by = ada,
        body = "A path through the library for someone new to reef ecology.")
    plan = K.create_task!(kb, "RB", "Map macroalgae cover against fishing pressure across sites"; by = claude,
        subtasks = ["Collect fishing effort per site", "Plot cover against effort", "Mark the model's thresholds"],
        body = """
            The crowding model (@arXiv:2606.14955) and the rate-induced tipping result (@arXiv:2605.23487) both say
            herbivore loss can flip a reef to macroalgae. Plotting our sites' macroalgae cover against fishing effort,
            with the model's grazing thresholds marked, would show which sites are near the edge.""")

    K.note_task!(kb, models, "Fitted the crowding model at the two sheltered sites; the macroalgae-dominated state is stable at both."; kind = "progress", by = claude)
    K.note_task!(kb, models, "Can we use the turf cover from the photo transects, or only the quadrat counts?"; by = bea)
    K.note_task!(kb, heat, "Should the logger comparison use the 5 m or the 10 m loggers where a site has both?"; kind = "question", by = claude)
    K.note_task!(kb, plan, "Fishing effort is in the 2025 creel survey; ask Bea for the export."; by = ada)

    K.create_project!(kb, "Settlement tiles"; key = "LS", by = ada,
        description = "Textured settlement tiles for restoration: which surface relief gets the most larvae to settle.")
    tiles = K.create_task!(kb, "LS", "Print tiles with 1, 2 and 4 mm ridges"; status = "ready", by = ada,
        body = "Ridge spacing ten to twenty times the height, after @arXiv:2401.17216; a flat tile as the control.")
    K.create_task!(kb, "LS", "Model near-bed flow over the tile array"; status = "backlog", by = ada,
        body = "The recirculation behind the ridges is what brings larvae down (@arXiv:2203.05645). Does it survive in an array of tiles?")
    K.create_task!(kb, "LS", "Write up the pilot season"; status = "backlog", by = bea)

    ridges = K.create_finding!(kb, "LS", "Millimetre-scale ridges raise coral larval settlement in wave-driven flow, most with ridge spacing ten to twenty times the ridge height";
        task = tiles, by = ada,
        body = """
            A flume experiment found ridged surfaces settle an order of magnitude more larvae than flat ones, and
            simulations of the same flow put the best spacing at ten to twenty ridge heights. Our tiles follow that
            design.""",
        evidence = [(; kind = "paper", target = "2203.05645",
                     excerpt = "millimeter-scale benthic topography increases the settlement of slow-swimming coral larvae by an order of magnitude relative to flat substrates"),
                    (; kind = "paper", target = "2401.17216",
                     excerpt = "ridge spacing-to-height ratios of 10 to 20, spacings of more than 30 coral larval body lengths, resulted in the highest settlement rates")])
    K.update_finding!(kb, ridges; status = "accepted", by = rowan)
    grazing = K.create_finding!(kb, "RB", "Grazing decides whether a recovering reef returns to coral or to macroalgae";
        task = models, by = rowan,
        body = "In the crowding model, two grazing thresholds separate a coral-dominated and a macroalgae-dominated reef, so protecting herbivores belongs in the recovery plan.",
        evidence = [(; kind = "paper", target = "2606.14955",
                     excerpt = "The grazing intensity \$g\$ organizes the dynamics through two thresholds")])
    K.update_finding!(kb, grazing; status = "accepted", by = rowan)
    K.create_finding!(kb, "RB", "Satellite SST alone overstates the heat stress at our deeper sites"; task = heat, by = claude,
        body = "Temperatures at depth run one to three degrees below the surface, so exposure below 5 m should come from logger-constrained profiles.",
        evidence = [(; kind = "paper", target = "2604.13131",
                     excerpt = "applying satellite SST uniformly to all depths therefore overestimates subsurface thermal stress")])

    K.library_add!(kb, "RB", "2606.14955"; why = "The crowding model we fit to our transects.", by = rowan)
    K.library_add!(kb, "RB", "2604.13131"; why = "Heat exposure at depth, from satellite SST and loggers.", by = rowan)
    K.library_add!(kb, "RB", "2511.12234"; why = "What the survey protocol should record for a bleaching assessment.", by = bea)
    K.library_add!(kb, "RB", "2605.23487"; why = "A slow rise in fishing effort can collapse a reef: the pressure our sites are under.", by = claude)
    return kb
end
