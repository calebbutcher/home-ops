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
| 5 | immich | `kubernetes/apps/immich/postgres-cluster.yaml` | **last**: PG17 + VectorChord + SUPERUSER, 20Gi (was PG14 — see `cnpg-major-upgrade.md`). Validate `vchord` loads on replicas |

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

## Worker drains — CNPG is always excluded

There are two things that reboot a worker, and they treat drains differently:

- **k3s version upgrades (SUC)** — `cordon: true` only, **no drain**. A `drain:` block was
  added here in `e8993e6` when the DBs went HA and reverted in `e9ba696`: it predates the
  Longhorn migration and deadlocks against it. Do not re-add it. See
  [updates.md](updates.md#k3s-version-upgrades-system-upgrade-controller).
- **OS package updates (Ansible)** — *does* drain, via
  [`ansible/tasks/k8s_node_reboot.yml`](../ansible/tasks/k8s_node_reboot.yml), using a pod
  selector that excludes both Longhorn's `instance-manager` and every CNPG pod:

  ```text
  longhorn.io/component!=instance-manager,!cnpg.io/cluster
  ```

**Why exclude CNPG.** Draining a node holding a CNPG **primary** forces a switchover, which
on a busy DB re-triggers [#828](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/828)
(hit on immich, 622 pending WALs). It would also block: each `<cluster>-primary` PDB allows
**0** disruptions until the operator has moved the primary itself. Excluding them lets CNPG
ride the reboot and fail over on its own — which it does correctly on hard node loss —
while everything movable migrates gracefully first.

**Trade-off to know:** single-instance `local-path` apps (Prometheus TSDB, MariaDB, `*arr`
configs) cannot relocate either, so they are down for their node's reboot window regardless.
That is inherent to node-local storage, not to draining. `-e drain=false` gives cordon-only
behaviour and remains a valid choice.

⚠️ The CNPG data PVCs are **no longer `local-path`** — the Longhorn migration moved all 8
clusters to `longhorn-single` (1 replica, `dataLocality: best-effort`). Older notes here that
reasoned from "their PVCs are node-local" are out of date; the switchover/#828 argument is
what still stands.

## Known issue: WAL archiving stuck after a busy switchover (#828)

On a **busy** DB, the affinity-triggered switchover can leave the old primary with a backlog
of un-archived WALs and — more importantly — the `.check-empty-wal-archive` marker file
persisting in `$PGDATA` (it should be removed once archiving resumes). That makes
[plugin-barman-cloud #828](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/828)
fire: the plugin runs `barman-cloud-check-wal-archive` on **every** archive call and fails
**"Expected empty archive"** against the legitimately non-empty archive — so WAL archiving
wedges cluster-wide (`ContinuousArchiving=False`, empty `lastArchivedWAL`) and the old primary
can't rejoin (stuck `1/2`, cluster "Upgrading"). Hit on **immich** (622 pending WALs); the
quieter DBs switched over cleanly. App stays up and data is safe (replicated) — only the backup
pipeline is affected.

**Recovery — the `cnpg.io/skipEmptyWalArchiveCheck: "enabled"` annotation** on the Cluster (skips
the buggy check). With it set, archiving resumes on the existing chain and the stuck instance
flushes its pending WALs (closing the gap) and rejoins. Verify: `kubectl -n <ns> get cluster
<name>` → `ContinuousArchiving=True`, `READY 3`. ⚠️ A fresh `serverName` does **NOT** fix this
(confirmed by the maintainer on issue #828): the check fails against *any* non-empty archive, so
pointing at a new path only works until the first WAL lands.

**Then remove the annotation again** — it globally disables a safety check, so it's a recovery
lever, not a permanent setting. It's only safe to remove once continuous archiving is healthy
**and** the `.check-empty-wal-archive` marker is gone in `$PGDATA` on **every** instance (the check
is gated on that marker; CNPG numbers instances from `1`):

```sh
for i in 1 2 3; do echo "== <name>-$i =="; kubectl -n <ns> exec <name>-$i -c postgres -- \
  ls -la /var/lib/postgresql/data/pgdata/.check-empty-wal-archive 2>&1 || true; done
# all "No such file or directory" → safe to drop the annotation (GitOps; metadata-only, no pod roll)
# still present on a pod → `rm -f` that path on it first (benign stale flag), then drop the annotation
```

⚠️ **No released upstream fix exists** — PR #843 was closed unmerged and we're on the latest plugin
(v0.13.0) — so a future *busy* switchover can re-trigger #828; just re-apply the annotation to
recover, then remove it again. On **immich** the marker was confirmed gone on all three instances
and the annotation was dropped (PR #73 recovered it; a follow-up PR removed the annotation). Not
needed pre-emptively on the other DBs — they only trip this on a *busy* switchover.

## Out of scope

- **MariaDB / uptime-kuma** HA (mariadb-operator replication/Galera) — non-critical, no PDB.
- **Replicated storage** (Longhorn or Piraeus/LINSTOR) for the non-DB `local-path` PVCs that
  can't self-replicate — a separate, larger effort.
- **Backups** are unaffected — barman → RustFS keeps archiving from the primary; HA
  complements backups, it doesn't replace them (see [backup-recovery.md](backup-recovery.md)).
