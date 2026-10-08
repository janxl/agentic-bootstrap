#!/usr/bin/env bash
# Check that this machine is ready to run the stack, and say how to fix what is not.
# Usage: scripts/doctor.sh      (also: make doctor)
# Order: tools (Docker first), the machine (WSL: systemd and cgroups), the cluster, configuration.
# Every failure comes with the next step to take; on WSL the details are in docs/wsl2.md.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null

CGROUP_DIR="${CGROUP_DIR:-/sys/fs/cgroup}"
bad=0
ok()   { echo "  ok    $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; bad=$((bad + 1)); }
hint() { echo "        -> $1"; }

PROC_VERSION="${PROC_VERSION:-/proc/version}"
wsl=""; wsl2=""
grep -qiE "microsoft|wsl" "$PROC_VERSION" 2>/dev/null && wsl=1
grep -qi "wsl2" "$PROC_VERSION" 2>/dev/null && wsl2=1   # WSL 1 has no real Linux kernel, and its version string lacks "WSL2"

# Is a cluster already reachable? Decides how serious the local-k3s problems below are: they only
# block you if you rely on k3s on this machine (Docker Desktop's Kubernetes, kind, a remote cluster
# etc. do not need them).
cluster_ok=""
[ -n "${KUBECTL:-}" ] && $KUBECTL get nodes --request-timeout=10s >/dev/null 2>&1 && cluster_ok=1
problem() { if [ -n "$cluster_ok" ]; then warn "$1"; else fail "$1"; fi; }

# ---------------------------------------------------------------- tools

echo "Tools"
for t in bash make python3 curl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || fail "$t not found"
done
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys, tomllib' 2>/dev/null && ok "python3 has tomllib (3.11+, needed to read corpus.toml)" \
    || fail "python3 is older than 3.11 (corpus.toml needs tomllib)"
fi

if command -v docker >/dev/null 2>&1; then
  err="$(docker info 2>&1 >/dev/null)"; rc=$?
  if [ $rc -eq 0 ]; then
    ok "docker (daemon reachable)"
  elif echo "$err" | grep -qi "permission denied"; then
    fail "docker: permission denied talking to the daemon"
    hint "add yourself to the docker group: sudo usermod -aG docker \$USER, then close and reopen the terminal"
  else
    fail "docker is installed but the daemon is not reachable"
    if [ -n "$wsl" ]; then
      hint "start Docker Desktop (with WSL integration on), or start the daemon here: sudo service docker start"
    else
      hint "start it: sudo systemctl start docker  (on Docker Desktop, open the app)"
    fi
  fi
elif [ -n "$wsl" ] && command -v docker.exe >/dev/null 2>&1; then
  fail "Docker is installed on Windows but not connected to this WSL distro"
  hint "Docker Desktop > Settings > Resources > WSL integration: switch on this distro, Apply & restart, then reopen the terminal"
  hint "or install Docker inside WSL instead: sudo apt-get install -y docker.io  (docs/wsl2.md)"
elif [ -n "$wsl" ]; then
  fail "docker not found (needed to build the images)"
  hint "install Docker Desktop and enable its WSL integration, or: sudo apt-get install -y docker.io  (docs/wsl2.md)"
else
  fail "docker not found (needed to build the images)"
  hint "install it: https://docs.docker.com/engine/install/"
fi

# ---------------------------------------------------------------- the machine

echo "System"
if [ -n "$wsl" ] && [ -z "$wsl2" ]; then
  # WSL 1 translates system calls instead of running a Linux kernel: no cgroups, no systemd, no
  # Kubernetes, and .wslconfig does not apply. The checks below would only mislead.
  problem "this is WSL 1, which cannot run Kubernetes (no Linux kernel, cgroups or systemd)"
  hint "in PowerShell: 'wsl -l -v' shows the version; convert with 'wsl --set-version <distro> 2'  (docs/wsl2.md)"
else
  if [ -n "$wsl" ]; then
    ok "running in WSL2"
    if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = systemd ]; then
      ok "systemd is running"
    else
      problem "systemd is not running (k3s runs as a systemd service)"
      hint "add these two lines to /etc/wsl.conf, then run 'wsl --shutdown' in PowerShell:  [boot]  systemd=true  (docs/wsl2.md)"
    fi
  fi
  if [ -r "$CGROUP_DIR/cgroup.controllers" ]; then
    ok "cgroup v2"
  elif [ -d "$CGROUP_DIR" ]; then
    problem "cgroup v1: current k3s refuses to start on it"
    if [ -n "$wsl" ]; then
      hint "add 'kernelCommandLine = cgroup_no_v1=all' under [wsl2] in %UserProfile%\\.wslconfig, then 'wsl --shutdown' (docs/wsl2.md)"
    else
      hint "boot the system with cgroup v2 (systemd.unified_cgroup_hierarchy=1); most current distributions default to it"
    fi
  fi
fi
if [ -r /proc/meminfo ]; then
  gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  if [ "$gb" -ge 9 ]; then
    ok "memory visible here: ${gb} GB"
  else
    warn "only ${gb} GB visible here; the local model needs about 6 GB spare"
    [ -n "$wsl" ] && hint "raise 'memory=' under [wsl2] in %UserProfile%\\.wslconfig, then 'wsl --shutdown' (docs/wsl2.md)"
  fi
fi

# ---------------------------------------------------------------- the cluster

echo "Cluster"
if [ -z "${KUBECTL:-}" ]; then
  fail "kubectl not found"
  if [ -n "$wsl" ]; then
    hint "run 'bash scripts/setup-wsl.sh' (it installs k3s, which includes kubectl), or install kubectl and use Docker Desktop's Kubernetes"
  else
    hint "install kubectl: https://kubernetes.io/docs/tasks/tools/   (or set KUBECTL=...)"
  fi
elif [ -n "$cluster_ok" ]; then
  ok "kubectl: $KUBECTL"
  ctx="$($KUBECTL config current-context 2>/dev/null)"
  ok "cluster reachable (context '$ctx')"
  $KUBECTL get nodes --no-headers 2>/dev/null | sed 's/^/        /'
  delivery="$(bash "$ROOT/scripts/load-images.sh" --detect 2>/dev/null)"
  ok "images will be delivered by: $delivery  (override: CLUSTER=... or REGISTRY=...)"
  [ "$delivery" = unknown ] && fail "cannot tell how to load images into this cluster: set CLUSTER=... or REGISTRY=..."
  if $KUBECTL get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -q true; then
    ok "a default StorageClass exists (the volumes need one)"
  else
    fail "no default StorageClass: the PersistentVolumeClaims would stay Pending"
  fi
  [ -n "$($KUBECTL get ingressclass -o name 2>/dev/null)" ] && ok "an ingress controller is installed" \
    || warn "no ingress controller: fine, 'make open' port-forwards instead"
else
  ok "kubectl: $KUBECTL"
  fail "cannot reach a cluster with that kubectl"
  if [ -n "$wsl" ]; then
    if [ -z "$wsl2" ]; then
      hint "this distro is WSL 1, which cannot run a cluster: fix that first (see System above)"
    elif ! command -v k3s >/dev/null 2>&1 && [ ! -x /usr/local/bin/k3s ]; then
      hint "k3s is not installed here: run 'bash scripts/setup-wsl.sh', or enable Kubernetes in Docker Desktop (docs/wsl2.md)"
    elif [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
      hint "k3s is installed but has not started (it has not written /etc/rancher/k3s/k3s.yaml): sudo systemctl status k3s, sudo journalctl -u k3s -n 30"
      hint "most often systemd or cgroup v2 is missing: see the System checks above (docs/wsl2.md)"
    elif [ ! -f "$HOME/.kube/config" ]; then
      hint "copy k3s's config: mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
    else
      hint "k3s may still be starting (about 30 seconds after boot): sudo systemctl status k3s"
    fi
  else
    hint "start your cluster (k3s, kind, minikube, Docker Desktop's Kubernetes) and check that 'kubectl get nodes' works, or set KUBECONFIG"
  fi
fi

# ---------------------------------------------------------------- configuration

echo "Configuration"
[ -f "$ROOT/secret.yaml" ] && ok "secret.yaml present (Claude available)" \
  || warn "no secret.yaml: only the local model will work (cp secret.example.yaml secret.yaml and add a key for Claude)"

echo
if [ $bad -eq 0 ]; then
  echo "Ready."
else
  echo "$bad problem(s) to fix first."
  [ -n "$wsl" ] && echo "WSL help: docs/wsl2.md"
  exit 1
fi
