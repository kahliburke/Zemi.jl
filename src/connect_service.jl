# Running `zemi connect` (see connect.jl for the syncing itself): one process at a time syncs the
# folders a config names, whoever holds its lock; the terminal app (connect_app.jl), the knowledge
# base run on this machine when the folders go to it (see `follow_connect`), the background service
# for a knowledge base elsewhere, or a single pass. Whoever syncs writes a status file (each folder's state and what moved
# lately) that the others show, and reads the folder list afresh at each pass, so the app can add and
# remove folders while the service syncs them. A pass is asked for early by touching a file the
# syncer watches.

using FileWatching.Pidfile: trymkpidlock, parse_pidfile, isvalidpid

"How often `zemi connect` looks for changes, in seconds."
const CONNECT_EVERY = 10

"How many of the latest changes the status keeps."
const ACTIVITY_KEPT = 200

# What a config's syncing keeps beside the folders' states: named by the config, so that each
# config's folders are synced by one process of their own.
connect_key() = bytes2hex(sha256(abspath(connect_config_path())))[1:16]
connect_lock_path() = joinpath(connect_dir(), "$(connect_key()).lock")
connect_status_path() = joinpath(connect_dir(), "$(connect_key()).status.json")
connect_request_path() = joinpath(connect_dir(), "$(connect_key()).now")

"Ask whoever syncs for a pass now, rather than at its next."
request_pass() = (mkpath(connect_dir()); touch(connect_request_path()); nothing)

"The process that syncs this config's folders now (its pid), or `nothing`."
function syncing_pid()
    f = connect_lock_path()
    isfile(f) || return nothing
    pid, host, _ = try parse_pidfile(f) catch; return nothing end
    pid > 0 && isvalidpid(host, pid) ? Int(pid) : nothing
end

"The status the syncer last wrote (see [`Syncer`](@ref)), or an empty one."
read_connect_status() =
    (f = connect_status_path(); isfile(f) ? (try Dict{String,Any}(JSON.parsefile(f)) catch; empty_status() end) : empty_status())
empty_status() = Dict{String,Any}("site" => "", "pid" => 0, "by" => "", "updated" => "", "syncing" => false, "paused" => false,
                                  "error" => "", "folders" => Any[], "activity" => Any[])

"""
    Syncer

The process syncing a config's folders: its lock, and the status it keeps (`site`, `pid`, `by` (who
it is, when not a `zemi connect` of its own: `"the knowledge base"`), whether it is in a pass
(`syncing`), `paused`, an `error` that stopped a whole pass, each folder's `name`, `path`, `state` ("in step", "syncing", "waiting", "paused", "missing" or "error"), `files`,
`message`, `checked` and `changed`, and the latest `activity`, each `at`, `folder`, `what` and `path`).
`line(entry)` is told each change as it is made.
"""
mutable struct Syncer
    lock::Any
    status::Dict{String,Any}
    guard::ReentrantLock
    line::Function
end

"""
    claim_syncing(; line = entry -> nothing, by = "") -> Union{Syncer,Nothing}

Become the process that syncs this config's folders, or `nothing` when another is. A lock left by a
process that ended is taken over within half a minute. `by` says who it is, in the status.
"""
function claim_syncing(; line = entry -> nothing, by::AbstractString = "")
    mkpath(connect_dir())
    # A lock whose process has ended is taken over at once; one written a moment ago may be another's, just made.
    f = connect_lock_path()
    isfile(f) && syncing_pid() === nothing && time() - mtime(f) > 2 && rm(f; force = true)
    l = trymkpidlock(f; stale_age = 30)
    l === false && return nothing
    status = read_connect_status()
    status["pid"], status["by"], status["syncing"], status["error"] = getpid(), by, false, ""
    s = Syncer(l, status, ReentrantLock(), line)
    write_status(s)
    return s
end

"Stop syncing: the lock goes, and the status says no one syncs."
function release!(s::Syncer)
    lock(s.guard) do
        s.status["pid"], s.status["by"], s.status["syncing"] = 0, "", false
        foreach(f -> f["state"] == "syncing" && (f["state"] = "in step"), s.status["folders"])
    end
    write_status(s)
    close(s.lock)
    return nothing
end

"A copy of the status, safe to read while a pass changes it."
status_copy(s::Syncer) = lock(() -> deepcopy(s.status), s.guard)

write_status(s::Syncer) = (mkpath(connect_dir());
                           write_atomic(connect_status_path(), lock(() -> JSON.json(merge(s.status, Dict("updated" => now_iso()))), s.guard)))

const MOVED = Dict(:sent => "sent", :received => "received", :removed_here => "removed here", :removed_there => "removed there",
                   :waiting => "waits", :error => "error", :removed => "removed from the library")

function note!(s::Syncer, folder::AbstractString, what::Symbol, path::AbstractString)
    e = Dict{String,Any}("at" => now_iso(), "folder" => String(folder), "what" => MOVED[what], "path" => String(path))
    lock(s.guard) do
        a = s.status["activity"]
        push!(a, e)
        length(a) > ACTIVITY_KEPT && deleteat!(a, 1:length(a)-ACTIVITY_KEPT)
    end
    s.line(e)
end

# A folder's entry in the status: the one it had, else a new one.
function folder_entry(s::Syncer, name, path)
    i = findfirst(f -> f["name"] == name && f["path"] == path, s.status["folders"])
    i === nothing || return s.status["folders"][i]
    return Dict{String,Any}("name" => name, "path" => path, "state" => "in step", "files" => 0, "message" => "", "checked" => "", "changed" => "")
end

"""
    sync_pass!(s; remote = nothing) -> Bool

Sync each folder the config names once (see [`sync_folder!`](@ref)), keeping the status as it goes;
whether all went well. A folder marked to be removed from the library (`remove = "library"`, see
[`remove_folder!`](@ref)) has its files removed there and leaves the config. `remote`: the library,
else the config's site.
"""
function sync_pass!(s::Syncer; remote::Union{LibraryRemote,Nothing} = nothing)
    c = load_connect_config()
    site = String(get(c, "site", ""))
    paused = get(c, "paused", false) === true
    lock(s.guard) do
        s.status["site"], s.status["paused"], s.status["error"], s.status["syncing"] = site, paused, "", !paused
    end
    folders = get(c, "folders", Any[])
    entries = [folder_entry(s, String(f["name"]), String(f["path"])) for f in folders]
    lock(() -> (s.status["folders"] = entries), s.guard)
    ok = true
    try
        isempty(site) && error("No folders yet: add one")
        remote === nothing && !paused && (remote = library_remote(site))
        for (f, e) in zip(folders, entries)
            dir, name = abspath(expand_home(f["path"])), String(f["name"])
            if get(f, "remove", "") == "library"
                remote === nothing && continue
                remove_from_library!(s, remote, site, dir, name)
                continue
            end
            paused && (e["state"] = "paused"; continue)
            isdir(dir) || (e["state"] = "missing"; e["message"] = "not a folder here"; ok = false; continue)
            e["state"], e["message"] = "syncing", ""
            write_status(s)
            statefile = folder_state_path(site, dir)
            state = isfile(statefile) ? Dict{String,Any}(JSON.parsefile(statefile)) : Dict{String,Any}()
            try
                r = sync_folder!(remote, dir, name, state; skip = get(f, "skip", String[]), report = (what, p) -> note!(s, name, what, p))
                e["state"] = r.waiting > 0 ? "waiting" : "in step"
                e["message"] = r.full ? "your library is full" : r.waiting > 0 ? "$(r.waiting) for the next pass" : ""
                r.up + r.down + r.removed_here + r.removed_there > 0 && (e["changed"] = now_iso())
            catch err
                err isa InterruptException && rethrow()
                e["state"], e["message"] = "error", failure_message(err)
                note!(s, name, :error, failure_message(err))
                ok = false
            finally
                mkpath(dirname(statefile))
                write_atomic(statefile, JSON.json(state))
                e["files"] = length(get(state, "agreed", Dict()))
                e["checked"] = now_iso()
            end
        end
    catch err
        err isa InterruptException && rethrow()
        lock(() -> (s.status["error"] = failure_message(err)), s.guard)
        ok = false
    finally
        lock(() -> (s.status["syncing"] = false), s.guard)
        write_status(s)
    end
    return ok
end

# A folder's files removed from the library, and the folder from the config.
function remove_from_library!(s::Syncer, remote::LibraryRemote, site, dir, name)
    prefix = name * "/"
    for f in list_files(remote)
        startswith(f["path"], prefix) || continue
        try
            remove_file!(remote, f["path"]; base = f["sha256"])
        catch e
            e isa Refusal && e.status == 409 || rethrow()
        end
    end
    rm(folder_state_path(site, dir); force = true)
    c = load_connect_config()
    c["folders"] = [f for f in get(c, "folders", Any[]) if !(f["name"] == name && abspath(expand_home(f["path"])) == dir)]
    save_connect_config!(c)
    lock(() -> filter!(f -> f["name"] != name, s.status["folders"]), s.guard)
    note!(s, name, :removed, "")
end

"Wait for the next pass: `seconds`, or less when one is asked for (see [`request_pass`](@ref)) or `stop()` says so."
function wait_for_pass(seconds::Real = CONNECT_EVERY; stop = () -> false)
    t0 = time()
    while time() - t0 < seconds && !stop()
        isfile(connect_request_path()) && (rm(connect_request_path(); force = true); return)
        sleep(0.25)
    end
end

# ── Synced by the knowledge base run here ─────────────────────────────────────────────────────────

"""
Whether the knowledge base run on this machine syncs the folders: they go to it, and `zemi connect
--background` asked for it (see [`set_background!`](@ref)).
"""
synced_by_local(c::AbstractDict = load_connect_config()) = get(c, "site", "") == "local" && get(c, "background", false) === true

"How the knowledge base run here names itself in the status, as the one syncing."
const LOCAL_SYNCER = "the knowledge base"

"""
    follow_connect(kb) -> Task

While the knowledge base runs on this machine, sync the folders `zemi connect` keeps with it when it
is asked to (see [`synced_by_local`](@ref)): writing into the library in this process, as whoever runs
it, and keeping the status the app and `zemi connect --status` show. It lets go of the syncing when
the setting is cleared, and waits while another process holds it (the app, open on a terminal).
"""
function follow_connect(kb::KB; every::Real = CONNECT_EVERY)
    Threads.@spawn begin
        s = nothing
        try
            while !STOPPING[]
                # The setting is looked at again once the config changes, or after `every`.
                was = mtime(connect_config_path())
                changed() = STOPPING[] || mtime(connect_config_path()) != was
                wanted = try synced_by_local() catch e; @warn "zemi connect's folders could not be read" exception = e; false end
                if !wanted
                    s === nothing || (release!(s); s = nothing)
                    pause_while(every, changed)
                    continue
                end
                s === nothing && (s = claim_syncing(; by = LOCAL_SYNCER))
                if s === nothing
                    pause(every)                   # another process syncs them now
                    continue
                end
                try
                    sync_pass!(s; remote = InProcessLibrary(kb, local_caller()))
                catch e
                    @warn "Syncing zemi connect's folders failed" exception = e
                end
                wait_for_pass(every; stop = changed)
            end
        finally
            s === nothing || release!(s)
        end
    end
end

"Wait `seconds`, or less once `done()` says so or the knowledge base stops; `done` is asked four times a second."
function pause_while(seconds::Real, done)
    until = time() + seconds
    while !STOPPING[] && time() < until && !done()
        sleep(min(0.25, until - time()))
    end
end

# ── The folders ───────────────────────────────────────────────────────────────────────────────────

"""
    add_folder!(site, dir; name = basename(dir), skip = []) -> Dict

Have `zemi connect` keep folder `dir` in step with `<name>/` in one's library at `site`. What was
known of the folder from before is forgotten, so a folder added again is merged afresh (this
machine's files standing) rather than taken for one whose files were removed.
"""
function add_folder!(site::AbstractString, dir::AbstractString; name::Union{AbstractString,Nothing} = nothing, skip = String[])
    dir = abspath(expand_home(dir))
    isdir(dir) || error("$dir is not a folder here")
    c = load_connect_config()
    get(c, "site", site) == site || error("zemi connect keeps folders in step with $(c["site"]) already")
    name = String(strip(something(name, basename(rstrip(dir, '/')))))
    isempty(name) && error("A folder needs a name in the library")
    occursin('/', name) && error("A folder's name in the library has no /: $name")
    others = [f for f in get(c, "folders", Any[]) if abspath(expand_home(f["path"])) != dir]
    any(f -> f["name"] == name, others) && error("Another folder is $name/ in the library already: give this one another name")
    rm(folder_state_path(site, dir); force = true)
    f = Dict{String,Any}("path" => contractuser(dir), "name" => name, "skip" => String.(skip))
    c["site"], c["folders"] = site, [others; f]
    save_connect_config!(c)
    return f
end

"""
    remove_folder!(name; from_library = false)

Stop keeping the folder named `name` in step. With `from_library`, its files are also removed from
the library, by whoever syncs at their next pass; the folder on this machine is left as it is.
"""
function remove_folder!(name::AbstractString; from_library::Bool = false)
    c = load_connect_config()
    folders = get(c, "folders", Any[])
    i = findfirst(f -> f["name"] == name, folders)
    i === nothing && error("No folder $name")
    if from_library
        folders[i]["remove"] = "library"
    else
        rm(folder_state_path(c["site"], abspath(expand_home(folders[i]["path"]))); force = true)
        deleteat!(folders, i)
    end
    c["folders"] = folders
    save_connect_config!(c)
    request_pass()
end

"Set the subfolders and files of folder `name` that never leave this machine (paths in it)."
function set_skips!(name::AbstractString, skip)
    c = load_connect_config()
    f = findfirst(f -> f["name"] == name, get(c, "folders", Any[]))
    f === nothing && error("No folder $name")
    names = (strip(strip(s), '/') for s in skip)
    c["folders"][f]["skip"] = String[n for n in names if !isempty(n)]
    save_connect_config!(c)
    request_pass()
end

"""
    set_background!(on) -> Bool

Have the knowledge base run on this machine sync the folders that go to it, from now and whenever it
runs, or stop. A background service left from before, syncing these folders, is stopped: the
knowledge base takes its place. Returns whether the knowledge base runs now, to take it up.
"""
function set_background!(on::Bool)
    c = load_connect_config()
    get(c, "site", "") == "local" || error("The folders go to $(site_label(get(c, "site", ""))), not the knowledge base run here")
    on ? (c["background"] = true) : delete!(c, "background")
    save_connect_config!(c)
    on && background_installed() && (pid = syncing_pid(); pid !== nothing && pid != getpid() && isempty(get(read_connect_status(), "by", ""))) &&
        stop_background()
    return local_served(load_config()) !== nothing
end

"Pause syncing every folder, or carry on."
function set_paused!(paused::Bool)
    c = load_connect_config()
    paused ? (c["paused"] = true) : delete!(c, "paused")
    save_connect_config!(c)
    request_pass()
end

# ── Off a terminal: a line for each change ────────────────────────────────────────────────────────

"A change as a line: its time, the folder, what moved and the file."
activity_line(e) = join(filter(!isempty, [Dates.format(parse_iso(e["at"]) + local_offset(), "HH:MM:SS"), e["folder"], e["what"], e["path"]]), "  ")
local_offset() = now() - now(UTC)

"""
    run_headless() -> Int

Sync until stopped, a line for each change: what the background service runs, and `zemi connect`
off a terminal.
"""
function run_headless()
    s = claim_syncing(; line = e -> (println(activity_line(e)); flush(stdout)))
    if s === nothing
        say(:info, "Another zemi connect syncs these folders", "Process $(something(syncing_pid(), "?")); `zemi connect --status` shows how they stand")
        return 1
    end
    c = load_connect_config()
    n = length(get(c, "folders", Any[]))
    println("zemi connect: $(get(c, "site", "no site yet")), $n folder$(n == 1 ? "" : "s"), every $(CONNECT_EVERY) s")
    flush(stdout)
    try
        while true
            ok = sync_pass!(s)
            err = s.status["error"]
            ok || isempty(err) || (println("$(Dates.format(now(), "HH:MM:SS"))  $err"); flush(stdout))
            wait_for_pass()
        end
    finally
        release!(s)
    end
end

"""
    connect_once_cli() -> Int

One pass, saying how each folder stands; when another process syncs, it is asked for one instead.
"""
function connect_once_cli()
    s = claim_syncing()
    if s === nothing
        request_pass()
        say(:info, "Another zemi connect syncs these folders", "It was asked to sync now")
        return 0
    end
    ok = try sync_pass!(s) finally release!(s) end
    st = s.status
    isempty(st["error"]) || say(:warn, "Not synced", st["error"])
    for f in st["folders"]
        say(f["state"] in ("in step", "waiting") ? :ok : :warn, "$(f["name"]): $(f["state"])",
            isempty(f["message"]) ? "$(f["files"]) files" : f["message"])
    end
    return ok ? 0 : 1
end

# ── The background service ───────────────────────────────────────────────────────────────────────

connect_plist() = joinpath(homedir(), "Library", "LaunchAgents", "org.zemi.connect.plist")
connect_unit() = joinpath(xdg_home("XDG_CONFIG_HOME", ".config"), "systemd", "user", "zemi-connect.service")
connect_log() = joinpath(connect_dir(), "connect.log")

# What the service is to run with besides: the config and data folders, when this process was given others.
service_env() = [k => ENV[k] for k in ("ZEMI_CONFIG", "XDG_DATA_HOME", "XDG_CONFIG_HOME") if haskey(ENV, k)]

"""
    start_background()

Have the background service sync the folders, from now and at every login: a launch agent on a Mac,
a systemd user service on Linux, its output in `connect.log` beside the folders' states.
"""
function start_background()
    exe = joinpath(first(DEPOT_PATH), "bin", Sys.iswindows() ? "zemi.bat" : "zemi")
    isfile(exe) || error("The zemi app is not installed here (`pkg> app add Zemi`): it is what the service runs")
    mkpath(connect_dir())
    log, env = connect_log(), service_env()
    if Sys.isapple()
        plist = connect_plist()
        mkpath(dirname(plist))
        envxml = isempty(env) ? "" :
            "<key>EnvironmentVariables</key><dict>" * join("<key>$k</key><string>$(html_escape(v))</string>" for (k, v) in env) * "</dict>"
        write(plist, """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>org.zemi.connect</string>
              <key>ProgramArguments</key><array><string>$exe</string><string>connect</string><string>--headless</string></array>
              $envxml
              <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
              <key>StandardOutPath</key><string>$log</string><key>StandardErrorPath</key><string>$log</string>
            </dict></plist>
            """)
        try run(pipeline(`launchctl unload $plist`; stdout = devnull, stderr = devnull)) catch end
        run(`launchctl load -w $plist`)
    elseif Sys.islinux()
        unit = connect_unit()
        mkpath(dirname(unit))
        write(unit, """
            [Unit]
            Description=zemi connect: folders kept in step with a Zemi library

            [Service]
            ExecStart=$exe connect --headless
            $(join(("Environment=$k=$v" for (k, v) in env), "\n"))
            Restart=always
            StandardOutput=append:$log
            StandardError=append:$log

            [Install]
            WantedBy=default.target
            """)
        run(`systemctl --user daemon-reload`)
        run(`systemctl --user enable --now zemi-connect.service`)
    else
        error("The background service is set up on a Mac and on Linux: run `zemi connect` yourself")
    end
end

"Whether the background service is set up here."
background_installed() = Sys.isapple() ? isfile(connect_plist()) : Sys.islinux() ? isfile(connect_unit()) : false

"Stop the background service and take it out of the logins."
function stop_background()
    background_installed() || return false
    if Sys.isapple()
        try run(pipeline(`launchctl unload -w $(connect_plist())`; stdout = devnull, stderr = devnull)) catch end
        rm(connect_plist(); force = true)
    else
        try run(pipeline(`systemctl --user disable --now zemi-connect.service`; stdout = devnull, stderr = devnull)) catch end
        rm(connect_unit(); force = true)
        try run(pipeline(`systemctl --user daemon-reload`; stdout = devnull, stderr = devnull)) catch end
    end
    return true
end

"`zemi connect --status`: who syncs, and how each folder stands."
function connect_status_cli()
    pid, st = syncing_pid(), read_connect_status()
    by = get(st, "by", "")
    who = pid === nothing ? "nothing syncs now" : !isempty(by) ? "$by syncs (process $pid)" :
          background_installed() && pid != getpid() ? "the background service syncs (process $pid)" : "process $pid syncs"
    service = synced_by_local() ? ("Background", "the knowledge base run here, whenever it runs") :
              ("Service", background_installed() ? "set up, starts at login" : "not set up")
    say(:info, "zemi connect: $who", ("Site", isempty(st["site"]) ? "none yet" : st["site"]), service,
        (synced_by_local() ? () : (("Log", contractuser(connect_log())),))...)
    isempty(st["error"]) || say(:warn, "The last pass stopped", st["error"])
    for f in st["folders"]
        say(f["state"] in ("in step", "syncing") ? :ok : :warn, "$(f["name"]): $(f["state"])",
            ("Folder", f["path"]), ("Files", string(f["files"])), ("Checked", isempty(f["checked"]) ? "never" : f["checked"]),
            (isempty(f["message"]) ? () : (("Note", f["message"]),))...)
    end
    return 0
end

# ── The command ───────────────────────────────────────────────────────────────────────────────────

"""
    connect_cli(args)

`zemi connect`: with a site and a folder, keep that folder in step with one's library there (signing
in first); with a folder alone, at the site it keeps folders with, else the knowledge base served on
this machine (see [`default_connect_site`](@ref)). `--name NAME` names it there, and each
`--skip FOLDER` is a folder of it never sent. With
no arguments, the app that shows and manages the folders on a terminal, else a line for each change
(`--headless` either way); `--once`, one pass; `--background` (or `--install`), the folders synced
from now on by the knowledge base run here when they go to it (see [`follow_connect`](@ref)), else by
a service started at every login; `--status`, how they stand; `--stop`, either stopped.
"""
function connect_cli(args::AbstractVector{<:AbstractString})
    flags = filter(startswith("--"), args)
    valued = Set(j + 1 for (j, a) in enumerate(args) if a in ("--name", "--skip") && j < length(args))
    given(flag) = [args[j+1] for (j, a) in enumerate(args) if a == flag && j < length(args)]
    name = (n = given("--name"); isempty(n) ? nothing : last(n))
    plain = [a for (j, a) in enumerate(args) if !startswith(a, "--") && !(j in valued)]
    if length(plain) in (1, 2)
        length(plain) == 1 && !isdir(expand_home(plain[1])) &&
            error("$(plain[1]) is not a folder here: give a folder, or a site and a folder (zemi connect https://kb.example.org ~/Documents/Notes)")
        site = length(plain) == 2 ? connect_site(plain[1]) : default_connect_site()
        dir = abspath(expand_home(last(plain)))
        isdir(dir) || error("$dir is not a folder here")
        c = load_connect_config()
        get(c, "site", site) == site || error("zemi connect keeps folders in step with $(site_label(c["site"])) already")
        if site != "local" && get(load_connect_auth(), "site", "") != site
            save_connect_auth!(sign_in_library(site))
        end
        f = add_folder!(site, dir; name, skip = given("--skip"))
        say(:ok, "$(f["name"]) is kept in step with $(site_label(site))", ("Folder", f["path"]))
        syncing_pid() === nothing ? connect_once_cli() : request_pass()
        synced_by_local() || say(:info, "Keep it in step", "`zemi connect` to watch and manage the folders, `zemi connect --background` to " *
                                 (site == "local" ? "have the knowledge base sync them whenever it runs" : "sync from every login"))
    elseif !isempty(plain)
        error("Give a folder, or a site and a folder: zemi connect https://kb.example.org ~/Documents/Notes")
    elseif ("--background" in flags || "--install" in flags) && get(load_connect_config(), "site", "") == "local"
        running = set_background!(true)
        say(:ok, "The knowledge base run here syncs the folders" * (running ? ", from now" : ", once it runs") * " and whenever it runs",
            ("How it goes", "zemi connect --status"), ("To stop it", "zemi connect --stop"))
    elseif "--background" in flags || "--install" in flags
        start_background()
        say(:ok, "zemi connect syncs in the background, from now and at every login",
            ("Its log", contractuser(connect_log())), ("How it goes", "zemi connect --status"), ("To stop it", "zemi connect --stop"))
    elseif "--stop" in flags
        if synced_by_local()
            set_background!(false)
            say(:ok, "The knowledge base no longer syncs the folders", ("To sync them", "zemi connect, or zemi connect --background"))
        else
            stop_background() ? say(:ok, "The background service stopped") : say(:info, "No background service is set up")
        end
    elseif "--status" in flags
        return connect_status_cli()
    elseif "--once" in flags
        return connect_once_cli()
    elseif "--headless" in flags || !(stdout isa Base.TTY && stdin isa Base.TTY)
        return run_headless()
    else
        return run_connect_app()
    end
    return 0
end
