# Zemi run by Kaimon as its extension (kaimon.toml): Kaimon starts the process, serves the tools and
# hosts the agents, and the knowledge base starts here as the config's [service] says. The panel in
# Kaimon's Extensions tab (tui_panel.jl) shows how it is going, and changes the settings that say how
# it runs, which restart it in this process.

"Whether Kaimon runs this process as Zemi's extension."
hosted() = get(ENV, "KAIMON_EXTENSION", "") == MCP_NAMESPACE

"What the hosted knowledge base serves, while it does."
const HOST = Ref{Union{Running,Nothing}}(nothing)
"How the hosted knowledge base is: `starting`, `running`, `stopping`, `stopped` or `failed` (with `HOST_ERROR`)."
const HOST_STATE = Ref("stopped")
const HOST_ERROR = Ref("")
"How the hosted site is built (see [`build_site!`](@ref)): another for trying the hosting without building it."
const HOST_BUILD = Ref{Any}(default_site_build)
"One start, stop or restart at a time."
const HOST_LOCK = ReentrantLock()
const PANEL_FEED = Threads.Atomic{Bool}(false)

"""
    host!() -> Task

Start the knowledge base Kaimon hosts, in the background, as `[service]` says: for one person, or
the shared service, built or for development. The panel is told how it is going (see
[`hosted_status`](@ref)) from then on.
"""
function host!()
    start_panel_feed!()
    return Threads.@spawn @lock HOST_LOCK start_hosted!()
end

function start_hosted!()
    HOST_STATE[] = "starting"
    HOST_ERROR[] = ""
    # Kaimon loads Revise before Zemi, which it then follows; the plugins are followed the same way.
    isdefined(Main, :Revise) && (TRACK_PLUGIN[] = m -> Base.invokelatest(Main.Revise.track, m))
    try
        s = kb().config.service
        HOST[] = s.mode == :shared ? start_shared(; dev = s.dev, hosted = true) : start_local(; dev = s.dev, hosted = true, build = HOST_BUILD[])
        HOST_STATE[] = "running"
        @info "Zemi is at $(HOST[].url)"
    catch e
        HOST_STATE[] = "failed"
        HOST_ERROR[] = first(sprint(showerror, e), 2000)
        @error "Zemi did not start" exception = (e, catch_backtrace())
    end
end

function stop_hosted!(; seconds::Real = 15)
    r = HOST[]
    r === nothing && return
    HOST_STATE[] = "stopping"
    stop!(r; seconds)
    HOST[] = nothing
    HOST_STATE[] = "stopped"
end

"""
    restart!() -> Task

Stop the hosted knowledge base and start it again with the config read afresh: after the panel
changes how it runs. The tools stay served throughout.
"""
restart!() = Threads.@spawn @lock HOST_LOCK begin
    stop_hosted!()
    shutdown()                       # opened again with the config as it is now
    start_hosted!()
end

"""
    stop_hosting()

What Kaimon calls as it stops the extension: stop the knowledge base quickly, and close it.
"""
function stop_hosting()
    PANEL_FEED[] = false
    try stop_hosted!(; seconds = 3) catch e; @warn "Stopping the knowledge base failed" exception = e end
    shutdown()
end

"""
    rebuild!()

Build the site again now, as a change to what it is built from would (the build stamp, see
[`rebuild_site!`](@ref)).
"""
rebuild!() = (touch(build_stamp(kb().config)); nothing)

"Open the hosted knowledge base in the browser, with the key that keeps other accounts out."
function open_hosted()
    r = HOST[]
    r === nothing && error("Zemi is not running")
    url = r.mode == :shared ? r.url : r.mode == :dev ? r.url : local_link(kb().config, LOCAL_PORT[])
    cmd = Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start "" $url` : `xdg-open $url`
    run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
    return url
end

# ── Settings ──────────────────────────────────────────────────────────────────────────────────────

"""
The settings the panel changes, which the site's Configuration page does not: how the knowledge base
runs and where on this machine it keeps and finds things. Each a dotted key into the config, what
kind of value it takes (`choice` from `choices`, `bool`, `int`, `path` or `string`), a label, and a
line of help.
"""
const MACHINE_SETTINGS = [
    (key = "service.mode", kind = "choice", choices = ["solo", "shared"], label = "Serve",
     help = "For you alone, or for the people signed in to it ([shared] in the config)"),
    (key = "service.dev", kind = "bool", choices = String[], label = "Development",
     help = "The site from VitePress's development server, components updated as they are edited"),
    (key = "service.port", kind = "int", choices = String[], label = "Port", help = "Where it is served for one person"),
    (key = "service.dev_port", kind = "int", choices = String[], label = "Development port", help = "VitePress's development server"),
    (key = "data_dir", kind = "path", choices = String[], label = "Data folder", help = "The database, the papers and the site's builds"),
    (key = "content_dir", kind = "path", choices = String[], label = "Content folder", help = "Pages, studies and notebooks"),
    (key = "ollama_url", kind = "string", choices = String[], label = "Ollama", help = "Where the embedding models run"),
    (key = "qdrant_url", kind = "string", choices = String[], label = "Qdrant", help = "Empty for the Qdrant Kaimon runs"),
    (key = "mutool", kind = "string", choices = String[], label = "mutool", help = "MuPDF's tool, for reading PDFs and cutting figures"),
]

"Setting `key`'s value in configuration `c`, as the panel shows it."
function machine_setting(c::Config, key::AbstractString)
    v = startswith(key, "service.") ? getfield(c.service, Symbol(key[9:end])) : getfield(c, Symbol(key))
    return v isa Symbol ? string(v) : v
end

"""
    set_machine_setting!(key, value; path = config_path()) -> Config

Change one of the [`MACHINE_SETTINGS`](@ref) in the settings file beside the config, if the
configuration it makes holds as a whole (see [`write_settings!`](@ref)); the knowledge base runs as
it did until restarted (see [`restart!`](@ref)).
"""
function set_machine_setting!(key::AbstractString, value; path::AbstractString = config_path())
    i = findfirst(s -> s.key == key, MACHINE_SETTINGS)
    i === nothing && error("$key is not a setting the panel changes")
    s = MACHINE_SETTINGS[i]
    v = s.kind == "bool" ? (value === true || string(value) in ("true", "1", "yes")) :
        s.kind == "int" ? tryparse(Int, strip(string(value))) :
        strip(string(value))
    v === nothing && error("$(s.label): a whole number")
    s.kind == "choice" && !(v in s.choices) && error("$(s.label): $(join(s.choices, " or "))")
    s.kind == "path" && isempty(v) && error("$(s.label): a folder")
    parts = split(key, '.')
    over = length(parts) == 1 ? Dict{String,Any}(key => v) : Dict{String,Any}(parts[1] => Dict{String,Any}(parts[2] => v))
    return write_settings!(over; path)
end

# ── The panel ─────────────────────────────────────────────────────────────────────────────────────

"""
    hosted_status() -> Dict{String,Any}

How the hosted knowledge base is, for the panel: its state (and error), how it runs and where,
whether the site is building and when the one served was built, where its config is, and the
[`MACHINE_SETTINGS`](@ref) with their values in the config as it is now.
"""
function hosted_status()
    r = HOST[]
    c = try load_config() catch; kb().config end
    served = try current_site(c) catch; nothing end
    built = served === nothing ? "" : basename(dirname(served))
    return Dict{String,Any}(
        "state" => HOST_STATE[], "error" => HOST_ERROR[],
        "mode" => r === nothing ? "" : string(r.mode), "url" => r === nothing ? "" : r.url, "api" => r === nothing ? "" : r.api,
        "building" => try site_building(c) catch; false end, "built" => built,
        "config" => config_path(), "settings_file" => settings_path(),
        "settings" => [Dict{String,Any}("key" => s.key, "kind" => s.kind, "choices" => s.choices, "label" => s.label,
                                        "help" => s.help, "value" => machine_setting(c, s.key)) for s in MACHINE_SETTINGS])
end

"Tell the panel how the hosted knowledge base is, every two seconds, while Kaimon hosts it."
function start_panel_feed!()
    Threads.atomic_xchg!(PANEL_FEED, true) && return
    Threads.@spawn while PANEL_FEED[]
        try
            g = GATE[]
            g === nothing || !isdefined(g, :push_panel) || g.push_panel("status", hosted_status())
        catch e
            @debug "Telling the panel failed" exception = e
        end
        sleep(2)
    end
end
