# How it works

You talk to an **agent**: a program that sends your message to an LLM and, when the LLM asks for it,
runs tools and passes the results back. The tools live in their own server, and one of them searches
your documents. The agent remembers each conversation in a small database, and a simple web page lets
you chat with it.

```
 you ──▶ web page ──▶ gateway ──▶ agent ──▶ LLM  (Claude, or a local model)
                                    │
                                    ├──▶ conversation history  (SQLite)
                                    │
                                    └──▶ tools (MCP server)
                                           └── document search ──▶ Qdrant + embeddings (Ollama)
```

Each part has its own page. Read them in order for the full picture, or jump to the one you care about.

## [The agent](docs/agent.md)

The loop at the heart of everything: send the conversation and a list of tools to the LLM; if it asks
for a tool, run it, send the result back, and repeat (up to 10 times) until it answers.

## [The UI](docs/ui.md)

A minimal web page and a small gateway in front of the agent. The agent only needs "a message and a
conversation id in, a reply out", so the web page is one channel among many that could be added.

## [The MCP server](docs/mcp-server.md)

The tools sit behind an MCP server, a standard interface, so the agent has one way to list and call any
tool, and adding a tool is writing one function without changing the agent.

## [Conversation history](docs/conversation-history.md)

Every message is stored in SQLite, so conversations survive restarts and page reloads, and the model
can be sent the recent part of the conversation each time.

## [Document search](docs/document-search.md)

Documents are split into passages, turned into vectors with an embedding model, and stored in the
Qdrant vector database. A search tool finds the passages closest in meaning to a question, so the agent
can answer from documents the LLM was never trained on.

---

## Appendix

How the system is run and configured, rather than how its pieces fit together.

### [Deployment](docs/deployment.md)

Everything runs as pods in one Kubernetes namespace, with volumes for the data that must survive a
restart. `make up` builds the images and deploys the lot, and it is safe to run again after a change.

### [Model choice](docs/model-choice.md)

The chat model is either Claude or a small local model, switched with one command; a separate local
embedding model powers document search either way. The page compares the two and says how to change them.
