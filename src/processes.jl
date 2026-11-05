# Processes the service starts and stops: the site's builds and its own Kaimon, each stopped when the
# service stops, and one an earlier run left running stopped when it starts again.

"""
    terminate(pid; group = false, what, seconds)

Stop process `pid` (with `group`, its whole process group): SIGTERM, then SIGKILL if it is still
running after `seconds`, with a warning naming `what` it was.
"""
function terminate(pid::Integer; group::Bool = false, what::AbstractString, seconds::Real)
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
process_command(pid::Integer) = try readchomp(pipeline(`ps -o command= -p $pid`; stderr = devnull)) catch; "" end

"""
    reap_pid_file!(file; matches, what, group = false, seconds)

Stop the process an earlier run recorded in pid file `file`, if it still runs and `matches(pid)` (a
pid is reused once its process ends, so what runs under it is checked), and remove the file. See
[`terminate`](@ref) for `group` and `seconds`; `what` names it in the log.
"""
function reap_pid_file!(file::AbstractString; matches, what::AbstractString, group::Bool = false, seconds::Real)
    isfile(file) || return
    pid = tryparse(Int, strip(read(file, String)))
    if pid !== nothing && matches(pid)
        @warn "Stopping $what left from an earlier run" pid
        terminate(pid; group, what = uppercasefirst(what), seconds)
    end
    rm(file; force = true)
end
