#!/bin/sh
# rollout-guard soak check. Runs every 5 minutes (cronjob.yaml).
#
# Helm's wait only proves that pods became Ready once. It passes an app that crashes
# two minutes later (immich OOM, 2026-10), and with TCP-only readiness probes on most
# app-template apps, it passes anything that opens its port. This watches each
# HelmRelease for SOAK_WINDOW seconds after an upgrade and reports one that breaks.
#
# For every HelmRelease whose newest Helm release is a successful `upgrade` deployed
# between GRACE and SOAK_WINDOW seconds ago, check the release's pods
# (app.kubernetes.io/instance=<release>) for:
#   - waiting in CrashLoopBackOff / ImagePullBackOff / ErrImagePull / Create*Error
#   - >= RESTART_THRESHOLD container restarts since the upgrade, when the last exit
#     came after GRACE (restarts while the rollout settles are start-up races, e.g.
#     longhorn-manager exiting on a settings conflict before its peers are up)
#   - an OOMKilled exit since the upgrade
#   - NotReady since after the upgrade, for longer than NOTREADY_GRACE
#   - the app's blackbox probe failing for a full 5m (probe_success, job blackbox-app)
#
# A failure is POSTed to notification-controller as a Flux event:
#   "Soak check failed for release <ns>/<release> with chart <c>@<v> (revision N): ..."
# From there, the Flux Alerts do the rest: `discord` posts it to #flux-deploys, and
# `rollout-revert` sends it to GitHub, where the workflow reverts it if it was an
# automerged Renovate update. Each release revision is reported once, tracked in
# ConfigMap rollout-guard-state.
#
# Posting to notification-controller rather than GitHub means this needs no token,
# and the payload has the same shape as helm-controller's own failure events. Flux's
# `allow-egress` NetworkPolicy admits any pod in flux-system.
#
# Output: one logfmt RESULT line per HelmRelease checked.
set -eu

SOAK_WINDOW="${SOAK_WINDOW:-2700}"
GRACE="${GRACE:-120}"
NOTREADY_GRACE="${NOTREADY_GRACE:-300}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-1}"
PROM_URL="${PROM_URL:-http://prometheus-operated.monitoring.svc:9090}"
NC_URL="${NC_URL:-http://notification-controller.flux-system.svc.cluster.local./}"
DRY_RUN="${DRY_RUN:-false}"
STATE=rollout-guard-state
NOW=$(date +%s)

# The state ConfigMap is created here, not in git, so kustomize-controller never
# owns (or prunes) what it records. A dry run writes nothing at all.
if ! kubectl -n flux-system get configmap "$STATE" -o json > /tmp/state.json 2>/dev/null; then
  echo '{"data":{}}' > /tmp/state.json
  [ "$DRY_RUN" = true ] || kubectl -n flux-system create configmap "$STATE" >/dev/null
fi

# Candidates: releases upgraded (successfully) inside the soak window, not yet reported.
kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -c \
  --argjson now "$NOW" --argjson grace "$GRACE" --argjson window "$SOAK_WINDOW" \
  --slurpfile state /tmp/state.json '
  def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
  .items[]
  | select(.spec.suspend != true)
  | .status.history[0] as $h
  | select($h != null and $h.action == "upgrade" and $h.status == "deployed")
  | ($now - ($h.lastDeployed | ts)) as $age
  | select($age > $grace and $age < $window)
  | {ns: .metadata.namespace, name: .metadata.name, uid: .metadata.uid,
     rel: $h.name, relns: $h.namespace, ver: ($h.version | tostring),
     chart: "\($h.chartName)@\($h.chartVersion)", deployed: ($h.lastDeployed | ts), age: $age}
  | select(($state[0].data // {})["\(.ns).\(.name)"] != .ver)' > /tmp/candidates.jsonl

checked=0
failed=0
while read -r hr; do
  ns=$(echo "$hr" | jq -r .ns)
  name=$(echo "$hr" | jq -r .name)
  rel=$(echo "$hr" | jq -r .rel)
  relns=$(echo "$hr" | jq -r .relns)
  ver=$(echo "$hr" | jq -r .ver)
  deployed=$(echo "$hr" | jq -r .deployed)
  age=$(echo "$hr" | jq -r .age)
  checked=$((checked + 1))

  # Pod-level reasons, one per line.
  reasons=$(kubectl -n "$relns" get pods -l "app.kubernetes.io/instance=$rel" -o json | jq -r \
    --argjson now "$NOW" --argjson since "$deployed" \
    --argjson threshold "$RESTART_THRESHOLD" --argjson nrgrace "$NOTREADY_GRACE" \
    --argjson grace "$GRACE" '
    def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
    .items[]
    | select(.metadata.deletionTimestamp == null and .status.phase != "Succeeded")
    | select(all(.metadata.ownerReferences[]?; .kind != "Job"))
    | .metadata.name as $pod
    | (.metadata.creationTimestamp | ts) as $created
    | (
        ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
        | . as $c
        | (
            (.state.waiting.reason // empty
              | select(test("^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError)$"))
              | "\($pod)/\($c.name) is \(.)"),
            ((if (($c.lastState.terminated.finishedAt // null) == null
                  or ($c.lastState.terminated.finishedAt | ts) <= ($since + $grace)) then 0
              elif $created >= $since then $c.restartCount
              else 1 end) as $r
              | select($r >= $threshold)
              | "\($pod)/\($c.name) restarted \($r)x since the upgrade"),
            (select(($c.lastState.terminated.reason // "") == "OOMKilled"
                    and ($c.lastState.terminated.finishedAt | ts) > $since)
              | "\($pod)/\($c.name) was OOMKilled")
          )
      ),
      (
        .status.conditions[]? | select(.type == "Ready" and .status == "False")
        | (.lastTransitionTime | ts) as $t
        | select($t > $since and ($now - $t) > $nrgrace)
        | "\($pod) NotReady for \(($now - $t) / 60 | floor)m"
      )' | sort -u)

  # Blackbox probe: map the release's Services to probe targets (no hand-kept map).
  # Only after the probe has had a full post-upgrade 5m window.
  if [ "$age" -gt $((GRACE + 300)) ]; then
    svcs=$(kubectl -n "$relns" get svc -l "app.kubernetes.io/instance=$rel" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{end}' | sed 's/|$//')
    if [ -n "$svcs" ]; then
      query="max_over_time(probe_success{job=\"blackbox-app\",instance=~\"https?://($svcs)\\\\.${relns}[:/].*\"}[5m])"
      # A Prometheus outage must not fail the whole run (pod checks still count),
      # but it must not pass silently either.
      resp=$(curl -sS -G --max-time 20 --data-urlencode "query=$query" "$PROM_URL/api/v1/query" || echo '{}')
      if [ "$(echo "$resp" | jq -r '.status // "unreachable"' 2>/dev/null)" != success ]; then
        echo "WARN hr=$ns/$name probe check skipped: Prometheus query failed"
      fi
      down=$(echo "$resp" | jq -r '.data.result[]? | select(.value[1] == "0") | .metric.instance' 2>/dev/null || true)
      for i in $down; do
        reasons=$(printf '%s\n%s' "$reasons" "blackbox probe $i failing for 5m" | sed '/^$/d')
      done
    fi
  fi

  if [ -z "$reasons" ]; then
    echo "RESULT hr=$ns/$name revision=$ver age=${age}s status=ok"
    continue
  fi

  failed=$((failed + 1))
  summary=$(echo "$reasons" | head -5 | paste -sd ';' - | sed 's/;/; /g')
  msg="Soak check failed for release $relns/$rel with chart $(echo "$hr" | jq -r .chart) (revision $ver): $summary"
  echo "RESULT hr=$ns/$name revision=$ver age=${age}s status=fail reasons=\"$summary\""

  if [ "$DRY_RUN" = true ]; then
    echo "  dry-run: not posting event"
    continue
  fi
  jq -n --arg ns "$ns" --arg name "$name" --arg uid "$(echo "$hr" | jq -r .uid)" \
    --arg msg "$msg" --arg ver "$ver" --arg host "$(hostname)" '{
      involvedObject: {kind: "HelmRelease", apiVersion: "helm.toolkit.fluxcd.io/v2",
                       namespace: $ns, name: $name, uid: $uid},
      severity: "error", timestamp: (now | todate), reason: "SoakFailed", message: $msg,
      metadata: {revision: $ver},
      reportingController: "rollout-guard", reportingInstance: $host}' > /tmp/event.json
  # Retry a refused connect: k3s's kube-router adds a new pod's IP to the
  # NetworkPolicy ipsets asynchronously, and until it does, allow-egress's
  # same-namespace ingress rule REJECTs this pod. This job is seconds old here.
  curl -sS -f --max-time 20 --retry 5 --retry-delay 2 --retry-connrefused \
    -X POST -H 'Content-Type: application/json' \
    --data @/tmp/event.json "$NC_URL"
  # Mark reported only after a successful POST, so a failed POST is retried next run.
  kubectl -n flux-system patch configmap "$STATE" --type merge \
    -p "$(jq -n --arg k "$ns.$name" --arg v "$ver" '{data: {($k): $v}}')" >/dev/null
done < /tmp/candidates.jsonl

echo "SUMMARY checked=$checked failed=$failed window=${SOAK_WINDOW}s dry_run=$DRY_RUN"
