# reef-log: hand-entered tank readings

Phosphate and nitrate are measured with a test kit, not a probe. They are
entered in the HYDROS app as static inputs, and **the public API never returns
them** — see [hydros-deploy.md](hydros-deploy.md) for the audit that established
this. reef-log is the non-API path: a small form that records a reading and
publishes it to Prometheus.

Source: [github.com/calebbutcher/reef-log](https://github.com/calebbutcher/reef-log).

## Why the metric names look like the exporter's

reef-log publishes under the names the HYDROS exporter *would* use for the same
reading:

```
hydros_input_phosphate_ppm{name="Phosphate",   basis="PO4", source="manual"}
hydros_input_nitrate_ppm{name="Nitrate",       basis="NO3", source="manual"}
hydros_input_alkalinity_dkh{name="Alkalinity", basis="dKH", source="manual"}
hydros_input_specific_gravity{name="Salinity", basis="SG",  source="manual"}
hydros_input_salinity_ppt{name="Salinity", basis="SG-derived", source="manual"}
hydros_input_measured_timestamp_seconds{name="Phosphate", source="manual"}
```

`hydros_input_alkalinity_dkh` is the name the exporter already reserves for a
HYDROS alkalinity tester, so adding an Alky later joins this same series.

That is deliberate, and it is the whole design. We control the metric name —
`classify_input()` / `UNIT_METRICS` in the exporter decide it, not CoralVue — so
if the API ever reports these, the exporter emits the *same* name and the two
histories merge on `max by (name)` with no backfill and no rename. Verified
against Thanos:

| | |
|---|---|
| `{source=""}` | Matches series that have no `source` label — i.e. the exporter's |
| `A or B`, both present | Left wins |
| `A or B`, A empty | Falls back to the right |
| `max by (name)` over both | One series |

Transition query, if that day comes — API preferred, manual fills the past:

```promql
max by (name) (hydros_input_phosphate_ppm{source=""})
  or max by (name) (hydros_input_phosphate_ppm{source="manual"})
```

The dashboard does not use that form today; it queries
`max by (name) (hydros_input_phosphate_ppm)`, which merges both sources already.

🔴 **Only reef-log sets `source`.** Never add a `source` label to the exporter's
metrics: adding a label changes series identity and would fork temperature and pH
into new series, the same failure as the pod churn fixed in #414.

### Salinity is the one that cannot share a name

A HYDROS salinity probe reports **ppt** (~35); a refractometer reads **specific
gravity** (~1.026). Publishing SG under `hydros_input_salinity_ppt` would merge
1.026 with 35 and produce a nonsense series — the one place the merge design
actively breaks if the names are chosen carelessly.

So SG is stored and published as measured, and ppt is *derived* alongside it:
the raw measurement is never lost, and a future probe still has a ppt series to
land in. The dashboard shows SG, since that is what gets measured and acted on.

The conversion is linear through two published reference points for SG at 25 °C
referred to water at 25 °C — 1.0226 → 30 ppt and 1.0264 → 35 ppt — and checks
out against a third (1.0210 → 27.9 vs a published 28). Good to about 0.2 ppt
across the reef range. **It is wrong if the refractometer is calibrated at some
other temperature**, which is why the SG value is the one stored.

### The basis is stored, not assumed

Phosphate can be reported as PO₄ or as P (3.07× apart), nitrate as NO₃ or as N
(4.43×), alkalinity as dKH, meq/L or ppm CaCO₃. Every row records which, because
a number with no stated basis cannot be reconciled later at any price — whereas
a wrongly-named metric can be fixed in one query.

The label is `basis`, not `compound`: dKH and SG are not compounds. It was
renamed in `v0.2.0`, while the database still held zero readings and the rename
was therefore free.

**If the API side is added later:** give it `ppm` in `UNIT_METRICS` plus a name
token so it emits `hydros_input_phosphate_ppm`, *not* the generic
`hydros_input_reading` fallback. The "All readings" table on the Tank dashboard
is the early warning that the controller has started reporting it.

## What's in `kubernetes/apps/reef-log/`

| File | |
|---|---|
| `namespace.yaml` | Own namespace, PSA `baseline` |
| `pvc.yaml` | 1Gi Longhorn, holds the SQLite database |
| `helmrelease.yaml` | app-template 5.1.0, GHCR image, Service, ServiceMonitor |
| `ingress.yaml` | `reef-log.int.nerdbox.dev`, behind Authentik |

Its own namespace rather than `monitoring`, which is pinned to privileged PSA
for Alloy's dbus and AppArmor needs — a user-facing write path should not
inherit that.

No VolSync, following coc-trade-bot: Longhorn's `daily-backup` RecurringJob
covers the `default` group, and every reading reaches Thanos on the next scrape
and lives there two years. Losing the database would cost the entry log, not the
history the dashboards draw from.

`replicas: 1` + `strategy: Recreate` — RWO volume and SQLite's single writer.
The ServiceMonitor pins `instance` and drops `pod` for the same reason as the
exporter: without it every redeploy mints a fresh series set.

## Auth

The app has **no login of its own**; the Authentik forwardAuth middleware is the
entire boundary. `POST` additionally rejects cross-origin submissions, so an
Authentik session cookie cannot be replayed from another site.

This does not gate Prometheus — the ServiceMonitor scrapes the ClusterIP Service
directly and never traverses Traefik.

## Timezone

The form posts naive local time, so `TZ` in the HelmRelease decides how a
"measured at" entry is read. It is `America/New_York`, **not** UTC like the
exporter. Change both together or entries will land offset.

## Verify

```sh
kubectl -n reef-log get pods,pvc
kubectl -n reef-log port-forward svc/reef-log 8080:8080
curl -s localhost:8080/metrics | grep hydros_input
```

Then open <https://reef-log.int.nerdbox.dev>, record a reading, and confirm it
appears on **Hydros / Tank** within a scrape (1m).

```promql
count(max by (name) (hydros_input_phosphate_ppm))          # 1 per parameter
count(count by (pod) (hydros_input_phosphate_ppm[24h]))    # 1, across redeploys
```

## Caveats worth knowing

⚠️ **Prometheus samples at scrape time.** A back-dated entry graphs as a step at
the moment it was *entered*, not when it was measured; out-of-order backfill is
rejected. `hydros_input_measured_timestamp_seconds` is what carries the real test
time, and the trends draw these as stepped points so a held value cannot be
mistaken for continuous measurement.

⚠️ **The value is held between tests.** That is correct for a water parameter,
which genuinely persists — unlike the exporter's live telemetry, where a stale
value is dropped rather than republished as fiction.

## Adding a parameter

Add a `Parameter` to `reeflog/parameters.py` (name, compound, metric name, and
sanity bounds), then add it to `CHEM` in the dashboard generator. Alkalinity
already has a metric name reserved — `hydros_input_alkalinity_dkh` — so a manual
alk entry would merge automatically if an Alkatronic or Trident is ever added.
