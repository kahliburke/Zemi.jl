# Changelog

## Unreleased

- **Agents see what is attached**: `media` opens a file attached in a task, note or finding by its
  address (an image shown, a PDF's text and pages, a text file's text), to whoever may see it.
  `task`, `next_task` and `finding` show the newest images and list the other files.
- **Private libraries**: everyone signed in keeps their own notes and files in a space of their own
  in the site's library store (`[library]`, kept apart from the dataset), read for their searches and
  agents alone. A document can be private to the people who brought it in, whatever anyone's role.
- **Obsidian vaults** in a library are read as notes: records the person's searches and agents use,
  wikilinks references between them, and a note naming a paper by arXiv id or DOI brings the paper in.
  Paper notes get references back (`zemi`, `zemi-page`, and the paper's details where the note's
  template leaves them empty); nothing else is written into the vault. PDFs in a library are read as
  documents.
- **Sharing and contributing** what one holds, from the Documents page: shared, a document stays its
  holder's and live; contributed, the group gets a version that stays. Project access applies to any
  kind of document.
- **`zemi connect`** keeps a folder (an Obsidian vault) in step with one's library, signed in through
  the browser for a token that reaches the library alone (OAuth scope `library`), or to the knowledge
  base on the same machine. `zemi connect` alone opens a terminal app that shows the folders, what
  moves, and adds, removes and pauses them; `--background` syncs from every login (`--status`,
  `--stop`). The account page shows the library's folders and the machines keeping them in step,
  each signed out there.
- **Sources** can remove a record whose item is gone (`Zemi.remove!`), follow one that moved
  (`Zemi.rekey!`), and have their records embedded for searching without summarizing them
  (`summarized = false`), and say what their records are (`about`), as agents are told.
- **A project's codebase** can be linked by a folder's path, or a repository's address, from its board.
  A shared service reads a folder of its machine in place; only someone with `config.edit` adds one.

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
