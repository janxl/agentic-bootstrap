#!/usr/bin/env bash
# Build the four images and get them to the cluster (see scripts/load-images.sh for how).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
set -euo pipefail

SERVICES="agent gateway mcp-tools ingest"

if [ -n "${REGISTRY:-}" ]; then
  tag="${TAG:-$(date +%Y%m%d%H%M%S)}"   # unique per build; see image_tag in lib.sh
  echo "$tag" > "$ROOT/.build-tag"
else
  tag=dev
fi
prefix="$(image_prefix)"

images=()
for s in $SERVICES; do
  docker build -t "$prefix/$s:$tag" "$ROOT/$s"
  images+=("$prefix/$s:$tag")
done

bash "$ROOT/scripts/load-images.sh" "${images[@]}"
echo "built and loaded: ${images[*]}"
