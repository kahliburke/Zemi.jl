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
    zemi connect SITE FOLDER [--name NAME]
                                         keep FOLDER (an Obsidian vault, say) in step with your library at SITE,
                                         signing in there in the browser (SITE `local`: the knowledge base run
                                         here); then `zemi connect` keeps every such folder in step until
                                         stopped, --once once, --install at every login
    zemi token create NAME --out FILE [--write]
                                         issue NAME a key to the dataset's bucket, saved to FILE (read-only,
                                         or read and write with --write)
    zemi token list                      the keys issued
    zemi token revoke NAME               take NAME's key back
    zemi token add FILE                  install a key you were sent, and share the dataset it opens
    zemi token issuer                    save the Cloudflare API token that issues keys (asked for, not echoed)
    zemi backup [--keep NAME]            take a snapshot now ([backup] in the config), kept by NAME until deleted
    zemi backups                         the snapshots, the latest first
    zemi restore SNAPSHOT [--config] [--force]
                                         put a snapshot back, with the service stopped: the database, content,
                                         records and files (the config folder's files too with --config);
                                         what was there is kept first as a snapshot. --force restores even
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
            text = bibliography(kb())
            if isempty(rest)
                print(text)
            else
                write(expanduser(rest[1]), text)
                println("Wrote $(count(startswith("@"), split(text, '\n'))) entries to $(rest[1])")
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
            before = restore_backup!(c, rest[1]; config_files = "--config" in rest)
            println("Restored $(rest[1]) into $(c.data_dir).", isempty(before) ? "" : " What was there is kept as the snapshot $before.")
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
                path = write_private(abspath(expanduser(out)), key_file(c, key; write = can_write, who = rest[2]))
                println("Issued $(key.name) ($(can_write ? "read and write" : "read-only")), saved to $path")
            elseif sub == "list"
                issued = list_keys(c)
                isempty(issued) && println("No keys issued.")
                foreach(k -> println(k.name, "  ", k.status), issued)
            elseif sub == "add" && length(rest) >= 2
                println(install_key(expanduser(rest[2])))
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
