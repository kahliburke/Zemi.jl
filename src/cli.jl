# The zemi app's commands, other than serving (`run_local`, `run_shared`).

const CLI_HELP = """
    zemi [serve]                         serve the site and the API at http://localhost:8000, rebuilding the
                                         site when pages, notebooks, the package or the knowledge base change
    zemi manual                          the same, rebuilding on Enter (or when a job changes the knowledge base)
    zemi open                            open it in the browser, with the key that keeps other accounts out
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
    zemi token create NAME --out FILE [--write]
                                         issue NAME a key to the dataset's bucket, saved to FILE (read-only,
                                         or read and write with --write)
    zemi token list                      the keys issued
    zemi token revoke NAME               take NAME's key back
    zemi token add FILE                  install a key you were sent, and share the dataset it opens
    zemi token issuer                    save the Cloudflare API token that issues keys (asked for, not echoed)

    ZEMI_PORT=<port> serves on another port than 8000 (ZEMI_DEV_PORT, the development server's, than
    5173); ZEMI_CONFIG=<file> reads another config.
    """

"""
    agent_session(; tools = false)

Open a Kaimon session of this process's own, for agent summarizers to work through, and have Kaimon
start Qdrant if it manages it and it is not running. With `tools`, the session serves the knowledge
base's tools (as `zemi.*`) to the Kaimon on this machine, for its Claude sessions and notebooks;
otherwise it is unlisted.
"""
function agent_session(; tools::Bool = false)
    KAIMON[] === nothing && return @warn "Kaimon is not loaded: agent summarizers will not run"
    ensure_qdrant(kb().config; patience = 30) || @warn "Qdrant is not answering at $(Qdrant.url()): searching by meaning and embedding will fail"
    try
        Gate = kaimon().KaimonGate
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
        println(stderr, "zemi $cmd: ", sprint(showerror, e))
        return 1
    end
end
