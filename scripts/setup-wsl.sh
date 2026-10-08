#!/usr/bin/env bash
# OPTIONAL one-time setup for a single-node k3s inside WSL2 Ubuntu (needs sudo).
# Anywhere else, use your own cluster: k3s, kind, minikube, Docker Desktop, or a remote one.
# Run: bash scripts/setup-wsl.sh        (read docs/wsl2.md first)
set -euo pipefail

# WSL2 kernels default to cgroup v1, which current k3s refuses to run on. Check before installing.
if [ ! -r /sys/fs/cgroup/cgroup.controllers ]; then
  cat >&2 <<'EOF'
This WSL2 is using cgroup v1; k3s will crash-loop. First add this to %UserProfile%\.wslconfig on Windows:

    [wsl2]
    kernelCommandLine = cgroup_no_v1=all
    memory=10GB

then run `wsl --shutdown` in PowerShell, reopen WSL, and re-run this script.
EOF
  exit 1
fi

# systemd must be on (k3s runs as a service): /etc/wsl.conf should contain  [boot] systemd=true
if [ "$(ps -p 1 -o comm=)" != systemd ]; then
  echo "systemd is not running. Add to /etc/wsl.conf:  [boot]  systemd=true   then wsl --shutdown." >&2
  exit 1
fi

# Docker is only used to build images; k3s runs them via its own containerd.
sudo apt-get update
sudo apt-get install -y docker.io make python3 curl
sudo usermod -aG docker "$USER"

curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
echo "Done. Open a NEW shell (for the docker group), then run: make doctor"
