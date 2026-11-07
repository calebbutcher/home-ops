#!/usr/bin/env bash
# Exports a workflow from the in-cluster n8n into git: keeps only the workflow itself (the full
# export carries the owner's name and email) and keeps the committed "Reader profile" node, whose
# live contents are private.
#
# usage: n8n/export.sh <workflow-id> n8n/workflows/<name>.json
set -euo pipefail

id=$1
out=$2
pod=$(kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o name | head -1)

kubectl -n n8n exec "$pod" -c app -- sh -c \
  "n8n export:workflow --id=$id --output=/tmp/wf.json >/dev/null 2>&1 && cat /tmp/wf.json && rm /tmp/wf.json" |
  python3 -c '
import json, os, sys
[w] = json.load(sys.stdin)
w = {k: w[k] for k in ("id", "name", "nodes", "connections", "settings")}
out = sys.argv[1]
committed = json.load(open(out)) if os.path.exists(out) else {"nodes": []}
private = {n["name"]: n for n in committed["nodes"] if n["name"] == "Reader profile"}
for n in w["nodes"]:
    if n["name"] == "Reader profile":
        if n["name"] not in private:
            sys.exit("Reader profile node has no committed placeholder; add one by hand first")
        n["parameters"] = private[n["name"]]["parameters"]
with open(out, "w") as f:
    json.dump(w, f, indent=2, ensure_ascii=False)
    f.write("\n")
' "$out"
