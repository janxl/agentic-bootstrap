[← How it works](../HOW_IT_WORKS.md)

# The UI

The [agent](agent.md) has no screen. It is a web service with a very small HTTP API, and the UI is
just one way of talking to it. The UI here is deliberately minimal, and it could be replaced by (or
sit alongside) any other channel.

```
 browser ──▶ gateway (gateway/app.py) ──▶ agent (agent/app.py)
              serves the page                runs the agent loop
              forwards the messages
```

## The agent's API

Two endpoints are all the agent exposes to the outside:

| Endpoint | What it does |
|---|---|
| `POST /chat` | Takes `{"session_id": "...", "message": "..."}` and returns `{"reply": "..."}` after running the loop |
| `GET /sessions/<id>/messages` | Returns what a person saw in that conversation, so a channel can redraw it |

The `session_id` is how the agent tells conversations apart (see
[Conversation history](conversation-history.md) for what it is used for). The agent knows nothing about
HTML, browsers or buttons.

## The gateway and the page

The gateway (`gateway/app.py`, about 50 lines) is the only thing exposed outside the cluster. It does
three things:

- Serves the chat page at `/`.
- Forwards `POST /chat` to the agent and returns the reply.
- Forwards `GET /history/<id>` to the agent so the page can redraw an earlier conversation.

It also waits up to five minutes for the agent (`AGENT_TIMEOUT`), because a local model can be slow,
and turns agent failures into readable messages for the page.

The page itself (`gateway/static/index.html`) is one file of plain HTML and JavaScript, with no
framework and no build step. When you press Send it posts the message to `/chat`, shows a "Thinking...
12s" counter while it waits, and prints the reply. It keeps its session id in the browser, so a
reload shows the same conversation, and **New chat** starts a new id.

## Any other channel

Because the agent's whole contract is "send a message with a conversation id, get a reply", a
different front end only has to make that one call. For example:

- **A chat app** (Slack, Teams): the bot calls `/chat`, using the channel or thread id as `session_id`.
- **A command-line tool or a script**, which posts to the same endpoint.
- **Another service or agent**, calling it as a function.
- **Voice or email**, with a small bridge that turns speech or mail into a message and the reply back.

Only the web page exists today; the others are examples, not something built. And the gateway has no
login, so anyone who can reach it can use the agent. Replies also arrive all at once rather than
streaming word by word.

Keeping the gateway separate from the agent has a practical benefit: channel details (pages, timeouts,
and later logins or message formatting) stay out of the agent, and the agent is never exposed to the
outside directly. A new channel is a new gateway, and the agent does not change.

---

← Previous: [The agent](agent.md) · Next: [The MCP server](mcp-server.md)
