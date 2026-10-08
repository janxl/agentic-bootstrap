[← How it works](../HOW_IT_WORKS.md) · Appendix

# Model choice

The system uses two different models for two different jobs.

| | Job | Where it runs | Default |
|---|---|---|---|
| **Chat model** | Reads the conversation, decides which tools to call, writes the answer | Claude through the API, **or** locally in Ollama | Claude (`claude-sonnet-5-5`) |
| **Embedding model** | Turns text into vectors for document search ([Document search](document-search.md)) | Always locally, in Ollama | `nomic-embed-text` |

Search needs the embedding model even when the chat model is Claude, so Ollama runs either way.

## Switching the chat model

The agent talks to its LLM through one API shape, and Ollama offers the same shape, so the agent loop
([The agent](agent.md)) is identical for both. Switching only changes where the agent sends its requests:

```bash
make use-local     # local model in Ollama
make use-claude    # back to Claude
```

`make use-local` points the agent at the Ollama service (`LLM_BASE_URL`) and names the local model
(`MODEL`); `make use-claude` removes those settings. Claude needs an API key in `secret.yaml`.

## Which to use

| | Claude | Local model |
|---|---|---|
| **Answer quality** | Strong | Noticeably weaker |
| **Using tools** | Reliable | A small model sometimes answers from memory instead of calling a tool, or picks the wrong one |
| **Speed** | Seconds | Slow on a CPU: expect several seconds to tens of seconds per answer |
| **Cost** | Pay per use | Free once downloaded |
| **Privacy** | Questions and retrieved passages go to the API | Everything stays on your machine |
| **Needs** | An API key | About 6 GB of free memory and a 2.5 GB download |

Claude is the better choice for results. The local model is for trying the system with no account, no
cost and no data leaving the machine.

## The local model

The default is `qwen3:4b-instruct`: small enough for a laptop, and able to call tools. It is an
*instruct* model, which answers directly. A model that "reasons" first
spends most of its output on long hidden thinking, which is slow on a CPU and uses up the limited
context window.

Ollama runs it on the CPU. Settings in `k8s/ollama.yaml`:

- `OLLAMA_CONTEXT_LENGTH` (8192): how much text the model can read at once.
- `OLLAMA_KEEP_ALIVE` (30 minutes): how long it stays in memory after use. The first answer after that
  is slower, while the model reloads.

To try a different model:

```bash
LOCAL_MODEL=<name> make models     # download it
LOCAL_MODEL=<name> make use-local  # switch to it
```

Pick one that supports tool calling (the Ollama model library says which).

## Changing the embedding model

Vectors from different models cannot be compared, so every document has to be embedded again. Change
`EMBED_MODEL` and `COLLECTION` (to a new name) in the tool server and ingest manifests, then run
`make ingest`, which re-indexes everything.

---

← Previous: [Deployment](deployment.md)
