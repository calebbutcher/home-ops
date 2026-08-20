# Speedtest Tracker: deploying on the cluster

This runbook covers the **net-new** [speedtest-tracker](https://github.com/alexjustesen/speedtest-tracker)
deployment under `kubernetes/apps/speedtest/`, which runs an hourly Ookla speedtest against the
WAN link and exports the result to Prometheus. It uses the
[`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/) with the
[LinuxServer image](https://docs.linuxserver.io/images/docker-speedtest-tracker/), reached at
<https://speedtest.int.nerdbox.dev> (internal only, gated by Authentik).

It closes the last blind spot in the monitoring stack: everything else watches the *inside* of
the cluster (nodes, Proxmox, TrueNAS, Longhorn, Postgres, a dozen apps) and nothing measured the
internet connection itself.

## Why this and not a Prometheus speedtest exporter

Every speedtest *exporter* — [MiguelNdeCarvalho](https://github.com/MiguelNdeCarvalho/speedtest-exporter),
[danopstech](https://github.com/danopstech/speedtest_exporter),
[heathcliff26](https://github.com/heathcliff26/speedtest-exporter) — runs the test **on scrape**.
Prometheus here runs **2 replicas** (`prometheusSpec.replicas`, for HA + Thanos dedup). Both
scrape every target, and Prometheus derives a target's scrape offset from its label set —
identical across replicas — so they fire at effectively the same instant. MiguelNdeCarvalho's
exporter has no lock around its test function and serves under Waitress' 4 threads, so its
`SPEEDTEST_CACHE_FOR` does not rescue this: two speedtests run concurrently, contend for the same
WAN link, and each reports roughly **half** the real throughput. That is an architecture mismatch,
not a tuning problem.

speedtest-tracker runs tests on its **own cron** (`SPEEDTEST_SCHEDULE`) and serves the last stored
result at `/prometheus`. Scrapes become idempotent reads, so the number of scrapers is irrelevant.
It is also actively maintained — unlike the exporters above, whose newest release is ~3 years old —
so Renovate can keep it current.

## Prerequisites

- **DNS**: `speedtest.int.nerdbox.dev` → cluster ingress (handled by external-dns via the
  `external-dns.alpha.kubernetes.io/target` annotation, like the other `*.int` hosts).
- **`APP_KEY`** generated *before* the first apply — see below.

## What's in `kubernetes/apps/speedtest/`

| File | Role |
|------|------|
| `namespace.yaml` | `speedtest` namespace, PSA `baseline`. |
| `speedtest-secret.sops.yaml` | `APP_KEY` (Laravel encryption key). |
| `pvc.yaml` | Longhorn `speedtest-config` (RWO, 2Gi, `/config`) — SQLite DB + Laravel storage. |
| `helmrelease.yaml` | app-template → Deployment + Service `speedtest-tracker:80` + ServiceMonitor. |
| `ingress.yaml` | `speedtest.int.nerdbox.dev`, security-headers + Authentik forward-auth. |

Plus, in `kubernetes/apps/monitoring/`:

| File | Role |
|------|------|
| `speedtest/dashboard.yaml` | Grafana dashboard (grafana.com ID 24608), defaults to the **Thanos** datasource. |
| `kube-prometheus-stack/prometheusrule-speedtest.yaml` | Six alerts → Discord. |

### Storage

SQLite in `/config`, **not** CNPG. The `/config` PVC is required either way (LinuxServer images
keep Laravel's key cache and storage dir there), so a Postgres cluster would be purely additive
for a table that gains one row an hour.

No `ReplicationSource` either — same reasoning as `coc-trade-bot`: Longhorn's `daily-backup`
RecurringJob covers the `default` group that every volume joins automatically, so this PVC is
already backed up to `s3://longhorn-backups` nightly at 04:00.

### securityContext

`fsGroup: 1000` only. **Do not** add `runAsUser` / `runAsNonRoot` / `capabilities.drop: ["ALL"]`.
LinuxServer images boot s6-overlay as root, chown `/config`, then drop to `PUID`/`PGID`
themselves; forcing a non-root uid breaks the init before the app starts. This is also why the
namespace is PSA `baseline` rather than `restricted`.

## Deploy

1. **Generate `APP_KEY` first.** This is Laravel's encryption key — every encrypted column in the
   database is sealed with it.

   ```sh
   echo "base64:$(openssl rand -base64 32)"
   ```

   It is already generated and committed in `speedtest-secret.sops.yaml`. ⚠️ **Never rotate it in
   place.** Changing it does not re-encrypt anything; it just makes the existing rows
   undecryptable and the app throws on boot. Losing it means starting the history over.

2. Merge the PR to `main`, then `flux reconcile kustomization apps --with-source` (or wait for the
   30m interval).

3. Watch it come up — first boot builds the SQLite file and runs migrations, which is what the
   5-minute startup probe window is for:

   ```sh
   kubectl -n speedtest get pods,pvc,ingress,certificate
   kubectl -n speedtest logs deploy/speedtest-tracker -f
   ```

   In the logs you want to see s6 drop to uid/gid 1000 and the migrations complete. A crash here
   is almost always a too-strict securityContext (see above).

4. Browse <https://speedtest.int.nerdbox.dev> → redirected to Authentik → after login the
   speedtest-tracker dashboard loads.

## Post-deploy configuration (in the UI)

These are **not** in git. Note that down for anyone reading the manifests and wondering why the
Grafana panels are empty.

1. **Change the default login.** The image ships `admin@example.com` / `password`. The Authentik
   forward-auth in front of it is what makes that survivable until you do; change it anyway.

2. **Enable the Prometheus endpoint** — Settings → Data Platforms → Prometheus: switch it on and
   allowlist the pod CIDR **`10.42.0.0/16`** (the live k3s default — *not* ansible's `10.52`
   `cluster_cidr`, which is not what the cluster actually runs).

   ⚠️ **Do this promptly after the first deploy.** Until it is done the route does not exist at
   all — `/prometheus` returns **404**, so the scrape fails, `up{job="speedtest-tracker"} == 0`,
   and `SpeedtestTargetDown` fires to Discord after 15 minutes. Verified on the 2026-08-19 rollout:
   the target sat at `up == 0` from the moment the pod went Ready.

   (That is the *good* failure mode — loud rather than silent — but it does mean a fresh deploy
   has a 15-minute clock on it.)

   Upstream closed the request to configure this via environment variables
   ([#2500](https://github.com/alexjustesen/speedtest-tracker/issues/2500)) as *not planned*, so it
   is database state, not git — same class of gotcha as pricewatch's watches living in the datastore.

3. Verify the endpoint from inside the cluster:

   ```sh
   kubectl -n speedtest run curl --rm -it --restart=Never --image=curlimages/curl -- \
     curl -s http://speedtest-tracker.speedtest.svc.cluster.local/prometheus | head
   ```

   Expect `speedtest_tracker_download_bits`, `speedtest_tracker_upload_bits`,
   `speedtest_tracker_ping_ms`, `speedtest_tracker_packet_loss_percent`, and friends (plus a
   `php_info` gauge the app emits alongside them). A **404** means step 2 is not done; an empty or
   403 response means it is enabled but the CIDR does not match.

4. **Nothing — the test server is pinned in git.** See below for why.

## The test server is pinned (and why that mattered)

`SPEEDTEST_SERVERS: "14229"` in the HelmRelease. It started out deliberately *absent*, letting
Ookla auto-select the nearest server. That turned out to be the single largest source of noise in
the data.

### What auto-selection actually did

Auto-selection kept landing on **GoNetspeed Rochester (49674)** for scheduled runs — 10 of the
first 13 successful ones. Grouping the first two days of results by server:

| Server | n | Download min/avg/max | Upload min/avg/max | Ping |
|--------|---|----------------------|--------------------|------|
| 14229 Frontier, Ashburn VA | 6 | 928 / 936 / **944** | 500 / 543 / 601 | 13.6ms |
| 14228 Frontier, Chicago IL | 3 | 923 / 931 / 936 | 428 / 454 / 495 | 15.5ms |
| 21276 Greenlight, Rochester NY | 2 | 932 / 932 / 932 | 379 / 384 / 389 | 22.0ms |
| 45389 U of Rochester | 1 | 742 | 293 | 24.6ms |
| **49674 GoNetspeed, Rochester NY** | **10** | **83 / 362 / 478** | 159 / 301 / 387 | 25.1ms |

GoNetspeed never once cleared 478 Mbps down on a link that does a steady ~935 everywhere else,
and bottomed out at **83 Mbps**. Every other server in the list agrees the line is healthy, so
this is that server's congestion — not the WAN.

It also almost certainly explains the failures. **7 of 20 scheduled tests (35%) died** with the
Ookla CLI's `Error: [0] Cannot read from socket:` — a server-side abort, recorded with
`server.id = null` so it cannot be attributed directly. But GoNetspeed was the auto-pick for
essentially every scheduled run in that window, and **zero** manual runs (which drew other
servers) failed. If failures continue after this pin, the server was not the cause.

The consequence was a false page in the making: **`SpeedtestDownloadDegraded` was `pending` on
2026-08-20** — six hours from firing to Discord — with the connection perfectly fine.

### Why exactly one ID, not a list

`SelectSpeedtestServerJob::getConfigServer()` does **`Arr::random($servers)`** over the list. A
second entry is *not* a fallback for when the first is unreachable — it is a coin flip on every
test. Since upload varies by server far more than download does (530 Mbps on 14229 vs ~380 on
Greenlight), a list would make the upload series **bimodal** and impossible to threshold
sensibly. One ID keeps the series comparable across time, and collapses the `server_*` label
cardinality the alert rules `avg()` away to a single value.

14229 was chosen because it is the lowest-latency entry in the entire nearby-server list and the
only one sustaining 900+ down *and* 500+ up.

> ⚠️ **Caveat:** 14229 is our own ISP's server, so this measures *Frontier's* network rather than
> a true internet path — it will not catch a bad peering/transit link. Accepted deliberately: it
> is also the cleanest possible evidence for the open upload complaint below (their own server,
> their own line). The nearest **neutral** replacement is **21276** (Greenlight Rochester), which
> held 932 Mbps down across every sample.

### Scheduled only

The job checks `$this->result->scheduled` *before* consulting `SPEEDTEST_SERVERS`, so manual runs
from the UI still auto-select and can still draw GoNetspeed. `SPEEDTEST_BLOCKED_SERVERS: "49674"`
covers those — manual runs skip the server list and fall through to the blocked-server filter.

Set `SPEEDTEST_SERVERS` to real IDs or omit it entirely — **never** `""`. Laravel's `env()` hands
a set-but-empty variable through as the empty string, which explodes into a list holding one
invalid server ID rather than meaning "choose for me".

To re-survey the field (the CLI orders its output nearest-first):

```sh
kubectl -n speedtest exec deploy/speedtest-tracker -- \
  speedtest --servers --format=json --accept-license --accept-gdpr
```

## Verify the monitoring path

- **Prometheus** → Status → Targets: job `speedtest-tracker` UP with a non-empty scrape.
  (`jobLabel` resolves through the Service's `app.kubernetes.io/name`, which is why the alert
  rules match `job="speedtest-tracker"`.)
- Trigger a manual test in the UI; the metric value changes within one 5m scrape.
- **Grafana** → *Speedtest Tracker*. It defaults to the **Thanos** datasource on purpose:
  `prometheusSpec.retention` is 2d, and the dashboard's default range is 30d, so against the local
  Prometheus it would be 93% empty. Same reasoning as the backup-verify dashboard.
- **Prometheus** → Alerts: the six `speedtest.*` rules load and sit inactive on a healthy line.
- **Longhorn UI** → Volume `speedtest-config` → Recurring Jobs shows `daily-backup` (inherited
  from the `default` group), confirming no VolSync is needed.

## Alerting

Thresholds live in `kube-prometheus-stack/prometheusrule-speedtest.yaml`. Download, latency and
loss are set for a **1 Gbps symmetric** line. Upload is **provisional and deliberately lower** — see
below.

### ⚠️ The upload threshold does not match the rated line speed

First readings (2026-08-19) put upload at **288.6–515.7 Mbps**, and fast.com from a LAN client
independently reported **500–600 Mbps** — two different measurement paths agreeing on roughly *half*
the rated 1 Gbps up, while download sat at a steady ≥935 Mbps. That is an ISP provisioning problem
to chase, not something to tune away.

Setting the alert at half the *rated* speed (500 Mbps) would therefore fire permanently and tell you
nothing new. It is set to **250 Mbps** instead — below the observed floor, since the 289 Mbps reading
was taken with a remote Plex stream running and anything higher would page on ordinary household
upload contention.

**Knowingly accepted:** a drop from ~550 to ~300 Mbps is a 45% regression this will *not* catch.
Recalibrate once ~24h of scheduled results give a real baseline distribution — three hours with a
confounding Plex stream is not enough to pick a good number from.

> **The recalibration clock restarts from the server pin (2026-08-20).** The scheduled results
> collected before it are unusable as a baseline: they are overwhelmingly GoNetspeed 49674, whose
> upload ran 159–387 Mbps against 500–601 on the pinned server. Averaging the two populations
> would set the threshold from the bad server's congestion. Wait for ~24h of post-pin results.

Note that the same contamination made the **download** threshold nearly misfire: `< 500 Mbps for
6h` is a sane number for this line, but GoNetspeed alone would have tripped it. That rule was
`pending` on 2026-08-20 with the WAN healthy — the pin is what makes 500 Mbps meaningful.

| Alert | Fires when |
|-------|-----------|
| `SpeedtestDownloadDegraded` | download < 500 Mbps for 6h |
| `SpeedtestUploadDegraded` | upload < 250 Mbps for 6h (provisional — see above) |
| `SpeedtestHighLatency` | idle ping > 100ms for 6h |
| `SpeedtestPacketLoss` | packet loss > 2% for 6h |
| `SpeedtestTargetDown` | Prometheus cannot scrape the app for 15m |
| `SpeedtestNoRecentResults` | no new result in 6h, or no metrics at all |

Two things that make these rules read oddly until you know why:

- The metrics are **gauges holding the last result**, not live measurements — a test runs hourly
  and the value then sits flat. So `for: 6h` means "six consecutive hourly tests came back slow",
  which is deliberate: one bad test (someone streaming 4K, a Wi-Fi blip) must not page anyone.
- Every rule aggregates with `avg()` to collapse the per-server labels. With the server pinned
  this is now a no-op on scheduled results, but keep it: a manual UI run auto-selects and emits a
  different `server_id`, and without the aggregation that starts a brand new series — splitting
  the comparison and resetting any range function looking back over it.

`SpeedtestNoRecentResults` exists because the failure that matters most here is silent: a wedged
scheduler or a disabled `/prometheus` endpoint leaves the gauges frozen at their last value, which
reads as "everything is fine" forever. The `changes()` arm is a heuristic — but two real
speedtests returning a bit-identical throughput figure six hours apart does not happen.

## Upgrades

Renovate manages the image tag like any other. The app is a Laravel monolith that runs migrations
on boot, so upgrades are ordinary rolling (well, `Recreate` — RWO PVC + SQLite's single-writer
rule) restarts. Keep `APP_KEY` untouched across them.
