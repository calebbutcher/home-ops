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
        │                      ◀─ reads /var/log/containers/home-assistant-*_home-assistant_*.log
        │  parses w/ crowdsecurity/traefik + crowdsecurity/home-assistant, runs scenarios
        ▼
   CrowdSec LAPI (Deployment) ── stores decisions, pulls community blocklist (CAPI)
```

**Application log sources.** Detection only fires on logs we acquire. Two acquisitions are
configured (`agent.acquisition[]` in the HelmRelease), both keyed by a `program:` label that
selects the parser:

| `program` | Source | Collection | Detects |
|-----------|--------|------------|---------|
| `traefik` | Traefik JSON access logs | `crowdsecurity/traefik` + `base-http-scenarios` + `http-dos` | HTTP probing, crawling, CVE paths, L7 DoS (simulation) |
| `home-assistant` | HA container stdout | `crowdsecurity/home-assistant` | Failed HA logins / invalid-auth requests (`home-assistant-bf`) |

HA is a genuine log source (unlike Authentik, which logs auth events to its DB — see Notes):
`homeassistant.components.http.ban` writes one WARNING per invalid-auth request, and HA's
`http.use_x_forwarded_for` + `trusted_proxies` config means the line carries the **real client
IP**, not the Traefik pod IP. Removing that config from `configuration.yaml` silently turns this
acquisition into a no-op (every failure would attribute to a whitelisted `10.42.x` pod IP).

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
| `helmrelease.yaml` | CrowdSec chart `0.24.0` — LAPI (Deployment) + agent (DaemonSet), `container_runtime: containerd`, Traefik + Home Assistant acquisitions, LAN whitelist, ServiceMonitors. |
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

# Agent: acquisitions parsing lines, collections installed
kubectl -n crowdsec exec ds/crowdsec-agent -- cscli metrics
kubectl -n crowdsec exec ds/crowdsec-agent -- cscli collections list   # traefik + home-assistant enabled

# Traefik plugin loaded + connected to LAPI (should log no auth errors)
kubectl -n traefik logs deploy/traefik | grep -i crowdsec
```

Let observe mode run long enough to confirm normal usage (Immich upload, `*arr` API polling,
Authentik logins) does **not** raise decisions against legitimate clients.

### Verify a log-based acquisition end to end

`cscli explain` replays a real captured line through the whole pipeline and prints which parser
matched and what it extracted. This is the only reliable way to confirm an app acquisition
works — a stuck or non-matching acquisition looks completely healthy from the outside (all
targets UP, agents `Running`, heartbeats ✔️). Home Assistant as the worked example:

```sh
# 1. Generate one invalid-auth request. An unauthenticated GET is enough — HA raises
#    HTTPUnauthorized and its ban middleware logs the WARNING, no bogus token needed.
#    It does NOT self-ban: login_attempts_threshold defaults to -1, so this is safe
#    to repeat.
curl -s -o /dev/null -w '%{http_code}\n' https://ha.int.nerdbox.dev/api/   # expect 401

# 2. Replay the resulting line through the pipeline, on the agent co-located with the HA pod.
#    HA runs with hostNetwork on one node, so pick that node's agent:
#      kubectl -n home-assistant get pod -o wide   → NODE
#      kubectl -n crowdsec get pod -o wide         → the crowdsec-agent on that NODE
AGENT=crowdsec-agent-xxxxx
kubectl -n crowdsec exec "$AGENT" -- sh -c '
  grep "http.ban" /var/log/containers/home-assistant-*_home-assistant_*.log | tail -1 |
  cscli explain --type containerd --labels program:home-assistant -f - -v'
```

Expect `🟢 crowdsecurity/home-assistant-logs` in `s01-parse`, creating
`evt.Meta.log_type: home-assistant_failed_auth` and an `evt.Parsed.source_ip` that is the **real
client IP**. A LAN client then ends in `parser success, ignored by whitelist (private ranges
(RFC1918))` — that is the correct outcome, not a failure; only non-RFC1918 sources can reach the
`home-assistant-bf` scenario.

> HA colourises stdout (`^[[33m…^[[0m` wraps every line). The hub grok is unanchored so it
> matches straight through the escapes — confirmed, no `--log-no-color` needed.

## Enforce

The bouncer is attached via the `router.middlewares` annotation (bouncer **first** — cheap IP
check before any auth). Internal `*.int` routes are unaffected either way: LAN is whitelisted.

**What actually determines exposure.** Three of these routes have public Cloudflare DNS —
`immich`, `seerr`, and `ha` (added 2026-08-14 for away-from-home access). But **DNS is not the
boundary**, and the `.int` label is a naming convention, not a routing boundary:

- Traefik matches on the `Host` header, so *any* router — `.int` or bare — answers a request
  sent to the WAN IP with that Host. No DNS record is required to reach it.
- Every hostname here is published in **Certificate Transparency logs** the moment Let's Encrypt
  issues its cert. `crt.sh -q '%.int.nerdbox.dev'` returns ~38 internal names including
  `ha.int`, `longhorn.int`, `grafana.int`. There is no obscurity to rely on.

So treat the bouncer as blanket defense-in-depth on every route, and do not read "internal-only
DNS" as protection for any of them.

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

### `home-assistant` — the full stack

HA is deliberately internet-exposed (`ha.nerdbox.dev`) and fronts locks, cameras and presence,
so it carries every layer — the same chain as `seerr`, one step beyond `immich`:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd,traefik-rate-limit@kubernetescrd,crowdsec-crowdsec-bouncer@kubernetescrd,crowdsec-crowdsec-appsec@kubernetescrd
```

- **No Authentik forward-auth** — it challenges/redirects, which breaks the companion app and
  the REST/webhook API (same reason `immich` has none). HA's own login **plus MFA on every
  account** is therefore the authentication boundary. Not optional on a public route.
- **`traefik-rate-limit` is safe here** despite the long-lived websocket: Traefik's rateLimit
  counts the websocket *upgrade* request, not traffic on the established socket, so a persistent
  companion-app connection costs 1 against the 50/s average.
- **AppSec is the one that can bite.** It fails open if the component is down or errors, but a
  false-positive in-band rule match returns a real 403 — which on this route reads as "my house
  is broken", not "the WAF fired". First triage step is to drop
  `crowdsec-crowdsec-appsec@kubernetescrd` from the annotation, then check
  `cscli alerts list` (kind `waf`) and `cs_appsec_block_total`.
- HA is also a **detection** source (see the acquisitions table above), so this route is
  self-defending: repeated failed logins from a public IP raise `home-assistant-bf` → a ban →
  the bouncer on this same Ingress enforces it. That loop only closes for non-RFC1918 sources,
  which is precisely the traffic that arrives on `ha.nerdbox.dev`.

The public `ha.nerdbox.dev` A record is a **manual Cloudflare record** (DNS-only / grey cloud,
straight to the WAN IP), like `immich`/`seerr`. external-dns cannot manage it — it is hard-filtered
to `domainFilters: [int.nerdbox.dev]` so that nothing in-cluster can write a public record.

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
`crowdsec-appsec` Middleware (`crowdsec-appsec-service:7422`), attached to **seerr** and
**home-assistant** (immich excluded — large uploads get body-inspected). It runs in **two tiers**:

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

### AppSec stats from the CLI

`scripts/appsec-stats.sh` is a one-shot helper — it runs the right `cscli` command against the right
pod (see the gotcha below) and prints Processed/Blocked + per-rule triggers, recent `waf` detections,
and active bans in one go:

```sh
scripts/appsec-stats.sh          # default: 20 recent alerts
scripts/appsec-stats.sh 50       # more alerts;  NS=crowdsec to override the namespace
```

> **Gotcha:** AppSec **metrics** live on the **appsec pod**, but **alerts** and **decisions** live on
> the **LAPI**. `cscli metrics show appsec` run against the LAPI returns an **empty table** — it must
> target the appsec pod. The underlying commands:

```sh
# metrics (Processed / Blocked + per-rule) — APPSEC POD, not the LAPI:
kubectl -n crowdsec exec deploy/crowdsec-appsec -- cscli metrics show appsec
# detections + bans — LAPI:
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list --limit 20    # kind "waf" = appsec
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts inspect <ID> -d    # matched rules + request
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list            # active bans (add -a for CAPI)
# smoke-test a detection from an external vantage (a generic SQLi is CRS out-of-band = alert-only):
#   curl -s -o /dev/null 'https://seerr.nerdbox.dev/?id=1%20OR%201=1'
```

## Notes

- **Community blocklist (CAPI)**: the LAPI auto-enrolls with the central API on first start
  (online) to pull the community blocklist — no key required. Optional: enroll into the
  [CrowdSec console](https://app.crowdsec.net/) for dashboards via `cscli console enroll <key>`.
- **Persistence**: LAPI uses two small `local-path` PVCs (decision DB + machine creds). On a
  fresh volume the `traefik` bouncer re-registers automatically from `BOUNCER_KEY_traefik`.
- **Never install collections with `cscli` on an agent.** The agent's config directory is an
  `EmptyDir`, so anything installed by hand is wiped by the next pod restart, rollout or node
  reboot — and the loss is silent (the scenario just stops existing; no alert covers it).
  `agent.env.COLLECTIONS` in the HelmRelease is the durable install: the image entrypoint runs
  the install on every start. `cscli collections install` is still the right tool for a
  throwaway test, e.g. to run `cscli explain` against a hub parser before committing to it.
- **Adding a new app log source** is three things, all in git: an `agent.acquisition[]` entry
  (`namespace` + `podName` glob + a `program:` label matching the hub parser's filter, plus
  `poll_without_inotify: true` — see the log-rotation gotcha), the collection appended to
  `agent.env.COLLECTIONS`, and the bouncer middleware on that app's Ingress so a resulting
  decision is actually enforced. Verify with `cscli explain` (above) before trusting it.
- **Not every app can be a log source.** Authentik was tried and reverted: it writes auth
  events to its **database**, and its stdout carries only `authentik.asgi` request logs, so no
  parser can distinguish a failed password from a success. Home Assistant works precisely
  because it logs the failure itself. Check for a real failed-auth line on stdout *before*
  wiring an acquisition — dead config is worse than no config.
- **Monitoring gap**: `CrowdSecIngestionStalled` sums `cs_parser_hits_total` across all
  acquisitions, so it fires only if *everything* stops. Traefik's volume dwarfs HA's, so an
  HA-specific acquisition wedge would not trip it. If HA detection ever becomes load-bearing,
  add a per-source rule — but note the `source` label embeds pod name + container ID and
  churns on every rollout.
