# CloudNativePG: PostgreSQL major version upgrades

Companion to [`cnpg-ha.md`](cnpg-ha.md). That doc covers `instances: 1 → 3`; this
one covers crossing a **major** — the operation that took immich from PG14 to
PG17 on 2026-08-09, and that authentik (still 16) and eventually every cluster
will need.

CNPG ≥ 1.26 does this **declaratively**: change `.spec.imageName` to an image with
a higher major and the operator runs `pg_upgrade` for you. We are on 1.30.

Three properties decide everything else about the procedure:

1. **It is a full outage, replicas included.** The operator shuts down *every*
   pod, runs the upgrade job on the primary's PVC, then **destroys the replica
   PVCs** and re-clones them. `<cluster>-rw` has no endpoint throughout. This is
   not a rolling update and `primaryUpdateMethod: switchover` does not apply.
2. **`pg_upgrade --link` means there is no in-place downgrade.** The old data
   directory is hard-linked into the new one and then removed. Once the upgrade
   *succeeds*, going back means restoring a backup into a new cluster.
3. **PITR does not cross a major boundary**, and `pg_upgrade` resets the timeline
   to 1. Both facts land on the barman archive — see [the serverName
   rule](#the-servername-rule) below, which is the single least obvious part of
   this whole procedure.

## Prerequisites

- **Same OS distribution on both images.** CNPG only supports major upgrades
  between images built on the same distro. For immich this was the load-bearing
  check: `cloudnative-vectorchord:14-0.4.3` and `:17-0.4.3` are both Debian
  bookworm, same upstream build revision. Same base also means the same glibc,
  so the `C` collation carries over with no reindex.
- **Extensions must exist, at compatible versions, in the target image.** The
  safest shape is the one immich used: hold every extension version *constant*
  and move only the PostgreSQL major, so the upgrade has exactly one variable.
  If an extension version does move, `pg_upgrade` may leave an
  `update_extensions.sql` in PGDATA — CNPG logs it, and you must run it.
- **`.spec.postgresql.parameters` must be non-empty.** The upgrade path writes
  `max_slot_wal_keep_size=-1` into that map; CNPG's mutating webhook materialises
  it server-side so it is populated in practice even when the manifest sets none.
  Check it (`kubectl get cluster <c> -o jsonpath='{.spec.postgresql.parameters}'`)
  rather than assume.
- **`max_slot_wal_keep_size` must be `-1`** when the target is PostgreSQL
  17.0–17.5 — a `pg_upgrade` bug in those releases. The operator forces it during
  the upgrade, and we set it nowhere, so this is a "confirm, don't fix".
- **The OLD image must stay pullable.** The upgrade job's `prepare` init container
  runs on `.status.pgDataImageInfo.image`, not the new tag.

## Rehearse it first — it is nearly free

This is the part that generalises best, so do it every time.

`backup-verify` already restores every cluster from barman weekly, which means a
**real-data rehearsal costs one `kubectl apply` and one `patch`**: recover the
cluster under test into a scratch cluster on the *current* image, then bump *that*
one's image and watch the upgrade. Production is never touched.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg17-rehearsal
  namespace: backup-verify
spec:
  instances: 1
  imageName: <the CURRENT image>
  storage:
    size: 5Gi
    storageClass: local-path
  postgresql:
    shared_preload_libraries:   # mirror prod exactly — this is under test
      - vchord.so
  bootstrap:
    recovery:
      source: <source cluster>
  externalClusters:
    - name: <source cluster>
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: postgres-backups-store
          serverName: <source cluster's serverName>
```

Two traps:

- **No `spec.plugins`.** That is this namespace's safety invariant: with no WAL
  archiver attached the scratch cluster physically cannot write to the object
  store. `externalClusters[].plugin` is a read path only.
- **Do not label it `app.kubernetes.io/name: restore-verify`.** The weekly
  CronJob's `cleanup()` deletes every cluster carrying that label from three
  separate call sites. Unlabelled, it is invisible to the job — and the job
  excludes the `backup-verify` namespace from discovery, so it will not try to
  verify it either.

Capture a baseline on the old major, patch the image, then re-assert. What
actually matters is not `SELECT version()` — it is that the *index files*
survived `--link`. For immich that meant `EXPLAIN (ANALYZE)` on both
`vchordrq` indexes:

```sh
kubectl -n backup-verify exec <pod> -c postgres -- psql -U postgres -d immich -c \
  "SET vchordrq.probes='1'; SET enable_seqscan=off;
   EXPLAIN (ANALYZE, COSTS OFF) SELECT \"assetId\" FROM smart_search
   ORDER BY embedding <=> (SELECT embedding FROM smart_search LIMIT 1) LIMIT 5;"
```

`Index Scan using clip_index` and 5 rows back on **both** sides. (Note the
`vchordrq.probes` GUC — without it the query errors with `need 1 probes, but 0
probes provided`, which looks like a broken index and is not.)

Tear down with `delete cluster` **and** `delete pvc -l cnpg.io/cluster=<name>`.

### What the immich rehearsal actually showed (2026-08-09)

Restore-from-backup 89s; the upgrade itself ~75s on a 390 MB database. PG 14.18 →
17.5; `vchord` stayed 0.4.3 and `vector` 0.8.0; every row count identical
(`asset` 14396, `asset_face` 15284, `smart_search` 13238, `face_search` 15279,
`person` 577, `geodata_places` 227901); `clip_index` 67 MB and `face_index` 43 MB
both intact and both still serving Index Scans. No `update_extensions.sql`.

It also settled the one genuine unknown: the upgrade job **does** render
`shared_preload_libraries = vchord.so` into the new PGDATA before starting the
new postmaster, so `pg_upgrade`'s binary-upgrade `CREATE EXTENSION vchord`
resolves. An extension that needs preloading is not a blocker.

And a number worth keeping: `vacuumdb --analyze-in-stages` took **3.7s**, after
which the same CLIP query went from 313 ms to 3 ms. `pg_upgrade` carries no
optimizer statistics — skipping ANALYZE does not break anything, it just makes
the application look broken.

## The serverName rule

**A major upgrade must move the cluster to a fresh barman `serverName`.** This is
the part that will be forgotten on the second app, so it is the reason this doc
exists.

`pg_upgrade` resets the timeline to 1, so the upgraded cluster starts archiving
`00000001...` segments — names that already exist under the old prefix from the
cluster's own timeline-1 era. Beyond the collision, the prefix would then hold two
majors' base backups, and barman recovery is *physical*: same-major only. A fresh
name gives the new major an empty archive to start from, and freezes the old chain
as the only rollback you have.

```yaml
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: immich-postgres-store
        serverName: immich-postgres-pg17     # defaults to the cluster name
```

It goes on the **Cluster's plugin parameters**, never on the ObjectStore — the
plugin's docs say `ObjectStore.spec.configuration.serverName` exists only for API
compatibility with the in-tree `barmanObjectStore` and must be left empty.

### ⚠️ Gotcha: it breaks restore verification unless you follow through

`kubernetes/apps/backup-verify/cronjob-postgres.yaml` reads **both**
`.spec.imageName` and the plugin's `serverName` off each source Cluster, and
defaults the latter to the cluster name. That default is what the other six
clusters rely on. If the CronJob ever derives the server name from the cluster
name instead of reading it, an upgraded cluster gets its *pre-upgrade* archive
restored with its *post-upgrade* image — which fails, weekly, for a reason that
reads like a missing backup.

### Consequence to clean up by hand

Once nothing archives to the old prefix, the ObjectStore's `retentionPolicy`
stops applying to it — those objects live forever. That is deliberate while it is
your rollback artefact; delete the prefix once the new major has proven itself.

## Execution

1. **Pre-flight.** Cluster healthy and `readyInstances == instances`; the
   prerequisite checks above; no logical replication slots; disk headroom on the
   primary's PVC; `ContinuousArchiving=True`. Record `datcollate`/`datctype` and
   the encoding for `template1` and `postgres` — the upgrade job's `initdb` passes
   no `--locale`/`--encoding`, so a locale disagreement between the two images is
   a hard `pg_upgrade` abort. Record row counts and index sizes to compare against.
2. **Silence** `CNPGClusterNotReady`, `PostgresInstanceDown` (both 5m), and at 15m
   `CNPGClusterDegraded`, `CNPGInstanceMetricsMissing`,
   `CNPGContinuousArchivingFailed`, plus the app's blackbox Probes and Uptime Kuma
   monitors. All route to Discord.
3. **Quiesce the app** — `flux suspend hr` then scale its deployments to 0.
   ⚠️ `flux resume` will **not** put the replica count back (Helm sees no diff);
   scaling up again is a manual step.
4. **Force a base backup on the OLD serverName** — the rollback artefact. Do this
   **imperatively, before merging**, not as a committed manifest: a committed
   `Backup` would race the operator's shutdown, and once merged it would inherit
   the *new* serverName and write to the very prefix it is meant to protect you
   from. Use an explicit `name` and omit `backupOwnerReference: self`. Verify it
   with `kubectl get backups.postgresql.cnpg.io` — ⚠️ fully qualified, since
   mariadb-operator and Longhorn both register kind `Backup` and the short name
   resolves to the wrong CRD.
5. **Merge the PR**, then `flux reconcile kustomization apps --with-source`.
6. **Watch.** Phase goes to `Upgrading Postgres major version`; the job is
   `<primary-pod>-major-upgrade` (label `cnpg.io/jobRole=major-upgrade`,
   `backoffLimit: 0`). `.status.pgDataImageInfo.majorVersion` flipping is the
   completion signal. Replica PVCs being destroyed is expected, not a failure.
   `archive_command` failures *inside the job log* are also expected — the plugin
   sidecar is not in the upgrade job.
7. **`vacuumdb --analyze-in-stages`** before letting the app back in.
8. **Force a base backup on the NEW serverName.** Until it exists there is no PITR
   for the new major, and restore verification has nothing to restore.
9. Confirm `ContinuousArchiving=True`, `LastBackupSucceeded=True`, all instances
   ready, and that replicas load any preloaded extension.
10. **Un-quiesce**, then validate the app against whatever the extensions actually
    serve — for immich that is CLIP search and People, plus a fresh upload (index
    *insert* is a different code path from index *scan*; a stale index can read
    fine and fail to write).
11. **Trigger restore verification by hand** rather than waiting for Sunday:
    `kubectl -n backup-verify create job --from=cronjob/postgres-restore-verify <name>`.
    It proves the new serverName, the new image, and the CronJob change in one
    shot — and because the Job carries a controlling ownerReference back to the
    CronJob, it advances `lastSuccessfulTime` and re-arms
    `PostgresRestoreVerificationStale` instead of leaving a blind window.

## Rollback

| Stage | What to do |
|---|---|
| Merged, upgrade not yet started | Revert the PR and reconcile. Nothing has changed. Same if pods are down but the job has not started — the operator brings the cluster back up on the old major. |
| **Upgrade job failed** | Revert the PR. Do **not** delete the job by hand; the operator needs to see it to roll back cleanly (`MajorUpgradeRollback` event). Your data directory was never modified — `pg_upgrade` wrote only to the new directory. If a `pgdata-new.failed_<ts>` directory is left behind, delete it: the upgrade refuses to re-run while one exists. No data loss. |
| **Upgrade succeeded**, app then misbehaves | No in-place downgrade. Quiesce, then bootstrap a **new** cluster on the **old** image with `bootstrap.recovery` against the **old** serverName, and repoint the app at its `-rw` service and `-app` secret. Data horizon is the pre-upgrade backup. |

⚠️ **The password trap in that last row.** A `recovery` bootstrap does not reset
the restored role's password, but CNPG mints a *fresh random* `<new>-app` secret —
so the app gets a password the restored database has never heard of. Fix it
explicitly before repointing:

```sh
NEWPW=$(kubectl -n <ns> get secret <new>-app -o jsonpath='{.data.password}' | base64 -d)
kubectl -n <ns> exec <new-primary> -c postgres -- psql -U postgres -c \
  "ALTER ROLE <role> WITH PASSWORD '$NEWPW'"
```

Also give the restored cluster its **own** serverName — never let it archive back
into the frozen prefix it was restored from.

⚠️ Do not bundle an application version bump into a major upgrade PR. Stage-C
rollback is only safe while the app version is unchanged; the moment the app has
migrated its schema forward, restoring the old major stops being a rollback.

## Status

| Cluster | Major | Notes |
|---|---|---|
| immich | **17** | 14 → 17 on 2026-08-09. VectorChord (`vchord.so` preloaded), SUPERUSER app role. `serverName: immich-postgres-pg17`; `immich-postgres/` is a frozen PG14 archive restorable only with a PG14 image. |
| authentik | 16 | Next. Plain `cloudnative-pg/postgresql`, only `pg_trgm` — much simpler, but it is the SSO dependency for everything, so not on a day anything else is moving. |
| gitea, n8n, paperless, tandoor, tracearr | 17 | tracearr is TimescaleDB and pins `timescaledb VERSION '2.19.3'`; a base image change there needs `ALTER EXTENSION timescaledb UPDATE` and its own rehearsal. |

## Known issues

- **PostgreSQL 17.0–17.5 as an upgrade target** requires `max_slot_wal_keep_size
  = -1`. The operator forces it, we never set it — confirm, don't fix.
- **`ghcr.io/tensorchord/cloudnative-vectorchord` is stale.** Last built
  2025-06-20; `17-0.4.3` is PG **17.5**, not a current 17.x, and there is no PG18
  tag. Moving to a maintained VectorChord image is its own decision with its own
  rehearsal.
- **Renovate cannot see any of these images.** Its `kubernetes` manager keys on
  `image:`; CNPG uses `imageName:`. A `customManagers` regex over
  `kubernetes/apps/**/postgres-cluster.yaml` would fix it for all seven clusters
  at once.
