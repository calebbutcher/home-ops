#!/bin/sh
# Backup dead-man's-switch checker.
#
# For each backup we read its authoritative success timestamp from the Kubernetes API and, if it is
# fresh, ping the matching Uptime Kuma Push monitor (status=up). If it is stale / missing / failed we
# ping status=down so Kuma alerts immediately instead of waiting for heartbeat expiry. A check that
# cannot reach the API simply doesn't ping -> Kuma marks it down at expiry. We never abort early: one
# failing backup must not suppress the other heartbeats.
#
# Env: KUMA_URL, TOKEN_<NAME> (push tokens), MAX_AGE_DEFAULT (s), MAX_AGE_ETCD (s).

set -u

KUMA_URL="${KUMA_URL:?KUMA_URL required}"
MAX_AGE_DEFAULT="${MAX_AGE_DEFAULT:-93600}"   # 26h  (daily backups + grace)
MAX_AGE_ETCD="${MAX_AGE_ETCD:-50400}"         # 14h  (etcd snapshots run twice daily)

NOW="$(date -u +%s)"
export HOME=/tmp   # kubectl discovery cache needs a writable HOME

# push <token> <status> <msg> <ping>
push() {
  _tok="$1"; _status="$2"; _msg="$3"; _ping="$4"
  if [ -z "$_tok" ] || [ "$_tok" = "REPLACE_WITH_PUSH_TOKEN" ]; then
    echo "  ! token not configured — skipping ping"
    return
  fi
  _msg_enc="$(printf '%s' "$_msg" | sed 's/ /+/g')"
  if curl -fsS -m 10 -o /dev/null \
      "$KUMA_URL/api/push/$_tok?status=$_status&msg=$_msg_enc&ping=$_ping"; then
    echo "  -> pushed $_status ($_msg)"
  else
    echo "  ! push failed (curl error)"
  fi
}

# report <label> <token> <iso8601-ts-or-empty> <max-age-seconds>
report() {
  _label="$1"; _tok="$2"; _ts="$3"; _max="$4"
  if [ -z "$_ts" ]; then
    echo "$_label: DOWN (no successful backup found)"
    push "$_tok" down "no-successful-backup" 0
    return
  fi
  _epoch="$(printf '%s' "$_ts" | jq -Rr 'fromdateiso8601? // empty' 2>/dev/null)"
  if [ -z "$_epoch" ]; then
    echo "$_label: DOWN (unparseable timestamp '$_ts')"
    push "$_tok" down "bad-timestamp" 0
    return
  fi
  _age=$(( NOW - _epoch ))
  _age_h=$(( _age / 3600 ))
  if [ "$_age" -le "$_max" ]; then
    echo "$_label: UP (last backup ${_age_h}h ago)"
    push "$_tok" up "fresh ${_age_h}h" "$_age"
  else
    echo "$_label: DOWN (last backup ${_age_h}h ago, stale)"
    push "$_tok" down "stale ${_age_h}h" "$_age"
  fi
}

# --- 1-4: VolSync ReplicationSources (media) -----------------------------------------------
for app in sonarr radarr prowlarr seerr; do
  ts="$(kubectl get replicationsource "${app}-config" -n media \
        -o jsonpath='{.status.lastSyncTime}' 2>/dev/null)"
  tok_var="TOKEN_$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  tok=""
  eval "tok=\${$tok_var:-}"
  report "volsync/$app" "$tok" "$ts" "$MAX_AGE_DEFAULT"
done

# --- 5: CNPG (tracearr) — newest completed Backup object ------------------------------------
ts="$(kubectl get backup.postgresql.cnpg.io -n media -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.phase=="completed")]
               | sort_by(.status.stoppedAt) | last | .status.stoppedAt // empty')"
report "cnpg/tracearr" "${TOKEN_TRACEARR:-}" "$ts" "$MAX_AGE_DEFAULT"

# --- 6: MariaDB (uptime-kuma) — operator CronJob lastSuccessfulTime ------------------------
ts="$(kubectl get cronjob uptime-kuma-mariadb -n uptime-kuma \
      -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null)"
report "mariadb/uptime-kuma" "${TOKEN_UPTIME_KUMA:-}" "$ts" "$MAX_AGE_DEFAULT"

# --- 7: etcd offsite — newest s3-* ETCDSnapshotFile (cluster-scoped) ------------------------
ts="$(kubectl get etcdsnapshotfile -o json 2>/dev/null \
      | jq -r '[.items[] | select(.metadata.name | startswith("s3-"))]
               | sort_by(.status.creationTime) | last | .status.creationTime // empty')"
report "etcd/offsite" "${TOKEN_ETCD:-}" "$ts" "$MAX_AGE_ETCD"

echo "done."
