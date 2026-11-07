#!/usr/bin/env bash
# The container's start (see Dockerfile): the config, written from its ZEMI_ variables where there is
# none yet; the embedding models the config's layers use, pulled into its Ollama; where compose.yaml
# shares a folder with Caddy (/srv/zemi/caddy), Caddy's site and the page it shows while the service
# is down; then the service.
set -euo pipefail
cd /srv/zemi/Zemi.jl
dir=$(dirname "$ZEMI_CONFIG")
local_sign_in=${ZEMI_LOCAL_SIGN_IN:-}

# Started as root only to make the config folder the service's user's (a folder compose makes for a
# mount is root's), then run again as that user.
if [ "$(id -u)" = 0 ]; then
    mkdir -p "$dir" && chown -R zemi:zemi "$dir" && chmod 700 "$dir"
    exec setpriv --reuid=zemi --regid=zemi --init-groups env HOME=/srv/zemi "$0" "$@"
fi

# The first start's config, from the variables: the public address, the admins (who sign in through
# the provider with these emails) and GitHub's OAuth app, whose secret is a file in the config folder.
# From then on the file is the config, and the variables are not read.
if [ ! -f "$ZEMI_CONFIG" ]; then
    base_url=${ZEMI_BASE_URL:-}
    # Tried on one machine, the address the browser uses: the port compose.local.yaml publishes.
    [ -z "$base_url" ] && [ "$local_sign_in" = 1 ] && base_url=http://localhost:${ZEMI_LOCAL_PORT:-8800}
    [ -n "$base_url" ] || { echo "No config at $ZEMI_CONFIG: set ZEMI_BASE_URL, ZEMI_ADMINS and ZEMI_GITHUB_CLIENT_ID for a first one (see https://kahliburke.github.io/Zemi.jl/deployment)." >&2; exit 1; }
    admins=""
    IFS=, read -ra emails <<< "${ZEMI_ADMINS:-}"
    for e in "${emails[@]}"; do
        e=$(echo "$e" | tr -d '[:space:]')
        [ -z "$e" ] && continue
        [[ "$e" =~ ^[^@\"]+@[^@\"]+$ ]] || { echo "Not an email in ZEMI_ADMINS: $e" >&2; exit 1; }
        admins+="${admins:+, }\"$e\""
    done
    {
        echo "# Written at the container's first start from its ZEMI_ variables: edit it here from now on."
        echo "data_dir = \"/srv/zemi/data\""
        echo "qdrant_url = \"${ZEMI_QDRANT_URL:-http://qdrant:6333}\""
        echo "ollama_url = \"${ZEMI_OLLAMA_URL:-http://ollama:11434}\""
        echo
        echo "[shared]"
        echo "base_url = \"$base_url\""
        # Caddy reaches it from its own container; the local sign-in needs it on this one's localhost.
        [ "$local_sign_in" = 1 ] && echo "host = \"127.0.0.1\"" || echo "host = \"0.0.0.0\""
        echo "port = 8800"
        echo "admins = [$admins]"
        if [ -n "${ZEMI_GITHUB_CLIENT_ID:-}" ]; then
            echo
            echo "[[shared.providers]]"
            echo "name = \"GitHub\""
            echo "kind = \"github\""
            echo "client_id = \"$ZEMI_GITHUB_CLIENT_ID\""
            echo "client_secret = \"file:${ZEMI_GITHUB_CLIENT_SECRET_FILE:-$dir/github_oauth_secret}\""
        fi
    } > "$ZEMI_CONFIG"
    echo "Wrote a first config at $ZEMI_CONFIG"
fi

# The host name, the service's port, its Ollama and the layers' models, from the config; the down page
# and the logo, written where Caddy reads them. A public service needs a provider to sign in with.
caddy=/srv/zemi/caddy
read -r domain port ollama models < <(julia --project=app -e '
    import Zemi as K
    c = K.load_config()
    m = match(r"^https?://([^/:]+)", c.shared.base_url)
    m === nothing && error("[shared] base_url is not set in the config")
    get(ENV, "ZEMI_LOCAL_SIGN_IN", "") == "1" || !isempty(c.shared.providers) ||
        error("No sign-in provider in the config ([[shared.providers]]), so nobody could sign in: set ZEMI_GITHUB_CLIENT_ID for a first config, or add one")
    caddy = ARGS[1]
    if isdir(caddy)
        mkpath(joinpath(caddy, "down"))
        write(joinpath(caddy, "down", "index.html"), K.down_page(c))
        cp(K.site_icon(c, "logo.png"), joinpath(caddy, "down", "logo.png"); force = true)
    end
    println(m[1], " ", c.shared.port, " ", c.ollama_url, " ", join(unique(l.model for l in c.layers), " "))' "$caddy") || true
[ -n "${port:-}" ] || exit 1

if [ -d "$caddy" ]; then
    # The service as Caddy reaches it: by its name on compose's network.
    sed -e "s|@DOMAIN@|$domain|g" -e "s|127.0.0.1:@PORT@|${ZEMI_UPSTREAM:-zemi}:$port|g" -e "s|@DOWN@|$caddy/down|g" \
        deploy/Caddyfile > "$caddy/site.caddy"
fi

echo "Embedding models: $models, from $ollama"
for i in $(seq 1 30); do curl -fsS "$ollama/api/version" >/dev/null 2>&1 && break; sleep 2; done
for m in $models; do
    curl -fsS "$ollama/api/pull" -d "{\"model\": \"$m\", \"stream\": false}" >/dev/null ||
        echo "Could not pull $m from $ollama: search by meaning waits for it." >&2
done

# Tried on one machine (compose.local.yaml): the service listens on the container's own localhost, as
# the local sign-in needs, and the port published on the host's localhost reaches it through this.
if [ "$local_sign_in" = 1 ]; then
    socat TCP-LISTEN:"$port",bind="$(hostname -i | cut -d' ' -f1)",fork,reuseaddr TCP:127.0.0.1:"$port" &
fi

exec ./zemi --shared
