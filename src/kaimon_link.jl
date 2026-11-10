# The Kaimon installed on this machine, found without loading it: where it keeps its config and
# cache, whether it is running, the Qdrant it runs, and Zemi's place among its extensions. Zemi talks
# to a running Kaimon through KaimonGate (its agents); the full Kaimon package is loaded only where
# Kaimon runs Zemi as its extension, or embeds one in the shared service.

"Kaimon's config folder (`KAIMON_CONFIG_DIR`, else `~/.config/kaimon`; `%APPDATA%\\Kaimon` on Windows), as Kaimon finds it."
function kaimon_config_dir()
    d = get(ENV, "KAIMON_CONFIG_DIR", "")
    isempty(d) || return d
    Sys.iswindows() && return joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Kaimon")
    return joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "kaimon")
end

"Kaimon's cache folder (`KAIMON_CACHE_DIR`, else `~/.cache/kaimon`; `%LOCALAPPDATA%\\Kaimon` on Windows), as Kaimon finds it."
function kaimon_cache_dir()
    d = get(ENV, "KAIMON_CACHE_DIR", "")
    isempty(d) || return d
    Sys.iswindows() && return joinpath(get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")), "Kaimon")
    return joinpath(xdg_home("XDG_CACHE_HOME", ".cache"), "kaimon")
end

"Whether Kaimon is installed for this account: its config folder exists."
kaimon_installed() = isdir(kaimon_config_dir())

"Whether a Kaimon server runs on this machine for this account: its service endpoint is there."
kaimon_running() = Sys.iswindows() || ispath(joinpath(KaimonGate.sock_dir(), "kaimon-service.sock"))

# ── Its Qdrant ────────────────────────────────────────────────────────────────────────────────────

"Kaimon's search settings (`search.json` in its config folder), or none."
kaimon_search_settings() = (f = joinpath(kaimon_config_dir(), "search.json"); try JSON.parsefile(f) catch; Dict{String,Any}() end)

"Kaimon's setting `section.key`: its environment variable first, as Kaimon reads it, then its search settings."
function kaimon_setting(section::AbstractString, key::AbstractString, env::AbstractString, default)
    v = strip(get(ENV, env, ""))
    isempty(v) || return String(v)
    x = get(get(kaimon_search_settings(), section, Dict()), key, nothing)
    return x === nothing || (x isa AbstractString && isempty(strip(x))) ? default : x
end

"Whether process `pid` is running here."
pid_alive(pid::Integer) = pid > 0 && (Sys.iswindows() ? true : success(pipeline(`kill -0 $pid`; stderr = devnull)))

"""
    kaimon_qdrant() -> Union{Tuple{String,String},Nothing}

The Qdrant the Kaimon here uses, `(url, key)`: one configured for it (`qdrant.url`), or the one it
runs, from the record that one keeps of itself (`server.json` where Kaimon stores it) while its
process lives. `nothing` without Kaimon or a Qdrant of its own running.
"""
function kaimon_qdrant()
    kaimon_installed() || return nothing
    url = String(kaimon_setting("qdrant", "url", "KAIMON_QDRANT_URL", ""))
    isempty(url) || return (String(rstrip(url, '/')), String(kaimon_setting("qdrant", "api_key", "KAIMON_QDRANT_API_KEY", "")))
    root = abspath(expanduser(String(kaimon_setting("qdrant", "storage_dir", "KAIMON_QDRANT_STORAGE", joinpath(kaimon_cache_dir(), "qdrant")))))
    r = try JSON.parsefile(joinpath(root, "server.json")) catch; return nothing end
    (get(r, "host", "") == gethostname() && pid_alive(Int(get(r, "pid", 0)))) || return nothing
    return ("http://127.0.0.1:$(r["port"])", String(get(r, "key", "")))
end

# ── Zemi among its extensions ─────────────────────────────────────────────────────────────────────

"Kaimon's registry of the extensions it runs."
extensions_file() = joinpath(kaimon_config_dir(), "extensions.json")

"Whether `path` holds Zemi: a checkout, or a copy Pkg installed."
is_zemi(path::AbstractString) = (f = joinpath(path, "Project.toml"); isfile(f) && get(try TOML.parsefile(f) catch; Dict() end, "name", "") == "Zemi")

"""
Whether `path` is a copy of Zemi Pkg installed, `<depot>/packages/Zemi/<slug>`: each version goes
to a folder of its own, which tells an install an update moved from a checkout worked in.
"""
is_depot_copy(path::AbstractString) =
    !isempty(path) && (p = normpath(abspath(path)); basename(dirname(p)) == "Zemi" && basename(dirname(dirname(p))) == "packages")

"Kaimon's registry, its entries and the whole file, or an error when it does not parse (writing it then would lose the others)."
function read_extensions()
    f = extensions_file()
    isfile(f) || return Dict{String,Any}("extensions" => Any[])
    data = try JSON.parsefile(f) catch; error("Kaimon's $f does not parse: fix or remove it first") end
    data isa AbstractDict || error("Kaimon's $f is not a registry of extensions")
    get(data, "extensions", nothing) isa AbstractVector || (data["extensions"] = Any[])
    return data
end

write_extensions(data) = (mkpath(dirname(extensions_file())); write(extensions_file(), JSON.json(data, 2)); nothing)

"The entries in `data` that run Zemi: a checkout of it, a copy installed, or one an update left behind."
zemi_entries(data) = [e for e in data["extensions"] if e isa AbstractDict &&
                      (p = String(get(e, "project_path", "")); is_zemi(p) || is_depot_copy(p))]

"""
    zemi_extension() -> Union{Dict,Nothing}

Zemi's entry among the Kaimon here's extensions (its `project_path`, and whether it is `enabled` and
starts with Kaimon), or `nothing`.
"""
zemi_extension() = (es = try zemi_entries(read_extensions()) catch; [] end; isempty(es) ? nothing : first(es))

"Whether Kaimon runs this knowledge base: Zemi is among its extensions, enabled and starting with it."
kaimon_runs_zemi() = (e = zemi_extension(); e !== nothing && get(e, "enabled", true) === true && get(e, "auto_start", true) === true)

"""
Whether the entry at `old` should name `new` instead: when `old` is no longer Zemi, or when both are
copies Pkg installed and an update moved it. A second checkout is never repointed.
"""
stale_entry(old::AbstractString, new::AbstractString) =
    !is_zemi(old) || (normpath(abspath(old)) != normpath(abspath(new)) && is_depot_copy(old) && is_depot_copy(new))

"""
    register_extension(; project_path = pkgdir(Zemi), force = false) -> Symbol

`zemi kaimon`: add Zemi to the extensions the Kaimon installed here runs, writing its registry
(Kaimon picks the change up itself). Returns what it did: `:added`, `:repointed` (an entry an update
left behind, or another with `force`), `:already` (this one), `:other` (another checkout, left as it
is), or `:no_kaimon`.
"""
function register_extension(; project_path::AbstractString = pkgdir(@__MODULE__), force::Bool = false)
    kaimon_installed() || return :no_kaimon
    path = abspath(project_path)
    data = read_extensions()
    ours = zemi_entries(data)
    if !isempty(ours)
        any(e -> normpath(abspath(String(e["project_path"]))) == normpath(path), ours) && length(ours) == 1 && return :already
        force || all(e -> stale_entry(String(e["project_path"]), path), ours) || return :other
        prev = first(ours)
        filter!(e -> !any(o -> o === e, ours), data["extensions"])
        push!(data["extensions"], Dict{String,Any}("project_path" => path, "enabled" => get(prev, "enabled", true),
                                                    "auto_start" => get(prev, "auto_start", true)))
        write_extensions(data)
        return :repointed
    end
    push!(data["extensions"], Dict{String,Any}("project_path" => path, "enabled" => true, "auto_start" => true))
    write_extensions(data)
    return :added
end

"""
    repair_registration!() -> Bool

Repoint Zemi's entry among Kaimon's extensions at this copy when an update left it naming the
version replaced (an installed app's folder changes with each version). Only when every entry for
Zemi is stale: a checkout registered is left as it is. Run as the app starts.
"""
function repair_registration!()
    kaimon_installed() || return false
    data = try read_extensions() catch; return false end
    ours = zemi_entries(data)
    me = pkgdir(@__MODULE__)
    (isempty(ours) || me === nothing || !all(e -> stale_entry(String(e["project_path"]), me), ours)) && return false
    register_extension(; project_path = me) == :repointed
end
