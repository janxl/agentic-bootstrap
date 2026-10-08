# Thin wrapper over scripts/. Run `make` (or `make help`) for the list.
# Needs: bash, make, python3, curl, docker, and a Kubernetes cluster that kubectl can reach.
SHELL := /bin/bash

LOCAL_MODEL ?= qwen3:4b-instruct
EMBED_MODEL ?= nomic-embed-text

# Cluster / image delivery (see scripts/load-images.sh):
#   CLUSTER=k3s|kind|k3d|minikube|shared-docker   (default: detected from the kubectl context)
#   REGISTRY=ghcr.io/you                          (push images instead; the cluster pulls them)
export CLUSTER REGISTRY KEEP_MODELS IMAGES LOCAL YES DRY_RUN   # CLUSTER/REGISTRY: image delivery; the rest: `make clean`

K := bash scripts/k.sh
APPS := mcp-tools agent gateway

.DEFAULT_GOAL := help
.PHONY: help doctor up config models use-local use-claude ingest \
        open logs status test test-persistence clean

help:  ## show this list
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  make %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor:  ## check this machine is ready (tools, cluster, storage, memory) and say how to fix gaps
	@bash scripts/doctor.sh

# ---- first-time setup: make doctor; make up; make models; make use-local; make ingest

up:  ## build and deploy everything (first install, and again after any code change)
	bash scripts/build.sh
	bash scripts/apply.sh k8s/namespace.yaml
	bash scripts/apply-config.sh
	@if [ -f secret.yaml ]; then bash scripts/apply.sh secret.yaml; \
	  else echo "note: no secret.yaml, so no Anthropic key: only the local model will work (see README)"; fi
	bash scripts/apply.sh k8s/qdrant.yaml k8s/ollama.yaml k8s/mcp-tools.yaml k8s/agent.yaml k8s/gateway.yaml
	$(K) rollout restart $(addprefix deploy/,$(APPS))
	@for d in qdrant ollama $(APPS); do $(K) rollout status deploy/$$d --timeout=600s || exit 1; done
	@echo; echo "Up. First time? Next: make models; make use-local (or add secret.yaml for Claude); make ingest; make open"

config:  ## after editing corpus.toml (prompt, topics, titles): publish it and restart agent + tools
	bash scripts/apply-config.sh
	$(K) rollout restart deploy/agent deploy/mcp-tools
	@for d in agent mcp-tools; do $(K) rollout status deploy/$$d --timeout=300s || exit 1; done

# ---- models

models:  ## download the chat model (~2.5 GB) and the embedding model (~270 MB) into Ollama
	$(K) exec deploy/ollama -- ollama pull $(LOCAL_MODEL)
	$(K) exec deploy/ollama -- ollama pull $(EMBED_MODEL)

use-local:  ## point the agent at the local Ollama model (loads it into memory first, so chat 1 is not slow)
	$(K) exec deploy/ollama -- ollama run $(LOCAL_MODEL) --keepalive 30m "hi" >/dev/null
	$(K) set env deploy/agent LLM_BASE_URL=http://ollama:11434 LLM_API_KEY=ollama MODEL=$(LOCAL_MODEL)

use-claude:  ## point the agent back at Claude (needs secret.yaml)
	$(K) set env deploy/agent LLM_BASE_URL- LLM_API_KEY- MODEL-

# ---- documents

ingest:  ## download any missing documents listed in corpus.toml (~14 MB), then index corpus/ (idempotent)
	python3 scripts/download_corpus.py
	bash scripts/apply-config.sh
	bash scripts/upload-corpus.sh
	$(K) delete job ingest --ignore-not-found
	bash scripts/apply.sh k8s/ingest-job.yaml
	@$(K) wait --for=condition=ready pod -l job-name=ingest --timeout=180s || true
	$(K) logs -f job/ingest

# ---- day to day

open:  ## serve the UI on http://localhost:8080 (leave running)
	bash scripts/portforward.sh

logs:  ## follow the agent logs (full LLM requests/responses unless LOG_LLM=false)
	$(K) logs -f deploy/agent

status:  ## what is running, recent warnings, log tails
	@bash scripts/status.sh

test:  ## every tool plus document search, which also proves Qdrant and embeddings work (no LLM)
	bash scripts/test-tools.sh

test-persistence:  ## chat, restart the agent mid-conversation, check the history survived
	bash scripts/test-persistence.sh

clean:  ## delete everything deployed, to start over (asks first; KEEP_MODELS=1 IMAGES=1 LOCAL=1 DRY_RUN=1)
	@bash scripts/clean.sh
