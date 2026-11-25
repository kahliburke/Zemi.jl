#!/usr/bin/env bash
# Installs Zemi and what it uses on macOS or Linux, for this account:
#
#   curl -fsSL https://raw.githubusercontent.com/kahliburke/Zemi.jl/main/deploy/install-personal.sh | bash
#   bash install-personal.sh                 the released Zemi
#   bash install-personal.sh BRANCH          Zemi from a branch of github.com/kahliburke/Zemi.jl
#   bash install-personal.sh ~/path/Zemi.jl  Zemi from a checkout on this machine
#
# Each part is skipped where this account already has it: Julia, Poppler's pdftoppm (Claude Code
# reads long PDFs with it), Ollama (search by meaning), Git and Claude Code (agents that summarize),
# then Kaimon and Zemi, with Kaimon set up to run Zemi: the questions of its first run answered for
# one person's machine.
# On macOS it installs through Homebrew. On Linux it uses the system's packages where sudo is allowed
# and installs into ~/.local where it is not. For a group's shared server, see deploy/install.sh.
set -euo pipefail

source=${1:-}
installed=()
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
step() { printf '\n\033[36m== %s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
found() { echo "Found $(command -v "$1")"; }
fail() { echo "$*" >&2; exit 1; }
os=$(uname -s)
case "$os" in Darwin|Linux) ;; *) fail "This installs on macOS or Linux; on Windows, run deploy/windows/install.bat." ;; esac
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.juliaup/bin:$HOME/.julia/bin:$HOME/.local/bin:$PATH"

# Commands as root on Linux: as root, through sudo without a password, or through sudo with one for
# an account in an administrators' group (asked on the terminal). Not at all otherwise.
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif have sudo && sudo -n true 2>/dev/null; then sudo "$@"
    elif have sudo && [ -r /dev/tty ] && id -nG | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then sudo "$@" </dev/tty
    else return 1
    fi
}
can_root() { as_root true 2>/dev/null; }
# Installs Debian or Ubuntu packages, reading the package lists first, once.
apt_listed=""
apt_install() {
    [ -n "$apt_listed" ] || { as_root apt-get update -qq >/dev/null && apt_listed=1; }
    as_root apt-get install -y -qq "$@" >/dev/null
}

if [ "$os" = Darwin ]; then
    have brew || [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ] ||
        fail "Zemi installs its programs on macOS through Homebrew: install it from https://brew.sh, then run this again."
    have brew || eval "$( { [ -x /opt/homebrew/bin/brew ] && /opt/homebrew/bin/brew shellenv; } || /usr/local/bin/brew shellenv)"
fi

step "Julia"
if have julia && julia --startup-file=no -e 'exit(VERSION >= v"1.12" ? 0 : 1)'; then found julia
elif have juliaup; then
    juliaup add release && juliaup default release
    installed+=("Julia $(julia --startup-file=no -e 'print(VERSION)')")
else
    # juliaup, in this account's home folder, which also puts its folder on the shells' PATH.
    curl -fsSL https://install.julialang.org | sh -s -- --yes
    installed+=("Julia $(julia --startup-file=no -e 'print(VERSION)')")
fi

step "Poppler's pdftoppm"
# Not Zemi's: Claude Code reads a PDF too large to attach whole as its pages' images, made by poppler's pdftoppm.
if ! have pdftoppm; then
    if [ "$os" = Darwin ]; then brew install poppler
    elif have apt-get && can_root; then apt_install poppler-utils
    elif have dnf && can_root; then as_root dnf install -y -q poppler-utils
    else echo "No pdftoppm (poppler): Claude Code then reads long PDFs as text only."
    fi
fi

step "Ollama"
# Where Ollama listens, as its own commands read it.
ollama_at=${OLLAMA_HOST:-127.0.0.1:11434}
case "$ollama_at" in http://*|https://*) ;; *) ollama_at="http://$ollama_at" ;; esac
ollama_up() { curl -fsS -m 2 "$ollama_at/api/version" >/dev/null 2>&1; }
if [ "$os" = Darwin ]; then
    have ollama && found ollama || { brew install ollama; installed+=("Ollama"); }
    # Served at each login by Homebrew's launch agent, unless an Ollama app already serves it.
    ollama_up || brew services start ollama
elif have ollama; then found ollama
elif can_root; then
    # Ollama's own installer: a system service, started at boot.
    have zstd || { have apt-get && apt_install zstd; } || true
    curl -fsSL https://ollama.com/install.sh | sh
    installed+=("Ollama")
else
    arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    if have zstd; then curl -fsSL "https://ollama.com/download/ollama-linux-$arch.tar.zst" | tar -x --zstd -C "$HOME/.local"
    else curl -fsSL "https://ollama.com/download/ollama-linux-$arch.tgz" | tar -xz -C "$HOME/.local"
    fi
    installed+=("Ollama")
fi
if [ "$os" = Linux ] && ! ollama_up && [ "$(command -v ollama)" = "$HOME/.local/bin/ollama" ]; then
    # This account's own Ollama, served at each login by a user service where systemd runs one.
    if systemctl --user show-environment >/dev/null 2>&1; then
        mkdir -p "$HOME/.config/systemd/user"
        printf '[Unit]\nDescription=Ollama\n\n[Service]\nExecStart=%%h/.local/bin/ollama serve\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n' \
            > "$HOME/.config/systemd/user/ollama.service"
        systemctl --user daemon-reload
        systemctl --user enable --now ollama
    else
        nohup ollama serve >"$HOME/.local/ollama.log" 2>&1 &
        echo "Ollama is running for now; start it with 'ollama serve' after you next log in."
    fi
fi
for i in $(seq 1 30); do ollama_up && break; sleep 1; done
ollama_up || fail "Ollama did not start."
# The embedding model Zemi's search uses by default, which Kaimon's code search is set to use too.
for model in qwen3-embedding:4b; do ollama pull "$model"; done

step "Git"
# Claude Code works in a repository through git, and Zemi reads codebases with it.
if have git && git --version >/dev/null 2>&1; then found git
elif [ "$os" = Darwin ]; then
    xcode-select --install 2>/dev/null || true
    fail "Git comes with Apple's command line tools: finish their install, then run this again."
elif have apt-get && can_root; then apt_install git; installed+=("Git")
elif have dnf && can_root; then as_root dnf install -y -q git; installed+=("Git")
else fail "Git is needed: ask whoever looks after this machine to install it, then run this again."
fi

step "Claude Code"
if have claude; then found claude
else
    curl -fsSL https://claude.ai/install.sh | bash
    installed+=("Claude Code")
fi

step "Kaimon and Zemi"
if [ -z "$source" ]; then zemi='Pkg.Apps.add("Zemi")'
elif [ -d "$source" ]; then zemi="Pkg.Apps.develop(path = raw\"$(cd "$source" && pwd)\")"
else zemi="Pkg.Apps.add(PackageSpec(url = \"https://github.com/kahliburke/Zemi.jl\", rev = raw\"$source\"))"
fi
printf 'using Pkg\nPkg.Apps.add("Kaimon")\n%s\n' "$zemi" > "$work/apps.jl"
julia --startup-file=no "$work/apps.jl"
installed+=("Kaimon" "Zemi")

step "Kaimon settings"
# The answers to Kaimon's first-run setup, for one person on their own machine: only this account's
# programs reach it, with no keys; it searches code through Ollama, with the model Zemi uses, and a
# Qdrant it runs; Claude Code reaches its tools, the knowledge base's among them. A Kaimon that sets
# itself up so does it; an older one is set up here. Settings already there are left as they are.
kaimon="$HOME/.julia/bin/kaimon"
if "$kaimon" --help 2>/dev/null | grep -q -- --setup-defaults; then
    "$kaimon" --setup-defaults --embedding-model qwen3-embedding:4b
else
    settings=${KAIMON_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/kaimon}/config.json
    if [ -f "$settings" ]; then echo "Found $settings"
    else
        mkdir -p "$(dirname "$settings")"
        # gate_setup_version: other Julia sessions are left alone.
        printf '{\n  "mode": "lax",\n  "api_keys": [],\n  "allowed_ips": ["127.0.0.1", "::1"],\n  "port": 2828,\n  "created_at": %s,\n  "editor": "vscode",\n  "gate_setup_version": 1\n}\n' \
            "$(date +%s)" > "$settings"
        chmod 600 "$settings"
        echo "Wrote $settings"
    fi
    # Code search through Ollama with the model Zemi uses, so one model serves both.
    search="$(dirname "$settings")/search.json"
    if [ -f "$search" ]; then echo "Found $search"
    else
        printf '{\n  "version": 1,\n  "projects": {},\n  "embedding_model": "qwen3-embedding:4b",\n  "embedding": {"backend": "ollama"}\n}\n' > "$search"
        echo "Wrote $search"
    fi
    # Qdrant, where Kaimon runs it from, installed as Kaimon installs it.
    julia --startup-file=no --project="$HOME/.julia/environments/apps/Kaimon" \
        -e 'import Kaimon; Kaimon.managed_qdrant_installed() || run(Kaimon.qdrant_install_command())'
    # Claude Code reaches Kaimon's tools, and the knowledge base's among them, at Kaimon's address: with
    # no key while Kaimon takes none from this machine's programs.
    port=$(sed -n 's/^ *"port": *\([0-9]*\).*/\1/p' "$settings" | head -1)
    if grep -q '"mode": *"lax"' "$settings" && have claude && ! claude mcp get kaimon >/dev/null 2>&1; then
        claude mcp add --scope user --transport http kaimon "http://localhost:${port:-2828}/mcp"
    fi
fi
zemi kaimon

# Julia's apps and Claude Code on the PATH of new shells (juliaup puts its own folder there).
if [ "$os" = Darwin ]; then profiles=("$HOME/.zshrc"); [ -f "$HOME/.bash_profile" ] && profiles+=("$HOME/.bash_profile")
else profiles=("$HOME/.bashrc"); [ -f "$HOME/.zshrc" ] && profiles+=("$HOME/.zshrc")
fi
for p in "${profiles[@]}"; do
    grep -qF '.julia/bin' "$p" 2>/dev/null ||
        printf '\n# Julia apps (Kaimon, Zemi) and Claude Code\nexport PATH="$HOME/.julia/bin:$HOME/.local/bin:$PATH"\n' >> "$p"
done

summary="nothing new"
[ ${#installed[@]} -gt 0 ] && summary=$(printf '%s, ' "${installed[@]}") && summary=${summary%, }
printf '\n\033[32mInstalled: %s\033[0m\n' "$summary"
cat <<'EOF'

In a new terminal, which has the PATH this set:
  claude        once, to sign in to Claude Code, for agents that summarize
  kaimon        to run Kaimon, which runs the knowledge base
EOF
