# The key a browser needs to reach the knowledge base run for one person (`zemi`). It listens on
# localhost, whose ports every account on the machine reaches; the key, in a file only its owner
# reads, keeps the others out. A browser is given it once, by the address `zemi` prints or by
# `zemi open`, and keeps it in a cookie.

"Where the key is kept: in the data directory, readable only by whoever runs the knowledge base."
local_key_path(c::Config) = joinpath(c.data_dir, "local_key")

const LOCAL_KEY = Ref(("", ""))          # (path, key), as last read
const LOCAL_KEY_LOCK = ReentrantLock()

"The knowledge base's local key, made the first time it is asked for."
function local_key(c::Config)
    path = local_key_path(c)
    lock(LOCAL_KEY_LOCK) do
        first(LOCAL_KEY[]) == path && return last(LOCAL_KEY[])
        key = isfile(path) ? String(strip(read(path, String))) : ""
        if isempty(key)
            key = new_secret()
            mkpath(dirname(path))
            write_private(path, key)
        end
        LOCAL_KEY[] = (path, key)
        return key
    end
end

"The port `zemi` serves on, which names its cookie: knowledge bases on other ports have keys of their own."
const LOCAL_PORT = Ref(0)
local_cookie() = "zemi_key_$(LOCAL_PORT[])"

"The address that opens the knowledge base in a browser new to it."
local_link(c::Config, port::Integer = LOCAL_PORT[], path::AbstractString = "/") = "http://localhost:$port$path?key=$(local_key(c))"

"Whether `a` and `b` are equal, taking as long whatever they are."
same_secret(a::AbstractString, b::AbstractString) =
    ncodeunits(a) == ncodeunits(b) && foldl(|, (x ⊻ y for (x, y) in zip(codeunits(a), codeunits(b))); init = 0x00) == 0x00

const LOCKED_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Zemi</title>$ICON_LINK
    <meta name="viewport" content="width=device-width, initial-scale=1"></head>
    <body style="font-family:system-ui,sans-serif;max-width:34rem;margin:4rem auto;padding:0 1rem;line-height:1.5">
    <h1 style="font-size:1.3rem">This knowledge base is its owner's</h1>
    <p>Open it from the address <code>zemi</code> printed when it started, or run <code>zemi open</code>.
    This browser then keeps its key.</p></body></html>"""

"""
    local_key_response(kb, req, uri, params) -> Union{HTTP.Response,Nothing}

`nothing` for a request with the knowledge base's key (its cookie, or `Authorization: Bearer`). For
one giving the key in `?key=`, the same address without it, the cookie set. For any other, a
refusal saying how to get in.
"""
function local_key_response(kb::KB, req::HTTP.Request, uri::HTTP.URI, params)
    key = local_key(kb.config)
    same_secret(cookie(req, local_cookie()), key) && return nothing
    auth = HTTP.header(req, "Authorization", "")
    startswith(auth, "Bearer ") && same_secret(String(strip(auth[8:end])), key) && return nothing
    if same_secret(get(params, "key", ""), key)
        rest = [k => v for (k, v) in params if k != "key"]
        to = uri.path * (isempty(rest) ? "" : "?" * HTTP.URIs.escapeuri(rest))
        # Lax: sent when a link elsewhere leads here, never with another site's requests.
        return redirect(to, ["Set-Cookie" => "$(local_cookie())=$key; Path=/; HttpOnly; SameSite=Lax; Max-Age=$(400 * 86400)",
                             "Cache-Control" => "no-store"])
    end
    startswith(uri.path, "/api/") &&
        return json_response(Dict("error" => "This knowledge base is its owner's: open it from the address zemi printed, or run zemi open.",
                                  "locked" => true); status = 401)
    return HTTP.Response(401, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store"], LOCKED_PAGE)
end

"""
    open_local(; port)

`zemi open`: open the knowledge base run for one person in the browser, with its key, once `zemi`
serves it on `port`.
"""
function open_local(; port::Integer = parse(Int, get(ENV, "ZEMI_PORT", "8000")))
    serving = try close(Sockets.connect("127.0.0.1", port)); true catch; false end
    serving || return println(stderr, "Nothing is serving on port $port: start the knowledge base with `zemi` first, then `zemi open`.")
    url = local_link(load_config(), port)
    cmd = Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start "" $url` : `xdg-open $url`
    try
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
    catch
        println(url)
    end
end
