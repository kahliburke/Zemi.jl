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
            script = joinpath(root, "node_modules", "vitepress", "bin", "vitepress.js")
            run(Cmd(`$exe $script $command $(joinpath(build, ".documenter")) $(collect(args))`; dir = root))
        end
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
