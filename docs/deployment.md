[← How it works](../HOW_IT_WORKS.md) · Appendix

# Deployment

Everything runs in one Kubernetes namespace, `agentic`. `make up` builds and deploys it all; the
manifests are in `k8s/`.

```
                         ┌─────────────────────── namespace "agentic" ───────────────────────┐
 browser ── Ingress ───▶ │ gateway ──▶ agent ──▶ mcp-tools ──▶ qdrant        ollama (models) │
 (or make open)          │                │                       │              │           │
                         │             agent-data             qdrant-storage  ollama-models  │
                         │            (conversations)         (the index)     (the models)   │
                         └────────────────────────────────────────────────────────────────────┘
```

## What runs

| Pod | Image | Job |
|---|---|---|
| `gateway` | built from `gateway/` | The web page and the entry point ([The UI](ui.md)) |
| `agent` | built from `agent/` | The agent loop ([The agent](agent.md)) |
| `mcp-tools` | built from `mcp-tools/` | The tools, including document search ([The MCP server](mcp-server.md)) |
| `qdrant` | `qdrant/qdrant` | The vector database ([Document search](document-search.md)) |
| `ollama` | `ollama/ollama` | Runs the local models: embeddings always, chat optionally ([Model choice](model-choice.md)) |
| `ingest` | built from `ingest/` | A job, not a service: `make ingest` runs it to index the documents |

The four images built from this repo are made by `make up` and loaded into the cluster. On k3s, kind,
k3d, minikube and Docker Desktop that is detected automatically; for a remote cluster they are pushed to
a registry (`REGISTRY=...`).

## Networking

Every pod is reached by name inside the cluster (`agent`, `mcp-tools`, `qdrant`, `ollama`). Only the
gateway is exposed, through an Ingress. `make open` is an alternative that forwards a local port to the
gateway, and works on any cluster, with or without an ingress controller.

## Storage

Four volumes keep data across pod restarts:

| Volume | Holds | Size |
|---|---|---|
| `agent-data` | Conversation history ([Conversation history](conversation-history.md)) | 256 Mi |
| `qdrant-storage` | The document index | 1 Gi |
| `ollama-models` | The downloaded models (about 2.8 GB for the two defaults) | 8 Gi |
| `corpus` | A copy of the documents, for the ingest job (created by `make ingest`) | 512 Mi |

They use the cluster's default storage class. The sizes are requests: some storage classes (the k3s
default among them) do not enforce them, while others allocate and bill the full amount. The models
volume is the only large one; raise it if you want several models on disk. `make clean` deletes the
volumes (or all but the models, with `KEEP_MODELS=1`).

## Configuration

Everything that is specific to the documents (system prompt, what the search tool is described as,
document titles and download links) is in **`corpus.toml`**. It reaches the pods as the `corpus-config`
ConfigMap. After editing it, run `make config`, which publishes it and restarts the agent and tool
server.

**The Anthropic API key** comes from `secret.yaml` as a Secret. It is optional: without it only the
local model works.

**Everything else** is an environment variable in the manifests under `k8s/`. Edit the value, then run
`make up` (or just `bash scripts/apply.sh k8s/<file>.yaml` if only the setting changed). The values
shown are the defaults. For a one-off change without editing a file:
`kubectl -n agentic set env deploy/agent LOG_LLM=false`.

### Agent (`k8s/agent.yaml`)

| Setting | Default | Meaning |
|---|---|---|
| `MODEL` | `claude-sonnet-5-5` | Model name. `make use-local` sets it to the local model |
| `LLM_BASE_URL` | unset | Use another Anthropic-compatible endpoint. `make use-local` sets it to the Ollama service |
| `LLM_API_KEY` | unset | Key for that endpoint (Ollama ignores it) |
| `ANTHROPIC_API_KEY` | from `secret.yaml` | Key for Claude. Optional if you only use the local model |
| `MCP_URL` | `http://mcp-tools:8000/mcp` | Where the tool server is |
| `DB_PATH` | `/data/agent.db` | Where conversation history is stored |
| `MAX_CONTEXT_MESSAGES` | `24` | How many recent messages are sent to the model (all are stored) |
| `LOG_LLM` | `true` | Log every full request to and response from the LLM |
| `ACCESS_LOG` | `true` | Log each HTTP request |
| `CORPUS_CONFIG` | `/config/corpus.toml` | Where `corpus.toml` is mounted (the system prompt) |

### Gateway (`k8s/gateway.yaml`)

| Setting | Default | Meaning |
|---|---|---|
| `AGENT_URL` | `http://agent:8000` | Where the agent is |
| `AGENT_TIMEOUT` | `300` | Seconds to wait for the agent. Not in the manifest; add it to change it |
| `ACCESS_LOG` | `true` | Log each HTTP request |

### Tool server (`k8s/mcp-tools.yaml`)

| Setting | Default | Meaning |
|---|---|---|
| `QDRANT_URL` | `http://qdrant:6333` | Where Qdrant is |
| `OLLAMA_URL` | `http://ollama:11434` | Where Ollama is (it makes the embeddings) |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model. Must match the ingest job |
| `COLLECTION` | `documents_nomic_v1` | Qdrant collection to search. Must match the ingest job |
| `CORPUS_CONFIG` | `/config/corpus.toml` | Where `corpus.toml` is mounted (the search tool description) |

### Ingest job (`k8s/ingest-job.yaml`)

| Setting | Default | Meaning |
|---|---|---|
| `CORPUS_DIR` | `/corpus` | Where the documents are mounted |
| `QDRANT_URL`, `OLLAMA_URL` | as above | Where Qdrant and Ollama are |
| `EMBED_MODEL`, `COLLECTION` | as above | Must match the tool server. A different model needs a new collection name, and `make ingest` then re-indexes everything |
| `CORPUS_CONFIG` | `/config/corpus.toml` | Where `corpus.toml` is mounted (the document titles) |

### Ollama (`k8s/ollama.yaml`)

| Setting | Default | Meaning |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Context window of the local model, in tokens |
| `OLLAMA_KEEP_ALIVE` | `30m` | How long a model stays loaded in memory after use |
| `OLLAMA_NUM_PARALLEL` | `1` | Requests served at once (more uses more memory) |

### `make` variables

| Variable | Default | Meaning |
|---|---|---|
| `LOCAL_MODEL` | `qwen3:4b-instruct` | Local chat model for `make models` and `make use-local` |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model for `make models` (the manifests have their own copy) |
| `CLUSTER` | detected | `k3s`, `kind`, `k3d`, `minikube` or `shared-docker`: how images reach the cluster |
| `REGISTRY` | unset | Push images to a registry instead, e.g. `ghcr.io/you` |

## What `make up` does

1. Builds the four images and loads them into the cluster.
2. Creates the namespace, publishes the config, and applies the secret if `secret.yaml` exists.
3. Applies the manifests for Qdrant, Ollama, the tool server, the agent and the gateway.
4. Restarts the agent, gateway and tool server so they run the new images.
5. Waits until everything is ready.

It is safe to run again, which is how you roll out a code change.

## Limits

- **One replica of each service.** The agent uses a single SQLite file, and Qdrant and Ollama each own
  one volume, so they are replaced one at a time (a brief gap on update).
- **No authentication or encryption.** Anyone who can reach the gateway can use the agent. Keep it on
  your machine or behind your own access controls.
- **`:latest` images** for Qdrant and Ollama are not version-pinned.

---

← Previous: [Document search](document-search.md) · Next: [Model choice](model-choice.md)
