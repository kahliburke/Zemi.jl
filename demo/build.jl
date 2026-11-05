# The site GitHub Pages serves: the guide at its root and the demo's static site under demo/.
#
#     julia --project=app demo/build.jl [out] [store]
#
# `out` is by default ~/.cache/zemi/demo/pages, `store` the demo dataset (see make_dataset.jl).
# ZEMI_PAGES_BASE is the path Pages serves it under, `/Zemi.jl/` by default.

include("seed.jl")

out = abspath(expanduser(get(ARGS, 1, joinpath(DEMO_CACHE, "pages"))))
store = abspath(expanduser(get(ARGS, 2, DEMO_DATASET)))
base = get(ENV, "ZEMI_PAGES_BASE", "/Zemi.jl/")
root = dirname(DEMO)

# The demo, static: built at demo/ under the base, with a notice of what it leaves out.
ENV["ZEMI_SITE_NOTEBOOKS"] = "0"
ENV["ZEMI_SITE_BASE"] = base * "demo/"
ENV["ZEMI_SITE_NOTICE"] = "A static copy of the demo knowledge base: projects, findings, the tutor and " *
    "search by meaning need a running Zemi. <a href=\"$(base)serving\">What a static copy shows</a> · " *
    "<a href=\"$(base)work\">Projects and findings</a>"
work = joinpath(DEMO_CACHE, "build")
kb = demo_kb(work; store)
site = joinpath(work, "site")
rm(site; recursive = true, force = true)
K.default_site_build(site, joinpath(work, "site.log"))

# The guide.
guide = joinpath(root, "guide")
julia(args...) = run(setenv(`$(Base.julia_cmd()) --project=$guide $args`, merge(ENV, Dict("ZEMI_GUIDE_BASE" => base))))
julia("-e", "using Pkg; Pkg.instantiate()")
julia(joinpath(guide, "make.jl"))

rm(out; recursive = true, force = true)
cp(joinpath(guide, "build", "1"), out)
cp(joinpath(site, "1"), joinpath(out, "demo"))
@info "The site for GitHub Pages is in $out"
