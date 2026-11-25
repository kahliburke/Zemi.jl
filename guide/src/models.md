# Models

## Embeddings

`qwen3-embedding:4b` through Ollama, in five layers: paper (title and abstract), section, passage,
section summary, paper summary. Search fuses the rankings from each layer and a keyword index.

## The model that reads papers

```@raw html
<figure class="shot">
  <img class="light-only" src="./assets/screenshots/models-light.png" alt="Choosing the model that reads papers on the Configuration page">
  <img class="dark-only" src="./assets/screenshots/models-dark.png" alt="Choosing the model that reads papers on the Configuration page">
</figure>
```

One model, the summarizer, summarizes papers, codebases and records, sorts what is added, and picks
the paper of the day. Setup's Model step and the Configuration page choose it by where it runs: a
service (OpenCode Zen, OpenAI, or another OpenAI-compatible API by its address, model and key), Claude
on your subscription through Kaimon, another agent on your own plan through Kaimon (Codex, Gemini or
OpenCode, each offered once its command is installed and signed in), or Ollama on this machine. Each
choice says what it needs here (a key, Kaimon's agents, an agent's command, Ollama and a model) and
whether it has it. Another agent runs its own default model unless one is named. Zen's models are listed with their
cost per paper, from Zen's prices.

**Try** has the choice summarize a section as each section of a paper is summarized: a section of a
paper here, a sample one before there are any, or a passage pasted. Each answer stays beside the
others to compare, with how many words it made of how many and how long it took; a failure is said
plainly (a key refused or expired, a model not pulled, nothing answering).

For a local model, they recommend one for the machine's memory and free disk, and pull it into
Ollama, refusing when the disk would keep less than 5 GB free. When the summarizer keeps failing (at
once for a refused key), the front page says so to those who may change it.

Changing the summarizer marks existing summaries out of date; the next sync rewrites them.

Two kinds of model:

- **API**: one request per section to an OpenAI-compatible endpoint (OpenCode Zen, OpenAI, Ollama's
  `/v1`).
- **Agent**: Claude Code, or an agent supporting ACP (Codex, Gemini, OpenCode), run through Kaimon;
  reads the whole paper before summarizing. Claude reads the PDF, figures included, or the extracted
  text; Codex reads the text and looks at the figures and tables Zemi cut from the PDF; the others
  read the text. Needs a Kaimon running on this machine, or Kaimon running the
  knowledge base as its extension.

Built in:

- `deepseek-v4.1-flash`, `deepseek-flash`: OpenCode Zen, with a key typed on the setup page
  (`opencode_key` beside the config, used first), or `opencode auth login`, or `OPENCODE_API_KEY`.
  Any other of Zen's chat models can be chosen too: it gets a summarizer of its own, `zen-<model>`.
- `gpt-5.4-mini`: OpenAI, its key in `~/.config/zemi/openai_key`.
- `opus-agent-pdf`, `opus-agent-text`, `opus-agent-code`, `sonnet-agent-pdf`, `sonnet-agent-code`:
  Claude through a Claude subscription.

Choosing Codex, Gemini or OpenCode adds a summarizer for it, `codex-agent` (`codex-agent-<model>` with
a model named), which reads papers and codebases both:

| Agent    | Installed with                                   | Signed in with        |
|:---------|:-------------------------------------------------|:----------------------|
| Codex    | `npm install -g @agentclientprotocol/codex-acp`  | `codex login`         |
| Gemini   | `npm install -g @google/gemini-cli`              | running `gemini` once |
| OpenCode | from [opencode.ai](https://opencode.ai)          | `opencode auth login` |

## Who does what

The Configuration page's **Who does what** gives other jobs a model of their own; left empty, the
summarizer does them. In the config file:

```toml
summarizer = "deepseek-v4.1-flash"       # summaries and classification
code_summarizer = "deepseek-v4.1-flash"  # codebases
record_summarizer = ""                   # records
judge = "opus-agent-pdf"                 # comparing summarizers
tutor = ""                               # the tutor
tutor_effort = "medium"                  # how hard it thinks: low, medium, high
notebooker = ""                          # the agent making notebooks
analyst = ""                             # writes about the paper of the day

[watch]
judge = ""                               # rates new arXiv papers, picks the paper of the day
```

## A model of your own

An agent other than Claude, or an API with its own request settings and prices, is added in the
config file, and can then be chosen under **Who does what**:

```toml
[[summarizers]]
name = "local-agent"
kind = "agent"
model = "ollama:qwen3:32b"      # or "sonnet", "acp:codex", "acp:opencode:opencode/glm-5.3-flash", ...
reads = "text"                  # default "pdf": Claude reads the PDF, other agents the text (Codex with the figures)

[[summarizers]]
name = "local-api"
url = "http://localhost:11434/v1"
model = "qwen3:32b"
key = ""                        # or "file:~/.config/zemi/key", "env:API_KEY", "opencode"
request = { temperature = 0.2 }
price_in = 0                    # dollars per million tokens, for the cost estimates
price_out = 0
```

