# The demo knowledge base, served as `zemi` serves one for one person, at http://localhost:8020
# (ZEMI_PORT for another): `julia --project=app demo/serve.jl`. Its data is kept in
# ~/.cache/zemi/demo/serve between runs.
#
# Without the arXiv watch, and its Kaimon session serves no tools, so it leaves the `zemi` tools of
# another knowledge base on this machine alone. The tutor runs through Kaimon's agents.

include("seed.jl")
import Kaimon               # the agents behind the tutor

ENV["ZEMI_SITE_NOTEBOOKS"] = "0"            # the demo has none
port = parse(Int, get(ENV, "ZEMI_PORT", "8020"))
kb = demo_kb(joinpath(DEMO_CACHE, "serve"))
K.agent_session()
server = K.serve_local(; kb, port, sources = false)
println("READY ", K.local_link(kb.config, port))           # with its key, which the browser keeps
flush(stdout)
wait(server)
