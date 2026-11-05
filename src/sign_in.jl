# Who asks the shared service: their session's cookie or their token, and where a change may come
# from; and the sign-in page with the routes under `/auth/` it leads to (see auth.jl for the providers).

const SESSION_COOKIE = "kb_session"

function cookie(req::HTTP.Request, name::AbstractString)
    for c in split(HTTP.header(req, "Cookie", ""), ';')
        k, _, v = partition_eq(strip(c))
        k == name && return String(v)
    end
    return ""
end
partition_eq(s) = (i = findfirst('=', s); i === nothing ? (s, "", "") : (s[1:i-1], "=", s[i+1:end]))

"""
    shared_caller(kb, req) -> Caller

Who a request to the shared service comes from: the person whose token it carries
(`Authorization: Bearer zemi_…`), else whose session cookie, else nobody.
"""
function shared_caller(kb::KB, req::HTTP.Request)
    auth = HTTP.header(req, "Authorization", "")
    startswith(auth, "Bearer ") && return token_caller(kb, strip(auth[8:end]))
    return session_caller(kb, cookie(req, SESSION_COOKIE))
end

"The scheme, host and port people reach the service at, as an `Origin` header has them."
origin_of(url::AbstractString) = (u = HTTP.URI(url); string(u.scheme, "://", u.host, isempty(u.port) ? "" : ":" * u.port))

"""
Whether a change may be made with this request: one with a token always (a browser never sends a
token on its own); one with the session cookie only from the service's own pages, with the API's
header, which a form on another site cannot send.
"""
function shared_write_allowed(shared::SharedConfig, req::HTTP.Request)
    startswith(HTTP.header(req, "Authorization", ""), "Bearer ") && return true
    origin = HTTP.header(req, "Origin", "")
    # Under `zemi dev` the pages are the development server's, which forwards their requests here.
    ours = isempty(origin) || origin == origin_of(shared.base_url) || (!isempty(DEV_URL[]) && origin == origin_of(DEV_URL[]))
    return ours && HTTP.header(req, "X-Zemi", "") == "1"
end

function session_cookie(shared::SharedConfig, secret::AbstractString; max_age::Integer = shared.session_days * 86400)
    secure = startswith(shared.base_url, "https://") ? "; Secure" : ""
    return "Set-Cookie" => "$SESSION_COOKIE=$secret; Path=/; HttpOnly; SameSite=Lax; Max-Age=$max_age$secure"
end

"The cookie tying a sign-in to the browser that started it (see [`begin_sign_in`](@ref)), for its few minutes."
const SIGN_IN_COOKIE = "kb_signin"
function sign_in_cookie(shared::SharedConfig, secret::AbstractString; max_age::Integer = 600)
    secure = startswith(shared.base_url, "https://") ? "; Secure" : ""
    return "Set-Cookie" => "$SIGN_IN_COOKIE=$secret; Path=/auth; HttpOnly; SameSite=Lax; Max-Age=$max_age$secure"
end

redirect(to::AbstractString, headers = Pair{String,String}[]) = HTTP.Response(302, ["Location" => to, headers...])

# ── Signing in ────────────────────────────────────────────────────────────────────────────────────

"""
The sign-in page: a button for each provider, and, for a provider that sends people back to an
address not up yet, a box to paste that address into. Self-contained, so it needs nothing else of
the site, which is only for people signed in.
"""
function sign_in_page(shared::SharedConfig; return_to = "/", message = "")
    esc(s) = html_escape(string(s))
    rt = HTTP.escapeuri(return_to)
    buttons = join(("<a class=\"b\" href=\"/auth/login/$(slugify(p.name))?return_to=$rt\">Sign in with $(esc(p.name))</a>"
                    for p in shared.providers), "\n")
    isempty(shared.providers) && !local_sign_in(shared) && (buttons = "<p>No sign-in providers configured (<code>[[shared.providers]]</code>).</p>")
    # Signing in as anyone, for trying the service on this machine (see `local_sign_in`).
    local_form = !local_sign_in(shared) ? "" : """
        <form class="l" method="post" action="/auth/local"><p><strong>On this machine</strong>: sign in as $(shared.sign_up == :invite ? "anyone invited, or an admin" : "anyone").</p>
        <input name="email" type="email" placeholder="Email" required><input name="name" placeholder="Name (optional)">
        <input type="hidden" name="return_to" value="$(esc(return_to))"><button>Sign in</button></form>"""
    note = isempty(message) ? "" : "<p class=\"m\">$(esc(message))</p>"
    return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">$ICON_LINK
        <title>Sign in</title><style>
        body{font:16px/1.5 system-ui,sans-serif;background:#1b1b1f;color:#dfdfd6;display:grid;place-items:center;min-height:100vh;margin:0}
        main{max-width:30rem;padding:2rem}h1{font-size:1.4rem}a.b{display:block;margin:.6rem 0;padding:.7rem 1rem;border-radius:8px;
        background:#3dd68c;color:#1b1b1f;text-decoration:none;font-weight:600;text-align:center}.m{color:#f66f81}
        details{margin-top:2rem;color:#98989f;font-size:.9rem}form.l{margin:1rem 0;padding:1rem;border:1px dashed #f9b44e;border-radius:8px}
        form.l input{display:block;width:100%;box-sizing:border-box;margin:.4rem 0;padding:.45rem;background:#202127;color:inherit;
        border:1px solid #3c3f44;border-radius:6px}form.l button{background:#f9b44e}textarea{width:100%;box-sizing:border-box;margin:.5rem 0;background:#202127;
        color:inherit;border:1px solid #3c3f44;border-radius:6px;padding:.5rem}button{padding:.4rem 1rem;border-radius:6px;border:0;font-weight:600}
        </style></head><body><main>
        <h1>Sign in</h1>
        $note
        $buttons
        $local_form
        $(shared.sign_up == :invite ? "<p style=\"color:#98989f;font-size:.9rem\">Invitation only.</p>" : "")
        <details><summary>Return page didn't load?</summary>
        <p>Paste its full address:</p>
        <form method="post" action="/auth/paste"><textarea name="url" rows="3" required></textarea><button>Continue</button></form>
        </details></main></body></html>"""
end

function auth_response(kb::KB, shared::SharedConfig, req::HTTP.Request, parts, params)
    html(s; status = 200) = HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store"], s)
    signed_in(r) = redirect(r.return_to, [session_cookie(shared, start_session!(kb, r.user_id, shared;
                                                                                agent = HTTP.header(req, "User-Agent", ""))),
                                          sign_in_cookie(shared, ""; max_age = 0)])
    browser = cookie(req, SIGN_IN_COOKIE)
    failed(e) = (@warn "Sign-in failed" exception = e; html(sign_in_page(shared; message = client_message(e)); status = 400))
    if parts == ["auth", "sign-in"]
        return html(sign_in_page(shared; return_to = get(params, "return_to", "/")))
    elseif length(parts) == 3 && parts[2] == "login"
        b = new_secret()
        return try redirect(begin_sign_in(shared, parts[3]; return_to = get(params, "return_to", "/"), browser = b),
                            [sign_in_cookie(shared, b)]) catch e; failed(e) end
    elseif length(parts) == 3 && parts[2] == "callback"
        return try signed_in(finish_sign_in(kb, shared, parts[3], params; browser)) catch e; failed(e) end
    elseif parts == ["auth", "local"] && req.method == "POST" && local_sign_in(shared)
        # From the sign-in page's form, which sends no X-Zemi: its origin is the check.
        origin = HTTP.header(req, "Origin", "")
        origin in filter(!isempty, [origin_of(shared.base_url), isempty(DEV_URL[]) ? "" : origin_of(DEV_URL[])]) ||
            return html(sign_in_page(shared; message = "Sign in from this site's own page."); status = 403)
        direct_local(req) || return html(sign_in_page(shared; message = "Signing in without a provider is for this machine only."); status = 403)
        form = form_body(req)
        return try signed_in(finish_local_sign_in(kb, shared, form)) catch e; failed(e) end
    elseif parts == ["auth", "paste"] && req.method == "POST"
        url = get(form_body(req), "url", "")
        return try signed_in(finish_pasted_sign_in(kb, shared, url; browser)) catch e; failed(e) end
    elseif parts == ["auth", "sign-out"] && req.method == "POST"
        shared_write_allowed(shared, req) || return json_response(Dict("error" => "not from this site's pages"); status = 403)
        end_session!(kb, cookie(req, SESSION_COOKIE))
        return HTTP.Response(204, [session_cookie(shared, ""; max_age = 0)])
    end
    return HTTP.Response(404)
end
