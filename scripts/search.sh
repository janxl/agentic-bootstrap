#!/usr/bin/env bash
# Ad-hoc search_documents call through the MCP server, one summary line per hit.
# Usage: scripts/search.sh "your question" [top_k] [--full]
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

in_agent "${1:?query required}" "${2:-6}" "${3:-}" <<'EOF'
import sys
from mcp_client import call_tool
query, top_k, full = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "--full"
out = call_tool("search_documents", {"query": query, "top_k": top_k})
if full:
    print(out)
else:
    for block in out.split("\n\n["):
        head, _, body = block.partition("\n")
        print(head if head.startswith("[") else "[" + head)
        print("      " + " ".join(body.split())[:200])
EOF
