# CrowdSec: WAF / IP-reputation in front of Traefik

This runbook covers the **net-new** [CrowdSec](https://www.crowdsec.net/) deployment under
`kubernetes/infrastructure/controllers/crowdsec/`. CrowdSec watches Traefik's access logs,
detects scanners / brute-force / HTTP attacks, and (via a Traefik plugin **bouncer**) blocks
offending IPs — plus the crowd-sourced community blocklist (CAPI) — before requests reach an
app. It complements Authentik SSO (which only gates a subset of routes) and is the first
security layer on the internet-exposed `*.nerdbox.dev` hosts.

Rollout is **observe-first**: this PR deploys the engine and registers the plugin but does
**not** attach the bouncer to any Ingress. Enforcement is a deliberate second step (below).

## Architecture

```
Internet ──(port-forward :443)──▶ MetalLB VIP ──▶ Traefik (2 replicas)
                                                     │  bouncer plugin middleware (enforcement step)
                                                     ▼        checks source IP vs LAPI decisions → 403 if banned
                                                Ingress ──▶ App
   CrowdSec Agent (DaemonSet) ◀─ reads /var/log/containers/traefik-*_traefik_*.log
        │  parses w/ crowdsecurity/traefik, runs HTTP scenarios
        ▼
   CrowdSec LAPI (Deployment) ── stores decisions, pulls community blocklist (CAPI)
```

Because traffic is a **direct port-forward to MetalLB** (no upstream proxy), Traefik sees the
real client source IP, so no `forwardedHeaders.trustedIPs` gymnastics are needed. RFC1918/LAN
ranges are whitelisted on **both** sides: the agent won't raise decisions for them
(`config.parsers.s02-enrich/lan-whitelist.yaml`), and the bouncer won't block them
(`clientTrustedIPs` in the Middleware).

## What's in `kubernetes/infrastructure/controllers/crowdsec/`

| File | Role |
|------|------|
| `namespace.yaml` | `crowdsec` namespace. |
| `helmrepository.yaml` | `crowdsec` HelmRepository (`https://crowdsecurity.github.io/helm-charts`). |
| `helmrelease.yaml` | CrowdSec chart `0.24.0` — LAPI (Deployment) + agent (DaemonSet), `container_runtime: containerd`, Traefik acquisition, LAN whitelist, ServiceMonitors. |
| `secret.sops.yaml` | `crowdsec-bouncer-key` (crowdsec ns) → `BOUNCER_KEY_traefik` env; LAPI auto-registers the `traefik` bouncer with this key. |
| `middleware.yaml` | `crowdsec-bouncer` Traefik Middleware (defined, not yet attached). |

Plus, wired into the Traefik controller:

| File | Change |
|------|--------|
| `controllers/traefik/helmrelease.yaml` | JSON access logs; `experimental.plugins.bouncer` (`v1.7.0`); mounts the key at `/var/run/secrets/crowdsec`. |
| `controllers/traefik/crowdsec-bouncer-key.sops.yaml` | `crowdsec-bouncer-key` (traefik ns) → file `bouncer-key`, same value as the crowdsec-ns secret. |

> **Bouncer key**: one random value lives in two SOPS secrets (crowdsec-ns as
> `BOUNCER_KEY_traefik` env; traefik-ns as the `bouncer-key` file). This is CrowdSec's
> documented cross-namespace pattern. To rotate, regenerate the value in **both** files and
> re-encrypt with `sops --encrypt --in-place`.

## Verify (observe mode)

```sh
# LAPI: bouncer registered + validated, decisions/alerts flowing
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli bouncers list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list

# Agent: Traefik acquisition parsing lines, collections installed
kubectl -n crowdsec exec ds/crowdsec-agent -- cscli metrics
kubectl -n crowdsec exec ds/crowdsec-agent -- cscli collections list   # crowdsecurity/traefik enabled

# Traefik plugin loaded + connected to LAPI (should log no auth errors)
kubectl -n traefik logs deploy/traefik | grep -i crowdsec
```

Let observe mode run long enough to confirm normal usage (Immich upload, `*arr` API polling,
Authentik logins) does **not** raise decisions against legitimate clients.

## Enforce

The bouncer is attached to every Ingress carrying a bare `*.nerdbox.dev` host by adding it to the
`router.middlewares` annotation (bouncer **first** — cheap IP check before any auth). Only
`immich` and `seerr` actually have external Cloudflare DNS; the rest (`uptime`, `radarr`/`sonarr`
+ their `-api`, `tracearr`) have no DNS but their bare routers still answer on the public IP with a
spoofed `Host` header, so they are covered as **defense-in-depth**. Internal `*.int` routes on the
same Ingresses are unaffected — LAN is whitelisted.

Routes with **no** existing middleware — set the annotation:

```yaml
# uptime-kuma, seerr, immich, radarr-api, sonarr-api
traefik.ingress.kubernetes.io/router.middlewares: crowdsec-crowdsec-bouncer@kubernetescrd
```

Routes **already** using Authentik forward-auth — chain (bouncer first):

```yaml
# radarr (UI), sonarr (UI), tracearr
traefik.ingress.kubernetes.io/router.middlewares: crowdsec-crowdsec-bouncer@kubernetescrd,authentik-authentik-forwardauth@kubernetescrd
```

Files: `kubernetes/apps/{immich/ingress.yaml, uptime-kuma/ingress.yaml,
media/seerr/ingress.yaml, media/radarr/ingress.yaml, media/sonarr/ingress.yaml,
media/tracearr/ingress.yaml}` — note `radarr`/`sonarr` each have **two** Ingresses (UI + open
`-api`); annotate both. `immich` intentionally keeps no forward-auth (mobile app), so it gets
the bouncer only.

### Test enforcement

```sh
# Ban a throwaway IP, then hit an enforced host FROM THAT EXTERNAL IP (phone on cellular / a VPS)
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions add --ip <external-ip> --duration 5m --type ban
#   from that IP:  curl -s -o /dev/null -w '%{http_code}\n' https://immich.nerdbox.dev   # expect 403
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <external-ip>
```

> You **cannot** test a block from a LAN machine (even with a spoofed `X-Forwarded-For`): LAN
> sources are in the bouncer's `clientTrustedIPs`, so they bypass the check entirely.

## Rollback

Remove the bouncer entry from an Ingress annotation (one line) to stop enforcing on that host
— Traefik keeps serving. To disable entirely, drop `experimental.plugins.bouncer` +
the `volumes` mount from the Traefik HelmRelease and remove `controllers/crowdsec` from
`kubernetes/infrastructure/kustomization.yaml`. `abortOnPluginFailure` is left at the chart
default (`false`), so even a failed plugin download never takes Traefik down.

## Request-level WAF (AppSec) — staged enforcement

CrowdSec's AppSec component (port 7422) does in-band request inspection. Deployed via
`appsec.enabled: true` + the custom `home-ops/appsec-detect` config in the HelmRelease, behind the
`crowdsec-appsec` Middleware (`crowdsec-appsec-service:7422`), attached to **seerr only** for now
(immich excluded — large uploads get body-inspected). It runs in **two tiers**:

- **In-band (enforcing): `default_remediation: ban`** over `base-config` + `vpatch-*` (CVE virtual
  patches) + `generic-*` (scanner patterns). A match **403s the live request**. These are narrow,
  high-confidence signatures → low false-positive risk. The `appsec-vpatch`/`appsec-native` ban
  scenarios fire on in-band (`appsec-block`) events only.
- **Out-of-band (detect-only): OWASP CRS** (`crowdsecurity/crs`), for generic SQLi/XSS/etc. that the
  vpatch/generic sets don't cover. Out-of-band rules run **after** the response, so they **never
  block the live request**. CRS is installed as an `APPSEC_RULES` **rule**, *not* the
  `crowdsecurity/appsec-crs` collection — so its banning scenario `crowdsec-appsec-outofband` is
  **absent** and CRS can only **alert** (`on_match: SendAlert()`), never ban, while we tune.

> **Prerequisite that made this real:** the AppSec engine only sees genuine attacker IPs because
> Traefik now preserves the client source IP (`externalTrafficPolicy: Local`). Before that, external
> traffic was SNAT'd to a whitelisted node IP and AppSec inspected nothing. Read appsec metrics on
> the **appsec pod** (`:6060`), not via `cscli` on the LAPI (which has no appsec metrics locally).

**CRS tuning → promotion rollout:**

1. **Observe** (current): watch `cs_appsec_rule_hits{type="outofband"}` (AppSec Grafana dashboard) and
   `cscli alerts list` (kind `waf`) for CRS matches on legit seerr traffic — those are false positives.
2. **Tune**: add an app exclusion rule (`crowdsecurity/crs-exclusion-plugin-*`) to `outofband_rules`,
   or drop a noisy rule id with a custom appsec-rule (`SecRuleRemoveById <id>` /
   `SecRuleUpdateTargetById <id> "!ARGS:<param>"`). Raise `tx.inbound_anomaly_score_threshold` only if
   broadly noisy.
3. **Promote CRS to enforcing** once quiet: move `crowdsecurity/crs` from `outofband_rules` to
   `inband_rules`. (Do **not** switch to the `crowdsecurity/appsec-crs` collection — that reintroduces
   the auto-ban scenario; keep it as the rule.)
4. **Widen** beyond seerr: attach the `crowdsec-appsec` middleware to other external hosts (raise
   `crowdsecAppsecBodyLimit` before adding immich).

## Observability (Grafana dashboards + metrics)

Prometheus scrapes the CrowdSec ServiceMonitors (lapi + agent + appsec, port `metrics`/6060) —
`serviceMonitorSelectorNilUsesHelmValues: false` means no label wiring is needed. The appsec
ServiceMonitor is enabled via `appsec.metrics.serviceMonitor.enabled: true` in the HelmRelease.

Five dashboards are provisioned as ConfigMaps in `kubernetes/apps/monitoring/crowdsec/` (label
`grafana_dashboard: "1"`, datasource pinned to uid `prometheus`, auto-imported by the Grafana
sidecar). The first four are the official `crowdsecurity/grafana-dashboards` v5 set (vendored:
`__inputs`/`__requires` stripped, `${DS_PROMETHEUS}` → hardcoded `prometheus`); the last is
hand-authored:

| Dashboard | File | Notes |
|-----------|------|-------|
| Overview | `dashboard.yaml` | Global decisions / alerts / buckets / parsers. |
| Insight | `dashboard-insight.yaml` | Per-node health + Top scenarios. |
| Details per instance | `dashboard-details.yaml` | Deep per-node parser/bucket internals + heatmaps. |
| LAPI Metrics | `dashboard-lapi.yaml` | LAPI request-duration heatmaps (pick the lapi instance). |
| AppSec | `dashboard-appsec.yaml` | `cs_appsec_*` WAF metrics — **empty until the WAF processes traffic**. |

> **Instance dropdowns** on Insight/Details/LAPI list every CrowdSec pod as `IP:port` (the
> Prometheus `instance` label). Only the two agents co-located with a Traefik replica emit parse
> metrics (`cs_parser_hits_*`, `cs_parsing_time_*`) — the rest just carry `cs_info`.
>
> **AppSec panels stay empty** until the AppSec component actually inspects requests. It is
> detect-only on seerr today, so `cs_appsec_reqs_total` / `cs_appsec_block_total` /
> `cs_appsec_rule_hits` register only once real WAF traffic flows (see the smoke test below).

To confirm AppSec metrics after some traffic:

```sh
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli metrics show appsec   # non-empty once traffic hits
# smoke-test from an external vantage (detect-only → logs/counts, won't block):
#   curl -s -o /dev/null 'https://seerr.nerdbox.dev/?id=1%20OR%201=1'
```

## Notes

- **Community blocklist (CAPI)**: the LAPI auto-enrolls with the central API on first start
  (online) to pull the community blocklist — no key required. Optional: enroll into the
  [CrowdSec console](https://app.crowdsec.net/) for dashboards via `cscli console enroll <key>`.
- **Persistence**: LAPI uses two small `local-path` PVCs (decision DB + machine creds). On a
  fresh volume the `traefik` bouncer re-registers automatically from `BOUNCER_KEY_traefik`.
