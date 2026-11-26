# Serving modes

The site is static pages. Reading needs nothing else; changing the knowledge base, searching by
meaning and running agents need Zemi's API behind it.

| | Static copy | `zemi` | `zemi --shared` |
|:---|:---:|:---:|:---:|
| Paper pages with section summaries; topics, authors, timeline, landscape | ✓ | ✓ | ✓ |
| Paper of the day, with its figures | ✓ | ✓ | ✓ |
| Status tables; the arXiv watch's last check | ✓ | ✓ | ✓ |
| Keyword search (titles, authors, summaries, topics, ids) | ✓ | ✓ | ✓ |
| Sections on the paper's pages, or as text; figure galleries | | ✓ | ✓ |
| Full-text and semantic search | | ✓ | ✓ |
| Adding papers, sync, checking arXiv | | ✓ | ✓ |
| Projects, tasks, findings | | ✓ | ✓ |
| Tutor, agent notebooks | | ✓ | ✓ |
| Configuration, Setup, Operations, Documents | | ✓ | ✓ |
| Agent tools | | via Kaimon | MCP at `/mcp` |
| Sign-in, roles, invitations, API tokens | | | ✓ |

The top bar's menu has Operations, Configuration and Setup, and in the shared service Account (API
tokens), Administration and Sign out, each for the roles that allow it. Open source ends the sidebar.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/menu-light.png" alt="The top bar's menu of the service's pages">
  <img class="dark-only" src="./assets/screenshots/menu-dark.png" alt="The top bar's menu of the service's pages">
</figure>
```

Choose **Search Zemi** in the header, or press **Ctrl-K** (**Cmd-K** on macOS). Type a reference,
title or words from a task note. The live palette shows matching items, including excerpts that open
the matching note on its task. On a project board, **In project** narrows the search. Press Enter to
open the full results, or select a suggestion with the arrow keys and press Enter to open it directly.
The results page can be filtered by project and type. Its address keeps the query and filters.

Enter **>** in the palette or press **F1** or **Ctrl-Shift-P** (**Cmd-Shift-P** on macOS) for commands and
page navigation. A static copy uses the site's local page index for the header search.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/palette-light.png" alt="The palette, finding a task and a finding as one types">
  <img class="dark-only" src="./assets/screenshots/palette-dark.png" alt="The palette, finding a task and a finding as one types">
</figure>
```

**Operations** shows how the service is doing: memory, disk, the database, the services it needs,
the site's builds and the backups; its jobs, each with when it started and finished and how long it
took; the agents and what each is doing; and the requests it has answered. Those whose roles allow it
cancel a job, interrupt or close an agent, rebuild the site, back up now and reload the config.

Under Jobs, **Ingestion history** shows the stages recorded for each document, including across
server restarts. Open an attempt to see its models, reported token counts and errors. You can
retry a failed document individually with document management permission. The MCP tool
`zemi.ingest_history` reads the same history and accepts a document ID or run ID.

Completed attempts are kept for 90 days after their final stage. Set **Configuration → Ingestion →
History retention (days)** or `history_days` under `[ingestion]` in the TOML config. Choose 0 to
keep history indefinitely. The service checks at startup and hourly, and each new ingestion also
checks. Attempts without a final stage remain available for diagnosis after a restart.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/operations-light.png" alt="The Operations page's jobs">
  <img class="dark-only" src="./assets/screenshots/operations-dark.png" alt="The Operations page's jobs">
</figure>
```

!!! warning "Projects, records and findings need a server"
    They are stored in the knowledge base's database and edited through the API. On a static copy
    their pages show only "Needs a running Zemi server."

## Page addresses

Zemi serves the knowledge base at `/kb/`, findings at `/findings` and projects at
`/projects`. A link can include a search or a specific finding, for example
`/kb/?q=reef` or `/findings#KB-F3`.

## Install Zemi

Open the site over HTTPS (or on localhost) and choose **Install Zemi** on the home page.
On iPhone or iPad, use Safari’s Share menu and **Add to Home Screen**. Notifications are optional.

After the public demo has downloaded its reading files on the first visit, it can reopen offline,
search papers by keyword, and display their summaries and sections. The personal and shared
services need a connection to read the knowledge base or make changes.

Choose **Share this page** in the navigation (in the menu on a phone). **Content and link**
lets you review and edit the page text or a selected passage. **Link only** includes the
current view and anchor. Use **Share…** to choose an app, or copy the result.

## Static copy

Set `ZEMI_SITE_CLEAN_URLS=0` when building for a static host that requires literal
HTML filenames. The public demo uses this setting.

A built site is a folder any web server can host. Without the API, search uses `papers.json` and
shows *offline*. The demo is a static copy.

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/paper-light.png" alt="A paper page">
  <img class="dark-only" src="./assets/screenshots/paper-dark.png" alt="A paper page">
</figure>
```

## `zemi`

One person, no sign-in, `http://localhost:8000`, opened once from the address it prints or with
`zemi open` (see [Installation](installation.md)). Rebuilds the site when papers, pages or notebooks
change. Serves its tools to the local
[Kaimon](https://github.com/kahliburke/Kaimon.jl) (see [Agents and MCP](agents.md)).

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/search-light.png" alt="Search by meaning, with the passages that matched">
  <img class="dark-only" src="./assets/screenshots/search-dark.png" alt="Search by meaning, with the passages that matched">
</figure>
```

## In Kaimon

[Kaimon](https://github.com/kahliburke/Kaimon.jl) can run the knowledge base as one of its
extensions, so nothing has to be started or watched by hand. `zemi kaimon` registers it (see
[Installation](installation.md#With-Kaimon)). Kaimon then starts it with itself, restarts it if it
fails, serves its tools to the Claude sessions and notebooks it hosts, and runs its agents and
Qdrant. `zemi` need not be run any more: run, it says that Kaimon runs the knowledge base and where,
and serves nothing (`zemi --here` serves it anyway, for when Kaimon is not running). Its log is
`~/.cache/kaimon/extensions/zemi.log`.

It serves as `[service]` in the config says (see [Configuration](configuration.md#Other-keys)): for
you alone on `port`, as `zemi` does, or as the shared service. With `dev`, the site comes from
VitePress's development server on `dev_port`, its components updated as they are edited.

`[u]` on it in the Extensions tab opens its panel. It shows whether it is running, where, and
whether the site is building. Its keys open the site in the browser (`o`), build it again (`b`) and
restart it (`r`). It changes the settings the site's Configuration page does not: how it serves, the
ports, the data and content folders, Ollama, Qdrant and `mutool`. A change is checked as a whole
configuration and written to `config.settings.toml`; `r` restarts the knowledge base with it.

## `zemi --shared`

A group, signing in through GitHub or any OpenID Connect provider. Adds roles, invitations, API
tokens and MCP (at `/mcp` with the default `[shared] kaimon = "embedded"`).
`zemi --shared --local-sign-in` tries it on localhost, signing in as any invited person or admin
without a provider. For a server,
see [Server deployment](deployment.md).

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/admin-light.png" alt="The Administration page">
  <img class="dark-only" src="./assets/screenshots/admin-dark.png" alt="The Administration page">
</figure>
```

Admins invite people on the Administration page, each with roles. The roles it starts with, with their daily
quotas of tutor turns and notebooks:

| Role | May | Tutor | Notebooks |
|:---|:---|:---:|:---:|
| Reader | read and search; see the projects they are in | 0 | 0 |
| Learner | also use the tutor, make notebooks, work on tasks, make projects | 60 | 3 |
| Curator | also add and manage papers, sync, check arXiv, see the service's state | 200 | 10 |
| Admin | everything: configuration, people, tokens | no limit | no limit |

With `[shared] sign_up = "open"`, anyone may sign in, as `default_role` (`"Reader"`). Admins change
the roles and add others.

The bibliography is at `/api/bib`: BibTeX of the papers, uploads and records the caller may see, or
only those cited by the keys in `?keys=arXiv:2401.01234,rec-…`. A document the caller's own
bibliographies key (see [Bibliographies](work.md#Bibliographies)) is in it under that key as well as
its own, and `?keys=` takes either. A program reads it with an API token
that has `read` (`Authorization: Bearer zemi_…`); the search page links it for download. A Slate
notebook citing the knowledge base signs in instead: the notebook asks for the `read` scope by
OAuth, and you approve it on the knowledge base's own page. That works run for one person too, where
the approval page is behind the knowledge base's key, so only you can approve, and the connections
you approved are listed, with Revoke, under Configuration, Connections.

A codebase, like any document of a kind with access, is open to every reader, or only to the
members of the projects linked to it (and those whose roles reach every project). A record linked to
no project is seen only by those who manage papers (see [Records](work.md#Records)). A document is
linked to a project as its codebase or by a link of its own. A codebase from a repository the GitHub
App reads, a private one, starts closed; the rest start open. Those who manage papers change it on
the codebase's page or the Documents page. A closed document is left out of the site's build, its
search index and the landscape, and out of the dataset; the service shows its pages to those who
may see it. Records are never built into the site,
open or not. Linking a project to a codebase, or keeping one in a library, takes seeing it.
