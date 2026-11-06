#!/usr/bin/env bash
# Install a knowledge base's shared service on a Debian or Ubuntu server, from this checkout:
#
#   sudo /srv/zemi/Zemi.jl/deploy/install.sh kb.example.org [name]
#
# `name` (by default `zemi`) names what is installed for it, `<name>.service` and Caddy's
# `sites/<name>.caddy`, so several knowledge bases can be served from one machine, each on its own
# host name and port.
#
# The service runs as the user who owns the checkout: a service user of its own (see
# https://kahliburke.github.io/Zemi.jl/deployment), never root and never one with sudo, since the code its members run (notebooks,
# the tutor) runs as that user. Its config is that user's ~/.config/zemi/config.toml,
# or ZEMI_CONFIG; see https://kahliburke.github.io/Zemi.jl/deployment for what it needs. Installs Caddy and Ollama if they are missing and pulls the embedding models the config's
# layers use, installs the Qdrant binary Kaimon runs for the service unless the config names a Qdrant
# of its own, then installs and starts the
# systemd service. Run again after changing the host name, the config's port or the logo.
set -euo pipefail

domain=${1:?usage: sudo deploy/install.sh <host name> [name]}
name=${2:-zemi}
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "The name is lower case letters, digits and dashes: $name" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
checkout=$(cd "$(dirname "$0")/.." && pwd)
user=$(stat -c %U "$checkout")
[ "$user" != root ] || { echo "The checkout is root's: clone it as the service's user (see https://kahliburke.github.io/Zemi.jl/deployment)." >&2; exit 1; }
if id -nG "$user" | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin|docker'; then
    echo "$user can become root (group sudo, wheel, admin or docker); the service needs a user of its own (see https://kahliburke.github.io/Zemi.jl/deployment)." >&2
    exit 1
fi
home=$(getent passwd "$user" | cut -d: -f6)
config=${ZEMI_CONFIG:-$home/.config/zemi/config.toml}
[ -f "$config" ] || { echo "No config at $config (see https://kahliburke.github.io/Zemi.jl/deployment)." >&2; exit 1; }
# Its folder holds the secrets too (service.env, key files): its user's alone.
chmod 700 "$(dirname "$config")"
as_user() { sudo -u "$user" -H env ZEMI_CONFIG="$config" "$@"; }
as_user sh -c 'command -v julia' >/dev/null || { echo "No julia on $user's path: install it as /usr/local/bin/julia (see https://kahliburke.github.io/Zemi.jl/deployment)." >&2; exit 1; }

echo "Installing the packages"
# The newest versions the compat entries allow, from an up-to-date registry: resolving alone keeps the
# versions the environment last had, even ones its compat no longer allows.
install='using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add("General"); Pkg.update(); Pkg.instantiate()'
(cd "$checkout" && as_user julia --project=app -e "$install")

# The port the service listens on, whose Qdrant it uses (Kaimon's, or its own at `qdrant_url`) and
# the embedding models its layers use, from its config.
read -r port qdrant models < <(cd "$checkout" && as_user julia --project=app -e '
    import Zemi as K
    c = K.load_config()
    c.shared.base_url == "" && error("[shared] base_url is not set in the config")
    println(c.shared.port, " ", isempty(c.qdrant_url) ? "kaimon" : "own", " ", join(unique(l.model for l in c.layers), " "))')

echo "Reading PDFs: MuPDF's mutool"
# The version papers are read with (older ones read pages and draw figures differently): the
# distribution's package where it is that new, as on Ubuntu 26.04 and Debian 14, else MuPDF's source
# built here.
mupdf=1.27.0 mupdf_sha256=ae2442416de499182d37a526c6fa2bacc7a3bed5a888d113ca04844484dfe7c6
# Whether version $1 is at least $mupdf. None (an empty version) is not.
recent() { [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$mupdf" "$1" | sort -V | head -1)" = "$mupdf" ]; }
have=$(mutool -v 2>&1 | sed -n 's/^mutool version \([0-9.]*\).*/\1/p' | head -1 || true)
if ! recent "$have"; then
    apt-get update -qq >/dev/null
    packaged=$(apt-cache policy mupdf-tools | sed -n 's/^ *Candidate: \([0-9.]*\).*/\1/p')
    if recent "$packaged"; then
        apt-get install -y -qq mupdf-tools >/dev/null
    else
        apt-get install -y -qq build-essential pkg-config >/dev/null
        src=$(mktemp -d)
        curl -fsSL -o "$src/mupdf.tar.gz" "https://mupdf.com/downloads/archive/mupdf-$mupdf-source.tar.gz"
        echo "$mupdf_sha256  $src/mupdf.tar.gz" | sha256sum -c --quiet || { echo "MuPDF's source is not the one expected." >&2; exit 1; }
        tar xzf "$src/mupdf.tar.gz" -C "$src"
        make -C "$src/mupdf-$mupdf-source" -j"$(nproc)" HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no build=release prefix=/usr/local install >/dev/null
        rm -rf "$src"
    fi
fi
# Not Zemi's: Claude Code reads a PDF too large to attach whole as its pages' images, which its Read
# tool makes with poppler's pdftoppm.
command -v pdftoppm >/dev/null || apt-get install -y -qq poppler-utils >/dev/null

echo "Codebases: git, and openssl to sign as the GitHub App"
for c in git openssl; do command -v $c >/dev/null || apt-get install -y -qq $c >/dev/null; done

if [ "$qdrant" = kaimon ]; then
    echo "Search: Qdrant, which the service has Kaimon run"
    # Kaimon starts its Qdrant only once the binary is in its environment for that; it downloads none unasked.
    (cd "$checkout" && as_user julia --project=app -e 'import Kaimon; Kaimon.managed_qdrant_installed() || run(Kaimon.qdrant_install_command())')
else
    echo "Search: the Qdrant at the config's qdrant_url"
fi

echo "Embedding: Ollama"
# Its own service, listening on this machine only; the service embeds queries and new documents with it.
# Its installer unpacks with zstd, which minimal systems lack.
if ! command -v ollama >/dev/null; then
    command -v zstd >/dev/null || apt-get install -y -qq zstd >/dev/null
    curl -fsSL https://ollama.com/install.sh | sh
fi
# Several requests at once, so a search's query is embedded beside a document being read rather than
# waiting for it to finish.
mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment=OLLAMA_NUM_PARALLEL=4\n' > /etc/systemd/system/ollama.service.d/zemi.conf
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama
for i in $(seq 1 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done
for m in $models; do ollama pull "$m"; done

echo "HTTPS: Caddy"
if ! command -v caddy >/dev/null; then
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq >/dev/null && apt-get install -y -qq caddy >/dev/null
fi
# The site goes in a file of its own, which the main Caddyfile imports; the package's placeholder site
# is replaced, and any other sites are left as they are.
mkdir -p /etc/caddy/sites
# The page Caddy shows while the service is down, somewhere Caddy can read without the service's home.
down=/var/www/$name-down
install -d -m 755 "$down"
# The knowledge base's own logo where its content has one (see `content_path`), else the package's.
logo=$(cd "$checkout" && as_user julia --project=app -e 'import Zemi as K; print(K.site_icon(K.load_config(), "logo.png"))')
# Headed with the group's own words where its config has them.
(cd "$checkout" && as_user julia --project=app -e 'import Zemi as K; write(stdout, K.down_page(K.load_config()))') > "$down/index.html"
chmod 644 "$down/index.html"
install -m 644 "$logo" "$down/logo.png"
sed -e "s|@DOMAIN@|$domain|g" -e "s|@PORT@|$port|g" -e "s|@DOWN@|$down|g" "$checkout/deploy/Caddyfile" > "/etc/caddy/sites/$name.caddy"
if grep -q '^:80 {' /etc/caddy/Caddyfile 2>/dev/null || [ ! -s /etc/caddy/Caddyfile ]; then
    echo 'import sites/*' > /etc/caddy/Caddyfile
elif ! grep -q 'import sites/\*' /etc/caddy/Caddyfile; then
    echo 'import sites/*' >> /etc/caddy/Caddyfile
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
# Started here where its package was installed without starting it.
systemctl enable caddy >/dev/null 2>&1
systemctl reload-or-restart caddy
# HTTP/3, which Caddy offers, runs over UDP: with a firewall, its port is opened beside HTTPS's.
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ufw allow 443/udp >/dev/null
fi

echo "The service: $name"
# Four fifths of the machine's memory, leaving the rest to search, the system and ssh.
memory_max=$(awk '/^MemTotal:/ { printf "%dM", $2 * 0.8 / 1024 }' /proc/meminfo)
sed -e "s|@NAME@|$name|g" -e "s|@USER@|$user|g" -e "s|@HOME@|$home|g" -e "s|@CHECKOUT@|$checkout|g" -e "s|@CONFIG@|$config|g" \
    -e "s|@MEMORY_MAX@|$memory_max|g" "$checkout/deploy/zemi.service" > "/etc/systemd/system/$name.service"
systemctl daemon-reload
systemctl enable --now "$name"
systemctl restart "$name"

echo "Done: https://$domain once the service has started (journalctl -u $name -f)."
