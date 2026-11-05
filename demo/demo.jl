# What the demo's scripts share: its papers, and a working config made from config.toml.

using TOML

const DEMO = @__DIR__
"Where the demo's scripts keep what they make, outside the checkout."
const DEMO_CACHE = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "zemi", "demo")
"""
The demo dataset (see make_dataset.jl), which the other scripts import. Not under the cache: making
it again reads and summarizes every paper.
"""
const DEMO_DATASET = joinpath(get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share")), "zemi", "demo", "dataset")

# The papers the demo group has read: each CC BY or CC0 on arXiv, since the demo publishes their
# text and figures.
const PAPERS = [
    "2103.11035",   # CC0    Modeling coral reef bleaching recovery through KCC-theory
    "2511.12234",   # CC BY  Statistical and machine learning approaches for coral bleaching assessment
    "2604.13131",   # CC BY  Depth-resolved coral reef thermal fields from satellite SST and loggers
    "2605.23487",   # CC BY  Rate-induced tipping in a coral reef ecosystem
    "2606.14955",   # CC BY  Dynamics of coral-macroalgae interactions under crowding
    "2209.08974",   # CC BY  Zigzag persistence for coral reef resilience
    "2203.05645",   # CC BY  Millimeter-scale topography enables coral larval settlement
    "2401.17216",   # CC BY  Surface topography and benthic boundary layer flow
    "2405.07491",   # CC BY  Bifurcations and chaos control in a discrete-time coral reef model
    "2310.04887",   # CC BY  Symmetry-based model selection for coral population growth
    "2406.19591",   # CC BY  Uncertainty quantification for biphasic coral growth
    "2111.04003",   # CC BY  Predicting gross community production of coral reefs
    "2603.03237",   # CC BY  Topology of multi-species localization
    "2502.13495",   # CC BY  Monthly marine heatwave forecasts in New Zealand
    "2412.04475",   # CC BY  Marine heatwave forecasts with deep learning
    "2505.22071",   # CC BY  Ocean-E2E: forecasting extreme marine heatwaves
    "2601.01864",   # CC BY  Extending SST anomaly forecasts
    "2608.10022",   # CC BY  Statistical downscaling of sea surface temperature
    "1903.10322",   # CC BY  Biophysical connectivity in coastal reserve design
    "2202.03096",   # CC0    Inter-specific seagrass interactions
    "2304.09693",   # CC BY  Seagrass species competition
    "2204.11559",   # CC0    Global warming and Western Mediterranean seagrasses
]
# The paper of the day the dataset carries, with its analysis.
const DAILY = "2203.05645"

"""
    demo_config(dir; prefix, dataset) -> String

Write a working config into `dir`: config.toml with its data in `dir`, its content from the
checkout, Qdrant collections named from `prefix` and `dataset` as its `[dataset]`. Returns its path.
"""
function demo_config(dir::AbstractString; prefix::AbstractString, dataset::AbstractDict)
    t = TOML.parsefile(joinpath(DEMO, "config.toml"))
    t["data_dir"] = joinpath(dir, "data")
    t["content_dir"] = joinpath(DEMO, "content")
    t["collection_prefix"] = prefix
    t["dataset"] = dataset
    mkpath(dir)
    path = joinpath(dir, "config.toml")
    open(io -> TOML.print(io, t), path, "w")
    return path
end
