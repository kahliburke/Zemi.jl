# Loaded with Kaimon: hands the knowledge base Kaimon, for its agents (summaries, the tutor,
# notebooks), the gate its tools are served through and the Qdrant it runs (see `KAIMON`,
# `qdrant_endpoint`).
module ZemiKaimonExt

import Zemi
import Kaimon

function __init__()
    Zemi.KAIMON[] = Kaimon
end

end
