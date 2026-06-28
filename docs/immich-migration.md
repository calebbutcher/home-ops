# Immich: migrating from Docker Compose into the cluster

This runbook covers a **one-time** migration of an existing **Docker Compose**
Immich install onto the in-cluster deployment under `kubernetes/apps/immich/`.
The in-cluster app uses the [`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/)
with **external Postgres (CloudNativePG + VectorChord)** and **our own Redis**,
reached at <https://immich.int.nerdbox.dev> (internal only).

Immich keeps two kinds of state:

- **Photo/video files** on TrueNAS NFS (`10.2.40.10:/mnt/mainPool/immich-data`).
  This is the bulk of the data. The cluster mounts the **same export in-place**, so
  **no files are copied** — only a clean cutover (one writer at a time) is required.
- **PostgreSQL** — albums, faces/people, smart-search embeddings, users, sharing,
  settings. This is logically dumped from Docker and restored into CNPG.

Redis is only a cache / job (BullMQ) broker and is **not** migrated — it rebuilds.

For restoring this app from backup (disaster recovery, not migration) see
[backup-recovery.md](backup-recovery.md).

## ⚠️ The catch: the database extension is stale

The Immich **server is already current (v2.7.5)**, but the database container was
never migrated off the now-deprecated **pgvecto.rs `vectors` 0.2.0** extension
(`docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0`). Immich still runs on it, but a
`0.2.0` dump **cannot** be restored straight into the VectorChord CNPG image.

So we first run Immich's **official pgvecto.rs → VectorChord migration in the
working Docker env** (Phase 1), then do a clean same-extension dump/restore into
the cluster (Phases 2–4).

> **Versions — pinned to match on both ends.** Source Postgres major is **14**. Phase 1
> migrates Docker onto **VectorChord 0.4.3** (the newest transition image on the
> `pgvectors-0.2.0` path), and the CNPG cluster pins the matching
> `ghcr.io/tensorchord/cloudnative-vectorchord:14-0.4.3` — so the restore is a
> same-major **and** same-vchord-version operation (no VectorChord 1.0 boundary to
> cross). Keep the in-cluster `immich-server`/`immich-machine-learning` tags **equal**
> and **≥** your running server (v2.7.5) — Immich only migrates schemas forward.

## What you need

- `kubectl` / `flux` pointed at the cluster, from this repo's context.
- Shell access to the Docker host running Immich.
- The transition image **`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`**
  (the `-pgvectors0.2.0` suffix lets it read your existing `0.2.0` data; `vectorchord0.4.3`
  matches the CNPG cluster). Background: [v1.133.0 release notes](https://github.com/immich-app/immich/releases/tag/v1.133.0).

## Steps

### 0. Land the manifests (no downtime)

Merge the `feat/immich` PR. Flux creates the `immich` namespace, the CNPG cluster
(bootstraps an empty `immich` DB with `vchord`/`cube`/`earthdistance` + a superuser
role), Redis, and the NFS PV/PVC. The Immich `immich-server` and
`immich-machine-learning` controllers ship at **`replicas: 0`** on purpose — the DB
must be restored before the app runs.

Wait for the DB to come up healthy:

```bash
kubectl -n immich get cluster immich-postgres
# → "Cluster in healthy state"; pod immich-postgres-1 Ready
```

### 1. Migrate the Docker DB to VectorChord (server stays on v2.7.5)

In the **Docker env**, where Immich's tested migrations run:

```bash
# 1a. Back up first — this is the rollback anchor (you flagged backups may be stale).
docker exec -t immich_postgres pg_dump --clean --if-exists \
  --dbname=immich --username=postgres | gzip > immich-pre-vchord.sql.gz
# copy immich-pre-vchord.sql.gz off-box

# 1b. In docker-compose.yml, update the `database:` service:
#   image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
#   - DELETE the `command:` line(s) (old `-c shared_preload_libraries=vectors.so ...`)
#   - DELETE the `healthcheck:` block (both are now handled inside the image)
#   - keep the volume + POSTGRES_* env
# Also ensure nothing forces DB_VECTOR_EXTENSION=pgvector|pgvecto.rs on immich-server.

docker compose pull && docker compose up -d
docker compose logs -f immich_server   # watch the reindex
# Normal to sit on "Reindexing clip_index" / "Reindexing face_index" for minutes
# on large libraries.

# 1c. Confirm the extension is now VectorChord 0.4.3 and the UI/search/faces work:
docker exec immich_postgres psql -U postgres -d immich -c "\dx"
# → vchord 0.4.3 (+ vector) present; no more "vectors 0.2.0"
```

### 2. Quiesce + dump (cutover begins)

Stop Immich's app containers but keep Postgres up, then dump the now-VectorChord DB:

```bash
docker compose stop immich-server immich-machine-learning   # keep immich_postgres up
docker exec -t immich_postgres pg_dump --clean --if-exists \
  --dbname=immich --username=postgres | gzip > immich-dump.sql.gz
docker compose down            # Docker fully stopped — single writer to the NFS export
```

### 3. Restore into CNPG

Pipe the dump through the `search_path` fix into the CNPG primary:

```bash
gunzip -c immich-dump.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | kubectl exec -i -n immich immich-postgres-1 -- \
      psql -U postgres -d immich --single-transaction --set ON_ERROR_STOP=on
```

`--single-transaction` + `ON_ERROR_STOP` means any failure rolls back cleanly (the
DB stays empty and the restore is re-runnable). Spot-check the row count against the
old stack:

```bash
kubectl exec -n immich immich-postgres-1 -- \
  psql -U postgres -d immich -c "SELECT count(*) FROM assets;"
```

### 4. Start Immich on the cluster

Flip both controllers back to `replicas: 1` in
`kubernetes/apps/immich/helmrelease.yaml`, commit, and push:

```yaml
controllers:
  immich-server:
    replicas: 1          # was 0 for the migration
  immich-machine-learning:
    replicas: 1          # was 0 for the migration
```

```bash
flux -n immich reconcile hr immich --with-source
kubectl -n immich get pods
```

Immich comes up against the migrated DB and the existing NFS library — no files
were copied.

## Verification

- Pods Ready: `immich-server`, `immich-machine-learning`, `immich-redis`,
  `immich-postgres-1`.
- Server health:
  `kubectl -n immich exec deploy/immich-server -- wget -qO- localhost:2283/api/server/ping`
- Web UI <https://immich.int.nerdbox.dev> — log in with an **existing** account;
  albums, faces, timeline, and thumbnails render (originals served from the same NFS).
- ML: trigger Smart Search / a face-recognition job; `immich-machine-learning` logs
  show model load + inference (first run downloads models to `model-cache`).
- DB backup: wait for the 04:00 `ScheduledBackup` (or run a one-off `Backup`) and
  confirm objects under `s3://postgres-backups/immich-postgres/` on RustFS.

## Rollback

Nothing destructive happens to the source until you've verified the cluster:

- The Docker Postgres volume is only **read** (pg_dump) — restart with `docker compose up -d`.
- NFS originals are not rewritten by a healthy Immich; the old stack remounts the same files.
- If the restore aborts, the CNPG DB stays empty (single transaction) — fix and re-run step 3.

Keep the Docker stack and **both** dumps (`immich-pre-vchord.sql.gz` and
`immich-dump.sql.gz`) until the cluster deployment is confirmed good.

## Notes

- **Auth:** do **not** put the Authentik forwardauth middleware in front of Immich —
  it breaks the mobile app/API. Wire Immich's **native OIDC** to Authentik instead
  (Immich admin settings + an Authentik blueprint), as a separate task.
- **Old DB-dump path:** the Docker stack wrote dumps to
  `10.2.40.10:/mnt/mainPool/backups/immich`. In the cluster, DB backups go to CNPG
  barman → RustFS (`s3://postgres-backups/`). The old path can be retired or kept as
  an extra cold copy; it is **not** mounted into the cluster.
