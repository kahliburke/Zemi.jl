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
  whole paper before summarizing. Needs Kaimon loaded in the same process (the `zemi` command, the
  Kaimon extension, Slate notebooks).

Built in:

- `deepseek-v4.1-flash`, `deepseek-flash`: OpenCode Zen (`opencode auth login`).
- `gpt-5.4-mini`: OpenAI, its key in `~/.config/zemi/openai_key`.
- `opus-agent-pdf`, `opus-agent-text`, `opus-agent-code`, `sonnet-agent-pdf`, `sonnet-agent-code`:
  Claude through a Claude subscription.

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
