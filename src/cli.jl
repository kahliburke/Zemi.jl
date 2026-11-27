# The zemi app's commands, other than serving (`run_local`, `run_shared`).

const CLI_HELP = """
    zemi [serve]                         serve the site and the API at http://localhost:8000, rebuilding the
                                         site when pages, notebooks, the package or the knowledge base change
    zemi open                            open it in the browser, with the key that keeps other accounts out
    zemi kaimon [--force]                have the Kaimon installed here run it, as its extension: Kaimon
                                         starts it with itself and serves its tools, and its panel there sets
                                         how it runs; zemi then says Kaimon runs it (--here runs it anyway)
    zemi dev [--shared [--kaimon]]       for developing it: the site from VitePress's development server at
                                         http://localhost:5173, components updated as they are edited, nothing
                                         bundled; with --shared, the shared service the same way
    zemi --shared [--kaimon] [--local-sign-in]
                                         serve it to the people signed in to it ([shared] in the config); with
                                         --kaimon, through the Kaimon running on this machine, not one of its own;
                                         with --local-sign-in (or ZEMI_LOCAL_SIGN_IN=1), signing in as anyone
                                         without a provider, on localhost only, for trying it
    zemi sync [--unread] [--resummarize] bring the knowledge base up to date (a dataset consumer imports the
                                         published dataset first); --unread also reads papers only recorded;
                                         --resummarize lets it replace agent summaries for more than a few
    zemi publish                         publish this knowledge base's stream of the dataset
    zemi pull                            import the dataset's streams
    zemi bib [FILE]                      every paper and upload as BibTeX, to FILE or the terminal
    zemi references [--force]            fetch reference lists for the papers that have none fetched yet
                                         (--force: every paper again); nothing is summarized or embedded
    zemi connect SITE FOLDER [--name NAME] [--skip SUBFOLDER]...
                                         keep FOLDER (an Obsidian vault, say) in step with your library at SITE,
                                         signing in there in the browser (SITE `local`: the knowledge base run
                                         here), its SUBFOLDERs never sent. `zemi connect` alone: an app that
                                         shows and manages the folders; --background syncs from every login
                                         (--status, --stop), --once once
    zemi obsidian [VAULT] [--name NAME]  build Zemi's Obsidian plugin and install it in VAULT (its folder, or
                                         the name of a vault Obsidian has opened; alone, the one it knows),
                                         and connect the vault as zemi connect does (as NAME in your library)
    zemi token create NAME --out FILE [--write]
                                         issue NAME a key to the dataset's bucket, saved to FILE (read-only,
                                         or read and write with --write)
    zemi token list                      the keys issued
    zemi token revoke NAME               take NAME's key back
    zemi token add FILE                  install a key you were sent, and share the dataset it opens
    zemi token issuer                    save the Cloudflare API token that issues keys (asked for, not echoed)
    zemi admin [EMAIL]...                make EMAIL an admin of the shared service: an account with it gets
                                         the role back, otherwise it is invited as one and its first sign-in
                                         makes it an admin. Alone, who can administer it
    zemi backup [--keep NAME]            take a snapshot now ([backup] in the config), kept by NAME until deleted
    zemi backup --offsite [--background | --follow]
                                         copy the latest snapshot off this machine now ([backup.offsite]),
                                         showing how far it has got; --background sends it from a process
                                         of its own, which goes on when the terminal closes; --follow (or the
                                         same command while one is being sent) shows the copy under way
    zemi backup --offsite-key [FILE]     make the key [backup.offsite] seals copies with (beside the config
                                         by default); keep a copy of it somewhere other than this machine
    zemi backup --offsite-recovery       set the recovery passphrase, which opens the copies without the key
    zemi backups [--offsite [--check [--full]] [--recovery]]
                                         the snapshots, the latest first; with --offsite those in the store,
                                         and with --check, proof in seconds that the latest restores (the
                                         store holds every object as sent, by the copy's digest; every file
                                         fetched with --full), with the passphrase given --recovery
    zemi restore SNAPSHOT [--config] [--include] [--force]
    zemi restore --offsite COPY [--recovery] [--config] [--include] [--force]
                                         put a snapshot back, with the service stopped: the database, content,
                                         records and files (the config folder's files too with --config, the
                                         paths [backup] include names with --include); what was there is kept
                                         first as a snapshot. --offsite fetches it from the store first, opened
                                         with the key or (--recovery) the passphrase. --force restores even
                                         though something answers on the service's port

    ZEMI_PORT=<port> serves on another port than [service] port, 8000 by default (ZEMI_DEV_PORT, the
    development server's, than [service] dev_port, 5173); ZEMI_CONFIG=<file> reads another config.
    """

"""
    agent_session(; tools = false)

Open a Kaimon session of this process's own, for agent summarizers to work through, and have Kaimon
start Qdrant if it manages it and it is not running. With `tools`, the session serves the knowledge
base's tools (as `zemi.*`) to the Kaimon on this machine, for its Claude sessions and notebooks;
otherwise it is unlisted.
"""
function agent_session(; tools::Bool = false)
    kaimon_running() || @warn "No Kaimon is running on this machine: agent summarizers will not run"
    ensure_qdrant(kb().config; patience = 30) || @warn "Qdrant is not answering at $(Qdrant.url()): searching by meaning and embedding will fail"
    try
        Gate = KaimonGate
        tools ? Gate.serve(; tools = create_tools(Gate.GateTool), namespace = MCP_NAMESPACE, force = true,
                           allow_mirror = false, allow_restart = false) :
                Gate.serve(; force = true, discoverable = false)
    catch e
        @warn "No Kaimon session: agent summarizers will not run" exception = e
    end
end

option(args, flag) = (i = findfirst(==(flag), args); i === nothing || i == length(args) ? nothing : args[i+1])

"The recovery passphrase, asked for without echoing it."
function passphrase_prompt()
    p = Base.getpass("Recovery passphrase")
    try
        return read(seekstart(p), String)
    finally
        Base.shred!(p)
    end
end

"""
    progress_line() -> (report, finish)

Progress for a terminal: each report replaces the last on one line, and `finish()` ends the line.
Where stderr is not a terminal (a log), each report is its own line.
"""
function progress_line()
    tty = stderr isa Base.TTY
    report(msg) = tty ? print(stderr, "\r\e[K", first(msg, displaysize(stderr)[2] - 1)) : println(stderr, msg)
    finish() = tty && println(stderr)
    return report, finish
end

"""
    follow_copy(config)

Show how far the copy being sent off this machine has got (see [`sending_offsite`](@ref)), by
whichever process sends it, until it ends; then the last copy made. Leaving it (Ctrl-C) leaves the
copy going.
"""
function follow_copy(c::Config)
    meter, done = progress_line()
    d = sending_offsite(c)
    d === nothing && return println("No copy is being sent off this machine now.")
    stamp = d["stamp"]
    while (d = sending_offsite(c)) !== nothing
        meter(offsite_progress_text(d))
        sleep(1)
    end
    done()
    mark = try TOML.parsefile(offsite_mark(c)) catch; Dict{String,Any}() end
    println(get(mark, "stamp", "") == stamp ? "Copied $stamp off this machine to $(offsite_json(c)["where"])." :
            "The copy of $stamp stopped before it was done; see $(joinpath(backup_dir(c), "offsite.log")) when it was sent in the background.")
end

"""
    admin_cli(kb, emails) -> Vector{String}

`zemi admin`: make each of `emails` an admin (see [`make_admin!`](@ref)), saying what was done; with
none, who can administer the service: those the config names, the admins' accounts and the open
invitations to be one.
"""
function admin_cli(kb::KB, emails)
    shared = kb.config.shared
    isempty(shared.base_url) && error("zemi admin is for a shared service, and [shared] base_url is not set in $(config_path())")
    if !isempty(emails)
        return map(emails) do email
            make_admin!(kb, email) == :granted ? "$email is an admin." :
                "$email is invited as an admin: signing in at $(shared.base_url) with any of its providers makes them one."
        end
    end
    ensure_roles!(kb)
    managing = managing_roles(kb)
    lines = String[]
    isempty(shared.admins) || push!(lines, "Named in the config: $(join(shared.admins, ", "))")
    for u in users(kb)
        isdisjoint(u.roles, managing) || push!(lines, "Account: $(u.email)$(u.disabled ? " (disabled)" : "")")
    end
    for i in invitations(kb)
        isempty(i.accepted_at) && !isdisjoint(i.roles, managing) && push!(lines, "Invited: $(i.email)")
    end
    why = admin_problem(kb)
    isempty(why) || push!(lines, why)
    return lines
end

"The port of this knowledge base's service, the shared one's or `zemi`'s, if something answers on it."
function serving_port(c::Config)
    for port in unique([c.shared.port, parse(Int, get(ENV, "ZEMI_PORT", "8000"))])
        port_taken(port) && return port
    end
    return nothing
end

"""
    cli(args) -> Int

Run one of `zemi`'s commands (see `CLI_HELP`), returning the exit status.
"""
function cli(args::AbstractVector{<:AbstractString})
    say(msg) = println(stderr, msg)
    meter, done = progress_line()
    cmd = isempty(args) ? "help" : args[1]
    rest = args[2:end]
    try
        if cmd == "open"
            open_local()
        elseif cmd == "obsidian"
            foreach(println, obsidian_cli(rest))
        elseif cmd == "kaimon"
            say_registered(register_extension(; force = "--force" in rest))
        elseif cmd == "sync"
            agent_session()
            println(format_sync(sync!(kb(); unread = "--unread" in rest, resummarize = "--resummarize" in rest, progress = say)))
        elseif cmd == "publish"
            db = kb()
            db.config.dataset.role == :publish || error("This knowledge base is not a dataset publisher: set [dataset] role = \"publish\"")
            r = publish!(db; progress = meter)
            done()
            println(format_publish(r))
        elseif cmd == "pull"
            r = pull!(kb(); progress = meter)
            done()
            println(format_pull(r))
        elseif cmd == "bib"
            text = bibliography(kb(); space = "people/local")
            if isempty(rest)
                print(text)
            else
                write(expand_home(rest[1]), text)
                println("Wrote $(count(startswith("@"), split(text, '\n'))) entries to $(rest[1])")
            end
        elseif cmd == "references"
            db = kb()
            r = fetch_references!(db, literature_ids(db); force = "--force" in rest, progress = meter)
            done()
            println(references_report(r))
        elseif cmd == "admin"
            foreach(println, admin_cli(kb(), rest))
        elseif cmd == "backup" && "--offsite-key" in rest
            file = something(option(rest, "--offsite-key"), joinpath(dirname(config_path()), "backup_key"))
            path = new_offsite_key!(expand_home(file))
            println("Made a key at $path. In the config:\n\n  [backup.offsite]\n  key = \"file:$path\"\n\n",
                    "Keep a copy of it somewhere other than this machine (a password manager, say), and set a recovery\n",
                    "passphrase once copies are sent (zemi backup --offsite-recovery): without either, a lost machine's copies can't be opened.")
        elseif cmd == "backup" && "--offsite-recovery" in rest
            c = validate(load_config())
            a = Base.getpass("Recovery passphrase (12 characters or more)")
            b = Base.getpass("The same again")
            try
                read(seekstart(a), String) == read(seekstart(b), String) || error("The passphrases differ")
                set_offsite_recovery!(c, read(seekstart(a), String))
            finally
                Base.shred!(a); Base.shred!(b)
            end
            println("The copies open with the recovery passphrase too. Keep it where you would look for it without this machine.")
        elseif cmd == "backup" && "--offsite" in rest
            c = validate(load_config())
            if "--follow" in rest || sending_offsite(c) !== nothing
                follow_copy(c)
            elseif "--background" in rest
                log = joinpath(backup_dir(c), "offsite.log")
                mkpath(dirname(log))
                project = something(Base.active_project(), "@.")
                cmd = `$(Base.julia_cmd()) --startup-file=no --threads=auto --project=$project -m Zemi backup --offsite`
                p = run(pipeline(Cmd(cmd; detach = true); stdout = log, stderr = log, stdin = devnull); wait = false)
                println("Copying off this machine in the background (process $(getpid(p))), on when this terminal closes.\n",
                        "zemi backup --offsite --follow shows how far it has got; its output goes to $log.")
            else
                r = offsite!(c; progress = meter)
                done()
                println("Copied $(r.stamp) off this machine ($(r.sent) new file(s)) to $(offsite_json(c)["where"])")
            end
        elseif cmd == "backups" && "--offsite" in rest
            c = validate(load_config())
            passphrase = "--recovery" in rest ? passphrase_prompt() : nothing
            if "--check" in rest
                full = "--full" in rest
                r = check_offsite(c; passphrase, full, progress = meter)
                done()
                mb = round(r.bytes / 1e6; digits = 1)
                println(full ? "$(r.stamp) restores: every part fetched, unsealed and checked, $(r.files) file(s), $mb MB, the database intact." :
                        "$(r.stamp) restores: it opens with the key at hand, and the store holds exactly what was sent, every object " *
                        "by its SHA-256, the copy's digest $(first(r.digest, 16))…; $(r.files) file(s), $mb MB, $(r.fetched) opened at random. " *
                        "--full fetches and checks every file.")
            else
                store = offsite_store(c)
                copies = offsite_copies(c; store)
                isempty(copies) && println("No copies in $(offsite_json(c)["where"]).")
                for x in copies
                    println(rpad(x.stamp, 20), Dates.format(x.at, "yyyy-mm-dd HH:MM"), " UTC", x.complete ? "" : "  incomplete")
                end
                store === nothing || println(has_offsite_recovery(store) ? "A recovery passphrase is set." :
                                             "No recovery passphrase: set one with zemi backup --offsite-recovery.")
            end
        elseif cmd == "backup"
            c = validate(load_config())
            path = backup!(c; keep = something(option(rest, "--keep"), ""))
            println("Backed up to $path ($(round(filesize(joinpath(path, "state.tar.zst")) / 1e6; digits = 1)) MB packed, and the files)")
        elseif cmd == "backups"
            c = validate(load_config())
            all = backups(c)
            isempty(all) && println("No snapshots in $(backup_dir(c)).")
            for b in all
                println(rpad(b.name, 34), b.kept ? "kept  " : "      ", Dates.format(b.at, "yyyy-mm-dd HH:MM"), " UTC  schema ", b.schema,
                        "  ", round(b.state_bytes / 1e6; digits = 1), " MB")
            end
        elseif cmd == "restore" && length(rest) >= 1
            c = validate(load_config())
            port = serving_port(c)
            port === nothing || "--force" in rest ||
                error("something answers on port $port, the service's: stop it first (or pass --force if it is not this knowledge base)")
            config_files, included = "--config" in rest, "--include" in rest
            name = something(option(rest, "--offsite"), rest[1])
            before = if "--offsite" in rest
                option(rest, "--offsite") === nothing && error("say which copy: zemi restore --offsite COPY (zemi backups --offsite lists them)")
                restore_offsite!(c, name; passphrase = "--recovery" in rest ? passphrase_prompt() : nothing, config_files, included,
                                 progress = meter)
            else
                restore_backup!(c, name; config_files, included)
            end
            done()
            println("Restored $name into $(c.data_dir).", isempty(before) ? "" : " What was there is kept as the snapshot $before.")
        elseif cmd == "connect"
            return connect_cli(rest)
        elseif cmd == "token"
            c = load_config()
            sub = get(rest, 1, "")
            if sub == "create" && length(rest) >= 2
                out = option(rest, "--out")
                out === nothing && error("say where to save the key with --out FILE: the secret is not printed")
                can_write = "--write" in rest
                key = issue_key(c, rest[2]; write = can_write)
                path = write_private(abspath(expand_home(out)), key_file(c, key; write = can_write, who = rest[2]))
                println("Issued $(key.name) ($(can_write ? "read and write" : "read-only")), saved to $path")
            elseif sub == "list"
                issued = list_keys(c)
                isempty(issued) && println("No keys issued.")
                foreach(k -> println(k.name, "  ", k.status), issued)
            elseif sub == "add" && length(rest) >= 2
                println(install_key(expand_home(rest[2])))
            elseif sub == "issuer"
                token = Base.getpass("Cloudflare API token (Account API Tokens: Edit)")
                println("Saved to $(save_issuer_token(read(seekstart(token), String), c)).")
                Base.shred!(token)
            elseif sub == "revoke" && length(rest) >= 2
                revoke_key(c, rest[2])
                println("Revoked $(key_name(c, rest[2])).")
            else
                println(CLI_HELP)
                return 2
            end
        else
            println(CLI_HELP)
            return cmd in ("help", "-h", "--help") ? 0 : 2
        end
        return 0
    catch e
        e isa InterruptException && rethrow()
        println(stderr, "zemi $cmd: ", failure_message(e))
        return 1
    end
end
