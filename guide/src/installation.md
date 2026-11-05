# Installation

## Requirements

- [Julia](https://julialang.org/downloads/) 1.12 or later
- To read papers:
  - [Ollama](https://ollama.com) with `qwen3-embedding:4b`
  - [Qdrant](https://qdrant.tech) on port 6333 ([Kaimon](https://github.com/kahliburke/Kaimon.jl) can start it)
  - `mutool` 1.27 or later from [MuPDF](https://mupdf.com): `brew install mupdf-tools`; distributions'
    packages are often older, so build it from source there (as `deploy/install.sh` does)
  - poppler's `pdftoppm`, for agent summarizers reading large PDFs
  - access to a summarizer (see [Models](models.md))

Without Ollama and Qdrant, the site and keyword search still work; the Status page lists what is
missing.

## Run

```sh
git clone https://github.com/kahliburke/Zemi.jl.git
cd Zemi.jl
./zemi
```

The first run installs dependencies (a few minutes), then serves the site at
`http://localhost:8000` (`ZEMI_PORT` to change). Open it from the address `zemi` prints, which
carries a key (`?key=…`), or with `zemi open`: the browser keeps the key, and other accounts on the
machine, without it, are kept out. The front page leads to **Setup**: the group and its focus areas, the
watched arXiv categories and a contact email (sent to arXiv and OpenAlex), the summarizer, and
whether to read alone, join a group's dataset or start one. Setup is later in the top bar's
menu.

`./zemi help` lists the other commands: `zemi sync [--unread]` brings the knowledge base up to date,
`zemi bib [FILE]` writes every paper, upload and record as BibTeX, and `zemi publish`, `zemi pull` and `zemi token`
manage a dataset (see [Datasets](datasets.md)). `pkg> app develop ./app` installs `zemi` on your path.

## Add papers

From **Add documents** on the Status page, an agent's `ingest` tool, or Julia:

```julia
using Zemi
db = kb()
ingest!(db, ["1706.03762", "https://arxiv.org/abs/1412.6980"])
search(db, "how the method's error scales with the problem size")
```

Ingesting fetches, parses, summarizes and embeds each paper. Finished steps are skipped, so a
failed run can be repeated. PDFs not on arXiv and Git repositories (as codebases) are added from the
Status page too. The Manage page finds, reprocesses and removes documents.
