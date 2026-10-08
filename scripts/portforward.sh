#!/usr/bin/env bash
# Expose the gateway on http://localhost:8080 (or the port given as $1). Leave it running; Ctrl+C stops.
# Works on any cluster, with no ingress needed. It reconnects, so it survives a redeploy.
# (On WSL2 this is also what makes the page reachable from the Windows browser: k3s's ingress
# is not visible to WSL's localhost forwarding, but a port-forward is.)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

PORT="${1:-8080}"
echo "Gateway -> http://localhost:${PORT}"
while true; do
  k port-forward svc/gateway "${PORT}:80"
  echo "port-forward exited, retrying in 2s..."
  sleep 2
done
