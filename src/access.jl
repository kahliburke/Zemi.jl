# Keys to a dataset in Cloudflare R2, one per person, so access can be given and taken back person by
# person. A key is a Cloudflare API token limited to reading (or writing) the dataset's bucket; R2's S3
# credentials come from it (the token's id is the access key id, the SHA-256 of its value the secret).
# Issuing needs a token of the publisher's own with permission to create account API tokens, saved in
# `admin_credentials`.

const CLOUDFLARE_API = Ref("https://api.cloudflare.com/client/v4")

"The Cloudflare account a dataset's R2 endpoint belongs to."
function r2_account(c::Config)
    m = match(r"^https://([0-9a-f]{32})\.r2\.cloudflarestorage\.com", c.dataset.endpoint)
    m === nothing && error("[dataset] endpoint is not an R2 endpoint (https://<account id>.r2.cloudflarestorage.com)")
    return String(m[1])
end

function cloudflare(c::Config, method::AbstractString, path::AbstractString; body = nothing, whole::Bool = false)
    file = c.dataset.admin_credentials
    isfile(file) || error("Issuing keys needs a Cloudflare API token that may create account API tokens, saved as " *
                          "api_token = \"...\" in $file")
    token = get(TOML.parsefile(file), "api_token", "")
    isempty(token) && error("$file has no api_token")
    headers = ["Authorization" => "Bearer $token", "Content-Type" => "application/json"]
    r = HTTP.request(method, CLOUDFLARE_API[] * path, headers, body === nothing ? "" : JSON.json(body);
                     status_exception = false)
    data = JSON.parse(String(r.body))
    get(data, "success", false) === true ||
        error("Cloudflare $method $path: " * join((get(e, "message", "") for e in get(data, "errors", [])), "; "))
    return whole ? data : data["result"]
end

"The stream a member named `who` publishes to: the name, lowercased, its other characters as `-`."
member_stream(who::AbstractString) = slugify(who; keep = "._-")

"The name a key is issued under: the bucket, then whose it is."
key_name(c::Config, who::AbstractString) = "$(c.dataset.bucket): $who"

"""
    issue_key(config, who; write = false) -> NamedTuple

Issue `who` a key to the dataset's bucket: read-only, or read and write with `write` (for a
publisher). Returns `(; name, token_id, access_key_id, secret_access_key)`; the secret cannot be
shown again, so save it (see [`key_file`](@ref)).
"""
function issue_key(c::Config, who::AbstractString; write::Bool = false)
    account = r2_account(c)
    issued = list_keys(c)
    any(k -> k.name == key_name(c, who), issued) && error("$who already has a key; revoke it first to issue another")
    if write
        # A publisher's name names their stream (see `key_file`), which no one else may publish to: each
        # would drop the other's documents.
        stream = member_stream(who)
        valid_stream(stream) || error("\"$who\" makes no stream name (up to 64 of a-z, 0-9, '.', '_', '-'); issue the key under a name that does")
        other = findfirst(k -> member_stream(k.name[length(key_name(c, ""))+1:end]) == stream, issued)
        other === nothing || error("$who would publish to the stream $stream, which $(issued[other].name) names too; issue the key under another name")
    end
    groups = cloudflare(c, "GET", "/accounts/$account/tokens/permission_groups")
    wanted = write ? ["Workers R2 Storage Bucket Item Read", "Workers R2 Storage Bucket Item Write"] :
                     ["Workers R2 Storage Bucket Item Read"]
    ids = [only(g["id"] for g in groups if g["name"] == n) for n in wanted]
    resource = "com.cloudflare.edge.r2.bucket.$(account)_default_$(c.dataset.bucket)"
    t = cloudflare(c, "POST", "/accounts/$account/tokens"; body = Dict("name" => key_name(c, who),
        "policies" => [Dict("effect" => "allow", "resources" => Dict(resource => "*"),
                            "permission_groups" => [Dict("id" => id) for id in ids])]))
    return (; name = key_name(c, who), token_id = String(t["id"]), access_key_id = String(t["id"]),
              secret_access_key = bytes2hex(sha256(String(t["value"]))))
end

"The keys issued to the dataset's bucket: `(; name, token_id, status)` each."
function list_keys(c::Config)
    prefix = key_name(c, "")
    # The list comes a page at a time.
    tokens, page = [], 1
    while true
        data = cloudflare(c, "GET", "/accounts/$(r2_account(c))/tokens?per_page=50&page=$page"; whole = true)
        append!(tokens, data["result"])
        info = get(data, "result_info", nothing)
        (info === nothing || page >= get(info, "total_pages", 1) || isempty(data["result"])) && break
        page += 1
    end
    return [(; name = String(t["name"]), token_id = String(t["id"]), status = String(get(t, "status", "")))
            for t in tokens if startswith(t["name"], prefix)]
end

"Revoke `who`'s key to the dataset's bucket."
function revoke_key(c::Config, who::AbstractString)
    k = [k for k in list_keys(c) if k.name == key_name(c, who)]
    isempty(k) && not_found("No key issued to $who")
    cloudflare(c, "DELETE", "/accounts/$(r2_account(c))/tokens/$(only(k).token_id)")
    return nothing
end

"How a key file names the dataset it opens: the group's, when the group has a name."
dataset_title(group::AbstractString) = isempty(group) ? "a shared knowledge base's dataset" : "the $group dataset"

"""
    key_file(config, key; write = false) -> String

A key saved as the file its holder installs with `zemi token add FILE`: the key, and where the
dataset is, which is all a consumer needs; with `write`, a publisher, also the stream they publish to,
named after them (see [`member_stream`](@ref)).
"""
function key_file(c::Config, key; write::Bool = false, who::AbstractString = "")
    order = ["name", "group", "role", "stream", "endpoint", "bucket", "prefix", "access_key_id", "secret_access_key"]
    t = Dict{String,Any}("name" => key.name, "group" => c.group.name, "role" => write ? "publish" : "consume",
                         "endpoint" => c.dataset.endpoint, "bucket" => c.dataset.bucket, "prefix" => c.dataset.prefix,
                         "access_key_id" => key.access_key_id, "secret_access_key" => key.secret_access_key)
    write && (t["stream"] = member_stream(who))
    return "# $(key.name): a key to $(dataset_title(c.group.name)). Keep it private.\n" *
           "# Install it with `zemi token add <this file>`.\n" *
           sprint(io -> TOML.print(io, t; sorted = true, by = k -> something(findfirst(==(k), order), 0)))
end

"""
    save_key(text; config_dir = <the config directory>) -> Dict

Save the key file `text` someone issued (see [`key_file`](@ref)) as `r2_read` (or `r2_publish`),
readable only by its owner, and return the `[dataset]` table that reaches the dataset with it.
"""
function save_key(text::AbstractString; config_dir = dirname(config_path()))
    k = try TOML.parse(text) catch; error("This is not a key file: it is not TOML") end
    for f in ("role", "endpoint", "bucket", "access_key_id", "secret_access_key")
        isempty(string(get(k, f, ""))) && error("This is not a key file: it has no $f")
    end
    dest = joinpath(config_dir, k["role"] == "publish" ? "r2_publish" : "r2_read")
    write_private(dest, text)
    d = Dict{String,Any}("role" => k["role"], "store" => "s3", "endpoint" => k["endpoint"], "bucket" => k["bucket"],
                         "prefix" => get(k, "prefix", "kb"), "credentials" => dest)
    haskey(k, "stream") && (d["stream"] = k["stream"])
    return d
end

"""
    install_key(file; path = config_path()) -> String

Install a key file someone issued (see [`save_key`](@ref)) beside the config `path`, and set the
dataset it reaches in the settings file, as Setup does, unless the configuration already shares one.
Returns what was done, for people.
"""
function install_key(file::AbstractString; path::AbstractString = config_path())
    d = try save_key(read(file, String); config_dir = dirname(path)) catch e; error(replace(failure_message(e), "This" => file)) end
    current = load_config(path).dataset
    if current.role != :none
        return "Saved the key as $(d["credentials"]). The configuration already shares a dataset ($(current.store)), so it was left as it is."
    end
    write_settings!(Dict{String,Any}("dataset" => d); path)
    return "Saved the key as $(d["credentials"]) and set the dataset in $(settings_path(path))."
end

"Save the Cloudflare API token that issues keys, readable only by its owner."
function save_issuer_token(token::AbstractString, c::Config)
    isempty(strip(token)) && error("No token given")
    return write_private(c.dataset.admin_credentials,
                         "# A Cloudflare API token that may create account API tokens, for zemi token.\napi_token = \"$(strip(token))\"\n")
end
