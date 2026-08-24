# HYDROS exporter: deploying on the cluster

Long-term reef telemetry from a CoralVue HYDROS collective — water chemistry,
output/equipment state and per-device health — into Prometheus, Thanos and
Grafana.

Exporter source: [github.com/calebbutcher/hydros-exporter](https://github.com/calebbutcher/hydros-exporter).

## Prerequisites

Two credentials, both required:

| Credential | Where from |
|---|---|
| Provider key | CoralVue, via the form at [coralvuehydros.com/api](https://www.coralvuehydros.com/api/#request-provider-key). Individuals can request an unlisted key. |
| Device key | The HYDROS app: Device Properties → Manage API Keys → New. |

Create the device key with **read** scope. The exporter never writes, and the
permission level is fixed at creation — widening it later means issuing a new
key and revoking the old one.

One device key covers the whole collective. The state document it returns
carries every member's inputs, outputs, `health` and `otaState`.

## What's in `kubernetes/apps/monitoring/hydros/`

| File | |
|---|---|
| `secret.sops.yaml` | `HYDROS_PROVIDER_KEY`, `HYDROS_DEVICE_KEY` |
| `helmrelease.yaml` | app-template 5.1.0, GHCR image, Service, ServiceMonitor |
| `dashboard-tank.yaml` | Grafana "Hydros / Tank" |
| `dashboard-equipment.yaml` | Grafana "Hydros / Equipment" |

Lives inside `monitoring` alongside pve-exporter rather than getting its own
namespace. No PVC, no VolSync, no NetworkPolicy — state is in memory and
cluster egress is unrestricted.

### Why it is a background poller and not a scrape-time fetch

Reading state is a two-step flow, not a plain GET:

1. `POST /api/v1/device/state/session` mints a 6-hour ES256 poll token **and
   wakes the device** so it starts reporting.
2. The returned `pollUrl` is polled with that token as a Bearer credential.

Session starts are capped at **5/hour per device**, and the cap is shared across
every key issued for that device. Prometheus runs `replicas: 2` here, so a
scrape-time fetch would double every call and make session usage a function of
scrape timing. The exporter instead renews on its own clock (30 min before
expiry) and polls every 30s into an in-memory cache; `/metrics` renders the
cache. API load is then constant no matter who scrapes.

The same limit is why the controller is `replicas: 1` with `strategy: Recreate`.
A second pod mints its own session; a rolling update would run two.

### Staleness

Readings stop being exported once the cache is older than `max(3 × poll
interval, 180s)`, leaving `hydros_up 0` and an honest gap. A single failed poll
is absorbed. Re-serving a last-known value every 30s would write fiction into a
two-year store.

## Deploy

```sh
sops kubernetes/apps/monitoring/hydros/secret.sops.yaml   # replace both REPLACE_ME values
git add -A && git commit && gh pr create
```

After merge:

```sh
flux -n flux-system reconcile kustomization apps --with-source
kubectl -n monitoring logs deploy/hydros-exporter
```

A healthy start logs a session mint, then nothing further until something
changes:

```
INFO hydros serving metrics on :8080
INFO hydros session valid until 2026-08-25T05:47:01+00:00, polling every 30s
```

## Verify

```sh
kubectl -n monitoring port-forward svc/hydros-exporter 8080:8080
curl -s localhost:8080/metrics | grep -E '^hydros_(up|state_age|input_)'
```

Then in Grafana (both dashboards default to the **Thanos** datasource, not the
2-day local Prometheus):

- `hydros_up == 1`
- `hydros_state_age_seconds < 60`
- Prometheus → Targets shows the `hydros-exporter` job UP on both replicas

## ⚠️ Calibrate the derived units against the app

The spec documents `voltageI` as millivolts and `powerI` as milliwatts. Its own
worked example contradicts both — a heater at `voltageI: 12062` is 120.62 V US
mains, and a pump's `voltageI`/`current`/`powerI` only reconcile if power is
tenths of a watt. The exporter therefore divides:

| Field | Divisor | Metric |
|---|---|---|
| `temperatureI` | 10 | `hydros_device_temperature_celsius` |
| `voltageI` | 100 | `hydros_output_voltage_volts` |
| `current` | 1000 | `hydros_output_current_amperes` |
| `powerI` | 10 | `hydros_output_power_watts` |
| `valueState` | 10000 | `hydros_output_level_ratio` |

Cross-check two or three readings against the HYDROS app before trusting the
wattage. Mains-powered gear should read ~120 V and DC gear ~24 V.

## Sensor naming

Sensor names are user-assigned, so the exporter classifies them by name token
(`temp`, `ph`, `orp`, `salin`, `alk`, `level`/`ato`) into unit-suffixed metrics.
Anything unmatched still exports as `hydros_input_reading{name,field}` — nothing
is dropped, it just lands untyped.

To type a sensor the heuristic misses, set `HYDROS_INPUT_UNITS` in the
HelmRelease:

```yaml
HYDROS_INPUT_UNITS: "Sump Probe=celsius,Reactor Out=ph"
```

Valid units: `celsius`, `ph`, `ppt`, `orp`, `dkh`, `level`.

After the first successful poll, check for anything that fell through:

```promql
count by (name) (hydros_input_reading)
```

## Alerting

None, deliberately. Thresholds set before a few weeks of real readings mostly
generate noise, and HYDROS already alerts natively through its own app. The
exporter surfaces the controller's own per-sensor alert flag as
`hydros_input_alert_active` so it is visible on the dashboard.

When you do add rules, note there is **no Thanos Ruler in this cluster**:
PrometheusRules evaluate against the local Prometheus and only see 2 days. A
"drifted since last month" rule has to be Grafana-managed against the `thanos`
datasource, which already has a Discord contact point.

## Upgrades

Tag the source repo (`v0.2.0`), let its build workflow publish to GHCR, then
bump `tag:` in `helmrelease.yaml`. Renovate picks the image up through the
`helm-values` manager — no `# renovate:` annotation needed, but the tag must
stay a full semver rather than a `sha-` pin.

New GHCR packages default to **private**, which surfaces as a 403
`ImagePullBackOff`. Make the package public on first publish.

## Retention

Thanos compaction keeps raw samples 30 days, 5m for 180 days and 1h for 2 years.
Downsampling preserves min/max per bucket, so two-year-old pH still shows its
hourly excursions; what goes after 30 days is sub-5-minute shape.
