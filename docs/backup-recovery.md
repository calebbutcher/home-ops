# Backup & Recovery Runbook

This cluster is GitOps-managed (Flux). Most state is reconstructable from this
Git repo. This document covers the state that is **not** in Git and how to
recover it.

## What is backed up, and where

| State | Mechanism | Destination |
| --- | --- | --- |
| Desired state (manifests, HelmReleases) | Git | GitHub |
| App config PVCs (`*-config` in `media`) | VolSync (restic) | RustFS `volsync` bucket on NAS |
| etcd (cluster runtime state) | k3s `--etcd-s3` snapshots | RustFS `etcd-snapshots` bucket + local on each control node |
| Postgres (CNPG clusters) | barman-cloud plugin (base backup + WAL archive, PITR) | RustFS `postgres-backups` bucket |
| MariaDB (mariadb-operator) | native `Backup` CR (nightly `mariadb-dump` → S3) | RustFS `mariadb-backups` bucket |
| Media / downloads | NAS-level (out of scope here) | NAS `mainPool` |
| SOPS age key | **Manual / offline** | Password manager + offline copy |

RustFS (S3-compatible object storage) runs on the TrueNAS at
`10.2.40.10:30292`, intentionally independent of the cluster it protects.

## Critical secrets (the things that make recovery possible)

1. **SOPS age private key** — `~/.config/sops/age/keys.txt`
   (pubkey `age1wcyzl9vjwakzxtxzw2qupn5332q7kpe8j4zyz434dcx2frqwd58qeutllz`).
   Without it, every `*.sops.yaml` in Git is permanently undecryptable.
   **Store it in the password manager and keep one offline copy.**
2. **Restic repository password(s)** — in the VolSync secret
   (`kubernetes/apps/media/backup/s3-secret.sops.yaml`). Without it the restic
   repos cannot be opened even with RustFS access. Store in the password
   manager.
3. **RustFS access/secret keys** — used by both VolSync and k3s etcd-s3.
4. **`k3s_token`** — must live in the ansible-vaulted secrets file, never
   committed in plaintext.

## Restore: a single app config PVC (VolSync)

1. Suspend the app's HelmRelease and scale the deployment to 0 so nothing holds
   the PVC.
2. Create a `ReplicationDestination` in `media` with `copyMethod: Direct`
   pointing at the same restic secret, e.g.:

   ```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: seerr-config-restore
     namespace: media
   spec:
     trigger:
       manual: restore-once
     restic:
       repository: seerr-restic-secret
       copyMethod: Direct
       destinationPVC: seerr-config   # restore in place, or a scratch PVC
       cacheCapacity: 1Gi
       moverSecurityContext:
         runAsUser: 1000
         runAsGroup: 1000
         fsGroup: 1000
   ```

3. Wait for the mover job to complete (`kubectl get replicationdestination -n media`).
4. Remove the `ReplicationDestination`, scale the app back up, resume the HR.

## etcd snapshots: where they go

k3s auto-snapshots etcd twice daily on each control node. Snapshots are written
locally (`/var/lib/rancher/k3s/server/db/snapshots/`) **and** uploaded to RustFS
(`s3://etcd-snapshots`).

The offsite config currently lives in `/etc/rancher/k3s/config.yaml` on each
control node (root-only, holds the RustFS keys), applied directly + `systemctl
restart k3s` — not via Ansible, because re-running the server play re-invokes
`k3s-init` (unsafe on a live cluster). The Ansible `etcd_s3_enabled` toggle in
`group_vars/all.yml` stays `false` until the RustFS creds are ansible-vaulted;
once vaulted, flip it to `true` so Ansible is the source of truth again. The
relevant config.yaml keys:

```yaml
etcd-s3: true
etcd-s3-endpoint: "10.2.40.10:30292"
etcd-s3-bucket: "etcd-snapshots"
etcd-s3-access-key: "<key>"
etcd-s3-secret-key: "<secret>"
etcd-s3-insecure: true            # http endpoint
etcd-snapshot-retention: 14
```

## Restore: etcd (cluster-level disaster)

On a control node, with the cluster stopped:

```bash
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<snapshot> \
  --etcd-s3 \
  --etcd-s3-endpoint=10.2.40.10:30292 \
  --etcd-s3-bucket=etcd-snapshots \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret> \
  --etcd-s3-insecure
```

Then restart k3s on that node and rejoin the other servers. See the k3s docs on
cluster reset for the multi-server rejoin sequence.

## Restore: CNPG Postgres (point-in-time)

Postgres runs under the **CloudNativePG** operator (`cnpg-system`), one cluster
per app (e.g. `tracearr-postgres` in `media`). Backups go to RustFS
`s3://postgres-backups/` via the **barman-cloud plugin** (base backups +
continuous WAL archiving = PITR). The `ObjectStore`, plugin wiring, and a daily
`ScheduledBackup` live alongside each app (e.g. `kubernetes/apps/media/tracearr/`).

To restore, bootstrap a **new** Cluster that recovers from the ObjectStore — do
not restore in place. Outline:

```yaml
spec:
  bootstrap:
    recovery:
      source: tracearr-postgres
      # recoveryTarget:           # optional PITR target
      #   targetTime: "2026-06-24 00:00:00+00"
  externalClusters:
    - name: tracearr-postgres
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: tracearr-postgres-store
```

Then repoint the app at the new cluster's `-rw` service / `-app` secret. See the
CloudNativePG recovery docs for the full bootstrap-from-objectstore flow.

> **Token caveat:** a snapshot can only be restored with the **server token that
> was in effect when it was taken**. Snapshots predating a token rotation need
> the old token; keep retired tokens in the password manager until their
> snapshots age out.

## Restore: MariaDB (mariadb-operator)

MariaDB runs under the **mariadb-operator** (`mariadb-system`), one instance per
app — currently just `uptime-kuma-mariadb` in the `uptime-kuma` namespace. A
scheduled `Backup` CR (`kubernetes/apps/uptime-kuma/backup.yaml`) runs
`mariadb-dump` nightly (`0 2 * * *` UTC, gzip, 14-day retention) and ships the
dump to RustFS `s3://mariadb-backups/uptime-kuma/`. The S3 credentials are the
`mariadb-rustfs-creds` secret (keys `access-key-id` / `secret-access-key`).

Unlike CNPG, this is logical dump/restore, **not** PITR — you recover to the most
recent (or a chosen) nightly dump, not to an arbitrary point in time. The
operator restores **into the live `MariaDB` instance**; it does not create one,
and the target database is overwritten, so quiesce the app first.

1. Scale the app to 0 so nothing writes during the restore (Uptime Kuma is a
   single Deployment):

   ```bash
   kubectl scale deploy/uptime-kuma -n uptime-kuma --replicas=0
   ```

2. Apply a `Restore` CR in the `uptime-kuma` namespace pointing at the same S3
   location. `targetRecoveryTime` is optional — the operator picks the newest
   backup at or before it; omit it to get the latest dump:

   ```yaml
   apiVersion: k8s.mariadb.com/v1alpha1
   kind: Restore
   metadata:
     name: uptime-kuma-mariadb-restore
     namespace: uptime-kuma
   spec:
     mariaDbRef:
       name: uptime-kuma-mariadb
     # targetRecoveryTime: "2026-06-24T02:00:00Z"   # optional
     s3:
       bucket: mariadb-backups
       prefix: uptime-kuma
       endpoint: 10.2.40.10:30292
       region: us-east-1
       accessKeyIdSecretKeyRef:
         name: mariadb-rustfs-creds
         key: access-key-id
       secretAccessKeySecretKeyRef:
         name: mariadb-rustfs-creds
         key: secret-access-key
       tls:
         enabled: false
     stagingStorage:
       persistentVolumeClaim:
         storageClassName: local-path
         resources:
           requests:
             storage: 2Gi
         accessModes:
           - ReadWriteOnce
   ```

3. Watch the restore job to completion:

   ```bash
   kubectl get restore -n uptime-kuma -w
   kubectl logs -n uptime-kuma job/uptime-kuma-mariadb-restore
   ```

4. Scale the app back up and confirm it reconnects:

   ```bash
   kubectl scale deploy/uptime-kuma -n uptime-kuma --replicas=1
   ```

5. Delete the `Restore` object once it has completed — it is one-shot (leaving it
   is harmless, but tidy to remove).

**Full-rebuild order:** the `MariaDB` instance must exist and be `Ready` before
the `Restore` runs. On a from-scratch recovery, let Flux bring up
`uptime-kuma-mariadb` first, then apply the `Restore`, then let the app start.

## Rotate the k3s cluster token

The cluster token encrypts etcd bootstrap data and authorises node joins. Rotate
it if it leaks (e.g. was committed in plaintext). **Do not** just change
`k3s_token` and re-run the playbook — the server role re-invokes `k3s-init`,
which is unsafe on a live cluster. Use k3s's built-in rotation and roll it
node-by-node:

1. **Save both tokens** (old + new) to the password manager. Existing snapshots
   need the old one.
2. On one server: `sudo k3s token rotate --token <old> --new-token <new>`.
   This re-encrypts the bootstrap data; nodes keep running on the old key until
   restarted.
3. **Servers** read their token from `/var/lib/rancher/k3s/server/token` (the
   persistent `k3s.service` has no `--token`). For each server, one at a time,
   write the new token to config and restart:
   ```bash
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
   token: "<new>"
   EOF
   sudo systemctl restart k3s
   ```
   Verify `EtcdIsVoter=True` + `Ready=True` before moving on
   (`kubectl get node <name> -o jsonpath='{.status.conditions[*].type}'`).
   Do the rotate node last.
4. **Agents** have `--token` hardcoded in `/etc/systemd/system/k3s-node.service`
   (the agent unit is `k3s-node`, not `k3s`). Get the authoritative new token
   from a server (`sudo cat /var/lib/rancher/k3s/server/node-token`), then on
   each worker edit that `--token` value (keep the trailing backslash),
   `systemctl daemon-reload && systemctl restart k3s-node`.
5. Take a fresh snapshot keyed to the new token:
   `sudo k3s etcd-snapshot save --name post-token-rotation`.
6. Update `k3s_token` in the Ansible inventory (ansible-vaulted) so future
   playbook runs use the new token; never commit it in plaintext.

## Full disaster recovery (rebuild from scratch)

1. **Restore the age key** to `~/.config/sops/age/keys.txt` from the password
   manager.
2. Re-provision nodes and install k3s via the Ansible playbook
   (`ansible/`). Restore etcd from the RustFS snapshot if preserving cluster
   identity, or start fresh.
3. **`flux bootstrap`** against this Git repo — Flux reconciles all
   infrastructure and apps, decrypting secrets with the restored age key.
4. VolSync ReplicationSources come up; restore each `*-config` PVC from RustFS
   via the per-app `ReplicationDestination` procedure above before/while the
   apps start.

## Verifying backups are healthy

- `kubectl get replicationsource -n media` → `LAST SYNC` recent for all four.
- `kubectl get etcdsnapshotfiles.k3s.cattle.io` → entries with `s3://` locations.
- `kubectl get cronjob uptime-kuma-mariadb -n uptime-kuma` → recent
  `LAST SCHEDULE`; objects present in RustFS `mariadb-backups/uptime-kuma/`.
- Objects present in RustFS `volsync` and `etcd-snapshots` buckets.
- Periodically run a restore drill (restore `seerr-config` into a scratch PVC
  and confirm `db/db.sqlite3` + `settings.json` are intact).
