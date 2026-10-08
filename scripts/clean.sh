#!/usr/bin/env bash
# Remove what this project deployed, so you can start again from scratch with `make up`.
#
#   make clean                  everything in the cluster: the whole namespace, including its data
#                               (downloaded models, the document index, conversations, uploaded corpus)
#   make clean KEEP_MODELS=1    same, but keep the Ollama volume so the models are not downloaded again
#   make clean IMAGES=1         also delete the built images (Docker, and k3s's containerd)
#   make clean LOCAL=1          also delete the demo documents downloaded into corpus/ and .build-tag
#   make clean DRY_RUN=1        only show what would be deleted
#   make clean YES=1            do not ask for confirmation (for scripts)
# Options combine, e.g.  make clean KEEP_MODELS=1 IMAGES=1
#
# Never touched: the cluster itself, Docker, secret.yaml, corpus.toml, and any file you put in corpus/
# yourself (only the files corpus.toml downloads are removed by LOCAL=1).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
set -uo pipefail

KEEP_MODELS="${KEEP_MODELS:-}"; IMAGES="${IMAGES:-}"; LOCAL="${LOCAL:-}"; YES="${YES:-}"; DRY_RUN="${DRY_RUN:-}"
IMAGE_PATTERN='(^|/)agentic/(agent|gateway|mcp-tools|ingest):'

ctx="$($KUBECTL config current-context 2>/dev/null || echo '?')"
have_ns() { $KUBECTL get namespace "$NS" >/dev/null 2>&1; }

# Files that corpus.toml downloads (and so can be fetched again), never files you added yourself.
downloaded_files() {
  python3 - "$ROOT" <<'EOF'
import sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
try:
    docs = tomllib.loads((root / "corpus.toml").read_text(encoding="utf-8")).get("documents", [])
except FileNotFoundError:
    docs = []
for d in docs:
    p = root / "corpus" / d.get("file", "")
    if d.get("url") and d.get("file") and p.is_file():
        print(p)
EOF
}

# ---------------------------------------------------------------- the plan

echo "Kubernetes context: $ctx"
echo
if have_ns; then
  echo "In the cluster (namespace '$NS'):"
  k get deploy,job,svc,ingress,configmap,secret,pvc --no-headers 2>/dev/null | sed 's/^/    /' | grep -v 'kube-root-ca'
  echo
  if [ -n "$KEEP_MODELS" ]; then
    echo "  -> DELETE all of it except the 'ollama-models' volume (the downloaded models are kept)."
  else
    echo "  -> DELETE the whole namespace, including its DATA: the downloaded models (Ollama), the document"
    echo "     index (Qdrant), conversation history (agent) and the uploaded corpus."
    echo "     (To keep the models, which are the slow part to download again: KEEP_MODELS=1)"
  fi
else
  echo "Nothing to delete in the cluster: namespace '$NS' does not exist."
fi
[ -n "$IMAGES" ] && echo "  -> DELETE the built images (agentic/*) from Docker, and from k3s if that is the cluster."
files="$(downloaded_files)"
if [ -n "$LOCAL" ]; then
  echo "  -> DELETE .build-tag and the downloaded documents:"
  [ -n "$files" ] && echo "$files" | sed 's#^.*/corpus/#       corpus/#' || echo "       (none downloaded)"
fi
echo
echo "Kept: the cluster, Docker, secret.yaml, corpus.toml, and any files you added to corpus/ yourself."
if [ -z "$LOCAL" ] && [ -n "$files" ]; then
  echo "Also kept: the $(echo "$files" | wc -l | tr -d ' ') documents downloaded into corpus/ (add LOCAL=1 to delete them)."
fi

if [ -n "$DRY_RUN" ]; then echo; echo "Dry run: nothing deleted."; exit 0; fi

# ---------------------------------------------------------------- confirm

if [ -z "$YES" ]; then
  if [ -t 0 ]; then
    echo
    read -r -p "Type 'yes' to delete: " answer
    [ "$answer" = yes ] || { echo "Aborted: nothing deleted."; exit 1; }
  else
    echo "Not a terminal, so I cannot ask: re-run with YES=1 to confirm." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- delete

echo
if have_ns; then
  if [ -n "$KEEP_MODELS" ]; then
    echo "Deleting workloads, config and volumes (keeping the models volume)..."
    k delete deployment,statefulset,job,pod,service,ingress,configmap,secret --all --wait=true --timeout=180s
    k delete pvc agent-data qdrant-storage corpus --ignore-not-found --wait=true --timeout=180s
  else
    echo "Deleting namespace '$NS' (can take a minute while volumes are released)..."
    $KUBECTL delete namespace "$NS" --wait=true --timeout=240s \
      || echo "The namespace is still terminating. Check: $KUBECTL get namespace $NS -o yaml  (stuck finalizers)." >&2
  fi
  # The storage provisioner removes a claim's volume a few seconds after the claim goes (k3s local-path),
  # or never, if the storage class retains data. Wait a little, then say which ones are left.
  leftover_volumes() {
    $KUBECTL get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NS:.spec.claimRef.namespace --no-headers 2>/dev/null \
      | awk -v ns="$NS" -v keep="${KEEP_MODELS:+ollama-models}" '$3==ns && $2!=keep'
  }
  for _ in $(seq 1 30); do [ -z "$(leftover_volumes)" ] && break; sleep 2; done
  left="$(leftover_volumes)"
  if [ -n "$left" ]; then
    echo "These volumes outlived their claims (this storage class retains data); delete them with 'kubectl delete pv <name>':" >&2
    echo "$left" | sed 's/^/    /' >&2
  fi
fi

if [ -n "$IMAGES" ]; then
  echo "Deleting built images..."
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "$IMAGE_PATTERN" | while read -r img; do docker rmi "$img"; done
  cluster="$(bash "$ROOT/scripts/load-images.sh" --detect 2>/dev/null)"
  case "$cluster" in
    k3s)
      k3s_bin="$(command -v k3s || echo /usr/local/bin/k3s)"
      sudo "$k3s_bin" ctr images ls -q | grep -E "$IMAGE_PATTERN" | while read -r img; do sudo "$k3s_bin" ctr images rm "$img"; done
      ;;
    kind|k3d|minikube)
      echo "Images loaded into the $cluster node are not removed here; they go when you delete that cluster." ;;
    registry)
      echo "Images pushed to $REGISTRY are not removed (delete them in the registry if you want)." ;;
  esac
fi

if [ -n "$LOCAL" ]; then
  echo "Deleting local files..."
  rm -fv "$ROOT/.build-tag"
  downloaded_files | while read -r f; do rm -v "$f"; done
fi

echo
echo "Clean. To start again: make up, then make models, make use-local, make ingest (see README)."
