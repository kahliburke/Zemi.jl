# Signing in to /mcp with OAuth 2.1, as MCP clients such as claude.ai's connectors do instead of a
# pasted token: the discovery documents (RFC 8414, RFC 9728), dynamic client registration (RFC 7591),
# the authorization code flow with PKCE (S256 only), and refresh tokens. A person approves a client on
# a page of the service, signed in; what the client gets is one of that person's API tokens (see
# accounts.jl), so /mcp treats it as any other: it acts for them, within their roles and projects, and
# shows in their tokens, where revoking it ends the connection. Its secret lasts an hour and is
# replaced in place on each refresh. Scope `library` asks for a token of the `library` permission
# alone, for the API rather than /mcp: `zemi connect`'s, keeping a folder in step with one's library.

migration!(17, ["ALTER TABLE oauth_codes ADD COLUMN scope TEXT NOT NULL DEFAULT 'mcp'",
                "ALTER TABLE api_tokens ADD COLUMN scope TEXT"])

"What a client may ask for: the tools at /mcp, or one's library through the API."
const OAUTH_SCOPES = ("mcp", "library")

"How long an access token, an authorization code and an unused refresh token last."
const OAUTH_ACCESS = Hour(1)
const OAUTH_CODE = Minute(5)
const OAUTH_REFRESH = Day(90)

"The service's address as clients reach it: the configured `base_url`, or this request's host."
oauth_base(sh::SharedConfig, req::HTTP.Request) =
    !isempty(sh.base_url) ? rstrip(sh.base_url, '/') : "http://" * HTTP.header(req, "Host", "127.0.0.1:$(sh.port)")

"Where a client finds how to sign in to /mcp (RFC 9728), named in /mcp's 401 answer."
resource_metadata_url(base::AbstractString) = "$base/.well-known/oauth-protected-resource/mcp"

oauth_protected_resource(base) = Dict("resource" => "$base/mcp", "authorization_servers" => [base],
                                      "bearer_methods_supported" => ["header"], "resource_name" => "Knowledge base")

oauth_server_metadata(base) = Dict(
    "issuer" => base, "authorization_endpoint" => "$base/oauth/authorize", "token_endpoint" => "$base/oauth/token",
    "registration_endpoint" => "$base/oauth/register", "response_types_supported" => ["code"],
    "grant_types_supported" => ["authorization_code", "refresh_token"], "code_challenge_methods_supported" => ["S256"],
    "token_endpoint_auth_methods_supported" => ["none"], "scopes_supported" => collect(OAUTH_SCOPES))

"""
The hosts a client may be sent back to over https: those of the MCP clients people connect. Anyone
may register a client and name it anything, so a client sent back to any other host could be
someone's own, collecting the codes of those it tricks into connecting it.
"""
const OAUTH_REDIRECT_HOSTS = ("claude.ai", "claude.com")

"A redirect address a client may register: https to `OAUTH_REDIRECT_HOSTS`, or http back to this machine (for local clients)."
function allowed_redirect(uri::AbstractString)
    u = try HTTP.URI(uri) catch; return false end
    isempty(u.fragment) || return false
    u.scheme == "https" && lowercase(u.host) in OAUTH_REDIRECT_HOSTS && return true
    return u.scheme == "http" && u.host in ("localhost", "127.0.0.1", "[::1]", "::1")
end

tryparse_host(uri::AbstractString) = (u = try HTTP.URI(uri) catch; nothing end; u === nothing || isempty(u.host) ? nothing : u.host)

"""
    register_client!(kb, request) -> Dict

Register a client (RFC 7591): `request` names it (`client_name`) and the addresses it is sent back
to (`redirect_uris`). A public client, with no secret: PKCE is what binds a code to it. Returns the
registration, with its `client_id`.
"""
function register_client!(kb::KB, request::AbstractDict)
    uris = get(request, "redirect_uris", nothing)
    uris isa AbstractVector && !isempty(uris) && all(u -> u isa AbstractString && allowed_redirect(u), uris) ||
        error("invalid_redirect_uri: give redirect_uris, each https to $(join(OAUTH_REDIRECT_HOSTS, " or ")), or http to localhost")
    method = get(request, "token_endpoint_auth_method", "none")
    method == "none" || error("invalid_client_metadata: only public clients (token_endpoint_auth_method none)")
    name = strip(string(get(request, "client_name", "")))
    name = isempty(name) ? "MCP client" : first(name, 80)
    id = "zemic_" * first(new_secret(), 24)
    now = now_iso()
    execute!(kb, "INSERT INTO oauth_clients (client_id, name, redirect_uris, created_at) VALUES (?, ?, ?, ?)",
             (id, name, JSON.json(String.(uris)), now))
    return Dict("client_id" => id, "client_name" => name, "redirect_uris" => uris, "client_id_issued_at" => round(Int, time()),
                "token_endpoint_auth_method" => "none", "grant_types" => ["authorization_code", "refresh_token"],
                "response_types" => ["code"])
end

"""
    authorization_request(kb, params) -> NamedTuple

Check an authorization request: a code (`response_type`) for a registered client, sent back to one
of its addresses, with an S256 challenge, for a scope of `OAUTH_SCOPES` (`mcp` when none is named).
Returns `(; client_id, client_name, redirect_uri, state, challenge, scope)`. A request that cannot be sent back (no such client, or an address it did not register)
is refused outright; any other problem is `(; …, error)`, for the client to be told at its address.
"""
function authorization_request(kb::KB, params::AbstractDict)
    id = get(params, "client_id", "")
    r = query(kb, "SELECT * FROM oauth_clients WHERE client_id = ?", (id,))
    isempty(r) && error("No such client")
    c = first(r)
    uri = get(params, "redirect_uri", "")
    registered = String.(JSON.parse(c.redirect_uris))
    isempty(uri) && length(registered) == 1 && (uri = only(registered))
    uri in registered || error("That address is not one the client registered")
    allowed_redirect(uri) || error("That address is not one clients may be sent back to")
    scope = strip(get(params, "scope", ""))
    out = (; client_id = String(id), client_name = String(c.name), redirect_uri = String(uri), state = get(params, "state", ""),
             challenge = get(params, "code_challenge", ""), scope = isempty(scope) ? "mcp" : String(scope))
    problem = get(params, "response_type", "") != "code" ? "unsupported_response_type" :
              isempty(out.challenge) || get(params, "code_challenge_method", "") != "S256" ? "invalid_request" :
              out.scope in OAUTH_SCOPES ? "" : "invalid_scope"
    return merge(out, (; error = problem))
end

"The address to send the browser back to, with `fields` added to its query."
function back_to(uri::AbstractString, fields::Pair...)
    u = HTTP.URI(uri)
    q = [collect(HTTP.queryparams(u)); [String(k) => String(v) for (k, v) in fields if !isempty(v)]]
    return string(HTTP.URI(u; query = HTTP.escapeuri(q)))
end

"""
    issue_code!(kb, request, uid) -> String

Person `uid` approved `request` (see [`authorization_request`](@ref)): the address to send the
browser back to, with a code good once, for five minutes, to this client with this verifier.
"""
function issue_code!(kb::KB, request, uid::Integer)
    code = "zemio_" * new_secret()
    execute!(kb, "DELETE FROM oauth_codes WHERE expires_at < ?", (now_iso(),))
    execute!(kb, "INSERT INTO oauth_codes (code_hash, client_id, user_id, redirect_uri, challenge, expires_at, scope) VALUES (?, ?, ?, ?, ?, ?, ?)",
             (secret_hash(code), request.client_id, uid, request.redirect_uri, request.challenge, iso_in(OAUTH_CODE), request.scope))
    return back_to(request.redirect_uri, "code" => code, "state" => request.state)
end

"The S256 challenge of a PKCE verifier."
pkce_challenge(verifier::AbstractString) =
    rstrip(replace(base64encode(sha256(verifier)), '+' => '-', '/' => '_'), '=')

struct OAuthError <: Exception
    code::String
    description::String
end
Base.showerror(io::IO, e::OAuthError) = print(io, e.code, ": ", e.description)

"""
    oauth_token!(kb, form) -> Dict

The token endpoint: exchange a code (`grant_type=authorization_code`, with `code_verifier`) or a
refresh token (`grant_type=refresh_token`) for an access token and a new refresh token. A code
makes a token for its person, named for the client, with their permissions (for scope `library`,
that one alone, where they have it); a refresh replaces that token's secrets in place, so the old
ones stop working. Refuses (`OAuthError`) what does not match.
"""
function oauth_token!(kb::KB, form::AbstractDict)
    grant = get(form, "grant_type", "")
    client = get(form, "client_id", "")
    access, refresh = "zemi_" * new_secret(), "zemir_" * new_secret()
    scope = "mcp"
    if grant == "authorization_code"
        code = get(form, "code", "")
        # Taken and removed in one step, so two requests with one code cannot both have it.
        r = transaction(kb) do
            rows = query(kb, "SELECT * FROM oauth_codes WHERE code_hash = ?", (secret_hash(code),))
            execute!(kb, "DELETE FROM oauth_codes WHERE code_hash = ?", (secret_hash(code),))   # good once
            rows
        end
        isempty(r) && throw(OAuthError("invalid_grant", "unknown or used code"))
        c = first(r)
        c.expires_at < now_iso() && throw(OAuthError("invalid_grant", "the code expired"))
        c.client_id == client || throw(OAuthError("invalid_grant", "the code is another client's"))
        c.redirect_uri == get(form, "redirect_uri", c.redirect_uri) || throw(OAuthError("invalid_grant", "another redirect_uri"))
        pkce_challenge(get(form, "code_verifier", "")) == c.challenge || throw(OAuthError("invalid_grant", "the code_verifier does not match"))
        name = String(scalar(kb, "SELECT name FROM oauth_clients WHERE client_id = ?", (client,)))
        scope = String(c.scope)
        perms = collect(user_permissions(kb, c.user_id))
        scope == "library" && (perms = intersect(perms, ["library"]))
        execute!(kb, """INSERT INTO api_tokens (user_id, name, token_hash, prefix, permissions, created_at, expires_at, client_id, refresh_hash, scope)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                 (c.user_id, "$name (connected)", secret_hash(access), first(access, 10), JSON.json(perms), now_iso(),
                  iso_in(OAUTH_ACCESS), client, secret_hash(refresh), scope))
        audit!(kb, account_caller(kb, c.user_id, :session), "oauth.connect"; detail = Dict("client" => name))
    elseif grant == "refresh_token"
        r = query(kb, "SELECT * FROM api_tokens WHERE refresh_hash = ?", (secret_hash(get(form, "refresh_token", "")),))
        isempty(r) && throw(OAuthError("invalid_grant", "unknown refresh token"))
        t = first(r)
        ismissing(t.revoked_at) || throw(OAuthError("invalid_grant", "the connection was revoked"))
        t.client_id == client || throw(OAuthError("invalid_grant", "the refresh token is another client's"))
        coalesce(t.last_used, t.created_at) < iso_in(-OAUTH_REFRESH) && throw(OAuthError("invalid_grant", "the refresh token expired"))
        scope = String(coalesce(t.scope, "mcp"))
        execute!(kb, "UPDATE api_tokens SET token_hash = ?, prefix = ?, expires_at = ?, refresh_hash = ?, last_used = ? WHERE id = ?",
                 (secret_hash(access), first(access, 10), iso_in(OAUTH_ACCESS), secret_hash(refresh), now_iso(), t.id))
    else
        throw(OAuthError("unsupported_grant_type", "authorization_code or refresh_token"))
    end
    return Dict("access_token" => access, "token_type" => "Bearer", "expires_in" => Dates.value(Second(OAUTH_ACCESS)),
                "refresh_token" => refresh, "scope" => scope)
end

# ── Pages and routes ──────────────────────────────────────────────────────────────────────────────

attr_escape(s) = html_escape(s)          # a field's value in a form

"""
The page where a signed-in person approves a client: who asks, as whom it would act, and what it
could do, with Allow and Deny. The request's fields ride along in the form.
"""
function consent_page(request, who::AbstractString, params::AbstractDict, form_key::AbstractString)
    fields = join(("<input type=\"hidden\" name=\"$(attr_escape(k))\" value=\"$(attr_escape(v))\">" for (k, v) in params), "")
    style = """.a{display:flex;gap:.6rem;margin-top:1.5rem}button{flex:1;padding:.7rem 1rem;border-radius:8px;border:0;font:inherit;font-weight:600;cursor:pointer}
               .y{background:var(--brand);color:var(--bg)}.n{background:var(--muted);color:var(--fg)}"""
    return service_page("Connect $(request.client_name)", """
        <p>$(request.scope == "library" ?
             "It would keep your library in step with a folder, as <b>$(html_escape(who))</b>: read and write your library's files, and nothing else." :
             "It would act as <b>$(html_escape(who))</b>, with your roles and projects.") It is sent back to
        <b>$(html_escape(something(tryparse_host(request.redirect_uri), request.redirect_uri)))</b>.</p>
        <p>Revoke it under Your account, Tokens.</p>
        <form method="post" action="/oauth/authorize">$fields<input type="hidden" name="form_key" value="$(attr_escape(form_key))">
        <div class="a"><button class="n" name="decision" value="deny">Deny</button><button class="y" name="decision" value="allow">Allow</button></div>
        </form>"""; style)
end

"""
    oauth_response(kb, sh, req, parts, params) -> HTTP.Response

Answer `/.well-known/oauth-*` and `/oauth/…` in the shared service: the discovery documents, client
registration, the approval page, and the token endpoint.
"""
function oauth_response(kb::KB, sh::SharedConfig, req::HTTP.Request, parts, params)
    base = oauth_base(sh, req)
    nostore = ["Content-Type" => "application/json", "Cache-Control" => "no-store"]
    jsonr(x; status = 200) = HTTP.Response(status, nostore, JSON.json(x))
    html(s; status = 200) = HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store",
                                                    "X-Frame-Options" => "DENY"], s)
    problem(code, text) = jsonr(Dict("error" => code, "error_description" => text); status = 400)
    if parts[1] == ".well-known"
        length(parts) >= 2 && parts[2] == "oauth-protected-resource" && return jsonr(oauth_protected_resource(base))
        length(parts) >= 2 && parts[2] == "oauth-authorization-server" && return jsonr(oauth_server_metadata(base))
        return HTTP.Response(404)
    elseif parts == ["oauth", "register"] && req.method == "POST"
        body = try json_body(req) catch; nothing end
        body isa AbstractDict || return problem("invalid_client_metadata", "a JSON object")
        return try jsonr(register_client!(kb, body); status = 201) catch e
            msg = reason(e)
            msg === nothing && rethrow()
            code, text = occursin(": ", msg) ? split(msg, ": "; limit = 2) : ("invalid_client_metadata", msg)
            problem(code, text)
        end
    elseif parts == ["oauth", "token"] && req.method == "POST"
        form = form_body(req)
        return try jsonr(oauth_token!(kb, form)) catch e
            e isa OAuthError ? problem(e.code, e.description) : rethrow()
        end
    elseif parts == ["oauth", "authorize"]
        fields = req.method == "POST" ? form_body(req) : params
        request = try authorization_request(kb, fields) catch e
            msg = reason(e)
            msg === nothing && rethrow()
            return html(service_page("Not connected", "<p>$(html_escape(msg)).</p>"); status = 400)
        end
        isempty(request.error) || return redirect(back_to(request.redirect_uri, "error" => request.error, "state" => request.state))
        session = cookie(req, SESSION_COOKIE)
        caller = session_caller(kb, session)
        caller.via == :session || return redirect("/auth/sign-in?return_to=" * HTTP.escapeuri(req.target))
        # An admin viewing as someone acts for them in nothing that outlasts the view, as tokens do.
        caller.admin === nothing ||
            return html(service_page("Not connected", "<p>Stop viewing as $(html_escape(caller.name)) to connect a client as yourself.</p>"); status = 403)
        # The approval comes from the page this service showed this person for this client.
        key = secret_hash("oauth|$session|$(request.client_id)|$(request.redirect_uri)")
        if req.method == "GET"
            keep = Dict(k => v for (k, v) in fields if k in ("client_id", "redirect_uri", "state", "code_challenge",
                                                              "code_challenge_method", "response_type", "scope", "resource"))
            return html(consent_page(request, caller_label(caller), keep, key))
        end
        get(fields, "form_key", "") == key || return html(service_page("Not connected", "<p>This approval did not come from this service's page.</p>"); status = 403)
        get(fields, "decision", "") == "allow" ||
            return redirect(back_to(request.redirect_uri, "error" => "access_denied", "state" => request.state))
        return redirect(issue_code!(kb, request, caller.user_id))
    end
    return HTTP.Response(404)
end
