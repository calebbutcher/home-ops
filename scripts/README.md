# scripts

Repo-local operational helper scripts. These are not part of the GitOps reconcile — they are
convenience wrappers you run from your workstation. Cluster-facing scripts talk to the cluster via
`kubectl`, so they need a working kube-context.

Keep scripts self-contained, `chmod +x`, with a comment header describing usage.

| Script | What it does |
|--------|--------------|
| `appsec-stats.sh` | CrowdSec AppSec at a glance — Processed/Blocked + per-rule (appsec pod), recent `waf` detections and active bans (LAPI). Handles the gotcha that metrics live on the appsec pod while alerts/decisions live on the LAPI. `scripts/appsec-stats.sh [alert_limit]`. |
