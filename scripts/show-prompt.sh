#!/usr/bin/env bash
# Show what the model is actually given: the system prompt (from corpus.toml, as deployed) and the
# search_documents tool description (topics from corpus.toml plus the titles of the indexed documents).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

echo "=== system prompt (corpus.toml [prompt], as mounted in the agent pod)"
in_agent <<'EOF'
import os, tomllib
try:
    with open(os.environ.get("CORPUS_CONFIG", "/config/corpus.toml"), "rb") as f:
        print(tomllib.load(f).get("prompt", {}).get("system", "").strip() or "(none: the agent uses a generic prompt)")
except FileNotFoundError:
    print("(no corpus.toml in the cluster: run `make config`; the agent uses a generic prompt)")
EOF
echo
echo "=== search_documents description (as the agent sees it)"
in_agent <<'EOF'
from mcp_client import list_tools
for t in list_tools():
    if t["name"] == "search_documents":
        print(t["description"])
EOF
