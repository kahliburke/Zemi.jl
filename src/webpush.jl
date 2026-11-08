# Web Push (RFC 8030): notifications sent to people's browsers and phones through the push service
# each browser names. The service signs what it sends with a key of its own (VAPID, RFC 8292), so a
# push service knows the sends are the service's, and encrypts each message for the one device it is
# for (RFC 8291), so the push service relays only ciphertext. The cryptography is OpenSSL's.

migration!(14, [
    """CREATE TABLE push_devices (
        id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        endpoint TEXT NOT NULL UNIQUE,
        p256dh TEXT NOT NULL,
        auth TEXT NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        last_sent TEXT,
        failures INTEGER NOT NULL DEFAULT 0)""",
    "CREATE INDEX push_devices_user ON push_devices (user_id)",
    # What each person is notified of, and what the notifier last saw waiting on them (see notify.jl).
    """CREATE TABLE notify_people (
        user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        sections TEXT,
        seen TEXT,
        pending TEXT NOT NULL DEFAULT '[]',
        pending_since TEXT)""",
])

b64url(x) = rstrip(replace(base64encode(x), '+' => '-', '/' => '_'), '=')
function unb64url(s::AbstractString)
    t = replace(strip(s), '-' => '+', '_' => '/')
    return base64decode(t * "="^mod(-length(t), 4))
end

# ── OpenSSL ───────────────────────────────────────────────────────────────────────────────────────

"An OpenSSL key (`EVP_PKEY`), freed with it."
mutable struct PKey
    ptr::Ptr{Cvoid}
    function PKey(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("OpenSSL could not make the key")
        return finalizer(k -> ccall((:EVP_PKEY_free, libcrypto), Cvoid, (Ptr{Cvoid},), k.ptr), new(ptr))
    end
end

ossl(ok::Integer, what::AbstractString) = ok == 1 ? nothing : error("OpenSSL: $what failed")

"A new P-256 key."
function p256_key()
    ctx = ccall((:EVP_PKEY_CTX_new_from_name, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}), C_NULL, "EC", C_NULL)
    try
        ossl(ccall((:EVP_PKEY_keygen_init, libcrypto), Cint, (Ptr{Cvoid},), ctx), "keygen_init")
        ossl(ccall((:EVP_PKEY_CTX_set_group_name, libcrypto), Cint, (Ptr{Cvoid}, Cstring), ctx, "P-256"), "set_group_name")
        out = Ref{Ptr{Cvoid}}(C_NULL)
        ossl(ccall((:EVP_PKEY_keygen, libcrypto), Cint, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), ctx, out), "keygen")
        return PKey(out[])
    finally
        ccall((:EVP_PKEY_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
    end
end

# DER in and out: `i2d_*` writes through a pointer it moves on (or, given none, says how long it
# would write), `d2i_*` reads through one.
for (f, g) in ((:i2d_PUBKEY, :d2i_PUBKEY), (:i2d_PrivateKey, :d2i_AutoPrivateKey))
    @eval $f(key::PKey, pp) = ccall(($(QuoteNode(f)), libcrypto), Cint, (Ptr{Cvoid}, Ptr{Ptr{UInt8}}), key.ptr, pp)
    @eval $g(pp, n) = ccall(($(QuoteNode(g)), libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Clong), C_NULL, pp, n)
end
function to_der(i2d, key::PKey)
    n = i2d(key, C_NULL)
    n > 0 || error("OpenSSL: $i2d failed")
    buf = Vector{UInt8}(undef, n)
    GC.@preserve buf i2d(key, Ref(pointer(buf)))
    return buf
end
function from_der(d2i, der::Vector{UInt8})
    return GC.@preserve der PKey(d2i(Ref(pointer(der)), length(der)))
end

# A P-256 public key's SubjectPublicKeyInfo, up to the point itself.
const P256_SPKI = hex2bytes("3059301306072a8648ce3d020106082a8648ce3d030107034200")

"A P-256 key's public point, uncompressed (65 bytes), as Web Push names keys."
public_point(key::PKey) = (der = to_der(i2d_PUBKEY, key); der[1:length(P256_SPKI)] == P256_SPKI || error("Not a P-256 key"); der[end-64:end])
"The public key at `point` (65 bytes, uncompressed)."
public_key(point::Vector{UInt8}) = (length(point) == 65 && point[1] == 0x04 || error("Not an uncompressed P-256 point"); from_der(d2i_PUBKEY, [P256_SPKI; point]))
"The private key of scalar `d` and public point `point` (as RFC 8291's test vectors give them)."
private_key(d::Vector{UInt8}, point::Vector{UInt8}) =
    from_der(d2i_AutoPrivateKey, [hex2bytes("30770201010420"); d; hex2bytes("a00a06082a8648ce3d030107a144034200"); point])

"The secret `mine` and `theirs` share (ECDH)."
function ecdh(mine::PKey, theirs::PKey)
    ctx = ccall((:EVP_PKEY_CTX_new, libcrypto), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), mine.ptr, C_NULL)
    try
        ossl(ccall((:EVP_PKEY_derive_init, libcrypto), Cint, (Ptr{Cvoid},), ctx), "derive_init")
        ossl(ccall((:EVP_PKEY_derive_set_peer, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), ctx, theirs.ptr), "derive_set_peer")
        n = Ref{Csize_t}(0)
        ossl(ccall((:EVP_PKEY_derive, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}), ctx, C_NULL, n), "derive")
        out = Vector{UInt8}(undef, n[])
        ossl(ccall((:EVP_PKEY_derive, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}), ctx, out, n), "derive")
        return resize!(out, n[])
    finally
        ccall((:EVP_PKEY_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
    end
end

"`data` signed with `key` by ECDSA over SHA-256, as JWTs carry it: r and s, 32 bytes each."
function es256(key::PKey, data::Vector{UInt8})
    md = ccall((:EVP_MD_CTX_new, libcrypto), Ptr{Cvoid}, ())
    der = try
        sha = ccall((:EVP_sha256, libcrypto), Ptr{Cvoid}, ())
        ossl(ccall((:EVP_DigestSignInit, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                   md, C_NULL, sha, C_NULL, key.ptr), "DigestSignInit")
        n = Ref{Csize_t}(0)
        ossl(ccall((:EVP_DigestSign, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), md, C_NULL, n, data, length(data)), "DigestSign")
        sig = Vector{UInt8}(undef, n[])
        ossl(ccall((:EVP_DigestSign, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Csize_t}, Ptr{UInt8}, Csize_t), md, sig, n, data, length(data)), "DigestSign")
        resize!(sig, n[])
    finally
        ccall((:EVP_MD_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), md)
    end
    # SEQUENCE { INTEGER r, INTEGER s }, each integer as short as it goes and signed.
    der[1] == 0x30 || error("Not a DER signature")
    i, out = 3, UInt8[]
    for _ in 1:2
        der[i] == 0x02 || error("Not a DER signature")
        n = Int(der[i+1])
        v = der[i+2:i+1+n]
        while length(v) > 32 && v[1] == 0x00
            popfirst!(v)
        end
        append!(out, zeros(UInt8, 32 - length(v)), v)
        i += 2 + n
    end
    return out
end

"`plain` encrypted with AES-128-GCM under `key` and `iv`, its 16-byte tag after it."
function aes128gcm(key::Vector{UInt8}, iv::Vector{UInt8}, plain::Vector{UInt8})
    ctx = ccall((:EVP_CIPHER_CTX_new, libcrypto), Ptr{Cvoid}, ())
    try
        cipher = ccall((:EVP_aes_128_gcm, libcrypto), Ptr{Cvoid}, ())
        ossl(ccall((:EVP_EncryptInit_ex, libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}),
                   ctx, cipher, C_NULL, key, iv), "EncryptInit")
        out = Vector{UInt8}(undef, length(plain) + 32)
        n = Ref{Cint}(0)
        ossl(ccall((:EVP_EncryptUpdate, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}, Ptr{UInt8}, Cint),
                   ctx, out, n, plain, length(plain)), "EncryptUpdate")
        total = Int(n[])
        GC.@preserve out ossl(ccall((:EVP_EncryptFinal_ex, libcrypto), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ref{Cint}),
                                    ctx, pointer(out, total + 1), n), "EncryptFinal")
        total += n[]
        tag = Vector{UInt8}(undef, 16)
        ossl(ccall((:EVP_CIPHER_CTX_ctrl, libcrypto), Cint, (Ptr{Cvoid}, Cint, Cint, Ptr{UInt8}), ctx, 0x10, 16, tag), "GET_TAG")
        return [out[1:total]; tag]
    finally
        ccall((:EVP_CIPHER_CTX_free, libcrypto), Cvoid, (Ptr{Cvoid},), ctx)
    end
end

# ── RFC 8291 and RFC 8292 ────────────────────────────────────────────────────────────────────────

"""
    push_encrypt(payload, ua_public, auth; sender = p256_key(), salt = 16 random bytes) -> Vector{UInt8}

`payload` encrypted for the device whose subscription gave `ua_public` (its `p256dh`) and `auth`, as
the body of a push (`aes128gcm`, one record): the salt, the record size and `sender`'s public point,
then the ciphertext. A new `sender` key and salt for every message.
"""
function push_encrypt(payload::Vector{UInt8}, ua_public::Vector{UInt8}, auth::Vector{UInt8};
                      sender::PKey = p256_key(), salt::Vector{UInt8} = rand(Random.RandomDevice(), UInt8, 16))
    as_public = public_point(sender)
    secret = ecdh(sender, public_key(ua_public))
    ikm = hmac_sha256(hmac_sha256(auth, secret), [Vector{UInt8}("WebPush: info\0"); ua_public; as_public; 0x01])
    prk = hmac_sha256(salt, ikm)
    cek = hmac_sha256(prk, [Vector{UInt8}("Content-Encoding: aes128gcm\0"); 0x01])[1:16]
    nonce = hmac_sha256(prk, [Vector{UInt8}("Content-Encoding: nonce\0"); 0x01])[1:12]
    return [salt; 0x00; 0x00; 0x10; 0x00; UInt8(65); as_public; aes128gcm(cek, nonce, [payload; 0x02])]
end

"""
    vapid(key, endpoint; subject, at = time()) -> String

The `Authorization` header that tells the push service at `endpoint` the push comes from the holder
of `key`: a JWT for the endpoint's origin, good for 12 hours, naming `subject` as whom to contact.
"""
function vapid(key::PKey, endpoint::AbstractString; subject::AbstractString, at::Real = time())
    u = HTTP.URI(endpoint)
    aud = "$(u.scheme)://$(u.host)" * (isempty(u.port) ? "" : ":$(u.port)")
    head = b64url(JSON.json(Dict("typ" => "JWT", "alg" => "ES256")))
    claims = b64url(JSON.json(Dict("aud" => aud, "exp" => round(Int, at) + 12 * 3600, "sub" => subject)))
    signing = "$head.$claims"
    return "vapid t=$signing.$(b64url(es256(key, Vector{UInt8}(signing)))), k=$(b64url(public_point(key)))"
end

"Where the service's push key is kept: in the data directory, so a backup keeps it with the devices that know it."
push_key_path(c::Config) = joinpath(c.data_dir, "push_key")

const PUSH_KEY = Ref{Union{Nothing,Tuple{String,PKey}}}(nothing)
const PUSH_KEY_LOCK = ReentrantLock()

"The service's push key, made the first time it is needed."
function push_key(c::Config)
    path = push_key_path(c)
    lock(PUSH_KEY_LOCK) do
        k = PUSH_KEY[]
        k !== nothing && k[1] == path && isfile(path) && return k[2]
        key = if isfile(path)
            from_der(d2i_AutoPrivateKey, base64decode(strip(read(path, String))))
        else
            mkpath(dirname(path))
            key = p256_key()
            write(path, base64encode(to_der(i2d_PrivateKey, key)))
            chmod(path, 0o600)
            key
        end
        PUSH_KEY[] = (path, key)
        return key
    end
end

"The public half of the service's push key, as browsers take it to subscribe (`applicationServerKey`)."
push_public_key(c::Config) = b64url(public_point(push_key(c)))

"""
The push services the service sends to, by the end of their host names: Chrome's and Android's,
Firefox's, Safari's and Edge's. A device's endpoint is where the browser says to send, so it is
kept to these rather than letting an address name anything the service can reach.
"""
const PUSH_HOSTS = ("fcm.googleapis.com", "push.services.mozilla.com", "push.apple.com", "notify.windows.com")

"Why `endpoint` is not one to send to, or `nothing`."
function push_endpoint_problem(endpoint::AbstractString)
    u = try HTTP.URI(endpoint) catch; return "not an address" end
    u.scheme == "https" || return "not https"
    h = lowercase(u.host)
    any(s -> h == s || endswith(h, "." * s), PUSH_HOSTS) || return "not a known push service ($h)"
    return nothing
end

"Whom push services may contact about the service's pushes: its address, when it is https."
push_subject(c::Config) = (u = site_base(c); startswith(u, "https://") ? u : "mailto:zemi@localhost")

"""
    web_push(c, device, payload; ttl = 86400, urgency = "normal", post = HTTP.post) -> Int

Send `payload` (a short JSON text) to `device` (`endpoint`, `p256dh`, `auth`), returning the push
service's status: 201 when it took it, 404 or 410 when the device is gone.
"""
function web_push(c::Config, device, payload::AbstractString; ttl::Integer = 86400, urgency::AbstractString = "normal", post = HTTP.post)
    why = push_endpoint_problem(device.endpoint)
    why === nothing || error("Not sending to $(device.endpoint): $why")
    body = push_encrypt(Vector{UInt8}(payload), unb64url(device.p256dh), unb64url(device.auth))
    headers = ["Authorization" => vapid(push_key(c), device.endpoint; subject = push_subject(c)), "TTL" => string(ttl),
               "Content-Encoding" => "aes128gcm", "Content-Type" => "application/octet-stream", "Urgency" => urgency]
    r = post(device.endpoint, headers, body; status_exception = false, retry = false, request_timeout = 30, connect_timeout = 10)
    return Int(r.status)
end
