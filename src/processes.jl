# Processes the service starts and stops: the site's builds and its own Kaimon, each stopped when the
# service stops, and one an earlier run left running stopped when it starts again.

"Whether process `pid` runs here."
function pid_alive(pid::Integer)
    pid > 0 || return false
    Sys.iswindows() || return success(pipeline(`kill -0 $pid`; stderr = devnull))
    out = try readchomp(pipeline(`tasklist /FI "PID eq $pid" /FO CSV /NH`; stderr = devnull)) catch; "" end
    return occursin("\"$pid\"", out)
end

"""
    terminate(pid; group = false, what, seconds)

Stop process `pid` (with `group`, its whole process group): SIGTERM, then SIGKILL if it is still
running after `seconds`, with a warning naming `what` it was. On Windows, where a console program
takes no request to stop, it is ended at once, and with `group` the processes it started too.
"""
function terminate(pid::Integer; group::Bool = false, what::AbstractString, seconds::Real)
    if Sys.iswindows()
        tree = group ? ["/T"] : String[]
        run(pipeline(ignorestatus(`taskkill /F $tree /PID $pid`); stdout = devnull, stderr = devnull))
        return
    end
    target = group ? "-$pid" : "$pid"
    alive() = success(pipeline(`kill -0 $target`; stderr = devnull))
    run(pipeline(ignorestatus(`kill -TERM $target`); stderr = devnull))
    t0 = time()
    while alive() && time() - t0 < seconds
        sleep(0.25)
    end
    alive() && (@warn "$what did not stop in $(seconds) s; killing it" pid;
                run(pipeline(ignorestatus(`kill -KILL $target`); stderr = devnull)))
end

"The command line of process `pid`, or `\"\"` when there is none."
function process_command(pid::Integer)
    cmd = Sys.iswindows() ?
        `powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=$pid').CommandLine"` :
        `ps -o command= -p $pid`
    return try readchomp(pipeline(cmd; stderr = devnull)) catch; "" end
end

"When process `pid` started, in seconds since 1970, or `nothing` when there is none (Windows)."
function process_start(pid::Integer)
    cmd = `powershell -NoProfile -Command "[DateTimeOffset]::new((Get-Process -Id $pid).StartTime).ToUnixTimeSeconds()"`
    return tryparse(Int, try readchomp(pipeline(cmd; stderr = devnull)) catch; "" end)
end

"""
    reap_pid_file!(file; matches, what, group = false, seconds)

Stop the process an earlier run recorded in pid file `file`, if it still runs and is that process,
and remove the file. A pid is reused once its process ends, so what runs under it is checked: with
`matches(pid)`, or on Windows, which keeps no Julia program's arguments in its command line, by its
having started before the file was written. See [`terminate`](@ref) for `group` and `seconds`;
`what` names it in the log.
"""
function reap_pid_file!(file::AbstractString; matches, what::AbstractString, group::Bool = false, seconds::Real)
    isfile(file) || return
    pid = tryparse(Int, strip(read(file, String)))
    recorded(pid) = Sys.iswindows() ? something(process_start(pid), Inf) <= mtime(file) + 1 : matches(pid)
    if pid !== nothing && recorded(pid)
        @warn "Stopping $what left from an earlier run" pid
        terminate(pid; group, what = uppercasefirst(what), seconds)
    end
    rm(file; force = true)
end
