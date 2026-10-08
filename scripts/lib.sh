#!/usr/bin/env bash
# Shared helpers. Source from any script:   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides:
#   ROOT        repository root
#   NS          the namespace everything is deployed into (fixed: the manifests say "agentic")
#   KUBECTL     how to run kubectl on this machine (override with KUBECTL="...")
#   k ...       kubectl, scoped to the namespace
#   in_agent    run a Python script from stdin inside the agent pod (it has Python and the
#               cluster network, so scripts can talk to qdrant/ollama/mcp-tools directly)
#   image_prefix / image_tag   how the images are named (see scripts/build.sh)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=agentic

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL=kubectl
  elif command -v k3s >/dev/null 2>&1; then
    KUBECTL="k3s kubectl"
  elif [ -x /usr/local/bin/k3s ]; then
    KUBECTL="/usr/local/bin/k3s kubectl"
  else
    echo "kubectl not found. Install it, or set KUBECTL='path/to/kubectl'." >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# k3s keeps its own kubeconfig where only root can read it; `scripts/setup-wsl.sh` and the k3s
# docs copy it to ~/.kube/config. Use that if the caller has not chosen one.
if [ -z "${KUBECONFIG:-}" ] && [ -r "$HOME/.kube/config" ]; then
  export KUBECONFIG="$HOME/.kube/config"
fi

k() { $KUBECTL -n "$NS" "$@"; }

in_agent() { k exec -i deploy/agent -- python - "$@"; }

# Image names: agentic/<service>:<tag>, optionally under a registry (REGISTRY=ghcr.io/me).
image_prefix() { echo "${REGISTRY:+${REGISTRY%/}/}agentic"; }

# Local clusters use a fixed tag. With a registry every build gets a unique tag (a pushed
# `dev` would be served stale from node caches), remembered in .build-tag for later commands.
image_tag() {
  if [ -z "${REGISTRY:-}" ]; then
    echo dev
  elif [ -n "${TAG:-}" ]; then
    echo "$TAG"
  else
    cat "$ROOT/.build-tag" 2>/dev/null || echo dev
  fi
}
