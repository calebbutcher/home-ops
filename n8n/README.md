# n8n workflows

Exported workflows for the in-cluster n8n (`kubernetes/apps/n8n`). n8n keeps the live
copy in its Postgres; these files are the reviewable/restorable copy. Credentials are
never exported; nodes only reference them by name.

## weekly-digest.json

Sunday 14:00 UTC digest to the `#weekly-digest` Discord channel: backup/compactor
health, open PRs, disk and cert headroom, restarts, and week-over-week speedtest,
Longhorn and CrowdSec numbers, with a short Claude-written summary on top.

Credentials to create in n8n (Credentials → Add):

- **Discord Webhook**: the `#weekly-digest` channel webhook URL.
- **Anthropic**: an API key (used with Sonnet). If this call fails the digest still
  posts, just without the summary.

Queries live in the `Queries` node (one per line); formatting is in `Build digest`.

## Import / export

```sh
P=$(kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o name | head -1)

# import (lands inactive; attach credentials and activate in the UI)
kubectl -n n8n exec -i "$P" -c app -- sh -c 'cat > /tmp/wf.json && n8n import:workflow --input=/tmp/wf.json' < n8n/workflows/weekly-digest.json

# export after editing in the UI (keeps only the workflow itself; the full export
# carries the owner's name and email)
kubectl -n n8n exec "$P" -c app -- sh -c 'n8n export:workflow --id=<id> --output=/tmp/wf.json >/dev/null 2>&1 && node -e "const [w]=require(\"/tmp/wf.json\");const {id,name,nodes,connections,settings}=w;console.log(JSON.stringify({id,name,nodes,connections,settings},null,2))"' > n8n/workflows/weekly-digest.json
```
