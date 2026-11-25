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

"""
    local_link(c, port = LOCAL_PORT[], path = "/"; to = "") -> String

The address that opens the knowledge base in a browser new to it, giving it the key. With `to`, the
browser is sent on there after: the development server's address, whose requests the cookie, set for
`localhost` on every port, then reaches the knowledge base with.
"""
local_link(c::Config, port::Integer = LOCAL_PORT[], path::AbstractString = "/"; to::AbstractString = "") =
    "http://localhost:$port$path?key=$(local_key(c))" * (isempty(to) ? "" : "&to=$(HTTP.escapeuri(to))")

"Where a browser given the key is sent on to: a path here, or a page served on this machine; else nowhere."
function sent_on(to::AbstractString)
    startswith(to, "/") && !startswith(to, "//") && return to
    return occursin(r"^http://(localhost|127\.0\.0\.1):\d+(/|$)", to) ? to : ""
end

"Whether `a` and `b` are equal, taking as long whatever they are."
same_secret(a::AbstractString, b::AbstractString) =
    ncodeunits(a) == ncodeunits(b) && foldl(|, (x ⊻ y for (x, y) in zip(codeunits(a), codeunits(b))); init = 0x00) == 0x00

"""
The page a browser without the key is shown. Approving a client (`approving`) is asked of a browser
another program opened, the default one, which `zemi open` gives the key to.
"""
locked_page(approving::Bool) = """<!doctype html><html><head><meta charset="utf-8"><title>Zemi</title>$ICON_LINK
    <meta name="viewport" content="width=device-width, initial-scale=1"></head>
    <body style="font-family:system-ui,sans-serif;max-width:34rem;margin:4rem auto;padding:0 1rem;line-height:1.5">
    <h1 style="font-size:1.3rem">This knowledge base is its owner's</h1>""" * (approving ?
    """<p>Connecting a program to it is approved in a browser that has its key, and this one does not yet.
    Run <code>zemi open</code> in a terminal, which gives your default browser the key, then reload this page.</p>""" :
    """<p>Open it from the address <code>zemi</code> printed when it started, or run <code>zemi open</code>.
    This browser then keeps its key.</p>""") * "</body></html>"

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
        rest = [k => v for (k, v) in params if !(k in ("key", "to"))]
        to = sent_on(get(params, "to", ""))
        isempty(to) && (to = uri.path * (isempty(rest) ? "" : "?" * HTTP.URIs.escapeuri(rest)))
        # Lax: sent when a link elsewhere leads here, never with another site's requests.
        return redirect(to, ["Set-Cookie" => "$(local_cookie())=$key; Path=/; HttpOnly; SameSite=Lax; Max-Age=$(400 * 86400)",
                             "Cache-Control" => "no-store"])
    end
    startswith(uri.path, "/api/") &&
        return json_response(Dict("error" => "This knowledge base is its owner's: open it from the address zemi printed, or run zemi open.",
                                  "locked" => true); status = 401)
    return HTTP.Response(401, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store"],
                         locked_page(uri.path == "/oauth/authorize"))
end

"""
    open_local()

`zemi open`: open the knowledge base run for one person in the browser where it is served (see
[`local_served`](@ref)), with its key: in development, given by the API's port, which then sends the
browser on to the development server.
"""
function open_local()
    c = load_config()
    s = local_served(c)
    s === nothing && return println(stderr, "Nothing is serving the knowledge base: start it with `zemi` first, then `zemi open`.")
    port = parse(Int, match(r":(\d+)$", s.api)[1])
    url = local_link(c, port; to = s.url == "http://localhost:$port" ? "" : s.url)
    cmd = Sys.isapple() ? `open $url` : Sys.iswindows() ? `cmd /c start "" $url` : `xdg-open $url`
    try
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
    catch
        println(url)
    end
end
