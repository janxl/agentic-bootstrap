#!/usr/bin/env bash
# How many chunks are indexed, and per document?   Usage: scripts/qdrant-count.sh [collection]
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

in_agent "${1:-${COLLECTION:-documents_nomic_v1}}" <<'EOF'
import json, sys, urllib.request
c = sys.argv[1]
def post(path, body):
    r = urllib.request.Request("http://qdrant:6333" + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=30).read())["result"]
print("total chunks:", post(f"/collections/{c}/points/count", {"exact": True})["count"])
for h in post(f"/collections/{c}/facet", {"key": "source", "limit": 100})["hits"]:
    print(f"  {h['count']:5d}  {h['value']}")
EOF
