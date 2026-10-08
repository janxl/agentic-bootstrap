#!/usr/bin/env bash
# kubectl in the app namespace, using the same kubectl/kubeconfig discovery as every other script.
# The Makefile calls this so it never has to know where kubectl lives.   Usage: scripts/k.sh get pods
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
exec $KUBECTL -n "$NS" "$@"
