# `zemi connect`: keep folders on this machine in step with one's library in a knowledge base (see
# library_store.jl), so the knowledge base reads them (an Obsidian vault as notes, PDFs as documents;
# see library_reading.jl) and the references it writes into paper notes come back. Each folder is
# kept as `<name>/` in the library, its name the folder's own unless given.
#
# It signs in once, in the browser, as the person (OAuth, scope `library`: a token for their library
# and nothing else, see oauth.jl), or to the knowledge base run on this machine with its key. Then it
# syncs both ways: a file changed on one side only is copied to the other; changed on both, this
# machine's stands (what Zemi writes, it writes again). Each change is made over the version both last
# agreed on (`?base=`), so neither side's is lost to the other's. Folders and hidden files are left
# out but for a vault's settings the knowledge base reads, and the folders a vault's `.zemi.toml` says
# to skip, or that `zemi connect` is told to (`--skip`), never leave this machine.

"Where `zemi connect` keeps the folders it syncs and the knowledge base they go to: beside the config (`ZEMI_CONFIG`'s, given)."
connect_config_path() = joinpath(dirname(config_path()), "connect.toml")

"Where it keeps what it knows of each folder, and its sign-in."
connect_dir() = joinpath(xdg_home("XDG_DATA_HOME", ".local/share"), "zemi", "connect")

"The hidden files of a folder kept in step: a vault's settings, which say it is one and how it is read."
const CONNECT_HIDDEN = (".obsidian/app.json", ".obsidian/templates.json", ".obsidian/daily-notes.json", ".zemi.toml")

# ── Where the library is: the API, or anything answering as it does ──────────────────────────────

"""
A library as `zemi connect` reaches it: `list(r)` (the files, as `/api/library/files` gives them),
`fetch(r, path)` (a file's bytes), `store!(r, path, bytes; base, modified)` (a file's row, or throws
a [`Refusal`](@ref) with the API's status) and `remove!(r, path; base)`.
"""
abstract type LibraryRemote end

"The library at a knowledge base's address, reached with a token that `token()` gives, made again by `renew()` when refused."
struct HTTPLibrary <: LibraryRemote
    base::String
    token::Function
    renew::Function
end

function library_request(r::HTTPLibrary, method, path; body = UInt8[], query = Pair{String,String}[])
    url = r.base * "/api/library/files" * (isempty(path) ? "" : "/" * join(HTTP.escapeuri.(split(path, '/')), '/')) *
          (isempty(query) ? "" : "?" * HTTP.escapeuri(query))
    for attempt in 1:2
        resp = HTTP.request(method, url, ["Authorization" => "Bearer " * r.token()], body; status_exception = false, retry = false,
                            connect_timeout = 20, read_idle_timeout = 300)
        resp.status == 401 && attempt == 1 && (r.renew(); continue)
        resp.status < 300 && return resp.body
        msg = try String(get(JSON.parse(String(resp.body)), "error", "")) catch; "" end
        throw(Refusal(resp.status, isempty(msg) ? "The library answered $(resp.status)" : msg))
    end
    throw(Refusal(401, "The library refused the sign-in: run `zemi connect` with the site again to sign in"))
end

list_files(r::HTTPLibrary) = JSON.parse(String(library_request(r, "GET", "")))["files"]
fetch_file(r::HTTPLibrary, path) = library_request(r, "GET", path)
store_file!(r::HTTPLibrary, path, bytes; base, modified) =
    JSON.parse(String(library_request(r, "PUT", path; body = bytes, query = ["base" => something(base, ""), "modified" => string(modified)])))
remove_file!(r::HTTPLibrary, path; base) = library_request(r, "DELETE", path; query = ["base" => something(base, "")])

# ── Syncing a folder ──────────────────────────────────────────────────────────────────────────────

"""
    folder_files(dir; skip = []) -> Dict{String,String}

The files of folder `dir` kept in step, by their place in it (with `/`, in Unicode's composed form):
every file but hidden ones and those under hidden folders, except a vault's settings
(`CONNECT_HIDDEN`), and but those in the folders `skip` names or its `.zemi.toml` says to `skip`.
"""
function folder_files(dir::AbstractString; skip = String[])
    skip = vault_path.(String.(skip))
    zt = joinpath(dir, ".zemi.toml")
    if isfile(zt)
        s = try TOML.parsefile(zt) catch; Dict() end
        v = get(s, "skip", String[])
        append!(skip, vault_path.(String[string(x) for x in (v isa AbstractVector ? v : [v])]))
    end
    out = Dict{String,String}()
    for (root, dirs, files) in walkdir(dir)
        rel = relpath(root, dir) == "." ? "" : vault_path(relpath(root, dir))
        for f in files
            p = vault_path(isempty(rel) ? f : rel * "/" * f)
            hidden = any(startswith("."), split(p, '/'))
            (hidden ? p in CONNECT_HIDDEN : !any(d -> in_folder(p, d), skip)) || continue
            islink(joinpath(root, f)) && continue
            out[p] = joinpath(root, f)
        end
    end
    return out
end

"""
What is known of a folder: each file's hash as both sides last agreed on it, and its time and size
here when hashed. Kept for the folder and where it goes: the site, or the knowledge base run here by its config.
"""
folder_state_path(site::AbstractString, dir::AbstractString) =
    joinpath(connect_dir(), bytes2hex(sha256("$(site == "local" ? "local:" * abspath(config_path()) : site)|$dir"))[1:16] * ".json")

"""
    sync_folder!(remote, dir, name, state; skip = []) -> NamedTuple

Bring folder `dir` (but for the folders `skip` names) and `<name>/` in library `remote` in step (see
connect.jl), `state` what is known of them (see [`folder_state_path`](@ref)), changed in place. Returns how many files went each way,
were removed on each side, and were left for the next time (`waiting`: changed meanwhile, or the
library full).
"""
function sync_folder!(remote::LibraryRemote, dir::AbstractString, name::AbstractString, state::AbstractDict; skip = String[])
    prefix = name * "/"
    left_out(p) = any(d -> in_folder(p, d), vault_path.(String.(skip)))
    there = Dict(f["path"][ncodeunits(prefix)+1:end] => f for f in list_files(remote) if startswith(f["path"], prefix))
    filter!(((p, _),) -> !left_out(p), there)
    here = folder_files(dir; skip)
    agreed = get!(state, "agreed", Dict{String,Any}())
    seen = get!(state, "seen", Dict{String,Any}())
    n = (; up = Ref(0), down = Ref(0), removed_here = Ref(0), removed_there = Ref(0), waiting = Ref(0), full = Ref(false))
    # A file's hash here, hashed again only when its time or size changed.
    function local_sha(p)
        f = here[p]
        st = stat(f)
        e = get(seen, p, nothing)
        e !== nothing && e["mtime"] == st.mtime && e["size"] == st.size && return e["sha"]
        sha = bytes2hex(open(sha256, f))
        seen[p] = Dict("mtime" => st.mtime, "size" => st.size, "sha" => sha)
        return sha
    end
    function up(p, base)
        n.full[] && (n.waiting[] += 1; return)
        try
            f = store_file!(remote, prefix * p, read(here[p]); base, modified = stat(here[p]).mtime)
            agreed[p] = f["sha256"]
            n.up[] += 1
        catch e
            e isa Refusal && e.status in (409, 413) || rethrow()
            e.status == 413 && (n.full[] = true)
            n.waiting[] += 1
        end
    end
    function down(p)
        bytes = fetch_file(remote, prefix * p)
        f = joinpath(dir, split(p, '/')...)
        mkpath(dirname(f))
        write_atomic(f, bytes)
        here[p] = f
        agreed[p] = there[p]["sha256"]
        local_sha(p)
        n.down[] += 1
    end
    for p in sort!(collect(union(keys(here), keys(there), keys(agreed))))
        L = haskey(here, p) ? local_sha(p) : nothing
        R = haskey(there, p) ? String(there[p]["sha256"]) : nothing
        B = get(agreed, p, nothing)
        if L == R
            L === nothing ? delete!(agreed, p) : (agreed[p] = L)
        elseif L == B                                           # changed there only
            if R === nothing
                rm(here[p]; force = true); delete!(seen, p); delete!(agreed, p)
                n.removed_here[] += 1
            else
                down(p)
            end
        elseif L === nothing                                    # removed here: that stands
            try
                remove_file!(remote, prefix * p; base = R)
                delete!(agreed, p); n.removed_there[] += 1
            catch e
                e isa Refusal && e.status == 409 || rethrow()
                n.waiting[] += 1
            end
        else                                                    # changed here, there too or not: this machine's stands
            up(p, R === nothing ? "" : R)
        end
    end
    for q in collect(keys(seen))
        haskey(here, q) || delete!(seen, q)
    end
    return (; up = n.up[], down = n.down[], removed_here = n.removed_here[], removed_there = n.removed_there[], waiting = n.waiting[],
              full = n.full[])
end

# ── Signing in ────────────────────────────────────────────────────────────────────────────────────

"Where the sign-in to the site is kept: the OAuth client, and the access and refresh tokens, readable by this account alone."
connect_auth_path() = joinpath(connect_dir(), "auth.json")

load_connect_auth() = (f = connect_auth_path(); isfile(f) ? Dict{String,Any}(JSON.parsefile(f)) : Dict{String,Any}())
function save_connect_auth!(d)
    mkpath(connect_dir())
    write_atomic(connect_auth_path(), JSON.json(d))
    chmod(connect_auth_path(), 0o600)
end

"A site's address as it is kept: with its scheme, without a trailing slash."
site_address(site::AbstractString) = (s = rstrip(strip(site), '/'); occursin("://", s) ? String(s) : "https://" * s)

"""
    sign_in_library(site; open_browser) -> Dict

Sign in to the knowledge base at `site` for one's library: register a client, have the person approve
it in the browser (`open_browser(url)`), signed in there, and take the code the site sends back to a
port of this machine, for a token of the `library` permission alone (see oauth.jl).
"""
function sign_in_library(site::AbstractString; open_browser = open_in_browser)
    probe = Sockets.listen(Sockets.localhost, 0)                 # a port free now
    port = Int(Sockets.getsockname(probe)[2])
    close(probe)
    redirect = "http://127.0.0.1:$port/callback"
    got = Channel{Dict{String,String}}(1)
    http = HTTP.serve!("127.0.0.1", port) do req
        uri = HTTP.URI(req.target)
        uri.path == "/callback" || return HTTP.Response(404)
        isready(got) || put!(got, Dict{String,String}(HTTP.queryparams(uri)))
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"],
                      "<!doctype html><p style=\"font:16px system-ui;margin:4rem auto;max-width:30rem\">Done: you can close this tab.</p>")
    end
    try
        reg = JSON.parse(String(HTTP.post("$site/oauth/register", ["Content-Type" => "application/json"],
                                          JSON.json(Dict("client_name" => "zemi connect on $(gethostname())", "redirect_uris" => [redirect]))).body))
        client = String(reg["client_id"])
        verifier, state = new_secret(), new_secret()
        query = HTTP.escapeuri(["response_type" => "code", "client_id" => client, "redirect_uri" => redirect, "state" => state,
                                "code_challenge" => pkce_challenge(verifier), "code_challenge_method" => "S256", "scope" => "library"])
        open_browser("$site/oauth/authorize?$query")
        timedwait(() -> isready(got), 600.0) == :ok || error("No approval came in 10 minutes: run it again")
        back = take!(got)
        get(back, "state", "") == state || error("The approval came back for another request")
        haskey(back, "error") && error("The site refused: $(back["error"])")
        t = JSON.parse(String(HTTP.post("$site/oauth/token", ["Content-Type" => "application/x-www-form-urlencoded"],
                                        HTTP.escapeuri(["grant_type" => "authorization_code", "code" => back["code"], "redirect_uri" => redirect,
                                                        "client_id" => client, "code_verifier" => verifier])).body))
        return Dict{String,Any}("site" => site, "client_id" => client, "access" => t["access_token"], "refresh" => t["refresh_token"])
    finally
        close(http)
    end
end

"Open `url` in this machine's browser; say it, where none opens."
function open_in_browser(url::AbstractString)
    cmd = Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start "" $url` : `xdg-open $url`
    say(:info, "Approve zemi connect in your browser", url)
    try run(pipeline(cmd; stdout = devnull, stderr = devnull)) catch end
end

"Renew the sign-in `auth` with its refresh token, keeping the new tokens."
function renew_library_auth!(auth::AbstractDict)
    resp = HTTP.post("$(auth["site"])/oauth/token", ["Content-Type" => "application/x-www-form-urlencoded"],
                     HTTP.escapeuri(["grant_type" => "refresh_token", "refresh_token" => auth["refresh"], "client_id" => auth["client_id"]]);
                     status_exception = false)
    resp.status == 200 || throw(Refusal(401, "The sign-in has ended: run `zemi connect $(auth["site"]) …` again to sign in"))
    t = JSON.parse(String(resp.body))
    auth["access"], auth["refresh"] = t["access_token"], t["refresh_token"]
    save_connect_auth!(auth)
end

"""
    library_remote(site) -> LibraryRemote

The library at `site`: `local`, the knowledge base run on this machine, reached with its key; else the
site signed in to (see [`sign_in_library`](@ref)).
"""
function library_remote(site::AbstractString)
    if site == "local"
        c = load_config()
        return HTTPLibrary("http://127.0.0.1:$(local_port(c))", () -> local_key(c), () -> nothing)
    end
    auth = load_connect_auth()
    get(auth, "site", "") == site || error("Not signed in to $site: run `zemi connect $site FOLDER`")
    return HTTPLibrary(site, () -> auth["access"], () -> renew_library_auth!(auth))
end

# ── The command ───────────────────────────────────────────────────────────────────────────────────

load_connect_config() = (f = connect_config_path(); isfile(f) ? TOML.parsefile(f) : Dict{String,Any}())
function save_connect_config!(c)
    mkpath(dirname(connect_config_path()))
    open(io -> (println(io, "# The folders `zemi connect` keeps in step with your library, and where it is."); TOML.print(io, c)),
         connect_config_path(), "w")
end

"""
    connect_once(; quiet = false) -> Bool

Sync every folder `zemi connect` keeps (see [`sync_folder!`](@ref)) once, saying what moved; whether
all went well.
"""
function connect_once(; quiet::Bool = false)
    c = load_connect_config()
    site = get(c, "site", "")
    isempty(site) && error("Nothing to keep in step: run `zemi connect SITE FOLDER` first")
    remote = library_remote(site)
    ok = true
    for f in get(c, "folders", Any[])
        dir, name = abspath(expanduser(f["path"])), f["name"]
        isdir(dir) || (say(:warn, "Not a folder here", dir); ok = false; continue)
        statefile = folder_state_path(site, dir)
        state = isfile(statefile) ? Dict{String,Any}(JSON.parsefile(statefile)) : Dict{String,Any}()
        r = try
            sync_folder!(remote, dir, name, state; skip = get(f, "skip", String[]))
        catch e
            e isa InterruptException && rethrow()
            say(:warn, "$name could not be kept in step", failure_message(e))
            ok = false
            continue
        finally
            mkpath(dirname(statefile))
            write_atomic(statefile, JSON.json(state))
        end
        moved = r.up + r.down + r.removed_here + r.removed_there
        r.full && say(:warn, "Your library is full", "Remove files from it to send more")
        quiet && moved == 0 || say(:ok, "$name in step", "$(r.up) sent, $(r.down) received, $(r.removed_there) removed there, $(r.removed_here) removed here" *
                                                         (r.waiting > 0 ? ", $(r.waiting) for the next time" : ""))
    end
    return ok
end

"How often `zemi connect` looks for changes, in seconds."
const CONNECT_EVERY = 10

"""
    connect_cli(args)

`zemi connect`: with a site and a folder, keep that folder in step with one's library there (signing
in first); `--name NAME` names it there, and each `--skip FOLDER` is a folder of it never sent. With
no arguments, keep every folder in step until stopped; `--once`, once; `--install`, at every login,
in the background.
"""
function connect_cli(args::AbstractVector{<:AbstractString})
    flags = filter(startswith("--"), args)
    valued = Set(j + 1 for (j, a) in enumerate(args) if a in ("--name", "--skip") && j < length(args))
    given(flag) = [args[j+1] for (j, a) in enumerate(args) if a == flag && j < length(args)]
    name = (n = given("--name"); isempty(n) ? nothing : last(n))
    plain = [a for (j, a) in enumerate(args) if !startswith(a, "--") && !(j in valued)]
    if length(plain) == 2
        site = plain[1] == "local" ? "local" : site_address(plain[1])
        dir = abspath(expanduser(plain[2]))
        isdir(dir) || error("$dir is not a folder here")
        c = load_connect_config()
        get(c, "site", site) == site || error("zemi connect keeps folders in step with $(c["site"]) already")
        if site != "local" && get(load_connect_auth(), "site", "") != site
            save_connect_auth!(sign_in_library(site))
        end
        folders = [f for f in get(c, "folders", Any[]) if abspath(expanduser(f["path"])) != dir]
        push!(folders, Dict{String,Any}("path" => contractuser(dir), "name" => something(name, basename(dir)), "skip" => given("--skip")))
        save_connect_config!(Dict("site" => site, "folders" => folders))
        connect_once()
        say(:info, "Keep it in step", "`zemi connect` until stopped, or `zemi connect --install` to start it at every login")
    elseif !isempty(plain)
        error("Give a site and a folder: zemi connect https://kb.example.org ~/Documents/Notes")
    elseif "--install" in flags
        install_connect()
    elseif "--once" in flags
        connect_once() || return 1
    else
        while true
            try
                connect_once(; quiet = true)
            catch e
                e isa InterruptException && rethrow()
                say(:warn, "Could not keep the folders in step; trying again", failure_message(e))
            end
            sleep(CONNECT_EVERY)
        end
    end
    return 0
end

"""
    install_connect()

Have `zemi connect` run at every login, in the background: a launch agent on a Mac, a systemd user
service on Linux, its output in `connect.log` beside what it knows of the folders.
"""
function install_connect()
    exe = joinpath(first(DEPOT_PATH), "bin", Sys.iswindows() ? "zemi.bat" : "zemi")
    isfile(exe) || error("The zemi app is not installed here (`pkg> app add Zemi`): it is what runs at login")
    mkpath(connect_dir())
    log = joinpath(connect_dir(), "connect.log")
    if Sys.isapple()
        plist = joinpath(homedir(), "Library", "LaunchAgents", "org.zemi.connect.plist")
        mkpath(dirname(plist))
        write(plist, """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>org.zemi.connect</string>
              <key>ProgramArguments</key><array><string>$exe</string><string>connect</string></array>
              <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
              <key>StandardOutPath</key><string>$log</string><key>StandardErrorPath</key><string>$log</string>
            </dict></plist>
            """)
        try run(`launchctl unload $plist`; wait = true) catch end
        run(`launchctl load -w $plist`)
        say(:ok, "zemi connect starts at every login", ("Its log", contractuser(log)), ("To stop it", "launchctl unload -w $(contractuser(plist))"))
    elseif Sys.islinux()
        unit = joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "systemd", "user", "zemi-connect.service")
        mkpath(dirname(unit))
        write(unit, """
            [Unit]
            Description=zemi connect: folders kept in step with a Zemi library

            [Service]
            ExecStart=$exe connect
            Restart=always
            StandardOutput=append:$log
            StandardError=append:$log

            [Install]
            WantedBy=default.target
            """)
        run(`systemctl --user daemon-reload`)
        run(`systemctl --user enable --now zemi-connect.service`)
        say(:ok, "zemi connect starts at every login", ("Its log", contractuser(log)), ("To stop it", "systemctl --user disable --now zemi-connect"))
    else
        error("Starting at login is set up on a Mac and on Linux: run `zemi connect` yourself")
    end
end
