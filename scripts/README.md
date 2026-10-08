# Scripts

Most of these are called by `make`; you rarely run them directly. `make help` lists the commands.

## Called by `make`

| Script | Used by | What it does |
|---|---|---|
| `doctor.sh` | `make doctor` | Checks the machine is ready: tools (Docker first), Python version, systemd and cgroups on WSL, memory, the cluster and its default storage class. Every failure comes with the next step; WSL-specific hints appear only when WSL is detected. |
| `build.sh` | `make up` | Builds the four images (agent, gateway, mcp-tools, ingest) and hands them to `load-images.sh`. |
| `load-images.sh` | `build.sh` | Gets the built images to the cluster, whichever kind it is: k3s, kind, k3d, minikube, Docker Desktop, or a registry. `--detect` prints which one it found. |
| `apply.sh` | `make up`, `ingest` | Applies manifests, pointing the image names at the registry and tag in use (no change for local clusters). |
| `apply-config.sh` | `make up`, `config`, `ingest` | Checks `corpus.toml` is valid TOML, then publishes it to the cluster as the `corpus-config` ConfigMap. |
| `download_corpus.py` | `make ingest` | Downloads the documents listed in `corpus.toml` from their original sources into `corpus/`, and writes `corpus/SOURCES.md`. Skips files already there. |
| `upload-corpus.sh` | `make ingest` | Copies `corpus/` into the cluster's `corpus` volume, mirroring deletions, so the ingest job can read it. |
| `portforward.sh` | `make open` | Serves the UI on `http://localhost:8080` (or the port you pass) and reconnects after a redeploy. |
| `status.sh` | `make status` | Shows what is running, recent warnings and the last log lines of each service. |
| `test-tools.sh` | `make test` | Runs `tools_test.py` inside the agent pod. |
| `tools_test.py` | `test-tools.sh` | The checks: every tool, bad inputs, a non-existent tool, and document search against the expectations in `corpus.toml`. Needs no LLM. |
| `test-persistence.sh` | `make test-persistence` | Chats, restarts the agent pod mid-conversation, and checks the history survived. |
| `clean.sh` | `make clean` | Deletes everything deployed (and optionally images and downloaded files), after asking. Supports `DRY_RUN=1`, `KEEP_MODELS=1`, `IMAGES=1`, `LOCAL=1`, `YES=1`. |

## Shared helpers

| Script | What it does |
|---|---|
| `lib.sh` | Sourced by the other scripts. Finds `kubectl` and the kubeconfig, defines `k` (kubectl in the app namespace) and `in_agent` (run Python inside the agent pod), and names the images. |
| `k.sh` | `kubectl` in the app namespace using the same discovery as `lib.sh`. The Makefile calls this so it never needs to know where `kubectl` is. |

## Run by hand

| Script | What it does |
|---|---|
| `setup-wsl.sh` | Optional. Installs Docker and a single-node k3s inside WSL2 (see [docs/wsl2.md](../docs/wsl2.md) for the steps around it). |
| `search.sh "question" [top_k] [--full]` | Runs a document search and prints one line per hit (source, page, score), or the full passages with `--full`. For checking what retrieval returns. |
| `show-prompt.sh` | Prints the system prompt and the `search_documents` description exactly as the agent has them. |
| `qdrant-count.sh [collection]` | Shows how many chunks are indexed, per document. |
