# Authentik: migrating from Docker Compose into the cluster

This runbook covers a **one-time** migration of an existing **Docker Compose**
Authentik install onto the in-cluster deployment under
`kubernetes/apps/authentik/`. The in-cluster app uses the official
[`authentik` Helm chart](https://charts.goauthentik.io) with **external Postgres
(CloudNativePG)** and **our own Redis**, reached at <https://authentik.int.nerdbox.dev>
(internal only).

Authentik keeps **all** of its state in **PostgreSQL** — users, groups, flows,
providers, applications, certificates, tokens. Redis is only a cache / task
broker. So the migration is essentially a **Postgres logical dump/restore**, plus
carrying over the **secret key**.

For restoring this app from backup (disaster recovery, not migration) see
[backup-recovery.md → Restore: Authentik](backup-recovery.md#restore-authentik).
For wiring cluster apps to Authentik SSO, see [authentik-sso.md](authentik-sso.md).

## ⚠️ What migrates, and what doesn't

- **Migrates (via the Postgres dump):** everything configured in Authentik —
  users, credentials/MFA, groups, flows, stages, prompts, providers,
  applications, outposts, property mappings, tokens, and signing certificates.
- **Does not apply:** anything that lived *around* the compose stack — reverse
  proxy/TLS config, the compose `.env`, and any **separate outpost containers**
  (the embedded outpost in the server pod replaces the compose `worker`/proxy
  outpost; standalone outposts would be redeployed as their own workloads).
- **The recorder/cache** (Redis) is **not** migrated — it rebuilds itself.

> **Version note:** restore into a Postgres **major ≥** the source. The official
> compose uses Postgres 16, and this cluster pins `ghcr.io/cloudnative-pg/postgresql:16`
> to keep the migration a same-major operation. Also make sure the in-cluster
> Authentik **app version is ≥** your old one — Authentik only migrates schemas
> forward.

## Steps

Run `kubectl`/`flux` from this repo's context, pointed at the cluster.

### 1. Carry over the `AUTHENTIK_SECRET_KEY` (do this first)

The deployment ships with a **freshly generated** secret key in
`kubernetes/apps/authentik/secret.sops.yaml`. The secret key signs sessions and
tokens; if it doesn't match the database you're about to restore, the data still
loads but **every session and signed link is invalidated** (users must re-login,
recovery/email links break). To avoid that, replace it with your **existing**
key.

1. On the compose host, read the current value (do **not** paste it into chat):

   ```bash
   grep AUTHENTIK_SECRET_KEY /path/to/authentik/.env
   ```

2. Edit the encrypted secret in place — `sops` opens it decrypted in `$EDITOR`
   and re-encrypts on save:

   ```bash
   sops kubernetes/apps/authentik/secret.sops.yaml
   # set AUTHENTIK_SECRET_KEY to the value from the old .env, save, quit
   ```

3. Commit/PR that change and let Flux apply it (or apply now and reconcile). The
   server/worker restart with the carried-over key.

### 2. Suspend the HelmRelease

Stop Authentik from holding/migrating the database while you restore:

```bash
flux suspend hr authentik -n authentik
kubectl -n authentik scale deploy/authentik-server deploy/authentik-worker --replicas=0
```

### 3. Confirm the CNPG database is up and empty

```bash
kubectl get cluster -n authentik                 # authentik-postgres healthy, 1/1
PRIMARY=$(kubectl get pod -n authentik -l cnpg.io/cluster=authentik-postgres,role=primary -o name)
echo "primary: $PRIMARY"
```

CNPG bootstraps an empty `authentik` database (owner `authentik`) with the
`pg_trgm` extension already created. The next step wipes it to a known-clean
state regardless of whether anything connected first.

### 4. Dump the old database

On the compose host (service name `postgresql`, db/user `authentik`):

```bash
docker compose exec -T postgresql \
  pg_dump --no-owner --no-privileges -Fc -U authentik authentik > authentik.dump
```

`-Fc` = custom format (compressed, restorable with `pg_restore`).

### 5. Restore into CNPG

Copy the dump into the primary pod, reset the schema to a clean slate, and
restore so all objects are owned by the `authentik` role:

```bash
# $PRIMARY from step 3, e.g. pod/authentik-postgres-1
kubectl cp authentik.dump "authentik/${PRIMARY#pod/}:/var/lib/postgresql/data/authentik.dump"

# Clean target schema + ensure the extension exists (as the postgres superuser)
kubectl exec -n authentik "${PRIMARY#pod/}" -- \
  psql -d authentik -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm;'

# Restore (SET ROLE authentik -> objects owned by the app role)
kubectl exec -n authentik "${PRIMARY#pod/}" -- \
  pg_restore --no-owner --no-privileges --role=authentik -d authentik \
  /var/lib/postgresql/data/authentik.dump

kubectl exec -n authentik "${PRIMARY#pod/}" -- rm /var/lib/postgresql/data/authentik.dump
```

> A single `CREATE EXTENSION "pg_trgm" ... already exists` error from
> `pg_restore` is **expected and harmless** — we pre-created it as superuser
> because the app role can't. Any other errors should be investigated.

The DB **role password** in the old dump is irrelevant: the chart reads
`AUTHENTIK_POSTGRESQL__PASSWORD` from the CNPG-generated
`authentik-postgres-app` secret, so the app authenticates with CNPG's
managed password.

### 6. Resume Authentik

```bash
flux resume hr authentik -n authentik
kubectl -n authentik rollout status deploy/authentik-server
kubectl -n authentik logs deploy/authentik-worker -f
```

On start, the worker runs only the **delta** migrations against the restored
schema and applies the blueprints in `/blueprints/custom/`. Watch for migrations
finishing and `Finished authentik bootstrap` with no blueprint errors.

### 7. Verify and cut over

- Browse <https://authentik.int.nerdbox.dev> and log in with an **existing**
  user (working session/MFA confirms the secret key was carried correctly).
- Confirm your providers/applications are present (Admin → Applications).
- The **Grafana** OIDC provider is created by the in-repo blueprint
  (`kubernetes/apps/authentik/blueprints/grafana-oauth2.yaml`); test it by
  logging into <https://grafana.int.nerdbox.dev> via the **"Authentik"** button.
  (Local Grafana admin login stays enabled as a fallback.)
- Once satisfied, **shut down the old Compose stack** so the two don't both serve
  the same identities.

## Notes

- **Alternative (one-shot import):** instead of manual dump/restore, CNPG's
  `bootstrap.initdb.import` (`type: microservice`) can pull the database directly
  from the old Postgres at cluster-creation time via an `externalCluster` +
  `postImportApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS pg_trgm"]`. It's
  elegant when the old DB is network-reachable from the cluster, but harder to
  retry (you must delete the Cluster + wipe its PVC to redo). Manual
  dump/restore is preferred for a one-off because it's trivially repeatable.
- **Backups:** the `authentik-postgres` cluster is backed up by CNPG barman-cloud
  (base + WAL, PITR) to RustFS `postgres-backups`. The secret key lives in Git
  (SOPS). See [backup-recovery.md](backup-recovery.md).
- **Redis** is deliberately ephemeral (cache/broker) and is not backed up.
