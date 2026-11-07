# What agents are doing now, for the board to show: the tasks in progress they have worked on
# lately (changed or written on, in the activity, or read through their tools), and the projects
# where they wait for people (see `task_wait`). Reads and waits are kept in memory only.

"How long after an agent's last work on a task it still counts as working on it, in seconds."
const AGENT_ACTIVE_SECONDS = 30 * 60

const AGENT_SEEN = Dict{String,Tuple{String,Float64}}()          # task ref => (agent, when it read it)
const AGENTS_WAITING = Dict{Tuple{String,String},Float64}()      # (project, agent) => since when
const AGENT_ACTIVITY_LOCK = ReentrantLock()

"Note that `agent` read or used task `ref` through a tool."
agent_seen!(ref::AbstractString, agent::AbstractString) =
    lock(() -> (AGENT_SEEN[uppercase(strip(ref))] = (String(agent), time())), AGENT_ACTIVITY_LOCK)

"Note that `agent` waits for people on project `key` (`on = false`: no longer), and tell the boards."
function agent_waiting!(key::AbstractString, agent::AbstractString, on::Bool)
    lock(AGENT_ACTIVITY_LOCK) do
        on ? (AGENTS_WAITING[(String(key), String(agent))] = time()) : delete!(AGENTS_WAITING, (String(key), String(agent)))
    end
    tasks_changed!()
end

"""
    agents_at_work(kb, key) -> NamedTuple

What agents are doing in project `key`: `tasks`, each `(; ref, agent, at, via)`, the tasks in
progress an agent worked on in the last `AGENT_ACTIVE_SECONDS` (`at` when it last did; a task over
one being worked on is listed too, `via` the one), the latest first; and `waiting`, each
`(; agent, since)`, the agents waiting for people there.
"""
function agents_at_work(kb::KB, key::AbstractString)
    k = uppercase(strip(key))
    cutoff = time() - AGENT_ACTIVE_SECONDS
    latest = Dict{String,Tuple{String,Float64}}()
    keep!(ref, agent, t) = (t >= cutoff && t > get(latest, ref, ("", 0.0))[2]) && (latest[ref] = (agent, t))
    for r in query(kb, """SELECT p.key || '-' || t.number AS ref, e.who, max(e.at) AS at FROM task_events e
                          CROSS JOIN tasks t ON t.id = e.task_id JOIN projects p ON p.id = t.project_id
                          WHERE p.key = ? AND e.by_agent = 1 AND e.at >= ? GROUP BY t.id, e.who""", (k, iso(cutoff)))
        keep!(String(r.ref), String(r.who), datetime2unix(parse_iso(String(r.at))))
    end
    seen, waits = lock(() -> (copy(AGENT_SEEN), copy(AGENTS_WAITING)), AGENT_ACTIVITY_LOCK)
    for (ref, (agent, t)) in seen
        ref_project(ref) == k && keep!(ref, agent, t)
    end
    tasks = NamedTuple[]
    if !isempty(latest)
        rows = query(kb, """SELECT p.key || '-' || t.number AS ref, pp.key || '-' || pt.number AS parent FROM tasks t
                            JOIN projects p ON p.id = t.project_id LEFT JOIN tasks pt ON pt.id = t.parent_id
                            LEFT JOIN projects pp ON pp.id = pt.project_id WHERE p.key = ?""", (k,))
        parent = Dict(String(r.ref) => String(coalesce(r.parent, "")) for r in rows)
        working = Set(String(r.ref) for r in query(kb, """SELECT p.key || '-' || t.number AS ref FROM tasks t
                                                          JOIN projects p ON p.id = t.project_id
                                                          WHERE p.key = ? AND t.status = 'in_progress'""", (k,)))
        for (ref, (agent, t)) in sort!(collect(latest); by = x -> -x[2][2])
            ref in working && !any(x -> x.ref == ref, tasks) || continue
            push!(tasks, (; ref, agent, at = iso(t), via = ""))
            # The tasks it is part of, shown as being worked on through it.
            p = get(parent, ref, "")
            while !isempty(p) && !any(x -> x.ref == p, tasks)
                push!(tasks, (; ref = p, agent, at = iso(t), via = ref))
                p = get(parent, p, "")
            end
        end
    end
    waiting = [(; agent, since = iso(t)) for ((p, agent), t) in waits if p == k]
    return (; tasks, waiting)
end
