# The demo knowledge base, served as `zemi` serves one for one person, at http://localhost:8020
# (ZEMI_PORT for another): `julia --project=app demo/serve.jl`. Its data is kept in
# ~/.cache/zemi/demo/serve between runs.
#
# With `--shared`, as a group's shared service instead, signed in on this machine (local sign-in) as
# rowan@example.org, an admin. Ada and Bea are on the RB board, Ada planning with a task open and a
# comment half written, and the group's agent is at work on a task and waiting for people, for the
# guide's screenshots of working together.
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

# Ada and Bea on the board, reported as their boards report them, again before they would count as gone.
function keep_present(kb, ids)
    ada, bea = (K.account_caller(kb, ids[e], :session) for e in ("ada@example.org", "bea@example.org"))
    view = K.JSON.json(Dict("milestone" => "", "declined" => false, "reviewing" => false, "library" => false,
                            "focus" => "RB-5", "hover" => "", "panel" => 0.4, "control" => "comment"))
    while true
        K.report_presence!(ada, "planning"; project = "RB", open = "RB-5", draft_ref = "RB-5",
                           draft = "The 10 m ones: they sit below the thermocline most of the summer, as our deeper", view)
        K.report_presence!(bea, "present"; project = "RB")
        K.agent_seen!("RB-1", "Claude for Rowan")
        K.agent_waiting!("RB", "Claude for Rowan", true)
        sleep(20)
    end
end

if shared
    K.LOCAL_SIGN_IN[] = true
    kb = demo_kb(dir; shared = Dict("port" => port, "base_url" => "http://127.0.0.1:$port"))
    K.ensure_roles!(kb)
    ids = Dict(map(PEOPLE) do (email, name, role, member)
        ismissing(K.scalar(kb, "SELECT id FROM users WHERE email = ?", (email,))) &&
            K.invite!(kb, email; roles = [role], projects = Dict("RB" => member, "LS" => member))
        email => K.sign_in!(kb, kb.config.shared, "local", email; email, verified = true, name)
    end)
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
