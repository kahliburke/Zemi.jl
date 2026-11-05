# `zemi dev`'s writer of changed pages (see `write_changed_pages!`): one process that keeps Documenter
# compiled, so writing a few pages again takes moments rather than the time a new process takes to
# compile it. A request is a line on stdin, the environment to run make.jl with as tab-separated
# KEY=VALUE pairs; the answer is a line on stdout, "ok", or "error" and why.
using Documenter, DocumenterSlate, DocumenterVitepress
import KaimonSlate, Zemi

const ANSWER = stdout
redirect_stdout(stderr)
const MAKE = joinpath(@__DIR__, "make.jl")

for line in eachline(stdin)
    vars = [String(k) => String(v) for (k, v) in (split(kv, '='; limit = 2) for kv in split(line, '\t') if occursin('=', kv))]
    try
        # A module of its own each time, so make.jl's definitions start afresh.
        withenv(() -> Base.include(Module(:Pages), MAKE), vars...)
        println(ANSWER, "ok")
    catch e
        @error "Writing the pages failed" exception = (e, catch_backtrace())
        println(ANSWER, "error ", replace(sprint(showerror, e), '\n' => ' '))
    end
    flush(ANSWER)
end
