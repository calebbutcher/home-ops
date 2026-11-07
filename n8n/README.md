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

## threat-intel.json

Daily 07:00 Eastern briefing to the `#threat-intel` Discord channel. It reads the security news,
mailing-list, and research feeds in the `Sources` node, plus CISA KEV, NVD, and GitHub
advisories. Claude (Sonnet) then picks and writes up what matters, in four sections: your lab
(matched against running images), identity & access, offensive research, and big picture. Weekends
only post exploited issues that touch the lab. Stories already covered are remembered for 45 days
and only come back when something material changes. `threat-intel-errors.json` posts failed runs
to the same channel.

Credentials: a **Discord Webhook** named `Discord Threat Intel` (the `#threat-intel` webhook
URL), and the **Anthropic** credential above.

The `Reader profile` node (who the briefing is for, plus private keywords and feeds) is kept out
of git. Importing from git resets it to the placeholder; fill it in again in the UI. Critical items
also get a deep dive (Claude with web search, up to 3 a day) posted as a follow-up message; set
`ENABLED = false` in `Deep dive items` to turn it off.

## Import / export

```sh
P=$(kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o name | head -1)

# import (lands unpublished; attach credentials and publish in the UI)
kubectl -n n8n exec -i "$P" -c app -- sh -c 'cat > /tmp/wf.json && n8n import:workflow --input=/tmp/wf.json' < n8n/workflows/weekly-digest.json

# export after editing in the UI
n8n/export.sh <id> n8n/workflows/weekly-digest.json
```
