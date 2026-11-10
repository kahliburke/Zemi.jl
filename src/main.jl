# The zemi app (`pkg> app add Zemi`): serving the knowledge base, for one person or shared, and its
# commands (see `cli`). Where Kaimon runs the knowledge base as its extension, serving is Kaimon's,
# and `zemi` says so instead.

"Whether to sign in on this machine without a provider: `--local-sign-in`, or `ZEMI_LOCAL_SIGN_IN=1`."
local_sign_in(args) = "--local-sign-in" in args || get(ENV, "ZEMI_LOCAL_SIGN_IN", "") == "1"

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

"Have Revise follow the knowledge base's code and its plugins', where it is loaded (a checkout's `./zemi`)."
function track_code()
    isdefined(Main, :Revise) || return
    try
        Base.invokelatest(Main.Revise.track, @__MODULE__)
        TRACK_PLUGIN[] = m -> Base.invokelatest(Main.Revise.track, m)
    catch e
        @warn "Revise is not following the code: edits need a restart" exception = e
    end
end

"Where this knowledge base is served, as its config says: the shared service's address, or this machine's port."
served_address(c::Config) = c.service.mode == :shared ? c.shared.base_url : "http://localhost:$(local_port(c))"

const KAIMON_PANEL = "Kaimon › Extensions › zemi, then [u]"

"""
    kaimon_serves(args) -> Bool

Whether Kaimon runs this knowledge base as its extension, so `zemi` should not serve a second copy:
said, with where it is served and how to run it here instead (`--here`).
"""
function kaimon_serves(args)
    ("--here" in args || !kaimon_runs_zemi()) && return false
    c = try load_config() catch; nothing end
    where = c === nothing ? () : (("Served at", served_address(c), "zemi open, with the key"),)
    say(:info, "Kaimon runs this knowledge base",
        (kaimon_running() ? where : ("Kaimon is not running: start it (`kaimon`), and it starts the knowledge base",))...,
        ("Its panel", KAIMON_PANEL), "",
        "To run it here instead, stop it in Kaimon, or run `zemi --here`.")
    return true
end

"What `zemi kaimon` did (see [`register_extension`](@ref)), said."
function say_registered(result::Symbol)
    c = try load_config() catch; nothing end
    site = c === nothing ? () : (("The site", served_address(c), "zemi open, with the key"),)
    fields = (site..., ("Its panel", KAIMON_PANEL), ("Its log", contractuser(joinpath(kaimon_cache_dir(), "extensions", "zemi.log"))))
    starts = kaimon_running() ? "Kaimon starts it now." : "Start Kaimon (`kaimon`) and it starts the knowledge base with it."
    if result in (:added, :repointed)
        say(:ok, "Zemi is one of Kaimon's extensions",
            "Kaimon starts the knowledge base with itself, and restarts it if it stops:",
            "you no longer run `zemi` yourself. $starts", "", fields...)
    elseif result == :already
        say(:info, "Zemi is already one of Kaimon's extensions", "Kaimon runs the knowledge base: you need not run `zemi`.", "", fields...)
    elseif result == :other
        e = zemi_extension()
        say(:info, "Kaimon runs Zemi from another copy", ("From", contractuser(String(e["project_path"]))), "",
            "To run it from $(contractuser(pkgdir(@__MODULE__))) instead: `zemi kaimon --force`")
    else
        say(:warn, "Kaimon is not installed here",
            "Kaimon runs the knowledge base for you, with agents that summarize and the Qdrant search uses.",
            "Install it with `pkg> app add Kaimon`, run `kaimon` once, then `zemi kaimon` again.", "",
            "Or run the knowledge base on its own: `zemi`")
    end
end

function (@main)(args::Vector{String})
    flush_output()
    try repair_registration!() catch end
    rest = filter(!=("--here"), args)
    cmd = isempty(rest) ? "serve" : rest[1]
    try
        if cmd == "serve"
            kaimon_serves(args) && return 0
            track_code()
            run_local()
        elseif cmd == "dev"
            kaimon_serves(args) && return 0
            track_code()
            "--shared" in args ? run_shared(; kaimon_mode = "--kaimon" in args ? :external : nothing, dev = true,
                                             local_sign_in = local_sign_in(args)) : run_dev()
        elseif cmd in ("--shared", "shared")
            kaimon_serves(args) && return 0
            track_code()
            # --kaimon: the Kaimon already running on this machine serves the tools and hosts the agents.
            # --local-sign-in: signing in as anyone, for trying the service on this machine.
            run_shared(; kaimon_mode = "--kaimon" in args ? :external : nothing, local_sign_in = local_sign_in(args))
        else
            return cli(rest)
        end
    catch e
        e isa InterruptException && return 130
        say(:error, "Zemi did not start", failure_message(e))
        return 1
    end
    return 0
end
