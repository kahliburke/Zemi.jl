# Plugins: packages the config names (`[plugins]`) that the serving processes load, each of which
# registers what it brings in its `__init__`, record sources (see sources.jl) and, if it needs them,
# routes and tools. A plugin is code run in the service with the service's rights, so only plugins
# one trusts are installed; what it hands the knowledge base is still checked and labelled. One that
# fails to load is logged and shown on the Status page, and the service runs on without it.

"""
What became of each plugin the config names: its name, whether it loaded, why not if it did not, and
the sources it registered.
"""
const PLUGINS = Ref(NamedTuple{(:name, :loaded, :error, :sources),Tuple{String,Bool,String,Vector{String}}}[])

"""
What has Revise follow a plugin's code once it is loaded, as it follows Zemi's: set by the `zemi` app
(see app/src/ZemiApp.jl) when Revise is loaded, else nothing.
"""
const TRACK_PLUGIN = Ref{Union{Function,Nothing}}(nothing)

"""
    load_plugins!(c) -> Vector{NamedTuple}

Load the packages `[plugins] load` names from the environment `[plugins] env`, which goes on
`LOAD_PATH` after the environments already there (the app's own first), so a plugin uses the Zemi
and the packages the service runs with. Each package's `__init__` registers its sources
(`record_source!`). A package that is not there, fails to load or registers a source for another
interface ([`PLUGIN_API`](@ref)) is logged and left out. Only the serving processes load plugins.
Returns what became of each (see `PLUGINS`).

A plugin is code run in the service with its rights: install only plugins you trust. What it hands
the knowledge base is still checked and labelled as its source's.
"""
function load_plugins!(c::Config)
    p = c.plugins
    isempty(p.load) && return PLUGINS[]
    if !isempty(p.env)
        isfile(joinpath(p.env, "Project.toml")) || @warn "The plugins' environment $(p.env) has no Project.toml"
        p.env in LOAD_PATH || push!(LOAD_PATH, p.env)
    end
    out = similar(PLUGINS[], 0)
    for name in p.load
        try
            pkg = Base.identify_package(name)
            pkg === nothing && error("No package $name in $(isempty(p.env) ? "the environments loaded" : p.env)")
            m = task_local_storage(:zemi_plugin, name) do
                Base.require(pkg)
            end
            track = TRACK_PLUGIN[]
            track === nothing || try track(m) catch e; @warn "Revise is not following plugin $name" exception = e end
            sources = [s.name for s in SOURCES[] if s.plugin == name]
            @info "Loaded plugin $name" * (isempty(sources) ? ", which registered no source" : ", with source(s) $(join(sources, ", "))")
            push!(out, (; name, loaded = true, error = "", sources))
        catch e
            why = sprint(showerror, e isa LoadError || e isa InitError ? e.error : e)
            @error "Plugin $name did not load; the service runs on without it" exception = (e, catch_backtrace())
            push!(out, (; name, loaded = false, error = first(why, 2000), sources = String[]))
        end
    end
    PLUGINS[] = out
    return out
end
