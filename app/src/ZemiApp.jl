"""
The environment a checkout's `./zemi` and the shared server run Zemi in: with Kaimon loaded in the
same process (the shared service's own Kaimon, see `Zemi.start_embedded!`) and Revise (code changes
applied while it runs). The `zemi` app itself is Zemi's (`pkg> app add Zemi`), without either.

`ZEMI_REVISE=0` leaves Revise out, for a service that should not follow edits to its source.
"""
module ZemiApp

import Kaimon
import Zemi

"Load Revise, for the knowledge base to follow its code (see `Zemi.track_code`)."
function load_revise()
    get(ENV, "ZEMI_REVISE", "1") == "1" || return
    try
        Core.eval(Main, :(using Revise))
    catch e
        @warn "Revise is not loaded: edits need a restart" exception = e
    end
end

function (@main)(args::Vector{String})
    load_revise()
    return Base.invokelatest(Zemi.main, args)
end

end
