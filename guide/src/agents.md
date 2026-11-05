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

`zemi --shared` serves the tools at `/mcp`, limited to each person's roles. A client that signs in
through OAuth needs only the address:

```json
{
  "mcpServers": {
    "zemi": { "type": "http", "url": "https://kb.example.org/mcp" }
  }
}
```

With an API token made on the Account page (in the account menu):

```json
{
  "mcpServers": {
    "zemi": { "type": "http", "url": "https://kb.example.org/mcp", "headers": { "Authorization": "Bearer zemi_…" } }
  }
}
```

How agents use tasks: [Projects, records and findings](work.md).
