"""
A request refused with a reason for whoever made it, and the HTTP status that says why: nothing of
that name to them (404, [`not_found`](@ref)), a permission they lack (403, [`not_permitted`](@ref)),
a service it depends on that failed (502, [`upstream_failed`](@ref)), or another (410 gone, 413 too
large). A plain `error(…)` is a request that cannot be done as asked (400).
"""
struct Refusal <: Exception
    status::Int
    msg::String
end
Base.showerror(io::IO, e::Refusal) = print(io, e.msg)

"Refuse a request for something there is none of, or that the caller may not know of."
not_found(msg...) = throw(Refusal(404, string(msg...)))

"Refuse a request for a permission the caller lacks."
not_permitted(msg...) = throw(Refusal(403, string(msg...)))

"Fail a request because a service it needs (arXiv, OpenAlex) answered with a failure of its own."
upstream_failed(msg...) = throw(Refusal(502, string(msg...)))

"""
    root_failure(e)

The failure itself, out of what carried it from a task: one thrown where work runs in tasks
(`asyncmap`, `fetch`) arrives wrapped, and shown as it comes it brings the task's stack trace along.
"""
root_failure(e) = e isa TaskFailedException ? root_failure(e.task.exception) :
                  e isa CompositeException && !isempty(e.exceptions) ? root_failure(first(e.exceptions)) :
                  e isa CapturedException ? root_failure(e.ex) : e

"A failure as a line for a person: its message, without the stack trace a task wraps it in."
failure_message(e) = sprint(showerror, root_failure(e))

"The reason a failure gives the person, or `nothing` for one that is the service's own (a bug, a crash)."
function reason(e)
    e = root_failure(e)
    return e isa Refusal || e isa ErrorException ? e.msg : e isa DroppedError ? sprint(showerror, e) : nothing
end

"The HTTP status a failure is answered with: a document dropped here is a conflict (409)."
function error_status(e)
    e = root_failure(e)
    return e isa Refusal ? e.status : e isa ErrorException ? 400 : e isa DroppedError ? 409 : 500
end
