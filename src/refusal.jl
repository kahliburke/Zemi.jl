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

"The reason a failure gives the person, or `nothing` for one that is the service's own (a bug, a crash)."
reason(e) = e isa Refusal || e isa ErrorException ? e.msg : nothing

"The HTTP status a failure is answered with."
error_status(e) = e isa Refusal ? e.status : e isa ErrorException ? 400 : 500
