# CloudNativePG: single-instance → HA (`instances: 3`)

Every app database in this cluster runs as a **single CloudNativePG instance on
`local-path` (node-local) storage**. That has two consequences we want to fix:

1. **No failover** — if the node hosting the DB dies, the database is down until that
   node comes back (data is safe on its disk, but unreachable).
2. **Workers can't be drained** — CNPG gives a single-instance cluster a `-primary`
   PodDisruptionBudget that allows **0** disruptions, so `kubectl drain` can never evict
   the primary and deadlocks forever (this is what stalled worker-02 during the k3s 1.31
   upgrade, and why the [System Upgrade Controller](updates.md) agent Plan is cordon-only).

The fix for a **database** is app-level replication, **not** shared/replicated block
storage. Running 3 CNPG instances (primary + 2 streaming replicas, spread across nodes)
gives automatic failover and makes the PDB permit disruptions — while keeping cheap
`local-path` disks, because resilience now comes from Postgres replication, not the volume.

> Putting a single Postgres instance on networked storage (Longhorn/Ceph) only buys volume
> *mobility* — it's still one instance with downtime on any failover, plus a real
> performance/consistency cost. Replication is the correct HA answer for Postgres.

## Pre-flight

- **Disk headroom** — 3× storage per cluster. Going HA on all five DBs adds ~**120Gi** of
  `local-path` spread across nodes (authentik/paperless/n8n/tracearr 10→30Gi each, immich
  20→60Gi). Confirm the worker root disks have room.
- **≥3 schedulable nodes** — `required` anti-affinity + 3 instances needs 3 distinct nodes.
  We have 6 workers, so this is comfortable.
- **Do it while version-stable** — not in the middle of a k3s node upgrade.

## The change (per app, GitOps)

Edit the app's `postgres-cluster.yaml` — bump `instances` and add an `affinity` block.
Nothing else changes (image, storage class/size, barman plugin, bootstrap, resources):

```yaml
spec:
  instances: 3                       # was 1  → primary + 2 replicas
  primaryUpdateMethod: switchover    # graceful primary roll (see gotcha below)
  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    podAntiAffinityType: required    # hard-guarantee replicas on separate nodes
  # ...everything else unchanged
```

Why it's safe:

- Adding **replicas** is online — CNPG clones them from the running primary via
  `pg_basebackup`; the primary keeps serving.
- `bootstrap.postInitApplicationSQL` runs only at the *original* primary bootstrap, **not**
  on replica creation. Replicas inherit the schema (and extensions) via streaming, so those
  statements never re-run.
- Keep replication **async** (CNPG default) — a homelab wants writes to keep working if a
  replica is down. Do **not** set `minSyncReplicas`.
- `podAntiAffinityType: required` guarantees replicas land on different nodes (co-location
  defeats HA). If a replica ever goes `Pending` for capacity, soften to `preferred`.

### ⚠️ Gotcha: the affinity block rolls the primary

Adding the `affinity` block changes the **primary's** pod spec, so CNPG must roll the primary
too — and its **default `primaryUpdateMethod` is `restart`** (tear down + recreate the primary
pod, ~1–2 min). During that window the `<cluster>-rw` service has no endpoint and the app
loses its DB → **authentik crashlooped on its startup probe until the primary returned.** The
scale-up itself (adding replicas) is *not* what causes this — it's the primary roll.

Mitigation (baked into the snippet above): **`primaryUpdateMethod: switchover`** — CNPG
promotes a caught-up replica first (~seconds), then restarts the old primary as a replica, so
the write outage is a brief blip instead of a full restart. Setting this field does **not**
itself roll any pod. (authentik already took its one-time restart before this was added; the
field protects its future changes.)

## Rollout order & per-app quirks

Do one app per PR, and verify each reaches `READY 3` before starting the next.

| # | App | File | Quirk |
| --- | --- | --- | --- |
| 1 | **authentik** | `kubernetes/apps/authentik/postgres-cluster.yaml` | PG16 + `pg_trgm`. First — SSO for everything. ✅ done |
| 2 | paperless | `kubernetes/apps/paperless/postgres-cluster.yaml` | plain PG17 — trivial |
| 3 | n8n | `kubernetes/apps/n8n/postgres-cluster.yaml` | plain PG17 — trivial |
| 4 | tracearr | `kubernetes/apps/media/tracearr/postgres-cluster.yaml` | TimescaleDB — validate replicas load the extension |
| 5 | immich | `kubernetes/apps/immich/postgres-cluster.yaml` | **last**: PG14 + VectorChord + SUPERUSER, 20Gi. Validate `vchord` loads on replicas |

TimescaleDB and VectorChord both support physical/streaming replication, so CNPG replicas
work — the note is only to confirm the extension loads on the new replicas.

## Verification (per cluster)

```sh
kubectl -n <ns> get cluster <name>        # INSTANCES 3, READY 3, "Cluster in healthy state"
kubectl -n <ns> get pods -o wide          # 3 pods on 3 DIFFERENT nodes
kubectl -n <ns> get pdb                    # PDB now allows disruptions (ALLOWED DISRUPTIONS >= 1)
kubectl cnpg status <name> -n <ns>         # if the cnpg kubectl plugin is installed
```

Also confirm `kubectl kustomize kubernetes/apps/<app>` builds clean and the app itself stays
up throughout.

## Failover drill (prove it works)

On a non-critical cluster first (e.g. tracearr), delete the primary pod and watch CNPG
promote a replica:

```sh
kubectl -n media delete pod tracearr-postgres-1
kubectl -n media get cluster tracearr-postgres -w   # new primary within seconds, back to 3/3
```

The app should reconnect on its own.

## Worker drains (enabled, now that the DBs are HA)

The SUC agent Plan (`.../system-upgrade-controller/plans/agent.yaml`) drains movable pods
before the binary swap:

```yaml
  drain:
    force: true
    ignoreDaemonSets: true
    deleteEmptydirData: true        # note: lowercase "dir" is the CRD field name
    skipWaitForDeleteTimeout: 60
    podSelector:                     # drain everything EXCEPT CNPG pods
      matchExpressions:
        - { key: cnpg.io/cluster, operator: DoesNotExist }
```

**Why exclude CNPG.** Their PVCs are node-local (`local-path`), so a drained replica can't
move anyway, and draining a node with a CNPG **primary** forces a switchover — which on a busy
DB re-triggers [#828](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/828). Excluding
them lets CNPG restart in place on the k3s restart (no switchover, no #828), while everything
movable migrates gracefully.

**Trade-off to know:** other single-instance `local-path` apps (Prometheus TSDB, MariaDB,
`*arr` configs) also can't relocate, so they blip/down for their node's upgrade window — that's
inherent to draining on a node-local-storage cluster. Cordon-only (drop the `drain:` block) is
gentler for those and remains a valid choice.

## Known issue: WAL archiving stuck after a busy switchover (#828)

On a **busy** DB, the affinity-triggered switchover can leave the old primary with a backlog
of **un-archived WALs**, creating a gap that trips
[plugin-barman-cloud #828](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/828):
the new primary fails `barman-cloud-check-wal-archive` with **"Expected empty archive"**, so
WAL archiving wedges cluster-wide (`ContinuousArchiving=False`, empty `lastArchivedWAL`) and the
old primary can't rejoin (stuck `1/2`, cluster "Upgrading"). Hit on **immich** (622 pending
WALs); the quieter DBs switched over cleanly. The app stays up and data is safe (replicated) —
only the backup pipeline is affected.

Fix (no upstream release yet): **start a fresh archive chain** by overriding the barman
`serverName` to a new value in the cluster's `spec.plugins[].parameters`, e.g.
`serverName: immich-postgres-r2`. The new `s3://.../immich-postgres-r2/` path is empty, so the
first-WAL check passes, archiving resumes, and the stuck instance rejoins. **Then take a fresh
base backup** so the new chain is restorable; the old chain is retained for its 14d window.
Verify: `kubectl -n <ns> get cluster <name>` → `ContinuousArchiving=True`, `READY 3`.

## Out of scope

- **MariaDB / uptime-kuma** HA (mariadb-operator replication/Galera) — non-critical, no PDB.
- **Replicated storage** (Longhorn or Piraeus/LINSTOR) for the non-DB `local-path` PVCs that
  can't self-replicate — a separate, larger effort.
- **Backups** are unaffected — barman → RustFS keeps archiving from the primary; HA
  complements backups, it doesn't replace them (see [backup-recovery.md](backup-recovery.md)).
