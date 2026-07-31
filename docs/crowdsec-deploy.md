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

## Later: request-level WAF (AppSec)

CrowdSec's AppSec component (port 7422) adds OWASP-CRS / virtual-patching signature inspection
(the same niche as Coraza), kept in one ecosystem. Enable `appsec.enabled: true` +
`appsec.acquisitions`/`configs` in the HelmRelease and add a second Middleware in `appsec`
mode (`crowdsecAppsecEnabled: true`, host `crowdsec-appsec-service:7422`). Deferred for now.

## Notes

- **Community blocklist (CAPI)**: the LAPI auto-enrolls with the central API on first start
  (online) to pull the community blocklist — no key required. Optional: enroll into the
  [CrowdSec console](https://app.crowdsec.net/) for dashboards via `cscli console enroll <key>`.
- **Persistence**: LAPI uses two small `local-path` PVCs (decision DB + machine creds). On a
  fresh volume the `traefik` bouncer re-registers automatically from `BOUNCER_KEY_traefik`.
