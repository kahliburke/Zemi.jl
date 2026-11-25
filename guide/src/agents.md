# Agents and MCP

!!! warning "Needs a server"
    The tools run inside Zemi: `zemi`, `zemi --shared` or the Kaimon extension.

Tools: search, read papers and sections, list and read the group's records, find similar papers,
add papers, plan and work on tasks, draft findings, read the paper of the day.

## Kaimon

As a [Kaimon](https://github.com/kahliburke/Kaimon.jl) extension, Zemi gives every connected agent
session its tools as `zemi.*`. Add it in Kaimon's TUI: Extensions, `a`, this repository's path. A
running `zemi` also serves them to the local Kaimon.

## MCP

`zemi --shared` serves the tools at `/mcp`, limited to each person's roles.

### Connecting Claude

claude.ai and Claude Code sign in through OAuth: each person signs in to the knowledge base and
approves the connection, which then acts as them, with their roles and projects. It is listed
among their tokens on the Account page, where revoking it ends it. It stays signed in while used,
and lapses after 90 days unused.

**For a Claude organization.** An owner adds the connector once, in the organization's settings
under Connectors: Add custom connector, with the knowledge base's address
(`https://kb.example.org/mcp`), authentication by each user signing in, and the OAuth client
registered automatically. Each member then connects it: in claude.ai, Settings, Connectors, the
connector, Connect; in Claude Code, `/mcp`, the connector (named `claude.ai <name>`), Authenticate.
A member needs an account on the knowledge base, and no connector of their own for the same address.

**For one person.** In claude.ai, Settings, Connectors, Add custom connector, with the address. In
Claude Code:

```
claude mcp add --transport http --scope user zemi https://kb.example.org/mcp
```

then `/mcp`, `zemi`, Authenticate.

### Codex and Gemini

Their command-line agents sign in the same way, in the browser:

```
codex mcp add zemi --url https://kb.example.org/mcp
codex mcp login zemi

gemini mcp add --scope user --transport http zemi https://kb.example.org/mcp
```

Gemini asks to sign in when it first uses the server, or on `/mcp auth zemi`.

### Other clients

Signing in sends a client back only to claude.ai, claude.com or `localhost`, so a client running
on one's own machine signs in through OAuth with only the address:

```json
{
  "mcpServers": {
    "zemi": { "type": "http", "url": "https://kb.example.org/mcp" }
  }
}
```

A client sent back elsewhere, such as ChatGPT's connectors or Cursor, uses an API token made on the
Account page (in the account menu), where it takes one:

```json
{
  "mcpServers": {
    "zemi": { "type": "http", "url": "https://kb.example.org/mcp", "headers": { "Authorization": "Bearer zemi_…" } }
  }
}
```

How agents use tasks: [Projects, records and findings](work.md).
