# agentic

A small agent framework that runs on Kubernetes on your own machine: a chat UI, an agent with tools,
and document search.

**New here?** [How it works](HOW_IT_WORKS.md) explains how the pieces fit together.

## 1. Install

**Requirements:** Docker, `kubectl`, `make`, `curl`, Python 3.11+, and a Kubernetes cluster. About
6 GB of free memory for the local model. Linux and macOS work directly; on Windows use WSL2.

> **Note:** only tested on WSL2 with k3s. The other clusters below are supported by the scripts but
> have not been verified yet.

**Get a cluster** (skip if you already have one that `kubectl` can reach):

- **Docker Desktop:** enable Kubernetes in its settings.
- **kind / minikube / k3d:** `kind create cluster`, `minikube start` or `k3d cluster create`.
- **k3s on Linux:** `curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644`, then
  `mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config`.
- **A remote cluster:** point `kubectl` at it and use `REGISTRY=ghcr.io/you` in the `make up` step below.

<details>
<summary>Windows (WSL2) setup</summary>

Add this to `%UserProfile%\.wslconfig`, run `wsl --shutdown` in PowerShell, reopen WSL, and then
install k3s inside WSL:

```ini
[wsl2]
kernelCommandLine = cgroup_no_v1=all
memory=10GB
```

```bash
bash scripts/setup-wsl.sh
```

</details>

**Deploy:**

```bash
make doctor                          # check this machine is ready
cp secret.example.yaml secret.yaml   # optional: add your Anthropic API key (skip to use only the local model)
make up                              # build the images and deploy everything
make models                          # download the local models (~2.8 GB)
make use-local                       # use the local model (skip if you added an API key and want Claude)
make ingest                          # download the demo documents (~14 MB) and index them (several minutes)
```

Images are loaded into the cluster automatically (the right way for k3s, kind, k3d, minikube and
Docker Desktop is detected). `make help` lists every target.

## 2. Test

```bash
make open
```

Open **http://localhost:8080** (leave `make open` running) and try:

- `What happened to NSW prices in Q4 2025?`: searches the documents and answers with sources.
- `What is 17 * 23 + 4?`: uses the calculator tool.
- Reload the page: the conversation comes back. **New chat** starts a fresh one.

Automated checks: `make test`, and `make test-persistence`.

## 3. Clean up

```bash
make clean                  # delete everything deployed (asks first)
```

Options, which can be combined:

```bash
make clean DRY_RUN=1        # only show what would be deleted
make clean KEEP_MODELS=1    # keep the downloaded models
make clean IMAGES=1         # also delete the built images
make clean LOCAL=1          # also delete the downloaded demo documents
make clean YES=1            # no confirmation prompt
```

Settings and what they do: [Configuration](docs/deployment.md#configuration).
