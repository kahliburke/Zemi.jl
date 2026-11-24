# Server deployment

`zemi --shared` on Debian or Ubuntu: systemd, Caddy for HTTPS, Ollama for embeddings, and Qdrant
started by the service (or one of its own). The files are in
[`deploy/`](https://github.com/kahliburke/Zemi.jl/tree/main/deploy).

## Prerequisites

**Service user.** No sudo, no login. Notebooks and the tutor run code as this user.

```sh
sudo useradd --system --create-home --home-dir /srv/zemi --shell /usr/sbin/nologin zemi
sudo -u zemi git clone https://github.com/kahliburke/Zemi.jl.git /srv/zemi/Zemi.jl
sudo -u zemi mkdir -p /srv/zemi/.config/zemi
```

**Julia 1.12+** at `/usr/local/bin/julia` (a juliaup install in someone's home won't be found):

```sh
curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-<version>-linux-x86_64.tar.gz | sudo tar -xz -C /opt
sudo ln -sf /opt/julia-<version>/bin/julia /usr/local/bin/julia
```

On ARM, `aarch64` in place of `x64` and `x86_64`.

**Qdrant.** The service has Kaimon run one, unless the config names its own with `qdrant_url` and
`qdrant_key` (a file reference). Kaimon has no Qdrant for ARM Linux: there, run
[Qdrant's release](https://github.com/qdrant/qdrant/releases) (`aarch64-unknown-linux-musl`) as a
service of its own on `127.0.0.1`, with an API key.

**DNS and ports.** A host name pointing at the server, ports 80 and 443 open. Caddy gets and renews
the certificate.

**Sign-in.** For GitHub, an OAuth app with callback `https://<host>/auth/callback/github`. For
Google, in the Google Cloud console under APIs & Services: an OAuth consent screen (External, then
published, or only its test users can sign in; its privacy policy is `https://<host>/privacy`, which
the service shows to anyone) and a Web application client with redirect URI
`https://<host>/auth/callback/google`. Each provider's callback ends with its `name`, lowercased,
other characters as `-` ("Campus Login": `/auth/callback/campus-login`).

**Config** at `/srv/zemi/.config/zemi/config.toml`, secrets in files readable only by `zemi`:

```toml
data_dir = "/srv/zemi/data"

[shared]
base_url = "https://kb.example.org"
port = 8800
admins = ["you@example.org"]          # admins whenever they sign in (see The first sign-in)
# sign_up = "open"                    # default "invite"
# session_days = 14                   # how long a sign-in lasts
# trusted_proxies = ["127.0.0.1", "::1"]   # whose X-Forwarded-* headers are believed

[[shared.providers]]
name = "GitHub"
kind = "github"
client_id = "Ov23…"
client_secret = "file:/srv/zemi/.config/zemi/github_oauth_secret"

[[shared.providers]]                   # optional: Google
name = "Google"
issuer = "https://accounts.google.com"
client_id = "….apps.googleusercontent.com"
client_secret = "file:/srv/zemi/.config/zemi/google_oauth_secret"

[[shared.providers]]                   # optional: any other OpenID Connect provider
name = "Campus"
issuer = "https://login.example.org"
client_id = "…"
client_secret = "file:/srv/zemi/.config/zemi/campus_secret"
# email_verified = true                # its tokens don't say, and its emails are its own records

[shared.github_app]                    # optional: private codebase repositories
client_id = "Iv23…"
private_key = "/srv/zemi/.config/zemi/github_app.pem"

[media.backup]                         # optional: copy attachments to a bucket
store = "s3"
endpoint = "https://<account>.r2.cloudflarestorage.com"
bucket = "kb-files"
credentials = "/srv/zemi/.config/zemi/files_key"
```

**GitHub App** (only for private codebases): *Contents: Read-only*, no webhook, private key at the
path above, installed on the repositories. Link a project with
`project_codebase(project, "https://github.com/owner/repo")`. A repository the service hasn't read yet
is cloned with the service's credentials, so adding one takes `paper.add`. A folder on the server, such
as a checkout kept there, is read in place and added only by someone with `config.edit`. A codebase the App reads is
shown only to the members of the projects linked to it (see [Serving](serving.md)).

**Claude Code** for the service's agents, with its token in `service.env`:

```sh
sudo -u zemi -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
sudo -u zemi -H /srv/zemi/.local/bin/claude setup-token     # prints a token
sudo -u zemi -H bash -c 'umask 077; read -rsp "Token: " t; echo; printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$t" > ~/.config/zemi/service.env'
```

`ANTHROPIC_API_KEY=…` works instead.

**Summarizers.** The default summarizer, `deepseek-v4.1-flash`, needs an OpenCode Zen key: type it
with the model on the Configuration page (saved as `opencode_key` beside the config), or install
[OpenCode](https://opencode.ai) as `zemi` and run `opencode auth login`, or put the key in
`service.env` as `OPENCODE_API_KEY=…`. To summarize with
the Claude token instead, set `summarizer = "opus-agent-pdf"` and `code_summarizer =
"opus-agent-code"` in the config (see [Models](models.md)).

## Install

```sh
sudo /srv/zemi/Zemi.jl/deploy/install.sh kb.example.org [name] --admin you@example.org
```

Installs the Julia packages, Ollama and the embedding models, Caddy (site in
`/etc/caddy/sites/<name>.caddy`), and `<name>.service` (default `zemi`). Refuses to run the service
as a user who can become root. Several knowledge bases can share a machine, each with its own `name`,
user, config, host, `[shared] port`, `[shared] kaimon_port` (default 2829) and `collection_prefix`
(default `"zemi"`; they share one Qdrant). While the service is down or starting, Caddy shows a page
with the logo and `[group] restarting` (default "Back in a moment"). Rerun after changing the host,
port, logo or that line.

To move an existing knowledge base in, stop the service, copy its data folder to `data_dir`, and
start it. Vectors live in Qdrant, not the data folder, so a sync re-embeds the papers (Ollama must
be running).

## Operation

- Logs: `journalctl -u <name> -f` (also `-u caddy`, `-u ollama`).
- Update: `sudo -u zemi -H git -C /srv/zemi/Zemi.jl pull`, then `sudo systemctl restart <name>`.
- The service listens on `127.0.0.1` only and writes only under `/srv/zemi`.
- Linked codebases whose files changed are read again each night at `[shared] nightly_ingest`
  (default `"02:00"`, in `timezone`, default UTC); `""` turns it off.
- `MemoryMax` is 80% of RAM. Site builds use up to a 12 GB Node heap: 32 GB of RAM is comfortable,
  16 GB can stop a large build. Lower `MemoryMax` when several services share a machine.

## Backups

The service snapshots itself every hour into `/srv/zemi/data.backups` (see
[Configuration](configuration.md#backups)); its agents can't read them. A `[backup] dir` elsewhere
needs adding to `ReadWritePaths` in the service's unit.

```sh
sudo -u zemi env ZEMI_CONFIG=/srv/zemi/.config/zemi/config.toml /srv/zemi/Zemi.jl/zemi backups
sudo -u zemi env ZEMI_CONFIG=/srv/zemi/.config/zemi/config.toml /srv/zemi/Zemi.jl/zemi backup --keep before-upgrade
```

To restore one, stop the service, restore, and start it:

```sh
sudo systemctl stop zemi
sudo -u zemi env ZEMI_CONFIG=/srv/zemi/.config/zemi/config.toml /srv/zemi/Zemi.jl/zemi restore 20261108T010000Z
sudo systemctl start zemi
```

Restoring puts back the database, the content, the records and the files, as they were. What was
there is first kept as the snapshot `before-restore-<time>`, so a restore can be undone the same way.
`--config` puts back the config folder's files too.

## In containers

`deploy/compose.yaml` runs the service with Qdrant, Ollama and Caddy, in place of `install.sh`. From
the checkout, with Docker and its compose plugin:

```sh
ZEMI_BASE_URL=https://kb.example.org ZEMI_ADMINS=you@example.org ZEMI_GITHUB_CLIENT_ID=Ov23… \
    docker compose -f deploy/compose.yaml up -d --build
```

The first start writes the config at `deploy/config/config.toml` from these variables; from then on
the file is the config. Put the GitHub app's secret in `deploy/config/github_oauth_secret` before
starting. The folder belongs to the container's user (uid 10001), so edit it with `sudo`.

The default summarizer's key, `OPENCODE_API_KEY=…`, goes in `deploy/service.env`, which compose
reads (`chmod 600`). OpenAI's is `deploy/config/openai_key`. The image has no agents' CLIs (Claude
Code, OpenCode): a group whose summarizers or tutor run as agents builds an image `FROM zemi`
that installs them, with their tokens in `service.env`.

- Logs: `docker compose -f deploy/compose.yaml logs -f zemi`.
- Update: `git pull`, then the same `up -d --build`. The data, its backups, Julia's later installs,
  Qdrant's vectors and Ollama's models are volumes, kept across rebuilds.
- An NVIDIA GPU for Ollama: uncomment its `deploy` lines in `compose.yaml`.

To try it on one machine, without a domain or Caddy, add `deploy/compose.local.yaml`: the service is
at `http://localhost:8800` (`ZEMI_LOCAL_PORT` for another port), and anyone on the machine can sign
in as any invited email.

```sh
ZEMI_ADMINS=you@example.org docker compose -f deploy/compose.yaml -f deploy/compose.local.yaml up -d --build
```

## The first sign-in

Sign-up is by invitation (`[shared] sign_up = "invite"`), and admins send the invitations, so the
service needs an admin before anyone can sign in. Name the first with `--admin` when installing, or
in the config's `[shared] admins` (in a container, `ZEMI_ADMINS` at its first start). With neither,
`install.sh` asks for one, and the service refuses to start.

Whoever runs the server can name an admin at any time. This is also the way back in for an admin
who lost the role or was disabled:

```sh
sudo -u zemi env ZEMI_CONFIG=/srv/zemi/.config/zemi/config.toml /srv/zemi/Zemi.jl/zemi admin you@example.org
docker compose -f deploy/compose.yaml exec zemi /srv/zemi/Zemi.jl/zemi admin you@example.org   # in a container
```

An email with an account gets the Admin role back. Any other email is invited as an admin, and its
first sign-in makes it one. `zemi admin` alone lists who can administer the service. The email is
matched against the verified email the provider reports, so sign in with an account that has it.

**1. Sign in** at `https://<host>` with one of the providers.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/sign-in-light.png" alt="The sign-in page, with a button for each provider">
  <img class="dark-only" src="./assets/screenshots/sign-in-dark.png" alt="The sign-in page, with a button for each provider">
</figure>
```

**2. Set up the knowledge base.** Its front page leads an admin to Setup, four steps (see
[Configuration](configuration.md#Setup)). The group: its name, field, description and focus areas.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/setup-light.png" alt="Setup's first step: the group and its focus areas">
  <img class="dark-only" src="./assets/screenshots/setup-dark.png" alt="Setup's first step: the group and its focus areas">
</figure>
```

The arXiv categories to watch for new papers, and a contact email for arXiv and OpenAlex:

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/setup-arxiv-light.png" alt="Setup's second step: the arXiv categories watched">
  <img class="dark-only" src="./assets/screenshots/setup-arxiv-dark.png" alt="Setup's second step: the arXiv categories watched">
</figure>
```

The model that reads papers, which can be chosen later (see [Models](models.md)):

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/setup-model-light.png" alt="Setup's third step: the model that reads papers">
  <img class="dark-only" src="./assets/screenshots/setup-model-dark.png" alt="Setup's third step: the model that reads papers">
</figure>
```

Whether the knowledge base stands alone or shares a group's dataset (see [Datasets](datasets.md)):

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/setup-sharing-light.png" alt="Setup's fourth step: reading alone or sharing a dataset">
  <img class="dark-only" src="./assets/screenshots/setup-sharing-dark.png" alt="Setup's fourth step: reading alone or sharing a dataset">
</figure>
```

**3. Invite people** on the Administration page, in the top bar's menu: each email with its roles
(see [Serving](serving.md)). They sign in with any provider whose verified email it is.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/invite-light.png" alt="Inviting someone on the Administration page, with their roles">
  <img class="dark-only" src="./assets/screenshots/invite-dark.png" alt="Inviting someone on the Administration page, with their roles">
</figure>
```


## Agents and notebooks

The service's agents (summarizers, the tutor, notebook agents) and the workers that run notebooks'
code are confined by the kernel (Landlock, Linux 5.13 and later). They can read everything but the
config folder (with `service.env`), the data folder, other agents' folders, the key files the config
names and the usual credential folders (`~/.ssh`, `~/.config/gh`, …). They can write only their own
folders. Workers also start without the service's tokens.

The service refuses to start on a kernel without Landlock. `[shared] confine_agents = false` runs
agents unconfined there.

Its agents are Claude or OpenCode, which Kaimon holds to the tools Zemi gives them. Codex and Gemini
run their own file and shell tools, which Kaimon reaches only when they ask permission for a call, so
a shared service neither offers them nor starts with one in a role.

## Not covered

- Rate limiting: use the `caddy-ratelimit` plugin or fail2ban on Caddy's log.
- An agent can read its own model credential (Claude's token, Codex's or OpenCode's login), which its
  CLI needs to run. Members who can use the tutor or make notebooks can run code on the server as
  the service user, confined as above.
