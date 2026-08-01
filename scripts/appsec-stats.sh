#!/usr/bin/env bash
#
# appsec-stats — CrowdSec AppSec at a glance.
#
# Handles the gotcha that AppSec METRICS live on the appsec pod, while ALERTS and
# DECISIONS live on the LAPI — so you don't have to remember which cscli command
# goes to which pod.
#
# Usage:
#   scripts/appsec-stats.sh [alert_limit]      # default: 20 recent alerts
#   NS=crowdsec scripts/appsec-stats.sh 50
#
# Requires: kubectl with a context that can reach the cluster.
#
set -uo pipefail

ns="${NS:-crowdsec}"
limit="${1:-20}"
appsec="deploy/crowdsec-appsec"
lapi="deploy/crowdsec-lapi"

hr() { printf '\n\033[1m===== %s =====\033[0m\n' "$1"; }

hr "Processed / Blocked + per-rule triggers   (appsec pod)"
kubectl -n "$ns" exec "$appsec" -- cscli metrics show appsec \
  || echo "  !! could not reach $appsec in namespace '$ns'"

hr "Recent detections   (LAPI - kind \"waf\" = appsec)"
kubectl -n "$ns" exec "$lapi" -- cscli alerts list --limit "$limit" \
  || echo "  !! could not reach $lapi in namespace '$ns'"

hr "Active local bans   (LAPI - appsec / scenario / manual)"
kubectl -n "$ns" exec "$lapi" -- cscli decisions list \
  || echo "  !! could not reach $lapi in namespace '$ns'"

cat <<EOF

Tips:
  - Include the CAPI community blocklist:  kubectl -n $ns exec $lapi -- cscli decisions list -a
  - Drill into one detection:             kubectl -n $ns exec $lapi -- cscli alerts inspect <ID> -d
EOF
