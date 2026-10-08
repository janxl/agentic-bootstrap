[← How it works](../HOW_IT_WORKS.md)

# The agent

The agent is a small web service (`agent/app.py`). It receives a user's message and returns a reply.
Everything it does between those two points is one function, `run_agent()`: a loop that talks to an
LLM, and, when the LLM asks, runs tools on its behalf.

## Sending a query to the LLM

An LLM API is stateless: it remembers nothing between calls. So every call carries everything the
model needs: who it is, what it may use, and the conversation so far.

```json
{
  "model": "claude-sonnet-5-5",
  "max_tokens": 2048,
  "system": "You are an electricity market analyst's assistant ...",
  "tools": [ ... ],
  "messages": [
    {"role": "user", "content": "What is 17 * 23 + 4?"}
  ]
}
```

| Field | What it carries |
|---|---|
| `system` | The instructions that frame every answer (the system prompt). |
| `messages` | The conversation so far, oldest first. Each message has a `role` (`user` or `assistant`) and `content`. |
| `tools` | The tools the model is allowed to ask for (below). |
| `model`, `max_tokens` | Which model to use, and the longest reply to allow. |

The response contains the model's answer as a list of content blocks, plus a `stop_reason` that says
why it stopped:

```json
{
  "stop_reason": "end_turn",
  "content": [
    {"type": "text", "text": "Hello! How can I help?"}
  ]
}
```

With no tools involved, that is the whole story: the agent sends one request, reads the text out of
the response, and returns it. `stop_reason: "end_turn"` means the model considers its answer finished.

## Tools

A model can only produce text. It cannot calculate reliably, look at a clock, or search a document
library. Tools fix that: the agent offers the model a menu of functions, the model asks for one, and
the agent runs it and reports back.

**1. The agent lists the tools in the request.** Each tool is a name, a description in plain language,
and a JSON Schema for its arguments. At the start of every turn the agent fetches this list from the
tool server (`list_tools()` in `agent/mcp_client.py`; see [The MCP server](mcp-server.md)), so tools can
be added or changed without touching the agent.

```json
"tools": [
  {
    "name": "calculate",
    "description": "Evaluate an arithmetic expression using + - * / ** % and parentheses.",
    "input_schema": {
      "type": "object",
      "properties": {"expression": {"type": "string"}},
      "required": ["expression"]
    }
  }
]
```

The model sees only these names, descriptions and schemas. It chooses a tool, and writes its
arguments, from that text alone, so the descriptions matter a great deal.

**2. The model answers with a tool request instead of text.** If it decides a tool would help, the
response has `stop_reason: "tool_use"` and contains a `tool_use` block. The model has not run
anything. It has only written down which tool it wants and with what arguments:

```json
{
  "stop_reason": "tool_use",
  "content": [
    {"type": "text", "text": "I'll work that out."},
    {"type": "tool_use", "id": "toolu_01A", "name": "calculate", "input": {"expression": "17 * 23 + 4"}}
  ]
}
```

**3. The agent runs the tool.** The agent reads the `tool_use` block, calls the named tool with those
arguments (`call_tool()`), and gets the output back as text: `395`. If the tool fails, the agent does
not crash: the error text (`Tool error: ...`) is returned as the result, so the model can see what
went wrong and try something else. A single response may contain several `tool_use` blocks. The agent
runs all of them.

**4. The agent sends the result back.** It calls the LLM again. The new request holds the same `system`
and `tools` as before, and the conversation now has two more messages: the model's own tool request
(as an `assistant` message) and the tool's output (as a `user` message, linked to the request by
`tool_use_id`):

```json
"messages": [
  {"role": "user", "content": "What is 17 * 23 + 4?"},
  {"role": "assistant", "content": [
    {"type": "text", "text": "I'll work that out."},
    {"type": "tool_use", "id": "toolu_01A", "name": "calculate", "input": {"expression": "17 * 23 + 4"}}
  ]},
  {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "toolu_01A", "content": "395"}
  ]}
]
```

This time the model has what it needs and replies with text and `stop_reason: "end_turn"`:
*"17 × 23 + 4 = 395."* The agent returns that to the user.

## The loop

Sending a result back can lead to another tool request: a model may need a search, then a calculation
on what the search found. So the agent repeats until the model stops asking:

```
 user message
      │
      ▼
 ┌──▶ call the LLM  (system + tools + whole conversation so far)
 │         │
 │         ├── stop_reason is "end_turn" ──▶ return the text to the user   (done)
 │         │
 │         └── stop_reason is "tool_use"
 │                   │
 │                   ▼
 │            run each requested tool
 │                   │
 │                   ▼
 │            add the request and the results to the conversation
 └───────────────────┘
        (at most 10 times)
```

In code (`run_agent()` in `agent/app.py`), simplified:

```python
for step in range(MAX_STEPS):                       # MAX_STEPS = 10
    response = llm.create(system=SYSTEM, tools=tools, messages=messages)
    messages.append(assistant_message(response))
    if response.stop_reason != "tool_use":
        return text_of(response)                    # finished
    results = [run_tool(block) for block in response.tool_uses]
    messages.append(user_message(results))          # then loop: ask the LLM again
return "(stopped: too many steps)"
```

**The iteration limit.** `MAX_STEPS` caps the loop at 10 calls to the LLM per user message. Without a
cap, a model that keeps requesting tools (confused, or stuck repeating the same failing call) would
loop forever, costing money and time. When the cap is reached the agent gives up and returns
`(stopped: too many steps)`. A normal question takes one to three iterations.

**Why the whole conversation is resent every time.** Because the API keeps no memory, each iteration
sends the conversation so far, including every earlier tool request and result. This is also what makes
the loop work: the model reads its own earlier requests and their results, and continues from there.
Where that conversation is kept between messages, and between restarts, is covered in
[Conversation history](conversation-history.md).

**The same loop for every model.** Claude and a local model (via Ollama) are called through the same
API shape, so the loop is identical for both. Switching models changes only which endpoint
`client.messages.create` talks to.

---

Next: [The UI](ui.md)
