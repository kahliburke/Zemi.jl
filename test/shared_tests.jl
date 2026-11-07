# The shared service: accounts, roles, sessions, tokens, quotas and the audit log, and signing in
# through an OIDC provider and GitHub, both played by a stand-in served here.

shared_config(; kw...) = K.SharedConfig(; base_url = "http://127.0.0.1:8800", admins = ["boss@example.org"], kw...)

@zset "accounts" begin
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    @test Set(r.name for r in K.roles(kb)) == Set(["Reader", "Learner", "Curator", "Admin"])
    # Attaching a notebook, which the site build runs, is for curators, not learners.
    role(n) = only(filter(r -> r.name == n, K.roles(kb)))
    @test !("notebook.upload" in role("Learner").permissions) && "notebook.upload" in role("Curator").permissions
    sh = shared_config()

    # Invitation only: an admin named in the config, the invited, and nobody else.
    boss = K.sign_in!(kb, sh, "Campus", "u1"; email = "Boss@example.org", verified = true, name = "The Boss")
    @test K.user_roles(kb, boss) == ["Admin"] && K.user_permissions(kb, boss) == Set(K.PERMISSION_NAMES)
    @test_throws ErrorException K.sign_in!(kb, sh, "Campus", "u2"; email = "stranger@example.org", verified = true)
    K.invite!(kb, "student@example.org"; roles = ["Learner"], by = boss)
    student = K.sign_in!(kb, sh, "Campus", "u3"; email = "student@example.org", verified = true, name = "A Student")
    @test K.user_roles(kb, student) == ["Learner"] && only(K.invitations(kb)).accepted_at != ""
    @test K.sign_in!(kb, sh, "Campus", "u3") == student                       # the same sign-in, again
    # Work goes to people with accounts, by email or name, and to the agents; nobody else.
    @test K.assignee_id(kb, "A Student") == K.assignee_id(kb, "STUDENT@example.org") == "student@example.org"
    @test K.assignee_id(kb, "claude") == "agent:Claude" && K.assignee_id(kb, " ") == ""
    @test_throws "No one called aa" K.assignee_id(kb, "aa")
    # A second provider's sign-in with the same verified email joins the account; an unverified one does not.
    @test K.sign_in!(kb, sh, "GitHub", "g9"; email = "student@example.org", verified = true) == student
    @test_throws ErrorException K.sign_in!(kb, sh, "GitHub", "g10"; email = "student@example.org", verified = false)
    @test Set(only(filter(u -> u.id == student, K.users(kb))).sign_ins) == Set(["Campus", "GitHub"])
    # A name set here stays when a provider's sign-in brings another; an empty one is refused.
    K.set_name!(kb, student, "  Ada Lovelace ")
    K.sign_in!(kb, sh, "GitHub", "g9"; email = "student@example.org", verified = true, name = "ada-gh")
    @test only(filter(u -> u.id == student, K.users(kb))).name == "Ada Lovelace"
    @test_throws "can't be empty" K.set_name!(kb, student, " ")
    # Open sign-up gives the default role.
    open_sh = shared_config(sign_up = :open, default_role = "Reader")
    reader = K.sign_in!(kb, open_sh, "Campus", "u4"; email = "reader@example.org", verified = true)
    @test K.user_roles(kb, reader) == ["Reader"]
    @test_throws ErrorException K.invite!(kb, "not an email"; roles = ["Reader"])
    @test_throws ErrorException K.invite!(kb, "x@example.org"; roles = ["Nobody"])

    # Sessions: a secret for the cookie, which names the person until it ends or expires.
    s = K.start_session!(kb, student, sh)
    c = K.session_caller(kb, s)
    @test c.user_id == student && c.via == :session && K.can(c, "tutor") && !K.can(c, "paper.add")
    @test K.session_caller(kb, "made-up") === K.ANONYMOUS && !K.can(K.ANONYMOUS, "read")
    # Its use is written down at most once a minute, not on each request.
    seen() = K.scalar(kb, "SELECT last_seen FROM sessions WHERE token_hash = ?", (K.secret_hash(s),))
    recently = K.iso_in(K.Dates.Second(-30))
    K.execute!(kb, "UPDATE sessions SET last_seen = ?", (recently,))
    @test K.session_caller(kb, s).user_id == student && seen() == recently
    K.execute!(kb, "UPDATE sessions SET last_seen = ?", (K.iso_in(K.Dates.Minute(-2)),))
    K.session_caller(kb, s)
    @test seen() > recently
    K.execute!(kb, "UPDATE sessions SET expires_at = '2000-01-01T00:00:00Z'")
    @test K.session_caller(kb, s) === K.ANONYMOUS
    @test K.scalar(kb, "SELECT count(*) FROM sessions") == 0                   # an expired session is removed
    s = K.start_session!(kb, student, sh)
    K.set_disabled!(kb, student, true)
    @test K.session_caller(kb, s) === K.ANONYMOUS                              # a disabled account's sessions end
    @test_throws ErrorException K.sign_in!(kb, sh, "Campus", "u3")
    K.set_disabled!(kb, student, false)

    # Tokens: shown once, stored hashed, never wider than the person.
    t = K.create_token!(kb, student; name = "laptop", permissions = ["read", "tutor"])
    @test startswith(t.token, "zemi_") && K.scalar(kb, "SELECT count(*) FROM api_tokens WHERE token_hash = ?", (t.token,)) == 0
    c = K.token_caller(kb, t.token)
    @test c.via == :token && c.token_id == t.id && c.permissions == Set(["read", "tutor"])
    K.set_roles!(kb, student, ["Reader"])                                      # the person loses `tutor`, so does the token
    @test K.token_caller(kb, t.token).permissions == Set(["read"])
    K.set_roles!(kb, student, ["Learner"])
    @test only(K.tokens(kb; uid = student)).prefix == first(t.token, 10)
    @test_throws ErrorException K.revoke_token!(kb, t.id; uid = reader)        # not theirs
    K.revoke_token!(kb, t.id; uid = student)
    @test K.token_caller(kb, t.token) === K.ANONYMOUS && only(K.tokens(kb)).revoked
    @test_throws ErrorException K.create_token!(kb, student; name = "x", permissions = ["fly"])
    @test K.token_caller(kb, "zemi_unknown") === K.ANONYMOUS

    # Roles can be changed and added; Admin stays.
    K.save_role!(kb, "Visitor"; description = "Looks", permissions = ["read"], quotas = Dict("tutor" => 2))
    @test any(r -> r.name == "Visitor" && r.quotas["tutor"] == 2, K.roles(kb))
    @test_throws ErrorException K.save_role!(kb, "Bad"; permissions = ["read", "everything"])
    @test_throws ErrorException K.delete_role!(kb, "Admin")

    # Quotas: the most any role allows, by the day; none for a role without a limit.
    learner = K.session_caller(kb, K.start_session!(kb, student, sh))
    @test K.quota_left(kb, learner, "notebook") == 3
    foreach(_ -> K.spend!(kb, learner, "notebook"), 1:3)
    @test K.quota_left(kb, learner, "notebook") == 0 && (try K.spend!(kb, learner, "notebook"); false catch; true end)
    @test K.quota_left(kb, K.session_caller(kb, K.start_session!(kb, reader, open_sh)), "tutor") == 0
    @test K.quota_left(kb, K.session_caller(kb, K.start_session!(kb, boss, sh)), "tutor") === nothing
    @test K.quota_left(kb, K.local_caller(), "tutor") === nothing

    # The audit log.
    K.audit!(kb, learner, "token.create"; target = "laptop", detail = Dict("permissions" => ["read"]))
    e = first(K.audit_log(kb))
    @test e.who == "student@example.org" && e.action == "token.create" && e.detail["permissions"] == ["read"]
    close(kb)
end

@zset "signing in" begin
    HTTP, JSON = K.HTTP, K.JSON
    port = 19000 + rand(0:999)
    base = "http://127.0.0.1:$port"
    codes = Dict{String,Any}()          # code => what the provider was asked, as the browser would carry it
    unverified = Ref(false)             # the provider gives the email without saying whether it is verified
    bare_iss = Ref(false)               # the ID token names its issuer without the scheme
    secret_file = tempname(); write(secret_file, "s3cret\n")
    form(req) = Dict(HTTP.queryparams(String(req.body)))
    jsonr(x; status = 200) = HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(x))
    server = HTTP.serve!("127.0.0.1", port) do req
        path = HTTP.URI(req.target).path
        if path == "/.well-known/openid-configuration"
            jsonr(Dict("issuer" => base, "authorization_endpoint" => "$base/authorize", "token_endpoint" => "$base/token",
                       "userinfo_endpoint" => "$base/userinfo"))
        elseif path == "/token"
            f = form(req)
            c = get(codes, f["code"], nothing)
            c === nothing && return jsonr(Dict("error" => "invalid_grant"); status = 400)
            delete!(codes, f["code"])
            f["client_secret"] == "s3cret" || return jsonr(Dict("error" => "invalid_client"); status = 401)
            K.base64url(K.sha256(f["code_verifier"])) == c["code_challenge"] || return jsonr(Dict("error" => "invalid_grant"); status = 400)
            claims = Dict("iss" => bare_iss[] ? "127.0.0.1:$port" : base, "aud" => "kb-client", "exp" => time() + 300, "nonce" => get(c, "nonce_override", c["nonce"]),
                          "sub" => "cl-42", "name" => "Una Ames")
            jsonr(Dict("access_token" => "at", "id_token" => "e30." * K.base64url(Vector{UInt8}(JSON.json(claims))) * ".sig"))
        elseif path == "/userinfo"
            jsonr(unverified[] ? Dict("email" => "una@example.edu") : Dict("email" => "una@example.edu", "email_verified" => true))
        elseif path == "/gh/token"
            f = form(req)
            haskey(codes, f["code"]) ? (delete!(codes, f["code"]); jsonr(Dict("access_token" => "gh"))) : jsonr(Dict("error" => "bad_verification_code"))
        elseif path == "/gh/api/user"
            jsonr(Dict("id" => 7, "login" => "octo", "name" => nothing))
        elseif path == "/gh/api/user/emails"
            jsonr([Dict("email" => "octo@users.noreply.github.com", "primary" => false, "verified" => true),
                   Dict("email" => "una@example.edu", "primary" => true, "verified" => true)])
        else
            HTTP.Response(404)
        end
    end
    saved = K.GITHUB[]
    K.GITHUB[] = (authorize = "$base/gh/authorize", token = "$base/gh/token", api = "$base/gh/api")
    try
        sh = shared_config(providers = [
            K.Provider(name = "Campus Login", kind = :oidc, issuer = base, client_id = "kb-client", client_secret = "file:$secret_file"),
            K.Provider(name = "GitHub", kind = :github, client_id = "gh-client", client_secret = "file:$secret_file")])
        K.validate(Config(; shared = sh))
        @test_throws ErrorException K.validate(Config(; shared = shared_config(providers = [K.Provider(name = "X", kind = :oidc, client_id = "c")])))
        kb = open_kb(temp_config(shared = sh))
        K.ensure_roles!(kb)
        K.invite!(kb, "una@example.edu"; roles = ["Curator"])

        # The provider's side of the browser's round trip: it signs the person in and sends them back with a code.
        function visit(url; nonce_override = nothing)
            u = HTTP.URI(url)
            q = Dict(HTTP.queryparams(u))
            code = K.new_secret()
            codes[code] = nonce_override === nothing ? q : merge(q, Dict("nonce_override" => nonce_override))
            return (; q, back = Dict("code" => code, "state" => q["state"]))
        end

        # An email the provider does not say is verified signs nobody in, unless the config says the
        # provider's emails are its own records of people.
        unverified[] = true
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        @test_throws "no verified email" K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b1")
        unverified[] = false
        @test K.shared_config(Dict("providers" => [Dict("name" => "C", "email_verified" => true)])).providers[1].email_verified
        @test !K.shared_config(Dict("providers" => [Dict("name" => "C")])).providers[1].email_verified

        # Each sign-in is bound to the browser that starts it, by a secret in its cookie.
        url = K.begin_sign_in(sh, "campus-login"; return_to = "/generated/kb/papers/x", browser = "b1")
        v = visit(url)
        @test startswith(url, "$base/authorize?") && v.q["redirect_uri"] == "http://127.0.0.1:8800/auth/callback/campus-login"
        @test v.q["code_challenge_method"] == "S256" && v.q["scope"] == "openid email profile"
        r = K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b1")
        @test r.return_to == "/generated/kb/papers/x" && K.user_roles(kb, r.user_id) == ["Curator"]
        @test only(K.users(kb)).name == "Una Ames"
        @test_throws ErrorException K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b1")   # a state is used once
        # Another browser cannot finish it, so nobody is signed in as someone who started a sign-in.
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        @test_throws "another browser" K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b2")
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        @test_throws "another browser" K.finish_sign_in(kb, sh, "campus-login", v.back)

        # An ID token that does not answer this sign-in is refused.
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"); nonce_override = "another")
        @test_throws ErrorException K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b1")
        # A return address on another site is not followed, however it is spelled.
        for to in ("//evil.example", "/\t/evil.example", "/\\evil.example", "/ /evil.example")
            @test Dict(HTTP.queryparams(HTTP.URI(K.begin_sign_in(sh, "campus-login"; return_to = to)))) |> q ->
                  K.PENDING[q["state"]].return_to == "/"
        end
        @test_throws ErrorException K.finish_sign_in(kb, sh, "campus-login", Dict("error" => "access_denied"))

        # GitHub: its verified primary email finds the same account.
        v = visit(K.begin_sign_in(sh, "github"; browser = "b1"))
        @test startswith(K.begin_sign_in(sh, "github"), "$base/gh/authorize?") && v.q["scope"] == "read:user user:email"
        @test K.finish_sign_in(kb, sh, "github", v.back; browser = "b1").user_id == only(K.users(kb)).id
        @test Set(only(K.users(kb)).sign_ins) == Set(["Campus Login", "GitHub"])

        # An issuer named without its scheme (as Google does in some tokens) is the same issuer.
        bare_iss[] = true
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        @test K.finish_sign_in(kb, sh, "campus-login", v.back; browser = "b1").user_id == only(K.users(kb)).id
        bare_iss[] = false
        @test K.issued_by("accounts.google.com", "https://accounts.google.com")
        @test K.issued_by("https://accounts.google.com/", "https://accounts.google.com")
        @test !K.issued_by("evil.example/accounts.google.com", "https://accounts.google.com")
        @test !K.issued_by("http://accounts.google.com", "https://accounts.google.com")

        # Finishing from the address the provider sent the browser to, pasted in, in the same browser.
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        pasted = "https://kb.example.org/auth/callback/campus-login?" * HTTP.escapeuri(v.back)
        @test_throws "another browser" K.finish_pasted_sign_in(kb, sh, pasted; browser = "b2")
        v = visit(K.begin_sign_in(sh, "campus-login"; browser = "b1"))
        pasted = "https://kb.example.org/auth/callback/campus-login?" * HTTP.escapeuri(v.back)
        @test K.finish_pasted_sign_in(kb, sh, pasted; browser = "b1").user_id == only(K.users(kb)).id
        @test_throws ErrorException K.finish_pasted_sign_in(kb, sh, "https://kb.example.org/elsewhere?code=1")
        close(kb)
    finally
        K.GITHUB[] = saved
        close(server)
    end
end

@zset "privacy page" begin
    HTTP = K.HTTP
    sh = shared_config(providers = [K.Provider(name = "GitHub", kind = :github, client_id = "c"),
                                    K.Provider(name = "Google", issuer = "https://accounts.google.com", client_id = "g")])
    kb = open_kb(temp_config(; shared = sh, contact = "ada@example.org"))
    get(target) = K.respond_service(kb, HTTP.Request("GET", target); shared = true)
    # Shown to anyone, as providers link to it before anyone signs in; other pages still ask for one.
    r = get("/privacy")
    page = String(r.body)
    @test r.status == 200 && occursin("GitHub or Google", page) && occursin("mailto:ada@example.org", page)
    @test get("/").status == 302
    @test occursin("href=\"/privacy\"", K.sign_in_page(sh))
    close(kb)
    kb = open_kb(temp_config(; shared = sh))
    @test occursin("the group's admins", String(get("/privacy").body))
    close(kb)
end

@zset "permissions on the API" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    caller(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true);
                            K.set_roles!(kb, uid, roles); K.session_caller(kb, K.start_session!(kb, uid, sh)))
    reader, learner, other = caller("r@x.org", ["Reader"]), caller("l@x.org", ["Learner"]), caller("o@x.org", ["Learner"])
    call(c, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                             body === nothing ? UInt8[] : JSON.json(body)), c);
                                               (r.status, JSON.parse(String(r.body))))
    add_papers!(kb, ["2609.00001"])

    @test call(K.ANONYMOUS, "GET", "/api/status")[1] == 401
    s, me = call(reader, "GET", "/api/status")
    @test s == 200 && sort(me["me"]["permissions"]) == ["read", "tasks.view"] && me["me"]["quotas"]["tutor"] == 0
    # A reader sees the boards and changes nothing on them.
    @test call(reader, "GET", "/api/projects")[1] == 200
    @test call(reader, "POST", "/api/tasks", Dict("project" => "X", "title" => "t"))[1] == 403
    @test call(reader, "POST", "/api/tasks/X-1/delete", Dict())[1] == 403
    @test call(reader, "POST", "/api/documents", Dict("arxiv" => "2609.00002"))[1] == 403
    @test call(reader, "GET", "/api/documents")[1] == 403 && call(reader, "GET", "/api/jobs")[1] == 403
    # One job is its starter's to follow, which needs no more than reading.
    @test K.find_route("GET", ["api", "jobs", "j3"])[1].need == "read"
    @test call(K.local_caller(), "GET", "/api/documents")[1] == 200

    # Conversations are their owner's alone.
    for (id, owner) in (("cmine", learner.user_id), ("ctheirs", other.user_id))
        K.execute!(kb, "INSERT INTO chats (id, doc_id, title, started_at, updated_at, user_id) VALUES (?, '2609.00001', 't', 'x', 'x', ?)", (id, owner))
    end
    @test [c["id"] for c in call(learner, "GET", "/api/chats/2609.00001")[2]] == ["cmine"]
    @test call(learner, "GET", "/api/chat/ctheirs")[1] == 404 && call(learner, "GET", "/api/chat/ctheirs/files/x.svg")[1] == 404
    @test call(learner, "POST", "/api/chat", Dict("paper" => "2609.00001", "message" => "hi", "chat" => "ctheirs"))[1] == 404
    @test length(call(K.local_caller(), "GET", "/api/chats/2609.00001")[2]) == 2       # run for one person: all of them
    # A paper the knowledge base does not have is added only by someone who may add papers.
    for (route, field) in (("/api/chat", "paper"), ("/api/notebook", "id"))
        s, r = call(learner, "POST", route, Dict(field => "2609.09999", "message" => "hi"))
        @test s == 403 && occursin("paper.add", r["error"]) && ismissing(K.paper_id(kb, "2609.09999"))
    end

    # A quota spent is refused before any agent starts, and the log keeps what was done, not what was said.
    K.execute!(kb, "INSERT INTO usage (user_id, day, kind, n) VALUES (?, ?, 'tutor', 60)", (learner.user_id, K.utc_today()))
    s, r = call(learner, "POST", "/api/chat", Dict("paper" => "2609.00001", "message" => "a private question", "profile" => "secret"))
    @test s == 400 && occursin("limit", r["error"])
    e = first(K.audit_log(kb))
    @test e.action == "chat" && e.who == "l@x.org" && e.detail["paper"] == "2609.00001" && e.detail["status"] == 400
    @test !haskey(e.detail, "message") && !haskey(e.detail, "profile")
    # A board's presence and pen change nothing, so they are not in the log.
    @test call(reader, "POST", "/api/presence", Dict("mode" => "present"))[1] == 200
    call(reader, "POST", "/api/ink", Dict("project" => "", "stroke" => "s", "points" => "[]"))
    @test first(K.audit_log(kb)).action == "chat"
    close(kb)
end

@zset "project files" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    send(uid, method, target, body = UInt8[]) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"], body), as(uid));
                                                 (r.status, String(r.body)))
    post(uid, target, d) = send(uid, "POST", target, Vector{UInt8}(JSON.json(d)))
    boss, ada, bea = account("boss@example.org", ["Admin"]), account("ada@x.org", ["Curator"]), account("bea@x.org", ["Curator"])
    @test first(post(ada, "/api/projects", Dict("name" => "Ada's", "key" => "AA"))) == 200
    @test first(post(bea, "/api/projects", Dict("name" => "Bea's", "key" => "BB"))) == 200
    # A file attached in a project is that project's: its members have it, and to anyone else it is no file.
    status, body = send(ada, "POST", "/api/media?name=scan.png&project=AA", UInt8[1, 2, 3])
    address = JSON.parse(body)["address"]
    fetched(uid) = first(send(uid, "GET", "/api/" * address))
    @test status == 200 && fetched(ada) == 200 && fetched(boss) == 200 && fetched(bea) == 404
    @test first(send(bea, "POST", "/api/media?name=x.png&project=AA", UInt8[4])) == 404       # nor attached in it by others
    # Text in another project can't use it, unless its writer has the file: then it is that project's too.
    @test first(post(bea, "/api/tasks", Dict("project" => "BB", "title" => "Look", "body" => "![scan]($address)"))) == 403
    K.set_member!(kb, "BB", "ada@x.org", "contributor"; by = "bea@x.org")
    @test first(post(ada, "/api/tasks", Dict("project" => "BB", "title" => "Look", "body" => "![scan]($address)"))) == 200
    @test fetched(bea) == 200
    # A file attached in no project is its uploader's until text in a project uses it.
    _, loose = send(ada, "POST", "/api/media?name=draft.png", UInt8[9, 9])
    loose = JSON.parse(loose)["address"]
    @test first(send(ada, "GET", "/api/" * loose)) == 200 && first(send(bea, "GET", "/api/" * loose)) == 404
    # A paper's page shows the libraries of the projects the reader sees that hold it.
    add_papers!(kb, ["2609.00001"])
    @test first(post(bea, "/api/projects/AA/library", Dict("source" => "@[2609.00001](paper:2609.00001)"))) == 404
    status, body = post(ada, "/api/projects/AA/library", Dict("source" => "@[2609.00001](paper:2609.00001)", "why" => "Its method."))
    @test status == 200 && only(JSON.parse(body))["status"] == "kept"
    holding(uid) = Dict(p["key"] => p["library"] for p in JSON.parse(last(send(uid, "GET", "/api/projects?kind=paper&target=2609.00001")))["projects"])
    @test holding(ada)["AA"]["why"] == "Its method." && holding(ada)["BB"] === nothing
    @test !haskey(holding(bea), "AA")
    close(kb)
end

@zset "uploading a file from another machine" begin
    HTTP = K.HTTP
    kb = open_kb(temp_config())
    rowan, bot = K.person("Rowan"), K.agent("Claude for Rowan")
    K.create_project!(kb, "Edge"; key = "ED", by = rowan)
    t = K.create_task!(kb, "ED", "Plot the tide gauges"; by = rowan)
    put(token, bytes) = (r = K.respond_service(kb, HTTP.Request("PUT", "/api/media/upload/$token", [], bytes); shared = true);
                         (r.status, String(r.body)))
    png = UInt8[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]
    address = "media/$(bytes2hex(K.sha256(png)))/fig.png"
    # The link takes the file once, with no other credential, and answers with what to write.
    token = K.upload_link!(t, "ED"; name = "fig.png", caption = "The tide gauge", by = bot)
    status, said = put(token, png)
    @test status == 200 && occursin(address, said) && occursin("![The tide gauge]($address)", said)
    @test last(K.task(kb, t).activity).text == "The tide gauge\n\n![The tide gauge]($address)" && last(K.task(kb, t).activity).who == bot.name
    @test first(put(token, png)) == 404                                                        # used
    # For a finding, kept as the project's, not posted; the same bytes are kept once.
    status, said = put(K.upload_link!("ED-F1", "ED"; name = "fig.png", by = bot), png)
    @test status == 200 && occursin(address, said) && !occursin("Posted", said)
    @test K.scalar(kb, "SELECT count(*) FROM media") == 1
    # A link expires; a file of a type not kept here is refused when the link is asked for.
    late = K.upload_link!(t, "ED"; name = "data.csv", by = bot)
    lock(K.UPLOADS_LOCK) do
        u = K.UPLOADS[late]
        K.UPLOADS[late] = K.Upload(u.by, u.user, u.ref, u.project, u.name, u.caption, u.post, K.now(K.UTC) - K.Minute(1))
    end
    @test first(put(late, UInt8[1])) == 410
    @test_throws "a file here is one of" K.upload_link!(t, "ED"; name = "tool.exe", by = bot)
    @test K.respond_service(kb, HTTP.Request("GET", "/api/media/upload/$token"); shared = true).status == 405
    close(kb)
end

@zset "who is using the service" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    get_(uid, target) = (r = K.handle(kb, HTTP.Request("GET", target), as(uid)); (r.status, String(r.body)))
    empty!(K.PRESENCE)
    boss, ada, bea = account("boss@example.org", ["Admin"]), account("ada@x.org", ["Curator"]), account("bea@x.org", ["Reader"])
    @test K.activity().quiet && isempty(K.activity().people)
    # A page polling by itself is open; anything else its person asks for is them acting.
    get_(bea, "/api/status")
    a = K.activity()
    @test !a.quiet && only(a.people).open && !only(a.people).active
    get_(ada, "/api/projects")
    a = K.activity()
    @test first(a.people).email == "ada@x.org" && first(a.people).active && first(a.people).what == "GET /api/projects"
    # Later, both are idle: the service is quiet, and still lists them.
    later = K.now(K.UTC) + K.Minute(K.ACTIVE_MINUTES + 1)
    @test K.activity(; at = later).quiet && length(K.activity(; at = later).people) == 2
    # Agents' tool calls count, through MCP; what runs counts too.
    K.seen!(as(bea), "task_note", "MCP")
    @test occursin("task_note through the MCP", K.format_activity())
    K.doing!("chat-1", "")
    @test any(r -> occursin("tutor answering in conversation chat-1", r), K.activity(; at = later).running) && !K.activity(; at = later).quiet
    K.doing!("chat-1", nothing)
    # Those who look after the service see it on the operations page.
    status, body = get_(boss, "/api/ops")
    @test status == 200 && Set(p["email"] for p in JSON.parse(body)["activity"]["people"]) ⊇ Set(["ada@x.org", "bea@x.org"])
    @test first(get_(bea, "/api/ops")) == 403
    empty!(K.PRESENCE)
    close(kb)
end

@zset "a paper's PDF, where its text may be read" begin
    HTTP = K.HTTP
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    id = "doc-0123456789"
    K.execute!(kb, "INSERT INTO papers (doc_id, title, added_at) VALUES (?, 'Reef patches', ?)", (id, K.now_iso()))
    path = joinpath(K.pdf_dir(kb.config), K.pdf_filename(id, ""))
    write(path, "%PDF-1.4 reefs")
    K.execute!(kb, "INSERT INTO files VALUES (?, ?, 'x', 14, ?)", (K.paper_id(kb, id), path, K.now_iso()))
    rowan = K.sign_in!(kb, sh, "Campus", "r1"; email = "rowan@x.org", verified = true)
    K.set_roles!(kb, rowan, ["Learner"])
    status(c, target) = K.handle(kb, HTTP.Request("GET", target), c).status
    callers = [K.ANONYMOUS, K.session_caller(kb, K.start_session!(kb, rowan, sh)),
               K.token_caller(kb, K.create_token!(kb, rowan; name = "tutor only", permissions = ["tutor"]).token)]
    text = [status(c, "/api/paper-text?id=$id&section=1") for c in callers]
    @test text == [401, 200, 403]
    @test [status(c, "/api/pdf/$id") for c in callers] == text
    close(kb)
end

@zset "project access" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    call(uid, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                                body === nothing ? UInt8[] : JSON.json(body)), as(uid));
                                                  (r.status, JSON.parse(String(r.body))))
    boss, maker, other = account("boss@example.org", ["Admin"]), account("m@x.org", ["Curator"]), account("o@x.org", ["Curator"])
    reader = account("r@x.org", ["Reader"])

    # Those whose roles allow it create projects and own them; to anyone else a project is no project.
    @test call(reader, "POST", "/api/projects", Dict("name" => "Not mine", "key" => "NM"))[1] == 403
    @test call(maker, "POST", "/api/projects", Dict("name" => "Mine", "key" => "MN"))[1] == 200
    @test [(m.email, m.role) for m in K.members(kb, "MN")] == [("m@x.org", "maintainer")]
    @test call(other, "GET", "/api/projects/MN")[1] == 404
    @test !any(p -> p["key"] == "MN", call(other, "GET", "/api/projects")[2]["projects"])
    @test call(boss, "GET", "/api/projects/MN")[1] == 200                       # an admin reaches every project
    @test call(maker, "POST", "/api/tasks", Dict("project" => "MN", "title" => "Calibrate the probe"))[2]["ref"] == "MN-1"
    @test call(other, "POST", "/api/tasks", Dict("project" => "MN", "title" => "Sneak in"))[1] == 404
    @test call(other, "GET", "/api/tasks/MN-1")[1] == 404 && call(other, "POST", "/api/tasks/MN-1/notes", Dict("text" => "hi"))[1] == 404
    @test isempty(call(other, "GET", "/api/tasks/search?q=probe")[2])               # nor found by search
    @test !any(t -> t["ref"] == "MN-1", call(other, "GET", "/api/tasks/waiting")[2]["mine"])

    # Roles: a viewer looks, a contributor changes work, a maintainer manages the project; admins manage its members.
    K.set_member!(kb, "MN", "o@x.org", "viewer"; by = "m@x.org")
    @test call(other, "GET", "/api/tasks/MN-1")[1] == 200
    @test call(other, "POST", "/api/tasks/MN-1/notes", Dict("text" => "hi"))[1] == 403
    @test call(other, "POST", "/api/projects/MN/members", Dict("who" => "o@x.org", "role" => "contributor"))[1] == 403
    @test call(maker, "POST", "/api/projects/MN/members", Dict("who" => "o@x.org", "role" => "contributor"))[1] == 200   # its owner
    @test call(other, "POST", "/api/tasks/MN-1/notes", Dict("text" => "hi"))[1] == 200
    @test call(other, "POST", "/api/projects/MN", Dict("description" => "Ours"))[1] == 403
    @test call(maker, "GET", "/api/projects/MN/members")[2][1]["role"] == "maintainer"
    @test_throws "owner stays a maintainer" K.set_member!(kb, "MN", "m@x.org", "viewer")
    K.set_member!(kb, "MN", other, "maintainer")                                    # a maintainer, not its owner, does not
    @test call(other, "POST", "/api/projects/MN/members", Dict("who" => "r@x.org", "role" => "viewer"))[1] == 403
    @test call(boss, "POST", "/api/projects/MN/members", Dict("who" => "r@x.org", "role" => "viewer"))[1] == 200   # an admin does
    @test call(other, "POST", "/api/projects/MN/delete", Dict())[1] == 403
    @test call(maker, "GET", "/api/projects/MN")[2]["manages_members"] && !call(other, "GET", "/api/projects/MN")[2]["manages_members"]
    @test call(maker, "GET", "/api/tasks/people")[1] == 200 && call(other, "GET", "/api/tasks/people?project=MN")[1] == 200
    K.set_member!(kb, "MN", other, "contributor")
    @test call(maker, "POST", "/api/projects", Dict("name" => "Scratch", "key" => "SC"))[1] == 200
    @test call(maker, "POST", "/api/projects/SC/delete", Dict())[1] == 200 && call(maker, "GET", "/api/projects/SC")[1] == 404
    K.set_member!(kb, "MN", "r@x.org", "contributor")                            # without tasks.edit, a Reader still only looks
    @test K.project_access(kb, as(reader), "MN") == K.VIEW

    # Work goes to the project's people: members, those who reach every project, and the agents.
    @test Set(p.id for p in K.people(kb; project = "MN")) == Set(["boss@example.org", "m@x.org", "o@x.org", "r@x.org", K.AGENT_ASSIGNEE])
    K.create_project!(kb, "Other"; key = "OT", owner = boss, by = K.person("boss"))
    @test_throws "No one called o@x.org" K.create_task!(kb, "OT", "Theirs"; assignee = "o@x.org", by = K.person("boss"))

    # A token reaches its person's projects, and when made for some of them, only those.
    t = K.create_token!(kb, boss; name = "for MN", projects = ["mn"])
    @test K.project_access(kb, K.token_caller(kb, t.token), "MN") == K.MAINTAIN
    @test K.project_access(kb, K.token_caller(kb, t.token), "OT") == K.NO_ACCESS
    @test only(K.tokens(kb; uid = boss)).projects == ["MN"]
    @test K.project_access(kb, K.token_caller(kb, K.create_token!(kb, other; name = "all mine").token), "OT") == K.NO_ACCESS
    @test_throws "No project ZZ" K.create_token!(kb, boss; name = "bad", projects = ["ZZ"])

    # The board learns what one may do in a project; an invitation can name projects to join.
    @test call(maker, "GET", "/api/projects/MN")[2]["access"] == "maintainer" && call(other, "GET", "/api/projects/MN")[2]["access"] == "contributor"
    K.invite!(kb, "new@x.org"; roles = ["Curator"], projects = Dict("mn" => "contributor"))
    @test only(i for i in K.invitations(kb) if i.email == "new@x.org").projects == Dict("MN" => "contributor")
    newcomer = K.sign_in!(kb, sh, "Campus", "n1"; email = "new@x.org", verified = true)
    @test only(m.role for m in K.members(kb, "MN") if m.email == "new@x.org") == "contributor"
    @test_throws "No project ZZ" K.invite!(kb, "x@x.org"; roles = ["Reader"], projects = Dict("ZZ" => "viewer"))
    @test_throws "A member is a" K.invite!(kb, "x@x.org"; roles = ["Reader"], projects = Dict("MN" => "owner"))

    # An admin views the service as someone, a test account say, with exactly their rights, and goes back.
    sid = K.start_session!(kb, boss, sh)
    tester = K.add_test_account!(kb, "Test Reader"; roles = ["Reader"])
    @test_throws "already an account" K.add_test_account!(kb, "test reader"; roles = ["Reader"])
    K.view_as!(kb, sid, tester; caller = K.session_caller(kb, sid))
    c = K.session_caller(kb, sid)
    @test c.email == "test-reader@example.test" && c.admin == boss && !K.can(c, "users.manage")
    @test K.project_access(kb, c, "MN") == K.NO_ACCESS
    me = JSON.parse(String(K.handle(kb, HTTP.Request("GET", "/api/me"), c).body))
    @test me["admin"] == "boss@example.org" && me["email"] == "test-reader@example.test"
    K.audit!(kb, c, "try")
    @test first(K.audit_log(kb)).who == "boss@example.org as test-reader@example.test"
    # Viewing as someone makes no tokens of theirs.
    minted = K.handle(kb, HTTP.Request("POST", "/api/me/tokens", ["Content-Type" => "application/json"], JSON.json(Dict("name" => "x"))), c)
    @test minted.status >= 400 && occursin("viewing as someone", String(minted.body))
    back = K.handle(kb, HTTP.Request("POST", "/api/me/view-as", ["Content-Type" => "application/json", "Cookie" => "kb_session=$sid"],
                                     JSON.json(Dict("user_id" => nothing))), c)
    @test back.status == 200 && K.session_caller(kb, sid).email == "boss@example.org"
    osid = K.start_session!(kb, other, sh)
    @test_throws "Not permitted" K.view_as!(kb, osid, tester; caller = K.session_caller(kb, osid))
    close(kb)
end

@zset "codebase access" begin
    HTTP, JSON = K.HTTP, K.JSON
    sh = shared_config(sign_up = :open, default_role = "Reader")
    kb = open_kb(temp_config(shared = sh, layers = Layer[]))
    K.ensure_roles!(kb)
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    call(uid, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                                body === nothing ? UInt8[] : JSON.json(body)), as(uid));
                                                  (r.status, JSON.parse(String(r.body))))
    boss, ada, bea, rowan = account("boss@example.org", ["Admin"]), account("ada@x.org", ["Learner"]), account("bea@x.org", ["Learner"]),
                            account("rowan@x.org", ["Curator"])
    src = mktempdir()
    write(mkpath(joinpath(src, "src")) * "/Tide.jl", "\"Predict the tide.\"\ntide(t) = sin(t)\n")
    write(joinpath(src, "src", "notes.jl"), "#%% md id=intro\n@md\"\"\"\n# Tides\n\"\"\"\n#%% code id=run\ntide(1)\n")
    id = K.add_codebase!(kb, src; name = "Tide")
    K.parse_code!(kb, id)
    K.create_project!(kb, "Tides"; key = "TD", codebase = id, owner = ada, by = K.person("Ada"))
    K.create_project!(kb, "Other"; key = "OT", owner = bea, by = K.person("Bea"))
    saved = K._KB[]
    try
        # Open, as a codebase starts unless its repository is private, it is every reader's.
        @test K.scalar(kb, "SELECT access FROM papers WHERE doc_id = ?", (id,)) == "open" && K.document_visible(kb, as(bea), id)
        # Those who manage documents open it only to the members of its projects.
        @test call(bea, "POST", "/api/documents/$id/access", Dict("access" => "projects"))[1] == 403
        @test call(rowan, "POST", "/api/documents/$id/access", Dict("access" => "everyone"))[1] == 400
        @test call(rowan, "POST", "/api/documents/code-none/access", Dict("access" => "projects"))[1] == 404
        @test call(rowan, "POST", "/api/documents/$id/access", Dict("access" => "projects")) == (200, Dict("id" => id, "access" => "projects"))
        @test K.document_visible(kb, as(ada), id) && !K.document_visible(kb, as(bea), id) && !K.document_visible(kb, as(rowan), id)
        @test K.document_visible(kb, as(boss), id) && K.document_visible(kb, K.local_caller(), id)    # projects.all; run for one person
        @test K.hidden_documents(kb, as(bea)) == Set([id]) && isempty(K.hidden_documents(kb, as(ada)))

        # To anyone else it is none: not listed, not found, not read.
        listed(uid, target) = [x["id"] for x in call(uid, "GET", target)[2]]
        @test listed(ada, "/api/codebases") == [id] && only(call(ada, "GET", "/api/codebases")[2])["access"] == "projects"
        @test isempty(listed(bea, "/api/codebases")) && isempty(listed(bea, "/api/tasks/codebases")) && listed(ada, "/api/tasks/codebases") == [id]
        @test only(call(rowan, "GET", "/api/documents?state=code")[2]["documents"])["access"] == "projects"   # Manage lists every one
        hits(uid) = [h["id"] for h in call(uid, "GET", "/api/search?q=tide")[2]["hits"]]
        @test hits(ada) == [id] && isempty(hits(bea))
        @test call(ada, "GET", "/api/paper/$id")[1] == 200 && call(bea, "GET", "/api/paper/$id")[1] == 404
        @test call(ada, "GET", "/api/paper-text?id=$id&section=1")[1] == 200 && call(bea, "GET", "/api/paper-text?id=$id&section=1")[1] == 404
        @test call(bea, "GET", "/api/similar/$id")[1] == 404 && call(bea, "GET", "/api/figures?id=$id")[1] == 404
        @test call(bea, "POST", "/api/chat", Dict("paper" => id, "message" => "What is it?"))[1] == 404
        @test call(ada, "GET", "/api/tasks/file-work?codebase=$id&path=src/Tide.jl")[1] == 200
        @test call(bea, "GET", "/api/tasks/file-work?codebase=$id&path=src/Tide.jl")[1] == 404
        @test any(r -> r["kind"] == "code", call(ada, "GET", "/api/tasks/references?project=TD&q=code:src")[2])
        # Linking a project to it, or keeping it in a library, shows it to more people: it takes seeing it.
        @test call(bea, "POST", "/api/projects/OT", Dict("codebase" => id))[1] == 404
        @test call(bea, "POST", "/api/projects", Dict("name" => "Sneak", "key" => "SN", "codebase" => id))[1] == 404
        @test call(bea, "POST", "/api/projects/OT/library", Dict("source" => id))[1] == 404
        K.set_member!(kb, "OT", "ada@x.org", "contributor"; by = "bea@x.org")
        @test call(ada, "POST", "/api/projects/OT/library", Dict("source" => id))[1] == 200
        @test any(x -> x["target"] == id, call(ada, "GET", "/api/projects/OT/library")[2])
        @test !any(x -> x["target"] == id, call(bea, "GET", "/api/projects/OT/library")[2])   # in her project's library, not hers to see

        # The tools answer an agent as they answer the person it works for.
        K._KB[] = kb
        tools = Dict(t.name => t.f for t in K.TOOLS[])
        K.MCP_CALLERS["s-ada"] = (as(ada), K.Dates.now()); K.MCP_CALLERS["s-bea"] = (as(bea), K.Dates.now())
        by(sid, f) = task_local_storage(f, :gate_caller, sid)
        @test occursin("[$id]", by("s-ada", () -> tools["search"]("tide"))) && !occursin(id, by("s-bea", () -> tools["search"]("tide")))
        @test occursin("tide(t)", by("s-ada", () -> tools["read"](id)))
        @test_throws "No codebase $id" by("s-bea", () -> tools["read"](id))
        @test_throws "No codebase $id" by("s-bea", () -> tools["paper"](id))
        @test_throws "No codebase $id" by("s-bea", () -> tools["references"](id))
        @test occursin(id, by("s-ada", () -> tools["papers"]())) && !occursin(id, by("s-bea", () -> tools["papers"]()))
        @test occursin(id, by("s-ada", () -> tools["library"]("OT"))) && !occursin(id, by("s-bea", () -> tools["library"]("OT")))

        # The site every reader is served is built without it; the service answers its pages and data
        # at a built codebase's addresses, to those who may see it, and the 404 page to anyone else.
        K.build_site!(kb.config; build = (out, log) -> begin
            root = mkpath(joinpath(out, "1"))
            write(mkpath(joinpath(root, "generated", "kb", "templates")) * "/codebase.html", "<p>codebase template</p>")
            write(joinpath(root, "generated", "kb", "templates", "code-file.html"), "<p>file template</p>")
            write(mkpath(joinpath(root, "assets")) * "/generated_kb_templates_codebase.md.H1.js",
                  "page {\"relativePath\":\"generated/kb/templates/codebase.md\"}")
            write(joinpath(root, "index.html"), "home"); write(joinpath(root, "404.html"), "not here")
            write(log, "built")
        end)
        site(uid, path) = K.respond_shared(kb, HTTP.Request("GET", path, ["Cookie" => "kb_session=$(K.start_session!(kb, uid, sh))"]))
        text(r) = String(r.body)
        for path in ("/generated/kb/code/$id/", "/generated/kb/code/$id/files/src_Tide_jl.html", "/kb-data/codebase/$id/index.json",
                     "/code/$id.json", "/kb-data/code/$id/src_Tide_jl.json", "/code/$id/notebooks/src_notes_jl.json",
                     "/assets/generated_kb_code_$(id)_index.md.H1.c1.js")
            r = site(bea, path)
            @test r.status == 404 && text(r) == "not here"
        end
        @test text(site(ada, "/generated/kb/code/$id/")) == "<p>codebase template</p>"
        @test text(site(ada, "/generated/kb/code/$id/files/src_Tide_jl.html")) == "<p>file template</p>"
        @test text(site(ada, "/assets/generated_kb_code_$(id)_index.md.H1.c1.js")) == "page {\"relativePath\":\"generated/kb/code/$id/index.md\"}"
        page = site(ada, "/kb-data/codebase/$id/index.json")
        @test HTTP.header(page, "Cache-Control") == "no-store" && JSON.parse(text(page))["title"] == "Tide" &&
              JSON.parse(text(page))["access"] == "projects"
        @test JSON.parse(text(site(ada, "/code/$id.json")))["id"] == id
        @test JSON.parse(text(site(ada, "/kb-data/code/$id/src_Tide_jl.json")))["path"] == "src/Tide.jl"
        @test [x["id"] for x in JSON.parse(text(site(ada, "/code/$id/notebooks/src_notes_jl.json")))["cells"]] == ["intro", "run"]
        @test site(ada, "/kb-data/code/$id/src_None_jl.json").status == 404 && site(ada, "/code/$id/notebooks/src_Tide_jl.json").status == 404
        @test K.codebase_site_response(kb, K.local_caller(), "/kb-data/codebase/$id/index.json").status == 200   # run for one person

        # Nor does the dataset carry it: other members' services would show it to all their readers.
        K.set_shared!(kb, [id], true)
        @test !K.publishable(kb, id)
        K.set_document_access!(kb, id, "open")
        @test K.publishable(kb, id)
        # Open again, it is the site's own to serve.
        @test K.codebase_site_response(kb, as(bea), "/kb-data/codebase/$id/index.json") === nothing && hits(bea) == [id]
    finally
        K._KB[] = saved
        delete!(K.MCP_CALLERS, "s-ada"); delete!(K.MCP_CALLERS, "s-bea")
        close(kb)
    end
end

@zset "access to any document" begin
    sh = shared_config(sign_up = :open, default_role = "Reader")
    kb = open_kb(temp_config(shared = sh, layers = Layer[]))
    K.ensure_roles!(kb)
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    boss, ada, bea = account("boss@example.org", ["Admin"]), account("ada@x.org", ["Learner"]), account("bea@x.org", ["Learner"])
    K.create_project!(kb, "Reefs"; key = "RF", owner = ada, by = K.person("Ada"))
    K.create_project!(kb, "Other"; key = "OT", owner = bea, by = K.person("Bea"))
    # A kind of document with access that is not a codebase, belonging to projects by the links alone.
    note = K.DocumentKind(; name = "note", prefix = "note-", access = true, summarizer = :summarizer, prompts = K.PAPER.prompts,
                          read = K.PAPER.read, page = slug -> "notes/$slug")
    K.document_kind!(note)
    try
        K.execute!(kb, "INSERT INTO papers (doc_id, title, added_at, kind, access) VALUES ('note-survey', 'Survey notes', ?, 'note', 'projects')",
                   (K.now_iso(),))
        @test K.document_kind("note-survey") === note && isempty(K.document_projects(kb, "note-survey"))
        @test !K.document_visible(kb, as(ada), "note-survey") && K.document_visible(kb, K.local_caller(), "note-survey")
        K.link_document!(kb, "note-survey", "RF")
        @test K.document_projects(kb, "note-survey") == ["RF"]
        @test K.document_visible(kb, as(ada), "note-survey") && !K.document_visible(kb, as(bea), "note-survey")
        @test K.document_visible(kb, as(boss), "note-survey")                                    # projects.all
        @test K.hidden_documents(kb, as(bea)) == Set(["note-survey"]) && isempty(K.hidden_documents(kb, as(ada)))
        @test_throws "No note note-survey" K.seen_document(kb, as(bea), "note-survey")
        # Opened to every reader, it is every reader's; a paper has no access to set.
        K.set_document_access!(kb, "note-survey", "open")
        @test K.document_visible(kb, as(bea), "note-survey") && isempty(K.hidden_documents(kb, as(bea)))
        K.execute!(kb, "INSERT INTO papers (doc_id, title, added_at) VALUES ('2609.00001', 'Reef patches', ?)", (K.now_iso(),))
        @test_throws "open to every reader" K.set_document_access!(kb, "2609.00001", "projects")
        @test K.document_visible(kb, as(bea), "2609.00001")
        # A link undone, or its project deleted, no longer shows it.
        K.set_document_access!(kb, "note-survey", "projects")
        K.link_document!(kb, "note-survey", "OT")
        @test K.document_visible(kb, as(bea), "note-survey") && K.document_projects(kb, "note-survey") == ["OT", "RF"]
        K.unlink_document!(kb, "note-survey", "OT")
        @test !K.document_visible(kb, as(bea), "note-survey")
        @test_throws "No project XX" K.link_document!(kb, "note-survey", "XX")
        @test_throws "No document note-none" K.link_document!(kb, "note-none", "RF")
    finally
        filter!(k -> k.name != "note", K.DOCUMENT_KINDS)
        close(kb)
    end
end

@zset "record access" begin
    HTTP, JSON = K.HTTP, K.JSON
    sh = shared_config(sign_up = :open, default_role = "Reader")
    kb = open_kb(temp_config(shared = sh, layers = Layer[]))
    K.ensure_roles!(kb)
    account(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true); K.set_roles!(kb, uid, roles); uid)
    as(uid) = K.session_caller(kb, K.start_session!(kb, uid, sh))
    call(uid, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                                body === nothing ? UInt8[] : JSON.json(body)), as(uid));
                                                  (r.status, JSON.parse(String(r.body))))
    boss, ada, bea, rowan = account("boss@example.org", ["Admin"]), account("ada@x.org", ["Learner"]), account("bea@x.org", ["Learner"]),
                            account("rowan@x.org", ["Curator"])
    K.create_project!(kb, "Pumps"; key = "PU", owner = ada, by = K.person("Ada"))
    K.create_project!(kb, "Other"; key = "OT", owner = bea, by = K.person("Bea"))
    png = tempname() * ".png"
    K.PNGFiles.save(png, fill(K.RGB{K.N0f8}(0.2, 0.4, 0.6), 20, 30))
    id, _ = put_record!(kb, "notes", (; key = "pump-test", title = "Pump test review", date = "2026-10-02",
                                       people = ["Ada", "Rowan", "Bea"], label = "Meeting notes written up by a tool",
                                       sections = ["Results" => "Rowan reported the impeller held its pressure.\n\n![](screen-1)"],
                                       figures = [(; name = "screen-1", caption = "Pressure over time", image = png)]); read = false)
    K.read_record!(kb, id)
    saved = K._KB[]
    try
        # Linked to no project, it is seen only by those who manage documents, and whoever runs it alone.
        @test K.paper_row(kb, id).access == "projects" && isempty(K.document_projects(kb, id))
        @test K.document_visible(kb, as(rowan), id) && K.document_visible(kb, as(boss), id) && K.document_visible(kb, K.local_caller(), id)
        @test !K.document_visible(kb, as(ada), id) && !K.document_visible(kb, as(bea), id)
        # Those who manage documents link it to a project, whose members then see it.
        @test call(bea, "POST", "/api/documents/$id/projects", Dict("project" => "PU"))[1] == 403
        @test call(rowan, "POST", "/api/documents/$id/projects", Dict("project" => "XX"))[1] == 404
        @test call(rowan, "POST", "/api/documents/2609.00001/projects", Dict("project" => "PU"))[1] == 400
        @test call(rowan, "POST", "/api/documents/$id/projects", Dict("project" => "OT")) == (200, Dict("id" => id, "projects" => ["OT"]))
        @test call(rowan, "POST", "/api/documents/$id/projects", Dict("project" => "OT", "remove" => true))[2]["projects"] == []
        call(rowan, "POST", "/api/documents/$id/projects", Dict("project" => "PU"))
        @test K.document_visible(kb, as(ada), id) && !K.document_visible(kb, as(bea), id)
        @test only(call(rowan, "GET", "/api/documents?state=record")[2]["documents"])["projects"] == ["PU"]   # Manage lists every one

        # To its project's members it is listed, found, read and shown with what it is; to anyone else it is none.
        listed(uid, target = "/api/records") = [x["id"] for x in call(uid, "GET", target)[2]]
        @test listed(ada) == [id] && isempty(listed(bea)) && listed(ada, "/api/records?project=PU") == [id] &&
              isempty(listed(ada, "/api/records?project=OT")) && isempty(listed(ada, "/api/records?source=minutes"))
        @test only(call(ada, "GET", "/api/records")[2])["label"] == "Meeting notes written up by a tool"
        @test only(call(ada, "GET", "/api/projects/PU")[2]["records"])["id"] == id
        hits(uid, q = "impeller") = call(uid, "GET", "/api/search?q=$q")[2]["hits"]
        @test only(hits(ada))["id"] == id && isempty(hits(bea))
        @test only(hits(ada))["record"] == Dict("label" => "Meeting notes written up by a tool", "day" => "2 October 2026", "source" => "notes")
        @test occursin("record of the group's own work", only(hits(ada))["note"])
        @test isempty(hits(ada, "impeller&kinds=paper,code")) && length(hits(ada, "impeller&kinds=record")) == 1
        @test call(ada, "GET", "/api/paper/$id")[1] == 200 && call(bea, "GET", "/api/paper/$id")[1] == 404
        @test call(bea, "GET", "/api/figures?id=$id")[1] == 404 && only(call(ada, "GET", "/api/figures?id=$id")[2])["label"] == "screen-1"
        figure(uid) = K.handle(kb, HTTP.Request("GET", "/api/figures/$id/fig-1.webp"), as(uid)).status
        @test figure(ada) == 200 && figure(bea) == 404
        @test call(bea, "POST", "/api/chat", Dict("paper" => id, "message" => "What was decided?"))[1] == 404

        # The tools answer an agent as they answer the person it works for, and say what a record is.
        K._KB[] = kb
        tools = Dict(t.name => t.f for t in K.TOOLS[])
        K.MCP_CALLERS["s-ada"] = (as(ada), K.Dates.now()); K.MCP_CALLERS["s-bea"] = (as(bea), K.Dates.now())
        by(sid, f) = task_local_storage(f, :gate_caller, sid)
        found = by("s-ada", () -> tools["search"]("impeller"))
        @test occursin("[$id]", found) && occursin("record of the group's own work, from 2 October 2026", found)
        @test !occursin(id, by("s-bea", () -> tools["search"]("impeller")))
        @test occursin("not as established", by("s-ada", () -> tools["read"](id))) && occursin("impeller", by("s-ada", () -> tools["read"](id)))
        @test occursin("From notes; linked to PU", by("s-ada", () -> tools["paper"](id)))
        @test_throws "No record $id" by("s-bea", () -> tools["read"](id))
        @test occursin("[$id] Pump test review: 2 October 2026, with Ada, Rowan and Bea", by("s-ada", () -> tools["records"]()))
        @test by("s-bea", () -> tools["records"]()) == "No records."
        @test !occursin(id, by("s-ada", () -> tools["papers"]()))                               # not one of the papers
        @test occursin("Pressure over time", by("s-ada", () -> tools["figures"](id)))
        @test occursin("screen-1 of $id: Pressure over time", by("s-ada", () -> tools["figure"](id, "screen-1")))
        @test occursin("record of the group's own work", K.chat_context(kb, id))                          # the tutor is told too

        # Presence: present shows only that someone is on a board; planning also the task they have open,
        # what they write on it and whom they follow; hidden nothing. Only to those who reach the project.
        empty!(K.PRESENCE_BOARDS)
        K.report_presence!(as(ada), "present"; project = "PU", open = "PU-1", draft_ref = "PU-1", draft = "Not yet")
        p = only(K.presence(kb, as(boss)))
        @test p.name == as(ada).name && p.project == "PU" && !p.planning && p.open == "" && p.draft == ""
        @test isempty(K.presence(kb, as(ada))) && isempty(K.presence(kb, as(bea)))          # not yourself; not outside the project
        v = K.PRESENCE_VERSION[]
        K.report_presence!(as(ada), "present"; project = "PU")
        @test K.PRESENCE_VERSION[] == v                                                     # nothing new to show: no one is told
        K.report_presence!(as(ada), "planning"; project = "pu", open = "pu-1", draft_ref = "PU-1", draft = "The seals leak")
        p = only(K.presence(kb, as(boss)))
        @test p.planning && p.open == "PU-1" && p.draft == "The seals leak" && K.PRESENCE_VERSION[] > v
        K.report_presence!(as(boss), "planning"; project = "PU", following = as(ada).user_id)
        @test only(K.presence(kb, as(ada))).following == as(ada).user_id
        K.report_presence!(as(ada), "hidden"; project = "PU")
        @test isempty(K.presence(kb, as(boss)))
        K.report_presence!(as(ada), "present"; project = "PU")
        K.report_presence!(as(boss), "present"; project = "PU", at = time() + K.PRESENT_SECONDS + 1)   # Ada stopped reporting: gone
        @test isempty(K.presence(kb, as(rowan); at = time() + K.PRESENT_SECONDS + 1) |> ps -> filter(q -> q.name == as(ada).name, ps))
        @test_throws "hidden, present or planning" K.report_presence!(as(ada), "watching"; project = "PU")
        # The pen: whoever plans on a board, and those following them, point and draw for each other;
        # someone merely there sees none of it.
        empty!(K.PRESENCE_BOARDS); empty!(K.INK)
        K.report_presence!(as(ada), "planning"; project = "PU")
        K.report_presence!(as(boss), "present"; project = "PU", following = as(ada).user_id)
        K.report_presence!(as(rowan), "present"; project = "PU")
        @test K.in_session(as(ada), "PU") && K.in_session(as(boss), "pu") && !K.in_session(as(rowan), "PU")
        K.add_ink!(as(boss), "PU", "s1", "[{\"a\":\"ref:PU-1\",\"p\":\"\",\"x\":0.5,\"y\":0.5,\"d\":1}]")
        seen = K.ink_since(as(ada), "PU", 0; timeout = 0)
        @test only(seen.strokes).name == as(boss).name && only(seen.strokes).stroke == "s1" && seen.seq == K.INK_SEQ[]
        @test isempty(K.ink_since(as(boss), "PU", 0; timeout = 0).strokes)                     # not one's own
        @test isempty(K.ink_since(as(rowan), "PU", 0; timeout = 0).strokes)                    # not outside the session
        @test_throws "in a session" K.add_ink!(as(rowan), "PU", "s2", "[]")
        empty!(K.PRESENCE_BOARDS); empty!(K.INK)
        made = K.create_task!(kb, "PU", "Check the seals"; by = K.person("Ada Lovelace"))
        did = K.people_did(kb, "PU", as(boss))
        @test first(did).who == "Ada Lovelace" && first(did).kind == "created" && first(did).ref == made && first(did).title == "Check the seals"
        ada_named = K.Caller(as(ada).user_id, "Ada Lovelace", "ada@x.org", Set(["tasks.view"]), :session, nothing, nothing, nothing)
        @test !any(e -> e.who == "Ada Lovelace", K.people_did(kb, "PU", ada_named))             # your own are left out

        # The bibliography holds the records the caller sees, cited by their ids, and only what `keys` names.
        bib(caller, q = "", headers = Pair{String,String}[]) = K.handle(kb, HTTP.Request("GET", "/api/bib$q", headers), caller)
        r = bib(as(ada))
        @test r.status == 200 && HTTP.header(r, "Content-Type") == "text/plain; charset=utf-8"
        entry = String(r.body)
        @test occursin("@misc{$id,", entry) && occursin("date = {2026-10-02}", entry) &&
              occursin("howpublished = {Meeting notes written up by a tool}", entry) && occursin("title = {{Pump test review}}", entry)
        @test !occursin(id, String(bib(as(bea)).body))
        @test occursin(id, String(bib(as(ada), "?keys=arXiv:2401.00001,$id").body)) &&
              startswith(String(bib(as(ada), "?keys=arXiv:2401.00001").body), "% The documents of the knowledge base: 0 entries.")
        @test bib(as(ada), "", ["If-None-Match" => HTTP.header(r, "ETag")]).status == 304          # unchanged: asked again cheaply
        tutor_only = K.create_token!(kb, ada; name = "tutor only", permissions = ["tutor"]).token
        @test bib(K.ANONYMOUS).status == 401 && bib(K.token_caller(kb, tutor_only)).status == 403
        # Membership decides which records a token sees, whatever it may do with the project's tasks.
        read_only = K.token_caller(kb, K.create_token!(kb, ada; name = "read only", permissions = ["read"]).token)
        @test occursin("@misc{$id,", String(bib(read_only).body)) && K.project_access(kb, read_only, "PU") == K.NO_ACCESS

        # No page of it is built; the service answers its page, script and data, to those who may see it.
        site_dir, public = mktempdir(), mktempdir()
        nav = write_site(kb, site_dir, public; related = false)
        @test nav.records == "records.md" && occursin("<KBRecords />", read(joinpath(site_dir, "records.md"), String))
        @test read(joinpath(site_dir, "templates", "record.md"), String) == K.template_markdown("records")
        @test !ispath(joinpath(public, "kb-data", "records")) && !ispath(joinpath(site_dir, "records"))
        @test K.site_from_json(K.site_json(nav)).records == "records.md"
        K.build_site!(kb.config; build = (out, log) -> begin
            root = mkpath(joinpath(out, "1"))
            write(mkpath(joinpath(root, "generated", "kb", "templates")) * "/record.html", "<p>record template</p>")
            write(mkpath(joinpath(root, "assets")) * "/generated_kb_templates_record.md.H1.js",
                  "page {\"relativePath\":\"generated/kb/templates/record.md\"}")
            write(joinpath(root, "index.html"), "home"); write(joinpath(root, "404.html"), "not here")
            write(log, "built")
        end)
        site(uid, path) = K.respond_shared(kb, HTTP.Request("GET", path, ["Cookie" => "kb_session=$(K.start_session!(kb, uid, sh))"]))
        text(r) = String(r.body)
        for path in ("/generated/kb/records/$id.html", "/kb-data/records/$id.json", "/assets/generated_kb_records_$(id).md.H1.c1.js")
            r = site(bea, path)
            @test r.status == 404 && text(r) == "not here"
        end
        @test site(ada, "/kb-data/records/rec-notes-none.json").status == 404
        # The pages need `read`: a token made without it is refused them.
        bearer(token) = K.respond_shared(kb, HTTP.Request("GET", "/index.html", ["Authorization" => "Bearer $token"]))
        @test bearer(tutor_only).status == 403 && text(bearer(K.create_token!(kb, ada; name = "pages", permissions = ["read"]).token)) == "home"
        @test text(site(ada, "/generated/kb/records/$id.html")) == "<p>record template</p>"
        @test text(site(ada, "/assets/generated_kb_records_$(id).md.H1.c1.js")) == "page {\"relativePath\":\"generated/kb/records/$id.md\"}"
        page = site(ada, "/kb-data/records/$id.json")
        data = JSON.parse(text(page))
        @test HTTP.header(page, "Cache-Control") == "no-store" && data["title"] == "Pump test review" && data["day"] == "2 October 2026" &&
              data["label"] == "Meeting notes written up by a tool" && data["projects"] == [Dict("key" => "PU", "name" => "Pumps")]
        @test occursin("![Pressure over time](/api/figures/$id/fig-1.webp)", only(data["sections"])["text"]) && only(data["figures"])["placed"]
        # Cited as a record: dated to the day, described by how it was made.
        @test data["cite"]["reference"] == "@$id" && occursin("(2026, October 2). Pump test review [Meeting notes written up by a tool].", data["cite"]["citation"])
        # Run for one person, every record is theirs; open, it is still served, never built.
        @test K.record_site_response(kb, K.local_caller(), "/kb-data/records/$id.json").status == 200
        K.set_document_access!(kb, id, "open")
        @test site(bea, "/kb-data/records/$id.json").status == 200
        write_site(kb, site_dir, public; related = false)
        @test !ispath(joinpath(public, "kb-data", "records"))
        # Nor does the dataset carry it, open and marked shared.
        K.set_shared!(kb, [id], true)
        @test !K.publishable(kb, id)
        # A change to a record writes only the page listing them.
        @test K.write_site_changes!(kb, site_dir, public, [id]) == 0
    finally
        K._KB[] = saved
        delete!(K.MCP_CALLERS, "s-ada"); delete!(K.MCP_CALLERS, "s-bea")
        close(kb)
    end
end

@zset "record sources on the API" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config(layers = Layer[]))
    K.ensure_roles!(kb)
    saved = K.SOURCES[]
    K.READ_PUT[] = false
    sh = shared_config(sign_up = :open, default_role = "Reader")
    caller(email, roles) = (uid = K.sign_in!(kb, sh, "Campus", email; email, verified = true);
                            K.set_roles!(kb, uid, roles); K.session_caller(kb, K.start_session!(kb, uid, sh)))
    reader, curator, admin = caller("r@x.org", ["Reader"]), caller("c@x.org", ["Curator"]), caller("a@x.org", ["Admin"])
    call(c, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                             body === nothing ? UInt8[] : JSON.json(body)), c);
                                               (r.status, JSON.parse(String(r.body))))
    try
        poll_notes(run) = put!(run, (; key = "k1", title = "Pump review", date = "2026-10-02", sections = ["Notes" => "It held."]))
        record_source!("zz-notes"; label = "Written up by a stand-in", every = 3600, poll = poll_notes, api = K.PLUGIN_API)
        # Records of a source no package registers here any more.
        put_record!(kb, "zz-gone", (; key = "k1", title = "Old review", date = "2026-09-01", sections = ["Notes" => "Long ago."]); read = false)
        put_record!(kb, "zz-gone", (; key = "k2", title = "Older review", date = "2026-08-01", sections = ["Notes" => "Longer ago."]); read = false)

        # Those who manage documents see the sources and run them; only an Admin removes a source's records.
        @test call(reader, "GET", "/api/sources")[1] == 403
        @test K.find_route("POST", ["api", "sources", "x", "run"])[1].need == "paper.manage"
        @test K.find_route("POST", ["api", "sources", "x", "purge"])[1].need == "records.purge"
        @test "records.purge" in K.user_permissions(kb, admin.user_id) && !K.can(curator, "records.purge")
        s, r = call(curator, "GET", "/api/sources")
        byname = Dict(x["name"] => x for x in r["sources"])
        @test s == 200 && r["mode"] == "local"
        @test byname["zz-notes"]["registered"] && byname["zz-notes"]["polls"] && byname["zz-notes"]["here"] &&
              byname["zz-notes"]["every"] == 3600 && byname["zz-notes"]["outcome"] === nothing && byname["zz-notes"]["records"] == 0
        @test !byname["zz-gone"]["registered"] && byname["zz-gone"]["records"] == 2 && byname["zz-gone"]["label"] == ""
        @test byname["upload"]["uploads"] && !byname["upload"]["polls"] && byname["upload"]["next"] === nothing
        s, r = call(curator, "POST", "/api/sources/zz-notes/run", Dict())
        @test s == 200 && wait(K.get_job(r["job"])).status == :done
        x = only(filter(x -> x["name"] == "zz-notes", call(curator, "GET", "/api/sources")[2]["sources"]))
        @test x["outcome"] == "ok" && x["added"] == 1 && x["records"] == 1 && x["next"] !== nothing && !x["running"]
        @test call(curator, "POST", "/api/sources/zz-notes/pause", Dict())[1] == 200
        x = only(filter(x -> x["name"] == "zz-notes", call(curator, "GET", "/api/sources")[2]["sources"]))
        @test x["paused"] && x["next"] === nothing
        @test call(curator, "POST", "/api/sources/zz-notes/resume", Dict())[1] == 200 && !K.source_status(kb, "zz-notes")["paused"]
        @test call(curator, "POST", "/api/sources/zz-gone/run", Dict())[1] == 404
        @test call(curator, "POST", "/api/sources/upload/run", Dict())[1] == 400
        # Uploaded on a project's page, a record needs its uploader to contribute to that project.
        K.create_project!(kb, "Pumps"; key = "PU", owner = admin.user_id, by = K.person("Ada"))
        up(c, q) = K.handle(kb, HTTP.Request("POST", "/api/records/upload?name=n.md&date=2026-10-05&$q", ["Content-Type" => "text/markdown"],
                                             "# Standup\n\nAll well.\n"), c).status
        @test up(reader, "") == 403 && up(curator, "") == 400 && up(curator, "project=PU") == 404
        K.set_member!(kb, "PU", "c@x.org", "contributor")
        @test up(curator, "project=PU") == 200
        @test only(K.mentions(kb, K.record_id("upload", "2026-10-05 n"))).author == K.caller_name(curator)

        # Removing a source's records is confirmed with their count.
        @test call(curator, "POST", "/api/sources/zz-gone/purge", Dict("count" => 2))[1] == 403
        s, r = call(admin, "POST", "/api/sources/zz-gone/purge", Dict())
        @test s == 409 && r["count"] == 2 && occursin("2 record", r["error"])
        @test call(admin, "POST", "/api/sources/zz-gone/purge", Dict("count" => 1))[1] == 409
        s, r = call(admin, "POST", "/api/sources/zz-gone/purge", Dict("count" => 2))
        @test s == 200 && r["removed"] == 2 && isempty(K.query(kb, "SELECT 1 FROM records WHERE source = 'zz-gone'"))
        @test first(K.audit_log(kb)).action == "sources/zz-gone/purge"
    finally
        K.SOURCES[] = saved
        K.READ_PUT[] = true
        close(kb)
    end
end

@zset "the shared service" begin
    HTTP, JSON = K.HTTP, K.JSON
    sh = shared_config(base_url = "https://kb.example.org", sign_up = :open, default_role = "Reader",
                       providers = [K.Provider(name = "Campus Login", kind = :oidc, issuer = "https://idp.example.org", client_id = "c")])
    kb = open_kb(temp_config(shared = sh))
    K.ensure_roles!(kb)
    c = kb.config

    # Builds: each into a folder of its own, switched to in one step; a failed one leaves the site up.
    version = Ref(0)
    function fake_build(out, log)
        version[] += 1
        mkpath(joinpath(out, "1", "assets")); mkpath(joinpath(out, "1", "papers"))
        write(joinpath(out, "1", "index.html"), "home $(version[])")
        write(joinpath(out, "1", "papers", "a.html"), "paper a")
        write(joinpath(out, "1", "assets", "chunk.Hash000$(version[]).js"), "chunk $(version[])")
        write(log, "built")
    end
    failing(out, log) = error("vitepress fell over")
    id1 = K.build_site!(c; build = fake_build)
    @test read(K.site_file(c, "/"), String) == "home 1"
    sleep(1.1)                                                     # build ids are by the second
    K.build_site!(c; build = fake_build)
    @test read(K.site_file(c, "/index.html"), String) == "home 2"
    @test read(K.site_file(c, "/papers/a"), String) == "paper a"                       # clean addresses
    @test read(K.site_file(c, "/assets/chunk.Hash0001.js"), String) == "chunk 1"       # an earlier build's asset
    @test K.site_file(c, "/../../etc/passwd") === nothing && K.site_file(c, "/nowhere") === nothing
    # Each file carries an ETag of its content: a browser with the current copy is told so, without
    # the file. Hashed assets are kept for good, images for a day, the rest asked about each time.
    page = K.site_file(c, "/index.html")
    r = K.file_response(page)
    tag = HTTP.header(r, "ETag")
    @test r.status == 200 && HTTP.header(r, "Cache-Control") == "no-cache" && length(tag) == 34
    again = K.file_response(page; req = HTTP.Request("GET", "/index.html", ["If-None-Match" => "\"other\", $tag"]))
    @test again.status == 304 && isempty(again.body) && HTTP.header(again, "ETag") == tag
    @test K.file_response(page; req = HTTP.Request("GET", "/index.html", ["If-None-Match" => "\"other\""])).status == 200
    same = tempname() * ".html"
    cp(page, same)
    @test HTTP.header(K.file_response(same), "ETag") == tag                                 # the content's, wherever it is
    write(same, "changed")
    @test HTTP.header(K.file_response(same), "ETag") != tag
    @test HTTP.header(K.file_response(K.site_file(c, "/assets/chunk.Hash0001.js")), "Cache-Control") == "public, max-age=31536000, immutable"
    logo = joinpath(mkpath(joinpath(mktempdir(), "content", "assets")), "logo.png")        # a name kept when it changes
    write(logo, "png")
    @test HTTP.header(K.file_response(logo), "Cache-Control") == "public, max-age=86400"
    svg = tempname() * ".svg"; write(svg, "<svg></svg>")
    @test HTTP.header(K.file_response(svg), "Content-Security-Policy") == "sandbox"            # no script on the site's origin
    @test_throws ErrorException K.build_site!(c; build = failing)
    @test read(K.site_file(c, "/"), String) == "home 2"
    # One failing part way leaves its log, not its folder.
    half(out, log) = (mkpath(joinpath(out, "1")); write(log, "half"); error("vitepress fell over"))
    sleep(1.1)
    @test_throws ErrorException K.build_site!(c; build = half)
    failed_id = chop(last(sort(filter(endswith(".log"), readdir(K.builds_dir(c))))); tail = 4)
    @test !isdir(joinpath(K.builds_dir(c), failed_id)) && isfile(joinpath(K.builds_dir(c), failed_id * ".log"))

    # Requests while a build runs make one more build, not one each.
    gate = Channel{Nothing}(1)
    slow(out, log) = (take!(gate); sleep(1.1); fake_build(out, log))
    before = version[]
    K.request_build!(c; build = slow)
    foreach(_ -> K.request_build!(c; build = slow), 1:5)
    put!(gate, nothing); put!(gate, nothing)
    timedwait(() -> !K.SITE.building, 30)
    @test version[] == before + 2 && K.SITE.error === nothing
    # A build that settles first takes in what is asked for meanwhile: one build for a run of changes.
    before = version[]
    K.request_build!(c; build = fake_build, settle = 0.5)
    foreach(_ -> K.request_build!(c; build = fake_build, settle = 0.5), 1:5)
    timedwait(() -> !K.SITE.building, 30)
    @test version[] == before + 1
    # Pruned to the builds that built, the newest two and the one served, and the failed one's log goes.
    @test count(n -> occursin(r"^\d{8}T\d{6}$", n), readdir(K.builds_dir(c))) <= 3
    @test !isfile(joinpath(K.builds_dir(c), failed_id * ".log"))

    # Who may have what.
    req(method, target; headers = Pair{String,String}[], body = "") = K.respond_shared(kb, HTTP.Request(method, target, headers, body))
    r = req("GET", "/papers/a")
    @test r.status == 302 && HTTP.header(r, "Location") == "/auth/sign-in?return_to=" * HTTP.escapeuri("/papers/a")
    page = String(req("GET", "/auth/sign-in?return_to=/papers/a").body)
    @test occursin("/auth/login/campus-login?return_to=%2Fpapers%2Fa", page) && occursin("/auth/paste", page)
    # The site's icon is anyone's, wherever a client looks for it: the logo, before signing in.
    for (path, file, type) in (("/favicon.ico", "favicon.ico", "image/x-icon"), ("/favicon-32x32.png", "icon.png", "image/png"),
                               ("/apple-touch-icon.png", "logo.png", "image/png"), ("/android-chrome-192x192.png", "logo.png", "image/png"))
        icon = req("GET", path)
        @test icon.status == 200 && HTTP.header(icon, "Content-Type") == type && HTTP.header(icon, "Access-Control-Allow-Origin") == "*"
        @test icon.body == read(K.site_icon(kb.config, file))
    end
    @test length(read(K.site_icon(kb.config))) < 16_000                                             # the small one is small
    @test occursin("""<link rel="icon" type="image/png" href="/favicon.png">""", page)
    @test req("GET", "/api/status").status == 401
    @test !HTTP.hasheader(req("GET", "/api/status"), "Access-Control-Allow-Origin")       # no other site reads its answers

    uid = K.sign_in!(kb, sh, "Campus Login", "s1"; email = "r@x.org", verified = true)
    secret = K.start_session!(kb, uid, sh)
    signed = ["Cookie" => "other=1; kb_session=$secret"]
    @test String(req("GET", "/papers/a"; headers = signed).body) == "paper a"
    @test req("GET", "/api/status"; headers = signed).status == 200
    # A change with the cookie must come from the site's own pages, with the API's header.
    add = JSON.json(Dict("arxiv" => "2609.00002"))
    @test req("POST", "/api/documents"; headers = signed, body = add).status == 403
    @test req("POST", "/api/documents"; headers = [signed; "X-Zemi" => "1"; "Origin" => "https://evil.example"], body = add).status == 403
    r = req("POST", "/api/documents"; headers = [signed; "X-Zemi" => "1"; "Origin" => "https://kb.example.org"], body = add)
    @test r.status == 403 && JSON.parse(String(r.body))["permission"] == "paper.add"        # it got through, to the role
    # A token needs no header: a browser never sends one by itself.
    tok = K.create_token!(kb, uid; name = "script").token
    @test req("GET", "/api/status"; headers = ["Authorization" => "Bearer $tok"]).status == 200
    @test req("GET", "/api/status"; headers = ["Authorization" => "Bearer zemi_nope"]).status == 401

    # Signing out ends the session.
    r = req("POST", "/auth/sign-out"; headers = [signed; "X-Zemi" => "1"])
    @test r.status == 204 && occursin("Max-Age=0", HTTP.header(r, "Set-Cookie")) && occursin("Secure", HTTP.header(r, "Set-Cookie"))
    @test req("GET", "/api/status"; headers = signed).status == 401
    @test K.METRICS["site"].count >= 2 && haskey(K.METRICS, "GET /api/status")
    close(kb)
end

@zset "settings and the admin pages' API" begin
    HTTP, JSON = K.HTTP, K.JSON
    dir = mktempdir()
    cfg = joinpath(dir, "config.toml")
    write(cfg, """data_dir = "$(joinpath(dir, "data"))"\ncollection_prefix = "zemi_test"\nsummarizer = "opus-agent-pdf"\n""")
    withenv("ZEMI_CONFIG" => cfg) do
        kb = open_kb(K.load_config())
        K.ensure_roles!(kb)
        c = kb.config
        @test K.settings_path() == joinpath(dir, "config.settings.toml")
        @test K.purpose(c, :tutor).name == "opus-agent-pdf" && c.tutor_effort == "medium"

        # Settings: written beside the config, applied at once, refused whole when they do not hold.
        K.save_settings!(kb, Dict("tutor" => "deepseek-v4.1-flash", "watch.categories" => "physics.ao-ph, nlin.CD",
                                  "tutor_effort" => "low", "search.keyword" => false))
        @test kb.config.tutor == "deepseek-v4.1-flash" && K.purpose(kb.config, :tutor).name == "deepseek-v4.1-flash"
        @test kb.config.watch_categories == ["physics.ao-ph", "nlin.CD"] && !kb.config.search_keyword
        @test K.load_config().tutor_effort == "low"                                  # it is in the file too
        before = read(K.settings_path(), String)
        @test_throws ErrorException K.save_settings!(kb, Dict("tutor" => "nobody"))
        @test read(K.settings_path(), String) == before && kb.config.tutor == "deepseek-v4.1-flash"
        @test_throws ErrorException K.save_settings!(kb, Dict("data_dir" => "/elsewhere"))
        @test_throws ErrorException K.save_settings!(kb, Dict("tutor_effort" => "furious"))
        @test occursin("physics.ao-ph", read(cfg, String)) == false                   # the config file itself is untouched

        # The API, by role.
        sh = K.SharedConfig(base_url = "http://localhost:8800", admins = ["a@x.org"], sign_up = :open, default_role = "Reader")
        mk(email) = K.session_caller(kb, K.start_session!(kb, K.sign_in!(kb, sh, "Campus", email; email, verified = true), sh))
        admin, reader = mk("a@x.org"), mk("r@x.org")
        call(who, method, target, body = nothing) = (r = K.handle(kb, HTTP.Request(method, target, ["Content-Type" => "application/json"],
                                                                                   body === nothing ? UInt8[] : JSON.json(body)), who);
                                                     (r.status, JSON.parse(String(r.body))))
        @test call(reader, "GET", "/api/admin/users")[1] == 403 && call(reader, "GET", "/api/ops")[1] == 403
        @test call(reader, "GET", "/api/config")[1] == 403 && call(reader, "POST", "/api/config", Dict("changes" => Dict()))[1] == 403
        @test call(admin, "POST", "/api/admin/invite", Dict("email" => "new@x.org", "roles" => ["Learner"]))[1] == 200
        s, u = call(admin, "GET", "/api/admin/users")
        @test s == 200 && length(u["users"]) == 2 && only(u["invitations"])["email"] == "new@x.org"
        @test call(admin, "POST", "/api/admin/users/$(admin.user_id)", Dict("disabled" => true))[1] == 400   # not oneself
        @test call(admin, "POST", "/api/admin/users/$(reader.user_id)", Dict("roles" => ["Learner"]))[1] == 200
        @test K.user_roles(kb, reader.user_id) == ["Learner"]

        # Anyone signed in manages their own tokens; an admin sees and revokes everyone's.
        s, t = call(reader, "POST", "/api/me/tokens", Dict("name" => "laptop", "days" => 30))
        @test s == 200 && startswith(t["token"], "zemi_")
        me = call(reader, "GET", "/api/me")[2]
        @test me["accounts"] && only(me["tokens"])["name"] == "laptop" && !haskey(only(me["tokens"]), "token")
        @test only(call(admin, "GET", "/api/admin/tokens")[2]["tokens"])["email"] == "r@x.org"
        # A token cannot make another: one made with it could be wider than itself.
        narrow = K.token_caller(kb, K.create_token!(kb, reader.user_id; name = "read only", permissions = ["read"]).token)
        s, err = call(narrow, "POST", "/api/me/tokens", Dict("name" => "wider"))
        @test s >= 400 && occursin("not with a token", err["error"]) && length(K.tokens(kb; uid = reader.user_id)) == 2
        @test call(admin, "POST", "/api/admin/tokens/$(t["id"])/revoke")[1] == 200 && K.token_caller(kb, t["token"]) === K.ANONYMOUS

        # A job is its starter's to follow, and everyone's for those with jobs.view.
        mine = task_local_storage(() -> K.start_job(job -> "done", "reader's"), :kb_caller, reader)
        other = mk("o@x.org")
        @test call(reader, "GET", "/api/jobs/$(mine.id)")[1] == 200 && call(admin, "GET", "/api/jobs/$(mine.id)")[1] == 200
        @test call(other, "GET", "/api/jobs/$(mine.id)")[1] == 404
        # Without a project, the people listed are those of the projects one sees, not every account.
        @test !any(p -> p["id"] == "a@x.org", call(other, "GET", "/api/tasks/people")[2])
        # Nor are others found by what is typed after `@`.
        person(c) = any(r -> r["kind"] == "person" && r["target"] == "a@x.org", call(c, "GET", "/api/tasks/references?q=a")[2])
        @test !person(other) && person(admin)

        # Operations, and the configuration through the API.
        s, ops = call(admin, "GET", "/api/ops")
        @test s == 200 && haskey(ops["health"], "uptime_seconds") && haskey(ops["health"], "site") && ops["metrics"] isa Vector
        j = K.start_job(job -> (while !K.cancelled(job); sleep(0.05); end; "stopped"), "a long job")
        @test call(admin, "POST", "/api/jobs/$(j.id)/cancel")[1] == 200
        timedwait(() -> j.status != :running, 5)
        @test j.status == :cancelled && j.result == "stopped"
        s, conf = call(admin, "GET", "/api/config")
        @test s == 200 && any(x -> x["key"] == "tutor" && x["value"] == "deepseek-v4.1-flash", conf["settings"])
        @test call(admin, "POST", "/api/config", Dict("changes" => Dict("analyst" => "deepseek-v4.1-flash")))[1] == 200
        @test kb.config.analyst == "deepseek-v4.1-flash"
        @test any(e -> e.action == "config" && e.detail["changes"]["analyst"] == "deepseek-v4.1-flash", K.audit_log(kb))
        close(kb)
    end
end

@zset "nobody locks everyone out" begin
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader")
    boss = K.sign_in!(kb, sh, "Campus", "b"; email = "boss@example.org", verified = true)
    other = K.sign_in!(kb, sh, "Campus", "o"; email = "o@example.org", verified = true)
    # The only admin can neither drop the role, nor be disabled, nor have Admin stripped or removed.
    @test_throws ErrorException K.set_roles!(kb, boss, ["Reader"])
    @test_throws ErrorException K.set_disabled!(kb, boss, true)
    @test_throws ErrorException K.save_role!(kb, "Admin"; permissions = ["read"])
    @test_throws ErrorException K.delete_role!(kb, "Admin")
    @test K.user_roles(kb, boss) == ["Admin"]                                   # nothing was changed
    # With a second admin, either may step down.
    K.set_roles!(kb, other, ["Admin"])
    K.set_roles!(kb, boss, ["Reader"])
    @test K.user_roles(kb, boss) == ["Reader"]
    # An email the config names as an admin gets the role back on signing in.
    K.sign_in!(kb, sh, "Campus", "b")
    @test "Admin" in K.user_roles(kb, boss)
    close(kb)
end

@zset "a service before its first admin" begin
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader", admins = String[])
    a = K.sign_in!(kb, sh, "Campus", "a"; email = "a@example.org", verified = true)
    K.set_roles!(kb, a, ["Learner"])                     # no admin to lose, so roles can change
    @test K.user_roles(kb, a) == ["Learner"]
    close(kb)
end

@zset "nobody demotes themselves" begin
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config(sign_up = :open, default_role = "Reader", admins = String[])
    a = K.sign_in!(kb, sh, "Campus", "a"; email = "a@example.org", verified = true)
    b = K.sign_in!(kb, sh, "Campus", "b"; email = "b@example.org", verified = true)
    K.set_roles!(kb, a, ["Admin"]); K.set_roles!(kb, b, ["Admin"])
    # Even with another admin, nobody takes their own administration away; another admin can.
    @test_throws ErrorException K.set_roles!(kb, a, ["Reader"]; by = a)
    K.save_role!(kb, "Steward"; permissions = ["read", "users.manage"])
    K.set_roles!(kb, a, ["Steward"]; by = b)
    @test_throws ErrorException K.save_role!(kb, "Steward"; permissions = ["read"], by = a)
    @test_throws ErrorException K.delete_role!(kb, "Steward"; by = a)
    @test K.user_roles(kb, a) == ["Steward"]
    K.delete_role!(kb, "Steward"; by = b)                                        # b may
    @test isempty(K.user_roles(kb, a))
    close(kb)
end

@zset "embedding layers from the Configuration page" begin
    dir = mktempdir()
    cfg = joinpath(dir, "config.toml")
    write(cfg, """data_dir = "$(joinpath(dir, "data"))"\ncollection_prefix = "zemi_test"\nsummarizer = "deepseek-v4.1-flash"\n""")
    withenv("ZEMI_CONFIG" => cfg) do
        kb = open_kb(K.load_config())
        @test K.model_slug("qwen3-embedding:4b") == "qwen3-4b" && K.model_slug("nomic-embed-text") == "nomic"
        j = K.layers_json(kb)
        qwen = only(m for m in j["models"] if m["model"] == "qwen3-embedding:4b" && m["url"] == "")
        @test Set(l["kind"] for l in qwen["layers"]) == Set(["paper", "section", "chunk", "section-summary", "paper-summary"])
        @test any(l -> l["name"] == "section-summary-qwen3-4b" && l["source"] == "default", qwen["layers"])

        # Keep qwen's text layers and its paper summaries, drop the rest, and add a model for chunks.
        models = [Dict("model" => "qwen3-embedding:4b", "query_prefix" => K.qwen_query_prefix(),
                       "layers" => [Dict("kind" => "paper"), Dict("kind" => "section"), Dict("kind" => "paper-summary", "source" => "default")]),
                  Dict("model" => "all-minilm", "layers" => [Dict("kind" => "chunk", "trial" => true)])]
        K.save_layers!(kb, models)
        names = [l.name for l in kb.config.layers]
        @test names == ["paper-qwen3-4b", "section-qwen3-4b", "paper-summary-qwen3-4b", "chunk-all-minilm"]   # kept, kept, kept, new
        @test only(l for l in kb.config.layers if l.name == "chunk-all-minilm").trial
        @test only(l for l in kb.config.layers if l.name == "paper-summary-qwen3-4b").source == "deepseek-v4.1-flash"
        @test all(in(Set(names)), kb.config.search_layers)                      # no default search layer left behind
        @test [l.name for l in K.load_config().layers] == names                  # in the settings file
        @test_throws ErrorException K.save_layers!(kb, [])                       # at least one layer
        @test_throws ErrorException K.save_layers!(kb, [Dict("model" => "m", "layers" => [Dict("kind" => "everything")])])
        # A key read from this machine is the config file's to name: it is sent to the layer's address.
        for key in ("file:~/.ssh/id_ed25519", "env:CLAUDE_CODE_OAUTH_TOKEN", "opencode")
            @test_throws "Not permitted" K.save_layers!(kb, [Dict("model" => "m", "url" => "https://elsewhere.example", "key" => key,
                                                                  "layers" => [Dict("kind" => "chunk")])])
        end
        @test [l.name for l in kb.config.layers] == names                        # nothing changed by refused saves
        close(kb)
    end
end

@zset "serving one person's knowledge base" begin
    HTTP, JSON = K.HTTP, K.JSON
    kb = open_kb(temp_config())
    c = kb.config
    K.build_site!(c; build = (out, log) -> (mkpath(joinpath(out, "1")); write(joinpath(out, "1", "index.html"), "home"); write(log, "")))
    key = K.local_key(c)
    keyed = ["Cookie" => "$(K.local_cookie())=$key"]
    req(method, target; headers = Pair{String,String}[], body = "") = K.respond_service(kb, HTTP.Request(method, target, [keyed; headers], body); shared = false)
    # Only with its key, kept where only its owner reads it: other accounts on the machine reach its port too.
    bare(method, target; headers = Pair{String,String}[]) = K.respond_service(kb, HTTP.Request(method, target, headers); shared = false)
    @test filemode(K.local_key_path(c)) & 0o077 == 0
    @test bare("GET", "/api/status").status == 401 && K.JSON.parse(String(bare("GET", "/api/status").body))["locked"]
    @test bare("GET", "/").status == 401 && occursin("zemi open", String(bare("GET", "/").body))
    @test bare("GET", "/api/status"; headers = ["Cookie" => "$(K.local_cookie())=wrong"]).status == 401
    @test bare("GET", "/api/status"; headers = ["Authorization" => "Bearer $key"]).status == 200
    @test bare("GET", "/favicon.ico").status != 401
    # The address with the key sets it in the browser, and leads to the same page without it.
    r = bare("GET", "/papers/x?key=$key&a=1")
    @test r.status == 302 && HTTP.header(r, "Location") == "/papers/x?a=1" &&
          occursin("$(K.local_cookie())=$key", HTTP.header(r, "Set-Cookie")) && occursin("HttpOnly", HTTP.header(r, "Set-Cookie"))
    @test K.local_key(c) == key == strip(read(K.local_key_path(c), String))
    # The site and the API, with no signing in; the person running it may do everything.
    # No other site's page reads its answers, nor reaches it through a name of its own pointed here.
    @test !HTTP.hasheader(req("GET", "/api/status"), "Access-Control-Allow-Origin")
    @test req("GET", "/api/status"; headers = ["Host" => "evil.example:8000"]).status == 403
    @test req("GET", "/api/status"; headers = ["Host" => "localhost:8000"]).status == 200
    @test String(req("GET", "/").body) == "home"
    s = JSON.parse(String(req("GET", "/api/status").body))
    @test s["me"]["via"] == "local" && "config.edit" in s["me"]["permissions"] && s["build"] == K.SITE.id
    # Changes only from this machine's pages, with the API's header; no signing in at all.
    add = JSON.json(Dict("arxiv" => "2609.00002", "read" => false))
    @test req("POST", "/api/documents"; headers = ["X-Zemi" => "1", "Origin" => "https://evil.example"], body = add).status == 403
    @test req("GET", "/auth/sign-in").status == 404
    close(kb)

    # What the site is built from: a page of the content edited changes it; what builds write does not.
    c = temp_config()
    mkpath(K.content_path(c, "pages")); write(K.content_path(c, "pages", "page.md"), "x")
    before = K.source_signature(c)
    mkpath(K.slate_dir(c)); write(joinpath(K.slate_dir(c), "out.html"), "y")
    @test K.source_signature(c) == before
    sleep(1.1); write(K.content_path(c, "pages", "page.md"), "z")
    @test K.source_signature(c) != before
end

@zset "zemi dev" begin
    # What the pages are written by: the build script and the checkout's own pages, not the pages
    # written into it or its components; and the package's code.
    pkg = mktempdir()
    docs = joinpath(pkg, "docs")
    for d in (joinpath(docs, "src", "generated"), joinpath(docs, "src", "components"), joinpath(pkg, "src")) mkpath(d) end
    write(joinpath(docs, "make.jl"), ""); write(joinpath(docs, "src", "page.md"), ""); write(joinpath(pkg, "src", "a.jl"), "")
    w = K.dev_sources(docs)
    site, code = w.site(), w.code()
    sleep(1.1)
    write(joinpath(docs, "src", "generated", "kb.md"), "written by the build"); write(joinpath(docs, "src", "components", "KBX.vue"), "")
    @test w.site() == site
    write(joinpath(docs, "src", "page.md"), "edited")
    @test w.site() > site && w.code() == code
    write(joinpath(pkg, "src", "a.jl"), "edited")
    @test w.code() > code
    # Its development server is held to its port: one taken stops it before it starts.
    port, held = K.Sockets.listenany(K.Sockets.localhost, 18500)
    try
        @test_throws "is in use" K.start_dev_server!(temp_config(); port = Int(port))
    finally
        close(held)
    end
    # The pages folder's copies of the checkout's components and theme styles become links to them.
    docs = mktempdir(); md = mktempdir()
    for d in (joinpath(docs, "src", "components"), joinpath(docs, "src", ".vitepress", "theme"), joinpath(md, "components"),
              joinpath(md, ".vitepress", "theme"))
        mkpath(d)
    end
    write(joinpath(docs, "src", "components", "KBX.vue"), "<template/>"); write(joinpath(md, "components", "KBX.vue"), "old copy")
    write(joinpath(docs, "src", ".vitepress", "theme", "overrides.css"), "a {}")
    write(joinpath(md, "components", "Theirs.vue"), "a component of the theme's own")
    K.link_sources!(docs, md)
    @test islink(joinpath(md, "components", "KBX.vue")) && read(joinpath(md, "components", "KBX.vue"), String) == "<template/>"
    @test islink(joinpath(md, ".vitepress", "theme", "overrides.css")) && !islink(joinpath(md, "components", "Theirs.vue"))
    # Linking again picks up a component added since, and leaves the links in place alone.
    write(joinpath(docs, "src", "components", "KBNew.vue"), "<template/>")
    made = lstat(joinpath(md, "components", "KBX.vue")).ctime
    sleep(1.1)
    K.link_sources!(docs, md)
    @test islink(joinpath(md, "components", "KBNew.vue")) && lstat(joinpath(md, "components", "KBX.vue")).ctime == made
    # Pages are the development server's; the API stays here, and its pages may make changes.
    sh = shared_config(base_url = "http://localhost:8800")
    kb = open_kb(temp_config(shared = sh))
    K.DEV_URL[] = "http://localhost:5173"
    try
        r = K.respond_service(kb, K.HTTP.Request("GET", "/projects#KB", ["Cookie" => "$(K.local_cookie())=$(K.local_key(kb.config))"]); shared = false)
        @test r.status == 302 && K.HTTP.header(r, "Location") == "http://localhost:5173/projects#KB"
        req(origin) = K.HTTP.Request("POST", "/api/tasks", ["Origin" => origin, "X-Zemi" => "1"])
        @test K.shared_write_allowed(sh, req("http://localhost:5173")) && K.shared_write_allowed(sh, req("http://localhost:8800"))
        @test !K.shared_write_allowed(sh, req("https://evil.example"))
        # Writing the knowledge base's pages again says which files changed: all at first, then only
        # one edited since, and a page of a removed paper as removed.
        src, pub = mktempdir(), mktempdir()
        written, removed = K.diff_site_pages!(kb, src, pub)
        @test "generated/kb/index.md" in written && isempty(removed)
        index = joinpath(src, "generated", "kb", "index.md")
        gone = joinpath(src, "generated", "kb", "papers", "gone.md")
        write(index, "edited"); mkpath(dirname(gone)); write(gone, "a removed paper")
        written, removed = K.diff_site_pages!(kb, src, pub)
        @test "generated/kb/index.md" in written && !("generated/kb/timeline.md" in written)
        @test removed == ["generated/kb/papers/gone.md"] && read(index, String) != "edited"
        # Files whose contents differ are copied; the rest are left alone.
        to = mktempdir()
        @test K.sync_files!(pub, to) > 0 && K.sync_files!(pub, to) == 0
    finally
        K.DEV_URL[] = ""
        close(kb)
    end
    @test !K.shared_write_allowed(sh, K.HTTP.Request("POST", "/api/tasks", ["Origin" => "http://localhost:5173", "X-Zemi" => "1"]))
end

@zset "old site builds are removed" begin
    # The builds that built (each with its record) are kept, the newest two and the one served; one that
    # failed goes, its leftover sources too, and one newer than them all, running still, stays.
    c = temp_config()
    b = K.builds_dir(c)
    ids = ["20261001T000000", "20261002T000000", "20261003T000000", "20261004T000000", "20261005T000000", "20261006T000000"]
    foreach(id -> (mkpath(joinpath(b, id, "1")); write(joinpath(b, id * ".log"), "")), ids)
    foreach(i -> write(joinpath(b, ids[i] * ".json"), "{}"), (1, 2, 4, 5))
    mkpath(joinpath(b, "node_modules")); mkpath(joinpath(b, ids[3] * ".docs")); mkpath(joinpath(b, ids[6] * ".docs"))
    symlink(joinpath(b, ids[1], "1"), K.current_link(c))                   # an old build is the one served
    K.prune_builds!(c)
    @test sort(filter(d -> !endswith(d, ".log") && !endswith(d, ".json"), readdir(b))) ==
          [ids[1], ids[4], ids[5], ids[6], ids[6] * ".docs", "node_modules"]
    @test !isfile(joinpath(b, ids[2] * ".log")) && !isfile(joinpath(b, ids[3] * ".log")) && isfile(joinpath(b, ids[6] * ".log"))
end

@zset "site builds a run leaves behind" begin
    c = temp_config()
    mkpath(K.builds_dir(c))
    file = K.build_pid_file(K.builds_dir(c))
    # A build records its process while it runs, and its output is logged.
    io = IOBuffer()
    @test K.run_logged(`sh -c "sleep 0.5; cat $file; echo; echo built"`, io; pid_file = file)
    log = String(take!(io))
    @test occursin("built", log) && tryparse(Int, strip(split(log, '\n')[1])) !== nothing && !isfile(file)
    # One left running by an earlier run is stopped, with what it started; a process that has since
    # taken its number is not.
    child = tempname()
    stale = run(Cmd(`bash -c "sleep 60 & echo \$! > $child; exec -a 'julia docs/make.jl' sleep 60"`; detach = true); wait = false)
    timedwait(() -> isfile(child) && !isempty(read(child, String)), 5)
    write(file, string(getpid(stale)))
    K.reap_stale_build!(c)
    alive(pid) = success(pipeline(`kill -0 $pid`; stderr = devnull))
    @test timedwait(() -> process_exited(stale), 15) == :ok && !alive(parse(Int, strip(read(child, String)))) && !isfile(file)
    other = run(`sleep 60`; wait = false)
    write(file, string(getpid(other)))
    K.reap_stale_build!(c)
    @test !process_exited(other) && !isfile(file)
    kill(other)
end

@zset "MCP through the service's Kaimon" begin
    HTTP, JSON = K.HTTP, K.JSON
    sh = shared_config(kaimon_port = 0)
    kb = open_kb(temp_config(shared = sh))
    K.ensure_roles!(kb)
    boss = K.sign_in!(kb, sh, "Campus", "b"; email = "boss@example.org", verified = true)
    K.invite!(kb, "reader@example.org"; roles = ["Reader"], by = boss)
    K.invite!(kb, "curator@example.org"; roles = ["Curator"], by = boss)
    reader = K.sign_in!(kb, sh, "Campus", "r"; email = "reader@example.org", verified = true)
    curator = K.sign_in!(kb, sh, "Campus", "c"; email = "curator@example.org", verified = true)

    # Its own directories and configuration, with a key kept from one run to the next.
    e = K.prepare_embedded(kb.config)
    cfg = JSON.parsefile(joinpath(e.config_dir, "config.json"))
    @test cfg["mode"] == "strict" && cfg["api_keys"] == [e.key] && cfg["allowed_ips"] == ["127.0.0.1", "::1"]
    @test filemode(joinpath(e.config_dir, "config.json")) & 0o077 == 0 && filemode(e.cache_dir) & 0o077 == 0
    @test K.prepare_embedded(kb.config).key == e.key
    @test K.socket_dir_fits(e.cache_dir)
    deep = K.Config(; data_dir = "/srv/" * repeat("deep/", 20))
    @test startswith(K.embedded_dirs(deep)[2], "/tmp/kbk-") && K.embedded_dirs(deep)[1] == deep.data_dir * "kaimon"
    env = K.embedded_env(e)
    @test env["KAIMON_RESTRICTED"] == "1" && env["KAIMON_CACHE_DIR"] == e.cache_dir && !haskey(env, "JULIA_LOAD_PATH")

    # One left running by an earlier run is stopped before another starts; a process that has since
    # taken its number is not.
    looks_like(port) = run(`bash -c "exec -a 'julia -m Kaimon --headless --port $port' sleep 60"`; wait = false)
    stale, other = looks_like(e.port), run(`sleep 60`; wait = false)
    sleep(0.5)
    @test K.is_embedded_kaimon(getpid(stale), e.port) && !K.is_embedded_kaimon(getpid(stale), e.port + 1)
    write(K.embedded_pid_file(e), string(getpid(stale)))
    K.reap_stale_embedded!(e)
    @test timedwait(() -> process_exited(stale), 5) == :ok && !isfile(K.embedded_pid_file(e))
    write(K.embedded_pid_file(e), string(getpid(other)))
    K.reap_stale_embedded!(e)
    @test !process_exited(other) && !isfile(K.embedded_pid_file(e))
    kill(other)

    # Each token's tools follow its permissions; the tools that read the service's disk are no one's.
    rt = K.create_token!(kb, reader; name = "claude").token
    ct = K.create_token!(kb, curator; name = "claude").token
    narrow = K.create_token!(kb, curator; name = "read only", permissions = ["read"]).token
    @test K.mcp_tools(K.token_caller(kb, rt)) == ["zemi.$t" for t in ("daily", "figure", "figures", "finding", "findings", "library", "milestones", "page", "paper", "papers", "projects", "read", "records", "references", "search",
                                                                          "similar", "status", "task", "task_diff", "task_match", "task_search", "task_status", "task_wait", "tasks")]
    @test "zemi.ingest" in K.mcp_tools(K.token_caller(kb, ct)) && "zemi.job_status" in K.mcp_tools(K.token_caller(kb, ct))
    @test K.mcp_tools(K.token_caller(kb, narrow)) == ["zemi.$t" for t in ("daily", "figure", "figures", "page", "paper", "papers", "read", "records", "references", "search", "similar", "status")]
    @test "zemi.plan" in K.mcp_tools(K.token_caller(kb, ct)) && !("zemi.plan" in K.mcp_tools(K.token_caller(kb, rt)))
    @test !any(t -> occursin(r"add_pdf|ingest_code", t), K.mcp_tools(K.local_caller()))

    # A stand-in for the service's Kaimon, which records what reaches it. Each session it opens has an
    # id of its own; ending one answers `ends[]` (Kaimon may refuse it and keep the session).
    seen = HTTP.Request[]
    opened = Ref(0)
    ends = Ref(200)
    port = 19000 + rand(0:999)
    up = HTTP.serve!("127.0.0.1", port) do r
        push!(seen, r)
        sid = HTTP.header(r, "Mcp-Session-Id", "")
        r.method == "DELETE" && return HTTP.Response(ends[])
        occursin("leaky", String(copy(r.body))) &&
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"],
                "data: " * JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "result" => Dict("content" => [Dict("type" => "text",
                    "text" => "Knowledge base at /Users/someone/.local/share/kb/kb.sqlite3\nOllama $(kb.config.ollama_url): up\n" *
                              "failed in /home/svc/src/ingest.jl:12, see http://127.0.0.1:9999/x")]))) * "\n\n")
        if occursin("slow", String(copy(r.body)))
            parts = ["data: " * JSON.json(Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("message" => "Waiting"))) * "\n\n",
                     "data: " * JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "result" => Dict("content" => [Dict("type" => "text", "text" => "done")]))) * "\n\n"]
            sent = Ref(0)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], HTTP.CallbackBody(dst -> begin
                (sent[] += 1) > 2 && return 0
                sent[] == 2 && sleep(1.5)
                d = Vector{UInt8}(parts[sent[]]); copyto!(dst, 1, d, 1, length(d)); length(d)
            end, () -> nothing))
        end
        occursin("initialize", String(copy(r.body))) &&
            return HTTP.Response(200, ["Content-Type" => "text/event-stream", "Mcp-Session-Id" => "s-$(opened[] += 1)"],
                """data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\ndata: {"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"instructions":"Use the Julia REPL."}}\n\n""")
        # Like Kaimon, it lists only the tools a request names as allowed.
        occursin("tools/list", String(copy(r.body))) && occursin("zemi.status", HTTP.header(r, "X-Kaimon-Allowed-Tools", "")) &&
            return HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => sid],
                                 """{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"zemi.status"}]}}""")
        HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => sid], """{"jsonrpc":"2.0","id":1,"result":{}}""")
    end
    stand_in = K.EmbeddedKaimon(; port, key = "kaimon_k", config_dir = e.config_dir, cache_dir = e.cache_dir)
    rpc(method; id = 1, params = Dict()) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    # An answer's body: an event stream comes as it arrives, read here in the chunks the server would write.
    function chunks(r)
        r.body isa HTTP.CallbackBody || return [String(copy(r.body))]
        out, buf = String[], Vector{UInt8}(undef, 4096)
        while (n = r.body.read_cb(buf)) > 0
            push!(out, String(buf[1:n]))
        end
        r.body.close_cb()
        return out
    end
    text(r) = join(chunks(r))
    # The body as a server reads it off the socket: bytes of its own.
    post(body; token = ct, sid = "", headers = Pair{String,String}[], upstream = stand_in) =
        K.mcp_response(kb, HTTP.Request("POST", "/mcp", [["Authorization" => "Bearer $token"]; (isempty(sid) ? [] : ["Mcp-Session-Id" => sid]); headers],
                                        Vector{UInt8}(body)); upstream)
    open_session(token) = HTTP.header(post(rpc("initialize"; params = Dict("protocolVersion" => "2025-06-18")); token), "Mcp-Session-Id")
    close_session(token, sid) = K.mcp_response(kb, HTTP.Request("DELETE", "/mcp", ["Authorization" => "Bearer $token", "Mcp-Session-Id" => sid]);
                                               upstream = stand_in)
    empty!(K.MCP_CALLERS)
    try
        @test K.mcp_response(kb, HTTP.Request("POST", "/mcp", [], rpc("tools/list")); upstream = stand_in).status == 401
        @test post(rpc("tools/list"); token = "zemi_nope").status == 401
        @test post(rpc("tools/list"); upstream = nothing).status == 503
        @test K.mcp_response(kb, HTTP.Request("GET", "/mcp", ["Authorization" => "Bearer $ct"]); upstream = stand_in).status == 405
        @test post("[1, 2]").status == 400
        @test JSON.parse(String(post(rpc("ping"; id = 7)).body)) == Dict("jsonrpc" => "2.0", "id" => 7, "result" => Dict())
        @test JSON.parse(String(post(rpc("resources/list")).body))["error"]["code"] == -32601
        @test post(JSON.json(Dict("jsonrpc" => "2.0", "method" => "notifications/progress"))).status == 202
        # Nothing but opening a session goes on without one this token's holder opened: none at all,
        # or one made up (as after a restart, when none are known), is refused before Kaimon sees it.
        @test post(rpc("tools/list")).status == 400
        @test post(rpc("tools/call"; params = Dict("name" => "zemi.task_attach", "arguments" => Dict("ref" => "X-1", "path" => "~/.ssh/id_ed25519")));
                   sid = "s-made-up").status == 404
        @test isempty(seen)                                                    # none of those reached it

        # Clients are told what the knowledge base's tools are for, not what Kaimon is.
        r = post(rpc("initialize"; params = Dict("protocolVersion" => "2025-06-18")))
        events = [JSON.parse(l[7:end]) for l in split(text(r), '\n') if startswith(l, "data: ")]
        @test length(events) == 2 && events[2]["result"]["instructions"] == K.MCP_INSTRUCTIONS
        @test events[1]["method"] == "notifications/tools/list_changed" && HTTP.header(r, "Content-Type") == "text/event-stream"
        @test JSON.parse(String(K.rewrite_messages(K.with_instructions, Vector{UInt8}("""{"id":1,"result":{"capabilities":{}}}"""),
                                                   "application/json")))["result"]["instructions"] == K.MCP_INSTRUCTIONS
        # And the service's icon and web page, in the server's details, which clients show the connection with.
        info = events[2]["result"]["serverInfo"]
        @test [i["sizes"] for i in info["icons"]] == [["64x64"], ["256x256"]] && startswith(info["icons"][1]["src"], "data:image/png;base64,")
        @test info["icons"][2]["src"] == "http://127.0.0.1:8800/apple-touch-icon.png"
        @test info["websiteUrl"] == "http://127.0.0.1:8800"
        s1 = HTTP.header(r, "Mcp-Session-Id")
        @test s1 == "s-1" && K.session_owner(s1).email == "curator@example.org"
        empty!(seen)

        # Passed on with the service's key and the caller's tools, and none of the client's credentials.
        r = post(rpc("tools/list"); sid = s1, headers = ["Origin" => "https://evil.example", "X-Kaimon-Allowed-Tools" => "ex",
                                                          "X-Kaimon-Agent-Id" => "zemi-chat-c1", "Cookie" => "kb_session=x"])
        @test r.status == 200 && HTTP.header(r, "Mcp-Session-Id") == s1
        got = only(seen)
        @test HTTP.header(got, "Authorization") == "Bearer kaimon_k" && HTTP.header(got, "Mcp-Session-Id") == s1
        @test split(HTTP.header(got, "X-Kaimon-Allowed-Tools"), ',') == K.mcp_tools(K.token_caller(kb, ct))
        @test !HTTP.hasheader(got, "Origin") && !HTTP.hasheader(got, "Cookie") && !HTTP.hasheader(got, "X-Kaimon-Agent-Id") && got.target == "/mcp"
        @test JSON.parse(String(copy(got.body)))["method"] == "tools/list"
        empty!(seen)

        # A tool's answer comes back without the serving machine's paths and service addresses.
        r = post(rpc("tools/call"; params = Dict("name" => "zemi.status", "arguments" => Dict("leaky" => true))); sid = s1)
        said = JSON.parse(text(r)[7:end])["result"]["content"][1]["text"]
        @test said == "Knowledge base at [path]\nOllama [embedding service]: up\nfailed in [path], see [local service]"
        empty!(seen)

        # A tool's progress reaches the client while it runs, ahead of its answer.
        t0 = time()
        r = post(rpc("tools/call"; params = Dict("name" => "zemi.task_wait", "arguments" => Dict("slow" => true))); sid = s1)
        @test time() - t0 < 1.0
        got = chunks(r)
        @test occursin("notifications/progress", first(got)) && occursin("\"done\"", last(got)) && length(got) == 2
        empty!(seen)

        # A session is its opener's token's: the tools learn from it whom an agent works for (nothing
        # in the call says), and another token, even of the same person, cannot use it.
        post(rpc("tools/call"; params = Dict("name" => "zemi.plan", "arguments" => Dict("project" => "X", "title" => "t"))); sid = s1)
        @test !haskey(JSON.parse(String(copy(only(seen).body)))["params"]["arguments"], "by")
        empty!(seen)
        @test post(rpc("tools/list"); token = rt, sid = s1).status == 404 && isempty(seen)
        @test post(rpc("tools/list"); token = narrow, sid = s1).status == 404 && isempty(seen)
        task_local_storage(:gate_caller, s1) do
            @test K.mcp_person() == "curator@example.org"
        end
        # Ending a session Kaimon keeps leaves it its opener's; one Kaimon ends is forgotten.
        ends[] = 405
        close_session(ct, s1)
        @test K.session_owner(s1).email == "curator@example.org"
        ends[] = 200
        close_session(ct, s1)
        @test !haskey(K.MCP_CALLERS, s1)
        @test post(rpc("tools/list"); sid = s1).status == 404
        empty!(seen)

        # A call to a tool the token does not allow stops here; both are in the audit log.
        sr = open_session(rt)
        empty!(seen)
        r = post(rpc("tools/call"; params = Dict("name" => "zemi_ingest", "arguments" => Dict())); token = rt, sid = sr)
        @test occursin("not among your tools", JSON.parse(String(r.body))["error"]["message"]) && isempty(seen)
        @test post(rpc("tools/call"; params = Dict("name" => "zemi.search", "arguments" => Dict())); token = rt, sid = sr).status == 200
        @test length(seen) == 1
        log = filter(a -> a.action == "mcp.tool", K.audit_log(kb))
        @test [(a.target, a.detail["allowed"]) for a in log][1:2] == [("zemi.search", true), ("zemi_ingest", false)]

        # Kaimon serves the tools once a session it opens lists them.
        @test K.serves_tools(stand_in)
        empty!(seen)

        # Reached through the service, in shared mode only, once its Kaimon serves the tools; while the
        # service starts, a call waits for it rather than being refused.
        K.EMBEDDED[] = stand_in
        @test K.respond_shared(kb, HTTP.Request("POST", "/mcp", ["Authorization" => "Bearer $rt", "Mcp-Session-Id" => sr], rpc("tools/list"))).status == 503
        K.STARTING[] = true
        waiting = Threads.@spawn K.respond_shared(kb, HTTP.Request("POST", "/mcp", ["Authorization" => "Bearer $rt", "Mcp-Session-Id" => sr], rpc("tools/list")))
        sleep(1)
        @test !istaskdone(waiting)
        K.MCP_SERVING[] = true; K.STARTING[] = false
        @test fetch(waiting).status == 200
        @test K.respond_shared(kb, HTTP.Request("POST", "/mcp", ["Authorization" => "Bearer $rt", "Mcp-Session-Id" => sr], rpc("tools/list"))).status == 200
        @test K.respond_service(kb, HTTP.Request("POST", "/mcp", ["Cookie" => "$(K.local_cookie())=$(K.local_key(kb.config))"], rpc("tools/list")); shared = false).status == 405
    finally
        K.EMBEDDED[] = nothing
        K.MCP_SERVING[] = false; K.STARTING[] = false
        close(up)
        close(kb)
        # A temporary data directory's path is too long for sockets, so its cache went to /tmp.
        startswith(e.cache_dir, "/tmp/kbk-") && rm(e.cache_dir; recursive = true, force = true)
    end
end

@zset "OAuth for MCP clients" begin
    HTTP = K.HTTP
    kb = open_kb(temp_config(; shared = shared_config()))
    K.ensure_roles!(kb)
    sh = kb.config.shared
    boss = K.sign_in!(kb, sh, "Campus", "u1"; email = "boss@example.org", verified = true, name = "The Boss")
    serve(method, target; headers = Pair{String,String}[], body = "") =
        K.respond_service(kb, HTTP.Request(method, target, headers, body); shared = true)
    js(r) = K.JSON.parse(String(r.body))
    location(r) = HTTP.header(r, "Location")
    # Discovery: /mcp says where to learn how to sign in, and that names the endpoints.
    r = serve("POST", "/mcp")
    @test r.status == 401 &&
          occursin("resource_metadata=\"http://127.0.0.1:8800/.well-known/oauth-protected-resource/mcp\"", HTTP.header(r, "WWW-Authenticate"))
    @test js(serve("GET", "/.well-known/oauth-protected-resource/mcp"))["authorization_servers"] == ["http://127.0.0.1:8800"]
    meta = js(serve("GET", "/.well-known/oauth-authorization-server"))
    @test meta["token_endpoint"] == "http://127.0.0.1:8800/oauth/token" && meta["code_challenge_methods_supported"] == ["S256"]
    # A client registers its addresses: https to the MCP clients people connect, or http back to this
    # machine. Anyone may register one and name it anything, so no other site gets codes.
    @test serve("POST", "/oauth/register"; body = K.JSON.json(Dict("redirect_uris" => ["http://elsewhere.example/cb"]))).status == 400
    @test serve("POST", "/oauth/register"; body = K.JSON.json(Dict("client_name" => "Claude",
                                                                  "redirect_uris" => ["https://elsewhere.example/cb"]))).status == 400
    @test serve("POST", "/oauth/register"; body = K.JSON.json(Dict("redirect_uris" => ["http://localhost:4567/callback"]))).status == 201
    back = "https://claude.ai/api/mcp/auth_callback"
    reg = serve("POST", "/oauth/register"; body = K.JSON.json(Dict("client_name" => "Claude", "redirect_uris" => [back])))
    @test reg.status == 201
    client = js(reg)["client_id"]
    verifier = "a-verifier-long-enough-for-pkce-0123456789abcdef"
    P = ["response_type" => "code", "client_id" => client, "redirect_uri" => back, "state" => "s1",
         "code_challenge" => K.pkce_challenge(verifier), "code_challenge_method" => "S256"]
    q = HTTP.escapeuri(P)
    @test serve("GET", "/oauth/authorize?" * HTTP.escapeuri([P[1:2]; "redirect_uri" => "https://elsewhere.example/cb"])).status == 400
    @test startswith(location(serve("GET", "/oauth/authorize?" * HTTP.escapeuri([P[1:4]; "code_challenge" => "x"]))), "$back?error=invalid_request")
    # Signed out: to signing in, and back here after.
    r = serve("GET", "/oauth/authorize?$q")
    @test r.status == 302 && startswith(location(r), "/auth/sign-in?return_to=%2Foauth%2Fauthorize")
    # Signed in: the page to approve it, which alone can approve it.
    ck = ["Cookie" => "kb_session=$(K.start_session!(kb, boss, sh))"]
    page = String(serve("GET", "/oauth/authorize?$q"; headers = ck).body)
    @test occursin("Connect Claude", page) && occursin("The Boss", page) && occursin(r"sent back to\s+<b>claude.ai</b>", page)
    # Not while viewing as someone: a client connected then would act for them.
    viewing = K.start_session!(kb, boss, sh)
    K.view_as!(kb, viewing, K.add_test_account!(kb, "Test Reader"; roles = ["Reader"]); caller = K.session_caller(kb, viewing))
    r = serve("GET", "/oauth/authorize?$q"; headers = ["Cookie" => "kb_session=$viewing"])
    @test r.status == 403 && occursin("Stop viewing as", String(r.body))
    r = serve("POST", "/oauth/authorize"; headers = ["Cookie" => "kb_session=$viewing", "Content-Type" => "application/x-www-form-urlencoded"],
              body = HTTP.escapeuri([P; "decision" => "allow"]))
    @test r.status == 403 && occursin("Stop viewing as", String(r.body))
    key = match(r"name=\"form_key\" value=\"([^\"]+)\"", page)[1]
    post(extra...) = serve("POST", "/oauth/authorize"; headers = [ck; "Content-Type" => "application/x-www-form-urlencoded"],
                           body = HTTP.escapeuri([P; collect(extra)]))
    @test post("form_key" => "forged", "decision" => "allow").status == 403
    @test location(post("form_key" => key, "decision" => "deny")) == "$back?error=access_denied&state=s1"
    r = post("form_key" => key, "decision" => "allow")
    code = HTTP.queryparams(HTTP.URI(location(r)))["code"]
    @test startswith(location(r), back) && HTTP.queryparams(HTTP.URI(location(r)))["state"] == "s1"
    # The code, with its verifier, for a token acting for the person; good once.
    token(form) = serve("POST", "/oauth/token"; headers = ["Content-Type" => "application/x-www-form-urlencoded"], body = HTTP.escapeuri(form))
    exchange = ["grant_type" => "authorization_code", "code" => code, "client_id" => client, "redirect_uri" => back]
    bad = token([exchange; "code_verifier" => "wrong"])
    @test bad.status == 400 && js(bad)["error"] == "invalid_grant"
    code = HTTP.queryparams(HTTP.URI(location(post("form_key" => key, "decision" => "allow"))))["code"]
    exchange[2] = "code" => code
    got = js(token([exchange; "code_verifier" => verifier]))
    @test got["token_type"] == "Bearer" && got["expires_in"] == 3600
    @test token([exchange; "code_verifier" => verifier]).status == 400                       # the code is used
    @test K.token_caller(kb, got["access_token"]; mcp = true).user_id == boss
    @test serve("POST", "/mcp"; headers = ["Authorization" => "Bearer $(got["access_token"])"]).status == 503   # past the sign-in; no Kaimon here
    # It is for /mcp: the rest of the API does not take it, whatever its holder may do.
    @test K.token_caller(kb, got["access_token"]) === K.ANONYMOUS
    @test serve("GET", "/api/admin/users"; headers = ["Authorization" => "Bearer $(got["access_token"])"]).status == 401
    t = only(filter(t -> t.name == "Claude (connected)", K.tokens(kb; uid = boss)))
    # Refreshing replaces both secrets; the old ones stop working.
    again = js(token(["grant_type" => "refresh_token", "refresh_token" => got["refresh_token"], "client_id" => client]))
    @test K.token_caller(kb, again["access_token"]; mcp = true).user_id == boss && K.token_caller(kb, got["access_token"]; mcp = true) === K.ANONYMOUS
    @test token(["grant_type" => "refresh_token", "refresh_token" => got["refresh_token"], "client_id" => client]).status == 400
    @test length(filter(t -> t.name == "Claude (connected)", K.tokens(kb; uid = boss))) == 1     # still one connection
    # Revoked under the person's tokens: no more refreshing.
    K.revoke_token!(kb, t.id)
    @test js(token(["grant_type" => "refresh_token", "refresh_token" => again["refresh_token"], "client_id" => client]))["error"] == "invalid_grant"
    close(kb)
end

@zset "signing in on this machine, for trying the service" begin
    HTTP = K.HTTP
    kb = open_kb(temp_config())
    K.ensure_roles!(kb)
    sh = shared_config()                                         # base_url on 127.0.0.1, boss@example.org an admin
    page() = String(K.auth_response(kb, sh, HTTP.Request("GET", "/auth/sign-in"), ["auth", "sign-in"], Dict()).body)
    local_(email; origin = sh.base_url, headers = ["Host" => "127.0.0.1:8800"]) = K.auth_response(kb, sh,
        HTTP.Request("POST", "/auth/local", ["Origin" => origin, "Content-Type" => "application/x-www-form-urlencoded", headers...],
                     "email=$(HTTP.escapeuri(email))&name=Boss&return_to=%2Fprojects"), ["auth", "local"], Dict())
    try
        # Off unless asked for: no form, and nothing answers it.
        @test !occursin("/auth/local", page()) && local_("boss@example.org").status == 404
        K.LOCAL_SIGN_IN[] = true
        @test occursin("action=\"/auth/local\"", page())
        # What it says of who may sign in follows sign-up.
        @test occursin("sign in as anyone invited, or an admin", page()) && occursin("Invitation only.", page())
        opened = string(K.sign_in_page(shared_config(sign_up = :open, default_role = "Reader")))
        @test occursin("sign in as anyone.", opened) && !occursin("Invitation only", opened)
        r = local_("boss@example.org")
        @test r.status == 302 && HTTP.header(r, "Location") == "/projects" && occursin(K.SESSION_COOKIE, HTTP.header(r, "Set-Cookie"))
        @test K.user_roles(kb, only(K.users(kb)).id) == ["Admin"]
        # Invitations still decide who may come in, and the form must be the site's own.
        @test local_("stranger@example.org").status == 400 && length(K.users(kb)) == 1
        @test local_("boss@example.org"; origin = "https://elsewhere.example").status == 403
        # Nor through a proxy, which names whom it forwards for or the public name it was asked for.
        @test local_("boss@example.org"; headers = ["Host" => "127.0.0.1:8800", "X-Forwarded-For" => "203.0.113.9"]).status == 403
        @test local_("boss@example.org"; headers = ["Host" => "127.0.0.1:8800", "Via" => "1.1 Caddy"]).status == 403
        @test local_("boss@example.org"; headers = ["Host" => "kb.example.org"]).status == 403
        # Only for a service on this machine.
        @test K.local_sign_in_problem(sh) == ""
        # With it on, the service is at localhost on its port however often the config is read again.
        @test K.shared_config(Dict{String,Any}("port" => 8811)).base_url == "http://localhost:8811"
        @test occursin("not on localhost", K.local_sign_in_problem(shared_config(base_url = "https://kb.example.org")))
        @test occursin("not this machine only", K.local_sign_in_problem(shared_config(host = "0.0.0.0")))
        @test !K.local_sign_in(shared_config(base_url = "https://kb.example.org"))
        K.LOCAL_SIGN_IN[] = false
        @test K.shared_config(Dict{String,Any}()).base_url == ""
        K.LOCAL_SIGN_IN[] = true
        # With no admin named, the first to sign in is one; the next needs an invitation.
        fresh = open_kb(temp_config()); K.ensure_roles!(fresh)
        none = shared_config(admins = String[])
        post(email) = K.auth_response(fresh, none, HTTP.Request("POST", "/auth/local", ["Origin" => none.base_url, "Host" => "localhost:8800"],
                                                                "email=$(HTTP.escapeuri(email))"), ["auth", "local"], Dict()).status
        @test post("first@example.org") == 302 && K.user_roles(fresh, only(K.users(fresh)).id) == ["Admin"]
        @test post("second@example.org") == 400
        close(fresh)
    finally
        K.LOCAL_SIGN_IN[] = false
        close(kb)
    end
end
