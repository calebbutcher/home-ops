# Immich: bulk-upload OOM kills

Bulk uploads failed client-side for 17 days because `immich-server` was being
OOMKilled roughly every two minutes while it worked through the job queues. Single
uploads worked fine, which is what made it look like a flaky client rather than a
dead container. This documents the mechanism, the sizing, and the part of the fix
that git cannot hold.

> **Part of this is not in git.** Immich job concurrency lives in the database, in
> `system_metadata` under the `system-config` key, and is edited through the admin
> UI. Nothing in `kubernetes/apps/immich/` can pin it. The values below are
> therefore recorded here, and this document is the only record that they were
> deliberately chosen.

## What was happening

One container, two processes. `immich-server` runs both the API and the
microservices job worker, because `IMMICH_WORKERS_INCLUDE` is unset:

```
[Nest] 25 - [Api:...]            <- HTTP, serves uploads
[Nest]  7 - [Microservices:...]  <- BullMQ worker, thumbnails/faces/CLIP
```

They share one cgroup and one memory limit. The job worker is what outgrows the
limit, but the kernel kills the whole container, so **the API dies with it** and
every in-flight upload gets a connection reset. That is why the symptom appeared at
the client and not as an obvious server-side failure.

The secondary damage shows up in BullMQ as jobs that were holding a lock when the
worker vanished:

```
failedReason: job stalled more than allowable limit
data:         {"source":"upload","id":"..."}
```

Nine `thumbnailGeneration` jobs and two `facialRecognition` jobs were in that state.
They are not corrupt files — re-running the queue picks them up normally.

The `Machine learning request ... EPIPE` / `became unhealthy` lines in the server
log are a **symptom, not the cause**. The server dies mid-request to the ML pod, so
the socket breaks. The ML pod itself had 0 restarts throughout.

## Measured behaviour

Working set for `immich-server`, the evening it was diagnosed:

| Time (UTC) | Memory | |
|---|---|---|
| 21:59 | 1159 MiB | idle, flat for 6h+ |
| 22:00 | 1202 MiB | bulk upload begins |
| 22:02 | 3168 MiB | |
| 22:05 | 3978 MiB | hits the 4Gi limit → OOMKilled |
| 22:08 | 2074 MiB | restarted, climbing again |
| 22:17 | 3506 MiB | |
| 22:20 | 3 MiB | OOMKilled again |

About two minutes from idle baseline to dead. The ramp is near-vertical, not a
creep — which matters, because it rules out any "approaching the limit" alert as a
useful early warning (see the rejected-alternatives note in
`prometheusrule-oom.yaml`).

This predates the v3.2.0 bump. Thanos shows 4 restarts on 09-09 on the *previous*
pod, before that upgrade landed, so 4Gi was already marginal; v3.2.0 (which adds an
`ocr` queue) made it reliably fatal.

## The fix

Three parts. Only the first is in git.

**1. Sizing** — `kubernetes/apps/immich/helmrelease.yaml`

| | Before | After | Why |
|---|---|---|---|
| `requests.memory` | 512Mi | 1536Mi | Idle baseline is ~1160Mi. The old request was under half of true steady state, which understated the pod to the scheduler. |
| `limits.memory` | 4Gi | 8Gi | Peak demand is ~4Gi with default concurrency; 8Gi leaves headroom for a burst without another hard stop. |

**2. Job concurrency** — admin UI, *not* git

Both had been raised above upstream defaults. Defaults were confirmed by grepping
the `v3.2.0` server image directly, not from documentation:

| Queue | Was | Now | v3.2.0 default |
|---|---|---|---|
| `faceDetection` | 6 | 2 | 2 |
| `smartSearch` | 3 | 2 | 2 |

Six concurrent face-detection jobs plus three CLIP jobs, each buffering a
full-resolution decode, is the multiplier that turned a busy queue into a kill. The
CLIP model here is also the heavy one (`ViT-L-16-SigLIP-256__webli`), which is why
the ML pod's own working set jumps 682 MiB → ~2740 MiB the moment it loads.

If bulk uploads start failing again, **check these two values first** — they are UI
state, they survive no redeploy, and nothing in this repo will warn you that they
drifted.

**3. Alerts** — `kubernetes/apps/monitoring/kube-prometheus-stack/prometheusrule-oom.yaml`

Nothing alerted for 17 days. `KubePodCrashLooping` was stuck in `pending` the whole
time and structurally could not fire: it samples the `CrashLoopBackOff` waiting
*state* with `for: 15m`, and a container that dies every ~2 minutes spends most of
its life `Running`, so the clock kept resetting. There was also no OOM-specific
rule anywhere in the cluster. The new rules key on the restart *counter*, which
cannot oscillate away. See that file's header for the full reasoning.

## Worth doing next

Split the job worker into its own Deployment via `IMMICH_WORKERS_INCLUDE` (`api`
and `microservices`), which is what the upstream chart does. Then a job-worker OOM
degrades throughput instead of hard-failing uploads, and the API's memory ceiling
stops being a function of queue depth. Not done here because it is a topology
change, not a sizing one, and wanted its own PR.
