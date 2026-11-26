# Changelog

## 0.6.0 (unreleased)

### Breaking

- The database moves from schema 22 to 25 on first start, keeping a snapshot first
  (`data.backups/kept/before-schema-25`); 0.5 cannot read it afterwards.
- The shared knowledge base is exported as `default_kb()`; `kb` is no longer exported, so code and
  notebooks can name their own knowledge base `kb`.

### Changes

- Share the current page as a link or with editable text from the site navigation.

- **Signing in to a knowledge base run for one person**: an OAuth client, such as a Slate notebook
  citing from its bibliography, signs in with the owner's consent and reads what the owner sees.
  Configuration lists the clients connected and revokes them. A group's site signs a client in to a
  member's account as before.
- **Citation keys** for records and uploads are short and readable (`water-levels`,
  `rowan2024-soil`), given once and kept; arXiv papers keep `arXiv:<id>`.
- **Other agents**: Codex, Gemini and OpenCode can read papers, summarize codebases, tutor and make
  notebooks, offered on setup and Configuration once installed here. They read the extracted text.
  A shared service runs only Claude and OpenCode agents, whose tools Kaimon holds to their folder.
- **The first admin of a shared service** is named on the server: `zemi admin EMAIL`, or
  `install.sh --admin EMAIL`. The service refuses to start when nobody could administer it.
- **`zemi connect`** finds the knowledge base run on this machine wherever it is served, the
  development site included, and follows it when it moves. `zemi connect --background` for it has
  the knowledge base sync the folders itself whenever it runs, with no login service.
  `zemi connect --status` says where the folders go, what syncs them and whether it is syncing now.
- **Explore**: every document one may see placed by meaning, on a map or in a 3D space to fly
  through, with the links people made between them (citations, references, evidence, task links)
  and the pairs most alike that no link joins yet. A paper's or record's page shows its neighbourhood.
- **The Obsidian plugin** (`zemi obsidian VAULT` installs it) puts the knowledge base beside one's
  notes: a pane with a paper note's summary and figures and the documents nearest the note, search
  to insert a citation, and paper notes added by arXiv id or DOI. A note's citations link to what
  they cite, with the document shown on hover, and `zemi` blocks in a note show a search, the note's
  references, or a project's tasks or findings. A note's page in Zemi opens it in Obsidian.
- **Codebases** a project adds are read at once; one not read yet says so rather than showing no
  files.
- **Search** shows references as links in results and on a record's page, and the recently posted
  list follows the kind of document the search is set to. Findings come after the documents found,
  and are a kind of their own to search alone. A query of three words or more that a few documents
  hold word for word puts them first. A summary layer counts with the layer of its text as one
  ranking, so notes and codebases, which are not summarized, rank alongside papers.
- **The board** keeps a dragged subtask under its task unless it is dropped onto another;
  "make it a task of its own" on its page takes it out.
- **The installers** have Kaimon set itself up (`kaimon --setup-defaults`) where it can.

## 0.5.2 (2026-11-25)

- **Connecting claude.ai**: a client that asks for every scope the server lists, as claude.ai's
  connectors do, is given access to `/mcp`, which includes the library.

## 0.5.1 (2026-11-23)

- **Figures in series of their own**: captions such as "Fig. S2", "Supplementary Figure 1",
  "Table A1" and a report's drawings, maps and plates ("Annex, sheet S1") are read as captions, and
  their figures are cut and listed after the paper's own. A figure on a page of another size than
  the paper's text, such as a drawing on a landscape page, is cut from that page's own edges.
  Papers are read again (parser version 6) on the next sync.
- **MuPDF comes with Zemi** (MuPDF_jll), so nothing else needs installing to read papers, and the
  installers no longer install it. The `mutool` setting is empty for that one; a program named there
  is used instead.
- **Tables** whose row of column names is long enough to read as a sentence are cut whole.

## 0.5.0 (2026-11-21)

### Breaking

- The database moves from schema 20 to 22 on first start, keeping a snapshot first
  (`data.backups/kept/before-schema-22`); 0.4 cannot read it afterwards.

### Changes

- **Windows**: Zemi runs for one account without administrator rights. It builds and serves the
  site, reads codebases, recognizes and stops its own processes, and takes Windows paths (and a
  leading `~`) wherever it takes paths. `deploy/windows/install.bat` installs it with Julia, MuPDF,
  Ollama, Git, Claude Code and Kaimon, set up and connected.
- **One-step install on macOS and Linux**: `deploy/install-personal.sh` does the same for one
  account, through Homebrew on macOS, and on Linux through the system's packages where `sudo` is
  allowed, or into `~/.local`. Both installers pull `qwen3-embedding:4b` alone, and set Kaimon's
  code search to it.
- **The arXiv watch** places papers for a group without focus areas. When the group's description
  or focus areas change, the watched papers not yet taken in are placed and judged again. A
  cancelled watch stops between papers and leaves the rest to the next.
- **Papers without headings** are read as one section, Full text, rather than none; headings set in
  a medium, demi, heavy or black weight are recognized.
- **An agent's question to anyone** also reaches the person it works for, as on a knowledge base of
  one.
- **An agent taking a codebase task** is told how its commits name it (`Tasks: KB-12`, or
  `Fixes KB-12` in the one that finishes it), so they are recorded as the task's work.
- **Record pages** are served under `zemi dev`, and a private record's page says it is private.
- **A codebase whose files cannot be listed** shows what Git said.
- **The guide** starts with the site's Setup and Configuration pages, with screenshots.

## 0.4.0 (2026-11-14)

### Breaking

- The database moves from schema 14 to 20 on first start, keeping a snapshot first
  (`data.backups/kept/before-schema-20`); 0.3 cannot read it afterwards.
- `zemi connect` with no arguments opens the terminal app on a terminal, and prints a line for each
  change elsewhere, rather than syncing in the foreground silently; `--install` is now `--background`
  (the old name still works).

### Changes

- **Private libraries**: everyone signed in keeps their own notes and files in a space of their own
  in the site's library store (`[library]`, kept apart from the dataset), read for their searches and
  agents alone. A document can be private to the people who brought it in, whatever anyone's role.
- **Obsidian vaults** in a library are read as notes: records the person's searches and agents use,
  wikilinks references between them, and a note naming a paper by arXiv id or DOI brings the paper in.
  Paper notes get references back (`zemi`, `zemi-page`, and the paper's details where the note's
  template leaves them empty); nothing else is written into the vault. PDFs in a library are read as
  documents.
- **Sharing and contributing** what one holds, from the Documents page: shared, a document stays its
  holder's and live; contributed, the group gets a version that stays; removed from one's library,
  it goes once no one holds it. Project access applies to any kind of document.
- **`zemi connect`** keeps a folder (an Obsidian vault) in step with one's library, signed in through
  the browser for a token that reaches the library alone (OAuth scope `library`), or to the knowledge
  base on the same machine. `zemi connect` alone opens a terminal app that shows the folders, what
  moves, and adds, removes and pauses them; `--background` syncs from every login (`--status`,
  `--stop`). The account page shows the library's folders and the machines keeping them in step,
  each signed out there.
- **Zotero groups are linked from a project's library**, by its maintainers: a group's address, and
  an API key for a private one, checked with Zotero and kept where the service alone reads it. Each
  group shows its items, when it was last read and any error; one group failing no longer stops the
  others. The Configuration page lists the groups and sets whether items are sorted first.
- **Cmd-K palette**: anywhere on the site, it finds the knowledge base's tasks, findings, papers,
  records, notebooks and code as one types, goes to any page or project, searches the knowledge base
  for the words, adds a paper by its arXiv id, DOI or address, syncs, and switches the theme. A static
  copy of the site keeps VitePress's search. The Search page takes its query from `?q=`.
- **Agents see what is attached**: `media` opens a file attached in a task, note or finding by its
  address (an image shown, a PDF's text and pages, a text file's text), to whoever may see it.
  `task`, `next_task` and `finding` show the newest images and list the other files.
- **Names follow renames**: notes, questions, activity, tasks, findings and their comments show each
  person by the name their account has now, agents' notes by the name of whom they work for, and a
  person's own notes stay theirs to edit after a rename. Mentions show the current name, in task
  titles and notifications as `@Name`.
- **Questions and answers open where they are**: from Waiting on you, Focus, what others did lately
  and notifications, a task opens scrolled to the note, marked for a moment (`#KB-12/345` links to one).
- **Removing a note**: a comment, progress note or question is removed by whoever may edit it (on
  the task's activity, or `task_note_remove` for an agent's own); the activity keeps that it was
  removed. A comment on a finding is removed by its writer.
- **Jobs show when they ran**: when each started and finished, how long it took and how many
  documents it changed; the Operations page also shows a job's result or error.
- **A project's codebase** can be linked by a folder's path, or a repository's address, from its board.
  A shared service reads a folder of its machine in place; only someone with `config.edit` adds one.
- **Sources** can remove a record whose item is gone (`Zemi.remove!`), follow one that moved
  (`Zemi.rekey!`), and have their records embedded for searching without summarizing them
  (`summarized = false`), and say what their records are (`about`), as agents are told.
- **`zemi` starts in about a second**: the app's entry is compiled into the package image.
- **Signing in a client** (`zemi connect`, an MCP client) shows pages in the site's colors, light or
  dark, and says when an approval was denied.
- **The Documents page** says what one's library is, and how to fill it while it is empty.

## 0.3.2 (2026-11-10)

- **Studies** link the codebases they find to the codebases' pages, and show without a link what
  the site has no page for; a bibliography entry names a page only where there is one.

## 0.3.1 (2026-11-10)

- **On a phone** an open task takes the whole screen, closed by a back arrow; the board's columns
  swipe one at a time, its views bar scrolls on its own, and the project's About and the filters
  fold away until asked for. Wide tables scroll in place rather than widening the page, and small
  buttons are a finger's size on a touch screen. Where a panel is docked, a tablet's, its edge
  drags by touch.
- **API tokens** are known by their hash alone, so those an earlier version issued under another
  prefix keep working.
- **Search** on a server whose Qdrant Kaimon runs: the shared service starts that Qdrant when it is
  not running, and keeps to it once the service's own Kaimon is up.

## 0.3.0 (2026-11-10)

- **Installing**: `pkg> app add Zemi` installs `zemi`, which no longer carries Kaimon: it reaches the
  Kaimon running on this machine for its agents and Qdrant.
- **In Kaimon**: Kaimon can run the knowledge base as its extension (`zemi kaimon` registers it),
  starting it with itself and serving it as `[service]` says: for one person or shared, built or
  for development. Its panel in Kaimon's Extensions tab shows how it is going and changes how it
  runs. Once Kaimon runs it, `zemi` says so instead of serving a second copy. `zemi manual` and
  rebuilding on Enter are gone.
- **The model that reads papers** is chosen by where it runs, with what each choice needs on this
  machine, tries on a section of a paper to compare, a choice among OpenCode Zen's models, and a local
  model pulled from the page (the disk's room checked first). The same choice is on the
  Configuration page, and the front page says when summaries keep failing.
- **A section** opens on the paper's own pages, where it starts, with the rest of the pages dimmed;
  in the dark theme they are recolored for it, or shown as printed. Its extracted text is a click
  away.
- **Papers** are read again on the next sync, so a display equation holds only its own lines and the
  math labels of a figure the reading puts after it go with the figure.
- **Focus** on a board shows only your part of the project: questions for you and answers to yours,
  your tasks, the plans and reviews that concern you, and your questions still waiting.

## 0.2.0 (2026-11-09)

- **Notifications**: what newly waits on a person (questions for them, answers to theirs, plans and
  work to review, tasks assigned to them) comes to their phone or computer through the browsers' Web
  Push, encrypted and signed by the service itself. Offered once in each browser; on an iPhone, from
  the site added to the Home Screen.
- **Questions** on a task are asked of the agents, a person or anyone, and answered with a reply. An
  agent's question asked back goes to the person it works for.
- **The board** sorts its columns, hints in colour at what concerns you, marks cards others changed,
  and searches with a spinner while it runs. Who may edit an agent's note: the person it works for,
  and the project's maintainers.
- **Resources**: data sets, portals, laws and works cited without a copy to read, with pages, types,
  citations and a list. A **Cite** button on papers, resources, records, findings and tasks.
- **Zotero**: a group's library kept in step, each item sorted by the summarizer as a paper, resource
  or codebase, and works that are one merged.
- **Documents** are dropped from one page, and kept out of every source.
- **The service** backs itself up on a schedule, runs in containers (with Qdrant, Ollama and Caddy),
  installs on Ubuntu 26.04, and answers requests side by side. A privacy page; people may change the
  name they are shown by.
- **The landscape** places papers by when they were published or when the group had them, and is
  rebuilt when its format changes.

## 0.1.0 (2026-11-05)

The first release.

- **Documents**: arXiv papers, PDFs, codebases and records of the group's own work, read, summarized
  section by section, and embedded in several layers. Hybrid keyword and semantic search.
- **The site**: paper pages, topics, a timeline, a landscape against the group's focus areas, an
  arXiv watch, and a daily paper with an analysis.
- **A tutor** per paper, pitched to the reader's background, and notebooks made from papers.
- **Findings** that cite their evidence, and **projects** whose task boards people and agents share.
  A board shows who else is on it, and a planning session can follow one person and draw on it.
- **Agents** use all of it through MCP or Kaimon.
- **Solo or shared**: one person on a laptop, or a signed-in group on a server with roles, API
  tokens and a bibliography per person, sharing what they read as datasets.
- **Plugins** add sources of records, which bring in the group's work from other tools.
