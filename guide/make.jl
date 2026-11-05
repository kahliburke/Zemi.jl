# Zemi's guide: `julia --project=guide guide/make.jl`. The site goes to guide/build/1.
# ZEMI_GUIDE_BASE is the path it is served under (`/Zemi.jl/` on GitHub Pages); "/" by default.

using Documenter, DocumenterVitepress

# The package's look, from the knowledge base site's assets, so there is one copy of each: in
# `public`, which VitePress serves at the site's root.
const PUBLIC = mkpath(joinpath(@__DIR__, "src", "public"))
for f in ("hero-light.svg", "hero-dark.svg", "logo.png", "favicon.ico")
    cp(joinpath(dirname(@__DIR__), "docs", "src", "assets", f), joinpath(PUBLIC, f); force = true)
end

# Every page loads the version list from the repository's root, which deploying versions would write;
# the guide and the demo under it are one version.
write(joinpath(PUBLIC, "versions.js"), "// One version: no version list.\n")

const BASE = get(ENV, "ZEMI_GUIDE_BASE", "/")

"Serves the guide under `BASE`; DocumenterVitepress would put a local build at the root. The config names the base twice."
struct GuideSite <: Documenter.Plugin end
function DocumenterVitepress.vitepress_config_transform(::GuideSite, config::String)
    config = replace(config, r"base: '[^']*'" => "base: '$BASE'")
    # One version of the guide, the one on main: no version picker.
    config = replace(config, r"\{\s*component:\s*'VersionPicker'\s*\},?" => ""; count = 1)
    # The demo is a site of its own beside the guide, so it is left to the browser to load.
    marker = "...navTemp.nav,"
    occursin(marker, config) || (@warn "No `$marker` in the VitePress config; no Demo link in the nav"; return config)
    return replace(config, marker => marker * "\n    { text: 'Demo', link: '/demo/', target: '_self' },"; count = 1)
end

makedocs(;
    root = @__DIR__,
    sitename = "Zemi",
    authors = "Kahli Burke",
    format = MarkdownVitepress(; repo = "github.com/kahliburke/Zemi.jl", devbranch = "main", devurl = "dev",
                               deploy_decision = Documenter.DeployDecision(; all_ok = false)),
    plugins = [GuideSite()],
    remotes = nothing,
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Installation" => "installation.md",
            "Serving modes" => "serving.md",
            "Configuration" => "configuration.md",
            "Models" => "models.md",
            "Projects, records and findings" => "work.md",
            "Datasets" => "datasets.md",
            "Agents and MCP" => "agents.md",
        ],
        "Operations" => [
            "Server deployment" => "deployment.md",
            "Development" => "development.md",
            "Extensions" => "extensions.md",
        ],
    ],
)
