"""
The `zemi` app: the knowledge base from the command line, in an environment of its own with Kaimon (its
agents, the gate its tools are served through, the Qdrant it manages) and Revise (code changes applied
while it runs). `./zemi` runs it from a checkout; `pkg> app develop ./app` installs it as `zemi`.

    zemi                serve the knowledge base for whoever runs it, at http://localhost:8000
    zemi dev            for developing it: the site from VitePress's development server, components
                        updated as they are edited
    zemi --shared       serve it to the people signed in to it ([shared] in the config); with
                        --local-sign-in, signing in on this machine as anyone, for trying it
    zemi <command> …    a command; `zemi help` lists them

`ZEMI_REVISE=0` leaves Revise out, for a service that should not follow edits to its source.
"""
module ZemiApp

import Kaimon
import Zemi

"Load Revise and have it follow the knowledge base's code and its plugins', so a running service picks up edits."
function track_code()
    get(ENV, "ZEMI_REVISE", "1") == "1" || return
    try
        # Each at top level, so the second sees the module the first loaded.
        Core.eval(Main, :(using Revise))
        Core.eval(Main, :(Revise.track($Zemi)))
        # The plugins the service loads (see `Zemi.load_plugins!`) are followed the same way.
        Zemi.TRACK_PLUGIN[] = m -> Base.invokelatest(Main.Revise.track, m)
    catch e
        @warn "Revise is not following the code: edits need a restart" exception = e
    end
end

# Output to a file or a pipe (under nohup or a service manager) is buffered until a buffer fills, so
# a log would lag what is happening by minutes; written out every second, it keeps up.
const FLUSHER = Ref{Union{Timer,Nothing}}(nothing)
function flush_output()
    stdout isa Base.TTY && stderr isa Base.TTY && return
    FLUSHER[] = Timer(1; interval = 1) do _
        flush(stdout)
        flush(stderr)
    end
end

"Whether to sign in on this machine without a provider: `--local-sign-in`, or `ZEMI_LOCAL_SIGN_IN=1`."
local_sign_in(args) = "--local-sign-in" in args || get(ENV, "ZEMI_LOCAL_SIGN_IN", "") == "1"

function (@main)(args::Vector{String})
    flush_output()
    cmd = isempty(args) ? "serve" : args[1]
    if cmd == "serve"
        track_code()
        Zemi.run_local()
    elseif cmd == "dev"
        track_code()
        "--shared" in args ? Zemi.run_shared(; kaimon_mode = "--kaimon" in args ? :external : nothing, dev = true,
                                              local_sign_in = local_sign_in(args)) : Zemi.run_dev()
    elseif cmd in ("--shared", "shared")
        track_code()
        # --kaimon: the Kaimon already running on this machine serves the tools and hosts the agents.
        # --local-sign-in: signing in as anyone, for trying the service on this machine.
        Zemi.run_shared(; kaimon_mode = "--kaimon" in args ? :external : nothing, local_sign_in = local_sign_in(args))
    else
        return Zemi.cli(args)
    end
    return 0
end

end
