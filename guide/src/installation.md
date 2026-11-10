# Installation

## Requirements

- [Julia](https://julialang.org/downloads/) 1.12 or later
- To read papers:
  - `mutool` 1.27 or later from [MuPDF](https://mupdf.com): `apt install mupdf-tools` (Ubuntu 26.04,
    Debian 14 or later), `dnf install mupdf` (Fedora 43 or later), or `brew install mupdf-tools`
  - [Ollama](https://ollama.com) with `qwen3-embedding:4b`, for searching by meaning
  - [Qdrant](https://qdrant.tech), which [Kaimon](https://github.com/kahliburke/Kaimon.jl) runs for
    you, or one of your own on port 6333
  - a model that summarizes, chosen during setup (see [Models](models.md))

Without Ollama and Qdrant, the site and keyword search still work; the Status page lists what is
missing.

An agent summarizer may need tools of its own. Claude Code reads a PDF too large to attach as page
images made by poppler's `pdftoppm` (`apt install poppler-utils` or `brew install poppler`); Zemi
itself does not use it. Other agents may prefer other tools: their own documentation covers what
they need.

## With Kaimon

[Kaimon](https://github.com/kahliburke/Kaimon.jl) runs the knowledge base for you as one of its
extensions: it starts it with itself and restarts it if it stops, runs the Qdrant it searches and the
agents that can summarize, and serves its tools to the Claude sessions it hosts.

```
pkg> app add Kaimon
pkg> app add Zemi
```

Run `kaimon` once, then `zemi kaimon`, which adds Zemi to Kaimon's extensions. From then on Kaimon
runs it: `zemi` itself need not be run, and says so if it is (`zemi --here` runs it anyway). Its panel
in Kaimon's Extensions tab (`[u]` on Zemi) shows how it is going and sets how it serves (see
[Serving](serving.md#In-Kaimon)). `pkg> app update Zemi` updates it, and the next `zemi` points
Kaimon at the new version.

## On its own

```
pkg> app add Zemi
```

`zemi` serves the knowledge base at `http://localhost:8000` (`[service] port` in the config, or
`ZEMI_PORT`) until it is stopped. Its Qdrant is one of your own, or Kaimon's while Kaimon runs on this
machine; its agents, Kaimon's while it runs.

## Setting up

Open the knowledge base from the address `zemi` prints, which carries a key (`?key=…`), or with
`zemi open`: the browser keeps the key, and other accounts on the machine, without it, are kept out.
The front page leads to **Setup**: the group and its focus areas, the watched arXiv categories and a
contact email (sent to arXiv and OpenAlex), the model that summarizes (see [Models](models.md); it can
be chosen later, and papers are read without summaries until then), and whether to read alone, join a
group's dataset or start one. Setup is later in the top bar's menu.

`zemi help` lists the other commands: `zemi sync [--unread]` brings the knowledge base up to date,
`zemi bib [FILE]` writes every paper, upload and record as BibTeX, and `zemi publish`, `zemi pull` and
`zemi token` manage a dataset (see [Datasets](datasets.md)). To work on Zemi itself, from a checkout,
see [Development](development.md).

## Add papers

From **Add documents** on the Documents page, an agent's `ingest` tool, or Julia:

```julia
using Zemi
db = kb()
ingest!(db, ["1706.03762", "https://arxiv.org/abs/1412.6980"])
search(db, "how the method's error scales with the problem size")
```

Ingesting fetches, parses, summarizes and embeds each paper. Finished steps are skipped, so a
failed run can be repeated. PDFs not on arXiv and Git repositories (as codebases) are added there
too, and the same page finds, reprocesses and drops documents.
