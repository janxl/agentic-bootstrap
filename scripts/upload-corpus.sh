#!/usr/bin/env bash
# Mirror ./corpus into the cluster's `corpus` volume (files removed locally are removed there too,
# so the ingest job's reconcile can drop their chunks). Part of `make ingest`.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
set -euo pipefail

SRC="$ROOT/corpus"
[ -d "$SRC" ] || { echo "no $SRC folder: add documents to corpus/, or list some with a url in corpus.toml" >&2; exit 1; }

bash "$ROOT/scripts/apply.sh" "$ROOT/k8s/corpus.yaml"

# A throwaway pod that mounts the volume so files can be copied in. The ingest job cannot be used
# for this: it mounts the volume read-only and exits when done.
k delete pod corpus-upload --ignore-not-found --wait=true >/dev/null
k run corpus-upload --image=busybox:1.36 --restart=Never --overrides='{
  "spec": {
    "containers": [{
      "name": "corpus-upload", "image": "busybox:1.36", "command": ["sleep", "900"],
      "volumeMounts": [{"name": "corpus", "mountPath": "/corpus"}]
    }],
    "volumes": [{"name": "corpus", "persistentVolumeClaim": {"claimName": "corpus"}}]
  }
}' >/dev/null
trap 'k delete pod corpus-upload --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
k wait --for=condition=ready pod/corpus-upload --timeout=180s >/dev/null

k exec corpus-upload -- sh -c 'rm -rf /corpus/* /corpus/.[!.]* 2>/dev/null; true'
tar -C "$SRC" --exclude=SOURCES.md --exclude='*.part' -cf - . | k exec -i corpus-upload -- tar -C /corpus -xf -
echo "uploaded to the corpus volume:"
k exec corpus-upload -- ls -l /corpus
