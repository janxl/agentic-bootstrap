#!/usr/bin/env bash
# Publish corpus.toml to the cluster as the `corpus-config` ConfigMap, which the agent (system
# prompt), the tool server (what the library is about) and the ingest job (document titles) read.
# Usage: scripts/apply-config.sh            (make up / deploy / ingest call this for you)
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
set -euo pipefail

[ -f "$ROOT/corpus.toml" ] || { echo "no corpus.toml at the repo root" >&2; exit 1; }
# Fail here, on your machine, if the file is not valid TOML, instead of in a crash-looping pod.
python3 - "$ROOT/corpus.toml" <<'EOF'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except tomllib.TOMLDecodeError as e:
    sys.exit(f"corpus.toml is not valid TOML: {e}")
if not cfg.get("prompt", {}).get("system", "").strip():
    print("note: corpus.toml has no [prompt] system: the agent will use a generic prompt", file=sys.stderr)
EOF
$KUBECTL -n "$NS" create configmap corpus-config --from-file=corpus.toml="$ROOT/corpus.toml" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
