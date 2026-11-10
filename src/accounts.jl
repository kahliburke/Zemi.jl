# People and what they may do, for the shared service (`zemi --shared`): accounts, the sign-ins
# linked to them, roles (named sets of permissions, with daily quotas for agent work), invitations,
# sessions, personal API tokens and an audit log. Run for one person (`zemi`), the knowledge base
# has no accounts: every request comes from `LOCAL_CALLER`, who may do everything.

"""
Every permission, with what it allows. API routes and MCP tools each need one (see
`route!` in routes.jl).
"""
const PERMISSIONS = [
    "read" => "Read the pages, search, and see papers and notebooks",
    "tutor" => "Discuss papers with the tutor",
    "notebook.create" => "Have an agent make a notebook from a paper",
    "notebook.upload" => "Attach notebooks to papers",
    "paper.add" => "Add papers by arXiv id and upload PDFs",
    "paper.manage" => "Re-read, re-summarize, classify and remove papers",
    "records.purge" => "Remove every record a source made",
    "sync" => "Run syncs and publish the dataset",
    "daily" => "Pick and analyse the paper of the day",
    "watch" => "Check arXiv for new papers",
    "jobs.view" => "See jobs and their progress",
    "jobs.control" => "Cancel jobs",
    "agents.view" => "See the agents at work and what they cost",
    "agents.control" => "Interrupt and close agents",
    "server.view" => "See the service's health and metrics",
    "server.control" => "Rebuild the site, reload the configuration",
    "config.view" => "See the configuration",
    "config.edit" => "Change the configuration",
    "users.manage" => "Invite people, give them roles, disable accounts",
    "tokens.manage" => "See and revoke everyone's tokens, and issue dataset keys",
    "audit.view" => "Read the audit log",
    "tasks.view" => "See projects, milestones and tasks",
    "tasks.edit" => "Plan and change tasks, and approve agents' plans",
    "projects.all" => "Reach every project, not only those one is a member of",
    "projects.create" => "Create projects",
]
const PERMISSION_NAMES = first.(PERMISSIONS)

"The permissions by what they concern, each in one group, as the forms that choose them show them."
const PERMISSION_GROUPS = [
    "Reading" => ["read"],
    "Projects and tasks" => ["tasks.view", "tasks.edit", "projects.create", "projects.all"],
    "Tutor and notebooks" => ["tutor", "notebook.create", "notebook.upload"],
    "Documents" => ["paper.add", "paper.manage", "records.purge", "sync", "daily", "watch"],
    "The service" => ["jobs.view", "jobs.control", "agents.view", "agents.control", "server.view", "server.control",
                      "config.view", "config.edit"],
    "People" => ["users.manage", "tokens.manage", "audit.view"],
]

"[`PERMISSION_GROUPS`](@ref) for the pages: each group's name and its permissions, each with what it allows."
permission_groups_json() = [Dict("name" => g, "permissions" => [Dict("name" => p, "description" => Dict(PERMISSIONS)[p]) for p in ps])
                            for (g, ps) in PERMISSION_GROUPS]

"""
The roles a new shared service starts with: name, description, permissions, and daily quotas for
agent work (`tutor`: tutor turns, `notebook`: notebooks made; a quota not named is unlimited).
Admins can change them, and add others.
"""
const DEFAULT_ROLES = [
    (name = "Reader", description = "Reads and searches the knowledge base",
     permissions = ["read", "tasks.view"], quotas = Dict("tutor" => 0, "notebook" => 0)),
    (name = "Learner", description = "Reads, discusses papers with the tutor and makes notebooks",
     permissions = ["read", "tutor", "notebook.create", "tasks.view", "tasks.edit", "projects.create"],
     quotas = Dict("tutor" => 60, "notebook" => 3)),
    (name = "Curator", description = "Looks after the papers and the service's work",
     permissions = ["read", "tutor", "notebook.create", "notebook.upload", "paper.add", "paper.manage", "sync", "daily",
                    "watch", "jobs.view", "agents.view", "server.view", "config.view", "tasks.view", "tasks.edit", "projects.create"],
     quotas = Dict("tutor" => 200, "notebook" => 10)),
    (name = "Admin", description = "Runs the service: its configuration, people and tokens",
     permissions = PERMISSION_NAMES, quotas = Dict{String,Int}()),
]

"""
Who a request comes from and what they may do: a person signed in (`via` `:session`), a person's
API token (`:token`, with the token's permissions, never more than the person's), nobody signed in
(`:anonymous`, no permissions), or, outside shared mode, whoever runs the knowledge base (`:local`,
every permission). A token made for some projects only reaches those (`projects`; `nothing` for
whatever its person reaches, see project_access.jl). An admin viewing the service as someone else
(see [`view_as!`](@ref)) is that person, with `admin` the admin's account.
"""
struct Caller
    user_id::Union{Int,Nothing}
    name::String
    email::String
    permissions::Set{String}
    via::Symbol
    token_id::Union{Int,Nothing}
    projects::Union{Set{String},Nothing}
    admin::Union{Int,Nothing}
end
Caller(user_id, name, email, permissions, via, token_id) = Caller(user_id, name, email, permissions, via, token_id, nothing, nothing)
Caller(user_id, name, email, permissions, via, token_id, projects) = Caller(user_id, name, email, permissions, via, token_id, projects, nothing)

const ANONYMOUS = Caller(nothing, "", "", Set{String}(), :anonymous, nothing)
local_caller() = Caller(nothing, something(local_user(), "this machine"), "", Set(PERMISSION_NAMES), :local, nothing)

"Whether `caller` may do what `permission` allows."
can(c::Caller, permission::AbstractString) = permission in c.permissions

"The name additions are recorded under: the person's, or whoever runs the knowledge base."
caller_name(c::Caller) = isempty(c.name) ? something(local_user(), "") : c.name

"How tasks are assigned and questions addressed to `c`: their email in the shared service, else their name."
person_id(c::Caller) = c.via == :local ? caller_name(c) : c.email

"""
    ensure_roles!(kb)

Create the default roles a shared service has not got yet. Roles already there, and changes made
to them, are left alone.
"""

function ensure_roles!(kb::KB)
    for r in DEFAULT_ROLES
        execute!(kb, "INSERT OR IGNORE INTO roles (name, description, permissions, quotas) VALUES (?, ?, ?, ?)",
                 (r.name, r.description, JSON.json(r.permissions), JSON.json(r.quotas)))
    end
end

"The roles there are, with their permissions and quotas."
roles(kb::KB) = [(; name = r.name, description = r.description, permissions = String.(JSON.parse(r.permissions)),
                    quotas = Dict{String,Int}(JSON.parse(r.quotas)))
                 for r in query(kb, "SELECT * FROM roles ORDER BY name")]

"""
    keeping_an_admin(f, kb; by = nothing)

Make the changes `f` makes to accounts and roles, unless they would take away the last active person
who may manage people (`users.manage`), or take it away from `by`, the account making them: then none
of them are made. Nobody can lock everyone out, and nobody can demote themselves, by a role taken
away, an account disabled, or a role changed or removed.
"""
function keeping_an_admin(f, kb::KB; by = nothing)
    admins() = scalar(kb, """SELECT count(DISTINCT u.id) FROM users u JOIN user_roles ur ON ur.user_id = u.id
                             JOIN roles r ON r.name = ur.role WHERE u.disabled = 0 AND r.permissions LIKE '%"users.manage"%'""")
    transaction(kb) do
        before = admins()
        manages = by !== nothing && "users.manage" in user_permissions(kb, by)
        f()
        before > 0 && admins() == 0 && error("Would leave no admin.")
        manages && !("users.manage" in user_permissions(kb, by)) &&
            error("Can't remove your own admin rights.")
    end
end

"""
    save_role!(kb, name; description, permissions, quotas)

Create or change a role. Unknown permissions are refused, and Admin keeps every permission.
"""
function save_role!(kb::KB, name::AbstractString; description::AbstractString = "", permissions, quotas = Dict{String,Int}(), by = nothing)
    unknown = setdiff(permissions, PERMISSION_NAMES)
    isempty(unknown) || error("No such permission: $(join(unknown, ", "))")
    isempty(strip(name)) && error("A role needs a name")
    strip(name) == "Admin" && Set(permissions) != Set(PERMISSION_NAMES) && error("The Admin role keeps every permission")
    keeping_an_admin(kb; by) do
        execute!(kb, """INSERT INTO roles (name, description, permissions, quotas) VALUES (?, ?, ?, ?)
                        ON CONFLICT (name) DO UPDATE SET description = excluded.description, permissions = excluded.permissions,
                            quotas = excluded.quotas""",
                 (strip(name), description, JSON.json(unique(permissions)), JSON.json(quotas)))
    end
end

"Remove a role; people keep their other roles."
function delete_role!(kb::KB, name::AbstractString; by = nothing)
    name == "Admin" && error("The Admin role cannot be removed")
    keeping_an_admin(() -> execute!(kb, "DELETE FROM roles WHERE name = ?", (name,)), kb; by)
end

"The roles person `uid` has."
user_roles(kb::KB, uid::Integer) = [String(r.role) for r in query(kb, "SELECT role FROM user_roles WHERE user_id = ? ORDER BY role", (uid,))]

"Everything person `uid`'s roles allow; the Admin role, every permission there is, those added since it was saved too."
function user_permissions(kb::KB, uid::Integer)
    out = Set{String}()
    for r in query(kb, "SELECT r.name, r.permissions FROM roles r JOIN user_roles u ON u.role = r.name WHERE u.user_id = ?", (uid,))
        union!(out, r.name == "Admin" ? PERMISSION_NAMES : JSON.parse(r.permissions))
    end
    return out
end

"Give person `uid` exactly `roles`, as account `by` (see [`keeping_an_admin`](@ref))."
function set_roles!(kb::KB, uid::Integer, roles; by = nothing)
    known = Set(r.name for r in query(kb, "SELECT name FROM roles"))
    unknown = setdiff(roles, known)
    isempty(unknown) || error("No such role: $(join(unknown, ", "))")
    keeping_an_admin(kb; by) do
        execute!(kb, "DELETE FROM user_roles WHERE user_id = ?", (uid,))
        foreach(r -> execute!(kb, "INSERT INTO user_roles (user_id, role) VALUES (?, ?)", (uid, r)), unique(roles))
    end
end

"The accounts, with their roles and sign-ins."
function users(kb::KB)
    return [(; id = u.id, email = u.email, name = u.name, created_at = u.created_at, last_seen = coalesce(u.last_seen, ""),
               disabled = u.disabled == 1, roles = user_roles(kb, u.id),
               sign_ins = [String(i.provider) for i in query(kb, "SELECT provider FROM identities WHERE user_id = ?", (u.id,))])
            for u in query(kb, "SELECT * FROM users ORDER BY email")]
end

"""
    set_name!(kb, uid, name)

Set the name person `uid` is shown by. A provider's sign-in fills in a name only where there is none,
so this one stays.
"""
function set_name!(kb::KB, uid::Integer, name::AbstractString)
    name = strip(name)
    isempty(name) && error("A name can't be empty")
    length(name) <= 100 || error("A name is at most 100 characters")
    execute!(kb, "UPDATE users SET name = ? WHERE id = ?", (name, uid))
end

"Disable (or enable again) person `uid`'s account; a disabled account's sessions end."
function set_disabled!(kb::KB, uid::Integer, disabled::Bool)
    keeping_an_admin(kb) do
        execute!(kb, "UPDATE users SET disabled = ? WHERE id = ?", (Int(disabled), uid))
        disabled && execute!(kb, "DELETE FROM sessions WHERE user_id = ?", (uid,))
    end
end

"""
    invite!(kb, email; roles, projects = Dict(), by = nothing)

Invite `email` with `roles`: the first sign-in whose verified email it is gets an account with them,
and joins `projects`, project keys each with the role there (see project_access.jl).
"""
function invite!(kb::KB, email::AbstractString; roles, projects = Dict{String,String}(), by = nothing)
    occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email) || error("Not an email address: $email")
    known = Set(r.name for r in query(kb, "SELECT name FROM roles"))
    unknown = setdiff(roles, known)
    isempty(unknown) || error("No such role: $(join(unknown, ", "))")
    joins = Dict(uppercase(strip(String(k))) => lowercase(strip(String(v))) for (k, v) in projects)
    for (k, role) in joins
        ismissing(scalar(kb, "SELECT 1 FROM projects WHERE key = ?", (k,))) && not_found("No project $k")
        role in PROJECT_ROLES || error("A member is a $(join(PROJECT_ROLES, ", ", " or ")): $role")
    end
    execute!(kb, """INSERT INTO invitations (email, roles, invited_by, created_at, projects) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (email) DO UPDATE SET roles = excluded.roles, invited_by = excluded.invited_by,
                        created_at = excluded.created_at, accepted_at = NULL, projects = excluded.projects""",
             (lowercase(strip(email)), JSON.json(unique(roles)), something(by, missing), now_iso(), JSON.json(joins)))
end

"The invitations, open and accepted."
invitations(kb::KB) = [(; email = r.email, roles = String.(JSON.parse(r.roles)), projects = Dict{String,String}(JSON.parse(r.projects)),
                          created_at = r.created_at, accepted_at = coalesce(r.accepted_at, ""))
                       for r in query(kb, "SELECT * FROM invitations ORDER BY created_at DESC")]

"Withdraw an invitation not yet accepted."
uninvite!(kb::KB, email::AbstractString) = execute!(kb, "DELETE FROM invitations WHERE email = ? AND accepted_at IS NULL", (email,))

"""
    sign_in!(kb, shared, provider, subject; email, verified, name) -> Int

The account a sign-in (`subject` at `provider`) belongs to, its id. A sign-in seen before is its
account's. A new one joins the account with its verified email, or, with no account yet, makes one:
for an email in `shared.admins` (as an Admin), one invited (with the invitation's roles), or anyone
when sign-up is open (with `shared.default_role`). Errors otherwise, and for a disabled account.
An email in `shared.admins` is given the Admin role back whenever it signs in.
"""
function sign_in!(kb::KB, shared::SharedConfig, provider::AbstractString, subject::AbstractString;
                  email::AbstractString = "", verified::Bool = false, name::AbstractString = "")
    email = lowercase(strip(email))
    uid = transaction(kb) do
        known = scalar(kb, "SELECT user_id FROM identities WHERE provider = ? AND subject = ?", (provider, subject))
        ismissing(known) || return Int(known)
        (verified && !isempty(email)) || error("$provider gave no verified email.")
        existing = scalar(kb, "SELECT id FROM users WHERE email = ?", (email,))
        id = if !ismissing(existing)
            Int(existing)
        else
            invitation = query(kb, "SELECT roles, projects FROM invitations WHERE email = ? AND accepted_at IS NULL", (email,))
            roles = email in shared.admins ? ["Admin"] :
                    !isempty(invitation) ? String.(JSON.parse(first(invitation).roles)) :
                    shared.sign_up == :open ? [shared.default_role] :
                    error("Not invited: $email.")
            execute!(kb, "INSERT INTO users (email, name, created_at) VALUES (?, ?, ?)", (email, name, now_iso()))
            new = Int(scalar(kb, "SELECT id FROM users WHERE email = ?", (email,)))
            foreach(r -> execute!(kb, "INSERT OR IGNORE INTO user_roles (user_id, role) VALUES (?, ?)", (new, r)), roles)
            # The projects the invitation names, joined now (one since removed is passed over).
            isempty(invitation) || for (k, role) in JSON.parse(first(invitation).projects)
                ismissing(scalar(kb, "SELECT 1 FROM projects WHERE key = ?", (k,))) || set_member!(kb, k, new, role; by = "invitation")
            end
            execute!(kb, "UPDATE invitations SET accepted_at = ? WHERE email = ?", (now_iso(), email))
            new
        end
        execute!(kb, "INSERT INTO identities (provider, subject, user_id, email, created_at) VALUES (?, ?, ?, ?, ?)",
                 (provider, subject, id, email, now_iso()))
        id
    end
    u = first(query(kb, "SELECT * FROM users WHERE id = ?", (uid,)))
    u.disabled == 1 && error("Account disabled.")
    # An email the config names as an admin is one, whatever has been changed since: the way back in.
    lowercase(u.email) in shared.admins && execute!(kb, "INSERT OR IGNORE INTO user_roles (user_id, role) VALUES (?, 'Admin')", (uid,))
    isempty(name) || isempty(u.name) && execute!(kb, "UPDATE users SET name = ? WHERE id = ?", (name, uid))
    return uid
end

# ── Secrets: sessions and tokens ──────────────────────────────────────────────────────────────────
# Both are 256 random bits, given once and stored only as their SHA-256.

const SECRET_RNG = Random.RandomDevice()
new_secret() = rstrip(replace(base64encode(rand(SECRET_RNG, UInt8, 32)), '+' => '-', '/' => '_'), '=')
secret_hash(s::AbstractString) = bytes2hex(sha256(s))

"""
    start_session!(kb, uid, shared; agent = "") -> String

A new session for person `uid`, lasting `shared.session_days`: the secret for its cookie.
"""
function start_session!(kb::KB, uid::Integer, shared::SharedConfig; agent::AbstractString = "")
    s = new_secret()
    execute!(kb, "INSERT INTO sessions (token_hash, user_id, created_at, expires_at, last_seen, agent) VALUES (?, ?, ?, ?, ?, ?)",
             (secret_hash(s), uid, now_iso(), iso_in(Day(shared.session_days)), now_iso(), first(agent, 300)))
    execute!(kb, "UPDATE users SET last_seen = ? WHERE id = ?", (now_iso(), uid))
    return s
end

end_session!(kb::KB, secret::AbstractString) = execute!(kb, "DELETE FROM sessions WHERE token_hash = ?", (secret_hash(secret),))

function account_caller(kb::KB, uid::Integer, via::Symbol; token_id = nothing, only = nothing, projects = nothing, admin = nothing)
    u = first(query(kb, "SELECT * FROM users WHERE id = ?", (uid,)))
    u.disabled == 1 && return ANONYMOUS
    perms = user_permissions(kb, uid)
    only === nothing || intersect!(perms, only)
    return Caller(uid, u.name, u.email, perms, via, token_id, projects, admin)
end

"""
    session_caller(kb, secret) -> Caller

Who a session cookie's secret belongs to, or `ANONYMOUS` for one unknown, expired or of a disabled
account. A session in use is kept alive.
"""
function session_caller(kb::KB, secret::AbstractString)
    isempty(secret) && return ANONYMOUS
    h = secret_hash(secret)
    r = query(kb, "SELECT user_id, expires_at, last_seen, acting_as FROM sessions WHERE token_hash = ?", (h,))
    isempty(r) && return ANONYMOUS
    s = first(r)
    if s.expires_at < now_iso()
        end_session!(kb, secret)
        return ANONYMOUS
    end
    seen_now(s.last_seen) && execute!(kb, "UPDATE sessions SET last_seen = ? WHERE token_hash = ?", (now_iso(), h))
    ismissing(s.acting_as) || return account_caller(kb, s.acting_as, :session; admin = Int(s.user_id))
    return account_caller(kb, s.user_id, :session)
end

"""
Whether a session's or token's use is to be written down now: when it was last written (`last`) is
over a minute ago. A page asks every few seconds, and each write waits its turn for the database.
"""
seen_now(last) = coalesce(last, "") < iso_in(Minute(-1))

"""
    create_token!(kb, uid; name, permissions = nothing, projects = nothing, days = 90) -> (; id, token)

A personal API token for person `uid`: its id, and the token, which is shown only now. It can do
what `permissions` names (all the person may, when `nothing`), and never more than the person may
at the time it is used. `projects`, project keys, limits it to those (within the person's own; all
of the person's when `nothing`). `days` 0 means it does not expire.
"""
function create_token!(kb::KB, uid::Integer; name::AbstractString, permissions = nothing, projects = nothing, days::Integer = 90)
    isempty(strip(name)) && error("A token needs a name")
    perms = permissions === nothing ? collect(user_permissions(kb, uid)) : unique(String.(permissions))
    unknown = setdiff(perms, PERMISSION_NAMES)
    isempty(unknown) || error("No such permission: $(join(unknown, ", "))")
    keys = projects === nothing ? missing : JSON.json(unique(uppercase.(strip.(String.(projects)))))
    if projects !== nothing
        isempty(projects) && error("A token for no projects reaches nothing: name some, or none for all of yours")
        for k in JSON.parse(keys)
            ismissing(scalar(kb, "SELECT 1 FROM projects WHERE key = ?", (k,))) && not_found("No project $k")
        end
    end
    token = "zemi_" * new_secret()
    execute!(kb, """INSERT INTO api_tokens (user_id, name, token_hash, prefix, permissions, created_at, expires_at, projects)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
             (uid, strip(name), secret_hash(token), first(token, 10), JSON.json(perms), now_iso(),
              days > 0 ? iso_in(Day(days)) : missing, keys))
    return (; id = Int(scalar(kb, "SELECT id FROM api_tokens WHERE token_hash = ?", (secret_hash(token),))), token)
end

"""
    token_caller(kb, token; mcp = false) -> Caller

Who an API token acts for, with its permissions as far as its owner still has them, or `ANONYMOUS`
for a token unknown, revoked or expired. A token is known by its hash alone, whatever its prefix, so
those issued by earlier versions still work. A token an MCP client got by OAuth acts only at `/mcp`
(`mcp`), for its tools.
"""
function token_caller(kb::KB, token::AbstractString; mcp::Bool = false)
    isempty(token) && return ANONYMOUS
    r = query(kb, "SELECT * FROM api_tokens WHERE token_hash = ?", (secret_hash(token),))
    isempty(r) && return ANONYMOUS
    t = first(r)
    (ismissing(t.revoked_at) && (ismissing(t.expires_at) || t.expires_at > now_iso())) || return ANONYMOUS
    # A token an MCP client got by OAuth is for /mcp: its tools, not the whole API.
    mcp || ismissing(t.client_id) || return ANONYMOUS
    seen_now(t.last_used) && execute!(kb, "UPDATE api_tokens SET last_used = ? WHERE id = ?", (now_iso(), t.id))
    return account_caller(kb, t.user_id, :token; token_id = Int(t.id), only = Set(JSON.parse(t.permissions)),
                          projects = ismissing(t.projects) ? nothing : Set{String}(JSON.parse(t.projects)))
end

"The tokens of person `uid`, or everyone's: never the tokens themselves, only what identifies them."
function tokens(kb::KB; uid = nothing)
    rows = uid === nothing ? query(kb, "SELECT t.*, u.email FROM api_tokens t JOIN users u ON u.id = t.user_id ORDER BY t.created_at DESC") :
           query(kb, "SELECT t.*, u.email FROM api_tokens t JOIN users u ON u.id = t.user_id WHERE t.user_id = ? ORDER BY t.created_at DESC", (uid,))
    return [(; id = t.id, user_id = t.user_id, email = t.email, name = t.name, prefix = t.prefix,
               permissions = String.(JSON.parse(t.permissions)), projects = ismissing(t.projects) ? nothing : String.(JSON.parse(t.projects)),
               created_at = t.created_at,
               expires_at = coalesce(t.expires_at, ""), last_used = coalesce(t.last_used, ""), revoked = !ismissing(t.revoked_at))
            for t in rows]
end

"Revoke token `id`; `uid`, given, must own it."
function revoke_token!(kb::KB, id::Integer; uid = nothing)
    owner = scalar(kb, "SELECT user_id FROM api_tokens WHERE id = ?", (id,))
    ismissing(owner) && not_found("No token $id")
    uid === nothing || owner == uid || error("That token is not yours")
    execute!(kb, "UPDATE api_tokens SET revoked_at = coalesce(revoked_at, ?) WHERE id = ?", (now_iso(), id))
end

# ── Quotas and the audit log ──────────────────────────────────────────────────────────────────────

"""
    quota_left(kb, caller, kind) -> Union{Int,Nothing}

How many more of `kind` ("tutor", "notebook") `caller` may start today: the most any of their roles
allows less what they have used, or `nothing` for no limit (any role without one, or no account).
"""
function quota_left(kb::KB, c::Caller, kind::AbstractString)
    c.user_id === nothing && return nothing
    limits = [get(JSON.parse(r.quotas), kind, nothing)
              for r in query(kb, "SELECT r.quotas FROM roles r JOIN user_roles u ON u.role = r.name WHERE u.user_id = ?", (c.user_id,))]
    (isempty(limits) || any(isnothing, limits)) && return nothing
    used = coalesce(scalar(kb, "SELECT n FROM usage WHERE user_id = ? AND day = ? AND kind = ?", (c.user_id, utc_today(), kind)), 0)
    return max(0, maximum(limits) - used)
end

"""
    spend!(kb, caller, kind)

Count one `kind` of agent work against `caller`'s quota for today, or error if none is left.
"""
function spend!(kb::KB, c::Caller, kind::AbstractString)
    left = quota_left(kb, c, kind)
    left === nothing || left > 0 || error("Daily $kind limit reached (resets 00:00 UTC).")
    c.user_id === nothing && return
    execute!(kb, """INSERT INTO usage (user_id, day, kind, n) VALUES (?, ?, ?, 1)
                    ON CONFLICT (user_id, day, kind) DO UPDATE SET n = n + 1""", (c.user_id, utc_today(), kind))
end

"""
    audit!(kb, caller, action; target = "", detail = Dict())

Record that `caller` did `action` (to `target`), in the audit log.
"""
function audit!(kb::KB, c::Caller, action::AbstractString; target::AbstractString = "", detail = Dict{String,Any}())
    who = c.via == :local ? caller_name(c) : isempty(c.email) ? "anonymous" : c.email
    # An admin viewing the service as someone: theirs, as that person.
    c.admin === nothing || (who = "$(coalesce(scalar(kb, "SELECT email FROM users WHERE id = ?", (c.admin,)), "admin")) as $who")
    execute!(kb, "INSERT INTO audit (at, user_id, who, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)",
             (now_iso(), something(c.user_id, missing), who, action, target, JSON.json(detail)))
end

"The latest `limit` entries of the audit log, newest first."
audit_log(kb::KB; limit::Integer = 200, before = nothing) =
    [(; id = r.id, at = r.at, who = r.who, action = r.action, target = r.target, detail = JSON.parse(r.detail))
     for r in query(kb, "SELECT * FROM audit WHERE id < ? ORDER BY id DESC LIMIT ?", (something(before, typemax(Int)), limit))]

# ── Viewing the service as someone else ────────────────────────────────────────────────────────────

"""
    view_as!(kb, secret, who; caller)

Make session `secret` view the service as account `who` (its id), with that person's roles and
projects, or as its own account again with `who` `nothing`. Starting needs `users.manage` (of the
admin, also while already viewing as someone); going back is always allowed.
"""
function view_as!(kb::KB, secret::AbstractString, who; caller::Caller)
    admin = something(caller.admin, caller.user_id)
    admin === nothing && error("Viewing as someone needs an account")
    if who !== nothing
        "users.manage" in user_permissions(kb, admin) || not_permitted("Not permitted: viewing as someone needs users.manage")
        ismissing(scalar(kb, "SELECT 1 FROM users WHERE id = ?", (who,))) && not_found("No account $who")
    end
    target = who === nothing || who == admin ? missing : who
    execute!(kb, "UPDATE sessions SET acting_as = ? WHERE token_hash = ?", (target, secret_hash(secret)))
    return nothing
end

"""
    add_test_account!(kb, name; roles) -> Int

An account no one signs in to, named `name` with `roles`, for viewing the service as (see
[`view_as!`](@ref)): its email is `<name>@example.test`. Returns its id.
"""
function add_test_account!(kb::KB, name::AbstractString; roles)
    slug = strip(replace(lowercase(strip(name)), r"[^a-z0-9]+" => "-"), '-')
    isempty(slug) && error("A test account needs a name")
    email = "$slug@example.test"
    ismissing(scalar(kb, "SELECT 1 FROM users WHERE email = ?", (email,))) || error("There is already an account $email")
    execute!(kb, "INSERT INTO users (email, name, created_at) VALUES (?, ?, ?)", (email, strip(name), now_iso()))
    uid = Int(scalar(kb, "SELECT id FROM users WHERE email = ?", (email,)))
    set_roles!(kb, uid, roles)
    return uid
end
