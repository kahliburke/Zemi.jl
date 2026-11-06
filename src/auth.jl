# Signing in to the shared service through the providers in `[shared.providers]`: the authorization
# code flow, with `state` and (for OIDC) PKCE and a `nonce`. The browser goes to the provider and is
# sent back to `/auth/callback/<provider>` with a code, which this service exchanges for the person's
# identity by asking the provider directly over TLS. Only the browser needs to reach this service, so
# it signs people in on `localhost` too; where a provider will only send people back to an address
# that is not up yet, the address it sent them to can be pasted in to finish (`finish_sign_in`).

"How long a sign-in may take between leaving for the provider and coming back."
const SIGN_IN_WINDOW = Minute(10)

# Sign-ins under way, by their `state`: kept in memory, as a restart only means signing in again.
const PENDING = Dict{String,NamedTuple}()
const PENDING_LOCK = ReentrantLock()

"The GitHub endpoints (replaced in tests by a stand-in)."
const GITHUB = Ref((authorize = "https://github.com/login/oauth/authorize",
                    token = "https://github.com/login/oauth/access_token", api = "https://api.github.com"))

function provider(shared::SharedConfig, slug::AbstractString)
    i = findfirst(p -> slugify(p.name) == slug, shared.providers)
    i === nothing && not_found("No sign-in provider $slug")
    return shared.providers[i]
end

"Where provider `p` sends people back to."
callback_url(shared::SharedConfig, p::Provider) = "$(shared.base_url)/auth/callback/$(slugify(p.name))"

const DISCOVERY = LockedDict{String,Tuple{Float64,Dict{String,Any}}}()

"An OIDC provider's discovery document, fetched again after an hour."
function discovery(p::Provider)
    cached = get(DISCOVERY, p.issuer, nothing)
    cached !== nothing && time() - cached[1] < 3600 && return cached[2]
    r = HTTP.get(p.issuer * "/.well-known/openid-configuration"; status_exception = false, connect_timeout = 15, read_idle_timeout = 30)
    r.status == 200 || error("$(p.name): its discovery document answered HTTP $(r.status)")
    d = JSON.parse(String(r.body))
    DISCOVERY[p.issuer] = (time(), d)
    return d
end

base64url(bytes) = rstrip(replace(base64encode(bytes), '+' => '-', '/' => '_'), '=')
function base64url_decode(s::AbstractString)
    t = replace(s, '-' => '+', '_' => '/')
    return base64decode(t * repeat("=", mod(-length(t), 4)))
end

"A path on this site to return to after signing in: `path` when it is one, else the front page."
safe_return(path::AbstractString) =
    startswith(path, "/") && !startswith(path, "//") && !occursin(r"[\\\x00-\x20\x7f]", path) ? String(path) : "/"

"""
    begin_sign_in(shared, slug; return_to = "/", browser) -> String

Start signing in with provider `slug`: the address to send the browser to. `return_to`, a path on
this site, is where the person lands afterwards. `browser` is a secret the browser keeps in a
cookie (see `SIGN_IN_COOKIE`): only that browser can finish this sign-in, so nobody can have
someone else's browser finish one they started, and be signed in as them there.
"""
function begin_sign_in(shared::SharedConfig, slug::AbstractString; return_to::AbstractString = "/", browser::AbstractString = "")
    p = provider(shared, slug)
    state, nonce, verifier = new_secret(), new_secret(), new_secret()
    # Only a path on this site: not another site's address, however it is spelled (browsers drop tabs
    # and line breaks, so `/\t/elsewhere` would be `//elsewhere`).
    return_to = safe_return(return_to)
    lock(PENDING_LOCK) do
        filter!(kv -> now(UTC) - kv[2].at < SIGN_IN_WINDOW, PENDING)
        PENDING[state] = (; provider = slug, nonce, verifier, return_to, at = now(UTC), browser = secret_hash(browser))
    end
    q = ["response_type" => "code", "client_id" => p.client_id, "redirect_uri" => callback_url(shared, p),
         "scope" => p.scopes, "state" => state]
    if p.kind == :oidc
        challenge = base64url(sha256(verifier))
        append!(q, ["nonce" => nonce, "code_challenge" => challenge, "code_challenge_method" => "S256"])
        endpoint = discovery(p)["authorization_endpoint"]
    else
        endpoint = GITHUB[].authorize
    end
    return endpoint * "?" * HTTP.escapeuri(q)
end

"""
    finish_sign_in(kb, shared, slug, params; browser) -> (; user_id, return_to)

Finish signing in with provider `slug`, from the parameters it sent the browser back with (`code`
and `state`, or `error`): the account signed in to (see [`sign_in!`](@ref)), and where to go next.
A `state` is used once, only within [`SIGN_IN_WINDOW`](@ref) of starting, and only by the browser
that started it (`browser`, its cookie; see [`begin_sign_in`](@ref)).
"""
function finish_sign_in(kb::KB, shared::SharedConfig, slug::AbstractString, params::AbstractDict; browser::AbstractString = "")
    haskey(params, "error") && error("Not signed in: " *
                                     get(params, "error_description", params["error"]))
    state, code = get(params, "state", ""), get(params, "code", "")
    pending = lock(PENDING_LOCK) do
        pop!(PENDING, state, nothing)
    end
    (pending === nothing || now(UTC) - pending.at > SIGN_IN_WINDOW) && error("Sign-in expired. Try again.")
    !isempty(browser) && secret_hash(browser) == pending.browser || error("This sign-in was started in another browser. Try again here.")
    pending.provider == slug || error("This sign-in was started with another provider")
    isempty(code) && error("The provider sent no code")
    p = provider(shared, slug)
    who = p.kind == :oidc ? oidc_identity(shared, p, code, pending) : github_identity(shared, p, code)
    uid = sign_in!(kb, shared, p.name, who.subject; who.email, who.verified, who.name)
    return (; user_id = uid, pending.return_to)
end

"""
    finish_pasted_sign_in(kb, shared, url; browser) -> (; user_id, return_to)

Finish a sign-in from the address the provider sent the browser to, pasted in: for a provider that
only sends people to an address that is not up yet.
"""
function finish_pasted_sign_in(kb::KB, shared::SharedConfig, url::AbstractString; browser::AbstractString = "")
    u = HTTP.URI(strip(url))
    m = match(r"/auth/callback/([^/?#]+)", u.path)
    m === nothing && error("That is not an address this service sends people back to (…/auth/callback/<provider>?code=…)")
    return finish_sign_in(kb, shared, String(m[1]), HTTP.queryparams(u); browser)
end

function token_request(url, form; headers = Pair{String,String}[])
    r = HTTP.post(url, ["Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json", headers...],
                  HTTP.escapeuri(form); status_exception = false, connect_timeout = 15, read_idle_timeout = 30)
    body = try JSON.parse(String(r.body)) catch; Dict{String,Any}() end
    (r.status == 200 && !haskey(body, "error")) ||
        error("The provider would not exchange the code (HTTP $(r.status)): " * string(get(body, "error_description", get(body, "error", ""))))
    return body
end

"""
Whether an ID token's `iss` names `issuer`. Google writes its issuer without the scheme in some
tokens (`accounts.google.com`), which names the same issuer.
"""
function issued_by(iss::AbstractString, issuer::AbstractString)
    iss = rstrip(iss, '/')
    return iss == issuer || (!occursin("://", iss) && replace(issuer, r"^https?://" => "") == iss)
end

function oidc_identity(shared::SharedConfig, p::Provider, code::AbstractString, pending)
    d = discovery(p)
    t = token_request(d["token_endpoint"], ["grant_type" => "authorization_code", "code" => code,
        "redirect_uri" => callback_url(shared, p), "client_id" => p.client_id,
        "client_secret" => resolve_key(p.client_secret, "provider $(p.name)"), "code_verifier" => pending.verifier])
    haskey(t, "id_token") || error("$(p.name) returned no ID token")
    # The ID token came straight from the token endpoint over TLS, so TLS vouches for its issuer
    # (OIDC Core 3.1.3.7) and its signature need not be checked; its claims must still hold.
    parts = split(t["id_token"], '.')
    length(parts) == 3 || error("$(p.name) returned a malformed ID token")
    claims = JSON.parse(String(base64url_decode(parts[2])))
    issued_by(string(get(claims, "iss", "")), p.issuer) || error("The ID token is not from $(p.issuer)")
    aud = get(claims, "aud", "")
    p.client_id in (aud isa AbstractVector ? aud : [aud]) || error("The ID token is not for this service")
    get(claims, "exp", 0) > time() || error("The ID token has expired")
    get(claims, "nonce", "") == pending.nonce || error("The ID token does not answer this sign-in")
    if !haskey(claims, "email") && haskey(d, "userinfo_endpoint") && haskey(t, "access_token")
        r = HTTP.get(d["userinfo_endpoint"], ["Authorization" => "Bearer $(t["access_token"])"]; status_exception = false)
        r.status == 200 && merge!(claims, JSON.parse(String(r.body)))
    end
    email = string(get(claims, "email", ""))
    # One that does not say whether the email is verified (some institutional ones) is believed only
    # when the config says its emails are its own records of people.
    verified = haskey(claims, "email_verified") ? claims["email_verified"] in (true, "true") : p.email_verified
    name = string(get(claims, "name", join(filter(!isempty, [string(get(claims, "given_name", "")), string(get(claims, "family_name", ""))]), " ")))
    return (; subject = string(claims["sub"]), email, verified, name)
end

function github_identity(shared::SharedConfig, p::Provider, code::AbstractString)
    t = token_request(GITHUB[].token, ["client_id" => p.client_id, "client_secret" => resolve_key(p.client_secret, "provider $(p.name)"),
                                       "code" => code, "redirect_uri" => callback_url(shared, p)])
    auth = ["Authorization" => "Bearer $(t["access_token"])", "Accept" => "application/vnd.github+json"]
    get_json(path) = (r = HTTP.get(GITHUB[].api * path, auth; status_exception = false);
                      r.status == 200 || error("GitHub answered HTTP $(r.status) for $path"); JSON.parse(String(r.body)))
    user = get_json("/user")
    emails = get_json("/user/emails")
    i = findfirst(e -> get(e, "primary", false) && get(e, "verified", false), emails)
    i === nothing && (i = findfirst(e -> get(e, "verified", false), emails))
    email = i === nothing ? "" : string(emails[i]["email"])
    return (; subject = string(user["id"]), email, verified = i !== nothing,
              name = string(something(get(user, "name", nothing), get(user, "login", ""))))
end

# ── Signing in on this machine, for trying the service ────────────────────────────────────────────

"Whether signing in as anyone without a provider is on (`zemi --shared --local-sign-in`, or `ZEMI_LOCAL_SIGN_IN=1`)."
const LOCAL_SIGN_IN = Ref(false)
"The provider a local sign-in is recorded under."
const LOCAL_PROVIDER = "This machine"

"""
    local_sign_in_problem(shared) -> String

Why the local sign-in cannot be on for this service, or `""`: it serves `localhost` only, its
`base_url` and the address it listens on both, so nobody but this machine's users can reach it.
"""
function local_sign_in_problem(shared::SharedConfig)
    host = lowercase(something(HTTP.URI(shared.base_url).host, ""))
    host in ("localhost", "127.0.0.1", "::1", "[::1]") || return "[shared] base_url is $(shared.base_url), not on localhost"
    shared.host in ("127.0.0.1", "::1", "localhost") || return "[shared] host is $(shared.host), not this machine only"
    return ""
end

"Whether a local sign-in is on and allowed for this service (see [`local_sign_in_problem`](@ref))."
local_sign_in(shared::SharedConfig) = LOCAL_SIGN_IN[] && isempty(local_sign_in_problem(shared))

"""
    direct_local(req) -> Bool

Whether request `req` was made on this machine to its own address, with no proxy between: a proxy
(such as one serving the service under a public name) says whom it forwards for, and names the host
it was asked for. A local sign-in is taken only so, whatever the config says.
"""
function direct_local(req::HTTP.Request)
    any(h -> HTTP.hasheader(req, h), ("X-Forwarded-For", "X-Forwarded-Host", "Forwarded", "Via")) && return false
    host = replace(lowercase(HTTP.header(req, "Host", "")), r":\d+$" => "")
    return host in ("localhost", "127.0.0.1", "[::1]")
end

"""
    finish_local_sign_in(kb, shared, form) -> (; user_id, return_to)

Sign in as the person `form` names (`email`, `name`) without a provider: as anyone invited, or an
admin, as a provider's sign-in would, and with no admin named, the first to sign in as one. Only with
the local sign-in on (see [`local_sign_in`](@ref)).
"""
function finish_local_sign_in(kb::KB, shared::SharedConfig, form::AbstractDict)
    local_sign_in(shared) || error("Signing in without a provider is off")
    email = lowercase(strip(get(form, "email", "")))
    occursin(r"^[^@\s]+@[^@\s]+$", email) || error("Give an email address")
    # With no admin named, the first person to sign in is one, so the service can be tried at all.
    if isempty(shared.admins) && scalar(kb, "SELECT count(*) FROM users") == 0
        shared = SharedConfig(; (f => getfield(shared, f) for f in fieldnames(SharedConfig) if f != :admins)..., admins = [email])
    end
    uid = sign_in!(kb, shared, LOCAL_PROVIDER, email; email, verified = true, name = strip(get(form, "name", "")))
    return (; user_id = uid, return_to = safe_return(get(form, "return_to", "/")))
end
