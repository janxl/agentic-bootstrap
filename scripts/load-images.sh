#!/usr/bin/env bash
# Get locally built images to where the cluster can run them.
#   Usage: scripts/load-images.sh <image> [<image> ...]     |     scripts/load-images.sh --detect
#
# The right method depends on the cluster. It is detected from the kubectl context, or set it:
#   CLUSTER=k3s | kind | k3d | minikube | shared-docker | registry
#   REGISTRY=ghcr.io/you   (implies CLUSTER=registry: images are pushed and the cluster pulls them)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

ctx="$($KUBECTL config current-context 2>/dev/null || true)"

detect() {
  if [ -n "${CLUSTER:-}" ] && [ "$CLUSTER" != auto ]; then echo "$CLUSTER"; return; fi
  if [ -n "${REGISTRY:-}" ]; then echo registry; return; fi
  case "$ctx" in
    kind-*) echo kind ;;
    k3d-*) echo k3d ;;
    minikube*) echo minikube ;;
    docker-desktop|docker-for-desktop) echo shared-docker ;;
    *) if command -v k3s >/dev/null 2>&1 || [ -x /usr/local/bin/k3s ]; then echo k3s; else echo unknown; fi ;;
  esac
}

kind_of_cluster="$(detect)"
if [ "${1:-}" = "--detect" ]; then echo "$kind_of_cluster"; exit 0; fi
[ $# -gt 0 ] || { echo "usage: $0 <image>... | --detect" >&2; exit 2; }
echo "loading images ($kind_of_cluster, kubectl context '${ctx:-?}'): $*" >&2

case "$kind_of_cluster" in
  k3s)
    # k3s runs its own containerd, separate from Docker: import the images into it (needs root).
    k3s_bin="$(command -v k3s || echo /usr/local/bin/k3s)"
    docker save "$@" | sudo "$k3s_bin" ctr images import -
    ;;
  kind)
    kind load docker-image --name "${ctx#kind-}" "$@"
    ;;
  k3d)
    k3d image import -c "${ctx#k3d-}" "$@"
    ;;
  minikube)
    for img in "$@"; do minikube image load -p "$ctx" "$img"; done
    ;;
  shared-docker)
    echo "the cluster shares the local Docker daemon: nothing to load" >&2
    ;;
  registry)
    [ -n "${REGISTRY:-}" ] || { echo "CLUSTER=registry needs REGISTRY=<host/path>" >&2; exit 1; }
    for img in "$@"; do docker push "$img"; done
    echo "pushed. The cluster must be able to pull from $REGISTRY (imagePullSecrets if it is private)." >&2
    ;;
  *)
    cat >&2 <<EOF
Could not tell how to get images into this cluster (kubectl context: '${ctx:-none}').
Tell me with one of:
  CLUSTER=k3s|kind|k3d|minikube|shared-docker make up
  REGISTRY=ghcr.io/you make up           # push to a registry the cluster can pull from
EOF
    exit 1
    ;;
esac
