# `zemi obsidian`: the Obsidian plugin (`obsidian/` in the package) built with the Node the site is
# built with, and installed into a vault, where Obsidian lists it under Community plugins.

"The plugin's source, in the package."
plugin_source() = pkgdir(@__MODULE__, "obsidian")

"What a vault's copy of the plugin is: what Obsidian loads."
const PLUGIN_FILES = ("main.js", "manifest.json", "styles.css")

"Where the plugin is built: a copy of its source beside its npm packages, so the package's own folder, read-only once installed, is never written."
plugin_build_dir() = joinpath(xdg_home("XDG_CACHE_HOME", ".cache"), "zemi", "obsidian")

"""
    build_plugin(node, dir)

Build the plugin in `dir` (its `main.js`) with `node` (`DocumenterVitepress.node`, as
[`vitepress`](@ref) is given it): its npm packages installed first when its `package.json` is new to them.
"""
function build_plugin(node::Function, dir::AbstractString)
    node(; adjust_PATH = true, adjust_LIBPATH = true) do exe
        withenv("PATH" => dirname(exe) * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
            npm = npm_cli(exe)
            stamp = joinpath(dir, "node_modules", ".zemi-package.json")
            if !isfile(stamp) || read(stamp) != read(joinpath(dir, "package.json"))
                run(Cmd(`$exe $npm install --no-audit --no-fund`; dir))
                cp(joinpath(dir, "package.json"), stamp; force = true)
            end
            run(Cmd(`$exe $npm run build`; dir))
        end
    end
    return nothing
end

"""
    built_plugin(c; build) -> String

The folder of the plugin built from the package's source, returned with its `main.js`. `build(dir)`
builds it there; by default, in a Julia of the site's environment, which has DocumenterVitepress's Node.
"""
function built_plugin(c::Config; build = dir -> run_plugin_build(c, dir))
    dir = mkpath(plugin_build_dir())
    for name in readdir(plugin_source())
        name in ("node_modules", "main.js") && continue
        cp(joinpath(plugin_source(), name), joinpath(dir, name); force = true)
    end
    rm(joinpath(dir, "main.js"); force = true)
    build(dir)
    isfile(joinpath(dir, "main.js")) || error("The plugin's build wrote no main.js in $dir")
    return dir
end

function run_plugin_build(c::Config, dir::AbstractString)
    script = """
        import DocumenterVitepress, Zemi
        Zemi.build_plugin(DocumenterVitepress.node, ARGS[1])
        """
    run(setenv(`$(Base.julia_cmd()) --project=$(install_docs_env(c)) -e $script $dir`, build_env()))
end

"Obsidian's own settings folder, where it lists the vaults it has opened."
obsidian_settings_dir() =
    Sys.isapple() ? joinpath(homedir(), "Library", "Application Support", "obsidian") :
    Sys.iswindows() ? joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "obsidian") :
    joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "obsidian")

"The vaults Obsidian has opened on this machine, as their folders."
function obsidian_vaults(settings::AbstractString = obsidian_settings_dir())
    file = joinpath(settings, "obsidian.json")
    isfile(file) || return String[]
    vaults = get(JSON.parsefile(file), "vaults", Dict())
    return sort!([String(v["path"]) for v in values(vaults) if haskey(v, "path") && isdir(v["path"])])
end

"""
    find_vault(name, known) -> String

The vault `name` names: a folder holding `.obsidian`, or the last part of one of `known`'s. With no
`name`, the one vault known.
"""
function find_vault(name::AbstractString, known::AbstractVector{<:AbstractString})
    listed = isempty(known) ? "" : ". Obsidian knows: " * join(known, ", ")
    if isempty(name)
        length(known) == 1 && return only(known)
        error("Name the vault to install it in" * (isempty(known) ? ": Obsidian lists none on this machine" : listed))
    end
    path = expand_home(name)
    isdir(joinpath(path, ".obsidian")) && return abspath(path)
    named = filter(v -> basename(rstrip(v, ('/', '\\'))) == name, known)
    length(named) == 1 && return only(named)
    error(isempty(named) ? "No vault $name (a folder holding .obsidian)$listed" : "More than one vault is named $name: give its folder")
end

"""
    install_plugin!(vault, built) -> String

Copy the plugin `built` into `vault`'s plugins and turn it on there: Obsidian loads it when it next
starts or reloads, once community plugins are allowed in the vault. Returns the folder it went to.
"""
function install_plugin!(vault::AbstractString, built::AbstractString)
    manifest = JSON.parsefile(joinpath(built, "manifest.json"))
    to = mkpath(joinpath(vault, ".obsidian", "plugins", manifest["id"]))
    for f in PLUGIN_FILES
        cp(joinpath(built, f), joinpath(to, f); force = true)
    end
    on = joinpath(vault, ".obsidian", "community-plugins.json")
    ids = isfile(on) ? Vector{String}(JSON.parsefile(on)) : String[]
    manifest["id"] in ids || write(on, JSON.json([ids; manifest["id"]]))
    return to
end

"""
    plugin_settings!(to, site, folder)

Point the plugin installed at `to` at the knowledge base at `site` and at the vault's `folder` in
one's library, keeping the rest of its settings (a sign-in to the same site stays). It is given the
file asking whoever syncs the folders for a pass now (`syncNow`, see [`request_pass`](@ref)), which
it touches once a note is saved.
"""
function plugin_settings!(to::AbstractString, site::AbstractString, folder::AbstractString)
    file = joinpath(to, "data.json")
    d = isfile(file) ? JSON.parsefile(file) : Dict{String,Any}()
    d["site"], d["folder"], d["syncNow"] = site, folder, connect_request_path()
    write(file, JSON.json(d))
end

"Where the plugin reaches the knowledge base `zemi connect` names `site`: the address it is opened at, for the one run here."
function plugin_site(site::AbstractString, c::Config)
    site == "local" || return String(site)
    s = local_served(c)
    return s === nothing ? "http://localhost:$(local_port(c))" : s.url
end

"""
    obsidian_cli(args) -> Vector{String}

`zemi obsidian [VAULT] [--name NAME]`: build the plugin and install it in VAULT, and have `zemi
connect` keep the vault in step with one's library (as NAME), as the plugin needs: at the site it
keeps folders at, else the knowledge base run here, which then syncs them while it runs when nothing
else does. The plugin is pointed at the site and the folder. Returns what to tell.
"""
function obsidian_cli(args::AbstractVector{<:AbstractString}; build = nothing, known = obsidian_vaults())
    named = findfirst(==("--name"), args)
    name = named === nothing || named == length(args) ? nothing : args[named+1]
    plain = [a for (j, a) in enumerate(args) if !startswith(a, "--") && (named === nothing || j != named + 1)]
    vault = find_vault(isempty(plain) ? "" : plain[1], known)
    c = load_config()
    built = build === nothing ? built_plugin(c) : built_plugin(c; build)
    to = install_plugin!(vault, built)
    v = JSON.parsefile(joinpath(built, "manifest.json"))["version"]
    say(:ok, "Installed Zemi's plugin $v", ("In", contractuser(to)))

    cc = load_connect_config()
    i = findfirst(f -> same_path(expand_home(f["path"]), vault), get(cc, "folders", Any[]))
    if i === nothing || (name !== nothing && cc["folders"][i]["name"] != name)
        site = default_connect_site()
        f = connect_folder!(site, vault; name)
    else
        site, f = cc["site"], cc["folders"][i]
        say(:ok, "$(f["name"]) already syncs with $(site_label(site))")
    end
    if !synced_by_local() && syncing_pid() === nothing
        if site == "local"
            told = set_background!(true)
            say(:ok, "The knowledge base on this machine syncs it while it runs" * (told ? "" : ", from its next start"),
                ("To stop", "zemi connect --stop"))
        else
            say(:info, "To keep it synced", ("Watch it", "zemi connect"), ("Or", "zemi connect --background", "syncs after each login"))
        end
    end
    address = plugin_site(site, c)
    plugin_settings!(to, address, f["name"])
    return ["In Obsidian: reload it (or the app), and allow community plugins in the vault if it asks.",
            "Then sign in from the plugin's settings, to $address." *
            (site == "local" ? " Your default browser needs the knowledge base's key: run zemi open first if it has not opened it." : "")]
end
