#!/usr/bin/env bash
# What is running, and why anything is not: workloads, volumes, recent warnings, log tails.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

k get deploy,pods,jobs,svc,ingress,pvc -o wide
echo; echo "--- recent warnings"
k get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -8
for d in agent gateway mcp-tools; do
  echo; echo "--- $d (last 5 log lines)"
  k logs "deploy/$d" --tail=5 2>&1
done
