[← How it works](../HOW_IT_WORKS.md)

# The MCP server

[The agent](agent.md#tools) treats tools as something it can list and run. This page is about where
they live.

## The problem with tools inside the agent

The simplest design puts each tool's code in the agent itself: a function per tool, plus a hand-written
`tools` list that describes them to the model. That works for one or two tools, then gets awkward:

- Adding or changing a tool means editing the agent and redeploying it.
- Every tool has its own calling convention, and the agent needs custom code to run each one.
- A tool's dependencies (a database client, a search library) end up in the agent's image.
- A second agent that wants the same tools has to copy them.

## One interface: MCP

[MCP](https://modelcontextprotocol.io) (the Model Context Protocol) is an open standard for exactly
this. Tools live in a separate service, an **MCP server**, and the agent talks to it as an **MCP
client**. Whatever a tool does, the agent uses the same two operations:

| Operation | What it does | Used in the loop |
|---|---|---|
| `tools/list` | Returns every tool with its name, description and argument schema | Building the `tools` list for the LLM request (the first stage of the [tool flow](agent.md#tools)) |
| `tools/call` | Runs one tool by name with the given arguments and returns the output | Running what the model asked for (the third stage of the [tool flow](agent.md#tools)) |

```
 ┌──────────────────────── agent pod ────────────────────────┐        ┌──── mcp-tools pod ─────┐
 │  agent loop ──▶ MCP client (agent/mcp_client.py)          │  HTTP  │  MCP server            │
 │                    list_tools()  ───────────────────────────────▶   │   (mcp-tools/server.py)│
 │                    call_tool(name, args) ───────────────────────▶   │        │               │
 └────────────────────────────────────────────────────────────┘        │        ▼               │
                                                                       │  calculate(), ...      │
                                                                       └────────────────────────┘
```

The LLM never talks to MCP. It only sees the `tools` list inside the API request
([the agent](agent.md#tools)). MCP is the connection between the agent and the tools; the agent
translates between the two.

## Writing a tool

The server (`mcp-tools/server.py`) uses the official MCP Python SDK. A tool is an ordinary function with
a decorator:

```python
@mcp.tool()
def word_count(text: str) -> dict:
    """Count the words, characters and lines in a piece of text."""
    return {"words": len(text.split()), "characters": len(text), "lines": len(text.splitlines())}
```

The SDK builds everything MCP needs from the function itself: the name from the function name, the
description from the docstring, and the argument schema from the type hints. That is the entry the model
gets in its `tools` list (simplified; the SDK adds a few extra `title` fields):

```json
{
  "name": "word_count",
  "description": "Count the words, characters and lines in a piece of text.",
  "input_schema": {
    "type": "object",
    "properties": {"text": {"title": "Text", "type": "string"}},
    "required": ["text"]
  }
}
```

Because the model chooses a tool from that description alone, a clear docstring is part of the tool.
Arguments are validated against the schema before the function runs, so a call with a missing or
wrongly typed argument comes back as an error instead of reaching the function.

## How the agent uses it

Two small functions in `agent/mcp_client.py` are the entire integration:

- `list_tools()` asks the server for its tools and returns them in the shape the LLM API expects. The
  only translation is renaming MCP's `inputSchema` to the LLM API's `input_schema`. It runs at the
  start of every turn, so the agent always offers whatever the server has right now.
- `call_tool(name, args)` forwards a tool request to the server and returns the output as text. If the
  server reports an error, the text is prefixed `Tool error:`, so the model can read it and recover (as
  described in [the agent](agent.md#tools)).

The agent has no list of tools and no code for any individual tool. It reaches the server over HTTP at
`http://mcp-tools:8000/mcp` (the `MCP_URL` setting). The server is stateless: each operation is its own
short request, so there is no connection or session to keep alive between calls.

## What this buys

- **Adding a tool is one function.** Write it with `@mcp.tool()`, run `make up`, and the next turn
  the model is offered it. The agent's code does not change.
- **One interface for every tool.** Calculators, a clock and a document search are all called the same
  way, so the agent has a single code path and nothing tool-specific.
- **Separation.** The tool server is its own pod with its own dependencies and its own tests. The
  tests in `make test` call the tools through the same client the agent uses, with no LLM involved.
- **Reuse.** MCP is a standard, so the same server could serve a different agent or an MCP-aware
  application without changes. In the other direction, pointing this agent at another MCP server
  needs no per-tool code. (This agent talks to one server today; connecting to several would be a small
  change in `mcp_client.py`.)

The server currently offers six tools: `get_current_time`, `calculate`, `random_number`, `word_count`,
`convert_temperature` and `search_documents` (see [Document search](document-search.md)).

---

← Previous: [The UI](ui.md) · Next: [Conversation history](conversation-history.md)
