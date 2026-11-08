# Configuration

A knowledge base has a config file and a content folder.

## Config file

`~/.config/zemi/config.toml`, or the path in `ZEMI_CONFIG`. Defaults are in `src/config.jl`.
Changes made on the site go to `config.settings.toml` beside it, which overrides the config file key
by key: remove a key there to let the config file's value apply.

```toml
[group]
name = "Reef Ecology Lab"            # site title
field = "coral reef ecology"         # given to the agents; read after "in" and "about"
description = "We study how reef communities recover after bleaching, from field surveys and models."
restarting = "Surveying the reef"    # the page shown while the service restarts (see Deployment); default: Back in a moment

[[group.focus_areas]]                # what the landscape and the arXiv watch rank papers against
name = "Bleaching and recovery"
description = "Coral bleaching, mortality and the recovery of reef communities after heat stress"

[[group.panels]]                     # the front page's panels; default: Papers, Tutor, Findings, Projects
title = "Field surveys"
text = "Each reef's surveys since 2019, with what they found."
link = "/findings"                   # optional

[watch]
categories = ["q-bio.PE", "physics.ao-ph"]   # arXiv categories to watch
days = 7                             # how far back each check looks
hours = 24                           # how often `zemi` checks (0: only when asked)
read_from = 2                        # papers rated this or higher are read in full (0-3; 4: none)
record_from = 1                      # and these only recorded

[landscape]
clusters = 5                         # default: from the library's size
```

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/landscape-light.png" alt="The landscape: papers clustered by similarity">
  <img class="dark-only" src="./assets/screenshots/landscape-dark.png" alt="The landscape: papers clustered by similarity">
</figure>
```

The group's field and description go into every agent's prompt. `[[group.questions]]` replaces the
tutor's questions about the reader's background.

## Data and content

`data_dir` (default `~/.local/share/zemi`) holds the database, PDFs and built site. `content_dir`
(default `content` in `data_dir`) holds what people write. Relative paths are resolved from the
config file's folder.

```
pages/        site pages in Markdown; index.md replaces the front page
studies/      one folder per study: study.toml and drafts
notebooks/    Slate notebooks; a paper's under papers/<paper>/
assets/       logo, front page images (hero-light.svg, hero-dark.svg), images pages use
```

## Backups

The knowledge base snapshots itself every hour, into `backups` beside the data folder (the data
folder's path with `.backups` added, `~/.local/share/zemi.backups` by default). A snapshot holds the
database, the config folder, the content and the records, packed, and a copy of the uploads, PDFs
and figures. A file unchanged since the last snapshot is hard-linked to that snapshot's copy, so it
takes no more space. The site, cloned codebases, Kaimon's index and the vectors are left out: they
are rebuilt. The folder is readable only by its owner, since the config holds secrets.

```toml
[backup]
enabled = true                 # on by default
dir = "/mnt/backups/zemi"      # another disk, or a mounted share, survives losing this one
every_hours = 1
keep_all_hours = 24            # every snapshot of the last day
keep_half_daily_days = 3       # then one per 12 hours
keep_daily_days = 14           # then one a day; none older
files = true                   # false: the uploads only, not the PDFs and figures
min_free_gb = 5                # no snapshot when the disk has less free
max_gb = 0                     # past this, the oldest go first; 0 for no limit
```

`dir` must be outside the data folder. A small group's knowledge base takes a few MB a snapshot
packed, and its files once: about 45 snapshots under 1 GB. Before the database is migrated to a new
schema, the snapshot `before-schema-<n>` is taken and kept until deleted. The Status page shows the
last snapshot and the backups' size, with **Back up now**; [Deployment](deployment.md#backups) covers
restoring.

## Notebooks

[Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl) notebooks, rendered through the local
Slate hub, or the one on `[notebooks] slate_port`. `ZEMI_SITE_NOTEBOOKS=0` leaves them out.

## Other keys

| Key | Default | |
|:---|:---|:---|
| `ollama_url` | `http://localhost:11434` | the embedding service |
| `ollama_keep_alive` | `"24h"` | how long Ollama keeps an embedding model loaded after its last use, so a search does not wait for it to load (Ollama's own default is five minutes) |
| `qdrant_url`, `qdrant_key` | Kaimon's Qdrant, else `http://localhost:6333` | the vector store, and its API key as `"env:NAME"` or `"file:PATH"` |
| `collection_prefix` | `"zemi"` | Qdrant collections are `<prefix>_<layer>` |
| `mutool` | `"mutool"` | MuPDF's command |
| `contact` | `""` | an email sent to arXiv and OpenAlex with requests |
| `base_set` | `""` | a file a new, empty knowledge base is seeded from |
| `[[layers]]` | five layers (see [Models](models.md)) | replaces the default layers |
| `[search] layers`, `keyword` | the layers on the strongest model, `true` | what a search uses unless it says otherwise |
| `[ranking] k`, `weights` | `60`, each ranking 1 | how search fuses its rankings |
| `[landscape] layer` | the first paper layer searched | the layer papers are placed by |
| `[media] max_mb` | `200` | the largest file people and agents may attach |
| `[media.backup]` | none | a copy of every attached file, as `[dataset]` names a store |
