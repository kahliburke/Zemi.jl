# The stand-in S3 (s3_standin.jl) as a service of its own, for trying a dataset in a bucket without
# one: `julia --project=test test/s3_serve.jl [DIR] [PORT]`. Objects are kept as files under DIR (by
# default ~/zemi-try/s3), so they outlast a restart; one access key, written to DIR/credentials.toml
# for `[dataset] credentials`. Stopped with Ctrl-C.

using Zemi
const K = Zemi
include("s3_standin.jl")

dir = abspath(expanduser(get(ARGS, 1, "~/zemi-try/s3")))
port = parse(Int, get(ARGS, 2, "9010"))
creds = joinpath(dir, "credentials.toml")
key = isfile(creds) ? K.TOML.parsefile(creds) :
      Dict("access_key_id" => "zemi-try", "secret_access_key" => bytes2hex(rand(UInt8, 20)))
mkpath(dir)
isfile(creds) || (write(creds, sprint(K.TOML.print, key)); chmod(creds, 0o600))
s3 = standin_s3(Dict(key["access_key_id"] => key["secret_access_key"]); port, dir = joinpath(dir, "objects"))
println("""
    A stand-in S3 at $(s3.endpoint), its objects in $(joinpath(dir, "objects")). In a config:

    [dataset]
    store = "s3"
    endpoint = "$(s3.endpoint)"
    bucket = "zemi-try"
    credentials = "$creds"
    """)
flush(stdout)
Base.exit_on_sigint(false)
try
    wait(s3.server)
catch e
    e isa InterruptException || rethrow()
    close(s3.server)
end
