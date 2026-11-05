# The browser tests, in one command: `julia --project=app test/browser/run.jl [file.test.mjs …]`.
# Starts the seeded test service (serve.jl) on ports of its own, runs test/browser/*.test.mjs (or
# those named) with Node once it answers, stops it, and exits as the tests did. The service's
# output goes to a log, named if the tests fail. Needs Node and the docs' packages (npm install in docs/).

root = dirname(dirname(@__DIR__))
api_port = get(ENV, "ZEMI_TEST_API_PORT", "8701")
site_port = get(ENV, "ZEMI_TEST_SITE_PORT", "5181")
log = joinpath(tempdir(), "zemi-browser-service.log")
env = merge(Dict(ENV), Dict("ZEMI_TEST_API_PORT" => api_port, "ZEMI_TEST_SITE_PORT" => site_port))
service = open(pipeline(setenv(`$(Base.julia_cmd()) --project=$(joinpath(root, "app")) $(joinpath(@__DIR__, "serve.jl"))`, env);
                        stderr = log), "r+")
ok = false
try
    @info "Starting the test service (the first time writes every page; its output: $log)"
    line = ""
    while !occursin("READY", line)
        eof(service) && error("The test service stopped before it was ready; see $log")
        line = readline(service)
    end
    @info "Test service ready: $(strip(line))"
    m = match(r"key=(\S+)", line)
    key = m === nothing ? "" : String(m[1])
    files = isempty(ARGS) ? filter(f -> endswith(f, ".test.mjs"), readdir(@__DIR__; join = true)) : abspath.(ARGS)
    node = something(Sys.which("node"), "node")
    tests = setenv(`$node --test --test-concurrency=1 $files`,
                   merge(env, Dict("ZEMI_TEST_SITE" => "http://localhost:$site_port", "ZEMI_TEST_API" => "http://127.0.0.1:$api_port",
                              "ZEMI_TEST_KEY" => key)))
    global ok = success(pipeline(Cmd(tests; dir = root); stdout = stdout, stderr = stderr))
    ok || @warn "Browser tests failed; the test service's output: $log"
finally
    close(service.in)                                   # the service stops itself, the development server with it
    t0 = time()
    while process_running(service) && time() - t0 < 60
        sleep(0.5)
    end
    process_running(service) && kill(service, Base.SIGKILL)
end
exit(ok ? 0 : 1)
