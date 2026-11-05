# Make the demo dataset: read the demo's papers with its config's models, build the landscape and
# a paper of the day, and publish them to a directory store. Run once by a maintainer, with Ollama,
# Qdrant and Kaimon (whose agents summarize) at hand:
#
#     julia --project=app demo/make_dataset.jl [store]
#
# The store (by default ~/.local/share/zemi/demo/dataset) is what the demo's other scripts import.

include("demo.jl")
using Zemi
import Kaimon               # the agents that summarize
const K = Zemi

store = abspath(expanduser(get(ARGS, 1, DEMO_DATASET)))
work = joinpath(DEMO_CACHE, "make")
ENV["ZEMI_CONFIG"] = demo_config(work; prefix = "zemi_demo_make",
                                 dataset = Dict("role" => "publish", "stream" => "demo", "store" => "dir:$store"))
kb = K.kb()
say(msg) = @info msg
K.agent_session()

K.ensure_qdrant(kb.config) || error("Qdrant is not answering at $(K.Qdrant.url())")
failed = filter(r -> !r.ok, K.ingest!(kb, PAPERS; progress = say))
isempty(failed) || error("Reading failed: " * join(("$(r.id): $(r.error)" for r in failed), "; "))

# Figures cut from each reading, as WebP: the service's figure sweep, which this script runs itself.
K.cut_papers_figures!(kb; progress = say)
K.webp_figures!(kb; progress = say)

K.landscape!(kb; progress = say)

# The paper of the day, analysed once: a dataset made again keeps the analysis it has.
if ismissing(K.scalar(kb, "SELECT day FROM daily WHERE doc_id = ? AND status = 'done'", (DAILY,)))
    day = K.utc_today()
    K.execute!(kb, "INSERT OR REPLACE INTO daily (day, doc_id, source, why, status, picked_at) VALUES (?, ?, 'library', ?, 'picked', ?)",
               (day, DAILY, "How millimetre-scale texture decides where larvae settle bears on every restoration design the group is weighing.",
                K.now_iso()))
    K.feature_daily!(kb, day, DAILY; progress = say)
end

r = K.publish!(kb; progress = say)
@info "Published the demo dataset to $store" r
