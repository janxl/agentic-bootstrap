#!/usr/bin/env bash
# Apply manifests, pointing the images at wherever `make up` built them.
# The manifests say `image: agentic/<service>:dev`; this rewrites that to the registry/tag in use
# (a no-op for local clusters). Usage: scripts/apply.sh k8s/agent.yaml k8s/gateway.yaml
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

prefix="$(image_prefix)"
tag="$(image_tag)"
for f in "$@"; do
  sed -E "s#image: agentic/([a-z-]+):dev#image: ${prefix}/\1:${tag}#" "$f" | $KUBECTL apply -f -
done
