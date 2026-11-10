# Models

## Embeddings

`qwen3-embedding:4b` through Ollama, in five layers: paper (title and abstract), section, passage,
section summary, paper summary. Search fuses the rankings from each layer and a keyword index.

## Summarizers

Summaries, classification and judging are done by summarizers named in the config:

```toml
summarizer = "deepseek-v4.1-flash"       # summaries and classification
code_summarizer = "deepseek-v4.1-flash"  # codebases
record_summarizer = ""                   # records; default: summarizer
judge = "opus-agent-pdf"                 # comparing summarizers
tutor = ""                               # the tutor; default: summarizer
tutor_effort = "medium"                  # how hard it thinks: low, medium, high
notebooker = ""                          # the agent making notebooks; default: summarizer
analyst = ""                             # writes about the paper of the day; default: summarizer

[watch]
judge = ""                               # rates new arXiv papers, picks the paper of the day; default: summarizer
```

Two kinds:

- **API**: one request per section to an OpenAI-compatible endpoint (OpenCode Zen, OpenAI, Ollama's
  `/v1`).
- **Agent**: an agent supporting ACP (Claude Code, opencode, Codex), run through Kaimon; reads the
  whole paper before summarizing. Needs a Kaimon running on this machine, or Kaimon running the
  knowledge base as its extension.

Built in:

- `deepseek-v4.1-flash`, `deepseek-flash`: OpenCode Zen, with a key typed on the setup page
  (`opencode_key` beside the config, used first), or `opencode auth login`, or `OPENCODE_API_KEY`.
  Any other of Zen's chat models can be chosen too: it gets a summarizer of its own, `zen-<model>`.
- `gpt-5.4-mini`: OpenAI, its key in `~/.config/zemi/openai_key`.
- `opus-agent-pdf`, `opus-agent-text`, `opus-agent-code`, `sonnet-agent-pdf`, `sonnet-agent-code`:
  Claude through a Claude subscription.

Setup's Model step and the Configuration page choose among these by where the model runs (a
service, Claude through Kaimon, or Ollama on this machine), with what each needs here: a key, Kaimon's
agents, Ollama and a model. Zen's models are listed with their cost per paper, from Zen's prices.

**Try** has the choice summarize a section as each section of a paper is summarized: a section of a
paper here, a sample one before there are any, or a passage pasted. Each answer stays beside the
others to compare, with how many words it made of how many and how long it took; a failure is said
plainly (a key refused or expired, a model not pulled, nothing answering).

For a local model, they recommend one for the machine's memory and free disk, and pull it into
Ollama, refusing when the disk would keep less than 5 GB free. When the summarizer keeps failing (at
once for a refused key), the front page says so to those who may change it.

Add others:

```toml
[[summarizers]]
name = "local-agent"
kind = "agent"
model = "ollama:qwen3:32b"      # or "sonnet", "acp:opencode:opencode/glm-5.3-flash", ...
reads = "text"                  # default "pdf", for models that read PDFs

[[summarizers]]
name = "local-api"
url = "http://localhost:11434/v1"
model = "qwen3:32b"
key = ""                        # or "file:~/.config/zemi/key", "env:API_KEY", "opencode"
request = { temperature = 0.2 }
price_in = 0                    # dollars per million tokens, for the cost estimates
price_out = 0
```

Changing `summarizer` marks existing summaries out of date; the next sync rewrites them.
