# ── Confining the service's agents ────────────────────────────────────────────────
# Under `zemi --shared` on Linux, the processes of the agents the service's Kaimon starts (summarizers,
# the tutor, notebook agents) and of the Slate workers that run notebooks' code are confined by the
# kernel (Kaimon's `confine`, through Landlock): they read all but the service's secrets and data, and
# write only their own folders. A document an agent is to read where the data is kept is allowed it
# by the link to it in its folder (see `agent_reads`). Elsewhere, and for any agent, its file tools
# are kept to its folder (see `file_tools`).

# Where a user's credentials usually are, under their home: none of them is an agent's business.
const CREDENTIAL_PLACES = [".ssh", ".gnupg", ".git-credentials", ".netrc", ".config/gh", ".aws", ".docker", ".kube",
                           ".pgpass", ".config/kaimon"]

"""
    key_files(c; path = config_path()) -> Vector{String}

The files configuration `c`, read from `path`, takes keys and credentials from: every `file:` key in
it and its settings, the dataset's credentials, its Cloudflare token and the GitHub App's private key.
"""
function key_files(c::Config; path::AbstractString = config_path())
    files = String[]
    found(x) = nothing
    found(x::AbstractString) = startswith(x, "file:") && push!(files, expanduser(x[6:end]))
    found(x::AbstractVector) = foreach(found, x)
    found(x::AbstractDict) = foreach(found, values(x))
    for f in (path, settings_path(path))
        isfile(f) && found(TOML.parsefile(f))
    end
    append!(files, [c.dataset.credentials, c.dataset.admin_credentials, c.shared.github_app.private_key])
    return unique(filter(!isempty, files))
end

"""
    confine_policy(c, kaimon_cache; path = config_path()) -> String

The policy the service's agents are confined by, in the form Kaimon's launcher reads: denied, the
configuration's folder (its settings, and the service's environment file beside them), the data
directory (the database, the papers, the service's Kaimon), the agents' folders (each agent is given
its own), the service Kaimon's cache, the key files ([`key_files`](@ref)) and the usual places of
credentials.
"""
function confine_policy(c::Config, kaimon_cache::AbstractString; path::AbstractString = config_path())
    deny = [dirname(abspath(path)); c.data_dir; agents_dir(); kaimon_cache; key_files(c; path);
            [joinpath(homedir(), p) for p in CREDENTIAL_PLACES]]
    return "# What the service's agents and notebooks' workers may not read (written by zemi --shared).\n" *
           join("deny $p\n" for p in unique(deny))
end

"""
    confinement_env(c, e) -> Dict{String,String}

The environment that has the service's Kaimon `e` confine its agents and its Slate workers: the
launcher (`KAIMON_CONFINE`, built now) and the policy (`KAIMON_CONFINE_POLICY`, written beside its
configuration). Empty with `[shared] confine_agents = false`, and where there is no Landlock to confine
with: off Linux, with a warning; on a Linux kernel without it, an error rather than agents unconfined.
"""
function confinement_env(c::Config, e)
    c.shared.confine_agents || return Dict{String,String}()
    if !Sys.islinux()
        @warn "[mcp] The service's agents are not confined: that needs Linux (Landlock)"
        return Dict{String,String}()
    end
    isdefined(kaimon(), :confine_launcher) ||
        error("This Kaimon cannot confine agents: update it, or set [shared] confine_agents = false to run them unconfined")
    launcher = kaimon().confine_launcher()
    parse(Int, readchomp(`$launcher --check`)) > 0 ||
        error("This kernel has no Landlock, so the service's agents cannot be confined: " *
              "set [shared] confine_agents = false to run them unconfined")
    policy = joinpath(e.config_dir, "confine.policy")
    write(policy, confine_policy(c, e.cache_dir))
    return Dict("KAIMON_CONFINE" => launcher, "KAIMON_CONFINE_POLICY" => policy)
end

"""
    agent_reads(dir) -> Vector{String}

What an agent working in `dir` is to read outside it: the targets of the links there (a paper's
PDF, a codebase's files). Confined, it is allowed exactly these; a Claude agent may read in their
folders.
"""
agent_reads(dir::AbstractString) =
    [realpath(joinpath(dir, f)) for f in readdir(dir) if islink(joinpath(dir, f)) && ispath(joinpath(dir, f))]

"""
    file_tools(dir) -> Vector{String}

An agent's file tools, kept to `dir`: reading in it (and in the folders [`agent_reads`](@ref)
adds), and writing and editing only there, as Claude's permission rules (`//` begins an absolute
path).
"""
function file_tools(dir::AbstractString)
    d = realpath(dir)
    return ["Read(/$d/**)", "Write(/$d/**)", "Edit(/$d/**)"]
end
