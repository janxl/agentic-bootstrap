#!/usr/bin/env bash
# Check that this machine is ready to run the stack, and say how to fix what is not.
# Usage: scripts/doctor.sh      (also: make doctor)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null
bad=0
ok()   { echo "  ok    $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; bad=$((bad + 1)); }

echo "Tools"
for t in bash make python3 curl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || fail "$t not found"
done
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys, tomllib' 2>/dev/null && ok "python3 has tomllib (3.11+, needed to read corpus.toml)" \
    || fail "python3 is older than 3.11 (corpus.toml needs tomllib)"
fi
if command -v docker >/dev/null 2>&1; then
  docker info >/dev/null 2>&1 && ok "docker (daemon reachable)" || fail "docker is installed but the daemon is not reachable"
else
  fail "docker not found (needed to build the images)"
fi

echo "Cluster"
if [ -z "${KUBECTL:-}" ]; then
  fail "kubectl not found (install it, or set KUBECTL=...)"
else
  ok "kubectl: $KUBECTL"
  if $KUBECTL get nodes >/dev/null 2>&1; then
    ctx="$($KUBECTL config current-context 2>/dev/null)"
    ok "cluster reachable (context '$ctx')"
    $KUBECTL get nodes --no-headers 2>/dev/null | sed 's/^/        /'
    ok "images will be delivered by: $(bash "$ROOT/scripts/load-images.sh" --detect 2>/dev/null)  (override: CLUSTER=... or REGISTRY=...)"
    [ "$(bash "$ROOT/scripts/load-images.sh" --detect 2>/dev/null)" = unknown ] && fail "cannot tell how to load images into this cluster: set CLUSTER=... or REGISTRY=..."
    if $KUBECTL get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -q true; then
      ok "a default StorageClass exists (the volumes need one)"
    else
      fail "no default StorageClass: the PersistentVolumeClaims would stay Pending"
    fi
    [ -n "$($KUBECTL get ingressclass -o name 2>/dev/null)" ] && ok "an ingress controller is installed" \
      || warn "no ingress controller: fine, 'make open' port-forwards instead"
  else
    fail "cannot reach a cluster with that kubectl (is it running? is the kubeconfig set?)"
  fi
fi

echo "Configuration"
[ -f "$ROOT/secret.yaml" ] && ok "secret.yaml present (Claude available)" \
  || warn "no secret.yaml: only the local model will work (cp secret.example.yaml secret.yaml and add a key for Claude)"
if [ -r /proc/meminfo ]; then
  gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  [ "$gb" -ge 9 ] && ok "memory visible here: ${gb} GB" || warn "only ${gb} GB visible here; the local model needs ~6 GB spare (on WSL2 raise memory= in .wslconfig)"
fi
if [ -r /sys/fs/cgroup/cgroup.controllers ]; then ok "cgroup v2"; \
elif [ -d /sys/fs/cgroup ]; then warn "cgroup v1: current k3s/kubelet versions refuse to start (on WSL2 add kernelCommandLine = cgroup_no_v1=all to .wslconfig)"; fi

echo
[ $bad -eq 0 ] && echo "Ready." || { echo "$bad problem(s) to fix first."; exit 1; }
