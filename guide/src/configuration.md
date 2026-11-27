# Configuration

A knowledge base is set up on its own site, by those whose role may change its configuration (admins,
in a shared service): **Setup** when it is new, and the **Configuration** page after. Both are in the
top bar's menu. What they save goes beside the config file, which those who run the server keep for
what the site does not set (see [The config file](#The-config-file)).

## Setup

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/setup-light.png" alt="Setup's first step: the group and its focus areas">
  <img class="dark-only" src="./assets/screenshots/setup-dark.png" alt="Setup's first step: the group and its focus areas">
</figure>
```

The front page of a new knowledge base leads to Setup, four steps:

1. **Group**: its name (the site's title), its field and a description, which every agent is given,
   and its focus areas, the topics the landscape and the arXiv watch rank papers against.
2. **arXiv**: the categories watched for new papers, found by name, and a contact email sent with
   requests to arXiv and OpenAlex, as their policies ask.
3. **Model**: the model that reads papers (see [Models](models.md)). It can be chosen later: papers
   are read, searched and cited without summaries until then.
4. **Sharing**: read alone, join a group's dataset with the key file you were sent, or start one in a
   folder or a bucket (see [Datasets](datasets.md)).

Setup can be run again from the menu; saving replaces what it sets.

On a server, the first admin signs in and goes through it as [Server deployment](deployment.md#The-first-sign-in)
shows, each step's screen in turn.

## The Configuration page

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/configuration-light.png" alt="The Configuration page">
  <img class="dark-only" src="./assets/screenshots/configuration-dark.png" alt="The Configuration page">
</figure>
```

Everything Setup sets, and the rest of what a group changes, each field with its key in the config
file beside it. Changes are saved together, with **Save**; those who may only view the configuration
see it read-only.

- **Look**: the logo (the top bar's, and the icons made from it) and the front page's image in each
  theme, uploaded or pasted.
- **The model that reads papers**: see [Models](models.md).
- **Who does what**: a model for each job apart from the summarizer's: codebases, records, the judge
  comparing summarizers, the tutor and how hard it thinks, notebooks, the paper of the day's analysis,
  and rating new arXiv papers. Left empty, the summarizer does it.
- **Search**: the layers a search uses unless it picks others, and whether keyword ranking joins them.
- **New on arXiv**: the categories watched, the days of new papers listed, the hours between checks,
  and the ratings read in full (3 central, 2 related, 1 peripheral) or only recorded.
- **The group**: below.
- **Sharing**: the dataset this knowledge base publishes to or imports from (see [Datasets](datasets.md)).
- **Codebases**: the time each night linked codebases that changed are read again, and its time zone.
- **Zotero**: the groups read (see [Resources and Zotero](work.md#Resources-and-Zotero)), and whether
  a model sorts each new item before it is brought in.
- **Signing in**, in a shared service: invitation only or open to anyone who can sign in, the role a
  newcomer gets, and how many days a sign-in lasts.
- **Content in conflict**, when pages or notebooks were changed here and by another member of the
  dataset: keep yours or take theirs.

### The group

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/configuration-group-light.png" alt="The Configuration page's group section">
  <img class="dark-only" src="./assets/screenshots/configuration-group-dark.png" alt="The Configuration page's group section">
</figure>
```

The group's name, field and description, which go into every agent's prompt; its focus areas; the
**tutoring profile**, the questions readers answer about their background so the tutor pitches to them
(`{field}` in a question becomes the field); the front page's panels, each a title, a line and a page
it links to; and the contact email.

The focus areas are what the arXiv watch rates new papers against, and the landscape places each paper
by how near it is to each of them:

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/landscape-light.png" alt="The landscape: papers clustered by similarity">
  <img class="dark-only" src="./assets/screenshots/landscape-dark.png" alt="The landscape: papers clustered by similarity">
</figure>
```

Its clusters are the communities of the graph that joins each paper to those nearest it in meaning
(found by Leiden), so their number and sizes are the library's own. Rebuilt as papers come and go, the
clusters keep their papers, and so their names. `resolution` under `[landscape]` makes them finer
(above 1) or coarser (below 1).

**Explore**, beside the landscape, places every document you may see by what it is about, your own
notes included, with the links people made drawn between them: citations between papers, references
in notes and records, a finding's evidence, a task's links. It needs a running server.

It maps the documents read in full. **Include abstract only** adds the papers known only by their
title and abstract (recorded but not yet read, or found by the watch), on a map of every document laid
out and clustered afresh.

- **Map** lays them out flat; **Space** in three dimensions, to turn with the mouse, or fly through
  with F (WASD to move, the mouse to steer). The clusters are the landscape's, named where they lie;
  a map without the landscape's clusters finds its own.
- Clicking a document moves there and shows its card: its authors, its summary or abstract, its
  links, and the documents nearest it in meaning, with lines drawn to them, fainter the less alike.
  From the card, copy its citation or a link to this view. Double-click opens its page; Backspace
  goes back.
- Pointing at a document names it. Holding ⌥ (Alt) as you do draws its links and nearest documents
  where the view is, without moving it or fading the rest, and says its kind, year and cluster;
  ⌥-click chooses it without moving the view.
- The search box lights up what Zemi's search finds; Enter goes to the best, Tab to the next.
  **Drift** moves on by itself to the nearest document not yet visited, pausing as long as you set.
  Its trail lists where it went, to copy as text.
- **Suggested links** lists the pairs most alike that no link joins yet: **Everywhere**, in **This
  cluster**, or **Yours**, your own notes, records and findings beside what they do not link to yet.
  For each pair, copy a paper's citation for a note, add a document to a finding as evidence, **Link**
  the two as related, or say they are **Not related**, which stops suggesting the pair.

The panel at the top right has two tabs:

- **Legend**: **Colour by** a group each document is in, a row of the legend each: its cluster, arXiv
  category, how it was read (in full, by its abstract, or a note or record), kind, or whose it is
  (yours, your projects', everyone's). Or by a scale, from one colour to another by rank, with what
  each end means beneath:
  - **The field right now**: how much of what is nearest it was published in the last 30 days;
  - **Bridges**: how many of its nearest lie in other clusters, what joins topics;
  - **The group's attention**: how near the notes and records you may see come to it, and how often
    findings and tasks use it;
  - **Ahead of its time**: how much more it is like the papers published after it than before it;
  - **Loners**: how unlike even its nearest it is;
  - **Year published** and **Date added**.

  A row goes to its group and lights it; **Shade by** then shades a cluster's documents by how often
  they are cited and referred to, how central they are to the cluster, or how relevant the watch rated
  them.
- **Settings**: the layout, which documents and which kinds of link are drawn, and the pairs close in
  meaning that no link joins, with a slider for how alike they must be. Of the layouts, **t-SNE**
  keeps each document's close neighbourhood, **UMAP** more of how the groups lie to each other, and
  **PaCMAP** both, the most evenly. Either way, close together means alike.

**A map of its own.** A part of the knowledge base laid out by itself uses the whole map, and its
clusters are found again at a finer grain, so one cluster of the full map comes apart into its
subtopics:

- a cluster, from the lens on its legend row, and a cluster of that map in turn, a level further in;
- a project's library, chosen under **Settings**;
- the documents a search finds (**Map these**: the first 100, and **top** beside its name sets how
  many, up to 500);
- a drift's documents with the nearest of each (**Map this drift**, beside its trail).

The path above the map leads back to the maps it came from and to **All documents**. The address
names the part (`?set=cluster:4`, `?set=project:KB`, `?set=q:kelp`), so a map of one can be
reloaded and shared; each reader sees only what they may. A larger part is laid out as a job, its
progress over the map. Too few documents to lay out are said to be so.

A paper's or record's page shows its neighbourhood in a small map, with **Explore from here**. The
map is made with the landscape in a sync, and when the page is opened after documents changed.

### Explore authors and co-publications

Choose **Explore authors** on the document map, or follow an author from a paper. From their
profile, **Explore co-publications** shows their direct coauthors. Select a line or its count for
the shared publications, or a coauthor's name to centre the graph there. Each paper counts once.
The live service uses the papers you can open. A static site's graph contains only open papers.

An ORCID iD groups that individual's bylines across spellings. You can search for the name or
the iD. Without an iD the index groups an exact byline, which can still refer to namesakes.
Old surname-and-initial links offer a choice when they match multiple entries.

Zemi keeps the ORCID supplied on an uploaded paper's OpenAlex authorship (`raw_orcid`).
It validates the identifier's check digit. Entries supplied in a base set may carry an optional
`orcids` array aligned with `authors`, with `null` for unknown entries.
People with **Manage papers** permission can use **Edit ORCID** next to a publication on the
author's profile to record a sourced iD, correct it or clear it. A change applies to that
publication's byline. Readers can request corrections from the instance administrator.

## The config file

`~/.config/zemi/config.toml`, or the path in `ZEMI_CONFIG`. Defaults are in `src/config.jl`. What the
site saves goes to `config.settings.toml` beside it, which overrides the config file key by key: remove
a key there to let the config file's value apply. The Configuration page names both files at its top.

A new knowledge base needs no config file. Those who run the server set in it what the site has no
field for:

```toml
data_dir = "/srv/zemi/data"         # the database, PDFs and site
content_dir = "/srv/zemi/content"   # what people write

[group]
restarting = "Surveying the reef"   # shown while it restarts

[landscape]
resolution = 1.5                    # finer clusters (default 1.0; below 1, fewer and larger)

[backup]
dir = "/mnt/backups/zemi"           # see Backups
```

The site's own settings can be given here too, as the keys the Configuration page shows: a group run
from a repository of its config, say, keeps `[group]` and `[watch]` there.

### Data and content

`data_dir` (default `~/.local/share/zemi`) holds the database, PDFs and built site. `content_dir`
(default `content` in `data_dir`) holds what people write. Relative paths are resolved from the
config file's folder.

```
pages/        site pages in Markdown; index.md replaces the front page
studies/      one folder per study: study.toml and drafts
notebooks/    Slate notebooks; a paper's under papers/<paper>/
assets/       logo, front page images (hero-light.svg, hero-dark.svg), images pages use
```

### Backups

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

### Notebooks

[Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl) notebooks, rendered through the local
Slate hub, or the one on `[notebooks] slate_port`. `ZEMI_SITE_NOTEBOOKS=0` leaves them out.

### Other keys

| Key | Default | |
|:---|:---|:---|
| `ollama_url` | `http://localhost:11434` | the embedding service |
| `ollama_keep_alive` | `"24h"` | how long Ollama keeps an embedding model loaded after its last use, so a search does not wait for it to load (Ollama's own default is five minutes) |
| `qdrant_url`, `qdrant_key` | Kaimon's Qdrant, else `http://localhost:6333` | the vector store, and its API key as `"env:NAME"` or `"file:PATH"` |
| `collection_prefix` | `"zemi"` | Qdrant collections are `<prefix>_<layer>` |
| `mutool` | `""` | MuPDF's command; empty for the one Zemi carries |
| `contact` | `""` | an email sent to arXiv and OpenAlex with requests |
| `base_set` | `""` | a file a new, empty knowledge base is seeded from |
| `[[layers]]` | five layers (see [Models](models.md)) | replaces the default layers |
| `[search] layers`, `keyword` | the layers on the strongest model, `true` | what a search uses unless it says otherwise |
| `[ranking] k`, `weights` | `60`, each ranking 1 | how search fuses its rankings |
| `[landscape] layer` | the first paper layer searched | the layer papers are placed by |
| `[media] max_mb` | `200` | the largest file people and agents may attach |
| `[media.backup]` | none | a copy of every attached file, as `[dataset]` names a store |
| `[service] mode`, `dev`, `port`, `dev_port` | `"solo"`, `false`, `8000`, `5173` | how Kaimon serves it as its extension (see [Serving modes](serving.md#In-Kaimon)): for one person or `"shared"`, built or from VitePress's development server; `port` and `dev_port` are `zemi`'s and `zemi dev`'s too, under `ZEMI_PORT` and `ZEMI_DEV_PORT` |

### Public instance information

Anyone can read `/about` on a shared service, including before signing in. The sign-in page and the
site footer link to it. Zemi supplies the software credit, installed package version and upstream
repository. All instance details are optional. An empty configuration shows only the software block.
Use the following **fictional example** in the instance TOML file and replace only the entries you
want to publish.

```toml
[about]
operator = "Example Research Association"
contact = "contact@example.invalid"
hosting_provider = "Example Cloud"
data_region = "Example region"
domain_holder = "Example Research Association"
funding = """Hosting and domain → Example Research Association
AI calls → Example Research Grant"""
infer_models = true
models = ["Example model via Example Provider"]
note = "Fictional example for the configuration guide."
```

If `about.contact` is blank, the page uses the existing top-level `contact`. The location is the
storage location declared by the operator. Funding and notes are plain text and can span lines.

When the config selects models, summarizers or embedding layers, or follows a dataset model profile,
the page automatically lists the
models configured for the selected roles and active layers, once per model and provider or agent
runtime. These names describe the configuration. Unselected presets and
unused trial layers are omitted. The page identifies recognized services and runtimes by name.
Custom endpoint URLs, key settings and filesystem paths are excluded from the inferred list.

Set `infer_models = true` to also report the selected built-in defaults on an otherwise unconfigured
instance. Use `models` to supplement inferred entries, or set `infer_models = false` and supply the
entire public list yourself. The privacy page links directly to the models section whenever it has
entries.
