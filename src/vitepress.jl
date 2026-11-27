# VitePress, run the same way on every system by the Node that DocumenterVitepress brings: npm's and
# VitePress's scripts are given to that `node` directly (Windows can't run them by name), with its
# folder first on the PATH, where the packages' install scripts look for `node`.

"""
    vitepress(node, build, command, args...; install = true)

Run VitePress's `command` (`build`, `dev`) with `args` on the pages DocumenterVitepress wrote into
the build folder `build`, from the folder beside it that holds the site's packages (see
[`site_packages!`](@ref)). npm installs them first; with `install = false`, only where none are.
`node` is DocumenterVitepress's (`DocumenterVitepress.node`), which sets up what Node needs to run.
"""
function vitepress(node::Function, build::AbstractString, command::AbstractString, args::AbstractString...;
                   install::Bool = true)
    build = abspath(build)
    root = dirname(build)
    node(; adjust_PATH = true, adjust_LIBPATH = true) do exe
        withenv("PATH" => dirname(exe) * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
            (install || !isdir(joinpath(root, "node_modules"))) &&
                run(Cmd(`$exe $(npm_cli(exe)) install --no-audit --no-fund`; dir = root))
            command == "dev" && native_watcher!(exe, root)
            script = joinpath(root, "node_modules", "vitepress", "bin", "vitepress.js")
            run(Cmd(`$exe $script $command $(joinpath(build, ".documenter")) $(collect(args))`; dir = root))
        end
    end
    return nothing
end

"""
    native_watcher!(node, root)

On macOS, the file watcher VitePress's dev server uses (`fsevents`) in the packages at `root`, where
npm left it out: the npm beside DocumenterVitepress's Node runs a build for it that fails, though it
comes built, and drops it as optional. Without it the dev server watches the site's files by
checking each over and over. Installed at the version the lockfile names, without its scripts.
"""
function native_watcher!(node::AbstractString, root::AbstractString)
    Sys.isapple() || return nothing
    isdir(joinpath(root, "node_modules", "fsevents")) && return nothing
    lock = joinpath(root, "package-lock.json")
    isfile(lock) || return nothing
    version = get(get(get(JSON.parsefile(lock), "packages", Dict()), "node_modules/fsevents", Dict()), "version", nothing)
    version === nothing && return nothing
    try
        run(Cmd(`$node $(npm_cli(node)) install fsevents@$version --no-save --ignore-scripts --no-audit --no-fund`; dir = root))
    catch e
        @warn "The dev server's file watcher could not be installed: it checks the site's files over and over instead" exception = e
    end
    return nothing
end

"npm's script, which Node's builds keep under `lib` on Unix and beside `node` on Windows."
function npm_cli(node::AbstractString)
    bin = dirname(node)
    for path in (joinpath(bin, "..", "lib", "node_modules", "npm", "bin", "npm-cli.js"),
                 joinpath(bin, "node_modules", "npm", "bin", "npm-cli.js"))
        isfile(path) && return normpath(path)
    end
    error("No npm beside $node")
end
